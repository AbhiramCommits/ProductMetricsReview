library(testthat)

repo_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
setwd(repo_root)
source(file.path(repo_root, "R", "analyze.R"))

test_that("analysis_summary.csv has 3 rows and estimate inside its CI on every row", {
  s <- read.csv(file.path(OUTPUT_DIR, "analysis_summary.csv"), stringsAsFactors = FALSE)
  expect_equal(nrow(s), 3)
  expect_false(anyNA(s$estimate))
  expect_false(anyNA(s$ci_low))
  expect_false(anyNA(s$ci_high))
  expect_true(all(s$ci_low - 1e-12 <= s$estimate & s$estimate <= s$ci_high + 1e-12))
})

test_that("AOV bootstrap is reproducible with the fixed seed", {
  so <- read_snapshot("session_outcomes")
  purch <- so[so$purchased == 1, ]
  pre <- purch$revenue_usd[purch$event_date >= PRE_START & purch$event_date <= PRE_END & purch$revenue_usd > 0]
  post <- purch$revenue_usd[purch$event_date >= POST_START & purch$event_date <= POST_END & purch$revenue_usd > 0]

  r1 <- aov_bca(pre, post)
  r2 <- aov_bca(pre, post)
  expect_identical(r1$estimate, r2$estimate)
  expect_identical(r1$ci_low, r2$ci_low)
  expect_identical(r1$ci_high, r2$ci_high)

  q3 <- read.csv(file.path(OUTPUT_DIR, "q3_holiday_value_volume.csv"), stringsAsFactors = FALSE)
  row_aov <- q3[q3$metric == "aov_usd", ]
  expect_equal(r1$estimate, row_aov$change, tolerance = 1e-9)
  expect_equal(r1$ci_low, row_aov$ci_low, tolerance = 1e-9)
  expect_equal(r1$ci_high, row_aov$ci_high, tolerance = 1e-9)
})

test_that("the logistic model converges", {
  so <- read_snapshot("session_outcomes")
  m <- fit_q1_model(so)
  expect_true(m$converged)
  expect_equal(length(coef(m)), 15)  # intercept + 2 device + 1 returning + 10 country + 1 week
})
