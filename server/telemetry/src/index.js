// 地磁定位云端后台（Cloudflare Worker）。
//
// - GET  /                       网页看板（打开后输入口令）
// - GET  /ws?role=device|viewer  WebSocket：App 发日志 / 状态，看板实时接收（转给 Durable Object「Hub」）
// - PUT  /api/sessions/<名字>.zip  上传采集会话（R2：sessions/）
// - GET  /api/sessions           会话列表；GET /api/sessions/<名字>.zip 下载
// - PUT  /api/maps/<id>          上传地图 JSON（看板画地图用）；GET /api/maps/<id>
// - PUT  /api/reports/<名字>.json 上传评估报告（hpass-eval 的 --json）；GET /api/reports 列表
// - GET  /routes                 建图路线分段编辑页（拖动 / 旋转 / 删除每段，按磁场一致性着色）
// - GET|PUT /api/segments/<地图>  云端建图导出的路线分段（cloud_build.py 传）
// - GET|PUT /api/config/segments/<地图>  看板上手动改过的段（cloud_build.py 读，传给 hpass-build --edits）
// - GET  /api/logs?day=YYYY-MM-DD 某天的日志分块列表；GET /api/logs/<key> 取一块
// - PUT  /api/builds/<名字>.ipa   CI 上传签名（Ad Hoc）安装包，未签名的拒收；GET /api/builds 列表（只列签名包）；GET /api/builds/<名字> 下载
// - GET  /ota/<签名>/<名字>.plist|.ipa  签名的 Ad Hoc 包给 iPhone 直接安装（itms-services 不能带口令，用 HMAC 签名的
//                                    不可猜链接代替；签名只在登录后的 /api/builds 列表里给出）
//
// 鉴权：所有接口都要口令（secret TOKEN），放在 Authorization: Bearer … 或 ?token=…（WebSocket 用后者）。

import { Hub } from "./hub.js";
import DASHBOARD from "./dashboard.html";
import ROUTES from "./routes.html";

export { Hub };

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8" } });

function authorized(request, env, url) {
  if (!env.TOKEN) return false; // 没配口令就全部拒绝，防止裸奔
  const h = request.headers.get("authorization") || "";
  const t = h.startsWith("Bearer ") ? h.slice(7) : url.searchParams.get("token");
  if (!t || t.length !== env.TOKEN.length) return false;
  // 定长比较
  let diff = 0;
  for (let i = 0; i < t.length; i++) diff |= t.charCodeAt(i) ^ env.TOKEN.charCodeAt(i);
  return diff === 0;
}

const safeName = (s) => /^[A-Za-z0-9._\-]{1,120}$/.test(s);

// 安装链接的签名：HMAC-SHA256(口令, 包名) 前 32 位十六进制
async function otaSig(env, name) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.TOKEN), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode("ota:" + name)));
  return [...mac].slice(0, 16).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const xmlEsc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" }[c]));

async function listPrefix(env, prefix, limit = 500) {
  const out = [];
  let cursor;
  do {
    const r = await env.DATA.list({ prefix, cursor, limit: 1000 });
    for (const o of r.objects) out.push({ key: o.key, size: o.size, uploaded: o.uploaded });
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor && out.length < limit);
  return out.sort((a, b) => (a.uploaded < b.uploaded ? 1 : -1));
}

