#!/usr/bin/env Rscript
#
# Package a pool as a pinned LiPD bundle for the reconstruction templates.
#
#   Rscript pools/build_bundle.R <pool> <export_dir> <lpd_dir>
#
# lpd_dir holds the snapshot's .lpd files (each must match the export's
# datasets.file_md5, which is checked). Each file is trimmed to the pool's
# records and their tables' axis columns (trim_lpd.py), so an algorithm that
# takes every column it recognizes (the Holocene DA takes every degC column)
# assimilates the pool and nothing else.
#
# Writes, under pools/bundles/ (not in git; published as release assets):
#   presto-pool-<pool>-<snapshot>.zip   the trimmed .lpd files
#   presto-pool-<pool>-<snapshot>.json  manifest: snapshot, criteria, TSids,
#                                       source md5 and bundle sha256

suppressPackageStartupMessages({library(DBI); library(duckdb); library(jsonlite)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop("usage: build_bundle.R <pool> <export_dir> <lpd_dir>")
pool <- args[1]; export <- path.expand(args[2]); src <- path.expand(args[3])

con <- dbConnect(duckdb(shared_home = FALSE), dbdir = file.path(export, "lipdverse.duckdb"), read_only = TRUE)
snap <- jsonlite::read_json(file.path(export, "export_manifest.json"))$version
p <- read.csv(file.path(here, "output", pool, snap, "pool.csv"), stringsAsFactors = FALSE)
p <- p[p$dedup_keep, ]

ds <- dbGetQuery(con, "SELECT datasetId, dataSetName, file_md5 FROM datasets")
ds <- ds[ds$datasetId %in% p$datasetId, ]
f <- file.path(src, paste0(ds$dataSetName, ".lpd"))
md5 <- unname(tools::md5sum(f))
bad <- is.na(md5) | md5 != ds$file_md5
if (any(bad)) stop(sum(bad), " source files do not match the ", snap, " export, e.g. ", ds$dataSetName[bad][1])

duckdb::duckdb_register(con, "ds_tmp", data.frame(datasetId = ds$datasetId))
axes <- dbGetQuery(con, "SELECT TSid FROM timeseries JOIN ds_tmp USING (datasetId)
                         WHERE tableType = 'paleo' AND tableKind = 'measurement' AND isAxis")$TSid
keep <- unique(c(p$TSid, axes))

work <- tempfile("bundle"); dir.create(file.path(work, "src"), recursive = TRUE)
invisible(file.copy(f, file.path(work, "src")))
writeLines(keep, file.path(work, "keep.txt"))
name <- sprintf("presto-pool-%s-%s", pool, snap)
out <- file.path(work, name)
res <- system2("python3", c("-I", shQuote(file.path(here, "trim_lpd.py")), shQuote(file.path(work, "keep.txt")),
                            shQuote(file.path(work, "src")), shQuote(out)), stdout = TRUE)
r <- jsonlite::fromJSON(res[length(res)])
# Every pool record must survive trimming; a missing axis is only reported.
lost <- intersect(r$keep_missing, p$TSid)
if (r$n_keep_missing && any(p$TSid %in% r$keep_missing)) stop("pool records lost in trimming: ", paste(lost, collapse = ", "))

bdir <- file.path(here, "bundles"); dir.create(bdir, showWarnings = FALSE)
zip <- file.path(bdir, paste0(name, ".zip"))
unlink(zip)
old <- setwd(work); utils::zip(zip, name, flags = "-qrX"); setwd(old)
sha <- function(x) sub(" .*", "", system2("shasum", c("-a", "256", shQuote(x)), stdout = TRUE))

commit <- tryCatch(system2("git", c("-C", shQuote(here), "rev-parse", "--short", "HEAD"), stdout = TRUE), error = function(e) NA)
manifest <- list(
  pool = pool, snapshot = snap, criteria = file.path("pools/config", paste0(pool, ".yml")),
  presto_recipes_commit = commit, created = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  n_records = nrow(p), n_datasets = nrow(ds), columns_dropped = r$columns_dropped,
  bundle = list(file = basename(zip), sha256 = sha(zip), bytes = file.size(zip)),
  TSIDs = p$TSid,
  sources = lapply(seq_len(nrow(ds)), function(i) list(dataSetName = ds$dataSetName[i],
                                                         datasetId = ds$datasetId[i], md5 = ds$file_md5[i])))
write_json(manifest, file.path(bdir, paste0(name, ".json")), auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("%s: %d records, %d datasets, %d columns dropped, %.1f MB, sha256 %s\n",
            name, nrow(p), nrow(ds), r$columns_dropped, file.size(zip) / 1e6, manifest$bundle$sha256))
