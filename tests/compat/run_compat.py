#!/usr/bin/env python3
"""keydillo compatibility suite.

Runs the real proxy (kd-testproxy: same engine as the app, with a scripted approver and in-memory keys)
against a mock API, through every HTTP client we can find, and writes REPORT.md.

  python3 tests/compat/run_compat.py            # mock upstream only
  python3 tests/compat/run_compat.py --live     # also a few calls through `keydillo run` to postman-echo.com
"""
import base64, hashlib, json, os, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
PKG = os.path.join(ROOT, "Packages/VaultCore")
VENV_PY = os.path.join(HERE, ".venv/bin/python")
UP, UP2, PX = 18900, 18901, 18787
PROXY = f"http://127.0.0.1:{PX}"
RUN = tempfile.mkdtemp(prefix="kd-compat-")
DECISION = os.path.join(RUN, "decision")

SECRETS = {
    "hdr": "REAL-hdr-5e1f0a9c2b7d4e6f", "bearer": "REAL-bearer-8c3b1d2e4f5a6b7c", "basic": "sk_test_REALbasic9a8b7c6d",
    "pair": "ACrealsid12345:REALtoken6789abcd", "query": "REAL-query-1a2b3c4d5e6f7a8b", "multi": "REAL-multi-0f1e2d3c4b5a6978",
    "sub": "REAL-sub-123456:ABCDEFghijklmn", "openai": "sk-REALopenai-1234567890abcdef", "anthropic": "sk-ant-REALanthropic-12345678",
    "stripe": "sk_test_REALstripe1234567890", "rules": "REAL-rules-aabbccddeeff0011", "down": "REAL-down-0011223344556677",
}

def svc(name, header="", prefix="", **extra):
    d = {"name": name, "displayName": name.capitalize(), "project": "compat", "upstreamHost": f"127.0.0.1:{UP}", "upstreamScheme": "http",
         "authHeader": header, "authPrefix": prefix, "envVarName": name.upper() + "_API_KEY", "approval": {"eachRequest": {}}, "allowed": []}
    d.update(extra); return d

SERVICES = [
    svc("hdr", "xi-api-key"), svc("bearer", "Authorization", "Bearer "), svc("basic", "Authorization", basicAuth=True),
    svc("pair", "Authorization", basicAuth=True), svc("query", "", authQueryParam="key"),
    svc("multi", "apikey", extraHeaders={"Authorization": "Bearer {key}"}), svc("sub"),
    svc("openai", "Authorization", "Bearer "), svc("anthropic", "x-api-key"), svc("stripe", "Authorization", "Bearer "),
    svc("rules", "x-api-key", allowed=[{"method": "POST", "pattern": "/echo"}]),
    dict(svc("down", "x-api-key"), upstreamHost="127.0.0.1:18999"),
]

def ph(name): return f"keydillo:{name}"

# ---------- infrastructure ----------

procs = []
def start(cmd, ready_word="ready", env=None, log=None):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log or subprocess.DEVNULL, env=env, text=True)
    procs.append(p)
    line = p.stdout.readline()
    assert ready_word in line, f"{cmd} failed to start: {line}"
    return p

def hits(clear=False):
    with urllib.request.urlopen(f"http://127.0.0.1:{UP}/hits" + ("?clear=1" if clear else "")) as r: return json.loads(r.read())
def hits2():
    with urllib.request.urlopen(f"http://127.0.0.1:{UP2}/hits") as r: return json.loads(r.read())
def decide(d): open(DECISION, "w").write(d)
def approvals():
    try: return int(open(DECISION + ".count").read())
    except Exception: return 0

