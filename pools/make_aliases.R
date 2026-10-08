#!/usr/bin/env Rscript
#
# Find where baseline records went. A baseline TSid can disappear from
# LiPDverse when its dataset is renamed, merged into another, or retired as a
# duplicate, or be reassigned to another column; the record usually still
# exists under another TSid. Each missing TSid is matched by its values to a
# current column at the same site (same coordinates within ~1 km, or a dataset
# name that matches ignoring case).
#
#   Rscript pools/make_aliases.R <export_dir> [cache_dir]
#
# cache_dir holds the release TS tables make_ledgers.R caches
# (temp12k_1_0_0.rds, pages2k_2_0_0.rds). Writes pools/baselines/aliases.csv
# (baseline, oldTSid, TSid, score).

suppressPackageStartupMessages({library(DBI); library(duckdb)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
cache <- if (length(args) > 1) path.expand(args[2]) else file.path(tempdir(), "presto-releases")
con <- dbConnect(duckdb(shared_home = FALSE), dbdir = file.path(path.expand(args[1]), "lipdverse.duckdb"), read_only = TRUE)

lv <- dbGetQuery(con, "
  SELECT t.TSid, d.dataSetName, d.geo_latitude lat, d.geo_longitude lon
  FROM timeseries t JOIN datasets d USING (datasetId)
  WHERE t.tableType = 'paleo' AND t.tableKind = 'measurement' AND NOT coalesce(t.isAxis, false)")
# A TSid that now names an axis column has been reassigned (the record it
# named is elsewhere), so it is followed like a missing one.
present <- dbGetQuery(con, "SELECT TSid FROM timeseries WHERE NOT coalesce(isAxis, false)")$TSid

values_of <- function(tsids) {
  duckdb::duckdb_register(con, "q_tmp", data.frame(TSid = tsids))
  on.exit(duckdb::duckdb_unregister(con, "q_tmp"))
  v <- dbGetQuery(con, "SELECT TSid, value_num FROM \"values\" JOIN q_tmp USING (TSid) WHERE value_num IS NOT NULL")
  split(v$value_num, v$TSid)
}

out <- list()
for (b in c("temp12k_1_0_0", "pages2k_2_0_0")) {
  base <- utils::read.csv(file.path(here, "baselines", paste0(b, ".csv")), stringsAsFactors = FALSE)
  rel <- readRDS(file.path(cache, paste0(b, ".rds")))
  for (old in setdiff(base$TSid, present)) {
    r <- rel[rel$paleoData_TSid %in% old, ][1, ]
    dv <- suppressWarnings(as.numeric(unlist(r$paleoData_values)))
    dv <- round(dv[is.finite(dv)], 3)
    lat <- suppressWarnings(as.numeric(r$geo_latitude)); lon <- suppressWarnings(as.numeric(r$geo_longitude))
    near <- !is.na(lv$lat) & abs(lv$lat - lat) < 0.01 & abs(lv$lon - lon) < 0.015
    cand <- lv$TSid[near | tolower(lv$dataSetName) == tolower(r$dataSetName)]
    best <- NA_character_; score <- NA_real_
    if (length(cand) && length(dv)) {
      s <- vapply(values_of(cand), function(v) mean(dv %in% round(v, 3)), 0)
      if (length(s) && max(s) >= 0.95) { best <- names(s)[which.max(s)]; score <- max(s) }
    }
    out[[length(out) + 1L]] <- data.frame(baseline = b, oldTSid = old, TSid = best, score = score)
  }
}
x <- do.call(rbind, out)
utils::write.csv(x, file.path(here, "baselines", "aliases.csv"), row.names = FALSE)
print(x)
