# PReSto reconstruction runs

One directory per reconstruction and snapshot. Each holds the
`query_params.json` the template reads (written by `make_runs.R`): `mode:
bundle`, the pool bundle's URL and sha256, and the pool's TSids. A run is a
repository generated from the template with these files committed;
committing `query_params.json` last triggers the workflow.

| Run | Template | Pool | Config |
|---|---|---|---|
| presto-LMR | DaveEdge1/LMR2 (to be paleopresto/presto-LMR) | pages2k2017 | PReSto2k class-based seasonality: pending (see below) |
| presto-BayGMST | DaveEdge1/presto-BayGMST | pages2k2017 | `user_config.yml` here (LASSO, 1-2000 CE) |
| presto-HoloceneDA | DaveEdge1/presto-holocene_da | temp12k | template default (Erb et al. 2022 settings) |
| presto-Temp12k | presto-Temp12k_Composites (trial) | temp12k | template default (5 methods, nens 500) |

The templates accept `mode: bundle` on their `pool-bundles` branches, through
`.github/actions/fetch-pool` in this repo.

presto-LMR: the PReSto2k primary product used class-based seasonality
(LMRv2.1's per-proxy-class season pools, bilinear PSM for ring width,
GISTEMP and GPCC v6 as calibration targets), which the template's own data
path does not apply; its config has to carry the corresponding
`ptype_psm_dict` / `ptype_season_dict` keys (paleopresto/presto2k
CARC/lmr_reproduce.py).
