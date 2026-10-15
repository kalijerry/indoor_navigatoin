"""用 App Store Connect API 生成 Ad Hoc 描述文件（CI 打包用）。

每次都重新生成：自动包含开发者网站上已登记的全部 iPhone（新登记一台手机，下次打包就能装）。
需要：pip install pyjwt cryptography

环境变量：ASC_ISSUER_ID、ASC_KEY_ID、ASC_KEY_P8（.p8 全文）、BUNDLE_ID、CERT_SERIAL（发布证书序列号，十六进制）、
PROFILE_NAME（默认 "HPASS AdHoc"）。输出：描述文件路径（装进 ~/Library/MobileDevice/Provisioning Profiles）。
"""
import base64, json, os, sys, time, urllib.request, urllib.error
import jwt

API = "https://api.appstoreconnect.apple.com/v1"
NAME = os.environ.get("PROFILE_NAME", "HPASS AdHoc")


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"App Store Connect {method} {path} 出错 {e.code}：{e.read().decode()[:500]}")


def all_pages(path):
    out, url = [], path
    while url:
        r = call("GET", url)
        out += r.get("data", [])
        nxt = r.get("links", {}).get("next")
        url = nxt.replace(API, "") if nxt else None
    return out


def main():
    bundle = os.environ["BUNDLE_ID"]
    serial = os.environ["CERT_SERIAL"].upper().lstrip("0")
    ids = all_pages(f"/bundleIds?filter[identifier]={bundle}&limit=200")
    ids = [b for b in ids if b["attributes"]["identifier"] == bundle]
    if not ids:
        sys.exit(f"开发者网站上没有 App ID {bundle}：先到「标识符」里注册")
    bundle_id = ids[0]["id"]
    certs = [c for c in all_pages("/certificates?limit=200")
             if c["attributes"].get("serialNumber", "").upper().lstrip("0") == serial]
    if not certs:
        sys.exit("开发者网站上找不到这张发布证书（序列号对不上）")
    devices = [d for d in all_pages("/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=200")]
    if not devices:
        sys.exit("开发者网站上还没有登记任何 iPhone（「设备」里加 UDID）")
    print(f"App ID {bundle}，证书 {certs[0]['attributes'].get('name')}，设备 {len(devices)} 台："
          + "、".join(d["attributes"]["name"] for d in devices), file=sys.stderr)
    # 同名的旧描述文件删掉再建（设备列表变了也能包含进去）
    for p in all_pages(f"/profiles?filter[name]={urllib.request.quote(NAME)}&limit=200"):
        call("DELETE", f"/profiles/{p['id']}")
    r = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": NAME, "profileType": "IOS_APP_ADHOC"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": certs[0]["id"]}]},
            "devices": {"data": [{"type": "devices", "id": d["id"]} for d in devices]},
        }}})
    a = r["data"]["attributes"]
    d = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, a["uuid"] + ".mobileprovision")
    open(path, "wb").write(base64.b64decode(a["profileContent"]))
    print(path)


if __name__ == "__main__":
    main()
