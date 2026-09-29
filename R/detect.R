#!/usr/bin/env Rscript
# detect.R -- regression detection on the last 14 days of the sample.
#
# Hold out the last 14 days, refit the winning model (from the same rolling
# backtest as forecast.R) on the remainder, and flag a regression when
# actuals fall below the 95% lower bound on 2+ consecutive days, or below the
# 80% lower bound on 5 of the trailing 7 days. A single-day dip can never
# fire: the 95% rule needs the second consecutive day, and the 80% rule needs
# 5 breaches in a full 7-day window. The rule is applied as specified -- not
# tuned against this data.
#
# Output: output/regressions.csv (metric, first_flag_date, days_flagged,
# worst_deviation_pct, severity). If nothing is flagged, the CSV says so.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
})

options(digits = 15)

args <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
ROOT <- if (length(file_arg) && nzchar(file_arg)) {
  normalizePath(dirname(dirname(file_arg)))
} else {
  getwd()
}

source(file.path(ROOT, "R", "forecast.R"))

# dates/actual/lo80/lo95: aligned vectors over the holdout period.
# Returns NULL when nothing fires, otherwise a one-row data.frame.
detect_regressions <- function(dates, actual, lo80, lo95) {
  n <- length(dates)
  stopifnot(n == length(actual), n == length(lo80), n == length(lo95))
  below80 <- actual < lo80
  below95 <- actual < lo95
  # 95% rule: fires from the second consecutive day below lo95 onward.
  flag95 <- c(FALSE, below95[-1] & below95[-n])
  # 80% rule: 5 of the trailing 7 days below lo80 (full 7-day windows only).
  flag80 <- vapply(seq_len(n), function(t) {
    if (t < 7) return(FALSE)
    sum(below80[(t - 6):t]) >= 5
  }, logical(1))
  flagged <- flag95 | flag80
  if (!any(flagged)) return(NULL)
  dev <- (actual[flagged] - lo95[flagged]) / lo95[flagged] * 100
  severity <- dplyr::case_when(
    sum(flagged) >= 4 | min(dev) <= -30 ~ "high",
    sum(flagged) >= 2 | min(dev) <= -15 ~ "medium",
    TRUE ~ "low"
  )
  data.frame(
    first_flag_date = dates[which(flagged)[1]],
    days_flagged = sum(flagged),
    worst_deviation_pct = min(dev),
    severity = severity,
    stringsAsFactors = FALSE
  )
}

main_detect <- function() {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  series <- build_daily_series()
  bt <- run_backtest(series)
  winners <- pick_winner(bt)

  holdout_start <- max(series$date) - 13  # last 14 days
  holdout <- series %>% filter(date >= holdout_start)
  ts <- as_series_tsibble(series)

  rows <- list()
  for (i in seq_len(nrow(winners))) {
    metric_name <- winners$metric[i]
    model_name <- winners$model[i]
    train_ts <- ts %>% filter(date < holdout_start, metric == metric_name)
    nd <- new_data_tsibble(holdout$date, metric_name)
    fc <- fit_models(train_ts) %>%
      forecast(new_data = nd) %>%
      filter(.model == model_name) %>%
      hilo(level = c(80, 95)) %>%
      as_tibble()

    actual <- holdout[[metric_name]]
    lo80 <- vapply(fc$`80%`, function(x) x$lower, numeric(1))
    lo95 <- vapply(fc$`95%`, function(x) x$lower, numeric(1))

    d <- detect_regressions(holdout$date, actual, lo80, lo95)
    if (is.null(d)) {
      message("No regression flagged for ", metric_name, " (model: ", model_name, ")")
    } else {
      rows[[length(rows) + 1]] <- data.frame(metric = metric_name, d, model = model_name)
    }
  }

  if (length(rows) == 0) {
    res <- data.frame(
      metric = "(none)",
      first_flag_date = NA,
      days_flagged = 0,
      worst_deviation_pct = NA_real_,
      severity = "no regression detected",
      model = NA,
      stringsAsFactors = FALSE
    )
  } else {
    res <- bind_rows(rows)
  }
  write_results(res, "regressions.csv")
}

if (sys.nframe() == 0) main_detect()
