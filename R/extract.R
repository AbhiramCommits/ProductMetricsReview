#!/usr/bin/env Rscript
# extract.R -- snapshot the aggregated GA4 sample tables from BigQuery.
#
# Runs every .sql file in sql/ against the public Google Merchandise Store
# GA4 dataset, validates that the result is a small daily-grain aggregate
# (never raw event-level rows), and writes it to data/snapshot/<table>.parquet
# together with a MANIFEST.json describing each snapshot.
#
# Requirements:
#   * GCP_PROJECT_ID env var: the GCP project that BILLS the queries.
#     The dataset itself is public (bigquery-public-data) and needs no
#     further credentials than a billing project.
#   * The SQL in sql/ must produce aggregated tables at daily grain or
#     coarser. This script refuses to write anything that looks event-level.

suppressPackageStartupMessages({
  library(bigrquery)
  library(arrow)
  library(jsonlite)
})

args <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
ROOT <- if (length(file_arg) && nzchar(file_arg)) {
  normalizePath(dirname(dirname(file_arg)))
} else {
  getwd()
}

SQL_DIR <- file.path(ROOT, "sql")
SNAPSHOT_DIR <- file.path(ROOT, "data", "snapshot")
MANIFEST_PATH <- file.path(SNAPSHOT_DIR, "MANIFEST.json")

MAX_ROWS_PER_TABLE <- 1e6L
MAX_DISTINCT_DATES <- 120L

project_id <- Sys.getenv("GCP_PROJECT_ID", unset = "")
if (!nzchar(project_id)) {
  stop(
    "GCP_PROJECT_ID is not set.\n",
    "Set the BigQuery project that bills the queries, e.g.\n",
    "    export GCP_PROJECT_ID=my-sandbox-project"
  )
}

sql_files <- sort(list.files(SQL_DIR, pattern = "\\.sql$", full.names = TRUE))
if (length(sql_files) == 0L) {
  stop("No .sql files found in '", SQL_DIR, "'")
}

dir.create(SNAPSHOT_DIR, recursive = TRUE, showWarnings = FALSE)

first_date_col <- function(x) {
  is_date <- vapply(x, function(col) inherits(col, "Date") || inherits(col, "POSIXct"), logical(1))
  cols <- names(x)[is_date]
  if (length(cols) == 0L) NA_character_ else cols[[1L]]
}

tables <- list()
for (f in sql_files) {
  table <- sub("\\.sql$", "", basename(f))
  out_path <- file.path(SNAPSHOT_DIR, paste0(table, ".parquet"))
  query <- paste(readLines(f, warn = FALSE), collapse = "\n")

  message("Extracting ", table, " ...")
  job <- bq_perform_query(query, billing = project_id)
  bq_job_wait(job, quiet = TRUE)

  df <- bq_table_download(bq_job_table(job), bigint = "integer64")

  n <- nrow(df)
  if (n == 0L) {
    stop("Query for '", table, "' returned zero rows; refusing to snapshot an empty table.")
  }
  if (n > MAX_ROWS_PER_TABLE) {
    stop(
      sprintf(
        "'%s' has %d rows (limit %d). This looks like raw event-level data, which must never be committed. Aggregate in SQL to daily grain.",
        table, n, MAX_ROWS_PER_TABLE
      )
    )
  }

  date_min <- date_max <- NA_character_
  d <- first_date_col(df)
  if (is.na(d)) {
    warning("'", table, "' has no Date/Timestamp column; skipping date-grain validation.")
  } else {
    dates <- unique(df[[d]])
    if (length(dates) > MAX_DISTINCT_DATES) {
      stop(
        sprintf(
          "'%s' has %d distinct dates (limit %d). Expected daily grain (sample spans 2020-11-01 .. 2021-01-31). Aggregate in SQL.",
          table, length(dates), MAX_DISTINCT_DATES
        )
      )
    }
    date_min <- as.character(min(as.Date(dates)))
    date_max <- as.character(max(as.Date(dates)))
  }

  bytes <- NA_real_
  meta <- tryCatch(bq_job_meta(job), error = function(e) NULL)
  if (!is.null(meta) && !is.null(meta$statistics$totalBytesProcessed)) {
    bytes <- as.numeric(meta$statistics$totalBytesProcessed)
  }

  write_parquet(df, out_path)

  tables[[table]] <- list(
    table = table,
    query_file = file.path("sql", basename(f)),
    parquet_file = file.path("data", "snapshot", basename(out_path)),
    rows = n,
    date_min = date_min,
    date_max = date_max,
    bytes_processed = bytes
  )
  message("  -> ", out_path, " (", n, " rows)")
}

manifest <- list(
  extract_time = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  gcp_project_id = project_id,
  source_dataset = "bigquery-public-data.ga4_obfuscated_sample_ecommerce",
  tables = unname(tables)
)

writeLines(
  toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
  MANIFEST_PATH
)
message("Wrote ", MANIFEST_PATH)
