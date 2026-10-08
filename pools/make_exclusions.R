#!/usr/bin/env Rscript
#
# Build the curator exclusion ledger: records that people who assembled a
# compilation looked at and decided against. Automated criteria cannot see
# most of the reasons (a calibration the authors distrust, an inverse tree-ring
# response, a record superseded in a way the metadata does not say), so a pool
# keeps those decisions rather than re-making them.
#
#   Rscript pools/make_exclusions.R <export_dir> <qcstore_dir> [cache_dir]
#
# Sources, per pool:
#   temp12k      Temperature 12k v1.0.0 records flagged Tverse
#                ("temperature-sensitive records that do not" meet the criteria;
#                Kaufman et al. 2020), plus current Tverse membership
#   pages2k2017  PAGES 2k v2.0.0 records with useInGlobalTemperatureAnalysis
#                FALSE, plus inThisCompilation FALSE on the current QC sheet
# A record now admitted to the same compilation overrides an old exclusion.
# Exclusions are by TSid: a new dataset, or a new record in a new version of
# a dataset, is not blocked.
#
# Writes pools/baselines/curator_exclusions.csv (TSid, pool, source).

suppressPackageStartupMessages({library(DBI); library(duckdb)})

here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: make_exclusions.R <export_dir> <qcstore_dir> [cache_dir]")
export <- path.expand(args[1]); qcstore <- path.expand(args[2])
cache <- if (length(args) > 2) path.expand(args[3]) else file.path(tempdir(), "presto-releases")
dir.create(cache, showWarnings = FALSE, recursive = TRUE)

release_ts <- function(url, name) {
  rds <- file.path(cache, paste0(name, ".rds"))
  if (file.exists(rds)) return(readRDS(rds))
  zip <- file.path(cache, paste0(name, ".zip"))
  # lipdverse.org serves an incomplete certificate chain (handoff 2026-10-06).
  if (!file.exists(zip)) system2("curl", c("-sk", "-o", shQuote(zip), shQuote(url)))
  d <- file.path(cache, name); utils::unzip(zip, exdir = d)
  lpd <- list.files(d, pattern = "\\.lpd$", recursive = TRUE, full.names = TRUE)
  lpd <- lpd[!grepl("__MACOSX", lpd)]
  L <- suppressWarnings(suppressMessages(lipdR::readLipd(dirname(lpd[1]))))
  ts <- lipdR::ts2tibble(lipdR::extractTs(L))
  saveRDS(ts, rds)
  ts
}

con <- dbConnect(duckdb(shared_home = FALSE), dbdir = file.path(export, "lipdverse.duckdb"), read_only = TRUE)
member <- function(comp) dbGetQuery(con, sprintf(
  "SELECT DISTINCT TSid FROM compilations WHERE compilation = '%s' AND inThisCompilation", comp))$TSid

out <- list()

t100 <- release_ts("https://lipdverse.org/Temp12k/1_0_0/Temp12k1_0_0.zip", "temp12k_1_0_0")
tv <- t100$paleoData_TSid[grepl("tverse", tolower(as.character(t100$paleoData_inCompilation)))]
out[[1]] <- data.frame(TSid = tv, pool = "temp12k", source = "Temp12k v1.0.0 Tverse")
out[[2]] <- data.frame(TSid = member("Tverse"), pool = "temp12k", source = "Tverse (current)")

p200 <- release_ts("https://lipdverse.org/Pages2kTemperature/2_0_0/PAGES2k_v2.0.0_LiPD.zip", "pages2k_2_0_0")
no <- p200$paleoData_TSid[as.character(p200$paleoData_useInGlobalTemperatureAnalysis) %in% c("FALSE", "false")]
out[[3]] <- data.frame(TSid = no, pool = "pages2k2017", source = "PAGES2k v2.0.0 useInGlobalTemperatureAnalysis FALSE")
qc <- utils::read.csv(gzfile(file.path(qcstore, "snapshots/Pages2kTemperature/QC.csv.gz")), stringsAsFactors = FALSE)
out[[4]] <- data.frame(TSid = qc$TSid[qc$inThisCompilation %in% "FALSE"], pool = "pages2k2017",
                       source = "Pages2kTemperature QC inThisCompilation FALSE")

x <- do.call(rbind, out)
x <- x[!is.na(x$TSid) & nzchar(x$TSid), ]
# Re-admitted since: a curator's later yes outranks an earlier no. PAGES 2k
# re-admissions come from the QC sheet, not the export: the export stamps
# Pages2kTemperature membership on every column of a member dataset (EPS,
# sampleCount, ...; 2,885 TSids against the sheet's 691), which would re-admit
# nearly everything.
readmit <- list(temp12k = member("Temp12k"),
                pages2k2017 = qc$TSid[qc$inThisCompilation %in% "TRUE"])
x <- x[!mapply(function(t, p) t %in% readmit[[p]], x$TSid, x$pool), ]
x <- x[!duplicated(x[c("TSid", "pool")]), ]
utils::write.csv(x, file.path(here, "baselines", "curator_exclusions.csv"), row.names = FALSE)
print(table(x$pool, x$source))
dbDisconnect(con, shutdown = TRUE)
