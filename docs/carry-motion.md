# 携带无关的运动模型（口袋 / 摆臂 / 通话 / 包）

终端用户不开摄像头、手机怎么带都行：口袋、手里摆、贴耳、包里、边走边看。这份文档说明 HPASSKit 里为此改的运动核心、
哪些数值是**占位值**、要用什么数据标定、App / 评估怎么接。

## 问题

原来的惯导假设「手机前向轴 = 行走方向」：看屏时成立，手机进口袋 / 换手 / 拿起来看，前向轴和行走方向的夹角 δ 就突变几十到一百多度，
粒子滤波的航向偏差（随机游走 2°/√m）跟不上，位置冻住或锁到别处。公开 Lab 的「无摄像头」场景是合成漂移，根本不经过 FusionEngine，
所以今天的「可用」说明不了口袋和摆臂。

## 做法（全部在配置后面：HPASSKit 默认关、行为不变；App 默认开，设置 → 定位 →「按携带方式调整」可关）

```
IMUSample(50 Hz, 可选重力列 / 四元数)
  ├─ FusionAttitudeFilter   up 优先用重力列（陀螺辅助），没有就互补滤波；偏航只由 ω·up 积分
  ├─ FusionStepDetector     可选自适应阈值 + 步频锁；K 按模式表
  └─ CarryModeClassifier    重力系特征 → texting / upright / calling / swinging / pocket / bag / still + 「操作手机」事件
            │
            ▼ CarryMotionEvent（initial / changed / handled）
MagneticLocalizer.apply(_:)  按模式切特征权重 / 噪声下限 / 随机游走；changed → 按新模式先验重撒航向偏差与步长比例
                              （粒子位置不动），之后走一段不判丢，期间按「找位置」的强度用地磁
```

1. **输入**：`IMUSample.gravity` / `attitude`（格式 v4 列，见 `docs/data-format.md`），`IMUSample.fromCSV` 读；老数据 nil，退回原来的滤波。
   `MagneticFeatureExtractor` 有重力列时直接用它当「向上」（摆臂时 Bz 误差从几 µT 降到 1 µT 以内，合成数据），或由外部 `setUp` 给姿态滤波的 up。
2. **携带模式分类** `CarryModeClassifier`：2 s 窗、全部在重力系算（屏幕法线倾角、长轴倾角、陀螺 RMS、陀螺能量单轴占比、
   偏航率在步幅 / 步频上的能量比、线加速度起伏、步频），规则 + 阈值表 `CarryModeThresholds`，1.5 s 滞回；
   「操作手机」= 一段 1 s 的陀螺突增（峰值 > 2.5 rad/s，且 > 1.5 × 之前一个步幅的陀螺 RMS），并且突增之前一个步幅、
   之后一个步幅的**平均**「向上」方向转过 > 40°。只比 1 s 前后的瞬时值时，口袋 / 摆臂的大腿、手臂每个步幅本来就来回摆几十度，
   步频不正好 2 Hz（慢走 1.5 Hz）就每两秒误报一次、每次整圆重撒、判丢一直被压着（评审：阻断）；现在步频 1.4～2.2 Hz、摆幅 15～40° 扫过，
   稳定携带零误报。代价是事件晚一个步幅（≈1 s）发出。事件后从陀螺峰值算冻结 1.2 s、清窗口、快速重判（切换延迟 ≈ 3～4 s）。
   竖持（δ≈0 的紧先验）只能从手持（看屏 / 竖持 / 通话）判过去：一上来就竖着、晃得少的手机（包里、胸前口袋、背包侧袋）按包里（整圆）处理。
   `HoldClassifier` 变成它的映射壳，公开接口（`process` / `reset` / `tiltDeg`）不变，`HoldPosture` 多了 calling / pocket / bag。
   App 可以把近距离传感器塞进 `proximityNear`：竖直的手机贴着脸一律算通话（竖持 δ ≈ 0 和通话 δ ≈ ±90° 的先验相反，分错的代价不对称）。
