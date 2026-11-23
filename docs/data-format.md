# 会话数据格式

iOS 和 Android 采集端输出完全相同的格式，`tools/calibrate.py` 直接读取。

每次录制生成一个会话目录，命名为 `<平台>_<设备标签>_<yyyyMMdd_HHmmss>/`，目录内容如下：

| 文件 | 内容 |
|---|---|
| `meta.json` | 平台、机型、系统版本、App 版本、开始/结束时间、设备标签 |
| `ble.csv` | 每条广播一行 |
| `wifi.csv` | 每次 Wi-Fi 扫描里每个 AP 一行（可选，只有 Android 能扫） |
| `imu.csv` | 约 50 Hz，每个样本一行 |
| `marks.csv` | 每次打点一行 |

所有时间戳 `t_ms` 都是 **Unix 毫秒**（UTC）。

## ble.csv

```
t_ms,point_id,esl_id,rssi,src,mfg_hex
```

- `point_id`：录制这条广播时正在进行的打点编号，不在打点期间为空。
- `esl_id`：标签 ID。解析规则：
  1. 取公司 ID = 13（0x000D）的厂商数据（目标标签广播的厂商 ID）；
  2. 去掉公司 ID 后，payload 长度必须 ≥4 且 <8；
  3. 取前 4 字节，转成大写十六进制，用 `-` 连接，例如 `1A-2B-3C-4D`。

  非标签广播的 `esl_id` 为空。只有关闭「仅标签」开关时才会记录这类广播。
- `rssi`：dBm。iOS 上 RSSI 返回 127 表示不可用，这类记录直接丢弃。
- `src`：发出广播的设备标识。Android 记录 MAC 地址；iOS 拿不到 MAC，记录 CoreBluetooth 分配的 peripheral UUID。
- `mfg_hex`：完整的厂商数据，**包含** 2 字节公司 ID（小端序）。

## wifi.csv

```
t_ms,bssid,rssi,freq
```

可选文件。iOS 第三方 App 拿不到 Wi-Fi 扫描结果，只有 Android 采集端（和公开数据集转换脚本 `tools/bench/ilc_convert.py`）会写；
定位只在评估加 `--wifi` 时用（`public/pdr/cold-wifi` 场景）。

- `t_ms`：这一轮扫描结果上报的时刻。同一轮扫描的各个 AP 用同一个 `t_ms`，读取时按 `t_ms` 分组成一次扫描。
- `bssid`：AP 的 MAC 地址，小写，冒号分隔，例如 `a8:0c:ca:03:9d:d7`。
- `rssi`：dBm。
- `freq`：信道中心频率（MHz），例如 2437、5180。

系统会把之前缓存的旧结果混进新一轮扫描里：AP「最后一次被看到」的时刻比上报时刻早 5 秒以上的不写进来。

## imu.csv

```
t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg
```

数值统一换算成 **Android 传感器约定**，两个平台的数据可以用同一套算法处理：

| 列 | 单位 | 约定 |
|---|---|---|
| ax..az | m/s²，含重力 | 手机屏幕朝上平放时 az ≈ **+9.81** |
| gx..gz | rad/s | 右手系，逆时针为正 |
| mx..mz | µT | 已校准的磁场 |
| mag_acc | — | 磁场精度。iOS 取 -1 到 2（`CMMagneticFieldCalibrationAccuracy`）；Android 取 0 到 3（`SENSOR_STATUS_*`） |
| q* | — | 姿态四元数，只作参考 |
| heading_deg | ° | 系统给出的航向。不可用时为 -1 |

iOS 端的换算方法：
- 加速度：`a_android = -(userAcceleration + gravity) × 9.80665`。CoreMotion 用的单位是 g，而且符号与 Android 相反。
- 陀螺仪和磁场：坐标轴定义与 Android 相同（x 向右，y 指向手机顶部，z 垂直屏幕向外），不需要换算。

## marks.csv

```
point_id,x_cm,y_cm,t_start_ms,t_end_ms,note
```

- `x_cm`、`y_cm` 是场地地图坐标，单位 cm，可以不填。
- 做标定时，**两台手机要并排同时打点，并使用相同的 point_id**。

---

# 格式 v2：地磁可行性实验的附加文件（仅 iOS）

`meta.json` 里 `format_version` 为 2 时，会话目录除上述文件外还有下列文件。v1 的四个文件不变，`calibrate.py` 不受影响。
`meta.json` 另有 `setup_note`（保护壳 / MagSafe / 手持姿态备注）和 `sensors_available`（本次各传感器是否可用）。

