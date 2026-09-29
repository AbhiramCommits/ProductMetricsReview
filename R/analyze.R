#!/usr/bin/env Rscript
# analyze.R -- statistics for three product questions, computed from the
# committed snapshot only (no BigQuery access). Every result is written to
# output/ as CSV; the console is only used for progress messages.
#
#   Q1. Does mobile convert worse than desktop, and by how much?
#   Q2. Which funnel step loses the most sessions, and does that differ by device?
#   Q3. Did the holiday peak change purchase value, or only volume?

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(tidyr)
  library(broom)
  library(boot)
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

SEED <- 20261101
BOOT_R <- 10000
CONF <- 0.95

PRE_START <- as.Date("2020-11-01")
PRE_END <- as.Date("2020-11-26")   # day before Black Friday (Nov 27, 2020)
POST_START <- as.Date("2020-11-27")
POST_END <- as.Date("2020-12-25")

read_snapshot <- function(name) {
  read_parquet(file.path(SNAPSHOT_DIR, paste0(name, ".parquet")))
}

write_results <- function(df, name) {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(OUTPUT_DIR, name)
  write.csv(df, path, row.names = FALSE)
  message("Wrote ", path)
}

pct <- function(x) paste0(sprintf("%.2f", x * 100), "%")

# Closed-form Wilson score interval for a proportion.
wilson_ci <- function(k, n, conf = CONF) {
  z <- qnorm(1 - (1 - conf) / 2)
  p <- k / n
  denom <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / denom
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  c(low = centre - half, high = centre + half)
}

# Q1 ---------------------------------------------------------------------------

fit_q1_model <- function(so) {
  top10 <- so %>%
    count(country, sort = TRUE) %>%
    slice_head(n = 10) %>%
    pull(country)
  so %>%
    mutate(
      country_group = if_else(country %in% top10, country, "Other"),
      country_group = relevel(factor(country_group), ref = top10[1]),
      device_category = factor(device_category, levels = c("desktop", "mobile", "tablet")),
      week_idx = as.integer(as.numeric(difftime(event_date, min(event_date), units = "days")) %/% 7)
    ) %>%
    glm(
      purchased ~ device_category + is_returning_user + country_group + week_idx,
      data = ., family = binomial()
    )
}

question1 <- function(so) {
  rates <- so %>%
    group_by(device_category) %>%
    summarise(sessions = n(), conversions = sum(purchased), .groups = "drop") %>%
    rowwise() %>%
    mutate(
      rate = conversions / sessions,
      ci_low = wilson_ci(conversions, sessions)["low"],
      ci_high = wilson_ci(conversions, sessions)["high"]
    ) %>%
    ungroup()
  write_results(rates, "q1_device_rates.csv")

  # Raw mobile vs desktop gap (unadjusted).
  mob <- rates %>% filter(device_category == "mobile")
  desk <- rates %>% filter(device_category == "desktop")
  pt <- prop.test(
    c(mob$conversions, desk$conversions),
    c(mob$sessions, desk$sessions),
    correct = FALSE
  )
  gap <- data.frame(
    comparison = "mobile_minus_desktop",
    diff = as.numeric(pt$estimate[1] - pt$estimate[2]),
    ci_low = pt$conf.int[1],
    ci_high = pt$conf.int[2],
    p_value = pt$p.value,
    relative_lift_pct = (mob$rate - desk$rate) / desk$rate * 100
  )
  write_results(gap, "q1_rate_difference.csv")

  # Adjusted effect: logistic regression of purchase on device + controls.
  m <- fit_q1_model(so)
  ors <- tidy(m, exponentiate = TRUE, conf.int = TRUE, conf.level = CONF)
  label_term <- function(term) {
    dplyr::case_when(
      term == "(Intercept)" ~ "intercept",
      startsWith(term, "device_category") ~ paste0("device: ", sub("^device_category", "", term)),
      startsWith(term, "country_group") ~ paste0("country: ", sub("^country_group", "", term)),
      term == "is_returning_user" ~ "returning user (vs new)",
      term == "week_idx" ~ "week index (per week)",
      TRUE ~ term
    )
  }
  ors <- ors %>%
    mutate(
      term_label = vapply(term, label_term, character(1)),
      reference = dplyr::case_when(
        startsWith(term, "device_category") ~ "desktop",
        startsWith(term, "country_group") ~ "United States",
        term == "is_returning_user" ~ "0 (new)",
        term == "week_idx" ~ "numeric",
        TRUE ~ ""
      )
    ) %>%
    select(
      term, term_label, reference, odds_ratio = estimate, std.error,
      statistic, p_value = p.value, ci_low = conf.low, ci_high = conf.high
    )
  write_results(ors, "q1_logistic_or.csv")
  write_results(
    data.frame(n_obs = nobs(m), converged = m$converged, aic = AIC(m)),
    "q1_model_meta.csv"
  )

  mob_or <- ors %>% filter(term == "device_categorymobile")
  survives <- isTRUE(mob_or$ci_high < 1)
  summary <- data.frame(
    question = "Q1: does mobile convert worse than desktop, and by how much?",
    estimate = mob_or$odds_ratio,
    ci_low = mob_or$ci_low,
    ci_high = mob_or$ci_high,
    test = "logistic regression (Wald); unadjusted two-sample prop.test",
    p_value = mob_or$p_value,
    answer = paste0(
      "Mobile converts at ", pct(mob$rate), " vs desktop ", pct(desk$rate),
      " (raw gap ", sprintf("%.2f pp", gap$diff * 100), "); after controlling for returning status, country group and week, ",
      "the mobile odds ratio is ", sprintf("%.2f", mob_or$odds_ratio),
      " [", sprintf("%.2f", mob_or$ci_low), ", ", sprintf("%.2f", mob_or$ci_high), "], ",
      "so the device gap ", if (survives) "survives the controls" else "does NOT survive the controls", "."
    ),
    stringsAsFactors = FALSE
  )
  list(summary = summary, rates = rates, ors = ors)
}

