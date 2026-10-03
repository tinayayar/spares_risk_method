-- =============================================================================
-- Zero-OH (NULL-or-0) USP parts at ORF3 / ORF4, with PR (active requisition) status.
-- Reproduces adhoc/orf_usp_zero_oh_pr.py -> orf_usp_zero_oh_pr_check.csv, in pure SQL.
--
-- Definition (matches the flash report "MPN/CRN with 0/Null OH" metric):
--   grain    = unique (mpn, catalog_reference)
--   zero-OH  = NO apn in the group has OH > 0   (NULL treated as 0)
--   in APM   = not every apn in the group is "No APN found"
--   has_pr   = ANY apn in the group has an active requisition (has_active_pr = 1)
--
-- Reads the published mapping table default.rspl_apn_mapping (same source the
-- report uses). Run in Athena. Read-only.
-- =============================================================================

WITH base AS (
  -- Per-APN rows for ORF3/ORF4 USP: OH qty, APM status, and active-PR flag.
  SELECT
    m.site,
    m.rspl_mpn                                   AS mpn,
    m.rspl_catref                                AS catalog_reference,
    m.apn                                        AS r5_apn,
    m.mapping_status,
    s.site_oh_qty,
    s.min_level,
    s.sto_lastsaved,
    CASE WHEN ar.part IS NOT NULL THEN 1 ELSE 0 END AS has_active_pr,
    ar.req_number,
    ar.req_date,
    CASE WHEN c.apn IS NOT NULL THEN 1 ELSE 0 END AS has_consumption
  FROM default.rspl_apn_mapping m
  LEFT JOIN (
    -- current on-hand per apn+site (NA + EU stock)
    SELECT sto_part AS apn, SPLIT_PART(sto_store, '-', 1) AS site,
           MAX(CAST(sto_qty AS DOUBLE)) AS site_oh_qty,
           MAX(CAST(sto_minlev AS DOUBLE)) AS min_level,
           MAX(CAST(sto_lastsaved AS DATE)) AS sto_lastsaved
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE SPLIT_PART(sto_store, '-', 1) IN ('ORF3', 'ORF4')
    GROUP BY sto_part, SPLIT_PART(sto_store, '-', 1)
    UNION ALL
    SELECT sto_part AS apn, SPLIT_PART(sto_store, '-', 1) AS site,
           MAX(CAST(sto_qty AS DOUBLE)) AS site_oh_qty,
           MAX(CAST(sto_minlev AS DOUBLE)) AS min_level,
           MAX(CAST(sto_lastsaved AS DATE)) AS sto_lastsaved
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE SPLIT_PART(sto_store, '-', 1) IN ('ORF3', 'ORF4')
    GROUP BY sto_part, SPLIT_PART(sto_store, '-', 1)
  ) s ON s.apn = m.apn AND s.site = m.site
  LEFT JOIN (
    -- active requisitions (PRs): req + line both status 'A'
    SELECT rl.rql_part AS part, rh.req_org AS site,
           trim(cast(rl.rql_req AS varchar)) AS req_number,
           CAST(rh.req_date AS DATE) AS req_date
    FROM "andes"."rme-gdl.r5requislines_apm_na" rl
    JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
    WHERE rh.req_status = 'A' AND rl.rql_status = 'A'
    UNION ALL
    SELECT rl.rql_part AS part, rh.req_org AS site,
           trim(cast(rl.rql_req AS varchar)) AS req_number,
           CAST(rh.req_date AS DATE) AS req_date
    FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
    JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
    WHERE rh.req_status = 'A' AND rl.rql_status = 'A'
  ) ar ON ar.part = m.apn AND ar.site = m.site
  LEFT JOIN (
    -- APN+site pairs with any consumption history at ORF3/ORF4
    SELECT DISTINCT amazon_apn AS apn, organization AS site
    FROM "andes"."ar-performance-n-insights.hw_raw_consumption_daily"
    WHERE organization IN ('ORF3', 'ORF4')
  ) c ON c.apn = m.apn AND c.site = m.site
  WHERE m.site IN ('ORF3', 'ORF4')
    AND m.product IN ('USP', 'USP B1')
),

grouped AS (
  SELECT
    site,
    mpn,
    catalog_reference,
    ARRAY_JOIN(ARRAY_SORT(ARRAY_AGG(DISTINCT r5_apn)), ';')            AS apns,
    MAX(min_level)                                                     AS min_level,
    -- any apn has OH > 0 (NULL -> 0)
    MAX(CASE WHEN COALESCE(site_oh_qty, 0) > 0 THEN 1 ELSE 0 END)      AS any_oh_gt_zero,
    -- every apn is "No APN found" => not in APM
    MIN(CASE WHEN mapping_status = 'No APN found' THEN 1 ELSE 0 END)   AS all_not_in_apm,
    -- any apn has an active PR
    MAX(has_active_pr)                                                 AS has_pr,
    ARRAY_JOIN(ARRAY_SORT(ARRAY_AGG(DISTINCT
        CASE WHEN has_active_pr = 1 THEN req_number END)), ';')        AS req_numbers,
    -- oldest active-PR date in the group (earliest approved requisition)
    MIN(req_date)                                                      AS req_date,
    -- most recent stock last-saved date in the group (how current the OH reading is)
    MAX(sto_lastsaved)                                                 AS sto_lastsaved,
    -- any apn in the group has prior consumption at this site
    MAX(has_consumption)                                               AS has_consumption
  FROM base
  GROUP BY site, mpn, catalog_reference
)

SELECT
  site,
  mpn,
  catalog_reference,
  apns,
  min_level,
  CASE WHEN has_pr = 1 THEN true ELSE false END AS has_pr,
  req_numbers,
  req_date,
  sto_lastsaved,
  CASE WHEN has_consumption = 1 THEN true ELSE false END AS has_consumption_before
FROM grouped
WHERE any_oh_gt_zero = 0        -- zero-OH (NULL or 0)
  AND all_not_in_apm = 0        -- in APM
ORDER BY site, has_pr, mpn;