class Driver:
    def __init__(self, name, cmd, cwd=None):
        self.name = name
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=cwd)
        self.lock = threading.Lock()
    def __call__(self, method, url, headers=None, body=b"", chunked=False):
        with self.lock:
            self.p.stdin.write(json.dumps({"method": method, "url": url, "headers": headers or {}, "chunked": chunked,
                                           "body_b64": base64.b64encode(body).decode()}) + "\n"); self.p.stdin.flush()
            r = json.loads(self.p.stdout.readline())
        r["body"] = base64.b64decode(r.get("body_b64") or "")
        r["hdrs"] = {k.lower(): v for k, v in r.get("headers", [])}
        return r

def curl(method, url, headers=None, body=b"", chunked=False):
    hf = os.path.join(RUN, "h.txt"); bf = os.path.join(RUN, "b.bin"); inf = os.path.join(RUN, "in.bin")
    cmd = ["curl", "-s", "-S", "--noproxy", "*", "-X", method, "-D", hf, "-o", bf, "-w", "%{time_starttransfer} %{time_total}", url, "--max-time", "120"]
    for k, v in (headers or {}).items(): cmd += ["-H", f"{k}: {v}"]
    if chunked: cmd += ["-H", "Transfer-Encoding: chunked"]
    if body: open(inf, "wb").write(body); cmd += ["--data-binary", "@" + inf]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0: return {"status": 0, "error": p.stderr.strip(), "body": b"", "hdrs": {}}
    text = open(hf, newline="").read()
    blocks = [b for b in text.split("\r\n\r\n") if b.strip()]
    raw = blocks[-1]
    lines = raw.strip().split("\r\n"); status = int(lines[0].split()[1])
    hdrs = {}
    for l in lines[1:]:
        if ":" in l: k, v = l.split(":", 1); hdrs.setdefault(k.strip().lower(), v.strip())
    ttfb, total = map(float, p.stdout.split())
    return {"status": status, "hdrs": hdrs, "body": open(bf, "rb").read() if os.path.exists(bf) else b"", "ttfb": ttfb, "total": total}

# ---------- cases ----------

class Skip(Exception): pass
def check(cond, msg):
    if not cond: raise AssertionError(msg)
def js(r): return json.loads(r["body"] or b"{}")
def last_hit(path_part=None):
    hs = [h for h in hits() if path_part is None or path_part in h["path"]]
    check(hs, "upstream never received the request"); return hs[-1]
def no_secret(r, *names):
    for n in names: check(SECRETS[n].encode() not in r["body"], f"real {n} key leaked into the response body")
def hval(h, k): return {a.lower(): b for a, b in h["headers"].items()}.get(k.lower(), "")

def c_header(c):
    r = c("GET", f"{PROXY}/hdr/echo", {"xi-api-key": ph("hdr")}); check(r["status"] == 200, f"status {r['status']}")
    check(hval(last_hit("/echo"), "xi-api-key") == SECRETS["hdr"], "upstream didn't get the real key in xi-api-key")
    no_secret(r, "hdr"); check(b"redacted by keydillo" in r["body"], "echoed key wasn't scrubbed")
def c_bearer(c):
    r = c("GET", f"{PROXY}/bearer/echo"); check(r["status"] == 200, f"status {r['status']}")
    check(hval(last_hit("/echo"), "Authorization") == "Bearer " + SECRETS["bearer"], "wrong Authorization upstream"); no_secret(r, "bearer")
def c_basic(c):
    r = c("GET", f"{PROXY}/basic/echo"); check(r["status"] == 200, f"status {r['status']}")
    exp = "Basic " + base64.b64encode((SECRETS["basic"] + ":").encode()).decode()
    check(hval(last_hit("/echo"), "Authorization") == exp, "wrong Basic header")
def c_basic_pair(c):
    r = c("GET", f"{PROXY}/pair/echo"); check(r["status"] == 200, f"status {r['status']}")
    exp = "Basic " + base64.b64encode(SECRETS["pair"].encode()).decode()
    check(hval(last_hit("/echo"), "Authorization") == exp, "wrong user:password Basic header")
