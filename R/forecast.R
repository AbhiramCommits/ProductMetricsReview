#!/usr/bin/env Rscript
# forecast.R -- daily forecasts for dau, purchase_sessions and revenue_usd,
# computed from the committed snapshot only.
#
# Models compared with fable: ETS (weekly season), ARIMA, and SNAIVE (weekly
# lag) as the baseline. A model only "wins" if it beats SNAIVE.
#
# Backtest: rolling-origin CV -- minimum 42-day training window, 7-day
# horizon, origins advancing 7 days. MAE / RMSE / MAPE per model per series
# per fold, plus the fold mean, in output/backtest.csv. The winner per series
# then produces a 14-day forecast with 80% and 95% intervals in
# output/forecasts.csv.
#
# Holiday handling: the window contains Black Friday (2020-11-27) and the
# Christmas period, which are structural level shifts rather than weekly
# seasonality. Approach: an explicit holiday dummy (2020-11-27 .. 2020-12-25)
# as an exogenous regressor for ARIMA -- the model class where a level shift
# is hardest to represent otherwise. ETS and SNAIVE cannot take exogenous
# regressors and are left to absorb the spike through their own adaptation.
# The alternative considered (reporting accuracy with and without the holiday
# weeks) was rejected because it removes the most business-critical days from
# the evaluation.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(tidyr)
  library(tsibble)
  library(fable)
})

options(digits = 15)

args <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
ROOT <- if (length(file_arg) && nzchar(file_arg)) {
  normalizePath(dirname(dirname(file_arg)))
} else {
  getwd()
}
SNAPSHOT_DIR <- file.path(ROOT, "data", "snapshot")
OUTPUT_DIR <- file.path(ROOT, "output")

MIN_TRAIN <- 42
HORIZON <- 7
STEP <- 7
FINAL_HORIZON <- 14
METRICS <- c("dau", "purchase_sessions", "revenue_usd")

HOLIDAY_START <- as.Date("2020-11-27")
HOLIDAY_END <- as.Date("2020-12-25")

read_snapshot <- function(name) {
  read_parquet(file.path(SNAPSHOT_DIR, paste0(name, ".parquet")))
}

write_results <- function(df, name) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(OUTPUT_DIR, name)
  write.csv(df, path, row.names = FALSE)
  message("Wrote ", path)
}

# Daily series from the snapshot; purchase_sessions and revenue_usd are summed
# across device rows of revenue_daily.
build_daily_series <- function() {
  da <- read_snapshot("daily_active")
  rv <- read_snapshot("revenue_daily")
  rv_day <- rv %>%
    group_by(event_date) %>%
    summarise(purchases = sum(purchases), revenue_usd = sum(revenue_usd), .groups = "drop")
  da %>%
    select(event_date, dau) %>%
    inner_join(rv_day, by = "event_date") %>%
    transmute(
      date = event_date,
      dau = as.numeric(dau),
      purchase_sessions = as.numeric(purchases),
      revenue_usd = as.numeric(revenue_usd),
      holiday = as.numeric(date >= HOLIDAY_START & date <= HOLIDAY_END)
    ) %>%
    arrange(date)
}

# Rolling-origin folds: growing training window starting at the first date,
# train_end advancing STEP days at a time, testing the HORIZON days after it.
build_folds <- function(dates, min_train = MIN_TRAIN, horizon = HORIZON, step = STEP) {
  n <- length(dates)
  origins <- seq(min_train, n - horizon, by = step)
  lapply(origins, function(o) {
    list(
      fold = which(origins == o),
      train_start = dates[1],
      train_end = dates[o],
      test_start = dates[o + 1],
      test_end = dates[o + horizon]
    )
  })
}

as_series_tsibble <- function(series) {
  as_tsibble(
    series %>%
      pivot_longer(all_of(METRICS), names_to = "metric", values_to = "y"),
    key = metric, index = date
  )
}

new_data_tsibble <- function(dates, metrics = METRICS) {
  as_tsibble(
    crossing(date = dates, metric = metrics) %>%
      mutate(holiday = as.numeric(date >= HOLIDAY_START & date <= HOLIDAY_END)),
    key = metric, index = date
  )
}

fit_models <- function(train_ts) {
  train_ts %>%
    model(
      snaive = SNAIVE(y ~ lag("week")),
      ets = ETS(y ~ season(period = 7)),
      arima = ARIMA(y ~ holiday)
    )
}

