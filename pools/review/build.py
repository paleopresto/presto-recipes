"""Build the local record review site, one page per compilation.

    python3 pools/review/build.py <full.json> [site_dir]

<full.json> is the output of extract.R. For each compilation this writes
<site_dir>/<slug>/index.html (the record list, land and member locations) and
<site_dir>/<slug>/data/cNNN.json (full records, CHUNK per file, in list
order), plus a landing page. Records are ordered along a short path through
their locations (nearest neighbour, then 2-opt), so that records next to each
other in the list are near each other on the map. Serve it with server.py.
"""
import csv, html, json, math, os, re, shutil, sys
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1]
site = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "site")
CHUNK = 20
MAXPTS = 1500
VERSION = "0.1.0"
COMPS = {"Presto2k": {"slug": "presto2k", "dir": "PReSto2k", "run": "40738324606"},
         "Presto12k": {"slug": "presto12k", "dir": "PReSto12k", "run": None}}

d = json.load(open(src))
tpl = open(os.path.join(here, "template.html")).read()
esc = lambda s: html.escape("" if s is None else str(s), quote=True).replace("&#x27;", "'")


def order(R):
    """A short open path through the records' locations."""
    lat = np.radians([r["lat"] for r in R]); lon = np.radians([r["lon"] for r in R])
    xyz = np.c_[np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)]
    D = np.arccos(np.clip(xyz @ xyz.T, -1, 1)) * 6371.0
    n = len(R)
    start = int(np.argmax(lat))
    path = [start]; left = np.ones(n, bool); left[start] = False
    for _ in range(n - 1):
        j = int(np.argmin(np.where(left, D[path[-1]], np.inf))); path.append(j); left[j] = False
    path = np.array(path)
    improved = True
    while improved:
        improved = False
        for i in range(n - 2):
            a, b = path[i], path[i + 1]
            c = path[i + 2:]; nx = np.r_[path[i + 3:], -1]
            # reversing path[i+1..j] swaps edges (a,b),(path[j],path[j+1]) for (a,path[j]),(b,path[j+1])
            g = D[a, b] + np.where(nx >= 0, D[c, np.maximum(nx, 0)], 0) - D[a, c] - np.where(nx >= 0, D[b, np.maximum(nx, 0)], 0)
            k = int(np.argmax(g))
            if g[k] > 1e-6:
                j = i + 2 + k; path[i + 1:j + 1] = path[i + 1:j + 1][::-1].copy(); improved = True
        for j in range(1, n - 1):  # the path's free start
            if D[path[0], path[j + 1]] < D[path[j], path[j + 1]] - 1e-6:
                path[:j + 1] = path[:j + 1][::-1].copy(); improved = True
    steps = D[path[:-1], path[1:]]
    print("   path %.0f km; step median %.0f, 90%% %.0f, max %.0f km" % (steps.sum(), np.median(steps), np.quantile(steps, .9), steps.max()))
    return [R[i] for i in path]


def alerts(r):
    a = []
    for nb in r.get("neighbors") or []:
        if nb["km"] <= 5 and nb["variable"] == r["variable"] and nb["archive"] == r["archive"]:
            a.append(["bad", "DUP", f"<b>{esc(nb['name'])}</b> ({esc(nb['TSid'])}) is also in {r['compilation']}, {nb['km']} km away, same archive and variable."])
    p = r.get("psm"); st = p and p.get("status")
    if st == "drop_direction": a.append(["bad", "LMR", "Dropped from the LMR run: no candidate season gives the interpreted sign."])
    if st == "drop_interpretation": a.append(["bad", "LMR", "Dropped from the LMR run: interpretation names no variable its PSM uses."])
    if st == "pass_reseasoned": a.append(["warn", "LMR", "Recalibrated on another season to get the interpreted sign: " + esc(p.get("detail") or "")])
    if st == "uninterpreted": a.append(["warn", "INT", "No climate interpretation; LMR calibrated it without a sign check."])
    if r["compilation"] == "Presto2k" and not p: a.append(["warn", "LMR", "Not calibrated in the LMR run (too little overlap with instrumental data, or failed calibration)."])
    if not r.get("interpretations"): a.append(["warn", "INT", "No interpretation metadata."])
    sb = r.get("selectedBy") or ""
    if "admission" in sb: a.append(["warn", "CUR", "Admitted by a curator ledger although it fails a criterion" + (": " + esc(r["fails"]) if r.get("fails") else ".")])
    if "exception" in sb: a.append(["warn", "CUR", "Kept by the data-poor exception (no other record nearby)."])
    return a


