-- layer2_with_layer1.sql
-- Base table: the Layer 2 score-base output (from layer2_base_scores.sql).
-- Enriched with Layer 1 (RSPL / APM setup) attributes via LEFT JOIN on site + apn.
--
-- Because Layer 2 is the base and the join is a LEFT JOIN:
--   * every Layer 2 (scored) part is kept
--   * Layer 1 columns are populated where the part also exists in Layer 1,
--     and NULL otherwise
--   * is_rspl_apn is COALESCEd to 0 for parts not found in Layer 1
--
-- Join key: layer2.part (APN) = layer1.apn  AND  layer2.site = layer1.site
--
-- Sources:
--   L2 base : output of layer2_base_scores.sql
--             "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
--   L1 dedup: logic from layer1_dedup_site_apn.sql
--             "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"

WITH
-- Layer 1 deduped to one row per site + apn (see layer1_dedup_site_apn.sql).
layer1 AS (
  SELECT
    site,
    apn,
    1 AS is_rspl_apn,
    -- Distinct products for the site+apn, comma separated. Aggregated (not raw)
    -- so a site+apn mapping to multiple products stays ONE row (site+apn grain).
    ARRAY_JOIN(
      ARRAY_AGG(DISTINCT NULLIF(TRIM(COALESCE(CAST(product AS VARCHAR), '')), ''))
        FILTER (WHERE NULLIF(TRIM(COALESCE(CAST(product AS VARCHAR), '')), '') IS NOT NULL),
      ', '
    ) AS product,
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
    SELECT
      site,
      product,
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
  WHERE apn IS NOT NULL
  GROUP BY site, apn
),

-- Layer 2 score base, ALL snapshots (partitioned by snapshot_date).
-- History is kept: every snapshot_date is retained rather than filtering to the
-- latest. Layer 1 (below) is deduped to one row per site + apn with no date, so
-- the LEFT JOIN attaches the same current setup attributes to every historical
-- snapshot of a part.
layer2 AS (
  SELECT *
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
)

SELECT
  -- Layer 2 is the base: keep all of its columns.
  l2.*,

  -- Layer 1 enrichment (NULL when the part is not in Layer 1).
  COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
  l1.product,
  l1.product_rev

FROM layer2 l2
  LEFT JOIN layer1 l1
    ON l1.site = l2.site
   AND l1.apn  = l2.part
