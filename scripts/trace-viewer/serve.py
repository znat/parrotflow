#!/usr/bin/env python3
"""The run viewer: serves the recorded runs to a page on this Mac only.

    python3 scripts/trace-viewer/serve.py [--runs DIR] [--port N] [--no-open]

Binds 127.0.0.1 on a free port and opens the browser. Read-only: GET only,
and only files under the viewer's folder and the runs folder. The runs are
written by `built-in/recipes/runlog.py`.

    /                  the page
    /api/runs          the runs, newest first
    /api/run/<id>      one run: run.json and the names of its files
    /runs/<id>/<path>  one recorded file
"""

import argparse
import http.server
import json
import mimetypes
import os
import re
import sys
import time
import urllib.parse
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
DEV_RUNS = os.path.expanduser("~/Library/Logs/ParrotFlow-Dev-runs")
RUN = re.compile(r"^\d{4}-\d{2}-\d{2}T[\w.\-]+$")
PARTS = ("calls", "steps", "trees", "shots", "looks", "grounds")


def inside(root, *parts):
    """The real path of root/parts, or None when it leaves root."""
    root = os.path.realpath(root)
    path = os.path.realpath(os.path.join(root, *parts))
    return path if path.startswith(root + os.sep) else None


def read_run(folder):
    try:
        with open(os.path.join(folder, "run.json"), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def runs(root):
    out = []
    try:
        names = sorted((n for n in os.listdir(root) if RUN.match(n)), reverse=True)
    except OSError:
        return out
    for name in names:
        folder = os.path.join(root, name)
        info = read_run(folder)
        if info is None:
            continue
        out.append({"id": name, "request": info.get("request", ""), "app": info.get("app", ""),
                    "kind": info.get("kind", ""), "end": info.get("end"),
                    "outcome": info.get("outcome", ""), "started": info.get("started"),
                    "ended": info.get("ended"), "steps": info.get("steps", 0),
                    "calls": info.get("calls", 0),
                    "age": _age(os.path.join(folder, "run.json"))})
    return out


def _age(path):
    try:
        return time.time() - os.path.getmtime(path)
    except OSError:
        return None


def run(root, name):
    folder = inside(root, name) if RUN.match(name) else None
    if folder is None or not os.path.isdir(folder):
        return None
    files = {}
    for part in PARTS:
        try:
            files[part] = sorted(n for n in os.listdir(os.path.join(folder, part))
                                 if not n.endswith(".tmp"))
        except OSError:
            files[part] = []
    return {"id": name, "run": read_run(folder), "files": files}


class Handler(http.server.BaseHTTPRequestHandler):
    root = DEV_RUNS

    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if path == "/api/runs":
            return self._json(runs(self.root))
        if path.startswith("/api/run/"):
            found = run(self.root, path[len("/api/run/"):])
            return self._json(found) if found else self.send_error(404)
        if path.startswith("/runs/"):
            parts = path[len("/runs/"):].split("/")
            if len(parts) < 2 or not RUN.match(parts[0]):
                return self.send_error(404)
            return self._file(inside(self.root, *parts))
        if path in ("", "/"):
            path = "/index.html"
        return self._file(inside(HERE, path.lstrip("/")))

    def _json(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self._send(200, "application/json; charset=utf-8", body)

    def _file(self, path):
        if path is None or not os.path.isfile(path) or os.path.basename(path) == "serve.py":
            return self.send_error(404)
        kind = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if kind.startswith("text/") or kind in ("application/javascript", "application/json"):
            kind += "; charset=utf-8"
        with open(path, "rb") as handle:
            self._send(200, kind, handle.read())

    def _send(self, status, kind, body):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", default=DEV_RUNS, help=f"the runs folder (default {DEV_RUNS})")
    parser.add_argument("--port", type=int, default=0, help="default: a free one")
    parser.add_argument("--no-open", action="store_true", help="do not open the browser")
    args = parser.parse_args()
    mimetypes.add_type("application/javascript", ".js")
    Handler.root = os.path.abspath(os.path.expanduser(args.runs))
    if not os.path.isdir(Handler.root):
        print(f"no runs folder at {Handler.root}", file=sys.stderr)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"{url}  runs from {Handler.root}", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