def c_query(c):
    r = c("GET", f"{PROXY}/query/echo?model=x&key={ph('query')}"); check(r["status"] == 200, f"status {r['status']}")
    h = last_hit("/echo"); check(f"key={SECRETS['query']}" in h["path"] and "model=x" in h["path"], f"upstream query wrong: {h['path']}")
    no_secret(r, "query")
def c_multi(c):
    r = c("GET", f"{PROXY}/multi/echo"); check(r["status"] == 200, f"status {r['status']}")
    h = last_hit("/echo"); check(hval(h, "apikey") == SECRETS["multi"] and hval(h, "Authorization") == "Bearer " + SECRETS["multi"], "both headers not set")
def c_path(c):
    r = c("GET", f"{PROXY}/sub/bot{ph('sub')}/echo"); check(r["status"] == 200, f"status {r['status']}")
    check(f"/bot{SECRETS['sub']}/echo" in last_hit("/echo")["path"], "key not placed in URL path"); no_secret(r, "sub")
def c_json_body(c):
    b = json.dumps({"client_id": "abc", "client_secret": ph("sub"), "grant_type": "client_credentials"}).encode()
    r = c("POST", f"{PROXY}/sub/echo", {"Content-Type": "application/json"}, b); check(r["status"] == 200, f"status {r['status']}")
    check(json.loads(last_hit("/echo")["body"])["client_secret"] == SECRETS["sub"], "JSON body placeholder not replaced")
    no_secret(r, "sub")
def c_form_body(c):
    b = f"client_id=abc&client_secret={ph('sub')}".encode()
    r = c("POST", f"{PROXY}/sub/echo", {"Content-Type": "application/x-www-form-urlencoded"}, b); check(r["status"] == 200, f"status {r['status']}")
    check(SECRETS["sub"] in last_hit("/echo")["body"], "form body placeholder not replaced")
def c_cookie(c):
    r = c("GET", f"{PROXY}/sub/echo", {"Cookie": f"session=abc; token={ph('sub')}"}); check(r["status"] == 200, f"status {r['status']}")
    check(f"token={SECRETS['sub']}" in hval(last_hit("/echo"), "Cookie"), "cookie placeholder not replaced")
def c_agent_header_replaced(c):
    r = c("GET", f"{PROXY}/hdr/echo", {"xi-api-key": "sk-someone-elses-key"}); check(r["status"] == 200, f"status {r['status']}")
    check(hval(last_hit("/echo"), "xi-api-key") == SECRETS["hdr"], "agent-supplied key was forwarded")
def c_methods(c):
    for m in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]:
        r = c(m, f"{PROXY}/bearer/echo", {"Content-Type": "application/json"}, b'{"a":1}' if m in ("POST", "PUT", "PATCH") else b"")
        check(r["status"] == 200 and js(r)["method"] == m, f"{m} -> {r['status']}")
    r = c("HEAD", f"{PROXY}/bearer/echo"); check(r["status"] == 200 and not r["body"], f"HEAD -> {r['status']}")
def c_json_roundtrip(c):
    body = json.dumps({"text": "héllo ✓ 日本", "n": [1, 2, 3]}).encode()
    r = c("POST", f"{PROXY}/bearer/echo", {"Content-Type": "application/json; charset=utf-8"}, body)
    check(js(r)["body_sha256"] == hashlib.sha256(body).hexdigest(), "request body changed in transit")
def c_multipart(c):
    data = os.urandom(3 * 1024 * 1024); bnd = "kdbound123"
    body = (f"--{bnd}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--{bnd}\r\n"
            f"Content-Disposition: form-data; name=\"file\"; filename=\"a.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n").encode() + data + f"\r\n--{bnd}--\r\n".encode()
    r = c("POST", f"{PROXY}/bearer/echo", {"Content-Type": f"multipart/form-data; boundary={bnd}"}, body)
    check(r["status"] == 200 and js(r)["body_sha256"] == hashlib.sha256(body).hexdigest(), "multipart upload altered")
