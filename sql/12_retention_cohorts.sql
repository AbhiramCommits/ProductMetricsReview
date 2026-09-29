/*-----------------------------------------------------------------------------*
 * Product question: Do users come back? Weekly retention of each cohort
 *                   (users grouped by the week of their first visit),
 *                   observed 0 to 8 weeks after that week.
 * Grain: one row per (cohort_week, weeks_since_first_visit).
 * Caveat: "first visit" is the first event inside the sample window only.
 *         Late cohorts are right-censored: weeks that fall entirely outside
 *         2020-11-01 .. 2021-01-31 are omitted from the table rather than
 *         reported as zero retention. Weeks are Monday-anchored, so the
 *         first cohort_week label is 2020-10-26 (its only day in-window is
 *         Nov 1).
 *-----------------------------------------------------------------------------*/

WITH first_visits AS (
  SELECT
    user_pseudo_id,
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_visit
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY user_pseudo_id
),

cohorts AS (
  SELECT
    user_pseudo_id,
    DATE_TRUNC(first_visit, WEEK(MONDAY)) AS cohort_week
  FROM first_visits
),

activity AS (
  SELECT DISTINCT
    user_pseudo_id,
    DATE_TRUNC(PARSE_DATE('%Y%m%d', event_date), WEEK(MONDAY)) AS activity_week
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

weeks AS (
  SELECT w AS weeks_since_first_visit
  FROM UNNEST(GENERATE_ARRAY(0, 8)) AS w
)

SELECT
  c.cohort_week,
  wk.weeks_since_first_visit,
  COUNT(DISTINCT c.user_pseudo_id) AS cohort_size,
  COUNT(DISTINCT a.user_pseudo_id) AS retained_users
FROM cohorts c
CROSS JOIN weeks wk
LEFT JOIN activity a
  ON a.user_pseudo_id = c.user_pseudo_id
 AND DATE_DIFF(a.activity_week, c.cohort_week, WEEK) = wk.weeks_since_first_visit
WHERE DATE_ADD(c.cohort_week, INTERVAL 7 * wk.weeks_since_first_visit DAY) <= DATE '2021-01-31'
GROUP BY c.cohort_week, wk.weeks_since_first_visit
ORDER BY c.cohort_week, wk.weeks_since_first_visit;
