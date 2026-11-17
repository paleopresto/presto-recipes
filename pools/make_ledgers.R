#!/usr/bin/env Rscript
#
# Build the curator ledgers: records that people who assembled a compilation
# looked at and decided for (admissions) or against (exclusions). Automated criteria cannot see
# most of the reasons (a calibration the authors distrust, an inverse tree-ring
# response, a record superseded in a way the metadata does not say), so a pool
# keeps those decisions rather than re-making them.
#
#   Rscript pools/make_ledgers.R <export_dir> <qcstore_dir> [cache_dir]
#
# Sources, per pool:
#   temp12k      Temperature 12k v1.0.0 records flagged Tverse
#                ("temperature-sensitive records that do not" meet the criteria;
#                Kaufman et al. 2020), plus current Tverse membership
#   pages2k2017  PAGES 2k v2.0.0 records with useInGlobalTemperatureAnalysis
#                FALSE, plus inThisCompilation FALSE on the current QC sheet
#   cfr_annual   PReSto2k (2025)'s duplicate removals
#   any          baselines/presto_exclusions.csv, PReSto's own decisions
# A record now admitted to the same compilation overrides an old exclusion.
# Exclusions are by TSid: a new dataset, or a new record in a new version of
# a dataset, is not blocked.
#
# Admissions, per pool, are the compilation itself: Temperature 12k v1.0.0
# and current Temp12k membership; PAGES 2k v2.0.0 and inThisCompilation TRUE
# on the current QC sheet. Baseline TSids that no longer exist are followed to
# their current TSid through baselines/aliases.csv (make_aliases.R).
#
# Writes pools/baselines/curator_exclusions.csv and curator_admissions.csv
# (TSid, pool, source).

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
  "SELECT DISTINCT TSid FROM compilations WHERE lower(compilation) = lower('%s') AND inThisCompilation", comp))$TSid

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

# cfr_annual: PReSto2k's duplicate removals (Gondhalekar et al., presto2k
# data/flagged_tsids_with_notes.csv, each with its reason).
fl <- utils::read.csv(file.path(here, "baselines", "presto2k_2025_flagged.csv"), stringsAsFactors = FALSE)
out[[5]] <- data.frame(TSid = fl$TSID, pool = "cfr_annual", source = "PReSto2k (2025) duplicate removal")

# Decisions made for PReSto itself, kept by hand (TSid, pool, source).
out[[6]] <- utils::read.csv(file.path(here, "baselines", "presto_exclusions.csv"), stringsAsFactors = FALSE)

x <- do.call(rbind, out)
x <- x[!is.na(x$TSid) & nzchar(x$TSid), ]
# Re-admitted since: a curator's later yes outranks an earlier no. PAGES 2k
# re-admissions come from the QC sheet, not the export: the export stamps
# Pages2kTemperature membership on every column of a member dataset (EPS,
# sampleCount, ...; 2,885 TSids against the sheet's 691), which would re-admit
# nearly everything.
readmit <- list(temp12k = member("Temp12k"),
                pages2k2017 = qc$TSid[qc$inThisCompilation %in% "TRUE"],
                cfr_annual = character())
x <- x[!mapply(function(t, p) t %in% readmit[[p]], x$TSid, x$pool), ]
x <- x[!duplicated(x[c("TSid", "pool")]), ]
utils::write.csv(x, file.path(here, "baselines", "curator_exclusions.csv"), row.names = FALSE)
print(table(x$pool, x$source))

al <- utils::read.csv(file.path(here, "baselines", "aliases.csv"), stringsAsFactors = FALSE)
follow <- function(t) { a <- al$TSid[match(t, al$oldTSid)]; ifelse(is.na(a), t, a) }
present <- dbGetQuery(con, "SELECT TSid FROM timeseries")$TSid
base <- function(f) utils::read.csv(file.path(here, "baselines", f), stringsAsFactors = FALSE)$TSid
ad <- rbind(
  data.frame(TSid = follow(base("temp12k_1_0_0.csv")), pool = "temp12k", source = "Temp12k v1.0.0"),
  data.frame(TSid = member("Temp12k"), pool = "temp12k", source = "Temp12k (current)"),
  data.frame(TSid = follow(base("pages2k_2_0_0.csv")), pool = "pages2k2017", source = "PAGES2k v2.0.0"),
  data.frame(TSid = qc$TSid[qc$inThisCompilation %in% "TRUE"], pool = "pages2k2017",
             source = "Pages2kTemperature QC inThisCompilation TRUE"),
  data.frame(TSid = base("presto2k_2025.csv"), pool = "cfr_annual", source = "PReSto2k (2025) proxy database"))
ad <- ad[ad$TSid %in% present, ]
# A TSid can be reused: PAGES 2k v2.0.0's LPDb17a5e9e (RAPiD-12-1K) and
# LPD9cc3baf6 (Gulf of Guinea) are now GreatBasin.Salzer.2014's
# uncertaintyLow column and Turkana.Berke.2012, while the records themselves
# carry -dup TSids. An admission from a baseline with coordinates stands only
# if the export's record is within 100 km or has the same dataset name.
# (Agassiz.Lecavalier.2017 is 4,753 km off but keeps its name.)
here_ts <- dbGetQuery(con, "SELECT t.TSid, d.dataSetName, d.geo_latitude AS lat, d.geo_longitude AS lon
                             FROM timeseries t JOIN datasets d USING (datasetId)")
nm <- function(x) gsub("[^a-z0-9]", "", tolower(sub("^(Ocn|Arc|Ant|Asia|Aus|Eur|NAm|SAm|Afr|Africa|O2kLR|Ocean2kHR)-", "", x)))
same_record <- function(tsid, f) {
  b <- utils::read.csv(file.path(here, "baselines", f), stringsAsFactors = FALSE)
  b$TSid <- follow(b$TSid)
  b <- b[match(tsid, b$TSid), ]; e <- here_ts[match(tsid, here_ts$TSid), ]
  r <- pi / 180
  km <- 2 * 6371 * asin(pmin(1, sqrt(sin((e$lat - b$lat) * r / 2)^2 +
          cos(b$lat * r) * cos(e$lat * r) * sin((e$lon - b$lon) * r / 2)^2)))
  is.na(b$TSid) | is.na(km) | km <= 100 | nm(b$dataSetName) == nm(e$dataSetName)
}
srcs <- c("Temp12k v1.0.0" = "temp12k_1_0_0.csv", "PAGES2k v2.0.0" = "pages2k_2_0_0.csv")
for (s in names(srcs)) {
  i <- which(ad$source == s); ok <- same_record(ad$TSid[i], srcs[[s]])
  if (any(!ok)) message("Dropped reused TSids from ", s, ": ", paste(ad$TSid[i][!ok], collapse = ", "))
  ad <- ad[-i[!ok], , drop = FALSE]
}
ad <- ad[!duplicated(ad[c("TSid", "pool")]), ]
utils::write.csv(ad, file.path(here, "baselines", "curator_admissions.csv"), row.names = FALSE)
print(table(ad$pool, ad$source))
dbDisconnect(con, shutdown = TRUE)