def c_large_body(c):
    body = os.urandom(20 * 1024 * 1024)
    r = c("POST", f"{PROXY}/bearer/echo", {"Content-Type": "application/octet-stream"}, body)
    check(r["status"] == 200 and js(r)["body_sha256"] == hashlib.sha256(body).hexdigest(), f"20 MB upload altered ({r['status']})")
def c_chunked_upload(c):
    body = os.urandom(1024 * 1024)
    r = c("POST", f"{PROXY}/bearer/echo", {"Content-Type": "application/octet-stream"}, body, chunked=True)
    check(r["status"] == 200 and js(r)["body_sha256"] == hashlib.sha256(body).hexdigest(), f"chunked upload altered ({r['status']})")
def c_download(c):
    n = 10 * 1024 * 1024
    r = c("GET", f"{PROXY}/bearer/download?n={n}")
    exp = hashlib.sha256(urllib.request.urlopen(f"http://127.0.0.1:{UP}/download?n={n}").read()).hexdigest()
    check(r["status"] == 200 and hashlib.sha256(r["body"]).hexdigest() == exp, "binary download not byte-for-byte")
def c_gzip(c):
    r = c("GET", f"{PROXY}/bearer/gzip", {"Accept-Encoding": "gzip"})
    check(r["status"] == 200 and js(r).get("ok") is True, "gzip response not readable")
def c_sse(c):
    r = c("GET", f"{PROXY}/bearer/sse?n=6&delay=0.4", {"Accept": "text/event-stream"})
    check(r["status"] == 200 and r["body"].count(b"data:") == 6, "events missing")
    if r.get("ttfb") is None: raise Skip("client doesn't report time to first byte")
    check(r["ttfb"] < r["total"] - 1.0, f"not streamed: first byte at {r['ttfb']:.2f}s of {r['total']:.2f}s")
def c_slow(c):
    r = c("GET", f"{PROXY}/bearer/slow?s=20"); check(r["status"] == 200, f"20 s request -> {r['status']} {r.get('error')}")
def c_redirect(c):
    urllib.request.urlopen(f"http://127.0.0.1:{UP2}/hits?clear=1").read()
    r = c("GET", f"{PROXY}/bearer/redirect")
    check(r["status"] == 302 and "location" in r["hdrs"], f"redirect not passed back ({r['status']})")
    check(not any(SECRETS["bearer"] in json.dumps(h) for h in hits2()), "key was sent to the redirect target")
def c_status(c):
    for code in (400, 404, 429, 500, 503):
        r = c("GET", f"{PROXY}/bearer/status?code={code}")
        check(r["status"] == code, f"{code} became {r['status']}")
        check(r["hdrs"].get("retry-after") == "7" and r["hdrs"].get("x-request-id") == "req_123", f"{code}: headers dropped")
        check(js(r)["error"]["code"] == code, f"{code}: body changed")
def c_401_note(c):
    r = c("GET", f"{PROXY}/bearer/status?code=401")
    check(r["status"] == 401 and "rotate" in r["hdrs"].get("x-keydillo-note", ""), "401 not explained to the agent")
def c_cookies(c):
    r = c("GET", f"{PROXY}/bearer/cookies"); check(r["status"] == 200, f"status {r['status']}")
    check("set-cookie" in r["hdrs"], "Set-Cookie dropped")
def c_idempotency(c):
    c("POST", f"{PROXY}/bearer/echo", {"Idempotency-Key": "idem-42", "Content-Type": "application/json"}, b"{}")
    check(hval(last_hit("/echo"), "Idempotency-Key") == "idem-42", "Idempotency-Key not forwarded")
def c_parallel(c):
    decide("approve"); time.sleep(3.2); before = approvals()
    with ThreadPoolExecutor(20) as ex: rs = list(ex.map(lambda i: curl("GET", f"{PROXY}/hdr/echo?i={i}"), range(20)))
    check(all(r["status"] == 200 for r in rs), f"{sum(r['status'] != 200 for r in rs)} of 20 parallel calls failed")
    n = approvals() - before; check(n <= 2, f"{n} Touch ID prompts for one burst of 20 calls")
