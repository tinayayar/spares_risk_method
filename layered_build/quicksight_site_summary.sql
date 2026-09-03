-- quicksight_site_summary.sql
-- QuickSight dataset: one row per site summarizing two action counts.
--
-- Metrics (each computed on its OWN source side, then joined by site, so the
-- APM<->score fan-out in quicksight_apm_score_fulljoin does NOT double-count):
--   mrn_not_created_in_apm   <- APM side: COUNT(DISTINCT mpn) where the part is
--                               not_set_up_in_apm = 1 (i.e. created_in_apm = 'N')
--   apn_need_minmax_review   <- score side: COUNT(DISTINCT apn) where
--                               stockout_days_yr_min_150d > 0
--
-- Grain: one row per site (FULL OUTER JOIN of the two per-site aggregates so a
--        site that appears on only one side still shows, with 0 on the other).
--
-- Base tables:
--   apm setup details : "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--   layer 2 score base: "andes"."ar-performance-n-insights.hw_critical_spares_score_base"

WITH
-- APM side, deduped to one row per site + mpn + catalogue_reference + apn
-- (same dedup grain as quicksight_apm_score_fulljoin), so a repeated raw row
-- does not inflate the distinct-MPN count.
apm AS (
  SELECT
    site,
    mpn,
    not_set_up_in_apm
  FROM (
    SELECT
      site,
      mpn,
      catalogue_reference,
      CASE
        WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
        ELSE apn
      END AS apn,
      not_set_up_in_apm,
      ROW_NUMBER() OVER (
        PARTITION BY site, mpn, catalogue_reference,
          CASE
            WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
            ELSE apn
          END
        ORDER BY
          CASE WHEN mpn IS NOT NULL THEN 0 ELSE 1 END,
          catalogue_reference
      ) AS rn
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
  ) apm_ranked
  WHERE rn = 1
),

-- Per-site count of distinct MPNs that are not created in APM.
apm_summary AS (
  SELECT
    site,
    COUNT(DISTINCT CASE WHEN COALESCE(not_set_up_in_apm, 0) = 1 THEN mpn END)
      AS mrn_not_created_in_apm
  FROM apm
  GROUP BY site
),

-- Score side: latest snapshot only, one row per site + apn (part).
score AS (
  SELECT
    site,
    part AS apn,
    stockout_days_yr_min_150d
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
),

-- Per-site count of distinct APNs that need min/max review.
score_summary AS (
  SELECT
    site,
    COUNT(DISTINCT CASE WHEN COALESCE(stockout_days_yr_min_150d, 0) > 0 THEN apn END)
      AS apn_need_minmax_review
  FROM score
  GROUP BY site
)

SELECT
  COALESCE(a.site, s.site)                       AS site,
  COALESCE(a.mrn_not_created_in_apm, 0)          AS mrn_not_created_in_apm,
  COALESCE(s.apn_need_minmax_review, 0)          AS apn_need_minmax_review
FROM apm_summary a
  FULL OUTER JOIN score_summary s
    ON s.site = a.site
ORDER BY site
