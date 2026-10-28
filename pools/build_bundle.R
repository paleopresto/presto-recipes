#!/usr/bin/env Rscript
#
# Package a pool as a pinned LiPD bundle for the reconstruction templates.
#
#   Rscript pools/build_bundle.R <pool> <export_dir> <lpd_dir | source_bundle.zip> [--patch=<dir>]
#
# lpd_dir holds the snapshot's .lpd files (each must match the export's
# datasets.file_md5, which is checked). Each file is trimmed to the pool's
# records and their tables' axis columns (trim_lpd.py), so an algorithm that
# takes every column it recognizes (the Holocene DA takes every degC column)
# assimilates the pool and nothing else. Missing-value codes stored as data
# (+-9999, -999, +-99999, +-999999) in the pool's records are set to NaN and
# listed in the manifest's codes_masked; axes named age that hold years AD/CE
# are renamed year (axes_renamed), so readers do not reverse them in time.
#
# Writes, under pools/bundles/ (not in git; published as release assets):
#   presto-pool-<pool>-<snapshot>.zip   the trimmed .lpd files
#   presto-pool-<pool>-<snapshot>.json  manifest: snapshot, criteria, TSids,
#                                       source md5 and bundle sha256
#
# --patch=<dir> substitutes the .lpd files in <dir> for their export copies, to
# carry a curator's fix to a file before the next export without changing the
# snapshot. Each patched file must be a dataset of the pool (same datasetId);
# the manifest lists it under patched, with its md5 and the export's, and its
# sources entry gives the patched md5.

suppressPackageStartupMessages({library(DBI); library(duckdb); library(jsonlite)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
patch_dir <- sub("^--patch=", "", grep("^--patch=", args, value = TRUE))
args <- grep("^--", args, value = TRUE, invert = TRUE)
if (length(args) < 3) stop("usage: build_bundle.R <pool> <export_dir> <lpd_dir> [--patch=<dir>]")
pool <- args[1]; export <- path.expand(args[2]); src <- path.expand(args[3])

con <- dbConnect(duckdb(shared_home = FALSE), dbdir = file.path(export, "lipdverse.duckdb"), read_only = TRUE)
snap <- jsonlite::read_json(file.path(export, "export_manifest.json"))$version
p <- read.csv(file.path(here, "output", pool, snap, "pool.csv"), stringsAsFactors = FALSE)
p <- p[p$dedup_keep, ]

ds <- dbGetQuery(con, "SELECT datasetId, dataSetName, file_md5 FROM datasets")
ds <- ds[ds$datasetId %in% p$datasetId, ]
if (grepl("\\.zip$", src)) {
  # A bundle of the same snapshot as the source (for a pool that is a subset
  # of that bundle's): its manifest must record, for every dataset needed, the
  # export's own md5, and the new bundle trims its already-trimmed files.
  m <- jsonlite::read_json(sub("\\.zip$", ".json", src))
  if (!identical(m$snapshot, snap)) stop("source bundle is from snapshot ", m$snapshot, ", not ", snap)
  smd5 <- setNames(vapply(m$sources, `[[`, "", "md5"), vapply(m$sources, `[[`, "", "datasetId"))
  bad <- is.na(smd5[ds$datasetId]) | smd5[ds$datasetId] != ds$file_md5
  if (any(bad)) stop(sum(bad), " datasets are missing from the source bundle or from another export, e.g. ", ds$dataSetName[bad][1])
  ux <- tempfile("srcbundle"); utils::unzip(src, exdir = ux)
  f <- file.path(ux, sub("\\.zip$", "", basename(src)), paste0(ds$dataSetName, ".lpd"))
  if (!all(file.exists(f))) stop("source bundle lacks files, e.g. ", basename(f[!file.exists(f)][1]))
  missing_pool <- setdiff(p$TSid, unlist(m$TSIDs))
  if (length(missing_pool)) stop(length(missing_pool), " pool records are not in the source bundle, e.g. ", missing_pool[1])
} else {
  f <- file.path(src, paste0(ds$dataSetName, ".lpd"))
  md5 <- unname(tools::md5sum(f))
  bad <- is.na(md5) | md5 != ds$file_md5
  if (any(bad)) stop(sum(bad), " source files do not match the ", snap, " export, e.g. ", ds$dataSetName[bad][1])
}

patched <- list()
if (length(patch_dir)) {
  pf <- list.files(path.expand(patch_dir), pattern = "\\.lpd$", full.names = TRUE)
  for (x in pf) {
    i <- match(sub("\\.lpd$", "", basename(x)), ds$dataSetName)
    if (is.na(i)) stop("patch file is not a dataset of the pool: ", basename(x))
    ux <- tempfile("patch"); utils::unzip(x, exdir = ux)
    id <- jsonlite::read_json(list.files(ux, "metadata\\.jsonld$", recursive = TRUE, full.names = TRUE)[1])$datasetId
    if (!identical(id, ds$datasetId[i])) stop("patch file ", basename(x), " has datasetId ", id, ", not ", ds$datasetId[i])
    md5x <- unname(tools::md5sum(x))
    patched[[length(patched) + 1]] <- list(dataSetName = ds$dataSetName[i], datasetId = id,
                                           export_md5 = ds$file_md5[i], md5 = md5x)
    f[i] <- x; ds$file_md5[i] <- md5x
  }
  message("patched: ", paste(vapply(patched, `[[`, "", "dataSetName"), collapse = ", "))
}

duckdb::duckdb_register(con, "ds_tmp", data.frame(datasetId = ds$datasetId))
axes <- dbGetQuery(con, "SELECT TSid FROM timeseries JOIN ds_tmp USING (datasetId)
                         WHERE tableType = 'paleo' AND tableKind = 'measurement' AND isAxis")$TSid
keep <- unique(c(p$TSid, axes))

work <- tempfile("bundle"); dir.create(file.path(work, "src"), recursive = TRUE)
invisible(file.copy(f, file.path(work, "src")))
writeLines(keep, file.path(work, "keep.txt"))
writeLines(p$TSid, file.path(work, "records.txt"))
name <- sprintf("presto-pool-%s-%s", pool, snap)
out <- file.path(work, name)
res <- system2("python3", c("-I", shQuote(file.path(here, "trim_lpd.py")), shQuote(file.path(work, "keep.txt")),
                            shQuote(file.path(work, "src")), shQuote(out),
                            "--mask-codes", shQuote(file.path(work, "records.txt")), "--fix-ad-axes"), stdout = TRUE)
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
  codes_masked = r$codes_masked, axes_renamed = r$axes_renamed, patched = patched,
  bundle = list(file = basename(zip), sha256 = sha(zip), bytes = file.size(zip)),
  TSIDs = p$TSid,
  sources = lapply(seq_len(nrow(ds)), function(i) list(dataSetName = ds$dataSetName[i],
                                                         datasetId = ds$datasetId[i], md5 = ds$file_md5[i])))
write_json(manifest, file.path(bdir, paste0(name, ".json")), auto_unbox = TRUE, pretty = TRUE)
if (length(r$axes_renamed)) message("age axes in years AD renamed to year: ",
  paste(unique(r$axes_renamed$dataSetName), collapse = "; "))
if (length(r$codes_masked)) message("missing-value codes set to NaN: ",
  paste(sprintf("%s %s (%d)", r$codes_masked$dataSetName, r$codes_masked$TSid, r$codes_masked$n), collapse = "; "))
cat(sprintf("%s: %d records, %d datasets, %d columns dropped, %.1f MB, sha256 %s\n",
            name, nrow(p), nrow(ds), r$columns_dropped, file.size(zip) / 1e6, manifest$bundle$sha256))
