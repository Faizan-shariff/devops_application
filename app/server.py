"""Dependency-free HTTP service. Does not claim downstream AWS readiness."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.reply(200, {"service": "logikality-document-api", "status": "ok"})
        elif self.path == "/health":
            self.reply(200, {"status": "healthy"})
        else:
            self.reply(404, {"error": "not_found"})

    def reply(self, code, data):
        body = json.dumps(data, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