def c_denied(c):
    time.sleep(3.2); decide("deny")
    try:
        r = c("GET", f"{PROXY}/hdr/echo"); check(r["status"] == 403 and js(r)["code"] == "denied", f"{r['status']} {r['body'][:80]}")
    finally: decide("approve")
def c_locked(c):
    time.sleep(3.2); decide("locked")
    try:
        r = c("GET", f"{PROXY}/hdr/echo"); check(r["status"] == 423 and js(r)["code"] == "approval_unavailable", f"{r['status']}")
    finally: decide("approve")
def c_unknown(c):
    r = c("GET", f"{PROXY}/nope/echo"); check(r["status"] == 404 and js(r)["code"] == "unknown_service" and "request_secret" in js(r)["hint"], "unclear error")
def c_rules(c):
    r = c("GET", f"{PROXY}/rules/echo"); check(r["status"] == 403 and js(r)["code"] == "path_not_allowed", f"{r['status']}")
def c_upstream_down(c):
    r = c("GET", f"{PROXY}/down/echo"); check(r["status"] == 502 and js(r)["code"] == "upstream_failed", f"{r['status']}")
def c_browser_origin(c):
    r = c("POST", f"{PROXY}/hdr/echo", {"Origin": "https://evil.example", "Content-Type": "text/plain"}, b"x")
    check(r["status"] == 403 and js(r)["code"] == "browser_blocked", f"web page request allowed ({r['status']})")
def c_rebinding(c):
    r = curl("GET", f"{PROXY}/hdr/echo", {"Host": "attacker.example:7787"})
    check(r["status"] == 403, f"DNS-rebinding Host allowed ({r['status']})")
def c_ipv6(c):
    r = curl("GET", f"http://[::1]:{PX}/hdr/echo"); check(r["status"] == 200, f"::1 -> {r['status']} {r.get('error')}")
def c_localhost_name(c):
    r = c("GET", f"http://localhost:{PX}/hdr/echo"); check(r["status"] == 200, f"localhost -> {r['status']} {r.get('error')}")

GENERIC = [
    ("Auth: custom header (xi-api-key)", c_header), ("Auth: Bearer", c_bearer), ("Auth: Basic, key as user (Stripe)", c_basic),
    ("Auth: Basic user:password (Twilio)", c_basic_pair), ("Auth: query parameter (?key=)", c_query),
    ("Auth: two headers (Supabase)", c_multi), ("Auth: key in URL path (Telegram)", c_path), ("Auth: key in JSON body (OAuth)", c_json_body),
    ("Auth: key in form body", c_form_body), ("Auth: key in cookie", c_cookie), ("Agent-supplied key is replaced", c_agent_header_replaced),
    ("All HTTP methods incl. HEAD/OPTIONS", c_methods), ("JSON with Unicode, byte-exact", c_json_roundtrip), ("Multipart upload 3 MB", c_multipart),
    ("20 MB request body", c_large_body), ("Chunked (streamed) upload", c_chunked_upload), ("10 MB binary download, byte-exact", c_download),
    ("gzip response", c_gzip), ("SSE streaming arrives live", c_sse), ("20 s slow request", c_slow), ("Redirect returned, key not forwarded", c_redirect),
    ("Upstream 4xx/5xx passed through", c_status), ("401 explained to the agent", c_401_note), ("Set-Cookie passed through", c_cookies),
    ("Idempotency-Key forwarded", c_idempotency), ("localhost resolves (IPv4/IPv6)", c_localhost_name),
]
ONCE = [
    ("20 parallel calls share one Touch ID", c_parallel), ("Denied → clear 403", c_denied), ("Mac locked → clear 423", c_locked),
    ("Unknown key → hint to request_secret", c_unknown), ("Path rule blocks", c_rules), ("Upstream down → 502", c_upstream_down),
    ("Web page (Origin) blocked", c_browser_origin), ("DNS rebinding Host blocked", c_rebinding), ("IPv6 [::1] works", c_ipv6),
]