/// 让 GitHub Actions 跑云端建图（map-build.yml）。要 Worker secret GH_TOKEN（细粒度令牌，本仓库 Actions 读写），
/// 由部署工作流从 Actions 密钥 MAP_BUILD_TOKEN 写进来。没配返回 null。
async function dispatchMapBuild(env, inputs) {
  if (!env.GH_TOKEN) return null;
  const repo = env.GH_REPO || "kalijerry/indoor_navigatoin";
  const r = await fetch(`https://api.github.com/repos/${repo}/actions/workflows/map-build.yml/dispatches`, {
    method: "POST",
    headers: {
      authorization: "Bearer " + env.GH_TOKEN,
      accept: "application/vnd.github+json",
      "user-agent": "hpass-telemetry",
      "content-type": "application/json",
    },
    body: JSON.stringify({ ref: "main", inputs }),
  });
  return { ok: r.status === 204, status: r.status, text: r.status === 204 ? "" : (await r.text()).slice(0, 300) };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/" || path === "/index.html") {
      return new Response(DASHBOARD, { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    if (path === "/routes" || path === "/routes.html") {
      return new Response(ROUTES, { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    // 签名的 Ad Hoc 包：iPhone 点「安装」时系统去取 manifest 和 ipa，不能带口令
    let om = path.match(/^\/ota\/([0-9a-f]{32})\/([^/]+)\.(plist|ipa)$/);
    if (om && env.TOKEN) {
      const [, sig, base, ext] = om;
      const name = base + ".ipa";
      if (!safeName(name) || sig !== (await otaSig(env, name))) return json({ error: "链接不对" }, 404);
      const o = ext === "ipa" ? await env.DATA.get("builds/" + name) : await env.DATA.head("builds/" + name);
      if (!o || (o.customMetadata || {}).signed !== "adhoc") return json({ error: "没有这个安装包" }, 404);
      if (ext === "ipa") return new Response(o.body, { headers: { "content-type": "application/octet-stream" } });
      const m = o.customMetadata;
      const ipaUrl = `${url.origin}/ota/${sig}/${base}.ipa`;
      const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${xmlEsc(ipaUrl)}</string></dict></array>
<key>metadata</key><dict>
<key>bundle-identifier</key><string>${xmlEsc(m.bundle || "")}</string>
<key>bundle-version</key><string>${xmlEsc(m.version || "0.1.0")}</string>
<key>kind</key><string>software</string>
<key>title</key><string>HPASS ${xmlEsc(m.version || "")} (${xmlEsc(m.number || "")})</string>
</dict></dict></array></dict></plist>`;
      return new Response(plist, { headers: { "content-type": "application/xml; charset=utf-8" } });
    }

    if (!authorized(request, env, url)) return json({ error: "口令不对" }, 401);

    // WebSocket → Hub（全局一个实例）
    if (path === "/ws") {
      if (request.headers.get("upgrade") !== "websocket") return json({ error: "需要 WebSocket" }, 426);
      const id = env.HUB.idFromName("main");
      return env.HUB.get(id).fetch(request);
    }

    // 会话
    if (path === "/api/sessions" && request.method === "GET") {
      return json(await listPrefix(env, "sessions/"));
    }
    let m = path.match(/^\/api\/sessions\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name)) return json({ error: "名字不合法" }, 400);
      const key = "sessions/" + name;
      if (request.method === "PUT") {
        await env.DATA.put(key, request.body, { httpMetadata: { contentType: "application/zip" } });
        const hub = env.HUB.get(env.HUB.idFromName("main"));
        await hub.fetch(new Request("https://hub/event", {
          method: "POST",
          body: JSON.stringify({ type: "event", name: "session_uploaded", session: name, t: Date.now() }),
        }));
        // 建图采集传上来就自动重建（会话没变的地图云端会跳过；同时只跑一个，排队）
        if (name.startsWith("ios_survey_") && env.GH_TOKEN) ctx.waitUntil(dispatchMapBuild(env, {}).catch(() => null));
        return json({ ok: true, key });
      }
      if (request.method === "GET") {
        const o = await env.DATA.get(key);
        if (!o) return json({ error: "没有这个会话" }, 404);
        return new Response(o.body, { headers: { "content-type": "application/zip", "content-disposition": `attachment; filename="${name}"` } });
      }
    }

    // 地图
    m = path.match(/^\/api\/maps\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "maps/" + id + ".json";
      if (request.method === "PUT") {
        await env.DATA.put(key, request.body, { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get(key);
      if (!o) return json({ error: "没有这张地图" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 云端地图包（地图 + 磁场 + 蓝牙 + 视觉特征地图，App 打包上传、别的手机拉取）
    if (path === "/api/packages" && request.method === "GET") {
      const out = [];
      let cursor;
      do {
        const r = await env.DATA.list({ prefix: "packages/", cursor, include: ["customMetadata"] });
        for (const o of r.objects) {
          const m = o.customMetadata || {};
          out.push({ id: o.key.slice("packages/".length).replace(/\.hpmp$/, ""), size: o.size, uploaded: o.uploaded,
                     name: m.name ? decodeURIComponent(m.name) : "", kind: m.kind || "", version: Number(m.version || 0),
                     fieldCells: Number(m.fieldCells || 0), bleTags: Number(m.bleTags || 0),
                     origin: m.origin || "phone", sessions: Number(m.sessions || 0) });
        }
        cursor = r.truncated ? r.cursor : undefined;
      } while (cursor);
      return json(out.sort((a, b) => b.version - a.version));
    }
    m = path.match(/^\/api\/packages\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "packages/" + id + ".hpmp";
      if (request.method === "PUT") {
        const h = (k) => request.headers.get(k) || "";
        const version = Number(h("x-map-version") || 0);
        const old = await env.DATA.head(key);
        if (old && Number(old.customMetadata?.version || 0) > version) {
          return json({ error: "云端已经有更新的版本", version: Number(old.customMetadata.version) }, 409);
        }
        await env.DATA.put(key, request.body, {
          httpMetadata: { contentType: "application/octet-stream" },
          customMetadata: { name: h("x-map-name"), kind: h("x-map-kind"), version: String(version),
                            fieldCells: h("x-field-cells"), bleTags: h("x-ble-tags"),
                            origin: h("x-map-origin") || "phone", sessions: h("x-map-sessions") },
        });
        const hub = env.HUB.get(env.HUB.idFromName("main"));
        await hub.fetch(new Request("https://hub/event", {
          method: "POST",
          body: JSON.stringify({ type: "event", name: "map_package_uploaded", session: id, t: Date.now() }),
        }));
        return json({ ok: true, id, version });
      }
      if (request.method === "GET") {
        const o = await env.DATA.get(key);
        if (!o) return json({ error: "没有这个地图包" }, 404);
        return new Response(o.body, { headers: { "content-type": "application/octet-stream",
          "x-map-version": o.customMetadata?.version || "0" } });
      }
    }

    // 标签位置表（云端融合用：标签位置当蓝牙底图）
    m = path.match(/^\/api\/esl\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name)) return json({ error: "名字不合法" }, 400);
      if (request.method === "PUT") {
        await env.DATA.put("esl/" + name, request.body, { httpMetadata: { contentType: "text/csv; charset=utf-8" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get("esl/" + name);
      if (!o) return json({ error: "没有" }, 404);
      return new Response(o.body, { headers: { "content-type": "text/csv; charset=utf-8" } });
    }

    // 安装包：只收「iOS Ad Hoc (signed)」传上来的签名包，看板「下载」里一键安装到 iPhone
    if (path === "/api/builds" && request.method === "GET") {
      const out = [];
      let cursor;
      do {
        const r = await env.DATA.list({ prefix: "builds/", cursor, include: ["customMetadata"] });
        for (const o of r.objects) {
          const m = o.customMetadata || {};
          if (m.signed !== "adhoc") continue; // 只给签名包；未签名的在 GitHub Actions 的 artifact 里
          const name = o.key.slice("builds/".length);
          const item = { name, size: o.size, uploaded: o.uploaded, sha: m.sha || "",
                         message: m.message ? decodeURIComponent(m.message) : "", run: m.run || "", signed: m.signed || "" };
          if (m.signed === "adhoc") {
            const manifest = `${url.origin}/ota/${await otaSig(env, name)}/${name.replace(/\.ipa$/, "")}.plist`;
            item.install = "itms-services://?action=download-manifest&url=" + encodeURIComponent(manifest);
            item.version = m.version || ""; item.number = m.number || "";
          }
          out.push(item);
        }
        cursor = r.truncated ? r.cursor : undefined;
      } while (cursor);
      return json(out.sort((a, b) => (a.uploaded < b.uploaded ? 1 : -1)));
    }
    m = path.match(/^\/api\/builds\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name) || !name.endsWith(".ipa")) return json({ error: "名字不合法" }, 400);
      const key = "builds/" + name;
      if (request.method === "PUT") {
        const h = (k) => request.headers.get(k) || "";
        if (h("x-build-signed") !== "adhoc") return json({ error: "只收签名（Ad Hoc）安装包" }, 400);
        await env.DATA.put(key, request.body, {
          httpMetadata: { contentType: "application/octet-stream" },
          customMetadata: { sha: h("x-build-sha"), message: h("x-build-message"), run: h("x-build-run"),
                            signed: h("x-build-signed"), bundle: h("x-bundle-id"), version: h("x-bundle-version"),
                            number: h("x-build-number") },
        });
        // 只留最近 20 个
        const all = await listPrefix(env, "builds/", 1000);
        for (const o of all.slice(20)) await env.DATA.delete(o.key);
        const hub = env.HUB.get(env.HUB.idFromName("main"));
        await hub.fetch(new Request("https://hub/event", {
          method: "POST",
          body: JSON.stringify({ type: "event", name: "build_uploaded", session: name, t: Date.now() }),
        }));
        return json({ ok: true, key });
      }
      if (request.method === "GET") {
        const o = await env.DATA.get(key);
        if (!o) return json({ error: "没有这个安装包" }, 404);
        return new Response(o.body, { headers: { "content-type": "application/octet-stream",
          "content-disposition": `attachment; filename="${name}"` } });
      }
    }

    // 强制重建地图（看板 / App 的按钮）：{"map_id": "...", "force": true}
    if (path === "/api/rebuild" && request.method === "POST") {
      let b = {};
      try { b = await request.json(); } catch (_) { b = {}; }
      const inputs = { force: b.force === false ? "false" : "true" };
      if (b.map_id) {
        if (!safeName(String(b.map_id))) return json({ error: "名字不合法" }, 400);
        inputs.map_id = String(b.map_id);
      }
      const r = await dispatchMapBuild(env, inputs);
      if (!r) return json({ error: "后台还没配 GitHub 令牌：仓库 Actions 密钥加 MAP_BUILD_TOKEN 后重新部署后台（见 server/telemetry/README.md）" }, 503);
      if (!r.ok) return json({ error: `GitHub 拒绝了（HTTP ${r.status}）：${r.text}` }, 502);
      return json({ ok: true, message: "已开始重建，大约 3～5 分钟后手机上的地图会自动更新" });
    }

    // 云端建图不用的会话（名字列表）：cloud_build.py 每次都读
    if (path === "/api/config/exclude") {
      if (request.method === "PUT") {
        let list;
        try { list = await request.json(); } catch (_) { return json({ error: "要 JSON 数组" }, 400); }
        if (!Array.isArray(list) || !list.every((x) => typeof x === "string" && safeName(x))) return json({ error: "要会话名数组" }, 400);
        await env.DATA.put("config/exclude.json", JSON.stringify(list), { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true, count: list.length });
      }
      const o = await env.DATA.get("config/exclude.json");
      return new Response(o ? o.body : "[]", { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 路线分段（云端建图导出）
    m = path.match(/^\/api\/segments\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "segments/" + id + ".json";
      if (request.method === "PUT") {
        await env.DATA.put(key, request.body, { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get(key);
      if (!o) return json({ error: "这张地图还没有分段数据（重建一次地图就有）" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/json; charset=utf-8" } });
    }
    // 手动改过的段：{"version":1,"mapId":…,"edits":[{session,t0Ms,t1Ms,dx,dy,rotDeg,pivotX,pivotY,deleted}]}
    m = path.match(/^\/api\/config\/segments\/([^/]+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      if (!safeName(id)) return json({ error: "名字不合法" }, 400);
      const key = "config/segments/" + id + ".json";
      if (request.method === "PUT") {
        let b;
        try { b = await request.json(); } catch (_) { return json({ error: "要 JSON" }, 400); }
        const num = (x) => typeof x === "number" && Number.isFinite(x);
        const ok = b && Array.isArray(b.edits) && b.edits.length <= 5000 && b.edits.every((e) => e && typeof e.session === "string" && safeName(e.session)
          && num(e.t0Ms) && num(e.t1Ms) && ["dx", "dy", "rotDeg", "pivotX", "pivotY"].every((k) => e[k] === undefined || num(e[k]))
          && (e.deleted === undefined || typeof e.deleted === "boolean"));
        if (!ok) return json({ error: "格式不对：要 {edits:[{session,t0Ms,t1Ms,dx,dy,rotDeg,pivotX,pivotY,deleted}]}" }, 400);
        const out = { version: 1, mapId: id, savedMs: Date.now(), edits: b.edits };
        await env.DATA.put(key, JSON.stringify(out), { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true, count: b.edits.length });
      }
      const o = await env.DATA.get(key);
      return new Response(o ? o.body : JSON.stringify({ version: 1, mapId: id, edits: [] }), { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 评估报告
    if (path === "/api/reports" && request.method === "GET") return json(await listPrefix(env, "reports/"));
    m = path.match(/^\/api\/reports\/([^/]+)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!safeName(name)) return json({ error: "名字不合法" }, 400);
      if (request.method === "PUT") {
        await env.DATA.put("reports/" + name, request.body, { httpMetadata: { contentType: "application/json" } });
        return json({ ok: true });
      }
      const o = await env.DATA.get("reports/" + name);
      if (!o) return json({ error: "没有" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/json; charset=utf-8" } });
    }

    // 日志分块
    if (path === "/api/logs") {
      const day = url.searchParams.get("day") || new Date().toISOString().slice(0, 10);
      return json(await listPrefix(env, "logs/" + day + "/"));
    }
    m = path.match(/^\/api\/logs\/(.+)$/);
    if (m) {
      const key = "logs/" + decodeURIComponent(m[1]);
      const o = await env.DATA.get(key);
      if (!o) return json({ error: "没有" }, 404);
      return new Response(o.body, { headers: { "content-type": "application/x-ndjson; charset=utf-8" } });
    }

    return json({ error: "没有这个接口" }, 404);
  },
};
