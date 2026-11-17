"""Build the local duplicate review page for one pool's review queue.

    python3 pools/review/build_dedup.py <pairs.json> <slug> [site_dir]

<pairs.json> is review_data.R's output (the pairs the dedup rules leave to a
person). Pairs that share a record are shown together as one group: the
reviewer picks the records to keep, and the page saves one decision per pair. Writes <site_dir>/dedup-<slug>/index.html. server.py saves each
decision to verdicts/dedup_<slug>/<pair>.json, the format import_decisions.R
reads into baselines/dedup_decisions.csv.
"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
src, slug = sys.argv[1:3]
site = sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, "site")
d = json.load(open(src))
# jsonlite's auto_unbox writes a one-element vector as a scalar
for pr in d["pairs"]:
    for r in (pr["a"], pr["b"]):
        for k in ("compilations", "publications", "interpretations", "year", "value"):
            if r.get(k) is not None and not isinstance(r[k], list): r[k] = [r[k]]
# Linked pairs (A~B, B~C) become one group, decided on one page by choosing
# which records to keep (Nick, 2026-11-17); a lone pair is a group of two.
parent = {}
def find(t):
    while parent.setdefault(t, t) != t: t = parent[t]
    return t
for pr in d["pairs"]: parent[find(pr["a"]["TSid"])] = find(pr["b"]["TSid"])
groups = {}
for pr in d["pairs"]:
    g = groups.setdefault(find(pr["a"]["TSid"]), {"recs": {}, "pairs": []})
    for r in (pr["a"], pr["b"]): g["recs"].setdefault(r["TSid"], r)
    g["pairs"].append({k: pr.get(k) for k in ("key", "rule", "km", "n", "r", "r_diff", "same_doi", "suggest")}
                      | {"a": pr["a"]["TSid"], "b": pr["b"]["TSid"]})
items = [{"key": "+".join(sorted(g["recs"])), "recs": list(g["recs"].values()), "pairs": g["pairs"]} for g in groups.values()]
name = {"presto2k": "Presto2k", "presto12k": "Presto12k"}.get(slug, slug)
page = open(os.path.join(here, "dedup_template.html")).read()
page = (page.replace("__TITLE__", f"{name} Duplicate Review").replace("__HEADING__", f"{name} duplicate review")
        .replace("__DATA__", json.dumps({"slug": slug, "snapshot": d["snapshot"], "items": items},
                                        separators=(",", ":")).replace("</", "<\\/")))
out = os.path.join(site, f"dedup-{slug}"); os.makedirs(out, exist_ok=True)
open(os.path.join(out, "index.html"), "w").write(page)
idx = os.path.join(site, "index.html")
if os.path.exists(idx):
    s = open(idx).read()
    s = re.sub(rf'<li><a href="dedup-{slug}/">.*?</li>', "", s)
    s = s.replace("</ul>", f'<li><a href="dedup-{slug}/">{name} duplicate pairs</a> ({len(items)} to decide, export {d["snapshot"]})</li></ul>')
    open(idx, "w").write(s)
print(f"{len(d['pairs'])} pairs in {len(items)} groups ({sum(len(i['recs']) > 2 for i in items)} with more than two records) -> {out}")
