"""Mock API server for keydillo compatibility tests. Records what auth arrived so tests can check placement.

Routes (all methods unless noted):
  /echo            JSON: method, path, query, headers, body_len, body_sha256, body (if < 64KB text)
  /download?n=     n deterministic bytes (application/octet-stream)
  /gzip            gzip-encoded JSON
  /sse?n=&delay=   text/event-stream, n events
  /status?code=    that status, JSON body, Retry-After + X-Request-Id headers
  /slow?s=         waits s seconds
  /redirect        302 to the second server's /echo
  /cookies         sets two cookies
  /ws              websocket echo
  /v1/chat/completions, /v1/messages, /v1/customers   SDK-shaped responses (stream supported)
  /hits            JSON list of auth seen (for redirect checks)
"""
import base64, gzip, hashlib, json, socket, sys, threading, time, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HITS = []
REDIRECT_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 0

def det_bytes(n):
    out = bytearray(); i = 0
    while len(out) < n:
        out += hashlib.sha256(str(i).encode()).digest(); i += 1
    return bytes(out[:n])

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0: self.rfile.readline(); break
                data += self.rfile.read(size); self.rfile.readline()
            return data
        return self.rfile.read(n) if n else b""

    def send(self, code, payload, ctype="application/json", extra=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or []): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)

    def handle_any(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            HITS.append({"port": self.server.server_port, "path": self.path, "headers": dict(self.headers), "body": ""})
            return self.ws()
        b = self.body()
        if u.path != "/hits":
            HITS.append({"port": self.server.server_port, "path": self.path, "headers": dict(self.headers),
                         "body": b[:4096].decode(errors="replace")})
        if u.path == "/hits":
            out = list(HITS)
            if "clear" in q: HITS.clear()
            return self.send(200, out)
        if u.path.startswith("/download"):
            n = int(q.get("n", ["1000"])[0]); return self.send(200, det_bytes(n), "application/octet-stream")
        if u.path == "/gzip":
            data = gzip.compress(json.dumps({"ok": True, "pad": "x" * 2000}).encode())
            return self.send(200, data, "application/json", [("Content-Encoding", "gzip")])
        if u.path == "/sse": return self.sse(int(q.get("n", ["5"])[0]), float(q.get("delay", ["0.3"])[0]))
        if u.path == "/status":
            code = int(q.get("code", ["500"])[0])
            return self.send(code, {"error": {"code": code, "message": "mock"}}, extra=[("Retry-After", "7"), ("X-Request-Id", "req_123")])
        if u.path == "/slow":
            time.sleep(float(q.get("s", ["5"])[0])); return self.send(200, {"slept": True})
        if u.path == "/redirect":
            self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{REDIRECT_PORT}/echo"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if u.path == "/cookies":
            self.send_response(200); self.send_header("Set-Cookie", "a=1; Path=/"); self.send_header("Set-Cookie", "b=2; Path=/")
            self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}"); return
        if u.path == "/v1/chat/completions":
            req = json.loads(b or b"{}")
            if req.get("stream"):
                chunks = [{"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": "m", "choices": [{"index": 0, "delta": {"content": w}, "finish_reason": None}]} for w in ["Hel", "lo"]]
                return self.sse_raw([f"data: {json.dumps(c)}\n\n" for c in chunks] + ["data: [DONE]\n\n"], 0.1)
            return self.send(200, {"id": "c1", "object": "chat.completion", "created": 1, "model": "m",
                                   "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hello"}, "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
        if u.path == "/v1/messages":
            req = json.loads(b or b"{}")
            if req.get("stream"):
                ev = [("message_start", {"type": "message_start", "message": {"id": "m1", "type": "message", "role": "assistant", "model": "m", "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0}}}),
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                      ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
                      ("message_stop", {"type": "message_stop"})]
                return self.sse_raw([f"event: {n}\ndata: {json.dumps(d)}\n\n" for n, d in ev], 0.05)
            return self.send(200, {"id": "m1", "type": "message", "role": "assistant", "model": "m", "content": [{"type": "text", "text": "Hello"}],
                                   "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}})
        if u.path.startswith("/v1/customers"):
            return self.send(200, {"object": "list", "data": [], "has_more": False, "url": "/v1/customers"})
        # default: echo
        text = None
        if len(b) < 65536:
            try: text = b.decode()
            except UnicodeDecodeError: text = None
        return self.send(200, {"method": self.command, "path": u.path, "query": u.query, "headers": dict(self.headers),
                               "body_len": len(b), "body_sha256": hashlib.sha256(b).hexdigest(), "body": text})

    def sse(self, n, delay):
        self.sse_raw([f"data: {json.dumps({'i': i, 't': time.time()})}\n\n" for i in range(n)], delay)

    def sse_raw(self, events, delay):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        for e in events:
            d = e.encode(); self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush(); time.sleep(delay)
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()

    def ws(self):
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept); self.end_headers(); self.wfile.flush()
        auth = self.headers.get("Authorization", "") + self.headers.get("xi-api-key", "")
        try:
            while True:
                h = self.rfile.read(2)
                if len(h) < 2: return
                op = h[0] & 0x0F; ln = h[1] & 0x7F
                if ln == 126: ln = struct.unpack(">H", self.rfile.read(2))[0]
                elif ln == 127: ln = struct.unpack(">Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if h[1] & 0x80 else b"\0\0\0\0"
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(ln)))
                if op == 8: self.wfile.write(b"\x88\x00"); return
                reply = json.dumps({"echo": data.decode(errors="replace"), "auth": auth}).encode()
                hdr = bytes([0x81]) + (bytes([len(reply)]) if len(reply) < 126 else b"\x7e" + struct.pack(">H", len(reply)))
                self.wfile.write(hdr + reply); self.wfile.flush()
        except Exception:
            return

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_any

if __name__ == "__main__":
    port = int(sys.argv[1])
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print("ready", flush=True)
    srv.serve_forever()
