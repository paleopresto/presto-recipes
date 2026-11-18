#!/usr/bin/env Rscript
#
# Derive a screened pool from a parent pool and its screen output.
#
#   Rscript pools/screened_pool.R <export_dir> <pool>
#
# <pool> is a config (pools/config/<pool>.yml) with parent and, optionally,
# screen and variant. Reads the parent's pool.csv and screen_<screen>.csv for the
# export's snapshot (run pools/screen_pool.R first) and writes
# pools/output/<pool>/<snapshot>/pool.csv: the parent's kept records that
# pass, in the parent's format, so build_bundle.R packages it unchanged.
# Optional method-specific checks in the config (max_resolution,
# min_calibration_years, archives, max_repeat_fraction, exclude_units_pattern,
# max_lag1) apply to the
# parent's metrics.

here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: screened_pool.R <export_dir> <pool>")
export <- path.expand(args[1]); name <- args[2]
cfg <- yaml::read_yaml(file.path(here, "config", paste0(name, ".yml")))
snap <- jsonlite::read_json(file.path(export, "export_manifest.json"))$version
pdir <- file.path(here, "output", cfg$parent, snap)
p <- utils::read.csv(file.path(pdir, "pool.csv"), stringsAsFactors = FALSE)
p <- p[p$dedup_keep %in% TRUE, ]
# A screen (screen_pool.R output) is optional: presto-LMR's subset is
# defined by the method checks below alone.
if (!is.null(cfg$screen)) {
  s <- utils::read.csv(file.path(pdir, sprintf("screen_%s.csv", cfg$screen)), stringsAsFactors = FALSE)
  col <- paste0("pass_", cfg$variant)
  if (!col %in% names(s)) stop(col, " not in the screen output; add the variant and rerun screen_pool.R")
  p <- p[p$TSid %in% s$TSid[s[[col]] %in% TRUE], ]
}
# Method-specific checks on the parent's metrics (records.csv columns).
check <- function(drop, what) {
  drop[is.na(drop)] <- FALSE
  if (any(drop)) cat(sprintf("%s: %d records fail %s\n", name, sum(drop), what))
  p[!drop, ]
}
# What cfr (presto-LMR) can assimilate: an annual time step (its filter on
# dt), overlap with the PSM calibration period, and a proxy class it models.
if (!is.null(cfg$max_resolution)) p <- check(is.na(p$res_win) | p$res_win > cfg$max_resolution,
                                             sprintf("max_resolution %.1f", cfg$max_resolution))
if (!is.null(cfg$min_calibration_years)) p <- check(is.na(p$n_calib) | p$n_calib < cfg$min_calibration_years,
                                                    sprintf("min_calibration_years %d", cfg$min_calibration_years))
if (!is.null(cfg$archives)) p <- check(!p$archiveType %in% unlist(cfg$archives), "archives")
# Annual in information, not only in time step: successive values that
# repeat at least max_repeat_fraction of the time (step functions on an
# annual grid), and units that are rates per century or millennium.
if (!is.null(cfg$max_repeat_fraction)) {
  if (!"repeat_win" %in% names(p)) stop("repeat_win not in the parent pool; rebuild it with build_pools.R")
  p <- check(!is.na(p$repeat_win) & p$repeat_win >= cfg$max_repeat_fraction,
             sprintf("max_repeat_fraction %.2f", cfg$max_repeat_fraction))
}
if (!is.null(cfg$exclude_units_pattern))
  p <- check(grepl(cfg$exclude_units_pattern, p$units, ignore.case = TRUE),
             sprintf("exclude_units_pattern %s", cfg$exclude_units_pattern))
if (!is.null(cfg$max_lag1)) {
  if (!"lag1_win" %in% names(p)) stop("lag1_win not in the parent pool; rebuild it with build_pools.R")
  drop <- !is.na(p$lag1_win) & p$lag1_win > cfg$max_lag1
  if (any(drop)) cat(sprintf("%s: %d records fail max_lag1 %.2f: %s\n", name, sum(drop), cfg$max_lag1,
                             paste(p$dataSetName[drop], collapse = ", ")))
  p <- p[!drop, ]
}
odir <- file.path(here, "output", name, snap); dir.create(odir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(p, file.path(odir, "pool.csv"), row.names = FALSE)
cat(sprintf("%s: %d of the %s pool's records pass %s -> %s\n", name, nrow(p), cfg$parent,
            if (is.null(cfg$screen)) "the method checks" else paste0(cfg$screen, "/", cfg$variant), file.path(odir, "pool.csv")))
