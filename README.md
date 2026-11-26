<p align="center">
  <img src="docs/assets/logo.svg" width="128" height="128" alt="HPASS logo">
</p>

<h1 align="center">HPASS Indoor Positioning &amp; Navigation</h1>

<p align="center">
  Phone-only indoor positioning — geomagnetic field + inertial dead reckoning, no installed hardware.<br>
  只用手机、不装硬件的室内定位与导航：地磁 + 惯导。
</p>

<p align="center">
  <a href="#status">Status</a> ·
  <a href="#reports">Reports</a> ·
  <a href="#build">Build</a> ·
  <a href="#中文说明">中文说明</a>
</p>

---

HPASS locates a phone inside a building using the **Earth's magnetic field as distorted by the building** (a magnetic
map built by walking the site once) combined with **pedestrian dead reckoning** from the phone's IMU and the **walls of the
floor plan**. Bluetooth tags and the camera are optional add-ons; neither is required.

All algorithms are implemented from public literature — no vendor SDKs. The repository contains no raw sessions, map
packages, credentials or server addresses; the research reports under `docs/` contain aggregate statistics and a few plots.

## Design principles

These are the constraints every change is judged against.

- **Cold start from anywhere.** Real customers never tap a starting point and may open the app anywhere in a store, so
  there is no "tap your start" step and no entrance prior. The target is a unique fix within ~10 m from any start,
  then metre-level tracking.
- **Camera optional, off by default.** Visual odometry / relocalisation (ARKit) is a switchable enhancement
  (*Settings → 视觉增强*). Accuracy is always judged with the camera **off**.
- **No Wi-Fi fingerprinting.** iOS apps cannot scan Wi-Fi. The Wi-Fi code only exists to replay public benchmark data.
- **Bluetooth is optional.** BLE tag fingerprints / beacons act as a cold-start prior and wrong-fix detector where they
  exist; the office and the test store have none.
- **Magnetics: 3-axis vector + sequence.** In flat fields a single reading carries almost no information, so the
  direction of work is map-frame 3-axis vectors matched over a walked sequence rather than |B| per step
  ([flat-field report](docs/flat-field-localization.md)).
- **Measure everything.** Every algorithm change is replayed on fixed data in CI ([Lab CI](docs/lab-ci.md)); claims in
  docs cite the replay they came from.

## How it works

```
 survey walk (ARKit pose = truth, App-calibrated magnetometer bias)
        │
        ▼
 magnetic map  ──  multi-session fusion, route consistency (green / yellow / red / gray), map-up bearing
        │
 live: IMU ──► step detection + step length + attitude ──► particle filter ◄── walls / rooms
                                                              ▲      ▲
                                    magnetic likelihood ──────┘      └── optional: BLE, camera, barometer (floor)
        │
        ▼
 position ──► A* routing ──► turn-by-turn hints
```

| Capability | Details |
|---|---|
| Magnetic positioning | Magnetic field map + particle filter; cold start, lost-track detection and re-search, cross-session field offset alignment |
| Inertial / visual odometry | Step detection + Weinberg step length + attitude fusion; carry-mode classifier (texting, pocket, swing, call, bag); ARKit visual odometry as motion model when the camera is on |
| Map constraints | Corridor graphs or walkable polygons / rooms; particles cannot cross walls |
| Floors | Barometer floor-change detection; distinguishes lift / escalator / stairs |
| Radio (optional) | BLE fingerprints / beacons as cold-start prior and wrong-fix check |
| Visual (optional) | Room-scale visual relocalisation; sign text recognition as absolute landmarks |
| Mapping | Walk the site with the phone: ARKit poses as ground truth; map built on the phone or in the cloud; multiple surveys fused automatically; per-route consistency colouring and segment editor on the dashboard |
| Map sources | Own map format, IMDF venue import, RoomPlan 3-D scans (exportable as IMDF) |
| Navigation | A\* routing with turn penalty, turn hints, arrival detection |
| Map maintenance | Detects magnetic changes while localising and flags areas that need re-surveying |
| Evaluation | Replay evaluator (`hpass-eval`), public-dataset benchmark, leave-one-out on own surveys; median / P90 / wrong-fix rate / first-fix distance |

## Status

*As of 2026-11-26.* Two real sites are under test, both without BLE tags.

**Office (~200 m², one floor)** — [corridor check report](docs/reports/office-corridor-check-20261126.md)

| Metric | Value |
|---|---|
| Magnetic coverage of walkable area | 41.5 % overall — corridor ≈ 100 %, rooms off the corridor ≈ 22 % |
| Survey route consistency | 22 green / 8 yellow / **0 red** / 2 gray |
| 1 m magnetic contrast (median) | 4.4 µT |
| Live cold start, corridor part | 1–2 m (median 1.9 m) vs. camera ground truth; lost (14–17 m) after entering an unsurveyed room |
| Leave-one-out tracking replay, camera off | median 104 cm / P90 231 cm |
| Cross-session cold start, 3-axis vector + sequence (research) | correct within 10 m: 73 % → 93 % |

