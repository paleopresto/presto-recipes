#!/usr/bin/env Rscript
#
# The dedup review queue as JSON for the review page: each pair's two series
# and the metadata a curator needs to choose between them.
#
#   Rscript pools/review_data.R <export_dir> <pool> <out.json>
#
# Reads pools/output/<pool>/<snapshot>/dedup_review.csv. Decisions made on the
# page are exported to pools/baselines/dedup_decisions.csv.

suppressPackageStartupMessages({library(DBI); library(duckdb); library(jsonlite)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
for (f in list.files(file.path(here, "R"), full.names = TRUE)) source(f)
args <- commandArgs(trailingOnly = TRUE)
con <- pool_snapshot(args[1]); snap <- attr(con, "snapshot")
out <- file.path(here, "output", args[2], snap)
rv <- read.csv(file.path(out, "dedup_review.csv"), stringsAsFactors = FALSE)
pool <- read.csv(file.path(out, "pool.csv"), stringsAsFactors = FALSE)
ids <- unique(c(rv$TSid1, rv$TSid2)); q <- paste0("'", ids, "'", collapse = ",")
cfg <- yaml::read_yaml(file.path(here, "config", paste0(args[2], ".yml")))
opt <- utils::modifyList(dedup_defaults, cfg$dedup %||% list())

pts <- pool_points(con, pool[pool$TSid %in% ids, ])
comp <- dbGetQuery(con, sprintf("SELECT TSid, compilation FROM compilations WHERE inThisCompilation AND TSid IN (%s)", q))
pubs <- dbGetQuery(con, "SELECT datasetId, authors, year, title, doi FROM publications")
interp <- dbGetQuery(con, sprintf("SELECT TSid, scope, variable, direction, seasonality FROM interpretations
                                   WHERE variable IS NOT NULL AND TSid IN (%s)", q))
pubyear <- tapply(pubs$year, pubs$datasetId, function(y) suppressWarnings(max(as.numeric(y), na.rm = TRUE)))
im <- table(interp$TSid)
pref <- preference(pool[pool$TSid %in% ids, ], comp, pubyear, opt, stats::setNames(as.numeric(im) * 3, names(im)))

rec <- function(t) {
  r <- pool[pool$TSid == t, ][1, ]; p <- pts[pts$TSid == t, ]; p <- p[order(p$year), ]
  pb <- pubs[pubs$datasetId == r$datasetId, ]
  it <- interp[interp$TSid == t, ]
  list(TSid = t, dataSetName = r$dataSetName, variableName = r$variableName, units = r$units,
       archiveType = r$archiveType, lat = r$lat, lon = r$lon,
       start = round(r$min_win, 1), end = round(r$max_win, 1), n = r$n_win, resolution = round(r$res_win, 2),
       compilations = sort(unique(comp$compilation[comp$TSid == t])),
       publications = lapply(seq_len(nrow(pb)), function(i) list(authors = substr(pb$authors[i] %||% "", 1, 120),
                             year = pb$year[i], title = pb$title[i], doi = pb$doi[i])),
       interpretations = lapply(seq_len(nrow(it)), function(i) list(scope = it$scope[i], variable = it$variable[i],
                                direction = it$direction[i], seasonality = it$seasonality[i])),
       year = round(p$year, 3), value = signif(p$value, 6))
}
pairs <- lapply(seq_len(nrow(rv)), function(k) {
  a <- rv$TSid1[k]; b <- rv$TSid2[k]
  w <- prefer(pref[pref$TSid == a, ], pref[pref$TSid == b, ], opt)
  list(key = paste(sort(c(a, b)), collapse = "__"), km = round(rv$km[k], 1), n = rv$n[k],
       r = round(rv$r[k], 3), r_diff = round(rv$r_diff[k], 3), same_doi = isTRUE(rv$same_doi[k]),
       suggest = if (w == 1L) "a" else "b", a = rec(a), b = rec(b))
})
write_json(list(pool = args[2], snapshot = snap, built = format(Sys.time(), "%Y-%m-%d"), pairs = pairs),
           args[3], auto_unbox = TRUE, digits = NA, null = "null", na = "null")
message(length(pairs), " pairs -> ", args[3])
