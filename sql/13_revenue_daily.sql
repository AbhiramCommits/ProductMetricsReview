/*-----------------------------------------------------------------------------*
 * Product question: How much money does the store make per day, by device?
 * Grain: one row per (event_date, device_category) with >= 1 purchase event.
 * Caveat: revenue is ecommerce.purchase_revenue_in_usd. The sample is
 *         obfuscated, so some purchase events carry NULL or zero revenue;
 *         those events still count toward `purchases`. Days/devices without
 *         a purchase event are absent (no zero-fill rows).
 *-----------------------------------------------------------------------------*/

SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  COALESCE(NULLIF(device.category, ''), '(not set)') AS device_category,
  COUNT(*) AS purchases,
  COALESCE(ROUND(SUM(ecommerce.purchase_revenue_in_usd), 2), 0) AS revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase'
GROUP BY event_date, device_category
ORDER BY event_date, device_category;
