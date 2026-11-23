# 定位实验室（Lab CI）

目的：要做到 Oriient「走一遍就能用」的水平，每一次算法改动都必须在**固定数据、固定协议**上量出来，退步当场拦住，离目标还差多少一眼看清。全部在 GitHub Actions 里跑，不依赖谁的电脑。

## 怎么跑

| 触发 | 档位 | 场景 | 结果去哪 |
|---|---|---|---|
| PR（改了 `ios/HPASSKit/Sources`、`tools/lab`、`tools/bench`） | pr | 核心公开场景（含真实 IMU 的 `public/imu/track-mag`、`public/imu/cold-mag-radio`）+ 自采场景，每场景 3 个随机种子 | PR 评论（只保留一条，每次更新）+ 运行 Summary；**有退步 PR 检查失败** |
| push 到 main | pr | 同上 | 看板「评估」 |
| 每晚 北京时间 02:00 | nightly | 全部场景，5 个种子 | 看板「评估」，最上面是趋势表 |
| 手动（Actions → Lab → Run workflow） | 可选 | 可只跑某些场景 | 可勾「把这次结果提成新基线」 |

工作流：[.github/workflows/lab.yml](../.github/workflows/lab.yml)；场景、门槛、档位：[tools/lab/suite.json](../tools/lab/suite.json)；运行器：[tools/lab/lab.py](../tools/lab/lab.py)。

## 数据和协议

**公开数据**（每次都跑，不需要任何口令）：Microsoft Indoor Location Competition 2.0 商场一层（MIT 许可，CI 里下载并缓存）。测试会话的位姿是合成漂移，见 [benchmark.md](benchmark.md)。

| 场景 | 意义 |
|---|---|
| `public/pdr/track-mag` | 已知起点 · 只地磁 · 无摄像头（PDR 级漂移）：磁场图 + 滤波本身有多准 |
| `public/pdr/cold-mag` | 冷启动 · 只地磁 · 无摄像头：App 的冷启动配置档（`MagneticConfig.liveColdStart`）只靠地磁不报位置（评估里是 `--no-mag-only-cold-fix`），**场景目标只看错定 ≤ 20%、不报位置也算**（见下）。一个位置都不报，按构造只能达标，所以每晚跑、**不拦** |
| `public/pdr/cold-mag-search` | 同上但照常报位置（**拦退步**，和基线比）：量共用的冷启动搜索（蓝牙等外部先验到了之后用的也是它）有没有变坏 |
| `public/pdr/cold-mag-radio` | 冷启动 · 地磁 + 蓝牙 |
| `public/pdr-sparse/track-mag` | 建图只用 15 条 trace：模拟「只走几趟」的稀疏建图 |
| `public/vio/*`、`public/pdr/track-mag-radio` | 每晚跑：视觉里程计级漂移、已知起点 + 蓝牙（`public/vio/cold-mag` 和 `public/pdr/cold-mag` 一样只看错定、不拦；`public/vio/cold-mag-search` 拦退步） |
| `public/imu/track-mag`、`public/imu/cold-mag-radio`（PR + 每晚）；`public/imu/cold-mag-search`、`public/imu/cold-wifi`（每晚） | **真实 IMU**：数据集 `ilc-imu`（`ilc_convert.py --drift imu --flip-y`）的测试会话不写合成位姿，`hpass-eval --motion pdr-imu` 把手机的真实 IMU 送进 FusionEngine（配置和 App 实时定位页同一份 `FusionEngine.live`，罗盘关），推算位置的增量再推粒子（`ShadowLocalizer.odometryStep`）。已知起点的起步朝向取真值前 1.5 m（ILC 是手持，手机-行走夹角 δ≈0）；冷启动从地图中心、朝向 0 起步、粒子整圆。多出一张「办公室指标」表（≤1 m 按时间、TTFF 等） |
| `public/imu/track-mag-carry`（PR + 每晚）；`public/imu/track-mag-noheading`、`public/imu/track-mag-noheading-carry`（每晚） | 同上的真实 IMU 回放，加 `--carry-motion`（携带无关运动模型 + 按携带方式重撒 + 步长 K 在线标定，App 默认）和 / 或 `--start-heading unknown`（起步朝向整圆：口袋 / 包里起步的条件）。ILC 是手持数据，携带方式分类应判成看屏 / 竖持，这几个场景守的是「新运动模型在手持上不比老的差」，口袋 / 包 / 摆臂 / 通话仍要等自采 office-carry 数据 |