3. **航向**：引擎报的始终是**前向轴**（+y，竖持时 −z，切换按几何补偿）的方位角；行走方向 = 它 + δ，δ 由粒子滤波每个粒子的航向偏差吸收。
   看屏 / 竖持 δ ≈ 0；通话：手机离竖直 < 30° 时前向轴 −z 指向侧面 δ ≈ ±90°，后仰更多时切回 +y 指向后方 δ ≈ 180°（合成数据验证过），
   所以通话先验是 ±90° / 180° 三峰；口袋 / 包 / 摆臂整圆。摆臂 / 口袋用一个步幅周期（两步）的圆平均航向推步，不在步事件瞬间采样
   （合成摆臂：步内航向抖动从 14° 降到 3°）。步内航向噪声按模式表。
   注意：手机大幅翻转时陀螺偏航积分不保几何（合成 texting → pocket 之后引擎航向偏了 90°，不是口袋几何的 35°），所以「操作手机」
   事件本身就把航向偏差整圆撒开，不等分类器；之后 8 s 内判出的模式即使是 texting / upright，也只在已撒开的偏差附近再撒
   `postHandledSpreadDeg`（30°，保留偏差），不按 δ≈0 的 15° 紧先验重撒（评审：口袋 → 拿出来看屏时紧先验可能一个粒子都不在真值附近）。
4. **粒子滤波** `MagneticLocalizer.carryModeChanged(spreadDeg:centersDeg:scaleSigma:keepBias:suppressLostCm:)`：
   只动偏差和步长比例，粒子位置不动；之后 `suppressLostCm` 内不判丢、地磁按找位置的强度（不打 convergedMagWeight 折扣、不按相关长度变软）、
   估计只在另一团明显更重时才换簇（不走 15 次远跳确认）。`setCarryMode` / `apply` 第一次告知不重撒（起点先验还有效）。
   `MagneticConfig.carryModeAdaptive`（默认关）+ `carryTable`。
   只靠地磁的冷启动还没收敛时只重撒、**不进**保护期（保护期改似然温度，会让冷启动收敛门过度自信地错定）。
5. **计步** `FusionStepDetector.adaptive`：阈值 = clamp(max(0.5 σ_dyn, 0.35 × 最近几步峰谷差), 1.0, 2.5)（σ 窗按名义 50 Hz 定长，
   不随毫秒时间戳抖动重建），步频锁只丢距上一步 < 0.6 步周期**且** < 0.45 s 的峰，停下 2 s 清步周期（慢走 / 停顿后不再只数一半）；
   K 按模式表 × 在线学到的比例：`FusionEngine.applyLearnedStepScale(比值, for: 模式)`（吸收一半、限幅 0.6～1.7、可持久化）。
   `StepScaleCalibrator` 把标定包好，App、评估器、流水线测试都用它。**比值只取视觉里程计**（`observeVisualOdometry`：ARKit 跟踪正常时，
   5 m 净位移、≤ 8 s 的窗口里 ARKit 净位移 / 惯导净位移，攒够 20 m 更新一次；比值离谱的窗口——漏步、惯导没在推——整窗不要）。
   原来的「粒子步长比例后验中位数每 50 m 吸收一半」（`learnFromPosterior`）默认关：后验被墙的单边信息压短
   （人走到通道尽头才转弯，走过头的粒子撞墙被罚、走得不够的不受罚；零漂移合成位姿上 −2.5%，真实计步 −4%，撞墙原地不动本身不偏，
   偏差来自撞墙扣分），后验对真值的响应只有 ≈0.37，跨会话每次都在上次学到的 K 上再偏一截：公开 ILC 116 次按时间顺序回放
   （`hpass-eval --carry-k`）看屏 K 1 → 0.64（真值约 0.91），误差中位 / P90 / 错定 2.4 m / 7.1 m / 20% → 3.1 m / 8.4 m / 28%；
   自采 iPhone 商场学到的 K 带到办公室（同一台手机），办公室留一法 P90 233 → 247 cm。计步器距离也不当参照（室内正常步频比 ARKit 长约 11%，
   慢走 0.2～0.9）。没开过摄像头的手机 K 就是模式表的值。
   **实测（合成）**：步频 1.6 / 1.8 / 2.2 Hz、速度 1.3 m/s（真实步长 0.81 / 0.72 / 0.59 m，K=0.45 给 ≈0.65 m）走 55 m 看屏，
   末端误差不标定 14.3 / 6.9 / 1.1 m，标定 14.3 / 6.9 / 1.0 m：跟踪档粒子步长比例的初始 σ 只有 0.06、随机游走 0.005/√m，
   20～25% 的步长失配粒子吸收不了，标定也就学不到（K 只动了 1%）。**每人步长差异是现在最大的误差来源之一**，
   要在双机数据上先量 len_ratio 的人际分布，再定 initialScaleSigma / scaleWalkPerM 或者加一个首次使用的步长标定。
