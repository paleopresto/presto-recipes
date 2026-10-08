# Duplicate detection and resolution, after DoD2k (Evans et al., 2026, ESSD;
# github.com/lluecke/dod2k, dod2k_utilities/ut_duplicate_search.py).
#
# Detection follows DoD2k's find_duplicates(). A pair of records is a candidate
# when they share archive and proxy and lie within 8 km, and is a duplicate
# when, over more than 10 shared time points,
#   (r > 0.9 or r of first differences > 0.9) and
#   (RMSE < 0.1 or RMSE of z-scored first differences < 0.1),
# or when r > 0.98 alone. Two adaptations, both needed because LiPDverse holds
# far more than annual Common Era records:
#   - records that are not both annual are compared on a common grid (the
#     coarser of their median spacings, linear interpolation) rather than on
#     exact shared years, which irregularly sampled sediments almost never have;
#   - raw-unit RMSE is only used when both records share units.
#
# Resolution replaces DoD2k's interactive step with ordered rules, so a human
# is needed only where a rule cannot decide:
#   1. prior     a decision a person already made (the DoD2k decision log)
#   2. identical same values on every shared time point: keep the preferred
#   2b. curated  one copy is a member of the pool's reference compilation
#   3. update    one record is flagged as an update or recollection: keep it
#   4. subset    the shorter lies >= 90% within the longer: keep the longer
#   5. complementary  they overlap < 50% of the shorter: keep both
#   6. partial   anything else: keep the longer, and list it for review
# "Preferred" is DoD2k's database priority carried over to LiPDverse
# membership (Pages2kTemperature > iso2k > CoralHydro2k > other), then the
# more recent publication, then more data points.

dedup_defaults <- list(
  max_km = 8, min_overlap = 10, r = 0.9, r_alone = 0.98, rmse = 0.1,
  annual_max_resolution = 1.5, subset_frac = 0.9, complement_frac = 0.5,
  priority = c("Pages2kTemperature", "iso2k", "CoralHydro2k"),
  update_pattern = "recollect|re-collect|update"
)

haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- pi / 180
  a <- sin((lat2 - lat1) * r / 2)^2 + cos(lat1 * r) * cos(lat2 * r) * sin((lon2 - lon1) * r / 2)^2
  2 * 6371 * asin(pmin(1, sqrt(a)))
}

norm_proxy <- function(x) {
  p <- ifelse(is.na(x$proxy) | x$proxy == "", x$variableName, x$proxy)
  gsub("[^a-z0-9]", "", tolower(p))
}

# Candidate pairs: same archive, same proxy, within max_km, different TSids.
dedup_candidates <- function(pool, opt = dedup_defaults) {
  pool$pkey <- paste(pool$archiveType, norm_proxy(pool), sep = "|")
  out <- list()
  for (g in split(pool, pool$pkey)) {
    if (nrow(g) < 2) next
    ij <- utils::combn(nrow(g), 2)
    d <- haversine_km(g$lat[ij[1, ]], g$lon[ij[1, ]], g$lat[ij[2, ]], g$lon[ij[2, ]])
    keep <- !is.na(d) & d <= opt$max_km
    if (!any(keep)) next
    out[[length(out) + 1L]] <- data.frame(TSid1 = g$TSid[ij[1, keep]], TSid2 = g$TSid[ij[2, keep]],
                                          km = d[keep])
  }
  if (!length(out)) return(data.frame(TSid1 = character(), TSid2 = character(), km = numeric()))
  do.call(rbind, out)
}

zs <- function(v) { s <- stats::sd(v); if (!is.finite(s) || s == 0) v * NA else (v - mean(v)) / s }
safe_cor <- function(a, b) {
  if (length(a) < 3 || stats::sd(a) == 0 || stats::sd(b) == 0) return(NA_real_)
  stats::cor(a, b)
}

