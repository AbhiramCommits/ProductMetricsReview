/*-----------------------------------------------------------------------------*
 * Product question: How big is daily demand (unique users, sessions) and how
 *                   much of it is new?
 * Grain: one row per event_date (2020-11-01 .. 2021-01-31).
 * Caveat: "new_users" means "first event inside this window", not "first
 *         ever". Users who were active before 2020-11-01 reappear as new on
 *         their first day in the sample. Sessions are identified by
 *         user_pseudo_id + ga_session_id (UNNESTed from event_params); a
 *         session crossing midnight is counted on each day it has events.
 *-----------------------------------------------------------------------------*/

WITH events AS (
  SELECT
    event_date,
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

first_visits AS (
  SELECT
    user_pseudo_id,
    MIN(event_date) AS first_event_date
  FROM events
  GROUP BY user_pseudo_id
)

SELECT
  PARSE_DATE('%Y%m%d', e.event_date) AS event_date,
  COUNT(DISTINCT e.user_pseudo_id) AS dau,
  COUNT(DISTINCT CONCAT(e.user_pseudo_id, '#', e.session_id)) AS sessions,
  COUNT(DISTINCT IF(fv.first_event_date = e.event_date, e.user_pseudo_id, NULL)) AS new_users
FROM events e
LEFT JOIN first_visits fv USING (user_pseudo_id)
GROUP BY e.event_date
ORDER BY e.event_date;
