#!/usr/bin/env python3
"""Serves a feed site directory (scripts/release/sign-feed.sh --out) over HTTP
the way GitHub Pages does for this purpose: static files with
`Access-Control-Allow-Origin: *`, which LuCI's "Repository Public Keys" page
needs to fetch a key by URL from the browser.

    serve-site.py --dir SITE [--bind 127.0.0.1] [--port 0] [--ready-file FILE]

Port 0 picks a free port; it is written to --ready-file once listening. Used
by test/guest/package-luci-install.host.sh (the guest reaches it at
http://10.0.2.2:PORT) and for previewing a release site locally.
"""
import argparse
import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".adb": "application/octet-stream", ".apk": "application/octet-stream",
                      ".pem": "application/x-pem-file"}

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("serve-site: %s %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--ready-file")
    args = ap.parse_args()
    handler = functools.partial(Handler, directory=os.path.abspath(args.dir))
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler)
    if args.ready_file:
        tmp = args.ready_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d\n" % server.server_address[1])
        os.replace(tmp, args.ready_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
