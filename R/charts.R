#!/usr/bin/env Rscript
# charts.R -- ggplot2 charts for the decision memo, one shared theme,
# Okabe-Ito palette, PNG at 1600px wide / 150 dpi into charts/ (committed).
# Every title states the takeaway; axis labels carry units; captions name
# the source table and the sample date range.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(scales)
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
CHARTS_DIR <- file.path(ROOT, "charts")

WINDOW_LABEL <- "GA4 sample, 2020-11-01 to 2021-01-31"

OKABE_ITO <- c("#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7", "#000000")
names(OKABE_ITO) <- c("orange", "sky_blue", "green", "yellow", "blue", "vermilion", "purple", "black")

okabe <- function(nm) unname(OKABE_ITO[nm])

theme_pmr <- function(base_size = 18) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.title = element_text(face = "bold", size = rel(1.05)),
      panel.grid.minor = element_blank(),
      legend.position = "bottom",
      plot.caption = element_text(hjust = 0, size = rel(0.65), colour = "grey40")
    )
}

W_IN <- 1600 / 150

save_png <- function(p, file, height = 6.5) {
  dir.create(CHARTS_DIR, recursive = TRUE, showWarnings = FALSE)
  ggsave(file.path(CHARTS_DIR, file), p, width = W_IN, height = height, units = "in", dpi = 150)
  message("Wrote ", file.path(CHARTS_DIR, file))
}

read_out <- function(name) read.csv(file.path(OUTPUT_DIR, name), stringsAsFactors = FALSE)

# 1. DAU actuals + forecast with 80/95% ribbons, holdout marked.
chart_dau <- function() {
  da <- read_parquet(file.path(SNAPSHOT_DIR, "daily_active.parquet"))
  fc <- read_out("forecasts.csv") %>% filter(metric == "dau") %>% mutate(date = as.Date(date))
  actual <- data.frame(date = da$event_date, dau = as.numeric(da$dau))
  holdout_start <- max(actual$date) - 13

  p <- ggplot() +
    annotate(
      "rect", xmin = holdout_start, xmax = max(fc$date), ymin = -Inf, ymax = Inf,
      fill = "grey85", alpha = 0.55
    ) +
    geom_ribbon(data = fc, aes(date, ymin = lo95, ymax = hi95), fill = okabe("sky_blue"), alpha = 0.15) +
    geom_ribbon(data = fc, aes(date, ymin = lo80, ymax = hi80), fill = okabe("sky_blue"), alpha = 0.25) +
    geom_line(data = actual, aes(date, dau, colour = "actual"), linewidth = 1) +
    geom_line(data = fc, aes(date, forecast, colour = "forecast (ETS)"), linewidth = 1) +
    annotate("text", x = holdout_start + 1, y = min(actual$dau) * 0.92, label = "holdout", hjust = 0, size = 5) +
    scale_colour_manual(values = c("actual" = okabe("vermilion"), "forecast (ETS)" = okabe("sky_blue"))) +
    scale_y_continuous(labels = comma) +
    labs(
      title = paste0(
        "No regression: DAU runs ", comma(round(mean(actual$dau), -2)),
        "/day on average and the forecast is flat through mid-February"
      ),
      x = NULL, y = "Daily active users", colour = NULL,
      caption = "Source: data/snapshot/daily_active.parquet and output/forecasts.csv (GA4 sample, 2020-11-01 to 2021-01-31); 80% and 95% prediction intervals."
    ) +
    theme_pmr()
  save_png(p, "dau_forecast.png")
}

# 2. Funnel by device with step-drop CIs.
chart_funnel <- function() {
  fd <- read_out("q2_funnel_steps.csv")
  fd <- fd %>%
    mutate(
      step_label = factor(case_when(
        step_to == "view_item_sessions" ~ "view item",
        step_to == "add_to_cart_sessions" ~ "add to cart",
        step_to == "begin_checkout_sessions" ~ "begin checkout",
        TRUE ~ "purchase"
      ), levels = c("view item", "add to cart", "begin checkout", "purchase")),
      device_category = factor(device_category, levels = c("desktop", "mobile", "tablet"))
    )
  worst_conv <- min(fd$conversion)
  worst_step <- as.character(fd$step_label[which.min(fd$conversion)])

  p <- ggplot(fd, aes(step_label, conversion * 100, colour = device_category, group = device_category)) +
    geom_pointrange(aes(ymin = ci_low * 100, ymax = ci_high * 100), position = position_dodge(width = 0.3), linewidth = 0.7) +
    geom_line(position = position_dodge(width = 0.3), alpha = 0.4) +
    scale_colour_manual(values = c(
      desktop = okabe("blue"), mobile = okabe("vermilion"), tablet = okabe("green")
    )) +
    scale_y_continuous(labels = percent_format(scale = 1)) +
    labs(
      title = paste0(
        "The view item -> add to cart step is the cliff (about ",
        round(worst_conv * 100), "% convert) and no device is meaningfully better"
      ),
      x = "Funnel step reached", y = "Sessions converting to this step (%)", colour = "Device",
      caption = "Source: data/snapshot/funnel_daily.parquet via output/q2_funnel_steps.csv (GA4 sample, 2020-11-01 to 2021-01-31); ordered funnel, Wilson 95% CIs."
    ) +
    theme_pmr()
  save_png(p, "funnel_by_device.png")
}

