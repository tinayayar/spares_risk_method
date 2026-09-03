-- layer1_dedup_site_apn.sql
-- Dedup Layer 1 (APM setup details) to one row per site + apn.
--
-- Source: "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--   columns: site, product, rspl_rev, mpn, catalogue_reference, apn,
--            sto_prefmanufactpart, sto_min_lev, sto_leadtime,
--            not_set_up_in_apm, missing_mpn_network, missing_mpn_site,
--            missing_crn, incorrect_mpn, multiple_apns
--
-- Grain: one row per site + apn.
--
-- Output: site, apn, product_rev only.
--
-- Rules:
--   * apn = 'N/A' (case-insensitive) or blank means "no APN" -> normalized to
--     NULL, and those rows are dropped (apn must be present).
--   * rspl_rev = 'N/A' (case-insensitive) means "no revision" -> treated as blank
--     so it does not show up literally inside product_rev.
--   * product_rev = distinct "product rspl_rev" combos for the site+apn,
--                   comma separated into one value (e.g. "URL C, URL C2").

SELECT
  site,
  apn,

  -- Every row here comes from Layer 1 (RSPL / APM setup) and has a real APN,
  -- so flag it as an RSPL APN. After joining to Layer 2, parts that exist only
  -- in Layer 2 will have this as NULL -> COALESCE to 0 downstream.
  1 AS is_rspl_apn,

  -- Consolidated product + revision, distinct and comma separated
  ARRAY_JOIN(
    ARRAY_AGG(DISTINCT
      TRIM(CONCAT(
        COALESCE(CAST(product  AS VARCHAR), ''),
        ' ',
        COALESCE(CAST(rspl_rev AS VARCHAR), '')
      ))
    ),
    ', '
  ) AS product_rev

FROM (
  -- Normalize placeholder apn ('N/A' / blank) to a real NULL before grouping.
  SELECT
    site,
    product,
    -- rspl_rev = 'N/A' (case-insensitive) means "no revision" -> treat as blank
    -- so it does not appear literally in product_rev (e.g. "URL N/A").
    CASE
      WHEN UPPER(TRIM(CAST(rspl_rev AS VARCHAR))) IN ('N/A', 'NA') THEN ''
      ELSE rspl_rev
    END AS rspl_rev,
    CASE
      WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
      ELSE apn
    END AS apn
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
) src
-- Keep only rows with a real APN (blank / 'N/A' normalized to NULL above).
WHERE apn IS NOT NULL
GROUP BY site, apn
