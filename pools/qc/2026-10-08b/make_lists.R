# Builds the LiPDverse QC lists in this folder from the 2026-10-08b export.
# Sections 7 and 8 read outputs of the local LMR interpretation-screen test (~/presto-lmr-attrib/interp_test).
# Run from the presto-recipes root: Rscript pools/qc/2026-10-08b/make_lists.R
suppressPackageStartupMessages({library(DBI); library(duckdb); library(yaml)})
here <- path.expand("~/GitHub/presto-recipes/pools")
for (f in list.files(file.path(here, "R"), full.names = TRUE)) source(f)
con <- pool_snapshot("~/lipdverse-export/_database/2026-10-08b")
out <- file.path(here, "qc/2026-10-08b"); dir.create(out, showWarnings = FALSE)
q <- function(s) DBI::dbGetQuery(con, s)
pooled <- unique(unlist(lapply(list.files(file.path(here, "output"), full.names = TRUE), function(d) {
  f <- file.path(d, "2026-10-08b", "pool.csv"); if (!file.exists(f)) return(NULL)
  x <- read.csv(f); x$TSid[x$selected & x$dedup_keep %in% TRUE]
})))

## 1. Missing-value codes stored as data
mv <- q("SELECT v.TSid, d.dataSetName, t.variableName, t.units, d.archiveType, v.value_num AS code,
              count(*) AS n_code, any_value(t.n_values) AS n_values
         FROM values v JOIN timeseries t USING (TSid) JOIN datasets d USING (datasetId)
         WHERE t.tableType = 'paleo' AND t.tableKind = 'measurement' AND NOT coalesce(t.isAxis, false)
           AND v.value_num IN (-9999, -99999, -999, 9999, 99999, -9999.99, -999.9)
         GROUP BY ALL ORDER BY dataSetName, TSid")
mv$in_presto_pool <- mv$TSid %in% pooled
write.csv(mv, file.path(out, "missing_value_codes.csv"), row.names = FALSE)
message("missing-value codes: ", nrow(mv), " columns in ", length(unique(mv$dataSetName)), " datasets; ", sum(mv$in_presto_pool), " in a pool")

## 2. Mis-encoded text (U+FFFD replacement characters)
bad <- "�"
enc <- rbind(
  q(sprintf("SELECT d.dataSetName, 'publications.authors' AS field, p.pubIndex::VARCHAR AS id, array_to_string(p.authors, '; ') AS text FROM publications p JOIN datasets d USING (datasetId) WHERE array_to_string(p.authors, '; ') LIKE '%%%s%%'", bad)),
  q(sprintf("SELECT d.dataSetName, 'publications.title' AS field, p.pubIndex::VARCHAR AS id, p.title AS text FROM publications p JOIN datasets d USING (datasetId) WHERE p.title LIKE '%%%s%%'", bad)),
  q(sprintf("SELECT dataSetName, 'datasets.geo_siteName' AS field, datasetId AS id, geo_siteName AS text FROM datasets WHERE geo_siteName LIKE '%%%s%%' OR dataSetName LIKE '%%%s%%'", bad, bad)),
  q(sprintf("SELECT d.dataSetName, 'timeseries.description' AS field, t.TSid AS id, t.description AS text FROM timeseries t JOIN datasets d USING (datasetId) WHERE t.description LIKE '%%%s%%'", bad)))
enc$text <- substr(enc$text, 1, 300)
write.csv(enc, file.path(out, "bad_encoding.csv"), row.names = FALSE)
message("encoding: ", nrow(enc), " fields in ", length(unique(enc$dataSetName)), " datasets")

## 3. Duplicate value columns inside one dataset
dup <- q("WITH h AS (
            SELECT v.TSid, md5(string_agg(coalesce(v.value_num::VARCHAR, v.value_chr, 'NA'), ',' ORDER BY v.row_index)) AS h
            FROM values v JOIN timeseries t USING (TSid)
            WHERE t.tableType = 'paleo' AND t.tableKind = 'measurement' AND NOT coalesce(t.isAxis, false)
            GROUP BY v.TSid HAVING count(DISTINCT v.value_num) >= 10)
          SELECT d.dataSetName, a.TSid AS TSid1, b.TSid AS TSid2, ta.variableName AS variable1, tb.variableName AS variable2,
                 ta.n_values, 'identical' AS match
          FROM h a JOIN h b ON a.h = b.h AND a.TSid < b.TSid
          JOIN timeseries ta ON ta.TSid = a.TSid JOIN timeseries tb ON tb.TSid = b.TSid
          JOIN datasets d ON d.datasetId = ta.datasetId
          WHERE ta.datasetId = tb.datasetId AND ta.n_values >= 20")
near <- q("SELECT d.dataSetName, a.TSid AS TSid1, b.TSid AS TSid2, ta.variableName AS variable1, tb.variableName AS variable2,
                  ta.n_values, 'near-identical' AS match
           FROM timeseries ta JOIN timeseries tb ON ta.datasetId = tb.datasetId AND ta.TSid < tb.TSid
             AND ta.tableId = tb.tableId AND ta.variableName = tb.variableName AND ta.n_values = tb.n_values
           JOIN values a ON a.TSid = ta.TSid JOIN values b ON b.TSid = tb.TSid AND b.row_index = a.row_index
           JOIN datasets d ON d.datasetId = ta.datasetId
           WHERE ta.tableType = 'paleo' AND ta.tableKind = 'measurement' AND NOT coalesce(ta.isAxis, false)
             AND NOT coalesce(tb.isAxis, false) AND ta.n_values >= 20
           GROUP BY ALL HAVING avg(CASE WHEN a.value_num = b.value_num THEN 1.0 ELSE 0 END) >= 0.95
             AND count(DISTINCT a.value_num) >= 10")
near <- near[!paste(near$TSid1, near$TSid2) %in% paste(dup$TSid1, dup$TSid2), ]
dup <- rbind(dup, near)
dup$in_presto_pool <- dup$TSid1 %in% pooled | dup$TSid2 %in% pooled
write.csv(dup, file.path(out, "duplicate_columns.csv"), row.names = FALSE)
message("duplicate columns: ", nrow(dup), " pairs in ", length(unique(dup$dataSetName)), " datasets; ",
        sum(dup$match == "near-identical"), " near-identical; ", sum(dup$in_presto_pool), " touch a pool")

## 4. Placeholder variable names
ph <- q("SELECT d.dataSetName, t.TSid, t.variableName, t.units, t.tableType FROM timeseries t JOIN datasets d USING (datasetId)
         WHERE lower(t.variableName) IN ('needstobechanged', 'unknown', 'na', 'variable', 'column', 'x') ORDER BY 1")
write.csv(ph, file.path(out, "placeholder_variable_names.csv"), row.names = FALSE)
message("placeholder names: ", nrow(ph), " columns in ", length(unique(ph$dataSetName)), " datasets")

## 5. Conflicting or repeated interpretation entries on one column
ci <- q("WITH s AS (
           SELECT i.*, CASE WHEN lower(i.direction) IN ('positive','increase','+') THEN 1
                            WHEN lower(i.direction) IN ('negative','decrease','-') THEN -1 END AS sgn
           FROM interpretations i WHERE i.variable IS NOT NULL AND i.variable <> '')
         SELECT d.dataSetName, s.TSid, t.variableName, s.variable AS interpretation,
                string_agg(s.scope || ': ' || coalesce(s.direction, '?') || ' (rank ' || coalesce(s.rank::VARCHAR, '?') || ', ' || coalesce(s.seasonality, '') || ')', '; ') AS entries,
                count(*) AS n_entries, count(DISTINCT sgn) AS n_signs,
                count(DISTINCT coalesce(s.direction, '') || '|' || coalesce(s.seasonality, '') || '|' || s.scope) AS n_distinct
         FROM s JOIN timeseries t USING (TSid) JOIN datasets d USING (datasetId)
         GROUP BY ALL HAVING count(*) > 1 ORDER BY n_signs DESC, dataSetName")
ci <- ci[ci$n_signs > 1 | ci$n_distinct < ci$n_entries, ]
ci$problem <- ifelse(ci$n_signs > 1, "opposite directions", "exact repeat")
ci$in_presto_pool <- ci$TSid %in% pooled
write.csv(ci, file.path(out, "interpretation_conflicts.csv"), row.names = FALSE)
message("interpretation conflicts: ", sum(ci$n_signs > 1), " opposite-direction, ", sum(ci$n_signs <= 1), " exact repeats; ", sum(ci$in_presto_pool), " in a pool")

## 6. Uninterpreted columns that cfr_annual would use if they were interpreted
cfg <- read_yaml(file.path(here, "config", "cfr_annual.yml")); cfg$.dir <- here
on <- build_pool(con, cfg)
cfg$uninterpreted_only_in_uninterpreted_datasets <- FALSE
off <- build_pool(con, cfg)
s_on <- on$TSid[on$selected]; s_off <- off$TSid[off$selected]
ui <- off[off$selected & !off$TSid %in% s_on, c("TSid", "dataSetName", "variableName", "units", "archiveType", "proxy", "min_win", "max_win", "n_win")]
other <- q("SELECT t.datasetId, d.dataSetName, string_agg(DISTINCT t.variableName || ': ' || i.variable, '; ') AS interpreted_columns
            FROM interpretations i JOIN timeseries t USING (TSid) JOIN datasets d USING (datasetId)
            WHERE i.variable IS NOT NULL AND lower(i.scope) IN ('climate', 'isotope') GROUP BY ALL")
ui$interpreted_columns <- other$interpreted_columns[match(ui$dataSetName, other$dataSetName)]
r3 <- jsonlite::parse_json(system2("git", c("-C", here, "show", "94a0163:pools/output/cfr_annual/2026-10-08b/tsids.json"), stdout = TRUE) |> paste(collapse = ""))$TSIDs |> unlist()
ui$in_r3_pool <- ui$TSid %in% r3
ui <- ui[order(!ui$in_r3_pool, ui$archiveType, ui$dataSetName), ]
write.csv(ui, file.path(out, "uninterpreted_in_interpreted_datasets.csv"), row.names = FALSE)
message("uninterpreted columns blocked by the dataset rule: ", nrow(ui), " in ", length(unique(ui$dataSetName)), " datasets; ", sum(ui$in_r3_pool), " were in r3")
print(table(ui$archiveType)); print(sort(table(ui$variableName), decreasing = TRUE)[1:12])

## 7. Interpretations the instrumental calibration contradicts (LMR interpretation screen, v2 test)
sc <- read.csv(path.expand("~/presto-lmr-attrib/interp_test/v2_psm_screen.csv"))
sc <- sc[sc$status == "drop_direction", ]
meta <- q(sprintf("SELECT t.TSid, d.dataSetName, d.archiveType, t.variableName, d.geo_latitude AS lat, d.geo_longitude AS lon,
                          string_agg(DISTINCT c.compilation, '; ') AS compilations
                   FROM timeseries t JOIN datasets d USING (datasetId) LEFT JOIN compilations c ON c.TSid = t.TSid AND c.inThisCompilation
                   WHERE t.TSid IN (%s) GROUP BY ALL", paste0("'", sc$pid, "'", collapse = ",")))
cc <- merge(meta, data.frame(TSid = sc$pid, ptype = sc$ptype, interpretation = sc$interpretations,
                             best_adjR2 = round(sc$fitR2adj, 3), slope_tas = signif(sc$slope_tas, 3)), by = "TSid", all.y = TRUE)
cc$note <- "no calibration season (LMR template, 1850-2015 instrumental) gives the interpreted sign"
cc <- cc[order(cc$archiveType, -cc$best_adjR2), ]
write.csv(cc, file.path(out, "calibration_contradicts_interpretation.csv"), row.names = FALSE)
message("calibration contradicts interpretation: ", nrow(cc), "; ", sum(is.na(cc$dataSetName)), " not matched by TSid")
print(table(cc$archiveType))

## 8. Datasets pylipd cannot load
sk <- read.csv(path.expand("~/presto-lmr-attrib/interp_test/v2/prepare-data/skipped_records.csv"))
write.csv(sk, file.path(out, "pylipd_unreadable.csv"), row.names = FALSE)