# Similarity of two series given as data.frames with year and value.
pair_similarity <- function(s1, s2, same_units, opt = dedup_defaults) {
  s1 <- s1[order(s1$year), ]; s2 <- s2[order(s2$year), ]
  s1 <- s1[!duplicated(s1$year), ]; s2 <- s2[!duplicated(s2$year), ]
  res1 <- stats::median(diff(s1$year)); res2 <- stats::median(diff(s2$year))
  lo <- max(min(s1$year), min(s2$year)); hi <- min(max(s1$year), max(s2$year))
  span1 <- diff(range(s1$year)); span2 <- diff(range(s2$year))
  overlap_frac <- if (hi > lo) (hi - lo) / max(1e-9, min(span1, span2)) else 0
  na <- list(n = 0L, r = NA, r_diff = NA, rmse = NA, rmse_diff = NA, identical = FALSE,
             overlap_frac = overlap_frac, frac1 = NA, frac2 = NA)
  if (hi <= lo) return(na)
  annual <- isTRUE(res1 <= opt$annual_max_resolution && res2 <= opt$annual_max_resolution)
  if (annual) {
    y <- intersect(round(s1$year), round(s2$year))
    a <- s1$value[match(y, round(s1$year))]; b <- s2$value[match(y, round(s2$year))]
  } else {
    step <- max(res1, res2)
    y <- seq(lo, hi, by = step)
    a <- stats::approx(s1$year, s1$value, y)$y; b <- stats::approx(s2$year, s2$value, y)$y
  }
  ok <- is.finite(a) & is.finite(b)
  a <- a[ok]; b <- b[ok]
  n <- length(a)
  out <- na; out$n <- n
  if (n <= opt$min_overlap) return(out)
  out$r <- safe_cor(a, b)
  da <- diff(a); db <- diff(b)
  out$r_diff <- safe_cor(da, db)
  out$rmse <- if (same_units) sqrt(mean((a - b)^2)) else NA_real_
  out$rmse_diff <- sqrt(mean((zs(da) - zs(db))^2))
  out$identical <- same_units && n == min(nrow(s1), nrow(s2)) && max(abs(a - b)) < 1e-6
  # How much of each record lies inside the other's span.
  out$frac1 <- (hi - lo) / max(1e-9, span1); out$frac2 <- (hi - lo) / max(1e-9, span2)
  out
}

is_duplicate <- function(m, opt = dedup_defaults) {
  if (m$n <= opt$min_overlap) return(FALSE)
  if (isTRUE(m$identical) || isTRUE(m$r > opt$r_alone)) return(TRUE)
  corr <- isTRUE(m$r > opt$r) || isTRUE(m$r_diff > opt$r)
  close <- isTRUE(m$rmse < opt$rmse) || isTRUE(m$rmse_diff < opt$rmse)
  corr && close
}

# Preference score for keeping a record: higher wins.
preference <- function(pool, membership, pubyear, opt = dedup_defaults) {
  pr <- vapply(pool$TSid, function(t) {
    m <- membership$compilation[membership$TSid == t]
    hit <- match(m, opt$priority)
    if (all(is.na(hit))) 0 else length(opt$priority) + 1 - min(hit, na.rm = TRUE)
  }, 0)
  data.frame(TSid = pool$TSid, priority = pr, pubyear = pubyear[pool$datasetId],
             n = pool$n_win, stringsAsFactors = FALSE)
}

prefer <- function(p1, p2) {
  for (k in c("priority", "pubyear", "n")) {
    a <- p1[[k]]; b <- p2[[k]]
    if (is.na(a) && !is.na(b)) return(2L)
    if (!is.na(a) && is.na(b)) return(1L)
    if (!is.na(a) && !is.na(b) && a != b) return(if (a > b) 1L else 2L)
  }
  1L
}

norm_season <- function(x) {
  s <- tolower(gsub("[^A-Za-z0-9]", "", x))
  s[s %in% c("", "na")] <- NA
  s[s %in% c("annual", "ann", "tann", "1", "meanannual", "yearly")] <- "annual"
  s
}

