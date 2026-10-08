# Per-record metrics and the two criteria sets.
#
# Each criterion is a separate logical column, with NA meaning "could not be
# evaluated", so a pool reports why a record is out rather than only that it is.

# Sampling metrics for one record's years, inside a window.
record_metrics <- function(y, window, max_gap = Inf) {
  y <- sort(unique(y[y >= window$min_year & y <= window$max_year]))
  n <- length(y)
  if (n < 2) {
    return(c(n = n, min = if (n) y[1] else NA, max = if (n) y[n] else NA,
             span = 0, res = NA, longest = 0))
  }
  d <- diff(y)
  # Longest run of samples with no gap over max_gap.
  brk <- c(0, which(d > max_gap), n)
  runs <- vapply(seq_len(length(brk) - 1), function(i) y[brk[i + 1]] - y[brk[i] + 1], 0)
  c(n = n, min = y[1], max = y[n], span = y[n] - y[1], res = stats::median(d),
    longest = max(runs))
}

metrics_table <- function(points, window, max_gap = Inf) {
  s <- split(points$year, points$TSid)
  m <- t(vapply(s, record_metrics, numeric(6), window = window, max_gap = max_gap))
  out <- data.frame(TSid = names(s), m, row.names = NULL, check.names = FALSE)
  names(out)[-1] <- c("n_win", "min_win", "max_win", "span_win", "res_win", "longest_win")
  # Records that used an uncalibrated 14C axis are flagged; nothing else can be
  # said about them here.
  ax <- tapply(points$axisPref, points$TSid, min)
  out$axis_14C <- ax[out$TSid] == 3
  out
}

is_in <- function(x, set) !is.na(x) & x %in% set
matches <- function(x, pattern) !is.null(pattern) & !is.na(x) & grepl(pattern, x, ignore.case = TRUE)

layer_counted <- function(cand, chron_cfg) {
  is_in(cand$archiveType, chron_cfg$layer_counted_archives) |
    matches(cand$proxy, chron_cfg$layer_counted_proxy_pattern) |
    matches(cand$variableName, chron_cfg$layer_counted_proxy_pattern)
}

interp_checks <- function(cand, cfg) {
  dir <- tolower(cand$direction)
  known <- dir %in% c("positive", "negative")
  out <- data.frame(pass_direction = if (isTRUE(cfg$require_direction)) known else TRUE)
  po <- cfg$positive_only
  if (!is.null(po)) {
    applies <- is_in(cand$archiveType, po$archives) &
      (matches(cand$proxy, po$proxy_pattern) | matches(cand$variableName, po$proxy_pattern))
    out$pass_sign <- !applies | dir %in% "positive"
  } else {
    out$pass_sign <- TRUE
  }
  out
}

# Uncalibrated marine 14C ages read too old by the reservoir age. A nominal
# correction is enough to judge whether a date lies near a record's end.
reservoir_correct <- function(ctrl, x, years) {
  marine <- unique(x$datasetId[x$archiveType %in% "MarineSediment"])
  hit <- ctrl$is14C & ctrl$datasetId %in% marine
  ctrl$year[hit] <- ctrl$year[hit] + years
  ctrl
}

# PAGES 2k (2017). cand and metrics joined by TSid; ctrl is pool_age_controls().
eval_pages2k2017 <- function(x, ctrl, cfg) {
  annual <- !is.na(x$res_win) & x$res_win <= cfg$annual_max_resolution
  marine <- is_in(x$archiveType, cfg$marine_archives)
  min_len <- ifelse(annual, ifelse(marine, cfg$length$annual_marine, cfg$length$annual_terrestrial),
                    cfg$length$non_annual)
  x$annual <- annual
  x$pass_length <- x$span_win >= min_len
  max_res <- ifelse(marine, cfg$resolution$marine, cfg$resolution$terrestrial)
  x$pass_resolution <- annual | is_in(x$archiveType, cfg$resolution$exempt_archives) |
    (!is.na(x$res_win) & x$res_win <= max_res)

  cc <- cfg$chronology
  ctrl <- reservoir_correct(ctrl, x, cc$marine_reservoir_years)
  by_ds <- split(ctrl$year, ctrl$datasetId)
  lc <- layer_counted(x, cc)
  x$layer_counted <- lc
  x$n_age_controls <- vapply(x$datasetId, function(d) length(by_ds[[d]]), 0L)
  x$pass_chronology <- mapply(function(d, lo, hi, res, lcount) {
    if (lcount) return(TRUE)
    a <- by_ds[[d]]
    if (!length(a) || is.na(lo)) return(NA)
    tol <- max(cc$tolerance, cc$tolerance_resolution_multiple * res, na.rm = TRUE)
    old_target <- max(lo, cfg$window$min_year)
    young <- any(a >= hi - tol) || hi >= cc$core_top_if_younger_than
    old <- any(a <= old_target + tol)
    mid <- if (hi - lo > cc$midpoint_if_longer_than) any(abs(a - (lo + hi) / 2) <= tol) else TRUE
    young && old && mid
  }, x$datasetId, x$min_win, x$max_win, x$res_win, lc)
  x$chron_missing <- is.na(x$pass_chronology)
  if (identical(cc$missing_chron, "pass")) x$pass_chronology[x$chron_missing] <- TRUE

  x <- cbind(x, interp_checks(x, cfg$interpretation))
  finalize(x)
}

