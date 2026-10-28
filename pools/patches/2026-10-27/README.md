# Patches to export 2026-10-27

Corrected .lpd files that bundles of this snapshot use in place of the
export's copies (`build_bundle.R --patch=pools/patches/2026-10-27`), until the
next export carries the fixes. Each bundle manifest lists them under `patched`.

| File | Export md5 | Patched md5 | Fix |
|---|---|---|---|
| SayramLake.Jiang.2013.lpd | ce9d47ed4d33c4809fb215853236dfaf | 7d693e2d68bbacdc571d15ece5a9e1c5 | LiPDverse curator fix 2026-10-28 (changelog 1.0.5): removed an all-zero age column (lcRy0lBU8W0ixPNSulg), flagged primary, and an all-zero depth column (lcRIkSzGPWfYA586Rnu); the real age column lcR4GOByG3Fk9W8rWip is now primary. The zero age axis crashed Presto-HoloceneDA (da_load_proxies.py, IndexError) on PReSto12k 0_1_0. No change to PReSto12k membership. |
