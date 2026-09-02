-- layer1_layer2_join.sql
-- Full outer join of deduped Layer 1 (APM setup details) with Layer 2
-- (score base), joined on site + apn.
--
-- FULL OUTER JOIN keeps:
--   * parts in APM setup that have no score row (L2 side NULL)
--   * parts scored in L2 that are not in APM setup (L1 side NULL)
--   * parts present in both (matched)
--
-- Because either side can be NULL on a full outer join, site/apn are
-- COALESCEd into unified key columns so every row keeps its identity.
--
-- Sources:
--   L1 : "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--        (deduped inline; same logic as layer1_dedup.sql)
--   L2 : "andes"."ar-performance-n-insights.hw_critical_spares_score_base"

WITH
-- Layer 1 deduped to one row per site + mpn + catalogue_reference + apn.
-- product_rev = comma-separated distinct "product rspl_rev" combos.
layer1 AS (
  SELECT
    site,
    mpn,
    catalogue_reference,
    apn,
    ARRAY_JOIN(
      ARRAY_AGG(DISTINCT
        TRIM(CONCAT(
          COALESCE(CAST(product  AS VARCHAR), ''),
          ' ',
          COALESCE(CAST(rspl_rev AS VARCHAR), '')
        ))
      ),
      ', '
    ) AS product_rev,
    MAX(CAST(not_set_up_in_apm   AS INTEGER)) AS not_set_up_in_apm,
    MAX(CAST(missing_mpn_network AS INTEGER)) AS missing_mpn_network,
    MAX(CAST(missing_mpn_site    AS INTEGER)) AS missing_mpn_site,
    MAX(CAST(missing_crn         AS INTEGER)) AS missing_crn,
    MAX(CAST(incorrect_mpn       AS INTEGER)) AS incorrect_mpn,
    MAX(CAST(multiple_apns       AS INTEGER)) AS multiple_apns
  FROM (
    -- Normalize placeholder apn values to real NULLs. In the source table an
    -- apn of 'N/A' (case-insensitive) or blank actually means "no APN", so we
    -- convert it to NULL here -- before the GROUP BY and the downstream join --
    -- to avoid grouping distinct parts under a literal 'N/A' or falsely
    -- matching an 'N/A' apn against Layer 2. Select explicit columns (no *) so
    -- the cleaned value fully replaces the raw apn -- otherwise both the raw
    -- apn and apn_clean exist and the raw apn is neither grouped nor aggregated.
    SELECT
      site,
      product,
      rspl_rev,
      mpn,
      catalogue_reference,
      CASE
        WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
        ELSE apn
      END AS apn,
      not_set_up_in_apm,
      missing_mpn_network,
      missing_mpn_site,
      missing_crn,
      incorrect_mpn,
      multiple_apns
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
  ) src
  GROUP BY site, mpn, catalogue_reference, apn
),

-- Layer 2 score base, restricted to the latest snapshot only.
layer2 AS (
  SELECT *
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
)

SELECT
  -- Unified join keys (present regardless of which side matched)
  -- Unified join keys (present regardless of which side matched).
  -- Named all_site / all_apn so they do not collide with the site / part
  -- columns that l2.* re-emits below.
  COALESCE(l1.site, l2.site) AS all_site,
  COALESCE(l1.apn,  l2.part) AS all_apn,

  -- 1 if the part is a genuine RSPL part, else 0.
  -- An RSPL part must be identifiable at the PART level: it must come from
  -- Layer 1 AND have both an MPN and a CRN (catalogue_reference) populated.
  -- A Layer 1 row missing either identifier is not treated as an RSPL part.
  CASE
    WHEN l1.mpn IS NOT NULL
     AND l1.catalogue_reference IS NOT NULL
    THEN 1 ELSE 0
  END AS is_rspl_part,

  -- min_max_review: 1 when the MIN setting alone produces projected annual
  -- stockout days (stockout_days_yr_min_150d > 0), else 0. Sourced from L2.
  CASE WHEN COALESCE(l2.stockout_days_yr_min_150d, 0) > 0 THEN 1 ELSE 0 END AS min_max_review,

  -- Layer 1 (APM setup) columns
  l1.product_rev,
  l1.mpn,
  l1.catalogue_reference,
  l1.not_set_up_in_apm,
  l1.missing_mpn_network,
  l1.missing_mpn_site,
  l1.missing_crn,
  l1.incorrect_mpn,
  l1.multiple_apns,

  -- Incorrect virtual setup: 1 if any of the setup-issue flags is raised,
  -- else 0. NULL flags (e.g. Layer 2-only rows) are treated as 0.
  CASE
    WHEN COALESCE(l1.missing_mpn_network, 0) = 1
      OR COALESCE(l1.missing_mpn_site, 0) = 1
      OR COALESCE(l1.missing_crn, 0) = 1
      OR COALESCE(l1.incorrect_mpn, 0) = 1
      OR COALESCE(l1.multiple_apns, 0) = 1
    THEN 1 ELSE 0
  END AS incorrect_virtual_setup,

  -- Layer 2 (score base) columns
  l2.*

FROM layer1 l1
  FULL OUTER JOIN layer2 l2
    ON l1.site = l2.site
   AND l1.apn  = l2.part