# Temperature 12k (2020).
eval_temp12k <- function(x, ctrl, cfg) {
  x$pass_length <- x$longest_win >= cfg$duration$min_continuous
  x$pass_resolution <- !is.na(x$res_win) & x$res_win < cfg$resolution$max_median_spacing

  cc <- cfg$chronology
  ctrl <- reservoir_correct(ctrl, x, cc$marine_reservoir_years)
  by_ds <- split(ctrl$year, ctrl$datasetId)
  lc <- layer_counted(x, cc)
  x$layer_counted <- lc
  w <- cfg$window
  x$n_age_controls <- vapply(x$datasetId, function(d) {
    a <- by_ds[[d]]; sum(a >= w$min_year & a <= w$max_year)
  }, 0L)
  x$max_age_gap <- mapply(function(d, lo, hi) {
    a <- sort(by_ds[[d]])
    if (!length(a) || is.na(lo)) return(NA_real_)
    inside <- a[a > lo & a < hi]
    ends <- c(min(abs(a - lo)), min(abs(a - hi)))
    max(c(ends, diff(c(lo, inside, hi)) * (length(inside) > 0)))
  }, x$datasetId, x$min_win, x$max_win)
  # Age density over the record's span in the window, the quantity the
  # Temperature 12k QC sheet records as agesPerKyr.
  x$ages_per_kyr <- mapply(function(d, lo, hi) {
    a <- by_ds[[d]]
    if (!length(a) || is.na(lo) || hi <= lo) return(NA_real_)
    sum(a >= lo - cc$max_gap / 2 & a <= hi + cc$max_gap / 2) / ((hi - lo) / 1000)
  }, x$datasetId, x$min_win, x$max_win)
  ok <- switch(cc$rule,
    max_gap = x$max_age_gap <= cc$max_gap,
    density = x$ages_per_kyr >= 1000 / cc$max_gap)
  x$pass_chronology <- ifelse(lc, TRUE,
    ifelse(is.na(x$max_age_gap), NA, ok | x$n_age_controls >= cc$min_ages_exception))
  x$chron_missing <- is.na(x$pass_chronology)
  if (identical(cc$missing_chron, "pass")) x$pass_chronology[x$chron_missing] <- TRUE

  x$calibrated <- is_in(x$units, cfg$calibrated_units)
  x <- cbind(x, interp_checks(x, cfg$interpretation))
  finalize(x)
}

finalize <- function(x) {
  checks <- grep("^pass_", names(x), value = TRUE)
  m <- as.matrix(x[checks])
  m[is.na(m)] <- FALSE
  x$selected <- rowSums(!m) == 0
  x$fails <- apply(!m, 1, function(r) paste(sub("^pass_", "", checks[r]), collapse = ";"))
  x
}

build_pool <- function(con, cfg) {
  cand <- pool_candidates(con, cfg$interpretation)
  if (!is.null(cfg$exclude_variable_pattern))
    cand <- cand[!grepl(cfg$exclude_variable_pattern, cand$variableName, ignore.case = TRUE), ]
  pts <- pool_points(con, cand)
  gap <- if (!is.null(cfg$duration$max_gap)) cfg$duration$max_gap else Inf
  met <- metrics_table(pts, cfg$window, gap)
  x <- merge(cand, met, by = "TSid", all.x = TRUE)
  x$span_win[is.na(x$span_win)] <- 0
  x$longest_win[is.na(x$longest_win)] <- 0
  ctrl <- pool_age_controls(con, x$datasetId)
  if (!is.null(cfg$curator_exclusions)) {
    ex <- utils::read.csv(file.path(cfg$.dir, "baselines", cfg$curator_exclusions), stringsAsFactors = FALSE)
    x$pass_curator <- !x$TSid %in% ex$TSid[ex$pool == cfg$name]
  }
  ev <- switch(cfg$name, pages2k2017 = eval_pages2k2017, temp12k = eval_temp12k)
  x <- ev(x, ctrl, cfg)
  attr(x, "snapshot") <- attr(con, "snapshot")
  attr(x, "points") <- pts[pts$TSid %in% x$TSid[x$selected], ]
  x
}
