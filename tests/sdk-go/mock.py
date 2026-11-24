import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], 'a').write(self.path + '\n')
        b = json.dumps({"data": [], "object": "list", "has_more": False, "first_id": None, "last_id": None}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
