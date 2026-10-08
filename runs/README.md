# PReSto reconstruction runs

One directory per reconstruction and snapshot. Each holds the
`query_params.json` the template reads (written by `make_runs.R`): `mode:
bundle`, the pool bundle's URL and sha256, and the pool's TSids. A run is a
repository generated from the template with these files committed;
committing `query_params.json` last triggers the workflow.

| Run | Template | Pool | Config |
|---|---|---|---|
| presto-LMR | DaveEdge1/LMR2 (to be paleopresto/presto-LMR) | pages2k2017 | `lmr_configs.yml` here: PReSto2k class-based seasonality, annual records |
| presto-BayGMST | DaveEdge1/presto-BayGMST | pages2k2017 | `user_config.yml` here (LASSO, 1-2000 CE) |
| presto-HoloceneDA | DaveEdge1/presto-holocene_da | temp12k | template default (Erb et al. 2022 settings) |
| presto-Temp12k | presto-Temp12k_Composites (trial) | temp12k | template default (5 methods, nens 500) |

The templates accept `mode: bundle` on their `pool-bundles` branches, through
`.github/actions/fetch-pool` in this repo.

presto-LMR: `lmr_configs.yml` reproduces PReSto2k's class-based seasonality
(paleopresto/presto2k paleobook/C02_a: LMRv2.1 season pools per proxy class,
bilinear PSM for ring width, cfr defaults for other classes) and its run
settings, and assimilates annual and sub-annual records only (dt 0-1.2 yr).
