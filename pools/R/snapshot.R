# Reading a LiPDverse database export.
#
# A pool is built from one pinned export (lipdverse.org/dev/export/<dir>/),
# never from the live files, so the pool can name exactly what it was built
# from. The export needs schema v3 with timeseries.tableId (lipdverse-updater
# 3805c00 or later); without tableId a value column cannot be paired with its
# own time axis.

pool_snapshot <- function(dir) {
  dir <- path.expand(dir)
  db <- file.path(dir, "lipdverse.duckdb")
  if (file.exists(db)) {
    con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE), dbdir = db, read_only = TRUE)
  } else {
    con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
    for (t in c("datasets", "timeseries", "interpretations", "values", "compilations")) {
      DBI::dbExecute(con, sprintf("CREATE VIEW %s AS SELECT * FROM read_parquet('%s')",
                                  DBI::dbQuoteIdentifier(con, t), file.path(dir, paste0(t, ".parquet"))))
    }
  }
  cols <- DBI::dbListFields(con, "timeseries")
  if (!"tableId" %in% cols) {
    DBI::dbDisconnect(con)
    stop("This export has no timeseries.tableId; rebuild it with lipdverse-updater >= 3805c00.")
  }
  manifest <- file.path(dir, "export_manifest.json")
  attr(con, "snapshot") <- if (file.exists(manifest)) jsonlite::read_json(manifest)$version else basename(dir)
  con
}

# Candidate records: paleo measurement columns, not axes, whose climate
# interpretation of rank <= max_rank is the target variable. One row per TSid.
pool_candidates <- function(con, interp, tsids = NULL) {
  # With tsids, the interpretation is not required (curator admissions are
  # admitted on a person's judgment, whatever the metadata now says).
  sql <- sprintf("
    SELECT t.TSid, t.datasetId, t.tableId, t.variableName, t.units, t.proxy,
           t.proxyGeneral, t.primaryTimeseries, d.dataSetName, d.archiveType,
           d.geo_latitude AS lat, d.geo_longitude AS lon, d.geo_elevation AS elev,
           d.geo_siteName AS siteName, d.version AS datasetVersion,
           i.rank AS interpRank, i.seasonality, i.direction, i.variableDetail
    FROM timeseries t
    %s JOIN interpretations i ON i.TSid = t.TSid
      AND i.scope = '%s' AND lower(i.variable) = lower('%s') AND i.rank <= %d
    JOIN datasets d USING (datasetId)
    WHERE t.tableType = 'paleo' AND t.tableKind = 'measurement'
      AND NOT coalesce(t.isAxis, false) %s",
    if (is.null(tsids)) "" else "LEFT",
    interp$scope, interp$variable, as.integer(interp$max_rank),
    if (is.null(tsids)) "" else sprintf("AND t.TSid IN (%s)", paste0("'", tsids, "'", collapse = ",")))
  x <- DBI::dbGetQuery(con, sql)
  # A column interpreted as temperature twice within the rank limit is one record.
  x <- x[order(x$TSid, x$interpRank), ]
  x[!duplicated(x$TSid), ]
}

# The time axis of every table that holds a candidate, as calendar years CE.
# Preference within a table: year, then age, then age14C (uncalibrated, used
# only when nothing else exists, and flagged).
axis_sql <- "
  WITH ax AS (
    SELECT TSid AS axisTSid, datasetId, tableId, variableName, lower(coalesce(units, '')) AS u,
      CASE WHEN lower(variableName) = 'year' THEN 1
           WHEN lower(variableName) = 'age' THEN 2
           WHEN lower(variableName) = 'age14c' THEN 3 END AS pref
    FROM timeseries
    WHERE tableType = 'paleo' AND tableKind = 'measurement' AND isAxis
      AND lower(variableName) IN ('year', 'age', 'age14c')
  ), best AS (
    SELECT * FROM ax QUALIFY row_number() OVER (PARTITION BY datasetId, tableId ORDER BY pref) = 1
  )
  SELECT * FROM best"

