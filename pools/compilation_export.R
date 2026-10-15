#!/usr/bin/env Rscript
#
# Export a pool as a LiPDverse compilation: its membership, and every
# decision behind it that the pool's rules alone would not reproduce.
#
#   Rscript pools/compilation_export.R <pool> <compilation> <snapshot>
#
# e.g. cfr_annual -> PReSto2k, temp12k -> PReSto12k. presto-recipes computes
# membership; LiPDverse stores it as compilation tags and versions. The
# compilation must never be an input to a pool's criteria (a pool that
# selected on its own tag would select itself).
#
# Writes pools/compilations/<compilation>/<snapshot>/:
#   members.csv    one row per member record (the pool's dedup_keep rows,
#                  i.e. exactly the records in the pool's bundle)
#   decisions.csv  one row per non-automatic or deduplication decision:
#     admission       admitted by a curator ledger despite failing a criterion
#     exception       kept by a pool's data-poor exception
#     exclusion       excluded by PReSto (baselines/presto_exclusions.csv)
#     dedup_manual    a reviewed duplicate pair (baselines/dedup_decisions.csv)
#     dedup_prior     a pair decided by an earlier compilation (dedup_prior.csv)
#     dedup_auto      a cross-dataset duplicate dropped by rule
#     dedup_rule      dropped by a same-site or annual-preferred rule (no partner)
#     review_pending  a flagged pair that still needs a curator
#   Columns: kind, TSid, dataSetName, in_compilation, partner_TSid,
#   partner_dataSetName, rule, source, note.
#   qc_comments.csv one row per record with a decision: TSid, in_compilation,
#                  QCComments (the decisions as one sentence each), for the
#                  compilation's QC sheet.

here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop("usage: compilation_export.R <pool> <compilation> <snapshot>")
pool <- args[1]; comp <- args[2]; snap <- args[3]
rd <- function(...) utils::read.csv(file.path(here, ...), stringsAsFactors = FALSE)

p <- rd("output", pool, snap, "pool.csv")
pairs <- rd("output", pool, snap, "dedup_pairs.csv")
mem <- p[p$dedup_keep %in% TRUE, ]
nm <- setNames(p$dataSetName, p$TSid)

row <- function(kind, TSid, partner = NA, rule = NA, source = NA, note = NA)
  if (length(TSid)) data.frame(kind = kind, TSid = TSid, dataSetName = unname(nm[as.character(TSid)]),
                               in_compilation = TSid %in% mem$TSid, partner_TSid = partner,
                               partner_dataSetName = unname(nm[as.character(partner)]), rule = rule,
                               source = source, note = note, stringsAsFactors = FALSE)

# A pair is listed from the dropped record's side (or both, when both are kept).
pair_rows <- function(d, kind, note = NA) {
  if (!nrow(d)) return(NULL)
  # Only pairs with both records in this pool are decisions about it.
  d <- d[d$TSid1 %in% p$TSid & d$TSid2 %in% p$TSid & d$TSid1 != d$TSid2, , drop = FALSE]
  rbind(row(kind, d$TSid1, d$TSid2, ifelse(d$keep1, "kept", "dropped"), d$source, if (is.null(d$note)) note else d$note),
        row(kind, d$TSid2, d$TSid1, ifelse(d$keep2, "kept", "dropped"), d$source, if (is.null(d$note)) note else d$note))
}

man <- rd("baselines", "dedup_decisions.csv")
prior <- unique(rd("baselines", "dedup_prior.csv"))
excl <- rd("baselines", "presto_exclusions.csv"); excl <- excl[excl$pool == pool, ]
adm <- rd("baselines", "curator_admissions.csv"); adm <- adm[adm$pool == pool, ]

key <- function(a, b) paste(pmin(a, b), pmax(a, b))
decided <- c(key(man$TSid1, man$TSid2), key(prior$TSid1, prior$TSid2))
dup <- pairs[pairs$duplicate %in% TRUE, ]
auto <- dup[!key(dup$TSid1, dup$TSid2) %in% decided & !dup$review %in% TRUE, ]
auto_drop <- rbind(data.frame(t = auto$TSid1[!auto$keep1 %in% TRUE], o = auto$TSid2[!auto$keep1 %in% TRUE], r = auto$rule[!auto$keep1 %in% TRUE]),
                   data.frame(t = auto$TSid2[!auto$keep2 %in% TRUE], o = auto$TSid1[!auto$keep2 %in% TRUE], r = auto$rule[!auto$keep2 %in% TRUE]))
