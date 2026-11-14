# Datasets to add to LiPDverse

PAGES 2k v3 candidate records from Tanaya Gondhalekar's `presto2k` repo
(`lipd_files/`, last changed 2026-05-25) that LiPDverse does not hold, cleaned
by `clean_v3_candidates.py` (2026-11-13; decisions by Nick McKay):

- the `PAGES2k 3.0.0beta` labels (`inCompilationBeta`) are removed;
- an `age` axis in years AD is renamed `year` (the Jalali 2018 cores and
  Żabińskie keep `age` in yr BP);
- archive names are LiPDverse's (MarineSediment, MolluskShell, LakeSediment);
- interpretations are removed from uncertainty columns;
- the column Tanaya selected in each file gets a temperature interpretation:
  climate scope, rank 1, `air@surface` (trees, lake) or `sea@surface`
  (marine, coral, mollusk), the sign its proxy implies (temperature
  reconstructions, MXD, Uk37 positive; mollusk and coral d18O, coral Sr/Ca
  negative) and the season from the column's own `seasonality` field, left
  blank where it has none. Tree Nob's season is Apr-Nov (its file said
  Nov-Apr in the interpretation and April-Nov in the description). Coral
  d18O also gets isotope-scope temperature (negative) and seawater isotope
  (positive) entries.

Dataset IDs and TSids are removed (Tanaya's files carried NOAA study
numbers, shared by the four Jalali cores, and `PCU-` TSids); LiPDverse mints
new ones. The LiPDverse updater's dry run (2026-11-13) also led to these
fixes: Tree Nob's 2001-2017 rows held only the year and are padded with NA;
dataSetNames are NFC (Faxaflói, Żabińskie) and match the file names, with the
typos "Novogrod" and "Reynold" corrected; Firth River's MXD column is a
standardized chronology (mean 1.0), so its units are `unitless`, and its
"uncertainty" column is the number of trees (1 to 21), now `sampleCount`.

PacificNorthwest.King.2023 in Tanaya's folder holds Heeter et al. (2023,
doi:10.1038/s41612-023-00340-3) under the name PacificNorthwest.Heeter.2023,
and her PacificNorthwest.Heeter.2023 file is the same record, so the cleaned
file is named PacificNorthwest.Heeter.2023. Its author list looks garbled
("Heeter, ."; "Harley, K."; "Abatzoglou, G."), so check it against the paper.

## Files (28)

New to LiPDverse:

| Archive | Datasets |
|---|---|
| Wood | Fennoscandia.Linderholm.2015, FirthRiver.Edwards.2025, GYE.Heeter.2021, GulfofAlaska.Wilson.2017, ITRDBCANA.Wang.2022, MEA.Esper.2025, Novgorod.Helama.2017, PacificNorthwest.Heeter.2023, SCM.Heeter.2020, SY.Wilson.2019, Taiwan.Liu.2017, Tibetan_Plateau.Duan.2018, TienShan.Chen.2019, WhiteMountains.DeMil.2024 |
| MolluskShell | Faxaflói.Mette.2023, Grimsey.Reynolds.2016, TireePassage.Reynolds.2017, TreeNob.Edge.2021 |
| MarineSediment | CSS00-07.Jalali.2018, INV12-15.Jalali.2018, KESC9-14.Jalali.2018, SW104-ND-14.Jalali.2018, PlacentiaBay.Sicre.2014 |
| LakeSediment | Żabińskie.Zander.2024 |

New composites or versions of records LiPDverse already holds (Presto2k
needs a curator decision on which copy to keep once they are in):

| Dataset | Overlaps |
|---|---|
| Palmyra.Dee.2020 | Ocn-Palmyra.Cobb.2013 (91% of its values; lacks Cobb's pre-1146 segments) and Palmyra.Sanchez.2020 (84%; ends 2007). Nick: use Dee for Palmyra. |
| Ingøya.Mette.2021 | SH16MEIN (r = 0.82, few shared values: a revised version) |
| HonTreIsland.Goodkin.2021 | BO14HTI02 (68% of its Sr/Ca values) |
| Mentawai.Abram.2020 | AB20MEN* (CoralHydro2k monthly series it is built from) |

Not added: BAM80_E-17.Harris.2025 and DSNF.Bregy.2022 (already in
LiPDverse), Tanaya's second copy of Heeter 2023 (PacificNorthwest.Heeter.2023, internally named King), the two
`test*` files, and the unnamed `.lpd` (Placentia Bay temperature series).
