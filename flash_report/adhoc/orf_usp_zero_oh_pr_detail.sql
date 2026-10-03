-- =============================================================================
-- DETAIL companion to orf_usp_zero_oh_pr_check.sql.
-- Grain: one row per site + mpn/catref + APN + req_number (exploded).
--   - Only parts that are zero-OH (NULL-or-0) and in APM (same set as the summary).
--   - Each APN gets its own row; each active PR on that APN gets its own row.
--   - APNs / parts with no active PR appear once with null req fields.
--
-- Use the SUMMARY (orf_usp_zero_oh_pr_check.sql) to COUNT stocked-out parts;
-- use THIS detail to audit the individual APNs and requisitions behind them.
-- Read-only. Reads the published mapping table default.rspl_apn_mapping.
-- =============================================================================

WITH stock AS (
  SELECT sto_part AS apn, SPLIT_PART(sto_store, '-', 1) AS site,
         MAX(CAST(sto_qty AS DOUBLE))   AS site_oh_qty,
         MAX(CAST(sto_minlev AS DOUBLE)) AS min_level,
         MAX(CAST(sto_lastsaved AS DATE)) AS sto_lastsaved
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE SPLIT_PART(sto_store, '-', 1) IN ('ORF3', 'ORF4')
  GROUP BY sto_part, SPLIT_PART(sto_store, '-', 1)
  UNION ALL
  SELECT sto_part AS apn, SPLIT_PART(sto_store, '-', 1) AS site,
         MAX(CAST(sto_qty AS DOUBLE))   AS site_oh_qty,
         MAX(CAST(sto_minlev AS DOUBLE)) AS min_level,
         MAX(CAST(sto_lastsaved AS DATE)) AS sto_lastsaved
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE SPLIT_PART(sto_store, '-', 1) IN ('ORF3', 'ORF4')
  GROUP BY sto_part, SPLIT_PART(sto_store, '-', 1)
),

reqs AS (
  SELECT rl.rql_part AS part, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number,
         CAST(rl.rql_qty AS DOUBLE)        AS req_qty,
         CAST(rh.req_date AS DATE)         AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
  JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
    ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rh.req_status = 'A' AND rl.rql_status = 'A'
  UNION ALL
  SELECT rl.rql_part AS part, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number,
         CAST(rl.rql_qty AS DOUBLE)        AS req_qty,
         CAST(rh.req_date AS DATE)         AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open
  FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
  JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
    ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rh.req_status = 'A' AND rl.rql_status = 'A'
),

-- APN+site pairs that have any consumption history at ORF3/ORF4.
consumed AS (
  SELECT DISTINCT amazon_apn AS apn, organization AS site
  FROM "andes"."ar-performance-n-insights.hw_raw_consumption_daily"
  WHERE organization IN ('ORF3', 'ORF4')
),

-- The zero-OH + in-APM part set (same definition as the summary), computed at
-- the MPN/CRN grain so we only explode APNs belonging to a stocked-out part.
zero_parts AS (
  SELECT m.site, m.rspl_mpn AS mpn, m.rspl_catref AS catalog_reference
  FROM default.rspl_apn_mapping m
  LEFT JOIN stock s ON s.apn = m.apn AND s.site = m.site
  WHERE m.site IN ('ORF3', 'ORF4') AND m.product IN ('USP', 'USP B1')
  GROUP BY m.site, m.rspl_mpn, m.rspl_catref
  HAVING MAX(CASE WHEN COALESCE(s.site_oh_qty, 0) > 0 THEN 1 ELSE 0 END) = 0       -- zero-OH
     AND MIN(CASE WHEN m.mapping_status = 'No APN found' THEN 1 ELSE 0 END) = 0    -- in APM
)

SELECT DISTINCT
  m.site,
  m.rspl_mpn            AS mpn,
  m.rspl_catref         AS catalog_reference,
  m.apn,
  s.site_oh_qty,
  s.min_level,
  s.sto_lastsaved,
  CASE WHEN r.req_number IS NOT NULL THEN true ELSE false END AS has_pr,
  r.req_number,
  r.req_qty,
  r.req_date,
  r.days_open,
  CASE WHEN c.apn IS NOT NULL THEN true ELSE false END AS has_consumption_before
FROM default.rspl_apn_mapping m
JOIN zero_parts z
  ON z.site = m.site AND z.mpn = m.rspl_mpn
 AND (z.catalog_reference = m.rspl_catref
      OR (z.catalog_reference IS NULL AND m.rspl_catref IS NULL))
LEFT JOIN stock s ON s.apn = m.apn AND s.site = m.site
LEFT JOIN reqs  r ON r.part = m.apn AND r.site = m.site
LEFT JOIN consumed c ON c.apn = m.apn AND c.site = m.site
WHERE m.site IN ('ORF3', 'ORF4') AND m.product IN ('USP', 'USP B1')
  AND m.apn IS NOT NULL
ORDER BY m.site, has_pr, m.rspl_mpn, m.apn, r.req_date;