run_backtest <- function(series) {
  ts <- as_series_tsibble(series)
  dates <- sort(unique(series$date))
  folds <- build_folds(dates)
  actual_long <- series %>%
    select(date, all_of(METRICS)) %>%
    pivot_longer(all_of(METRICS), names_to = "metric", values_to = "y")

  rows <- list()
  for (fd in folds) {
    train <- ts %>% filter(date <= fd$train_end)
    test_dates <- dates[dates >= fd$test_start & dates <= fd$test_end]
    nd <- new_data_tsibble(test_dates)
    fc <- fit_models(train) %>%
      forecast(new_data = nd) %>%
      as_tibble() %>%
      select(metric, date, .model, .mean) %>%
      left_join(actual_long, by = c("metric", "date")) %>%
      mutate(e = .mean - y)

    stats <- fc %>%
      group_by(metric, .model) %>%
      summarise(mae = mean(abs(e)), rmse = sqrt(mean(e^2)), .groups = "drop")
    mapes <- fc %>%
      filter(y != 0) %>%
      group_by(metric, .model) %>%
      summarise(mape = mean(abs(e / y) * 100), .groups = "drop")
    stats <- left_join(stats, mapes, by = c("metric", ".model"))

    rows[[length(rows) + 1]] <- stats %>%
      mutate(
        fold = as.character(fd$fold),
        train_end = fd$train_end,
        test_start = fd$test_start,
        test_end = fd$test_end
      ) %>%
      select(metric, model = .model, fold, train_end, test_start, test_end, mae, rmse, mape)
  }

  folds_df <- bind_rows(rows)
  means <- folds_df %>%
    group_by(metric, model) %>%
    summarise(
      mae = mean(mae), rmse = mean(rmse), mape = mean(mape),
      .groups = "drop"
    ) %>%
    mutate(fold = "mean", train_end = NA, test_start = NA, test_end = NA)
  bind_rows(folds_df, means)
}

# Winner = lowest mean fold RMSE among models that beat SNAIVE; if no model
# beats SNAIVE, SNAIVE is the winner.
pick_winner <- function(backtest) {
  means <- backtest %>% filter(fold == "mean")
  winners <- list()
  for (m in unique(means$metric)) {
    mm <- means %>% filter(metric == m)
    snaive_rmse <- mm$rmse[mm$model == "snaive"]
    cands <- mm %>% filter(model != "snaive", rmse < snaive_rmse)
    winner <- if (nrow(cands) > 0) cands$model[which.min(cands$rmse)] else "snaive"
    winners[[m]] <- data.frame(
      metric = m,
      model = winner,
      mean_rmse = mm$rmse[mm$model == winner],
      beat_snaive = winner != "snaive",
      stringsAsFactors = FALSE
    )
  }
  bind_rows(winners)
}

make_final_forecast <- function(series, winner_row) {
  ts <- as_series_tsibble(series) %>% filter(metric == winner_row$metric)
  future_dates <- seq(max(series$date) + 1, by = "day", length.out = FINAL_HORIZON)
  nd <- new_data_tsibble(future_dates, winner_row$metric)
  fc <- fit_models(ts) %>%
    forecast(new_data = nd) %>%
    filter(.model == winner_row$model) %>%
    hilo(level = c(80, 95)) %>%
    as_tibble()
  data.frame(
    metric = fc$metric,
    date = fc$date,
    forecast = fc$.mean,
    lo80 = vapply(fc$`80%`, function(x) x$lower, numeric(1)),
    hi80 = vapply(fc$`80%`, function(x) x$upper, numeric(1)),
    lo95 = vapply(fc$`95%`, function(x) x$lower, numeric(1)),
    hi95 = vapply(fc$`95%`, function(x) x$upper, numeric(1)),
    model = fc$.model
  )
}

main <- function() {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  message("Building daily series from snapshot ...")
  series <- build_daily_series()

  message("Rolling-origin backtest (min train 42d, horizon 7d, step 7d) ...")
  bt <- run_backtest(series)
  write_results(bt, "backtest.csv")

  winners <- pick_winner(bt)
  write_results(winners, "forecast_winners.csv")

  message("Producing 14-day forecasts from winners ...")
  fc <- bind_rows(lapply(seq_len(nrow(winners)), function(i) {
    make_final_forecast(series, winners[i, ])
  }))
  write_results(fc, "forecasts.csv")
}

if (sys.nframe() == 0) main()
