#!/usr/bin/env Rscript
# Review-site data for Presto compilation members.
#   Rscript pools/review/extract.R <export_dir> <out.json> [TSid ...]   (no TSids: all members)
suppressPackageStartupMessages({library(DBI); library(duckdb); library(jsonlite)})
rec_dir <- normalizePath(file.path(dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)))), ".."))
for (f in list.files(file.path(rec_dir, "R"), full.names = TRUE)) source(f)
args <- commandArgs(trailingOnly = TRUE)
con <- pool_snapshot(args[1]); snap <- attr(con, "snapshot")
want <- args[-(1:2)]

comps <- list(
  Presto2k = list(dir = "PReSto2k", pool = "PReSto2k_0_1_0",
                  psm = "~/GitHub/presto-paper/analysis/data/runs/presto-LMR-run-presto2k-0_1_0/psm_screen.csv"),
  Presto12k = list(dir = "PReSto12k", pool = "PReSto12k_0_1_0", psm = NA))

num <- function(x, d = 3) if (is.null(x) || length(x) == 0 || is.na(x)) NULL else round(as.numeric(x), d)
chr <- function(x) if (is.null(x) || length(x) == 0 || is.na(x) || x == "") NULL else as.character(x)
hav <- function(lat1, lon1, lat2, lon2) {
  r <- pi / 180; a <- sin((lat2 - lat1) * r / 2)^2 + cos(lat1 * r) * cos(lat2 * r) * sin((lon2 - lon1) * r / 2)^2
  6371 * 2 * asin(pmin(1, sqrt(a)))
}