# ---------- SDKs ----------

NODE_SDK = r"""
const which = process.argv[2]; const base = process.argv[3];
try {
  if (which === "openai") { const { default: OpenAI } = await import("openai");
    const o = new OpenAI({ apiKey: "keydillo:openai", baseURL: base + "/openai/v1" });
    const r = await o.chat.completions.create({ model: "m", messages: [{ role: "user", content: "hi" }] });
    let s = ""; for await (const ch of await o.chat.completions.create({ model: "m", messages: [], stream: true })) s += ch.choices[0]?.delta?.content || "";
    console.log(JSON.stringify({ ok: r.choices[0].message.content === "Hello" && s === "Hello" }));
  } else if (which === "anthropic") { const { default: A } = await import("@anthropic-ai/sdk");
    const a = new A({ apiKey: "keydillo:anthropic", baseURL: base + "/anthropic" });
    const r = await a.messages.create({ model: "m", max_tokens: 5, messages: [{ role: "user", content: "hi" }] });
    let s = ""; const st = await a.messages.create({ model: "m", max_tokens: 5, messages: [{ role: "user", content: "hi" }], stream: true });
    for await (const e of st) if (e.type === "content_block_delta") s += e.delta.text;
    console.log(JSON.stringify({ ok: r.content[0].text === "Hello" && s === "Hello" }));
  } else if (which === "stripe") { const { default: Stripe } = await import("stripe");
    // Stripe's SDK can't add a path prefix, so point it at a per-service port-less host via a custom HTTP client.
    const u = new URL(base);
    const http = await import("node:http");
    const agent = new http.Agent();
    const client = Stripe.createNodeHttpClient(agent);
    const orig = client.makeRequest.bind(client);
    client.makeRequest = (host, port, path, ...rest) => orig(u.hostname, u.port, "/stripe" + path, ...rest);
    const s = new Stripe("keydillo:stripe", { httpClient: client, host: u.hostname, port: u.port, protocol: "http" });
    const r = await s.customers.list(); console.log(JSON.stringify({ ok: r.object === "list" }));
  } else if (which === "ws") { const { default: WebSocket } = await import("ws");
    const ws = new WebSocket(base.replace("http", "ws") + "/hdr/ws");
    ws.on("open", () => ws.send("ping")); ws.on("message", (m) => { const j = JSON.parse(m); console.log(JSON.stringify({ ok: j.echo === "ping", auth: j.auth })); ws.close(); });
    ws.on("error", (e) => console.log(JSON.stringify({ ok: false, error: e.message })));
  }
} catch (e) { console.log(JSON.stringify({ ok: false, error: e.message })); }
"""
PY_SDK = r"""
import json, sys, asyncio
which, base = sys.argv[1], sys.argv[2]
try:
    if which == "openai":
        from openai import OpenAI
        o = OpenAI(api_key="keydillo:openai", base_url=base + "/openai/v1")
        r = o.chat.completions.create(model="m", messages=[{"role": "user", "content": "hi"}])
        s = "".join(ch.choices[0].delta.content or "" for ch in o.chat.completions.create(model="m", messages=[], stream=True))
        print(json.dumps({"ok": r.choices[0].message.content == "Hello" and s == "Hello"}))
    elif which == "anthropic":
        import anthropic
        a = anthropic.Anthropic(api_key="keydillo:anthropic", base_url=base + "/anthropic")
        r = a.messages.create(model="m", max_tokens=5, messages=[{"role": "user", "content": "hi"}])
        with a.messages.stream(model="m", max_tokens=5, messages=[{"role": "user", "content": "hi"}]) as st: s = "".join(st.text_stream)
        print(json.dumps({"ok": r.content[0].text == "Hello" and s == "Hello"}))
    elif which == "ws":
        import websockets
        async def go():
            async with websockets.connect(base.replace("http", "ws") + "/hdr/ws") as w:
                await w.send("ping"); j = json.loads(await w.recv()); return {"ok": j["echo"] == "ping", "auth": j["auth"]}
        print(json.dumps(asyncio.run(go())))
except Exception as e:
    print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}))
"""

