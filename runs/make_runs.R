#!/usr/bin/env Rscript
#
# Write the query_params.json each reconstruction template reads, pointing at
# the pool bundles for one snapshot.
#
#   Rscript runs/make_runs.R <snapshot> <release_tag>
#
# The bundles are published as assets of the presto-recipes release
# <release_tag>; each query_params.json pins one by URL and sha256, and
# carries the pool's TSids (presto-LMR's converter whitelists by them).

suppressPackageStartupMessages(library(jsonlite))
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
snap <- args[1]; tag <- args[2]
base <- sprintf("https://github.com/paleopresto/presto-recipes/releases/download/%s", tag)

runs <- list(
  "presto-LMR"        = "pages2k2017",
  "presto-BayGMST"    = "pages2k2017",
  "presto-HoloceneDA" = "temp12k",
  "presto-Temp12k"    = "temp12k")

for (r in names(runs)) {
  pool <- runs[[r]]
  m <- read_json(file.path(here, "..", "pools", "bundles", sprintf("presto-pool-%s-%s.json", pool, snap)))
  qp <- list(
    mode = "bundle", pool = pool, snapshot = snap,
    criteria = sprintf("https://github.com/paleopresto/presto-recipes/blob/%s/pools/config/%s.yml", tag, pool),
    bundle = list(url = sprintf("%s/%s", base, m$bundle$file), sha256 = m$bundle$sha256),
    uniqueID = sprintf("%s-%s-%s", r, pool, snap),
    tsids = unlist(m$TSIDs))
  d <- file.path(here, r, snap); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  write_json(qp, file.path(d, "query_params.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("%-18s %-12s %4d records  %s\n", r, pool, length(qp$tsids), file.path(r, snap, "query_params.json")))
}
