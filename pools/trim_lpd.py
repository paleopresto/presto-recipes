#!/usr/bin/env python3
"""Trim LiPD files to a pool's records.

    python3 -I pools/trim_lpd.py <keep_tsids.txt> <src_dir> <out_dir>

Every paleo measurement column whose TSid is not in keep_tsids.txt (one TSid
per line: the pool's records plus the axis columns of their tables) is
removed from the JSON-LD and from its CSV, and the BagIt manifests are
recomputed. Chron data, models and ensembles are left as they are, so age
models and their ensembles travel with the records. Only the standard library
is used.

Column removal follows lipdGenerator's _remove_tsids_from_lpd
(DaveEdge1/prestoServer, getLipds/lipdGenerator/generate.py), inverted from a
drop list to a keep list, so a bundle reads exactly as PReSto's own filtered
files do.
"""
import csv
import glob
import hashlib
import io
import json
import os
import sys
import zipfile


def as_list(x):
    if isinstance(x, list):
        return x
    return [x] if x else []


def rehash(files, manifest_suffix):
    name = next((n for n in files if n.endswith(manifest_suffix)), None)
    if not name:
        return
    prefix = name[: -len(manifest_suffix)]
    out = []
    for line in files[name].decode("utf-8").strip().split("\n"):
        parts = line.split(None, 1)
        if len(parts) == 2 and (prefix + parts[1]) in files:
            out.append(f"{hashlib.md5(files[prefix + parts[1]]).hexdigest()}  {parts[1]}")
        else:
            out.append(line)
    files[name] = ("\n".join(out) + "\n").encode("utf-8")


def trim(path, keep, out_path):
    with zipfile.ZipFile(path) as z:
        files = {n: z.read(n) for n in z.namelist()}
    jname = next(n for n in files if n.endswith(".jsonld"))
    meta = json.loads(files[jname])
    kept, dropped = [], 0
    for pd_ in as_list(meta.get("paleoData")):
        for table in as_list(pd_.get("measurementTable")):
            cols = as_list(table.get("columns"))
            drop = [c for c in cols if c.get("TSid", c.get("tsid")) not in keep]
            if not drop:
                kept += [c.get("TSid") for c in cols]
                continue
            drop_nums = {int(c["number"]) for c in drop if isinstance(c.get("number"), (int, str))}
            new = [c for c in cols if c not in drop]
            for i, c in enumerate(new):
                c["number"] = i + 1
            table["columns"] = new
            kept += [c.get("TSid") for c in new]
            dropped += len(drop)
            fn = table.get("filename", "")
            cpath = next((n for n in files if fn and n.endswith(fn)), None)
            if cpath:
                rows = csv.reader(io.StringIO(files[cpath].decode("utf-8")))
                buf = io.StringIO()
                w = csv.writer(buf)
                for r in rows:
                    w.writerow([v for i, v in enumerate(r) if (i + 1) not in drop_nums])
                files[cpath] = buf.getvalue().encode("utf-8")
    files[jname] = json.dumps(meta, indent=2).encode("utf-8")
    # Data manifest first: the tag manifest checksums it.
    rehash(files, "manifest-md5.txt")
    rehash(files, "tagmanifest-md5.txt")
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for n, b in files.items():
            z.writestr(n, b)
    return kept, dropped


def main():
    keep_file, src, out = sys.argv[1:4]
    keep = {l.strip() for l in open(keep_file) if l.strip()}
    os.makedirs(out, exist_ok=True)
    found, ndrop = set(), 0
    for f in sorted(glob.glob(os.path.join(src, "*.lpd"))):
        kept, d = trim(f, keep, os.path.join(out, os.path.basename(f)))
        found.update(kept)
        ndrop += d
    missing = sorted(keep - found)
    print(json.dumps({"files": len(glob.glob(os.path.join(out, "*.lpd"))),
                      "columns_dropped": ndrop, "keep_requested": len(keep),
                      "keep_missing": missing[:20], "n_keep_missing": len(missing)}))


if __name__ == "__main__":
    main()