# 3. Device odds ratios from the logistic regression.
chart_device_or <- function() {
  ors <- read_out("q1_logistic_or.csv") %>%
    filter(startsWith(term, "device_category")) %>%
    mutate(term_label = factor(term_label, levels = rev(term_label)))
  straddles <- all(ors$ci_low < 1 & ors$ci_high > 1)

  p <- ggplot(ors, aes(odds_ratio, term_label, xmin = ci_low, xmax = ci_high)) +
    geom_vline(xintercept = 1, linetype = "dashed", colour = "grey50") +
    geom_pointrange(colour = okabe("blue"), linewidth = 0.9, size = 0.4) +
    scale_x_log10(labels = function(x) sprintf("%.2f", x)) +
    labs(
      title = if (straddles) {
        "After controls, mobile and tablet convert like desktop: odds ratios straddle 1"
      } else {
        "After controls, device still shifts conversion odds"
      },
      x = "Odds of purchase vs desktop (log scale; >1 means higher)", y = NULL,
      caption = "Source: data/snapshot/session_outcomes.parquet via output/q1_logistic_or.csv (GA4 sample, 2020-11-01 to 2021-01-31); logistic regression with returning-user, country and week controls; 95% profile CIs."
    ) +
    theme_pmr()
  save_png(p, "device_odds_ratios.png")
}

# 4. Retention cohort heatmap.
chart_retention <- function() {
  rc <- read_parquet(file.path(SNAPSHOT_DIR, "retention_cohorts.parquet"))
  rc <- rc %>%
    mutate(
      retention = retained_users / cohort_size,
      cohort_week = as.Date(cohort_week)
    )
  week4 <- mean(rc$retention[rc$weeks_since_first_visit == 4])

  p <- ggplot(rc, aes(cohort_week, weeks_since_first_visit, fill = retention)) +
    geom_tile(colour = "white") +
    scale_fill_gradient(low = "white", high = okabe("blue"), labels = percent) +
    scale_x_date(date_labels = "%b %d") +
    scale_y_continuous(breaks = 0:8) +
    labs(
      title = paste0(
        "Retention falls to about ", round(week4 * 100), "% by week 4 and stays there; ",
        "recent cohorts still have unobserved weeks"
      ),
      x = "Cohort (week of first visit)", y = "Weeks since first visit",
      fill = "Retained",
      caption = "Source: data/snapshot/retention_cohorts.parquet (GA4 sample, 2020-11-01 to 2021-01-31); Monday-anchored weekly cohorts, right-censored at the window end."
    ) +
    theme_pmr()
  save_png(p, "retention_heatmap.png", height = 6.8)
}

# 5. Tornado chart for the sizing.
chart_tornado <- function() {
  sens <- read_out("sensitivity.csv") %>%
    mutate(input_label = recode(input,
      relative_lift = "relative lift (assumed)",
      gross_margin = "gross margin (assumed)",
      build_cost_usd = "build cost (assumed)",
      yearly_maintenance_usd = "yearly maintenance (assumed)"
    )) %>%
    mutate(input_label = factor(input_label, levels = rev(input_label)))
  top_input <- as.character(sens$input_label[1])

  p <- ggplot(sens, aes(y = input_label)) +
    geom_linerange(aes(xmin = net_benefit_low, xmax = net_benefit_high), linewidth = 6, colour = okabe("sky_blue")) +
    geom_point(aes(x = net_benefit_point), colour = okabe("black"), size = 2) +
    geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
    scale_x_continuous(labels = dollar) +
    labs(
      title = paste0(
        "Year-1 net benefit swings most with the assumed ", top_input,
        "; build cost matters least"
      ),
      x = "Net benefit year 1 (USD, one input at low/point/high)", y = NULL,
      caption = "Source: output/sensitivity.csv (GA4 sample, 2020-11-01 to 2021-01-31); one-at-a-time variation around the point sizing; dots mark the point estimate."
    ) +
    theme_pmr()
  save_png(p, "sizing_tornado.png")
}

main <- function() {
  chart_dau()
  chart_funnel()
  chart_device_or()
  chart_retention()
  chart_tornado()
}

if (sys.nframe() == 0) main()
