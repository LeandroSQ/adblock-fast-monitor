#!/usr/bin/env python3
"""Pull-through cache for downloads.openwrt.org, plus a static fixture tree.

The OpenWrt guest's apk repositories are rewritten to http://10.0.2.2:PORT/...
(QEMU user-mode NAT maps 10.0.2.2 to the host loopback). Every request path
is the upstream path, so the cache directory keeps the layout of the original
private mirror (.local-validation/openwrt-package-mirror/releases/...).

- Cached files are served as-is (immutable release content).
- Misses are fetched from https://downloads.openwrt.org once, written
  atomically, and served; with --offline they return 404 instead.
- /fixtures/<path> serves the read-only fixture directory (e.g. blocklists).
"""
import argparse
import http.server
import os
import shutil
import sys
import tempfile
import threading
import urllib.error
import urllib.request

UPSTREAM = "https://downloads.openwrt.org"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--cache", required=True)
    parser.add_argument("--fixtures")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--ready-file")
    args = parser.parse_args()
    cache_root = os.path.realpath(args.cache)
    fixtures_root = os.path.realpath(args.fixtures) if args.fixtures else None
    os.makedirs(cache_root, exist_ok=True)
    locks = {}
    locks_guard = threading.Lock()

    def lock_for(path):
        with locks_guard:
            return locks.setdefault(path, threading.Lock())

    def resolve(root, relative):
        path = os.path.realpath(os.path.join(root, relative.lstrip("/")))
        if path != root and not path.startswith(root + os.sep):
            return None
        return path

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % a))

        def send_file(self, path, head):
            size = os.path.getsize(path)
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            if not head:
                with open(path, "rb") as source:
                    shutil.copyfileobj(source, self.wfile)

        def missing(self, code=404):
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def handle_request(self, head):
            request_path = self.path.split("?", 1)[0]
            if ".." in request_path.split("/"):
                return self.missing(400)
            if request_path.startswith("/fixtures/") and fixtures_root:
                path = resolve(fixtures_root, request_path[len("/fixtures/"):])
                if path and os.path.isfile(path):
                    return self.send_file(path, head)
                return self.missing()
            path = resolve(cache_root, request_path)
            if not path or request_path.endswith("/"):
                return self.missing(400)
            with lock_for(path):
                if not os.path.isfile(path):
                    if args.offline:
                        return self.missing()
                    try:
                        with urllib.request.urlopen(UPSTREAM + request_path, timeout=60) as response:
                            os.makedirs(os.path.dirname(path), exist_ok=True)
                            fd, partial = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".partial-")
                            with os.fdopen(fd, "wb") as target:
                                shutil.copyfileobj(response, target)
                            os.chmod(partial, 0o644)
                            os.replace(partial, path)
                    except urllib.error.HTTPError as error:
                        return self.missing(error.code)
                    except OSError as error:
                        sys.stderr.write("upstream fetch failed for %s: %s\n" % (request_path, error))
                        return self.missing(502)
            return self.send_file(path, head)

        def do_GET(self):
            self.handle_request(False)

        def do_HEAD(self):
            self.handle_request(True)

    server = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    if args.ready_file:
        with open(args.ready_file, "w") as ready:
            ready.write("%d\n" % server.server_address[1])
    server.serve_forever()


if __name__ == "__main__":
    main()