**合成小场地**（`sim-*`，每次都跑，不用任何外部数据，可以放心公开和商用）：[tools/bench/sim_small.py](../tools/bench/sim_small.py) 按自己定的模型生成
房间 + 门的地图（单元、MapDoor）、磁场（地磁背景 + 随机平面波 + 墙里的偶极子，统计量对着真实办公室调）、建图会话（经门走遍每间房，房里来回走）
和测试会话（房间之间随机走、偶尔停下）。商场数据量不到「小面积」的问题（房间认反、过门、步长偏短在十几米的房间里放大），这组专门量它。

| 场景 | 意义 |
|---|---|
| `public/sim-office/track-mag` | 约 320 m² 办公室，已知起点，只地磁 + 房间约束，PDR 漂移（尺度 σ4%） |
| `public/sim-office-phone/track-mag`、`public/sim-pair-phone/track-mag` | 同上 / 两间并排一扇门，漂移按 2026-11 办公室实测：步长系统性偏短（尺度均值 0.82）。和上一行的差 = 步长偏短的代价 |
| `public/sim-office-phone/cold-mag`（每晚） | 冷启动 |

合成数据只能说明「算法在一个干净、地图和真值完全一致的世界里」怎么样；真实地图的毛病（比如房间分界画错）要靠下面的自采留一法。

`public/pdr/*` 不经过 FusionEngine（位姿是合成的），留着当粒子滤波 / 地图侧的回归守门；`public/imu/*` 和它同一份建图 / 测试划分，
两组数字的差就是「合成漂移 vs 真实计步」的代价。ILC 的坐标 y 朝北，我们的地图 y 朝下（`FusionTypes.swift`：θ̇ = +ω_up），
不翻转时真实陀螺的左转在地图上变成右转（量过：不翻转纯推算中位 15～60 m，翻转后 1.5～15 m），所以 `ilc-imu` 带 `"flip_y": true`；
合成位姿只有旋转，老数据集不用翻。ILC 只有手持，口袋 / 包 / 摆臂只能靠自采的 office-carry 协议量。

**自采数据**（有后台口令时自动加入）：后台里每张地图的建图会话和测试会话（采集时打开「这次是测试会话」）。

| 协议 | 做法 |
|---|---|
| `leave-one-out` | **不用专门去走测试**：一张地图有 ≥ 3 次能用的建图会话时，每次拿掉一次，用其余的建图，再把拿掉那次的真实 IMU + 磁力计按 App 默认配置回放（`--motion pdr-imu --carry-motion --rooms --stationary-freeze`），参考轨迹 = 它自己的锚点 + ARKit。已知起点、冷启动各一个场景，带办公室指标；先不拦（`gate: false`）。后台排除名单（`/api/config/exclude`）和采集质量不合格的会话不用 |
| `walk-once` | **每个建图会话单独建图（= 只走一遍）**，用不是同一天的测试会话来测，所有组合混在一起出指标。这是对标 Oriient「走一遍就能用」的核心指标 |
| `all-builds` | 全部建图会话融合后测 |
| `track` | 全部建图会话融合，**已知起点跟踪**（`--oracle-start`）：量 App 实时定位的跟踪配置档（`MagneticConfig.tracking`）在自采门店上的表现。前两个协议都是冷启动 |
| `office-carry` | **办公室双机盲测**：盲测机 A（`purpose=blind_test`、`camera=false`、按被测携带方式带）配同一 `pair_id` 的真值伴随机 B（竖持 ARKit）。`tools/lab/bump_sync.py` 用两机开头 / 结尾各敲三下的 \|a\| 峰求时钟偏移 + 漂移（残差 > 20 ms 的组不用）；B 的轨迹换到 A 的时钟、沿行进方向后挪杆臂 0.25 m、只留开始敲击 3 s 后到结束敲击前，写成 A 的 `truth.csv`（`tools/lab/office_carry.py`）。回放 `--motion pdr-imu --carry-motion --rooms --stationary-freeze`（和 App 默认一致：携带无关运动模型、房间约束、静止冻结），出两个场景：`…/office-carry/track`（已知起点；texting 等手持看屏给真值朝向，其余 `--start-heading unknown` 整圆）和 `…/office-carry/cold`（App 冷启动配置档，只靠地磁不报位置）。指标见下「办公室指标」，按携带方式、地图年龄分组 |

