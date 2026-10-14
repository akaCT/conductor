#!/usr/bin/env python3
"""Fixture update host for tests/test-update.sh. Python 3.9, standard library only.

Binds 127.0.0.1 on a free port (plain http, or https with --cert and --key), writes the
port to --port-file, logs each request (request line and headers) to --log, and serves
files from --root:

  /install.sh        the file ROOT/install.sh
  /redir-same        302 to /install.sh on the same host
  /redir-path        302 to /other/install.sh on the same host (another path)
  /other/install.sh  the file ROOT/install.sh, under another path
  /redir-other       302 to the same path on the other loopback name (127.0.0.1 <-> localhost)
  /redir-http        302 to http://127.0.0.1:HTTP_PORT/install.sh (with --http-port-file)
  /big               6 MB of text
  anything else      404
"""
import argparse
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "fixture"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        pass

    def _record(self):
        lines = ["%s %s" % (self.command, self.path)]
        for key, val in self.headers.items():
            lines.append("%s: %s" % (key.lower(), val))
        with open(self.server.logfile, "a") as fh:
            fh.write("\n".join(lines) + "\n\n")

    def _redirect(self, where):
        self.send_response(302)
        self.send_header("Location", where)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._record()
        host = self.headers.get("Host", "127.0.0.1")
        port = host.rsplit(":", 1)[1] if ":" in host else ""
        scheme = "https" if self.server.tls else "http"
        if self.path in ("/install.sh", "/other/install.sh"):
            with open(os.path.join(self.server.root, "install.sh"), "rb") as fh:
                data = fh.read()
        elif self.path == "/redir-same":
            return self._redirect("/install.sh")
        elif self.path == "/redir-path":
            return self._redirect("/other/install.sh")
        elif self.path == "/redir-other":
            other = "localhost" if host.startswith("127.0.0.1") else "127.0.0.1"
            return self._redirect("%s://%s:%s/install.sh" % (scheme, other, port))
        elif self.path == "/redir-http":
            with open(self.server.http_port_file) as fh:
                hp = fh.read().strip()
            return self._redirect("http://127.0.0.1:%s/install.sh" % hp)
        elif self.path == "/big":
            data = (b"x" * 99 + b"\n") * 62915
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(ThreadingHTTPServer):
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--http-port-file", default="")
    a = ap.parse_args()
    srv = Server(("127.0.0.1", 0), Handler)
    srv.root, srv.logfile, srv.tls, srv.http_port_file = a.root, a.log, bool(a.cert), a.http_port_file
    if a.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    tmp = a.port_file + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(str(srv.server_address[1]))
    os.replace(tmp, a.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
