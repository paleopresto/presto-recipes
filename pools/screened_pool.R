#!/usr/bin/env Rscript
#
# Derive a screened pool from a parent pool and its screen output.
#
#   Rscript pools/screened_pool.R <export_dir> <pool>
#
# <pool> is a config (pools/config/<pool>.yml) with parent, screen and
# variant. Reads the parent's pool.csv and screen_<screen>.csv for the
# export's snapshot (run pools/screen_pool.R first) and writes
# pools/output/<pool>/<snapshot>/pool.csv: the parent's kept records that
# pass, in the parent's format, so build_bundle.R packages it unchanged.

here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: screened_pool.R <export_dir> <pool>")
export <- path.expand(args[1]); name <- args[2]
cfg <- yaml::read_yaml(file.path(here, "config", paste0(name, ".yml")))
snap <- jsonlite::read_json(file.path(export, "export_manifest.json"))$version
pdir <- file.path(here, "output", cfg$parent, snap)
p <- utils::read.csv(file.path(pdir, "pool.csv"), stringsAsFactors = FALSE)
s <- utils::read.csv(file.path(pdir, sprintf("screen_%s.csv", cfg$screen)), stringsAsFactors = FALSE)
col <- paste0("pass_", cfg$variant)
if (!col %in% names(s)) stop(col, " not in the screen output; add the variant and rerun screen_pool.R")
p <- p[p$dedup_keep %in% TRUE & p$TSid %in% s$TSid[s[[col]] %in% TRUE], ]
odir <- file.path(here, "output", name, snap); dir.create(odir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(p, file.path(odir, "pool.csv"), row.names = FALSE)
cat(sprintf("%s: %d of the %s pool's records pass %s/%s -> %s\n", name, nrow(p), cfg$parent, cfg$screen, cfg$variant, file.path(odir, "pool.csv")))
