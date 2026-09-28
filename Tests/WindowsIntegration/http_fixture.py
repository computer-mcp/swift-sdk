"""Loopback HTTP peer for native transport validation; no model or authentication."""

import argparse
import http.server
import json
import pathlib
import socketserver
import sys


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # A fixed loopback peer does not need HTTPServer's reverse hostname lookup.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 <= size <= 1_048_576:
            self.send_error(413)
            return
        body = self.rfile.read(size)
        status = 200
        if self.path.startswith("/status/"):
            status = int(self.path.removeprefix("/status/"))
        elif self.path == "/expire" and self.headers.get("MCP-Session-Id"):
            status = 404
        payload = json.dumps({
            "body": body.decode("utf-8"),
            "headers": {key.lower(): value for key, value in self.headers.items()},
        }).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if status == 200:
            self.send_header("MCP-Session-Id", "native-session")
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", type=pathlib.Path, required=True)
    args = parser.parse_args()
    print("Binding loopback HTTP peer", file=sys.stderr, flush=True)
    with LoopbackHTTPServer(("127.0.0.1", 0), Handler) as server:
        args.ready_file.write_text(
            f"http://127.0.0.1:{server.server_port}", encoding="utf-8"
        )
        print("Loopback HTTP peer ready", file=sys.stderr, flush=True)
        server.serve_forever()