pend <- pairs[pairs$review %in% TRUE & !key(pairs$TSid1, pairs$TSid2) %in% decided, ]
# Columns collapsed within one dataset are routine and left out.
within <- p[p$dedup_rule %in% c("same-site", "annual-preferred") & !p$dedup_keep %in% TRUE, ]

dec <- rbind(
  row("admission", mem$TSid[mem$selected_by == "curator admission"],
      source = adm$source[match(mem$TSid[mem$selected_by == "curator admission"], adm$TSid)]),
  row("exception", mem$TSid[mem$selected_by == "data-poor exception"], rule = "data-poor exception"),
  row("exclusion", excl$TSid, source = "PReSto", note = excl$source),
  pair_rows(man, "dedup_manual"),
  pair_rows(prior, "dedup_prior"),
  row("dedup_auto", auto_drop$t, auto_drop$o, auto_drop$r),
  row("dedup_rule", within$TSid, rule = within$dedup_rule),
  row("review_pending", c(pend$TSid1, pend$TSid2), c(pend$TSid2, pend$TSid1)))
dec <- dec[!duplicated(dec[, c("kind", "TSid", "partner_TSid")]), ]
# Pairs whose records left the pool for other reasons are not decisions about it.
dec <- dec[dec$TSid %in% p$TSid | dec$kind == "exclusion", ]

out <- file.path(here, "compilations", comp, snap); dir.create(out, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(mem[, c("TSid", "datasetId", "dataSetName", "variableName", "archiveType", "selected_by")],
                 file.path(out, "members.csv"), row.names = FALSE)
utils::write.csv(dec, file.path(out, "decisions.csv"), row.names = FALSE, na = "")
say <- function(d) {
  pr <- ifelse(is.na(d$partner_TSid) | d$partner_TSid == "", "",
               sprintf("%s (%s)", d$partner_dataSetName, d$partner_TSid))
  x <- switch(d$kind,
    admission = sprintf("Admitted by curator ledger (%s) although it fails a criterion.", d$source),
    exception = "Kept by the data-poor exception (no other record nearby).",
    exclusion = sprintf("Excluded by hand: %s", sub("^PReSto: ", "", d$note)),
    dedup_manual = if (isTRUE(d$both_kept)) sprintf("Reviewed against %s: not duplicates, both kept.", pr)
                   else sprintf("Curator-reviewed duplicate of %s: %s.", pr, d$rule),
    dedup_prior = sprintf("Duplicate of %s, decided by %s: %s.", pr, d$source, d$rule),
    dedup_auto = sprintf("Duplicate of %s (%s rule): dropped.", pr, d$rule),
    dedup_rule = sprintf("Dropped by the %s rule (another record from this dataset or site is kept).", d$rule),
    review_pending = sprintf("Possible duplicate of %s: awaiting curator review.", pr))
  if (!is.na(d$note) && d$note != "" && d$kind %in% c("dedup_manual", "dedup_prior"))
    x <- paste0(x, " Note: ", sub("([^.])$", "\\1.", d$note))
  x
}
# A PReSto review supersedes an earlier compilation's decision on the same pair.
pk <- function(a, b) paste(pmin(a, b), pmax(a, b))
rev <- dec$kind == "dedup_manual"
dec <- dec[!(dec$kind == "dedup_prior" & pk(dec$TSid, dec$partner_TSid) %in% pk(dec$TSid, dec$partner_TSid)[rev]), ]
both <- pk(man$TSid1, man$TSid2)[man$keep1 %in% TRUE & man$keep2 %in% TRUE]
dec$both_kept <- dec$kind == "dedup_manual" & pk(dec$TSid, dec$partner_TSid) %in% both
txt <- vapply(seq_len(nrow(dec)), function(i) say(dec[i, ]), "")
qc <- stats::aggregate(list(QCComments = txt), list(TSid = dec$TSid), paste, collapse = " ")
qc$QCComments <- paste("PReSto:", qc$QCComments)
qc$in_compilation <- qc$TSid %in% mem$TSid
utils::write.csv(qc[, c("TSid", "in_compilation", "QCComments")], file.path(out, "qc_comments.csv"), row.names = FALSE)
cat(sprintf("%s (%s, %s): %d members in %d datasets\n", comp, pool, snap, nrow(mem), length(unique(mem$datasetId))))
print(table(dec$kind))