# Stage 0: one record per dataset, proxy and season. Returns the TSids dropped.
# Only columns that name their proxy are collapsed: with no proxy, two
# temperature columns of one core (alkenone and Mg/Ca SST) cannot be told
# apart from two versions of one record, and both are kept.
collapse_within_dataset <- function(pool, prefer_units = character(), curated = character()) {
  has_proxy <- !is.na(pool$proxy) & nzchar(pool$proxy)
  key <- paste(pool$datasetId, ifelse(has_proxy, norm_proxy(pool), paste0("tsid:", pool$TSid)),
               norm_season(pool$seasonality), sep = "|")
  o <- order(key, -as.integer(pool$TSid %in% curated), -as.integer(pool$primaryTimeseries %in% TRUE),
             -as.integer(pool$units %in% prefer_units), -pool$n_win, pool$tableId, pool$TSid)
  p <- pool[o, ]
  # Curated records are never collapsed away: a compilation that kept two
  # records from one core kept them deliberately.
  drop <- duplicated(key[o]) & !p$TSid %in% curated
  p$TSid[drop]
}

# Stage 0b: one record per site for large uniform syntheses (see the config's
# one_record_per_site). Returns the TSids dropped.
collapse_syntheses <- function(con, pool, rules) {
  if (!length(rules)) return(character())
  pubs <- DBI::dbGetQuery(con, "SELECT DISTINCT datasetId, title FROM publications WHERE title IS NOT NULL")
  drop <- character()
  for (r in rules) {
    ds <- unique(pubs$datasetId[grepl(r$publication_title, pubs$title)])
    hit <- pool$datasetId %in% ds & !pool$TSid %in% drop
    if (!any(hit)) next
    s <- pool[hit, ]
    o <- order(s$datasetId, -as.integer(norm_season(s$seasonality) %in% r$prefer_season), -s$n_win, s$TSid)
    s <- s[o, ]
    drop <- c(drop, s$TSid[duplicated(s$datasetId)])
    s <- s[!duplicated(s$datasetId), ]
    others <- pool[!pool$datasetId %in% ds & !pool$TSid %in% drop, ]
    for (k in seq_len(nrow(s))) {
      o2 <- others[norm_proxy(others) == norm_proxy(s[k, ]) & others$archiveType %in% s$archiveType[k], ]
      if (nrow(o2) && any(haversine_km(s$lat[k], s$lon[k], o2$lat, o2$lon) <= r$defer_within_km, na.rm = TRUE))
        drop <- c(drop, s$TSid[k])
    }
  }
  drop
}

