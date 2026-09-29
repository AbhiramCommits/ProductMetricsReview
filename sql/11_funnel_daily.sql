/*-----------------------------------------------------------------------------*
 * Product question: Where do sessions drop off along the ecommerce funnel:
 *                   view item -> add to cart -> begin checkout -> purchase?
 * Grain: one row per (event_date, device_category).
 * Caveat: this is an ORDERED funnel, not independent step counts. A session
 *         counts at step k only if it also reached every earlier step, with
 *         the earlier step's event timestamp at or before the later one
 *         (greedy earliest-completion matching). Sessions are attributed to
 *         the date of their first funnel event, so a session crossing
 *         midnight is counted once, on its starting day. The funnel base
 *         `sessions` is sessions that fired at least one of the four events.
 *-----------------------------------------------------------------------------*/

WITH events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_date,
    event_timestamp,
    COALESCE(NULLIF(device.category, ''), '(not set)') AS device_category,
    event_name
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN ('view_item', 'add_to_cart', 'begin_checkout', 'purchase')
),

-- One row per session; per-step timestamps ascending.
session_steps AS (
  SELECT
    user_pseudo_id,
    session_id,
    PARSE_DATE('%Y%m%d', MIN(event_date)) AS event_date,
    ARRAY_AGG(device_category IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS device_category,
    ARRAY_AGG(IF(event_name = 'view_item', event_timestamp, NULL) IGNORE NULLS ORDER BY event_timestamp) AS view_ts,
    ARRAY_AGG(IF(event_name = 'add_to_cart', event_timestamp, NULL) IGNORE NULLS ORDER BY event_timestamp) AS cart_ts,
    ARRAY_AGG(IF(event_name = 'begin_checkout', event_timestamp, NULL) IGNORE NULLS ORDER BY event_timestamp) AS checkout_ts,
    ARRAY_AGG(IF(event_name = 'purchase', event_timestamp, NULL) IGNORE NULLS ORDER BY event_timestamp) AS purchase_ts
  FROM events
  GROUP BY user_pseudo_id, session_id
),

-- Earliest completion time per step: earliest timestamp of step k that is
-- >= the earliest completion time of step k-1. NULL means "not reached".
ordered AS (
  SELECT
    s.*,
    view_ts[SAFE_OFFSET(0)] AS view_first_ts,
    (SELECT MIN(ts) FROM UNNEST(cart_ts) AS ts WHERE ts >= view_ts[SAFE_OFFSET(0)]) AS cart_first_ts
  FROM session_steps s
),
ordered2 AS (
  SELECT
    o.*,
    (SELECT MIN(ts) FROM UNNEST(checkout_ts) AS ts WHERE ts >= cart_first_ts) AS checkout_first_ts
  FROM ordered o
),
ordered3 AS (
  SELECT
    o.*,
    (SELECT MIN(ts) FROM UNNEST(purchase_ts) AS ts WHERE ts >= checkout_first_ts) AS purchase_first_ts
  FROM ordered2 o
)

SELECT
  event_date,
  device_category,
  COUNT(*) AS sessions,
  COUNTIF(view_first_ts IS NOT NULL) AS view_item_sessions,
  COUNTIF(cart_first_ts IS NOT NULL) AS add_to_cart_sessions,
  COUNTIF(checkout_first_ts IS NOT NULL) AS begin_checkout_sessions,
  COUNTIF(purchase_first_ts IS NOT NULL) AS purchase_sessions
FROM ordered3
GROUP BY event_date, device_category
ORDER BY event_date, device_category;