| 文件 | 列 | 频率 | 说明 |
|---|---|---|---|
| `mag_raw.csv` | `t_ms,mx,my,mz` | ≈100 Hz | 原始磁力计，µT，设备坐标系，**未做偏置校正**。与 `imu.csv` 里已校准的 `mx..mz` 相减即系统当前估计的偏置，用来检测校准跳变 |
| `baro.csv` | `t_ms,rel_alt_m,pressure_kpa` | ≈1 Hz | 相对高度（起点为 0）与气压 |
| `heading.csv` | `t_ms,magnetic_deg,true_deg,accuracy_deg,x,y,z` | 事件 | CLHeading；`true_deg` 无定位授权时为 -1 |
| `pedometer.csv` | `t_ms,steps,distance_m,cadence_hz,pace_s_per_m` | 事件 | CMPedometer 累计值，缺项为空 |
| `device.csv` | `t_ms,battery,battery_state,thermal,low_power,brightness` | 1 Hz | `thermal`：0 正常 1 偏热 2 严重 3 危急 |

尚未包含：ARKit 位姿（阶段 1 后续，建图真值用）。

---

# 格式 v3：建图采集会话（仅 iOS，`meta.json` 里 `survey: true`）

在 v2 的基础上多两个文件。`meta.json` 另有 `map_width_cm`、`map_height_cm`、`arkit: true`。

`meta.json` 还可以有（扫描段合成之后的地图，见 [scan-and-map-management.md](scan-and-map-management.md)；老会话没有，按 `[0, 0]` 处理）：

| 键 | 说明 |
|---|---|
| `map_origin_offset_cm` | 录制时地图的累计原点偏移 `[x, y]`（cm）。地图后来因为接着扫往 −x / −y 扩展而整体平移过时，读会话的一方（`SurveySessionLoader` / `LiveRunLoader`，hpass-build、`SessionEvaluator` 走同一入口）把 `anchors.csv` / `track.csv` 里的地图坐标加上「地图现在的 `originOffsetCm` − 这个值」；ARKit 坐标不动。会话文件本身不改写 |
| `map_geometry_version` | 录制时地图的几何版本（扫描段注册表每次几何改动递增），只作记录 |
| `map_frame_id` | 录制时地图的基准 AR 坐标系身份（`frameId`），只作记录 |
| `quality_score` / `quality_grade` / `quality_kept` / `quality_reason` | 采集时质量打分的结果（详见 `quality.json`）。`quality_kept = false` 的会话整个不用 |

| 文件 | 列 | 频率 | 说明 |
|---|---|---|---|
| `arkit_pose.csv` | `t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason` | ≈30 Hz | ARKit 世界跟踪位姿。世界系重力对齐，x 右、y 上、z 朝向观察者；俯视时 (x, z) 与地图 (x, y) 手性相同。`tracking`：0 不可用、1 受限、2 正常；`limited_reason`：1 初始化、2 运动过快、3 特征不足、4 重定位、9 其他 |
| `anchors.csv` | `t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note` | 事件 | 操作者在 App 里长按地图记下的已知位置。`kind`：`start` 起点；`reanchor` 走动中的修正；`heading` 设朝向（记的是当时的估计位置，**不是真值**）；`end` 结束时的估计位置（**不是真值**）。`checkpoint` 精度实验的过点打卡（地图坐标 = 长按的已知点，**是真值**，但**不参与对齐**；`note` 里有当时 App 估计的位置「估计 x y 偏 N cm」；`meta.json` 里 `checkpoint_mode: true`）。`ar_*` 是同一时刻 ARKit 的 (x, z)，单位 cm |

| `quality.json` | `CollectionQualityMonitor.Summary` | 结束时 | 采集时质量打分（10 秒一段，和云端 `SessionQualityGate` 同一套阈值）：`score` 0～100、`grade` 好 / 一般 / 差、`kept`、`reason`、`droppedSpansMs`（差段连同前后各一段，绝对毫秒）、`autoStopped` / `stopReason`、`windowList`（每段的分数和问题）。读会话（`SurveySessionLoader`，手机建图和 hpass-build 同一入口）时 `droppedSpansMs` 里的磁场和蓝牙样本不用；`kept = false` 的会话 App 不上传、手机建图不列出、`cloud_build.py` / hpass-build 跳过。没有这个文件（旧会话）= 全部照用 |

离线建图时只把 `start` 和 `reanchor` 当真值：相邻两个锚点之间，用它们拟合「旋转 + 平移」把 ARKit 轨迹对到地图上，终点残差按时间线性摊回去；最后一个锚点之后沿用上一段的旋转，且最多信任 30 m。

---

# 格式 v4：imu.csv 加重力列、四元数写真值（`meta.json` 里 `format_version: 4`）

`imu.csv` 在 v1 的 16 列后面再加三列，老的读取方（只看前 10 列）不受影响：

