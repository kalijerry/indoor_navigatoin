# 定位云端后台（Cloudflare Worker）

App 实时发日志和定位 / 采集状态（WebSocket），采集会话和地图上传到 R2；浏览器打开就是看板：地图上看每台手机的实时位置和轨迹、滚动日志、下载会话、看评估报告。

## 部署（第一次，大约 10 分钟）

需要一个 Cloudflare 账号（免费版够用；Durable Objects 用的是 SQLite 存储，免费版可用）。

```bash
cd server/telemetry
npm install
npx wrangler login                       # 浏览器里登录 Cloudflare 授权
npx wrangler r2 bucket create hpass-data # 存会话、地图、日志、报告
npx wrangler secret put TOKEN            # 输入一个足够长的口令（App 和看板都用它）
npx wrangler deploy                      # 输出 https://hpass-telemetry.<你的子域>.workers.dev
```

## 自动部署

main 上 `server/telemetry` 有改动时，GitHub Actions「Deploy telemetry worker」自动 `wrangler deploy`（也可以在 Actions 页手动跑）。
要先在仓库 Settings → Secrets and variables → Actions 里加 `CLOUDFLARE`（API 令牌）（Cloudflare 后台 My Profile → API Tokens，「Edit Cloudflare Workers」模板）；账号不止一个时再加 `CLOUDFLARE_ACCOUNT_ID`。

**重建地图按钮 / 采集上传后自动重建**：再加一个 Actions 密钥 `MAP_BUILD_TOKEN`：GitHub → Settings → Developer settings → Fine-grained tokens → Generate，
Repository access 只选本仓库，Permissions → Actions 选 Read and write。加好后手动跑一次「Deploy telemetry worker」，它会写成 Worker secret `GH_TOKEN`。
之后 App「地图库 → 让云端重新生成当前地图」、看板「会话」页的「强制重建全部地图」都能用；建图采集传上来也会自动触发重建。

## App 里

「场地数据 → 云端后台」：填上面的地址（不带 https:// 也行）和口令，打开「连接后台」。
- 日志、定位 / 采集状态实时上去（每秒最多 2 次状态；断网时攒着，连上补发）；
- 「采集结束自动上传会话」默认开，也可以在「导出给电脑建图」里手动上传；
- 连上时自动上传当前地图（看板画地图用），切换地图会重新上传。

## 看板

浏览器打开部署地址，输入口令，点「连接」。左边设备列表，中间地图（滚轮缩放、拖动），右边日志 / 会话 / 评估 / 下载。

「下载」只放签名（Ad Hoc）安装包：GitHub Actions 的「iOS Ad Hoc (signed)」跑完自动传上来，用 iPhone 的 Safari 打开看板点「安装到 iPhone」即可（手机要先在开发者网站登记）。未签名包后台不收，只在 CI 运行的 Artifacts 里（见 `docs/sideload.md`）。

## 评估报告

建图会话和测试会话分开（App 采集页打开「这次是测试会话」），在电脑上：

```bash
cd ios/HPASSKit
swift run -c release hpass-eval --map map.json --build 会话1,会话2 --test 测试会话1 --json report.json
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @report.json \
  https://hpass-telemetry.<你的子域>.workers.dev/api/reports/$(date +%Y%m%d_%H%M).json
```

会话 zip 从看板「会话」里下载、解压就是 hpass-eval 要的目录。

## 本地调试

```bash
printf 'TOKEN=test\n' > .dev.vars
npx wrangler dev        # http://localhost:8787
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 看板 |
| GET | `/ws?role=device&device=名字&token=…` | App 连这里，发 JSON（单条或数组）：`hello` / `log` / `state` |
| GET | `/ws?role=viewer&token=…` | 看板连这里，先收 `snapshot`，之后实时收设备消息和 `online` |
| PUT/GET | `/api/sessions/<名字>.zip`、GET `/api/sessions` | 会话上传 / 下载 / 列表 |
| PUT/GET | `/api/maps/<地图编号>` | 地图 JSON |
| PUT/GET | `/api/reports/<名字>.json`、GET `/api/reports` | 评估报告 |
| GET | `/api/logs?day=YYYY-MM-DD`、`/api/logs/<key>` | 日志分块（NDJSON，每 200 条或 30 秒一块） |
| POST | `/api/rebuild` | 触发云端建图（map-build.yml），JSON `{"map_id": "...", "force": true}`，map_id 省略 = 全部；要 Worker secret `GH_TOKEN` |
| PUT/GET | `/api/config/exclude` | 云端建图不用的会话名（JSON 数组），cloud_build.py 每次合并进 EXCLUDE |
| GET | `/routes` | 建图路线页：每遍采集按拐弯切成段，拖动 / 旋转 / 删除，按磁场一致性着色（见 docs/survey-route-consistency.md） |
| PUT/GET | `/api/segments/<地图>` | 云端建图导出的路线分段和着色（cloud_build.py 传，路线页读） |
| PUT/GET | `/api/config/segments/<地图>` | 路线页手动改过的段 `{"edits":[{session,t0Ms,t1Ms,dx,dy,rotDeg,pivotX,pivotY,deleted}]}`，cloud_build.py 传给 hpass-build `--edits` |
| GET | `/api/packages` | 云端地图包列表（名字、类型、版本、大小、磁场格数、蓝牙标签数） |
| PUT/GET | `/api/packages/<地图编号>` | 地图包（App 打包：地图 + 磁场 + 蓝牙 + 视觉特征地图，zlib 压缩）；上传头 `X-Map-Name`（URL 编码）、`X-Map-Kind`、`X-Map-Version`（毫秒），比云端旧的版本返回 409 |

所有接口都要口令：`Authorization: Bearer <TOKEN>`，WebSocket 用 `?token=`。没配 TOKEN 时全部拒绝。
