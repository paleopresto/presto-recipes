# PReSto data pools

Automated selection of LiPDverse records for PReSto's reconstructions, from
the published inclusion criteria of the two community databases they descend
from:

| Pool | Criteria | Baseline | Used by |
|---|---|---|---|
| `pages2k2017` | PAGES 2k Consortium (2017), Sci. Data 4:170088 | PAGES 2k v2.0.0 (692 records) | presto-LMR, presto-BayGMST |
| `temp12k` | Kaufman et al. (2020), Sci. Data 7:115 | Temperature 12k v1.0.0 (1,332 TSids) | presto-HoloceneDA, presto-Temp12k |

Each pool is built from the whole of LiPDverse, not from the compilations, so
a record qualifies on its metadata and data alone. Pools are then narrowed by
each algorithm (e.g. calibrated degC records only for the Holocene DA; PSM
calibration screening in cfr).

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
