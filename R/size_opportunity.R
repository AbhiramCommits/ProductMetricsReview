#!/usr/bin/env Rscript
# size_opportunity.R -- size ONE product change: improving the view_item ->
# add_to_cart funnel step (the largest absolute drop from Q2).
#
# Every measured input is read from output/ (never hardcoded); every assumed
# input comes from config/assumptions.yml with a stated low / point / high.
# The relative lift is an ASSUMPTION, not a measured effect -- this is stated
# plainly in the output.
#
# Outputs:
#   output/opportunity_sizing.csv -- the sizing line items and results
#   output/sensitivity.csv       -- one-at-a-time tornado over assumed inputs

suppressPackageStartupMessages({
  library(dplyr)
  library(yaml)
})

options(digits = 15)

args <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
ROOT <- if (length(file_arg) && nzchar(file_arg)) {
  normalizePath(dirname(dirname(file_arg)))
} else {
  getwd()
}
OUTPUT_DIR <- file.path(ROOT, "output")
CONFIG_PATH <- file.path(ROOT, "config", "assumptions.yml")

write_results <- function(df, name) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(OUTPUT_DIR, name)
  write.csv(df, path, row.names = FALSE)
  message("Wrote ", path)
}

# Resolve a measured input: read the CSV named in the config from output/,
# optionally filter rows, take the named field, sum across rows.
resolve_measured <- function(entry) {
  df <- read.csv(file.path(ROOT, entry$source), stringsAsFactors = FALSE)
  if (!is.null(entry$where)) {
    parts <- trimws(strsplit(entry$where, "==", fixed = TRUE)[[1]])
    df <- df[df[[parts[1]]] == parts[2], ]
  }
  sum(df[[entry$field]])
}

net_benefit <- function(lift, margin, build, maint, base_carts_year, ctp, aov) {
  revenue <- base_carts_year * lift * ctp * aov
  revenue * margin - build - maint
}

main <- function() {
  cfg <- read_yaml(CONFIG_PATH)
  inputs <- cfg$inputs

  measured <- list(
    baseline_step_conversion = resolve_measured(inputs$baseline_step_conversion),
    addressable_sessions_92d = resolve_measured(inputs$addressable_sessions_92d),
    carts_pooled = resolve_measured(inputs$carts_pooled),
    purchases_pooled = resolve_measured(inputs$purchases_pooled),
    aov_usd = resolve_measured(inputs$aov_usd)
  )
  assumed <- list(
    relative_lift = inputs$relative_lift,
    gross_margin = inputs$gross_margin,
    build_cost_usd = inputs$build_cost_usd,
    yearly_maintenance_usd = inputs$yearly_maintenance_usd
  )

  addressable_sessions_year <- measured$addressable_sessions_92d * 365 / cfg$window$days
  cart_to_purchase <- measured$purchases_pooled / measured$carts_pooled
  base_carts_year <- addressable_sessions_year * measured$baseline_step_conversion

  p <- assumed$relative_lift$point
  m <- assumed$gross_margin$point
  b <- assumed$build_cost_usd$point
  mt <- assumed$yearly_maintenance_usd$point

  incremental_carts_year <- base_carts_year * p
  incremental_purchases_year <- incremental_carts_year * cart_to_purchase
  incremental_revenue_year <- incremental_purchases_year * measured$aov_usd
  incremental_gross_profit_year <- incremental_revenue_year * m
  total_cost <- b + mt
  net <- incremental_gross_profit_year - total_cost
  roi <- net / total_cost
  annual_cash_flow <- incremental_gross_profit_year - mt
  payback_months <- if (annual_cash_flow <= 0) Inf else b / (annual_cash_flow / 12)
  break_even_lift <- total_cost / (base_carts_year * cart_to_purchase * measured$aov_usd * m)

  rows <- list(
    c("baseline_step_conversion", measured$baseline_step_conversion, "fraction", "measured", inputs$baseline_step_conversion$source),
    c("addressable_sessions_92d", measured$addressable_sessions_92d, "sessions", "measured", inputs$addressable_sessions_92d$source),
    c("addressable_sessions_year", addressable_sessions_year, "sessions", "calculated", "addressable_sessions_92d * 365/92"),
    c("cart_to_purchase_conversion", cart_to_purchase, "fraction", "measured", "pooled from output/q2_funnel_steps.csv"),
    c("relative_lift", p, "fraction", "assumed", "config/assumptions.yml (low/point/high)"),
    c("aov_usd", measured$aov_usd, "usd", "measured", inputs$aov_usd$source),
    c("gross_margin", m, "fraction", "assumed", "config/assumptions.yml (low/point/high)"),
    c("incremental_carts_year", incremental_carts_year, "carts", "calculated", "addressable_year * baseline * lift"),
    c("incremental_purchases_year", incremental_purchases_year, "purchases", "calculated", "incremental_carts * cart_to_purchase"),
    c("incremental_revenue_year", incremental_revenue_year, "usd", "calculated", "purchases * aov"),
    c("incremental_gross_profit_year", incremental_gross_profit_year, "usd", "calculated", "revenue * gross_margin"),
    c("build_cost_usd", b, "usd", "assumed", "config/assumptions.yml (low/point/high)"),
    c("yearly_maintenance_usd", mt, "usd", "assumed", "config/assumptions.yml (low/point/high)"),
    c("net_benefit_year1", net, "usd", "calculated", "gross_profit - build - maintenance"),
    c("roi_year1", roi, "fraction", "calculated", "net_benefit / total_cost"),
    c("payback_months", payback_months, "months", "calculated", "build / ((gross_profit - maintenance) / 12)"),
    c("break_even_lift", break_even_lift, "fraction", "calculated", "lift where net benefit = 0"),
    c("disclaimer", NA, "", "assumed", "The relative lift is an ASSUMPTION, not a measured effect.")
  )
  sizing <- data.frame(
    item = vapply(rows, `[`, character(1), 1),
    value = as.numeric(vapply(rows, `[`, character(1), 2)),
    unit = vapply(rows, `[`, character(1), 3),
    basis = vapply(rows, `[`, character(1), 4),
    source = vapply(rows, `[`, character(1), 5),
    stringsAsFactors = FALSE
  )
  write_results(sizing, "opportunity_sizing.csv")

  # One-at-a-time tornado: each assumed input at low/point/high, others at point.
  net_at <- function(name, level) {
    args <- lapply(names(assumed), function(nm) assumed[[nm]]$point)
    names(args) <- names(assumed)
    args[[name]] <- assumed[[name]][[level]]
    net_benefit(
      lift = args$relative_lift, margin = args$gross_margin,
      build = args$build_cost_usd, maint = args$yearly_maintenance_usd,
      base_carts_year = base_carts_year, ctp = cart_to_purchase, aov = measured$aov_usd
    )
  }
  sens <- lapply(names(assumed), function(nm) {
    lo <- net_at(nm, "low")
    pt <- net_at(nm, "point")
    hi <- net_at(nm, "high")
    data.frame(
      input = nm,
      low_value = assumed[[nm]]$low,
      point_value = assumed[[nm]]$point,
      high_value = assumed[[nm]]$high,
      net_benefit_low = lo,
      net_benefit_point = pt,
      net_benefit_high = hi,
      swing = abs(hi - lo),
      stringsAsFactors = FALSE
    )
  }) %>% bind_rows() %>% arrange(desc(swing))
  write_results(sens, "sensitivity.csv")
}

if (sys.nframe() == 0) main()
