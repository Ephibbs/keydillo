"""Line-based HTTP driver: reads JSON requests on stdin, prints JSON responses. Usage: py_driver.py <urllib|requests|httpx|aiohttp>"""
import base64, json, sys, time
lib = sys.argv[1]

def out(status, headers, body, ttfb, total, error=None):
    print(json.dumps({"status": status, "headers": headers, "body_b64": base64.b64encode(body or b"").decode(),
                      "ttfb": ttfb, "total": total, "error": error}), flush=True)

def chunked_gen(data):
    for i in range(0, len(data), 65536): yield data[i:i + 65536]

def run(r):
    body = base64.b64decode(r.get("body_b64") or "") or None
    t0 = time.time(); ttfb = None
    if lib == "urllib":
        import urllib.request, urllib.error
        req = urllib.request.Request(r["url"], data=body, method=r["method"], headers=r.get("headers", {}))
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k): return None
        opener = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))
        try: resp = opener.open(req, timeout=120)
        except urllib.error.HTTPError as e: resp = e
        chunks = []
        while True:
            c = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
            if not c: break
            if ttfb is None: ttfb = time.time() - t0
            chunks.append(c)
        return out(resp.status if hasattr(resp, "status") else resp.code, [[k, v] for k, v in resp.headers.items()], b"".join(chunks), ttfb, time.time() - t0)
    if lib == "requests":
        import requests
        data = chunked_gen(body) if (body and r.get("chunked")) else body
        resp = requests.request(r["method"], r["url"], headers=r.get("headers", {}), data=data, stream=True, allow_redirects=False, timeout=120,
                                proxies={"http": None, "https": None})
        chunks = []
        for c in resp.raw.stream(65536, decode_content=True):
            if ttfb is None: ttfb = time.time() - t0
            chunks.append(c)
        return out(resp.status_code, [[k, v] for k, v in resp.raw.headers.items()], b"".join(chunks), ttfb, time.time() - t0)
    if lib == "httpx":
        import httpx
        with httpx.Client(timeout=120, follow_redirects=False, trust_env=False) as c:
            content = chunked_gen(body) if (body and r.get("chunked")) else body
            with c.stream(r["method"], r["url"], headers=r.get("headers", {}), content=content) as resp:
                chunks = []
                for ch in resp.iter_bytes():
                    if ttfb is None: ttfb = time.time() - t0
                    chunks.append(ch)
                return out(resp.status_code, [[k, v] for k, v in resp.headers.multi_items()], b"".join(chunks), ttfb, time.time() - t0)
    if lib == "aiohttp":
        import asyncio, aiohttp
        async def go():
            nonlocal ttfb
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as s:
                async with s.request(r["method"], r["url"], headers=r.get("headers", {}), data=body, allow_redirects=False) as resp:
                    chunks = []
                    async for ch in resp.content.iter_any():
                        if ttfb is None: ttfb = time.time() - t0
                        chunks.append(ch)
                    return out(resp.status, [[k, v] for k, v in resp.headers.items()], b"".join(chunks), ttfb, time.time() - t0)
        return asyncio.run(go())

for line in sys.stdin:
    try: run(json.loads(line))
    except Exception as e: out(0, [], b"", None, 0, f"{type(e).__name__}: {e}")
