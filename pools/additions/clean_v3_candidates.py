"""Clean PAGES 2k v3 candidate LiPD files (Tanaya Gondhalekar's presto2k repo,
lipd_files/) for addition to LiPDverse.

    python3 pools/additions/clean_v3_candidates.py <presto2k/lipd_files> <out_dir>

For each file below this:
  - removes the inCompilationBeta (PAGES2k 3.0.0beta) labels;
  - renames an "age" axis in years AD to "year";
  - writes LiPDverse archive names;
  - removes interpretations from uncertainty columns;
  - gives each column Tanaya selected (the one that carried the beta label) a
    temperature interpretation: climate scope, rank 1, the season from the
    column's own seasonality field (blank where it has none), and the sign
    its proxy implies. Coral d18O also gets isotope-scope temperature and
    seawater-isotope entries, as the Iso2k Palmyra records have.
and rewrites the bag manifests. Dataset IDs and TSids are left for the
LiPDverse updater to assign. Decisions: Nick McKay, 2026-11-13.
"""
import hashlib, json, os, sys, zipfile

src, out = sys.argv[1:3]
os.makedirs(out, exist_ok=True)

FILES = ["Fennoscandia.Linderholm.2015", "FirthRiver.Edwards.2025", "GYE.Heeter.2021", "GulfofAlaska.Wilson.2017",
         "ITRDBCANA.Wang.2022", "MEA.Esper.2025", "Novgorod.Helama.2017", "PacificNorthwest.King.2023",
         "SCM.Heeter.2020", "SY.Wilson.2019", "Taiwan.Liu.2017", "Tibetan_Plateau.Duan.2018", "TienShan.Chen.2019",
         "WhiteMountains.DeMil.2024", "Faxaflói.Mette.2023", "Grimsey.Reynolds.2016", "TireePassage.Reynolds.2017",
         "TreeNob.Edge.2021", "CSS00-07.Jalali.2018", "INV12-15.Jalali.2018", "KESC9-14.Jalali.2018",
         "SW104-ND-14.Jalali.2018", "PlacentiaBay.Sicre.2014", "Żabińskie.Zander.2024",
         "Ingøya.Mette.2021", "HonTreIsland.Goodkin.2021", "Mentawai.Abram.2020", "Palmyra.Dee.2020"]
ARCHIVE = {"marine sediment": "MarineSediment", "mollusk shell": "MolluskShell", "molluskshell": "MolluskShell",
           "lake sediment": "LakeSediment", "wood": "Wood", "coral": "Coral"}
SEASON = {"TreeNob.Edge.2021": "Apr-Nov"}
CORAL_BASIS = ("Coral d18O records sea surface temperature and seawater d18O; ENSO variability is the dominant "
               "source of d18O variability in the Palmyra fossil-coral records (Cobb et al., 2003; Dee et al., 2020).")


def direction(archive, col):
    v = (col.get("variableName") or "").lower()
    if v in ("d18o", "sr/ca"):
        return "negative"   # mollusk and coral d18O, coral Sr/Ca
    return "positive"       # temperature reconstructions, MXD, Uk37


def detail(archive):
    return "sea@surface" if archive in ("MarineSediment", "Coral", "MolluskShell") else "air@surface"


md5 = lambda b: hashlib.md5(b).hexdigest()
for name in FILES:
    zi = zipfile.ZipFile(os.path.join(src, name + ".lpd"))
    files = {n: zi.read(n) for n in zi.namelist()}
    jn = [n for n in files if n.endswith(".jsonld")][0]
    L = json.loads(files[jn])
    arch = ARCHIVE.get(str(L.get("archiveType")).strip().lower(), L.get("archiveType"))
    L["archiveType"] = arch
    chosen = []
    for t in L.get("paleoData", []):
        for mt in t.get("measurementTable", []):
            cc = mt["columns"]; cc = cc if isinstance(cc, list) else list(cc.values())
            for c in cc:
                if c.get("variableName") == "age" and str(c.get("units", "")).lower() in ("yr ad", "yr ce"):
                    c["variableName"] = "year"; c["description"] = "Year AD"
                flagged = bool(c.pop("inCompilationBeta", None))
                # Uncertainty columns are not records (Tree Nob's carried copies
                # of the temperature interpretation, one misspelt "positve").
                if (c.get("variableName") or "").lower().startswith("uncertainty"):
                    c.pop("interpretation", None)
                if name == "TreeNob.Edge.2021" and c.get("variableName") == "temperature":
                    flagged = True
                if not flagged:
                    continue
                season = SEASON.get(name, c.get("seasonality"))
                sign = direction(arch, c)
                interp = dict(scope="climate", rank=1, variable="temperature", variableDetail=detail(arch),
                              direction=sign, interpDirection=sign)
                if season: interp["seasonality"] = season
                if name == "Palmyra.Dee.2020": interp["basis"] = CORAL_BASIS
                c["interpretation"] = [interp]
                if arch == "Coral" and (c.get("variableName") or "").lower() == "d18o":
                    iso = dict(scope="isotope", rank=1, variable="temperature", direction="negative")
                    if season: iso["seasonality"] = season
                    c["interpretation"] += [iso, dict(scope="isotope", rank=2, variable="seawaterIsotope", direction="positive")]
                chosen.append((c.get("variableName"), c.get("units"), sign, season or ""))
    files[jn] = json.dumps(L, indent=2, ensure_ascii=False).encode()
    root = jn.split("/")[0]
    files[root + "/manifest-md5.txt"] = "".join(f"{md5(files[n])}  {n[len(root) + 1:]}\n"
                                               for n in sorted(files) if n.startswith(root + "/data/") and not n.endswith("/")).encode()
    files[root + "/tagmanifest-md5.txt"] = "".join(f"{md5(files[root + '/' + n])}  {n}\n"
                                                  for n in ("bag-info.txt", "bagit.txt", "manifest-md5.txt")
                                                  if root + "/" + n in files).encode()
    with zipfile.ZipFile(os.path.join(out, name + ".lpd"), "w", zipfile.ZIP_DEFLATED) as zo:
        for n in zi.namelist():
            zo.writestr(n, files[n])
    print(f"{name:34s} {arch:15s} {chosen}")