6. **地磁特征权重 / 噪声下限**按模式表（摆臂基本只信 |B|）。

## 占位值（待自采 iPhone 双机数据标定）

RIDI / NILoc 的数字因许可证**全部作废**，下表没有任何一个数值来自它们。每个都要用办公室双机协议（`docs/office-test.md`，
手机 A 按被测方式携带、手机 B 竖持跑 ARKit 做真值，开始 / 结束各敲三下对时）采到的 iPhone 数据重拟。

| 参数 | 现在的占位值 | 怎么标 |
|---|---|---|
| `CarryModeThresholds` 全部阈值 | 物理直觉（口袋大腿摆 ±25° → 陀螺 RMS ≥ 1.3；摆臂 ≥ 1.6、多轴；手持 < 0.9 …） | 各模式各 ≥ 3 人 × 2 机型的会话，`CarryFeatures` 写日志，离线小决策树 / 网格搜索，留出受试者混淆矩阵 ≥ 90%；特别要量 bag（现在几乎没有可靠特征）和坐下 / 起身对「操作手机」事件的误触发 |
| `CarryMotionTable.stepLengthK` | 全部 0.45（现有常量） | 每模式 len_ratio 拟 K；同时量 `applyLearnedStepScale` 在线回写够不够（人际差异和模式间差异一样大，表只是先验） |
| `initialScaleSigma` | 0.10～0.15 | 各模式 K 的人际 / 段际离散 |
| `headingSpreadDeg` / `headingCentersDeg` | texting / upright 15°，calling ±90°/180° 各 30°，其余整圆 | 切换后引擎航向与真值行走方向的夹角分布 |
| `headingBiasWalkDegPerM` | 2 / 2 / 3 / 4 / 5 / 5 | 去 30 s 趋势后夹角的抖动 |
| `stepHeadingSigmaDeg` | 3 / 3 / 10 / 6 / 8 / 10 | 步内航向残差 |
| `featureWeights` / `observationSigmaFloorUT` | texting (0.5,1,0.25)/4（现有跟踪档）… swinging (1,0.3,0.1)/6 | `hpass-eval --residuals` + `tools/bench/mag_residuals.py` 按模式出 t 尺度 / 相关长度；口袋高度（0.8 m）和建图高度的梯度差先做「手持 + 髋部两机同走」的残差实验 |
| `StepDetectorTuning` | 0.5 σ / 0.35 × 峰谷差 / 0.7～2.5 / 0.6 周期（下限 0.7 已按自采 iPhone 标过：看屏走路步峰 P2 ≈ 0.80，手拿着站着的抖动峰 P90 ≈ 0.64；办公室慢走「走着没计到步」的时段 19.5% → 2.3%） | 各模式 steps_ratio 0.97～1.03（含快走）；口袋 / 包的 iPhone 步峰分布出来后复核下限 |
| `lostSuppressCm` | 800 / 1500 | 切换后重新收紧航向要走的路（合成走廊里 5～10 m） |
| `CarryMotionConfig.handledSpreadDeg` | nil（整圆） | 看「换手 / 拿起来看」这类小动作的 δ 变化；若多数 < 45° 可改成 45 |

## 接法（已接好）