def sdk_cases():
    res = []
    nf = os.path.join(HERE, "node", "sdk.mjs"); open(nf, "w").write(NODE_SDK)
    pf = os.path.join(RUN, "sdk.py"); open(pf, "w").write(PY_SDK)
    marker = {"openai": "/chat/completions", "anthropic": "/v1/messages", "stripe": "/customers"}
    out = []
    def record(name, raw, which):
        try:
            j = json.loads(raw.splitlines()[-1])
            ok = j.get("ok") and (which != "ws" or j.get("auth") == SECRETS["hdr"])
            hit_ok = True
            if which in marker:
                hs = [x for x in hits() if marker[which] in x["path"]]
                hit_ok = bool(hs) and SECRETS[which] in json.dumps(hs[-1]["headers"])
            out.append((name, "pass" if ok and hit_ok else "fail", j.get("error") or ("" if hit_ok else "real key not received upstream")))
        except Exception:
            out.append((name, "fail", raw[:200]))
    for which in ["openai", "anthropic", "stripe", "ws"]:
        hits(clear=True)
        p = subprocess.run(["node", nf, which, PROXY], capture_output=True, text=True, cwd=os.path.join(HERE, "node"), timeout=60)
        record(f"Node SDK: {which}", p.stdout.strip() or p.stderr.strip()[-200:], which)
    for which in ["openai", "anthropic", "ws"]:
        hits(clear=True)
        p = subprocess.run([VENV_PY, pf, which, PROXY], capture_output=True, text=True, timeout=60)
        record(f"Python SDK: {which}", p.stdout.strip() or p.stderr.strip()[-200:], which)
    return out

# ---------- main ----------

