"""Tiny HTTP CONNECT proxy for tests: logs each CONNECT target to stdout-adjacent file."""
import socket, sys, threading
port, log = int(sys.argv[1]), sys.argv[2]
def pipe(a, b):
    try:
        while (d := a.recv(65536)): b.sendall(d)
    except OSError: pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass
def handle(c):
    head = b""
    while b"\r\n\r\n" not in head:
        d = c.recv(4096)
        if not d: return
        head += d
    line = head.split(b"\r\n")[0].decode()
    open(log, "a").write(line + "\n")
    method, target, _ = line.split(" ", 2)
    host, p = target.rsplit(":", 1)
    up = socket.create_connection((host, int(p)))
    c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    rest = head.split(b"\r\n\r\n", 1)[1]
    if rest: up.sendall(rest)
    threading.Thread(target=pipe, args=(c, up), daemon=True).start(); pipe(up, c)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(50)
print("ready", flush=True)
while True:
    c, _ = s.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
