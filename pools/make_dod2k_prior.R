#!/usr/bin/env Rscript
#
# Carry DoD2k's duplicate decisions (Evans et al., 2026) over to LiPDverse
# TSids, so a pair a person already resolved is not resolved again.
#
#   Rscript pools/make_dod2k_prior.R <export_dir> <decisions.csv> <compact_metadata.csv>
#
# Inputs are from github.com/lluecke/dod2k: data/all_merged/dup_detection/
# dup_decisions_all_merged_MNE_25-12-19.csv and
# data/all_merged/all_merged_compact_metadata.csv. DoD2k identifies records by
# its own ids (pages2k_0, iso2k_296); each is matched to a LiPDverse TSid by
# dataSetName and variableName, and by coordinates within 1 km when a name
# matches several. FE23 records have no LiPDverse counterpart and are dropped.
#
# Writes pools/baselines/dedup_prior.csv (TSid1, TSid2, keep1, keep2, decision_type,
# source).

suppressPackageStartupMessages({library(DBI); library(duckdb)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
con <- dbConnect(duckdb(shared_home = FALSE), dbdir = file.path(path.expand(args[1]), "lipdverse.duckdb"), read_only = TRUE)

lines <- readLines(args[2])
dec <- utils::read.csv(text = lines[!grepl('^"?#', lines)], stringsAsFactors = FALSE, check.names = FALSE)
meta <- utils::read.csv(args[3], stringsAsFactors = FALSE)

vals_file <- if (length(args) > 3) args[4] else sub("metadata", "paleoData_values", args[3])
read_wide <- function(f) {
  l <- strsplit(readLines(f)[-1], ",")
  stats::setNames(lapply(l, function(z) suppressWarnings(as.numeric(z[-1]))), vapply(l, `[`, "", 1))
}
dvals <- read_wide(vals_file)

lv <- dbGetQuery(con, "
  SELECT t.TSid, t.datasetId, d.dataSetName, t.variableName, d.geo_latitude lat, d.geo_longitude lon
  FROM timeseries t JOIN datasets d USING (datasetId)
  WHERE t.tableType = 'paleo' AND t.tableKind = 'measurement' AND NOT coalesce(t.isAxis, false)")

values_of <- function(tsids) {
  duckdb::duckdb_register(con, "q_tmp", data.frame(TSid = tsids))
  on.exit(duckdb::duckdb_unregister(con, "q_tmp"))
  v <- dbGetQuery(con, "SELECT TSid, value_num FROM \"values\" JOIN q_tmp USING (TSid) WHERE value_num IS NOT NULL")
  split(v$value_num, v$TSid)
}

# A DoD2k record is the LiPDverse column holding the same numbers: candidates
# are columns of a dataset with the same name or within 1 km, and the match is
# the one containing the most of the DoD2k values (rounded to 3 decimals),
# accepted at 95%. Names alone fail where a dataset has two columns of one
# name (two ring-width chronologies) or DoD2k renamed the variable.
map_id <- function(id) {
  m <- meta[meta$datasetId == id, ][1, ]
  dv <- dvals[[id]]
  if (is.na(m$datasetId) || !length(dv)) return(NA_character_)
  near <- !is.na(lv$lat) & abs(lv$lat - m$geo_meanLat) < 0.01 & abs(lv$lon - m$geo_meanLon) < 0.015
  cand <- lv$TSid[lv$dataSetName == m$dataSetName | near]
  if (!length(cand)) return(NA_character_)
  cv <- values_of(cand)
  d <- round(dv[is.finite(dv)], 3)
  score <- vapply(cv, function(v) mean(d %in% round(v, 3)), 0)
  if (!length(score) || max(score) < 0.95) return(NA_character_)
  names(score)[which.max(score)]
}

ids <- unique(c(dec[["datasetId 1"]], dec[["datasetId 2"]]))
tsid <- stats::setNames(vapply(ids, map_id, ""), ids)
keep <- function(x) ifelse(x == "KEEP", TRUE, ifelse(x == "REMOVE", FALSE, NA))
out <- data.frame(TSid1 = tsid[dec[["datasetId 1"]]], TSid2 = tsid[dec[["datasetId 2"]]],
                  keep1 = keep(dec[["Decision 1"]]), keep2 = keep(dec[["Decision 2"]]),
                  decision_type = sub(":.*", "", dec[["Decision type"]]),
                  source = "DoD2k MNE 2025-12-19", row.names = NULL)
cat(sprintf("%d decisions; %d ids, %d mapped to TSids; %d pairs with both ends mapped\n",
            nrow(dec), length(ids), sum(!is.na(tsid)), sum(!is.na(out$TSid1) & !is.na(out$TSid2))))
print(table(dec[["originalDatabase 1"]][is.na(out$TSid1)]))
out <- out[!is.na(out$TSid1) & !is.na(out$TSid2) & !(is.na(out$keep1) & is.na(out$keep2)), ]
utils::write.csv(out, file.path(here, "baselines", "dedup_prior.csv"), row.names = FALSE)
print(table(out$decision_type))
