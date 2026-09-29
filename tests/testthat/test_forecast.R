library(testthat)

repo_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
setwd(repo_root)
source(file.path(repo_root, "R", "forecast.R"))
source(file.path(repo_root, "R", "detect.R"))

test_that("rolling-origin folds never leak future dates into training", {
  series <- build_daily_series()
  folds <- build_folds(sort(unique(series$date)))

  expect_equal(length(folds), 7)  # (92 - 42) / 7
  for (f in folds) {
    expect_true(f$train_end < f$test_start)                       # no leakage
    expect_equal(as.numeric(f$test_end - f$test_start) + 1, 7)    # 7-day horizon
  }
  expect_equal(as.numeric(folds[[1]]$train_end - folds[[1]]$train_start) + 1, 42)
  train_ends <- vapply(folds, function(f) f$train_end, as.Date(NA))
  expect_true(all(diff(train_ends) == 7))                         # step 7
  expect_equal(folds[[length(folds)]]$test_end, max(series$date) - 1)
})

test_that("detector fires on an injected -30% step change", {
  dates <- seq(as.Date("2021-01-01"), by = "day", length.out = 14)
  actual <- c(rep(100, 7), rep(70, 7))
  lo80 <- rep(90, 14)
  lo95 <- rep(85, 14)
  d <- detect_regressions(dates, actual, lo80, lo95)
  expect_false(is.null(d))
  expect_equal(d$first_flag_date, dates[9])  # 2nd consecutive day below lo95
  expect_true(d$days_flagged >= 2)
  expect_true(d$worst_deviation_pct < 0)
})

test_that("detector never flags a single-day dip", {
  dates <- seq(as.Date("2021-01-01"), by = "day", length.out = 14)
  actual <- rep(100, 14)
  actual[7] <- 80  # one day below lo95, nothing else
  expect_null(detect_regressions(dates, actual, rep(90, 14), rep(85, 14)))
})

test_that("detector stays silent on stationary noise", {
  set.seed(42)
  dates <- seq(as.Date("2021-01-01"), by = "day", length.out = 14)
  actual <- 100 + rnorm(14, 0, 2)
  expect_null(detect_regressions(dates, actual, rep(96, 14), rep(92, 14)))
})

test_that("forecast intervals are ordered on every row", {
  fc <- read.csv(file.path(OUTPUT_DIR, "forecasts.csv"), stringsAsFactors = FALSE)
  expect_true(nrow(fc) > 0)
  expect_true(all(fc$lo95 - 1e-9 <= fc$lo80))
  expect_true(all(fc$lo80 - 1e-9 <= fc$forecast))
  expect_true(all(fc$forecast <= fc$hi80 + 1e-9))
  expect_true(all(fc$hi80 <= fc$hi95 + 1e-9))
})