# Year of every non-missing value of every candidate. Long: TSid, year, value.
pool_points <- function(con, cand) {
  duckdb::duckdb_register(con, "cand_tmp", cand[, c("TSid", "datasetId", "tableId")])
  on.exit(duckdb::duckdb_unregister(con, "cand_tmp"))
  sql <- sprintf("
    WITH best AS (%s)
    SELECT c.TSid, b.pref AS axisPref, v.value_num AS value,
      CASE WHEN b.pref = 1 THEN a.value_num
           WHEN b.u LIKE '%%ka%%' OR b.u LIKE '%%kyr%%' THEN 1950 - 1000 * a.value_num
           ELSE 1950 - a.value_num END AS year
    FROM cand_tmp c
    JOIN best b ON b.datasetId = c.datasetId AND b.tableId = c.tableId
    JOIN \"values\" v ON v.TSid = c.TSid
    JOIN \"values\" a ON a.TSid = b.axisTSid AND a.row_index = v.row_index
    WHERE v.value_num IS NOT NULL AND isfinite(v.value_num)
      AND a.value_num IS NOT NULL AND isfinite(a.value_num)", axis_sql)
  p <- DBI::dbGetQuery(con, sql)
  p[p$year > -1e6 & p$year < 2100, ]
}

# Age control points per dataset, as calendar years CE: one per row of each
# chron measurement table, taking the first of age, year, age14C that the row
# has. A table can split its dates across columns (210Pb ages in `age`, 14C in
# `age14C`), so reading one column per table misses most of them. Rows a table
# marks as rejected are dropped. is14C marks uncalibrated radiocarbon ages,
# which the criteria correct only roughly (marine reservoir).
pool_age_controls <- function(con, datasets) {
  duckdb::duckdb_register(con, "ds_tmp", data.frame(datasetId = unique(datasets)))
  on.exit(duckdb::duckdb_unregister(con, "ds_tmp"))
  sql <- "
    WITH cols AS (
      SELECT t.TSid, t.datasetId, t.tableId, lower(coalesce(t.units, '')) AS u,
        CASE WHEN lower(t.variableName) = 'age' THEN 1
             WHEN lower(t.variableName) = 'year' THEN 2
             WHEN lower(t.variableName) = 'age14c' THEN 3 END AS pref
      FROM timeseries t JOIN ds_tmp USING (datasetId)
      WHERE t.tableType = 'chron' AND t.tableKind = 'measurement'
        AND lower(t.variableName) IN ('age', 'year', 'age14c')
    ), vals AS (
      SELECT c.datasetId, c.tableId, v.row_index, c.pref,
        CASE WHEN c.pref = 2 THEN v.value_num
             WHEN c.u LIKE '%ka%' OR c.u LIKE '%kyr%' THEN 1950 - 1000 * v.value_num
             ELSE 1950 - v.value_num END AS year
      FROM cols c JOIN \"values\" v ON v.TSid = c.TSid
      WHERE v.value_num IS NOT NULL AND isfinite(v.value_num)
    ), rej AS (
      SELECT t.datasetId, t.tableId, v.row_index
      FROM timeseries t JOIN ds_tmp USING (datasetId) JOIN \"values\" v USING (TSid)
      WHERE t.tableType = 'chron' AND lower(t.variableName) = 'rejected'
        AND lower(coalesce(v.value_chr, CAST(v.value_num AS VARCHAR))) IN ('true', '1', 'yes', 'y', 'rejected')
    )
    SELECT v.datasetId, v.pref = 3 AS is14C, v.year
    FROM vals v
    LEFT JOIN rej r ON r.datasetId = v.datasetId AND r.tableId = v.tableId AND r.row_index = v.row_index
    WHERE r.row_index IS NULL
    QUALIFY row_number() OVER (PARTITION BY v.datasetId, v.tableId, v.row_index ORDER BY v.pref) = 1"
  a <- DBI::dbGetQuery(con, sql)
  a[a$year > -1e6 & a$year < 2100, ]
}