仓库是公开的：报告、日志里站点只用代号（`site-xxxxxx`），不出现地图编号、名称、会话内容、坐标、房间名、日期。
设置了环境变量 `HPASS_LAB_SALT`（CI 用仓库 secret）时代号 = HMAC-SHA256(盐, map_id) 前 6 位——`sha1(map_id)` 拿已知的地图编号一试就能对上，
加盐才藏得住；没有盐时退回老的 sha1 前 6 位（老结果的代号不变）。

## 办公室指标（`tools/lab/office_metrics.py`）

`hpass-eval --track-out track.csv` 每个运动节拍写一行（`session,run,t_ms,est_x,est_y,converged,unc_cm,ref_x,ref_y,room_id,room_mass,carry_mode,frozen`；
后四列是 `--rooms` 时滤波器报的房间 / 房间置信度、`--carry-motion` 时引擎判的携带方式、`--stationary-freeze` 时是否冻结），
`office_metrics.py` 按 1 Hz 网格、用 `map.json` 的房间单元（`units`）算：

| 指标 | 口径 |
|---|---|
| `room_correct` / `room_correct_all` | 报了位置时房间对的比例 / 全部时间（没报位置算错）。真值离单元边界 < 0.5 m 的点不计 |
| `wrong_room_adjacent` / `wrong_room_far` | 错到相邻房间（两单元最近距离 ≤ 0.6 m）/ 不相邻的地方 |
| `door_latency_p50_s` / `_p90_s`、`door_miss` | 真值进新房间后，估计进入并连续保持 3 s 用了多久；> 15 s 算漏 |
| `within1m_points` / `within1m_time` | ≤ 1 m：按定位点 / 按全部时间 |
| `p50_cm` / `p90_cm`、`coverage` | 报了位置的网格点的误差、报了位置的时间占比 |
| `ttff_s_p50` / `ttff_m_p50`、`ttff_rate` | 第一次「房间对且 ≤ 2 m 并保持 10 s」的时间 / 路程（没发生按窗口截尾）、定到率 |
| `wrong_fix_before_first_correct` | 首个正确定位前「报了但 > 5 m 或房间错」的次数（按连续段） |

分组：`by_carry_mode`、`by_map_age`（0 / 1–7 / 8–30 / >30 天）。档位 `office_ladder`（suite.json）：
可用 = 房间判对 ≥ 85%、远房间错 ≤ 3%、P50 ≤ 2.5 m、P90 ≤ 5 m、TTFF ≤ 30 m；目标 = 92% / 2% / 1.5 m / 3 m / 20 m（首批自采数据后再定）。
没有房间单元的地图（公开 ILC）房间类指标为空、不评档。真值有 0.3–0.5 m 底噪，≤ 1 m 会被系统性低估，版本间只看差值。

## 指标与判定

每个场景把所有测试会话、所有随机种子的定位点混在一起：中位、P75（IPIN 竞赛口径）、P90、错定（误差 > 5 m 的比例）、覆盖（参考轨迹上有多少比例给出了定位）、首次定位前走的距离、定到率。

- **退步**（PR 失败）：和 `tools/lab/baseline.json` 比，中位变差超过 15% + 0.3 m、P90 变差超过 15% + 0.6 m、错定多 5 个点、覆盖少 7 个点、定到率少 10 个点；或者以前能跑的场景现在跑不出结果。容差是给粒子滤波的随机性留的。
- **档位**（只显示，不拦）：

| 档位 | 中位 | P90 | 错定 | 覆盖 |
|---|---|---|---|---|
| 可用 | ≤ 3 m | ≤ 6 m | ≤ 20% | ≥ 50% |
| 目标 | ≤ 2 m | ≤ 4 m | ≤ 10% | ≥ 60% |
| 对标 Oriient | ≤ 1.5 m | ≤ 3 m | ≤ 5% | ≥ 70% |

报告里每个场景都写着「离对标 Oriient 还差多少」。覆盖也是门槛，防止靠「只在有把握的少数点上报位置」刷指标。