```
t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz
```

| 列 | 单位 | 约定 |
|---|---|---|
| qw..qz | — | **真的**姿态四元数（设备系 → 参考系，参考系 z 朝上）。v3 及以前实时定位页写的是占位 1,0,0,0，不能用；不可用时全 0 |
| gvx..gvz | m/s² | 设备系里的「向上」× g，**Android `TYPE_GRAVITY` 约定**：屏幕朝上平放 ≈ (0, 0, **+9.81**)，和 ax..az 同号。iOS 的 `CMDeviceMotion.gravity` 平放是 (0, 0, −1) g，写入时要 **× −9.81**，否则 Bz 直接反号。不可用时留空 |

读取端（`IMUSample.fromCSV`）按列数判断：≥ 19 列视为 v4，重力列模长在 5～15 m/s² 之间才用、四元数模长接近 1 才用；
老文件照旧只读前 10 列，姿态和地磁特征退回加速度低通，行为不变。

为什么要这几列：摆臂时手的离心加速度会把「加速度低通」估的向上方向带偏几十度，Bz 差 10～20 µT；CoreMotion 的 gravity 是陀螺辅助的，
不受影响。iOS 端的参考系要用 **不含磁力计** 的 `.xArbitraryZVertical`（`.xArbitraryCorrectedZVertical` 仍用磁力计改善偏航），
偏航只靠陀螺 + 重力，磁场由我们自己处理；换参考系后 `CMDeviceMotion.magneticField` 可能不可用，偏置估计要走原始磁力计那条路（待真机核对）。
四元数目前只在没有重力列时用来推向上方向，**偏航不用**（iOS 四元数到这个约定的换算还没在真机上核对）。

公开数据转换器（`tools/bench/ilc_convert.py`）写 `format_version: 4` + `imu_quat_frame`；iOS App 写 `imu_format: 4` + `attitude_frame`（下表）。
读取端两种都认，只按列数判断格式。

`meta.json` 的 `imu_quat_frame` 说明四元数的参考系（公开数据）：

- `x_arbitrary_z_vertical`：iOS `CMAttitudeReferenceFrame.xArbitraryZVertical`（偏航任意，只用陀螺 + 重力，**不用磁力计**）。
  注意 `.xArbitraryCorrectedZVertical` 会用磁力计改善偏航，不是我们要的；
- `android_rotation_vector`：Android `TYPE_ROTATION_VECTOR`（东北天，偏航参考磁北；公开 ILC 数据集转换时用它）；
- 没有这个键或为 null：四元数不可用。

`meta.json` 相关字段：

| 字段 | 说明 |
|---|---|
| `imu_format` | 4 |
| `attitude_frame` | 实时定位 / 盲测：本机有没过期（30 天，占位）的硬铁偏置存档时 `xArbitraryZVertical`（姿态不用磁力计），否则 `xArbitraryCorrectedZVertical`（iOS 照常给校准后磁场；定位不用 CoreMotion 的姿态 / 偏航，所以不受磁力计参与姿态的影响）；建图 / 采集：`xMagneticNorthZVertical`（要 iOS 校准后磁场和系统航向） |
| `mag_calibration` | `ios`：mx..mz 是 iOS 校准后磁场；`app_hard_iron:<来源>`：参考系不含磁力计时 iOS 不给校准值，mx..mz = `mag_raw` − 本机硬铁偏置，来源 `learned`（建图 / 采集会话学到的存档）、`sphere_fit`（现场球面拟合）、`none`（还没有，mx..mz 为 0、mag_acc = -1） |
| `mag_bias_ut` | 用到的偏置 [x, y, z] µT（有时才写） |
| `mag_pollution` | true = 偏置核对没通过（开始后 15 s 里 \|原始 − 偏置\| 的中位数不在地图 \|B\| 的 P5～P95 ± 15 µT 里，例如磁吸附件），偏置作废、这次只用计步 + 地图 |

`mag_acc`：`ios` 时同 v1；`app_hard_iron` 时 2 = 存档偏置、1 = 现场拟合、-1 = 没有偏置。
mx..mz = 0,0,0 的行（没有偏置时）不是校准值：离线估偏置（`SurveyMapBuilder` / `RawBiasTracker`）和出特征都跳过它们。

## 实时定位 / 盲测会话（`mag-tracks/<时间>_files/`，`meta.json` 里 `live: true`）

不开摄像头也录。文件：`imu.csv`（v4）、`mag_raw.csv`、`ble.csv`、`signs.csv`、`track.csv`（结束时拷入）、`meta.json`；
开了「视觉增强」且摄像头打开过时另有 `arkit_pose.csv` 等（`arkit: true`）。盲测会话另有 `acc_raw.csv`。