all_recs <- list(); members_all <- list()
for (cn in names(comps)) {
  cc <- comps[[cn]]
  cdir <- file.path(rec_dir, "compilations", cc$dir, "0_1_0")
  mem <- read.csv(file.path(cdir, "members.csv"), stringsAsFactors = FALSE)
  dec <- read.csv(file.path(cdir, "decisions.csv"), stringsAsFactors = FALSE)
  qc <- read.csv(file.path(cdir, "qc_comments.csv"), stringsAsFactors = FALSE)
  pool <- read.csv(list.files(file.path(rec_dir, "output", cc$pool), "pool.csv", recursive = TRUE, full.names = TRUE)[1],
                   stringsAsFactors = FALSE)
  pool <- pool[!duplicated(pool$TSid), ]
  scr <- file.path(dirname(list.files(file.path(rec_dir, "output", cc$pool), "pool.csv", recursive = TRUE, full.names = TRUE)[1]),
                   "screen_local_temperature_interp.csv")
  scr <- if (file.exists(scr)) read.csv(scr, stringsAsFactors = FALSE) else NULL
  psm <- if (!is.na(cc$psm)) read.csv(path.expand(cc$psm), stringsAsFactors = FALSE) else NULL
  mp <- pool[match(mem$TSid, pool$TSid), ]
  members <- data.frame(TSid = mem$TSid, lat = mp$lat, lon = mp$lon, archive = mem$archiveType,
                        variable = mem$variableName, name = mem$dataSetName, stringsAsFactors = FALSE)
  members_all[[cn]] <- members
  ids <- if (length(want)) intersect(want, mem$TSid) else mem$TSid
  if (!length(ids)) next
  q <- paste0("'", ids, "'", collapse = ",")
  interp <- dbGetQuery(con, sprintf("SELECT * FROM interpretations WHERE TSid IN (%s) ORDER BY TSid, rank", q))
  ts <- dbGetQuery(con, sprintf("SELECT TSid, description, calibrationMethod, pages2kID, iso2kUI, medianResolution FROM timeseries WHERE TSid IN (%s)", q))
  comp <- dbGetQuery(con, sprintf("SELECT TSid, compilation, compilationVersion FROM compilations WHERE inThisCompilation AND TSid IN (%s)", q))
  dsids <- unique(pool$datasetId[pool$TSid %in% ids])
  pubs <- dbGetQuery(con, sprintf("SELECT * FROM publications WHERE datasetId IN (%s) ORDER BY datasetId, pubIndex",
                                  paste0("'", dsids, "'", collapse = ",")))
  pts <- pool_points(con, pool[pool$TSid %in% ids, ])
  for (t in ids) {
    r <- pool[pool$TSid == t, ]
    p <- pts[pts$TSid == t, ]; p <- p[order(p$year), ]
    others <- members[members$TSid != t & is.finite(members$lat), ]
    d <- hav(r$lat, r$lon, others$lat, others$lon)
    o <- order(d)[1:min(8, nrow(others))]
    nb <- lapply(o, function(i) list(TSid = others$TSid[i], name = others$name[i], archive = others$archive[i],
                                     variable = others$variable[i], lat = others$lat[i], lon = others$lon[i], km = round(d[i])))
    it <- interp[interp$TSid == t, ]
    pb <- pubs[pubs$datasetId == r$datasetId, ]
    dd <- dec[dec$TSid == t | dec$partner_TSid %in% t, ]
    crit <- grep("^pass_", names(r), value = TRUE)
    ps <- if (!is.null(psm)) psm[psm$pid == t, ] else NULL
    sc <- if (!is.null(scr)) scr[scr$TSid == t, ] else NULL
    all_recs[[length(all_recs) + 1]] <- list(
      compilation = cn, TSid = t, datasetId = r$datasetId, dataSetName = r$dataSetName, siteName = chr(r$siteName),
      datasetVersion = chr(r$datasetVersion), archive = r$archiveType, variable = r$variableName, units = chr(r$units),
      proxy = chr(r$proxy), proxyGeneral = chr(r$proxyGeneral), description = chr(ts$description[ts$TSid == t][1]),
      calibrationMethod = chr(ts$calibrationMethod[ts$TSid == t][1]),
      lat = num(r$lat, 4), lon = num(r$lon, 4), elev = num(r$elev, 0),
      start = num(r$min_win, 1), end = num(r$max_win, 1), n = r$n_win, resolution = num(r$res_win, 2),
      lag1 = num(r$lag1_win, 2), repeatFrac = num(r$repeat_win, 2), nCalib = num(r$n_calib, 0),
      selectedBy = r$selected_by, fails = chr(r$fails), dedupRule = chr(r$dedup_rule),
      criteria = setNames(lapply(crit, function(k) r[[k]]), sub("^pass_", "", crit)),
      compilations = unique(paste(comp$compilation[comp$TSid == t])),
      interpretations = lapply(seq_len(nrow(it)), function(i) list(rank = it$rank[i], scope = chr(it$scope[i]),
        variable = chr(it$variable[i]), detail = chr(it$variableDetail[i]), direction = chr(it$direction[i]),
        seasonality = chr(it$seasonality[i]), basis = chr(it$basis[i]))),
      publications = lapply(seq_len(min(3, nrow(pb))), function(i) list(authors = substr(pb$authors[i] %||% "", 1, 160),
        year = chr(pb$year[i]), title = chr(pb$title[i]), journal = chr(pb$journal[i]), doi = chr(pb$doi[i]))),
      decisions = lapply(seq_len(nrow(dd)), function(i) as.list(dd[i, ])),
      qc = chr(qc$QCComments[qc$TSid == t][1]),
      psm = if (!is.null(ps) && nrow(ps)) list(status = ps$status[1], ptype = ps$ptype[1], vars = ps$psm_vars[1],
        detail = chr(ps$detail[1]), r2adj = num(ps$fitR2adj[1]), slopeT = num(ps$slope_tas[1], 4)) else NULL,
      localScreen = if (!is.null(sc) && nrow(sc)) list(r = num(sc$r_fdr10[1]), p = num(sc$p_fdr10[1], 4),
        pass = sc$pass_fdr10[1], n = sc$n_overlap[1]) else NULL,
      neighbors = nb,
      series = list(year = round(p$year, 2), value = signif(p$value, 5)))
  }
}
members <- do.call(rbind, lapply(names(members_all), function(cn) cbind(compilation = cn, members_all[[cn]])))
out <- list(snapshot = snap, built = format(Sys.time(), "%Y-%m-%d"), records = all_recs,
            members = lapply(split(members, members$compilation), function(m)
              list(TSid = m$TSid, lat = round(m$lat, 2), lon = round(m$lon, 2), archive = m$archive)))
write_json(out, args[2], auto_unbox = TRUE, null = "null", na = "null", digits = NA)
cat("wrote", length(all_recs), "records to", args[2], "\n")
