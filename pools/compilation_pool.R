#!/usr/bin/env Rscript
#
# Make a pool from a published LiPDverse compilation version, so a
# reconstruction starts from the compilation rather than from the recipe.
#
#   Rscript pools/compilation_pool.R <export_dir> <compilation> <version> <metrics_pool>
#
# e.g. ~/lipdverse-export/_database/2026-10-15b PReSto2k 0_0_1 cfr_annual.
# Membership is read only from the export (compilations table: rows of the
# compilation with inThisCompilation and the version in compilationVersions);
# nothing in the recipe can add or remove a record. The metrics pool's
# config is used only to compute each member's metrics on this export
# (resolution, lag-1 and the rest, which method-specific screens read).
#
# Writes pools/output/<compilation>_<version>/<snapshot>/:
#   pool.csv    one row per member, in build_pools.R's format (dedup_keep
#               TRUE for all), with recipe_selected: whether the recipe's
#               criteria alone would select the record on this export
#   tsids.json  {"TSIDs": [...]}
# so screen_pool.R, screened_pool.R and build_bundle.R take it unchanged.

suppressPackageStartupMessages({library(DBI); library(duckdb); library(yaml); library(jsonlite)})
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
for (f in list.files(file.path(here, "R"), full.names = TRUE)) source(f)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("usage: compilation_pool.R <export_dir> <compilation> <version> <metrics_pool>")
comp <- args[2]; ver <- args[3]
con <- pool_snapshot(path.expand(args[1]))
snap <- attr(con, "snapshot")

m <- dbGetQuery(con, "SELECT TSid, datasetId, compilationVersions FROM compilations
                      WHERE compilation = ? AND inThisCompilation", params = list(comp))
m <- m[vapply(strsplit(m$compilationVersions, "[,; ]+"), function(v) ver %in% v, FALSE), ]
if (!nrow(m)) stop("no members of ", comp, " ", ver, " in the ", snap, " export")
if (anyDuplicated(m$TSid)) stop("duplicate member TSids in ", comp, " ", ver)

cfg <- read_yaml(file.path(here, "config", paste0(args[4], ".yml")))
cfg$.dir <- here
x <- build_pool(con, cfg)
miss <- setdiff(m$TSid, x$TSid)
if (length(miss)) stop(length(miss), " members are not candidates of ", args[4],
                       " on this export (no metrics), e.g. ", paste(head(miss, 5), collapse = ", "))
p <- x[match(m$TSid, x$TSid), ]
p$recipe_selected <- p$selected
p$selected <- TRUE
p$selected_by <- sprintf("compilation %s %s", comp, ver)
p$dedup_keep <- TRUE
p$dedup_rule <- NA_character_

name <- paste(comp, ver, sep = "_")
out <- file.path(here, "output", name, snap); dir.create(out, recursive = TRUE, showWarnings = FALSE)
write.csv(p, file.path(out, "pool.csv"), row.names = FALSE)
write_json(list(TSIDs = p$TSid, snapshot = snap, compilation = comp, version = ver),
           file.path(out, "tsids.json"), auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("%s: %d records in %d datasets from %s %s (%s export); %d would not be selected by %s's criteria alone on this export\n",
            name, nrow(p), length(unique(p$datasetId)), comp, ver, snap, sum(!p$recipe_selected), args[4]))
if (any(!p$recipe_selected)) print(table(unlist(strsplit(p$fails[!p$recipe_selected], ";"))))
