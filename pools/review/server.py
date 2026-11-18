"""Serve the record review site locally and keep the verdicts on disk.

    python3 pools/review/server.py [--port 8770] [--verdicts DIR]

Serves pools/review/site (build it with build.py) at http://127.0.0.1:<port>/
and stores each compilation's verdicts and notes in <verdicts>/<slug>.json
(default pools/review/verdicts), one entry per record, written on every change.
Duplicate-pair decisions go to <verdicts>/dedup_<slug>/<pair>.json, which
import_decisions.R reads.
"""
import argparse, json, os, re, threading, webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8770)
ap.add_argument("--verdicts", default=os.path.join(here, "verdicts"))
ap.add_argument("--no-browser", action="store_true")
args = ap.parse_args()
SITE = os.path.join(here, "site")
SLUGS = {"presto2k", "presto12k"}
DEDUP_FIELDS = {"choice", "tsidA", "tsidB", "nameA", "nameB", "note", "at"}
FIELDS = {"status", "note", "TSid", "compilation", "dataSetName", "updated"}
lock = threading.Lock()
os.makedirs(args.verdicts, exist_ok=True)


def path(slug):
    return os.path.join(args.verdicts, slug + ".json")


def load(slug):
    try:
        with open(path(slug)) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=SITE, **k)

    def end_headers(self):
        # pages are rebuilt often: make the browser check for a new copy each
        # time (it still gets 304 Not Modified when nothing changed)
        if self.command == "GET" and not self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *a):
        if self.command == "POST" or (len(a) > 1 and str(a[1]) not in ("200", "304")):
            super().log_message(fmt, *a)

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store")
        self.end_headers(); self.wfile.write(b)

    def _slug(self):
        m = re.fullmatch(r"/api/reviews/([a-z0-9]+)", self.path)
        return m.group(1) if m and m.group(1) in SLUGS else None

    def _dedup(self):
        m = re.fullmatch(r"/api/dedup/([a-z0-9]+)", self.path)
        return m.group(1) if m and m.group(1) in SLUGS else None

    def do_GET(self):
        if self.path.startswith("/api/dedup/"):
            s = self._dedup()
            if not s: return self._json(404, {"error": "unknown compilation"})
            d = os.path.join(args.verdicts, "dedup_" + s); out = {}
            with lock:
                if os.path.isdir(d):
                    for f in sorted(os.listdir(d)):
                        if f.endswith(".json"):
                            with open(os.path.join(d, f)) as fh: out[f[:-5]] = json.load(fh)
            return self._json(200, out)
        if self.path.startswith("/api/"):
            s = self._slug()
            if not s: return self._json(404, {"error": "unknown compilation"})
            with lock: return self._json(200, load(s))
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/dedup/"):
            s = self._dedup()
            if not s: return self._json(404, {"error": "unknown compilation"})
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                key, dv = body["key"], body["decision"]
                assert isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_.~:@+-]{1,300}", key) and isinstance(dv, dict)
            except Exception:
                return self._json(400, {"error": "expected {key, decision}"})
            dv = {k: v for k, v in dv.items() if k in DEDUP_FIELDS}
            d = os.path.join(args.verdicts, "dedup_" + s); f = os.path.join(d, key + ".json")
            with lock:
                os.makedirs(d, exist_ok=True)
                # A pair with no choice has no decision to import.
                if dv.get("choice") in ("a", "b", "both"):
                    with open(f + ".tmp", "w") as fh: json.dump(dv, fh, indent=1, sort_keys=True)
                    os.replace(f + ".tmp", f)
                elif os.path.exists(f):
                    os.remove(f)
            return self._json(200, {"ok": True})
        s = self._slug()
        if not s: return self._json(404, {"error": "unknown compilation"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            rid, rv = body["id"], body["review"]
            assert isinstance(rid, str) and re.fullmatch(r"[A-Za-z0-9_.~:@+-]{1,300}", rid) and isinstance(rv, dict)
        except Exception:
            return self._json(400, {"error": "expected {id, review}"})
        rv = {k: v for k, v in rv.items() if k in FIELDS}
        with lock:
            v = load(s); v[rid] = rv
            tmp = path(s) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(v, f, indent=1, sort_keys=True)
            os.replace(tmp, path(s))
        return self._json(200, {"ok": True})


srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
url = f"http://127.0.0.1:{args.port}/"
print(f"Serving {SITE} at {url}; verdicts in {args.verdicts}. Ctrl-C to stop.")
if not args.no_browser: webbrowser.open(url)
try:
    srv.serve_forever()
except KeyboardInterrupt:
    pass
