# PReSto data pools

Automated selection of LiPDverse records for PReSto's reconstructions, from
the published inclusion criteria of the two community databases they descend
from:

| Pool | Criteria | Baseline | Used by |
|---|---|---|---|
| `pages2k2017` | PAGES 2k Consortium (2017), Sci. Data 4:170088 | PAGES 2k v2.0.0 (692 records) | presto-LMR |
| `pages2k2017_localfdr10` | `pages2k2017`, screened on local HadCRUT5 temperature (FDR < 0.10, 1850-2000) | | presto-BayGMST |
| `temp12k` | Kaufman et al. (2020), Sci. Data 7:115 | Temperature 12k v1.0.0 (1,332 TSids) | presto-HoloceneDA, presto-Temp12k |

Each pool is built from the whole of LiPDverse, not from the compilations, so
a record qualifies on its metadata and data alone. Pools are then narrowed by
each algorithm (e.g. calibrated degC records only for the Holocene DA; PSM
calibration screening in cfr).

## Screened pools

Index reconstructions that calibrate a proxy composite against instrumental
GMST (BayGMST) need records that track temperature, which metadata alone
cannot show. `screen_pool.R` tests each record of a pool against the nearest
HadCRUT5 cell (AR(1)-adjusted p, sign from the interpretation direction;
`config/screens/`), and `screened_pool.R` writes the passing records as a new
pool (`config/pages2k2017_localfdr10.yml`), which `build_bundle.R` packages like
any other. The threshold was chosen by two-half validation in presto-paper
(`analysis/baygmst_screening/`).

    Rscript pools/screen_pool.R <export_dir> pages2k2017
    Rscript pools/screened_pool.R <export_dir> pages2k2017_localfdr10

## Running

    Rscript pools/build_pools.R ~/lipdverse-export/_database/2026-10-08

The export must be schema v3 with `timeseries.tableId` (lipdverse-updater
3805c00 or later): that is what pairs each value column with its own time axis
and makes windowed criteria computable from the export alone.

## How the criteria are automated

Thresholds live in `config/*.yml`, each quoted from its source paper or marked
as an operational choice where the paper describes something in words. Every
criterion is evaluated separately, so `records.csv` says which criteria a
record fails, and `baseline.csv` says which baseline records the automated
selection does not recover, and why.

## Baselines

`baselines/` holds the TSids of each comparison set: PAGES 2k v2.0.0
(`paleoData_useInGlobalTemperatureAnalysis`), Temperature 12k v1.0.0
(`paleoData_inCompilation` = Temp12k), and the 711 records Erb et al. (2022)
assimilated (`../holocene_DA_used_TSids.json`).

## Human decisions the pools reuse

Automation covers what the metadata can show. What it cannot show, people have
already decided, and the pools keep those decisions rather than re-making them:

- `baselines/curator_exclusions.csv` (`make_exclusions.R`): records a
  compilation's curators rejected. Temperature 12k v1.0.0 "Tverse" records,
  current Tverse membership, PAGES 2k v2.0.0 records not used in the global
  analysis, and current QC-sheet rejections. A later admission overrides.
- `baselines/dedup_prior.csv` (`make_dod2k_prior.R`): DoD2k's duplicate
  decisions (Evans et al., 2026), matched to LiPDverse TSids by their values.

Checked against DoD2k's 325 mappable decisions: 196 pairs are already a single
record in LiPDverse; of the remaining 128 expert-confirmed duplicates the
automated detector finds 117 (91%). Which copy to keep is mostly a tie (equal
length, same publication year) and is otherwise not predicted by any simple
rule, which is why prior decisions are reused rather than re-derived.