def main():
    live = "--live" in sys.argv
    print("Building test proxy…", flush=True)
    subprocess.run(["swift", "build", "-c", "release", "--product", "kd-testproxy"], cwd=PKG, check=True, capture_output=True)
    binp = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=PKG, capture_output=True, text=True).stdout.strip()
    decide("approve")
    cfg = os.path.join(RUN, "cfg.json")
    json.dump({"port": PX, "services": SERVICES, "secrets": SECRETS, "decisionFile": DECISION}, open(cfg, "w"))
    start([sys.executable, "-I", os.path.join(HERE, "mock_upstream.py"), str(UP2)])
    start([sys.executable, "-I", os.path.join(HERE, "mock_upstream.py"), str(UP), str(UP2)])
    start([os.path.join(binp, "kd-testproxy"), cfg], log=open(os.path.join(RUN, "proxy.log"), "w"))

    clients = {"curl": curl, "python urllib": Driver("urllib", [sys.executable, "-I", os.path.join(HERE, "drivers/py_driver.py"), "urllib"])}
    if os.path.exists(VENV_PY):
        for lib in ["requests", "httpx", "aiohttp"]:
            clients[f"python {lib}"] = Driver(lib, [VENV_PY, os.path.join(HERE, "drivers/py_driver.py"), lib])
    if shutil.which("node"):
        for lib in ["fetch", "undici", "axios"]:
            clients[f"node {lib}"] = Driver(lib, ["node", "driver.mjs", lib], cwd=os.path.join(HERE, "node"))

    results = {}
    for cname, c in clients.items():
        for name, fn in GENERIC:
            try: fn(c); results[(name, cname)] = ("pass", "")
            except Skip as e: results[(name, cname)] = ("skip", str(e))
            except Exception as e: results[(name, cname)] = ("fail", str(e)[:160])
            print(f"{results[(name, cname)][0]:4}  {cname:16} {name}", flush=True)
    once = []
    for name, fn in ONCE:
        try: fn(curl); once.append((name, "pass", ""))
        except Exception as e: once.append((name, "fail", str(e)[:160]))
        print(f"{once[-1][1]:4}  {'curl':16} {name}", flush=True)
    sdks = sdk_cases()
    for s in sdks: print(f"{s[1]:4}  sdk              {s[0]} {s[2]}", flush=True)

    live_rows = []
    if live:
        kd = os.path.join(ROOT, "App/build/Build/Products/Release/keydillo.app/Contents/Resources/bin/keydillo")
        env = dict(os.environ, KEYDILLO_TEST_APP_PORT=str(PX),
                   KEYDILLO_TEST_SERVICES=json.dumps([{"name": "hdr", "displayName": "Hdr", "project": "c", "host": "postman-echo.com",
                                                       "baseURL": "x", "envVarName": "E", "baseURLEnvName": "B"}]))
        for label, cmd in [("keydillo run + curl", ["curl", "-s", "https://postman-echo.com/get", "-H", "xi-api-key: keydillo:hdr"]),
                           ("keydillo run + python requests", [VENV_PY, "-c", "import requests;print(requests.get('https://postman-echo.com/get',headers={'xi-api-key':'keydillo:hdr'}).text)"]),
                           ("keydillo run + node fetch (Node 22)", ["node", "-e", "fetch('https://postman-echo.com/get',{headers:{'xi-api-key':'keydillo:hdr'}}).then(r=>r.text()).then(console.log)"])]:
            p = subprocess.run([kd, "run", "--"] + cmd, capture_output=True, text=True, env=env, timeout=90)
            ok = "/hdr/get" in p.stdout or "redacted by keydillo" in p.stdout
            live_rows.append((label, "pass" if ok else "fail", "" if ok else (p.stdout + p.stderr)[:160].replace("\n", " ")))
            print(f"{live_rows[-1][1]:4}  live             {label}", flush=True)

    write_report(clients, results, once, sdks, live_rows)
    for p in procs: p.kill()

def write_report(clients, results, once, sdks, live_rows):
    sym = {"pass": "✅", "fail": "❌", "skip": "➖"}
    names = list(clients)
    lines = ["# keydillo compatibility report", "", f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `tests/compat/run_compat.py`.",
             "Real proxy engine (test build with a scripted approver), mock API on localhost.", "",
             "## Request and auth types × clients", "", "| Case | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for name, _ in GENERIC:
        lines.append(f"| {name} | " + " | ".join(sym[results[(name, c)][0]] for c in names) + " |")
    fails = [(n, c, d) for (n, c), (s, d) in results.items() if s != "pass"]
    if fails:
        lines += ["", "Details:", ""] + [f"- **{n}** with {c}: {d}" for n, c, d in fails]
    lines += ["", "## Failure modes and safety (curl)", "", "| Case | Result | Detail |", "|---|---|---|"]
    lines += [f"| {n} | {sym[s]} | {d} |" for n, s, d in once]
    lines += ["", "## Official SDKs", "", "| SDK | Result | Detail |", "|---|---|---|"] + [f"| {n} | {sym[s]} | {d} |" for n, s, d in sdks]
    if live_rows:
        lines += ["", "## `keydillo run` (live, postman-echo.com)", "", "| Case | Result | Detail |", "|---|---|---|"] + [f"| {n} | {sym[s]} | {d} |" for n, s, d in live_rows]
    open(os.path.join(HERE, "REPORT.md"), "w").write("\n".join(lines) + "\n")
    print("\nWrote", os.path.join(HERE, "REPORT.md"))

if __name__ == "__main__":
    try: main()
    finally:
        for p in procs: p.kill()