`track.csv`：

```
t_ms,x_cm,y_cm,unc_cm,conf,pdr_x,pdr_y,heading_deg,steps,b_total,b_vert,b_horiz,check,src,trust,posture,lat_left_cm,lat_right_cm,room_id,carry_mode,room_mass,carry_auto,frozen
```

- `src`：终端用户定位里恒为 `pdr`（计步永远推粒子）。旧版本出现的 `visual` / `vio` / `vio-raw` 不再产生。
- `check`：`视觉观测` 表示这一刻用了一次视觉重定位当位置观测（σ 50 cm，只在「视觉增强」开着、手机竖持时）。
- `room_id` / `room_mass`：地图有房间单元时，粒子权重最多的房间和它的权重占比（< 0.7 时界面只报房间级）；没有房间图时为空。
- `carry_mode`：盲测会话声明的携带方式（中途切换后跟着变），普通定位为空。
- `carry_auto`：惯导引擎自动判的携带方式（texting / upright / calling / swinging / pocket / bag / still / unknown；「按携带方式调整」关着时恒为 unknown）。
- `frozen`：1 = 静止冻结中（房间图地图上坐着不动够久，粒子不随伪步移动）。

`acc_raw.csv`（盲测机 / 伴随真值机，对时用）：`t_ms,ax,ay,az`，≈100 Hz 原始加速度计（`CMAccelerometerData`），
m/s²，Android 约定（含重力，平放 az ≈ +9.81）。

盲测会话 `meta.json` 另有：`purpose: "blind_test"`、`protocol: "office-carry-v1"`、`camera: false`、`carry_mode`、
`route`、`pair_id`（伴随机广播的 8 位十六进制配对编号）、`pair_source`（`ble` / `manual` / 空）、`bumps_ms`（在线检测到的敲击时刻，只作核对，
离线以 `acc_raw.csv` 互相关为准）、`mode_switches`（`[{t_ms, mode}]`）、`map_id`、`map_version`、`model`、`battery_start/end`、
`thermal_start/end`、`proximity_monitoring`。所有实时定位会话还写 `carry_motion`（「按携带方式调整」开没开）、`room_constraints`、
`ble_background: false`（蓝牙只在前台扫）、`mag_pollution`。

伴随真值机用建图采集的测试会话（`survey: true`、`purpose: "test"`，格式 v3），`meta.json` 另有 `role: "gt_companion"`、
`pair_id`、`lever_arm_cm`、`bumps_ms`、`mode_switch_marks_ms`；地贴处的长按修正记在 `anchors.csv`（`kind = reanchor`）。

## 盲测 / 真值伴随会话（办公室双机协议，`tools/lab/office_carry.py`）

| `meta.json` 键 | 盲测机 A | 伴随机 B | 说明 |
|---|---|---|---|
| `purpose` / `role` | `purpose: blind_test` | `role: gt_companion`（App 写的；建图测试会话 `purpose: test`），或 `purpose: ground_truth` | |
| `camera` | `false`（必须） | — | 有摄像头的盲测会话不收 |
| `pair_id` | 必须 | 必须，和 A 相同 | 配对用 |
| `carry_mode` | `texting` / `pocket_front` / `hand_swing` / `calling` / `bag` / `mixed` … | — | `texting` 等手持看屏的方式已知起点时给真值起步朝向，其余整圆 |
| `lever_arm_cm` | — | 默认 25 | 盲测机在伴随机后面多远（沿行进方向） |
| `map_id` | 必须 | 可选（没有就跟着配对的盲测会话） | |

两机开始、结束各叠在一起敲三下（间隔约 0.5 s）；对时优先用两机的 `acc_raw.csv`（100 Hz），没有时用 `imu.csv`；B 要么是带 `arkit_pose.csv` + `anchors.csv` 的建图式会话，要么已经有导出的 `truth.csv`。

## 位置真值导出（`tools/magmap.py --truth-dir`）

`<会话名>.csv`，列 `t_ms,x_cm,y_cm`，约 10 Hz，是对齐后的地图坐标。给 `hpass-replay` 离线回放用。

## 磁场图（`magmap.json`）

`tools/magmap.py` 的输出，也是 App「地磁定位」页导入的格式：

```json
{ "width": 2000, "height": 1000, "mapElementList": [], "markPoints": [{"id":"1","x":100,"y":200}],
  "magField": { "cellCm": 50, "cols": 40, "rows": 20,
                "cells": [[|B|, Bz, Bh] 或 null, …], "sigma": [[…] 或 null, …], "counts": [n, …] } }
```

数组按行优先，下标 = row × cols + col；单位 µT。`counts` 是每格真实样本数（补齐的格子为 0），只用于质检。