App（终端用户定位页，`MagneticEngine.makeFusion` / `makeLocalizer` / `wireMotion` / `handleIMU`）：
- `FusionEngine.live(..., carryMotion: 设置开关)`；有磁场图时惯导**不带通道约束**（只当增量用；冷启动的绝对位置 / 航向是随便给的）；
- `IMUSample` 带 CoreMotion 的陀螺辅助重力（`gravity: -m.gravity × g`）；盲测模式打开近距离传感器，状态给 `fusion.proximityNear`；
- 粒子滤波 `carryModeAdaptive`，`fusion.onCarryEvent = { loc.apply($0) }`，每换一个粒子滤波补 `loc.setCarryMode(fusion.activeCarryMode)`；
- `StepScaleCalibrator.observeVisualOdometry` 在 ARKit 位姿回调里调（摄像头增强开着时），学到的分模式比例存在本机（`StepScaleStore`），
  下次 `setLearnedStepScales` 恢复；`step`（粒子后验）照旧每步调，`learnFromPosterior` 关着时什么都不做；
- track.csv 多 `carry_auto`（引擎判的携带方式）、`room_id` / `room_mass`（房间图地图）、`frozen`（静止冻结）列。

评估（`SessionEvaluator` 的 `.pdrIMU`，`hpass-eval --motion pdr-imu --carry-motion`）同一套接法；已知起点时起步朝向在第一个参考点重设
（盲测会话的预滚——敲击、放口袋、转身——的偏航不带进来），第一个参考点之前的携带事件不重撒。Lab 场景
`public/imu/track-mag-carry`、`public/imu/track-mag-noheading(-carry)` 量它（手持 Android，分类器应判成 texting / upright）。

## 还没做 / 待真机核对

- **锁屏 / 后台**：App 已加位置后台模式保活（`BackgroundKeeper`），CoreMotion 在后台继续；还没有在真机上量过锁屏后的采样率和耗电。
- **近距离传感器**：只在双机测试的盲测机上打开；终端用户定位没开（打开会在手挡住传感器时熄屏）。
- **两个高度**：建图是手持高度（≈1.2 m），口袋 ≈0.8 m，磁场梯度不同；「手持 + 髋部两机同走」的残差实验还没做（`docs/office-carry-test.md`）。
- **磁污染**：本机硬铁偏置存档 30 天过期、开始定位先核对 |B|（磁吸附件 / 磁性保护壳会让它对不上，对不上就作废、这次只用计步 + 地图）；
  iOS 校准参考系那条路靠 iOS 自己的校准和 `MagneticTrustMonitor`。
- **坐下 / 起身**：没有专门的检测器；房间图地图上静止冻结要连续走几步才解冻，坐着挪动不会解冻。
- **蓝牙**：只在前台扫描（没有服务 UUID 过滤，iOS 后台不回报），锁屏后的冷启动没有蓝牙先验。

## 测试

`CarryMotionTests`（合成 IMU，`SyntheticCarryIMU.swift`：人 + 手机刚体运动，加速度 / 陀螺 / 磁场 / 重力列 / 四元数自洽，
每种携带姿态有自己的周期性运动，姿态切换用 1 s 球面插值）：分类各姿态 ≥ 80%、切换 6 s 内判出、事件时刻、静止沿用携带姿态；
看屏 → 竖持航向不变；口袋夹角常数；通话几何 ±90°/180°；摆臂步幅平均；重力列 vs 加速度低通的 Bz；自适应计步不计次峰；
分模式 K 与在线标定；`carryModeChanged` 粒子不动、整圆 / 双峰 / 保留原偏差、保护期；整条流水线看屏 20 m → 口袋 / 通话 / 摆臂 30 m：
末端误差 13 / 24 / 41 cm、没判丢、重撒那帧估计不瞬移；同一剧本老路径（没有重撒）口袋末端误差 55 m；
看屏 → 口袋 → 看屏（罗盘关）末端 21 cm；只靠地磁冷启动中途换携带方式不进保护期、不报错位置；
稳定口袋 / 摆臂 1.4～2.2 Hz、15～40° 不误报「操作手机」；计步在时间戳抖动、慢走接正常步频时不漏步；步长失配网格（见上）。

合成数据只能证明机制对，证明不了数值对：所有阈值和表都要按上面的办法用自采数据重标。