**场景目标**（`suite.json` 里场景的 `"target"`，例如 `{"wrong_fix": 0.2, "no_fix_ok": true}`）：有的场景按产品决定不要求完整档位。
只靠地磁的冷启动（`public/pdr/cold-mag`、`public/vio/cold-mag`）就是这样：这层楼上十几米的磁场序列能对上很多处
（各种收敛门组合下错定都还有 91～100%），拿不到外部先验（蓝牙 / 贴近标签 / 货架标识牌 / 用户指起点）时，
App **不报位置，也不报很自信的错位置**：实时定位页冷启动用 `MagneticConfig.liveColdStart`，里面 `magOnlyColdStartReports = false`
（单元测试 `TrackingProfileTests.testLiveColdStartProfile` / `testLiveColdStartPriorsLiftSuppression` 守着这一点和解除它的外部先验）。
评估的冷启动（`ShadowLocalizer`）用同一份配置档，只是默认照常报位置（采集时的影子定位用），`--no-mag-only-cold-fix` 换成 App 的行为。
这两个场景一个位置都不报，按构造只能达标，所以**不当退步门槛**（每晚跑、只监看）；拦退步的是照常报位置的
`public/pdr/cold-mag-search`（PR + 每晚）和 `public/vio/cold-mag-search`（每晚），和基线比。

- 档位列只写「✅ 达标 / 未达标（场景目标：…）」，差距也按目标算；
  一个位置都没报时，只有目标写了 `"no_fix_ok": true` 才把错定按 0 算（注明「没有报位置」），否则算没量到（未达标 / 退步）。
- 退步只看目标里列出的指标（上例只看错定）；其余指标（覆盖、定到率、中位、P90）按设计会变，写在「目标不看：…」里，只显示不拦。
- 没有 `target` 的场景照旧用完整档位和全部退步判定。

冷启动收敛门（`hpass-eval --cold-gate`，`ShadowLocalizer(coldStartGate:)`，参数见 `MagneticConfig.applyColdStartGate` / `ColdStartGate`）：
只在冷启动、还没用过任何外部位置先验（蓝牙粗定位 / 标签范围 / 区域观测）时起作用；要走够路、有效粒子够多、最重的簇明显压过 5 m 外的第二个簇、
连续更多次满足收敛条件，才宣布定到。默认关（自采场景、采集时的自动起点不变）；`--oracle-start`（已知起点跟踪）从不用。
公开楼层上它本身降不下错定（91～100%），Lab 场景没用它；「只靠地磁不报位置」是单独、明说的开关（`--no-mag-only-cold-fix`）。

## 基线

1. 第一次：还没有 `baseline.json`，实验室只报告不拦。合并后手动跑一次 nightly 并勾「把这次结果提成新基线」，工作流会推一个 `lab/baseline-<运行号>` 分支并尝试开 PR（仓库设置里没允许 Actions 开 PR 时，日志里给出手动开 PR 的链接）。
2. 之后：算法有了确定的改善（报告里一片 🟢），同样操作更新基线，把进步「锁住」。
3. 加新场景：改 `suite.json`；新场景没有基线时标 🆕，不拦。

## 本地

```bash
python -m unittest tools/tests/test_lab.py
```

```bash
python tools/lab/lab.py report --results lab-results.json --baseline tools/lab/baseline.json
```

`run` 需要 `hpass-eval`（macOS 上 `swift build -c release --product hpass-eval`），一般直接用 CI。

单独看一份逐点轨迹 / 对一对时：

```bash
hpass-eval --map map.json --build build --test test --oracle-start --no-ble --motion pdr-imu --track-out track.csv
python -I -X utf8 tools/lab/office_metrics.py --track track.csv --map map.json [--meta meta.json] --json office.json
python -I -X utf8 tools/lab/bump_sync.py 盲测/imu.csv 伴随/imu.csv
```

## 下一步

- 多楼层场景：接入带气压的公开数据（IPIN 竞赛数据）后加楼层判对率，按 IPIN 口径楼层错一层罚 15 m。
- 无摄像头的真实 PDR：公开数据已有 `public/imu/*`（手持）；口袋 / 包 / 摆臂 / 通话要等自采 office-carry 数据。
  双机对时目前只用敲击（|a| 峰）；评审意见：iPhone 50 Hz deviceMotion 会削平敲击脉冲，以后加「两机贴紧一起转 2–3 s」的陀螺互相关。
- 耗时与耗电：回放计时已记录（`seconds`），后续加每秒计算量的预算。