# Q2 ---------------------------------------------------------------------------

question2 <- function(fd) {
  pooled <- fd %>%
    group_by(device_category) %>%
    summarise(
      sessions = sum(sessions),
      view_item_sessions = sum(view_item_sessions),
      add_to_cart_sessions = sum(add_to_cart_sessions),
      begin_checkout_sessions = sum(begin_checkout_sessions),
      purchase_sessions = sum(purchase_sessions),
      .groups = "drop"
    )

  steps <- data.frame(
    step_from = c("sessions", "view_item_sessions", "add_to_cart_sessions", "begin_checkout_sessions"),
    step_to = c("view_item_sessions", "add_to_cart_sessions", "begin_checkout_sessions", "purchase_sessions"),
    stringsAsFactors = FALSE
  )
  rows <- lapply(seq_len(nrow(steps)), function(i) {
    f <- steps$step_from[i]
    t <- steps$step_to[i]
    data.frame(
      device_category = pooled$device_category,
      step_from = f,
      step_to = t,
      entered = pooled[[f]],
      exited = pooled[[t]],
      stringsAsFactors = FALSE
    )
  })
  step_df <- bind_rows(rows) %>%
    rowwise() %>%
    mutate(
      conversion = exited / entered,
      dropped_sessions = entered - exited,
      ci_low = wilson_ci(exited, entered)["low"],
      ci_high = wilson_ci(exited, entered)["high"]
    ) %>%
    ungroup()
  write_results(step_df, "q2_funnel_steps.csv")

  worst <- step_df %>%
    group_by(step_from, step_to) %>%
    summarise(entered = sum(entered), exited = sum(exited), .groups = "drop") %>%
    mutate(dropped = entered - exited) %>%
    arrange(desc(dropped)) %>%
    slice(1)

  worst_rows <- step_df %>% filter(step_from == worst$step_from)
  tbl <- cbind(worst_rows$exited, worst_rows$entered - worst_rows$exited)
  rownames(tbl) <- worst_rows$device_category
  ch <- chisq.test(tbl)
  worst_ci <- wilson_ci(worst$exited, worst$entered)
  worst_df <- data.frame(
    step_from = worst$step_from,
    step_to = worst$step_to,
    entered_pooled = worst$entered,
    exited_pooled = worst$exited,
    conversion_pooled = worst$exited / worst$entered,
    ci_low = worst_ci["low"],
    ci_high = worst_ci["high"],
    dropped_sessions = worst$dropped,
    chi_sq = as.numeric(ch$statistic),
    df = as.numeric(ch$parameter),
    p_value = ch$p.value,
    stringsAsFactors = FALSE
  )
  write_results(worst_df, "q2_worst_step_test.csv")

  summary <- data.frame(
    question = "Q2: which funnel step loses the most sessions, and does that differ by device?",
    estimate = worst_df$conversion_pooled,
    ci_low = worst_df$ci_low,
    ci_high = worst_df$ci_high,
    test = "chi-square of step conversion by device (worst step)",
    p_value = ch$p.value,
    answer = paste0(
      "The single largest absolute drop is ", worst$step_from, " -> ", worst$step_to,
      ", losing ", format(worst$dropped, big.mark = ","), " sessions (conversion ",
      pct(worst_df$conversion_pooled), "); conversion of that step does ",
      if (ch$p.value < 0.05) "differ" else "not differ",
      " by device (chi-sq = ", sprintf("%.1f", ch$statistic), ", df = ", ch$parameter,
      ", p = ", format.pval(ch$p.value, digits = 3), ")."
    ),
    stringsAsFactors = FALSE
  )
  list(summary = summary, step_df = step_df, worst = worst_df)
}

# Q3 ---------------------------------------------------------------------------