# Resolve duplicates in a selected pool. Returns list(pairs, pool) where pool
# has a `dedup_keep` column and pairs records every decision and its rule.
dedup_pool <- function(con, pool, points, prior = NULL, prefer_units = character(),
                       syntheses = list(), curated = character(), opt = dedup_defaults) {
  within <- collapse_within_dataset(pool, prefer_units, curated)
  within <- c(within, collapse_syntheses(con, pool[!pool$TSid %in% within, ], syntheses))
  all_pool <- pool
  pool <- pool[!pool$TSid %in% within, ]
  cand <- dedup_candidates(pool, opt)
  # Different seasons of one dataset are not duplicates of each other, however
  # well they correlate: that is a choice an algorithm makes, not a pool.
  same_ds <- pool$datasetId[match(cand$TSid1, pool$TSid)] == pool$datasetId[match(cand$TSid2, pool$TSid)]
  cand <- cand[!same_ds, ]
  if (!nrow(cand)) {
    all_pool$dedup_keep <- !all_pool$TSid %in% within
    all_pool$dedup_rule <- ifelse(all_pool$TSid %in% within, "within-dataset", NA)
    return(list(pairs = cand, pool = all_pool))
  }

  ser <- split(points[, c("year", "value")], points$TSid)
  idx <- stats::setNames(seq_len(nrow(pool)), pool$TSid)
  sims <- lapply(seq_len(nrow(cand)), function(k) {
    i <- idx[[cand$TSid1[k]]]; j <- idx[[cand$TSid2[k]]]
    su <- identical(pool$units[i], pool$units[j]) && !is.na(pool$units[i])
    as.data.frame(pair_similarity(ser[[cand$TSid1[k]]], ser[[cand$TSid2[k]]], su, opt))
  })
  pairs <- cbind(cand, do.call(rbind, sims))
  pairs$duplicate <- vapply(seq_len(nrow(pairs)), function(k) is_duplicate(pairs[k, ], opt), FALSE)

  membership <- DBI::dbGetQuery(con, "SELECT TSid, compilation FROM compilations WHERE inThisCompilation")
  pubs <- DBI::dbGetQuery(con, "SELECT datasetId, min(year) AS year FROM publications GROUP BY 1")
  pubyear <- stats::setNames(pubs$year, pubs$datasetId)
  pref <- preference(pool, membership, pubyear, opt)
  text <- paste(pool$dataSetName, pool$siteName, pool$variableName)

  pairs$rule <- NA_character_; pairs$keep1 <- NA; pairs$keep2 <- NA
  for (k in which(pairs$duplicate)) {
    a <- pairs$TSid1[k]; b <- pairs$TSid2[k]; i <- idx[[a]]; j <- idx[[b]]
    pk <- if (is.null(prior)) NULL else
      prior[prior$TSid1 == a & prior$TSid2 == b | prior$TSid1 == b & prior$TSid2 == a, ]
    if (!is.null(pk) && nrow(pk)) {
      d1 <- if (pk$TSid1[1] == a) pk$keep1[1] else pk$keep2[1]
      d2 <- if (pk$TSid1[1] == a) pk$keep2[1] else pk$keep1[1]
      pairs[k, c("rule", "keep1", "keep2")] <- list("prior", d1, d2)
      next
    }
    up1 <- grepl(opt$update_pattern, text[i], ignore.case = TRUE)
    up2 <- grepl(opt$update_pattern, text[j], ignore.case = TRUE)
    w <- prefer(pref[i, ], pref[j, ])
    f_short <- max(pairs$frac1[k], pairs$frac2[k], na.rm = TRUE)
    longer <- if (pool$n_win[i] >= pool$n_win[j]) 1L else 2L
    c1 <- a %in% curated; c2 <- b %in% curated
    if (isTRUE(pairs$identical[k])) {
      rule <- "identical"
      if (xor(c1, c2)) w <- if (c1) 1L else 2L
    } else if (xor(c1, c2)) {
      # One copy is the compilation's own record: keep the curated one.
      rule <- "curated"; w <- if (c1) 1L else 2L
    } else if (xor(up1, up2)) {
      rule <- "update"; w <- if (up1) 1L else 2L
    } else if (f_short >= opt$subset_frac) {
      rule <- "subset"; w <- longer
    } else if (pairs$overlap_frac[k] < opt$complement_frac) {
      pairs[k, c("rule", "keep1", "keep2")] <- list("complementary", TRUE, TRUE)
      next
    } else {
      rule <- "partial"; w <- longer
    }
    pairs[k, c("rule", "keep1", "keep2")] <- list(rule, w == 1L, w == 2L)
  }

  drop <- unique(c(pairs$TSid1[pairs$duplicate & pairs$keep1 %in% FALSE],
                   pairs$TSid2[pairs$duplicate & pairs$keep2 %in% FALSE]))
  all_pool$dedup_keep <- !all_pool$TSid %in% c(within, drop)
  all_pool$dedup_rule <- ifelse(all_pool$TSid %in% within, "within-dataset",
                                ifelse(all_pool$TSid %in% drop, "cross-dataset", NA))
  pairs$review <- pairs$rule %in% "partial"
  list(pairs = pairs, pool = all_pool)
}
