#!/usr/bin/env Rscript
#
# Fold the duplicate review page's decisions into baselines/dedup_decisions.csv.
#
#   Rscript pools/import_decisions.R <dir of decision .json files>
#
# The JSON files are the page's `decisions` collection as saved by the
# ArtifactData tool (list, out_dir), one document per pair:
#   {choice: "a" | "b" | "both", tsidA, tsidB, note, at, ...}
# Each becomes one row (TSid1 = tsidA, TSid2 = tsidB, keep1, keep2,
# decision_type = MANUAL, source = "PReSto review <date>", note), replacing an
# earlier row for the same pair. build_pools.R reads this file before the
# DoD2k log, so these decisions win.

`%||%` <- function(a, b) if (is.null(a)) b else a
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
files <- list.files(commandArgs(trailingOnly = TRUE)[1], pattern = "\\.json$", recursive = TRUE, full.names = TRUE)
new <- do.call(rbind, lapply(files, function(f) {
  d <- jsonlite::read_json(f)
  d <- if (!is.null(d$data)) d$data else d
  if (!d$choice %in% c("a", "b", "both")) stop("unknown choice in ", f)
  data.frame(TSid1 = d$tsidA, TSid2 = d$tsidB, keep1 = d$choice %in% c("a", "both"),
             keep2 = d$choice %in% c("b", "both"), decision_type = "MANUAL",
             source = paste("PReSto review", substr(d$at %||% "", 1, 10)), note = d$note %||% "")
}))
out <- file.path(here, "baselines", "dedup_decisions.csv")
old <- if (file.exists(out)) utils::read.csv(out, stringsAsFactors = FALSE) else new[0, ]
key <- function(x) paste(pmin(x$TSid1, x$TSid2), pmax(x$TSid1, x$TSid2))
old <- old[!key(old) %in% key(new), ]
utils::write.csv(rbind(new, old), out, row.names = FALSE)
message(nrow(new), " decisions imported; ", nrow(new) + nrow(old), " in ", out)
