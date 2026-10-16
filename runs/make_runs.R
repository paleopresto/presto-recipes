#!/usr/bin/env Rscript
#
# Write the query_params.json each reconstruction template reads, pointing at
# the pool bundles for one snapshot.
#
#   Rscript runs/make_runs.R <snapshot> <release_tag> [--compilation=<version>] [run ...]
#
# --compilation=<version> runs on the published LiPDverse compilations
# (pools from pools/compilation_pool.R: PReSto2k_<version> and
# PReSto12k_<version>, and BayGMST's screened PReSto2k_<version>_localfdr10)
# instead of the recipe-built pools.
#
# The bundles are published as assets of the presto-recipes release
# <release_tag>; each query_params.json pins one by URL and sha256, and
# carries the pool's TSids (presto-LMR's converter whitelists by them).
# Naming runs (e.g. presto-BayGMST) writes only those, for a release that
# carries only their pools.

suppressPackageStartupMessages(library(jsonlite))
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
snap <- args[1]; tag <- args[2]
cv <- sub("^--compilation=", "", grep("^--compilation=", args, value = TRUE))
args <- args[!grepl("^--compilation=", args)]
base <- sprintf("https://github.com/paleopresto/presto-recipes/releases/download/%s", tag)

runs <- list(
  "presto-LMR"        = "cfr_annual",
  "presto-BayGMST"    = "cfr_annual_localfdr10",
  "presto-HoloceneDA" = "temp12k",
  "presto-Temp12k"    = "temp12k")

if (length(cv)) runs <- list(
  "presto-LMR"        = paste0("PReSto2k_", cv),
  "presto-BayGMST"    = paste0("PReSto2k_", cv, "_localfdr10"),
  "presto-HoloceneDA" = paste0("PReSto12k_", cv),
  "presto-Temp12k"    = paste0("PReSto12k_", cv))
if (length(args) > 2) runs <- runs[args[-(1:2)]]
for (r in names(runs)) {
  pool <- runs[[r]]
  m <- read_json(file.path(here, "..", "pools", "bundles", sprintf("presto-pool-%s-%s.json", pool, snap)))
  qp <- list(
    mode = "bundle", pool = pool, snapshot = snap,
    # A compilation's own members are defined by the compilation; a screened
    # subset of it by the screen's config.
    criteria = if (length(cv) && !grepl("_local", pool)) sprintf("https://lipdverse.org/%s/%s/", sub("_.*", "", pool), cv)
               else sprintf("https://github.com/paleopresto/presto-recipes/blob/%s/pools/config/%s.yml", tag, pool),
    bundle = list(url = sprintf("%s/%s", base, m$bundle$file), sha256 = m$bundle$sha256),
    uniqueID = sprintf("%s-%s-%s", r, pool, snap),
    compilation = if (length(cv)) list(name = sub("_.*", "", pool), version = cv, export = snap) else NULL,
    tsids = unlist(m$TSIDs))
  d <- file.path(here, r, snap); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  write_json(qp, file.path(d, "query_params.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("%-18s %-12s %4d records  %s\n", r, pool, length(qp$tsids), file.path(r, snap, "query_params.json")))
}
