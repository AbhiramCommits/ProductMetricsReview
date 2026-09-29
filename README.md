# ProductMetricsReview

A full product-analytics cycle on the Google Merchandise Store GA4 public sample dataset:
metric definitions in SQL (BigQuery), statistics and forecasting in R, regression detection,
cost-benefit sizing, and a decision memo for a PM.

## Data

- Source: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
- Range: 2020-11-01 to 2021-01-31
- Snapshot: aggregated daily-grain tables committed as Parquet in `data/snapshot/`,
  described by `data/snapshot/MANIFEST.json`.

## Obfuscated sample data

The GA4 public sample is obfuscated by Google: some field values are replaced with
placeholders such as `<Other>`. Treat those placeholders as first-class values: bucket and
report them explicitly rather than dropping them silently, or metric definitions will
silently undercount.

## Repo layout

```
sql/            BigQuery Standard SQL metric definitions (one table per file)
R/              R scripts (extract, analyze, forecast, detect, size_opportunity, charts)
config/         Sizing assumptions (measured vs assumed, low/point/high)
data/snapshot/  Committed Parquet snapshots + MANIFEST.json (input to analysis, no creds needed)
output/         Generated CSV artifacts (committed); output/tmp/ is ignored
charts/         PNG charts for the memo (committed)
reports/        Quarto decision memo (qmd source, rendered gfm + html)
tests/          testthat tests
```

The decision layer sizes one product change (fixing the view→cart step) from
`config/assumptions.yml` — measured inputs are read from `output/`, assumed inputs carry
low/point/high and the lift is stated as an assumption, not a measured effect
(`output/opportunity_sizing.csv`, `output/sensitivity.csv`, tornado chart). The memo
(`reports/decision_memo.qmd`) pulls every figure from `output/` with inline R; no
hand-typed numbers.

## Metric definitions (`sql/`, one table per file)

| File | Table | Grain |
|------|-------|-------|
| `10_daily_active.sql` | `daily_active(event_date, dau, sessions, new_users)` | day |
| `11_funnel_daily.sql` | `funnel_daily(event_date, device_category, sessions, view_item_sessions, add_to_cart_sessions, begin_checkout_sessions, purchase_sessions)` | day x device |
| `12_retention_cohorts.sql` | `retention_cohorts(cohort_week, weeks_since_first_visit, cohort_size, retained_users)` | cohort week x week |
| `13_revenue_daily.sql` | `revenue_daily(event_date, device_category, purchases, revenue_usd)` | day x device |
| `14_session_outcomes.sql` | `session_outcomes(event_date, device_category, country, is_returning_user, purchased, revenue_usd)` | session |

Sessions are `user_pseudo_id` + `ga_session_id` (UNNESTed from `event_params`); all queries
bound the window with `_TABLE_SUFFIX BETWEEN '20201101' AND '20210131'`. The funnel is ordered
(session counts at a step only if it reached every earlier step in timestamp order). All
metric logic lives in `sql/`; R only reads the committed snapshot tables.

## Forecasting (`R/forecast.R`)

Three daily series: `dau`, `purchase_sessions`, `revenue_usd`. Models compared with fable:
ETS (weekly season), ARIMA, and SNAIVE (weekly lag) as baseline; a model only "wins" if it
beats SNAIVE. Backtest: rolling-origin CV (min 42-day training, 7-day horizon, 7-day step);
MAE/RMSE/MAPE per model per series per fold plus the fold mean in `output/backtest.csv`,
winners in `output/forecast_winners.csv`, 14-day forecasts with 80%/95% intervals in
`output/forecasts.csv`.

**Holiday handling.** Black Friday through Christmas (2020-11-27 .. 2020-12-25) sits inside
the window and is a structural level shift, not weekly seasonality. Approach: an explicit
holiday dummy as an exogenous regressor for ARIMA — the model class where a level shift is
hardest to represent otherwise; ETS and SNAIVE cannot take regressors and absorb the spike
through their own adaptation. The alternative considered — reporting accuracy with and
without the holiday weeks — was rejected because it removes the most business-critical days
from the evaluation.

## Regression detection (`R/detect.R`)

The last 14 days are held out and the winning model is refit on the remainder. A regression
is flagged when actuals fall below the 95% lower bound on 2+ consecutive days, or below the
80% lower bound on 5 of the trailing 7 days; a single-day dip can never fire. The rule is
applied as specified, not tuned against this data. Results: `output/regressions.csv`.

## Setup

```sh
Rscript -e 'renv::restore()'   # install the pinned package stack (renv.lock)
```

The lockfile includes `feasts`, the tidyverts companion package required internally by
`fable::ARIMA()`, in addition to the declared stack.

## Workflow

| Target        | What it does                                   | Needs BigQuery creds |
|---------------|------------------------------------------------|----------------------|
| `make extract`  | Run `sql/*.sql`, snapshot Parquet + MANIFEST   | yes (`GCP_PROJECT_ID`) |
| `make analyze`  | Statistics from the committed snapshot         | no |
| `make forecast` | Time-series forecasting + backtest             | no |
| `make detect`   | Regression detection on the last 14 days       | no |
| `make report`   | Cost-benefit sizing, decision memo             | no |
| `make test`     | testthat suite                                 | no |
| `make all`      | analyze + forecast + detect + report + test    | no |

All analysis steps run from the committed snapshot in a clean clone; only `extract` needs
BigQuery credentials:

```sh
export GCP_PROJECT_ID=<your-billing-project>
make extract
git add data/snapshot && git commit -m "snapshot: refresh GA4 aggregated tables"
```

Raw event-level rows are never committed: `R/extract.R` refuses to write tables that exceed
daily-grain row/date limits.

## License

MIT — see [LICENSE](LICENSE).