aov_bca <- function(pre, post, R = BOOT_R, seed = SEED, conf = CONF) {
  d <- data.frame(
    revenue = c(pre, post),
    window = factor(c(rep("pre", length(pre)), rep("post", length(post))))
  )
  stat <- function(data, i) {
    x <- data[i, ]
    m <- tapply(x$revenue, x$window, mean)
    unname(m["post"] - m["pre"])
  }
  set.seed(seed)
  b <- boot::boot(d, stat, R = R, strata = d$window)
  ci <- boot::boot.ci(b, conf = conf, type = "bca")
  list(
    estimate = as.numeric(b$t0),
    ci_low = ci$bca[4],
    ci_high = ci$bca[5],
    R = R,
    seed = seed,
    pre_mean = mean(pre),
    post_mean = mean(post)
  )
}

question3 <- function(so) {
  purch <- so %>% filter(purchased == 1)
  in_pre <- purch$event_date >= PRE_START & purch$event_date <= PRE_END
  in_post <- purch$event_date >= POST_START & purch$event_date <= POST_END
  pre_p <- purch[in_pre, ]
  post_p <- purch[in_post, ]

  # Obfuscated NULL revenue arrives as 0 from SQL; exclude it from AOV rather
  # than silently averaging it in (kept, and reported, for the volume count).
  aov_pre <- pre_p$revenue_usd[pre_p$revenue_usd > 0]
  aov_post <- post_p$revenue_usd[post_p$revenue_usd > 0]

  res <- aov_bca(aov_pre, aov_post)

  pre_days <- as.numeric(PRE_END - PRE_START) + 1
  post_days <- as.numeric(POST_END - POST_START) + 1
  pre_per_day <- nrow(pre_p) / pre_days
  post_per_day <- nrow(post_p) / post_days

  q3 <- data.frame(
    metric = c("aov_usd", "purchase_sessions", "purchase_sessions_per_day"),
    pre = c(res$pre_mean, nrow(pre_p), pre_per_day),
    post = c(res$post_mean, nrow(post_p), post_per_day),
    change = c(
      res$estimate,
      (nrow(post_p) - nrow(pre_p)) / nrow(pre_p) * 100,
      (post_per_day - pre_per_day) / pre_per_day * 100
    ),
    change_unit = c("usd_per_order", "pct", "pct"),
    ci_low = c(res$ci_low, NA, NA),
    ci_high = c(res$ci_high, NA, NA),
    p_value = NA_real_,
    note = c(
      paste0(
        "AOV over purchasing sessions with recorded revenue > 0; zero-revenue ",
        "purchases excluded (obfuscated NULL revenue). BCa bootstrap, R = ", res$R,
        ", seed = ", res$seed, "."
      ),
      "All purchasing sessions, including zero-revenue (obfuscated) ones.",
      paste0("Window lengths: pre ", pre_days, "d, post ", post_days, "d.")
    ),
    stringsAsFactors = FALSE
  )
  write_results(q3, "q3_holiday_value_volume.csv")

  volume_change_pct <- (post_per_day - pre_per_day) / pre_per_day * 100
  summary <- data.frame(
    question = "Q3: did the holiday peak change purchase value, or only volume?",
    estimate = res$estimate,
    ci_low = res$ci_low,
    ci_high = res$ci_high,
    test = paste0("BCa bootstrap on AOV difference (", res$R, " resamples, seed ", res$seed, ")"),
    p_value = NA_real_,
    answer = paste0(
      "Average order value ", if (res$estimate < 0) "fell" else "rose",
      " by $", sprintf("%.2f", abs(res$estimate)),
      " [", sprintf("%.2f", res$ci_low), ", ", sprintf("%.2f", res$ci_high),
      "], while daily purchase volume ", if (volume_change_pct < 0) "fell" else "rose",
      " ", sprintf("%.1f", abs(volume_change_pct)), "%: the holiday peak was volume-driven, ",
      if (res$estimate < 0) "with a modest decline in order value" else "with a modest lift in order value",
      "."
    ),
    stringsAsFactors = FALSE
  )
  list(summary = summary, q3 = q3)
}

# Main -------------------------------------------------------------------------

main <- function() {
  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  message("Reading snapshot tables ...")
  so <- read_snapshot("session_outcomes")
  fd <- read_snapshot("funnel_daily")

  message("Q1: mobile vs desktop conversion ...")
  q1 <- question1(so)
  message("Q2: funnel step losses by device ...")
  q2 <- question2(fd)
  message("Q3: holiday value vs volume ...")
  q3 <- question3(so)

  summary <- bind_rows(q1$summary, q2$summary, q3$summary)
  write_results(summary, "analysis_summary.csv")

  si_path <- file.path(OUTPUT_DIR, "r_session_info.txt")
  writeLines(paste(capture.output(sessionInfo()), collapse = "\n"), si_path)
  message("Wrote ", si_path)
}

if (sys.nframe() == 0) main()
