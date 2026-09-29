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
R/              R scripts (extract, analyze, forecast, report)
data/snapshot/  Committed Parquet snapshots + MANIFEST.json (input to analysis, no creds needed)
output/         Generated artifacts (not committed)
tests/          testthat tests
```

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

## Setup

```sh
Rscript -e 'renv::restore()'   # install the pinned package stack (renv.lock)
```

`boot` is a recommended package shipped with R itself, so it is intentionally absent from
`renv.lock` but available in any R installation.

## Workflow

| Target        | What it does                                   | Needs BigQuery creds |
|---------------|------------------------------------------------|----------------------|
| `make extract`  | Run `sql/*.sql`, snapshot Parquet + MANIFEST   | yes (`GCP_PROJECT_ID`) |
| `make analyze`  | Statistics from the committed snapshot         | no |
| `make forecast` | Time-series forecasting                        | no |
| `make report`   | Regression detection, cost-benefit, memo       | no |
| `make test`     | testthat suite                                 | no |
| `make all`      | analyze + forecast + report + test             | no |

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
