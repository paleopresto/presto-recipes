# Instrumental screening of a pool: which records track local temperature.
#
# The pools select on metadata (a temperature interpretation with a
# direction), which every PAGES 2k (2017) record has. For index
# reconstructions that regress a composite on instrumental GMST (BayGMST),
# that is not enough: most of the pool's annual tree-ring-width records do
# not correlate with local temperature. PAGES 2k Consortium (2019) and
# Neukom et al. (2019) screened on correlation with local instrumental
# temperature; this is the same idea, as a reproducible stage on a pool.
#
# A record passes when, over the screening window, its annual values
# correlate with the annual mean of the nearest HadCRUT5 grid cell with the
# sign its interpretation direction predicts, at a p-value adjusted for
# autocorrelation (effective sample size, Bretherton et al. 1999), optionally
# after linear detrending of both series and with a Benjamini-Hochberg
# false-discovery-rate correction across the records tested.

screen_defaults <- list(window = c(1850, 2000), alpha = 0.05, fdr = FALSE, detrend = FALSE,
                        min_overlap = 25, min_months = 8)

# Annual-mean HadCRUT5 grid: list(lon, lat, years, tas[lon, lat, year]).
hadcrut_annual <- function(nc_file, years, min_months = 8) {
  n <- ncdf4::nc_open(nc_file); on.exit(ncdf4::nc_close(n))
  tas <- ncdf4::ncvar_get(n, "tas_mean")
  t <- ncdf4::ncvar_get(n, "time")
  origin <- sub("days since ", "", ncdf4::ncatt_get(n, "time", "units")$value)
  yr <- as.integer(format(as.Date(t, origin = as.Date(substr(origin, 1, 10))), "%Y"))
  out <- array(NA_real_, c(dim(tas)[1:2], length(years)))
  for (k in seq_along(years)) {
    s <- tas[, , yr == years[k], drop = FALSE]
    if (!dim(s)[3]) next
    m <- apply(s, 1:2, mean, na.rm = TRUE)
    m[apply(is.finite(s), 1:2, sum) < min_months] <- NA
    out[, , k] <- m
  }
  list(lon = as.vector(ncdf4::ncvar_get(n, "longitude")), lat = as.vector(ncdf4::ncvar_get(n, "latitude")),
       years = years, tas = out)
}

# Pool records as an annual matrix (years x TSid), mean of values per
# calendar year (year rounded to the nearest integer).
annual_matrix <- function(con, pool, years = 1:2000) {
  pts <- pool_points(con, pool)
  pts <- pts[is.finite(pts$value) & is.finite(pts$year), ]
  pts$yr <- floor(pts$year + 0.5)
  pts <- pts[pts$yr >= min(years) & pts$yr <= max(years), ]
  a <- stats::aggregate(value ~ TSid + yr, pts, mean)
  X <- matrix(NA_real_, length(years), nrow(pool), dimnames = list(NULL, pool$TSid))
  X[cbind(match(a$yr, years), match(a$TSid, pool$TSid))] <- a$value
  X[, colSums(is.finite(X)) > 0, drop = FALSE]
}

lag1 <- function(x) { x <- x[is.finite(x)]; if (length(x) < 3) return(0); stats::cor(x[-1], x[-length(x)]) }
detrend_ <- function(x, t) { ok <- is.finite(x); if (sum(ok) >= 3) x[ok] <- stats::resid(stats::lm(x[ok] ~ t[ok])); x }

# Correlation with AR(1)-adjusted significance. Returns c(r, p, n, n_eff).
cor_test_ar1 <- function(x, y, min_overlap = 25) {
  ok <- is.finite(x) & is.finite(y); n <- sum(ok)
  if (n < min_overlap) return(c(r = NA, p = NA, n = n, n_eff = NA))
  r <- stats::cor(x[ok], y[ok])
  a <- lag1(x[ok]) * lag1(y[ok])
  ne <- max(3, min(n, n * (1 - a) / (1 + a)))
  tt <- r * sqrt((ne - 2) / max(1e-12, 1 - r^2))
  c(r = r, p = 2 * stats::pt(-abs(tt), ne - 2), n = n, n_eff = ne)
}

# X: years x records matrix; years: its years; meta: TSid, lat, lon,
# direction; had: hadcrut_annual() covering the window.
screen_local <- function(X, years, meta, had, opt = list()) {
  opt <- utils::modifyList(screen_defaults, opt)
  w <- years >= opt$window[1] & years <= opt$window[2]
  hw <- match(years[w], had$years)
  meta <- meta[match(colnames(X), meta$TSid), ]
  res <- do.call(rbind, lapply(seq_len(ncol(X)), function(j) {
    i <- which.min(abs(((had$lon - meta$lon[j] + 180) %% 360) - 180))
    k <- which.min(abs(had$lat - meta$lat[j]))
    x <- X[w, j]; y <- had$tas[i, k, hw]
    if (isTRUE(opt$detrend)) { x <- detrend_(x, years[w]); y <- detrend_(y, years[w]) }
    data.frame(TSid = colnames(X)[j], t(cor_test_ar1(x, y, opt$min_overlap)))
  }))
  expect <- ifelse(meta$direction %in% "negative", -1, ifelse(meta$direction %in% "positive", 1, NA))
  res$expected_sign <- expect
  res$p_adj <- if (isTRUE(opt$fdr)) stats::p.adjust(res$p, "BH") else res$p
  res$pass <- !is.na(res$p_adj) & res$p_adj < opt$alpha & !is.na(expect) & sign(res$r) == expect
  res$wrong_sign <- !is.na(res$p_adj) & res$p_adj < opt$alpha & !is.na(expect) & sign(res$r) != expect
  attr(res, "options") <- opt
  res
}
