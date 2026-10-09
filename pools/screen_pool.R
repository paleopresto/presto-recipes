#!/usr/bin/env Rscript
#
# Screen a pool's records against local instrumental temperature.
#
#   Rscript pools/screen_pool.R <export_dir> <pool> [screen] [window_start window_end]
#
# screen defaults to local_temperature (pools/config/screens/<screen>.yml).
# The instrumental file is downloaded once to pools/cache/ and checked
# against the config's sha256. A window overrides the config's (the
# two-half validation screens on each half).
#
# Writes pools/output/<pool>/<snapshot>/screen_<screen>[_<start>-<end>].csv:
# one row per record with r, p, n, n_eff per variant (suffixes) and pass_<variant>.

suppressPackageStartupMessages({ library(DBI); library(duckdb) })
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
for (f in list.files(file.path(here, "R"), full.names = TRUE)) source(f)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: screen_pool.R <export_dir> <pool> [screen] [window_start window_end]")
export <- path.expand(args[1]); pool_name <- args[2]
screen <- if (length(args) >= 3) args[3] else "local_temperature"
cfg <- yaml::read_yaml(file.path(here, "config", "screens", paste0(screen, ".yml")))
win <- if (length(args) >= 5) as.integer(args[4:5]) else unlist(cfg$window)

cache <- file.path(here, "cache"); dir.create(cache, showWarnings = FALSE)
nc <- file.path(cache, basename(cfg$instrumental$url))
if (!file.exists(nc)) utils::download.file(cfg$instrumental$url, nc, mode = "wb", quiet = TRUE)
if (unname(tools::sha256sum(nc)) != cfg$instrumental$sha256) stop(nc, " does not match the configured sha256")

con <- pool_snapshot(export)
snap <- jsonlite::read_json(file.path(export, "export_manifest.json"))$version
pool <- utils::read.csv(file.path(here, "output", pool_name, snap, "pool.csv"), stringsAsFactors = FALSE)
pool <- pool[pool$dedup_keep %in% TRUE, ]
X <- annual_matrix(con, pool)
had <- hadcrut_annual(nc, win[1]:win[2], cfg$instrumental$min_months %||% 8)

out <- pool[match(colnames(X), pool$TSid), c("TSid", "dataSetName", "archiveType", "variableName", "lat", "lon", "direction")]
for (v in names(cfg$variants)) {
  s <- screen_local(X, 1:2000, pool, had, c(cfg$variants[[v]], list(window = win, min_overlap = cfg$min_overlap)))
  out[[paste0("r_", v)]] <- s$r; out[[paste0("p_", v)]] <- s$p_adj; out[[paste0("pass_", v)]] <- s$pass
  cat(sprintf("%-10s %4d of %d pass (%d significant with the wrong sign)\n", v, sum(s$pass), nrow(s), sum(s$wrong_sign)))
}
out$n_overlap <- s$n
suffix <- if (length(args) >= 5) sprintf("_%d-%d", win[1], win[2]) else ""
f <- file.path(here, "output", pool_name, snap, sprintf("screen_%s%s.csv", screen, suffix))
utils::write.csv(out, f, row.names = FALSE)
cat("wrote", f, "\n")
