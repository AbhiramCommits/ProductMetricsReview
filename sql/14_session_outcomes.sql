/*-----------------------------------------------------------------------------*
 * Product question: Per session, does it end in a purchase and with how much
 *                   revenue? This is the input for the statistical tests
 *                   (returning vs new users, device, country comparisons).
 * Grain: one row per session = (user_pseudo_id, ga_session_id).
 * Caveat: sessions whose ga_session_id is missing are kept as their own
 *         rows. is_returning_user = 1 when the session starts after the
 *         user's first event inside the sample window (window-local proxy,
 *         not true lifetime returning status). device_category and country
 *         come from the session's first event; obfuscated geo values such
 *         as '<Other>' are kept as-is.
 *-----------------------------------------------------------------------------*/

WITH events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_date,
    event_timestamp,
    COALESCE(NULLIF(device.category, ''), '(not set)') AS device_category,
    COALESCE(NULLIF(geo.country, ''), '(not set)') AS country,
    event_name,
    ecommerce.purchase_revenue_in_usd AS revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

user_first_ts AS (
  SELECT
    user_pseudo_id,
    MIN(event_timestamp) AS first_ts
  FROM events
  GROUP BY user_pseudo_id
)

SELECT
  PARSE_DATE('%Y%m%d', MIN(e.event_date)) AS event_date,
  ARRAY_AGG(e.device_category IGNORE NULLS ORDER BY e.event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS device_category,
  ARRAY_AGG(e.country IGNORE NULLS ORDER BY e.event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS country,
  IF(MIN(e.event_timestamp) > MIN(u.first_ts), 1, 0) AS is_returning_user,
  IF(COUNTIF(e.event_name = 'purchase') > 0, 1, 0) AS purchased,
  COALESCE(ROUND(SUM(IF(e.event_name = 'purchase', e.revenue, NULL)), 2), 0) AS revenue_usd
FROM events e
LEFT JOIN user_first_ts u USING (user_pseudo_id)
GROUP BY e.user_pseudo_id, e.session_id;