def thin(s):
    """Min and max of each bin, in time order, for series too long to plot."""
    y, v = s["year"], s["value"]
    if len(y) <= MAXPTS: return s
    keep = []
    for b in np.array_split(np.arange(len(y)), MAXPTS // 2):
        vb = [v[i] if v[i] is not None else math.nan for i in b]
        if all(math.isnan(x) for x in vb): continue
        keep += sorted({int(b[int(np.nanargmin(vb))]), int(b[int(np.nanargmax(vb))])})
    return {"year": [y[i] for i in keep], "value": [v[i] for i in keep], "thinned": len(y)}


def page_for(cn, cc, index):
    page = tpl.replace("__DATA__", json.dumps({"snapshot": d["snapshot"], "built": d["built"], "version": VERSION,
                                               "compilation": cn, "slug": cc["slug"], "records": index,
                                               "members": {cn: d["members"][cn]}}, separators=(",", ":")).replace("</", "<\\/"))
    other = [k for k in COMPS if k != cn][0]

    def sub(old, new):
        nonlocal page
        assert page.count(old) == 1, (old[:70], page.count(old))
        page = page.replace(old, new)

    sub("<title>Presto Record Review</title>", f"<title>{cn} Record Review</title>")
    sub('Presto record review <small id="snap"></small>', f'{cn} review <small id="snap"></small>')
    # one compilation per page: the compilation filter becomes a link to the other page
    sub('<select id="fc" aria-label="Compilation"><option value="">Both compilations</option><option>Presto2k</option><option>Presto12k</option></select>',
        f'<a class="chip" style="align-self:center;text-align:center;text-decoration:none" href="../{COMPS[other]["slug"]}/">{other} review</a>')
    sub("fc = $('#fc').value, ", "fc = '', ")
    sub("['#q', '#fc', '#fa', '#fs', '#fx']", "['#q', '#fa', '#fs', '#fx', '#fg']")
    # optionally only records with an inclusion criterion that is not green
    sub('<option value="curated">Has curator decisions</option></select>\n      </div>',
        '<option value="curated">Has curator decisions</option></select>\n      </div>\n'
        '      <label style="font:12px var(--f-ui);color:var(--muted);display:flex;gap:6px;align-items:center">'
        '<input type="checkbox" id="fg"> Only records not all green for inclusion</label>')
    sub("    && (!fx || (fx === 'alert' ? r._alerts.length : r._curated))",
        "    && (!fx || (fx === 'alert' ? r._alerts.length : r._curated))\n    && (!$('#fg').checked || !r.allGreen)")
    # records load from data/ in chunks
    sub("const R = D.records;", """const R = D.records;
const CH = new Map();
function loadChunk(k) {
  if (!CH.has(k)) CH.set(k, fetch(`data/c${String(k).padStart(3, '0')}.json`)
    .then(x => { if (!x.ok) throw new Error('HTTP ' + x.status); return x.json(); })
    .then(a => new Map(a.map(f => [f.compilation + '|' + f.TSid, f])))
    .catch(e => { CH.delete(k); throw e; }));
  return CH.get(k);
}""")
    sub("R.forEach(r => { r._alerts = alertsFor(r); r._curated = (r.decisions || []).length > 0 || /admission|exception/.test(r.selectedBy || ''); });",
        "R.forEach(r => { r._alerts = r.alerts || []; r._curated = !!r.curated; });")
    sub("""function show() {
  const r = view[cur];
  if (!r) { $('#main').innerHTML = '<p class="empty">No record selected.</p>'; return; }""",
        """let showTok = 0;
function show() {
  const r0 = view[cur];
  if (!r0) { $('#main').innerHTML = '<p class="empty">No record selected.</p>'; return; }
  const tok = ++showTok;
  const it = document.querySelector(`.item[data-i="${cur}"]`); if (it) it.scrollIntoView({ block: 'nearest' });
  loadChunk(r0.k).then(m => {
    if (tok !== showTok) return;
    const full = m.get(r0.compilation + '|' + r0.TSid);
    full._alerts = r0._alerts; full._curated = r0._curated;
    try { render(full); } catch (e) { $('#main').innerHTML = `<p class="empty">Could not display this record (${esc(e.message)}).</p>`; return; }
    const nx = view[cur + 1]; if (nx && nx.k !== r0.k) loadChunk(nx.k).catch(() => {});
  }).catch(e => { if (tok === showTok) $('#main').innerHTML = `<p class="empty">Could not load this record (${esc(e.message)}). Is server.py running? Move to another record and back to retry.</p>`; });
}
function render(r) {""")
    sub("${esc(r.compilation)} 0.0.1", "${esc(r.compilation)} ${esc(D.version)}")
    if cc["run"]: sub("Not calibrated in run 39104109040.", f"Not calibrated in run {cc['run']}.")
    # verdicts go to the local server, which writes them to verdicts/<slug>.json
    sub("""let reviews = {}; let db = null; let store = 'local';
try { reviews = JSON.parse(localStorage.getItem('presto-review') || '{}'); } catch (e) { reviews = {}; }
const saveLocal = () => { try { localStorage.setItem('presto-review', JSON.stringify(reviews)); } catch (e) {} };""",
        """let reviews = {}; let store = 'local';
const LS = 'presto-review-' + D.slug;
try { reviews = JSON.parse(localStorage.getItem(LS) || '{}'); } catch (e) { reviews = {}; }
const saveLocal = () => { try { localStorage.setItem(LS, JSON.stringify(reviews)); } catch (e) {} };
const SAVED = 'Saved to verdicts/' + D.slug + '.json', LOCAL = 'Not saved to the verdicts file (server not reachable); kept in this browser';
function post(id, rv) {
  return fetch('/api/reviews/' + D.slug, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, review: rv }) })
    .then(x => { if (!x.ok) throw new Error('HTTP ' + x.status); });
}""")
    sub("${store === 'db' ? 'Saved to the shared review list' : 'Saved in this browser only'}", "${store === 'server' ? SAVED : LOCAL}")
    sub("""  if (db) {
    writing = writing.then(() => db.collection('reviews').doc(id).set(next)).then(() => { if (el) el.textContent = 'Saved to the shared review list'; })
      .catch(e => { if (el) el.textContent = 'Could not save to the shared list (' + (e && e.code || 'error') + '); kept in this browser.'; });
  } else if (el) el.textContent = 'Saved in this browser only';""",
        """  writing = writing.then(() => post(id, next)).then(() => { store = 'server'; const e2 = $('#save'); if (e2) e2.textContent = SAVED; })
    .catch(() => { store = 'local'; const e2 = $('#save'); if (e2) e2.textContent = LOCAL; });""")
    a = page.index("// shared review list, when this view has it")
    b = page.index("})();\n</script>", a)
    page = page[:a] + """// verdicts already in the file; browser-only edits newer than the file are sent to it
(async () => {
  try {
    const x = await fetch('/api/reviews/' + D.slug); if (!x.ok) throw new Error();
    const srv = await x.json(); const push = [];
    for (const [k, v] of Object.entries(reviews)) if (!srv[k] || (v.updated || '') > (srv[k].updated || '')) { srv[k] = v; push.push(k); }
    reviews = srv; store = 'server'; saveLocal(); renderList();
    for (const k of push) writing = writing.then(() => post(k, reviews[k])).catch(() => { store = 'local'; });
    const r = view[cur]; if (r) document.querySelectorAll('.vbtns button').forEach(btn => btn.setAttribute('aria-pressed', String(btn.dataset.v === (reviews[docId(r)] || {}).status)));
    const el = $('#save'); if (el) el.textContent = SAVED;
  } catch (e) { /* no server: browser storage only */ }
})();
""" + page[b:]
    # maps always in light colours
    m0 = page.index("function mapSvg(r)"); m1 = page.index("let showTok", m0)
    body = page[m0:m1]
    for v, c in (("--water", "#f7f8f6"), ("--land", "#e4e2da"), ("--coast", "#c9c6bb"), ("--faint", "#8b9596"), ("--panel", "#ffffff"), ("--ink", "#1d2324")):
        body = body.replace(f"var({v})", c)
    assert "var(--" not in body
    page = page[:m0] + body + page[m1:]
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<style>body{margin:0}</style></head><body>' + page + '</body></html>')


os.makedirs(site, exist_ok=True)
for cn, cc in COMPS.items():
    sel = {row["TSid"]: row["selected_by"] for row in csv.DictReader(open(os.path.join(here, "..", "compilations", cc["dir"], VERSION.replace(".", "_"), "members.csv")))}
    R = [r for r in d["records"] if r["compilation"] == cn]
    for r in R:
        r["selectedBy"] = sel.get(r["TSid"], r.get("selectedBy"))
        # jsonlite's auto_unbox writes a one-element vector as a scalar
        for k in ("compilations", "interpretations", "publications", "decisions", "neighbors"):
            if r.get(k) is not None and not isinstance(r[k], list): r[k] = [r[k]]
        for k in ("year", "value"):
            if not isinstance(r["series"][k], list): r["series"][k] = [r["series"][k]]
    print(f"{cn}: {len(R)} records")
    R = order(R)
    out = os.path.join(site, cc["slug"]); shutil.rmtree(out, ignore_errors=True); os.makedirs(os.path.join(out, "data"))
    index = []
    for k0 in range(0, len(R), CHUNK):
        chunk = R[k0:k0 + CHUNK]
        for r in chunk:
            r["series"] = thin(r["series"])
            index.append({"compilation": cn, "TSid": r["TSid"], "dataSetName": r["dataSetName"], "siteName": r.get("siteName"),
                          "variable": r["variable"], "proxy": r.get("proxy"), "archive": r["archive"], "alerts": alerts(r),
                          "curated": bool(r.get("decisions")) or bool(re.search("admission|exception", r.get("selectedBy") or "")),
                          "allGreen": all(v is True for v in (r.get("criteria") or {}).values()),
                          "k": k0 // CHUNK})
        json.dump(chunk, open(os.path.join(out, "data", f"c{k0 // CHUNK:03d}.json"), "w"), separators=(",", ":"))
    open(os.path.join(out, "index.html"), "w").write(page_for(cn, cc, index))
    print(f"   {len(index)} records in {len(os.listdir(os.path.join(out, 'data')))} chunks")

links = "".join(f'<li><a href="{cc["slug"]}/">{cn} {VERSION}</a> ({sum(r["compilation"] == cn for r in d["records"])} records)</li>' for cn, cc in COMPS.items())
open(os.path.join(site, "index.html"), "w").write(
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Presto Record Review</title>'
    '<style>body{font:16px system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 16px}</style></head><body>'
    f'<h1>Presto record review</h1><p>Export {esc(d["snapshot"])}, built {esc(d["built"])}.</p><ul>{links}</ul></body></html>')
print("site ->", site)
