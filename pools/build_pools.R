#!/usr/bin/env Rscript
#
# Build the PReSto data pools from one LiPDverse export.
#
#   Rscript pools/build_pools.R <export_dir> [pool ...]
#
# export_dir is a whole-database export (lipdverse-updater lv_export_database),
# e.g. ~/lipdverse-export/_database/2026-10-08. Pools default to all configs in
# pools/config. For each pool this writes, under pools/output/<pool>/<snapshot>/:
#   records.csv     every candidate, its metrics and which criteria it fails
#   pool.csv        the selected records, with dedup_keep
#   dedup_pairs.csv every candidate duplicate pair, its similarity and the rule applied
#   tsids.json      {"TSIDs": [...]} after dedup, the format PReSto's recipes use
#   baseline.csv    the baseline records and whether the pool recovers them

suppressPackageStartupMessages({library(DBI); library(duckdb); library(yaml); library(jsonlite)})

here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
for (f in list.files(file.path(here, "R"), full.names = TRUE)) source(f)

args <- commandArgs(trailingOnly = TRUE)
if (!length(args)) stop("usage: build_pools.R <export_dir> [pool ...]")
con <- pool_snapshot(args[1])
on.exit(dbDisconnect(con, shutdown = TRUE))
snap <- attr(con, "snapshot")

pools <- if (length(args) > 1) args[-1] else sub("\\.yml$", "", list.files(file.path(here, "config")))

for (p in pools) {
  cfg <- read_yaml(file.path(here, "config", paste0(p, ".yml")))
  message(sprintf("== %s (snapshot %s)", p, snap))
  x <- build_pool(con, cfg)
  out <- file.path(here, "output", p, snap)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  write.csv(x, file.path(out, "records.csv"), row.names = FALSE)
  sel <- x[x$selected, ]
  message(sprintf("   %d candidates, %d selected from %d datasets", nrow(x), nrow(sel),
                  length(unique(sel$datasetId))))
  fails <- table(unlist(strsplit(x$fails[!x$selected], ";")))
  message("   failing criteria: ", paste(names(fails), fails, sep = "=", collapse = ", "))

  prior_file <- file.path(here, "baselines", "dedup_prior.csv")
  prior <- if (file.exists(prior_file)) read.csv(prior_file, stringsAsFactors = FALSE) else NULL
  dd <- dedup_pool(con, sel, attr(x, "points"), prior, unlist(cfg$collapse_prefer_units))
  write.csv(dd$pairs, file.path(out, "dedup_pairs.csv"), row.names = FALSE)
  sel <- dd$pool
  write.csv(sel, file.path(out, "pool.csv"), row.names = FALSE)
  pr <- dd$pairs[dd$pairs$duplicate, ]
  message(sprintf("   dedup: %d collapsed within datasets; %d cross-dataset pairs, %d duplicates (%s), %d removed, %d for review",
                  sum(sel$dedup_rule %in% "within-dataset"), nrow(dd$pairs), nrow(pr),
                  paste(names(table(pr$rule)), table(pr$rule), sep = "=", collapse = ", "),
                  sum(sel$dedup_rule %in% "cross-dataset"), sum(pr$review)))
  sel <- sel[sel$dedup_keep, ]
  write_json(list(TSIDs = sel$TSid, snapshot = snap, criteria = cfg$name), file.path(out, "tsids.json"),
             auto_unbox = TRUE, pretty = TRUE)
  message(sprintf("   final pool: %d records from %d datasets", nrow(sel), length(unique(sel$datasetId))))

  if (!is.null(cfg$baseline)) {
    b <- read.csv(file.path(here, "baselines", cfg$baseline), stringsAsFactors = FALSE)
    present <- dbGetQuery(con, "SELECT TSid FROM timeseries")$TSid
    b$in_snapshot <- b$TSid %in% present
    b$candidate <- b$TSid %in% x$TSid
    b$selected <- b$TSid %in% x$TSid[x$selected]
    b$final <- b$TSid %in% sel$TSid
    b$fails <- x$fails[match(b$TSid, x$TSid)]
    write.csv(b, file.path(out, "baseline.csv"), row.names = FALSE)
    message(sprintf("   baseline %s: %d records, %d in snapshot, %d candidates, %d pass criteria (recall %.1f%%), %d after dedup",
                    cfg$baseline, nrow(b), sum(b$in_snapshot), sum(b$candidate), sum(b$selected),
                    100 * sum(b$selected) / sum(b$in_snapshot), sum(b$final)))
    message(sprintf("   new relative to baseline: %d records", sum(!sel$TSid %in% b$TSid)))
  }
}