Missing: room interiors and corridor → room transitions; camera-off cold-start runs to confirm the live number.

**Test store (~200 m²)** — [drift diagnosis](docs/reports/tesco-drift-20261125.md),
[flat-field study](docs/flat-field-localization.md)

| Metric | Value |
|---|---|
| Magnetic coverage of walkable area | ~21 % |
| 1 m magnetic contrast (median) | **1.2 µT** — 84 % of the area is below 2 µT ("flat") |
| Leave-one-out tracking replay, camera off | median 214 cm / P90 454 cm (magnetics adds ~nothing; walls do the work) |
| Cold start | 57 % of reported fixes > 5 m off |

The field is too flat and too sparsely surveyed. Next step: **re-survey** the interior aisles in both directions with
crossing routes, draw the shelf geometry, then implement vector features in the map and particle filter.

**Public benchmark** — Microsoft Indoor Location Competition 2.0 mall floor plus synthetic small sites, replayed on every
PR and nightly; see [Lab CI](docs/lab-ci.md) and [benchmark](docs/benchmark.md).

## Reports

Research and diagnosis reports (Chinese, with data tables):

| Date | Report | Topic |
|---|---|---|
| 2026-11-26 | [Office corridor check](docs/reports/office-corridor-check-20261126.md) · [plot](docs/reports/office_20261126_coverage.png) | Coverage by region, route consistency, live cold-start error |
| 2026-11-25 | [Flat magnetic field localisation](docs/flat-field-localization.md) | How flat the test store is, what magnetics adds, vector + sequence matching |
| 2026-11-25 | [Test-store drift diagnosis](docs/reports/tesco-drift-20261125.md) · [plot](docs/reports/tesco_20261125_overview.png) | Cold start on a 23 %-coverage map; why one corner was accurate |
| 2026-11-23 | [Route verification research](docs/route-verification-research.md) | How commercial tools verify survey routes; overlap as the bottleneck |
| 2026-11-23 | [Survey route consistency](docs/survey-route-consistency.md) | Segment editor and green / yellow / red / gray rules |
| — | [Sensor audit and options](docs/sensor-audit-and-options.md) | Which sensors are actually used in live positioning |
| — | [Public benchmark](docs/benchmark.md) · [Lab CI](docs/lab-ci.md) | Replay protocol, scenarios, regression gates |

Plans and design:
[generic positioning roadmap](docs/generic-positioning-roadmap.md) ·
[geomagnetic plan](docs/geomagnetic-plan.md) ·
[Oriient-level benchmark plan](docs/oriient-benchmark-plan.md) ·
[roadmap (shelf-aisle site)](docs/roadmap.md) ·
[universal in-store navigation](docs/universal-store-navigation-design.md) ·
[carry-independent motion model](docs/carry-motion.md) ·
[scan & map management](docs/scan-and-map-management.md) ·
[3-D visualisation](docs/3d-visualization-plan.md) ·
[iOS UI/UX redesign](docs/uiux-redesign.md)

Guides:
[survey & localisation guide](docs/survey-and-localization-guide.md) ·
[office accuracy test](docs/office-test.md) ·
[office carry test (two phones)](docs/office-carry-test.md) ·
[RoomPlan → IMDF](docs/roomplan-imdf-authoring.md) ·
[sideload without Xcode](docs/sideload.md) ·
[session data format](docs/data-format.md)

## Repository layout

| Path | Contents |
|---|---|
| [`ios/HPASSKit`](ios/HPASSKit/README.md) | Core positioning & navigation library (Swift Package, Foundation only, no third-party deps) and CLIs `hpass-replay`, `hpass-eval`, `hpass-build` |
| `ios/HPASSApp` | iOS survey + positioning app (SwiftUI, iOS 16+, XcodeGen project) |
| `android` | Android BLE tag survey app (Kotlin) |
| [`server/telemetry`](server/telemetry/README.md) | Cloud backend (Cloudflare Workers + R2): live logs, sessions / maps / reports, dashboard, route editor |
| `tools/` | Offline tools: map QA, magnetic feasibility, LiDAR geometry check, cross-device RSSI calibration, cloud map build |
| `tools/lab`, `tools/bench` | Lab CI runner and public-dataset benchmark |
| `tools/research` | Scripts behind the research reports |
| `tools/venue` | Venue map conversion (IMDF) |
| `web/` | Map editor |
| `docs/` | Design docs, reports, data formats, guides |

## Build

**Core library and CLIs** (macOS; also builds on Linux with a Swift toolchain)

```bash
cd ios/HPASSKit && swift test
cd ios/HPASSKit && swift build -c release
```

