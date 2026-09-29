library(testthat)
library(arrow)

repo_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
snapshot_dir <- file.path(repo_root, "data", "snapshot")

read_table <- function(name) {
  path <- file.path(snapshot_dir, paste0(name, ".parquet"))
  expect_true(file.exists(path), info = paste("missing snapshot:", path))
  read_parquet(path)
}

all_days <- seq(as.Date("2020-11-01"), as.Date("2021-01-31"), by = "day")

test_that("MANIFEST.json describes the snapshot", {
  path <- file.path(snapshot_dir, "MANIFEST.json")
  expect_true(file.exists(path))
  manifest <- jsonlite::fromJSON(readLines(path, warn = FALSE), simplifyVector = FALSE)
  expect_true("extract_time" %in% names(manifest))
  expect_setequal(
    vapply(manifest$tables, `[[`, character(1), "table"),
    c("daily_active", "funnel_daily", "retention_cohorts", "revenue_daily", "session_outcomes")
  )
  expect_true(all(vapply(manifest$tables, `[[`, numeric(1), "rows") > 0))
})

test_that("daily_active covers the full 92-day range with no NULL keys", {
  x <- read_table("daily_active")
  expect_setequal(as.character(x$event_date), as.character(all_days))
  expect_false(anyNA(x$event_date))
  expect_true(all(x$dau > 0))
  expect_true(all(x$sessions >= x$dau))
  expect_true(all(x$new_users >= 0))
})

test_that("funnel_daily is non-increasing at every step on every row", {
  x <- read_table("funnel_daily")
  expect_setequal(as.character(unique(x$event_date)), as.character(all_days))
  expect_false(anyNA(x$event_date))
  expect_false(anyNA(x$device_category))
  expect_true(all(x$sessions >= x$view_item_sessions))
  expect_true(all(x$view_item_sessions >= x$add_to_cart_sessions))
  expect_true(all(x$add_to_cart_sessions >= x$begin_checkout_sessions))
  expect_true(all(x$begin_checkout_sessions >= x$purchase_sessions))
  expect_true(all(x$purchase_sessions >= 0))
})

test_that("retention_cohorts has week-0 retained equal to cohort size", {
  x <- read_table("retention_cohorts")
  expect_false(anyNA(x$cohort_week))
  expect_false(anyNA(x$weeks_since_first_visit))
  expect_true(all(x$weeks_since_first_visit >= 0 & x$weeks_since_first_visit <= 8))
  expect_true(all(x$cohort_size > 0))
  week0 <- x[x$weeks_since_first_visit == 0, ]
  expect_true(nrow(week0) > 0)
  expect_true(all(week0$retained_users == week0$cohort_size))
  expect_true(all(x$retained_users <= x$cohort_size))
})

test_that("revenue_daily has no NULL keys and sane values", {
  x <- read_table("revenue_daily")
  expect_setequal(as.character(unique(x$event_date)), as.character(all_days))
  expect_false(anyNA(x$event_date))
  expect_false(anyNA(x$device_category))
  expect_true(all(x$purchases >= 1))
  expect_true(all(x$revenue_usd >= 0))
  expect_true(all(x$event_date >= as.Date("2020-11-01") & x$event_date <= as.Date("2021-01-31")))
})

test_that("session_outcomes is one row per session, under 25 MB, no NULL keys", {
  x <- read_table("session_outcomes")
  expect_false(anyNA(x$event_date))
  expect_false(anyNA(x$device_category))
  expect_false(anyNA(x$country))
  expect_false(anyNA(x$is_returning_user))
  expect_false(anyNA(x$purchased))
  expect_true(all(x$is_returning_user %in% c(0, 1)))
  expect_true(all(x$purchased %in% c(0, 1)))
  expect_true(all(x$revenue_usd >= 0))
  expect_lt(file.size(file.path(snapshot_dir, "session_outcomes.parquet")), 25 * 1024^2)
})
