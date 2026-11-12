#!/usr/bin/env python3
"""A local HTTP server the plugin fetch CLI case reaches instead of the internet.

The sandboxed UI runner can't start python3, so the UI case serves the same
routes from its own process (`PluginFetchServer` in PlayhouseUITests.swift).

Prints one JSON line, {"port": <listening port>, "closedPort": <a port nothing
listens on>}, then serves on 127.0.0.1 until its stdin closes, so it ends with
the test that started it. Routes:

  GET  /greeting  200 JSON {"message": "hello from the fixture"}, header X-Fixture: playhouse
  POST /echo      200 JSON {"method", "token" (the X-Token header), "contentType", "body"}
  GET  /missing   404 text "nothing here"
  GET  /redirect  302 to /greeting
  GET  /requests  200 JSON: every request before this one, [{"method", "path", "token", "body"}]
"""

import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []
requests_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def respond(self, status, body, content_type="application/json", headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        token = self.headers.get("X-Token")
        if self.path == "/requests":
            with requests_lock:
                return self.respond(200, json.dumps(requests))
        with requests_lock:
            requests.append({"method": method, "path": self.path, "token": token, "body": body})
        if method == "GET" and self.path == "/greeting":
            self.respond(200, json.dumps({"message": "hello from the fixture"}), headers={"X-Fixture": "playhouse"})
        elif method == "POST" and self.path == "/echo":
            self.respond(200, json.dumps({"method": method, "token": token, "contentType": self.headers.get("Content-Type"), "body": body}))
        elif method == "GET" and self.path == "/missing":
            self.respond(404, "nothing here", content_type="text/plain")
        elif method == "GET" and self.path == "/redirect":
            self.respond(302, "", content_type="text/plain", headers={"Location": "/greeting"})
        else:
            self.respond(405 if self.path in ("/greeting", "/echo", "/missing", "/redirect") else 404, "unexpected", content_type="text/plain")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


def closed_port():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"port": server.server_address[1], "closedPort": closed_port()}), flush=True)
    sys.stdin.read()
    server.shutdown()


if __name__ == "__main__":
    main()