**iOS app** (Mac + Xcode 15+). The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen); no
`.xcodeproj` is committed. Run `xcodegen generate` in `ios/HPASSApp`, open the project, pick your team under
*Signing & Capabilities* and change the bundle identifier if needed. Or install a CI-built package — see
[sideload](docs/sideload.md).

**Android app**

```bash
cd android && ./gradlew assembleDebug
```

**Python tools**

```bash
python -m unittest discover -s tools/tests
```

## Continuous integration

| Workflow | What it does |
|---|---|
| `ci.yml` | Core library tests, iOS / Android builds, Python tool tests, backend checks |
| `lab.yml` | Positioning lab: replays fixed data and protocols, measures accuracy, flags regressions |
| `collection-eval.yml` | Daily: revisit consistency, magnetometer bias drift, live error vs. ARKit, coverage per map |
| `map-build.yml` | Cloud fused map build (manual or after a survey upload) |
| `ios-adhoc.yml` | Signed Ad Hoc iOS build on merge to `main` |
| `deploy-telemetry.yml` | Deploys the backend on changes to `server/telemetry` |

## Icon

The app icon and logo are original artwork: a location pin over magnetic field isolines, with a trail of footsteps
(dead reckoning) leading to it. Sources: [`docs/assets/app-icon.svg`](docs/assets/app-icon.svg) (full-bleed, iOS) and
[`docs/assets/logo.svg`](docs/assets/logo.svg) (rounded). The iOS asset catalog and Android launcher icons are rendered
from them.

---

## 中文说明

HPASS 是只用手机、不装硬件的室内定位与导航系统，全部自研。核心是**地磁指纹 + 惯导（PDR）+ 地图墙体约束**的粒子滤波；
蓝牙标签和摄像头是可选增强，不是必需。算法基于公开文献自行实现，不依赖厂商 SDK。仓库里没有原始会话、地图包、账号和服务器地址；
`docs/` 里的研究报告只有统计结果和少量图。

### 设计原则

- **任意位置冷启动**：真实顾客不会点起点，可能在店里任何地方打开 App，所以不做「点起点」，也不用入口先验。目标是从任意起点在约 10 m 内唯一定位，然后米级跟踪。
- **摄像头可关、默认关**：视觉增强（ARKit 视觉里程计 / 重定位）在「设置 → 视觉增强」里开关；精度一律按关摄像头评估。
- **不做 Wi-Fi 指纹**：iOS 扫不了 Wi-Fi，Wi-Fi 代码只用于回放公开数据集。
- **蓝牙可选**：有标签的场地用作冷启动先验和错定检测；办公室和测试店都没有标签。
- **地磁走三轴向量 + 序列匹配**：平坦区单点读数几乎没有信息，方向是地图坐标系三轴向量沿走过的一段路做匹配（见[平坦区报告](docs/flat-field-localization.md)）。
- **一切用数据说话**：每次算法改动都在 CI 里用固定数据回放（[定位实验室](docs/lab-ci.md)）。

### 现状（2026-11-26）

- **办公室（约 200 m²）**：走廊磁场基本全覆盖，走廊外约 22 %（整图 41.5 %）；路线一致性 22 绿 / 8 黄 / 0 红 / 2 灰；
  走廊冷启动误差 1–2 m（中位 1.9 m，对照摄像头真值），走进没采过的房间后跟丢；关摄像头留一法跟踪回放中位 104 cm / P90 231 cm；
  三轴向量 + 序列匹配让跨会话冷启动 10 m 内正确率 73 % → 93 %。详见[走廊核对报告](docs/reports/office-corridor-check-20261126.md)。
- **Tesco 测试店（约 200 m²）**：磁场太平（1 m 起伏中位 1.2 µT，84 % 低于 2 µT），覆盖约 21 %；跟踪基本靠墙，冷启动 57 % 的报点错 5 m 以上。
  需要**补采**内部通道（双向 + 交叉）并画货架。详见[漂移诊断](docs/reports/tesco-drift-20261125.md)和[平坦区研究](docs/flat-field-localization.md)（PR #84）。

### 报告

见上方 [Reports](#reports) 一节的表格：走廊核对、平坦区定位、Tesco 漂移诊断、路线校验研究、路线一致性规则、传感器盘点、公开基准与定位实验室。

### 编译

核心库：`cd ios/HPASSKit && swift test`；iOS App：在 `ios/HPASSApp` 运行 `xcodegen generate` 后用 Xcode 打开；
Android：`cd android && ./gradlew assembleDebug`；Python 工具：`python -m unittest discover -s tools/tests`。
合并到 `main` 会自动出签名安装包并部署后台。

### 图标

原创：定位图钉压在磁场等值线上，一串脚印（惯导推算）走向它。源文件在 `docs/assets/`，iOS 和 Android 的图标都由它导出。
