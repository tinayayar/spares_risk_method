-- quicksight_apm_score_fulljoin.sql
-- QuickSight dataset: FULL OUTER JOIN of APM setup details and Layer 2 scores.
--
-- Unlike quicksight_apm_review_visual.sql (APM base, LEFT JOIN -> APM rows only),
-- this view keeps rows that exist in EITHER dataset:
--   * exists in both               -> all columns populated
--   * exists only in APM setup     -> APM columns populated, score columns blank
--   * exists only in Layer 2 score -> APN + score columns populated, APM blank
--
-- Grain:
--   * APM parts  : one row per site + mpn + catalogue_reference (CRN) + apn
--                  (APM setup rows are NOT collapsed -- each distinct
--                   MPN/CRN setup combo is its own row)
--   * score-only parts: one row per site + apn
--
-- Join key: site + apn (the only key both datasets share; the score side has
--           no MPN/CRN). Because APM can have several rows per (site, apn)
--           (different MPN/CRN), a single score row may attach to more than one
--           APM row -- the derived score flags then repeat across those rows.
--           This is expected given the site+MPN+CRN+APN APM grain.
--
-- Columns F to N are Y / N / NULL (NULL = the row has no data on that side).
-- The raw APM flags behind H (missing_mpn_network, missing_mpn_site,
-- missing_crn, incorrect_mpn) remain 0 / 1 / NULL.
--
-- Column layout:
--   site                          <- COALESCE(apm.site, score.site)
--   possible_deployed_product     <- apm.product
--   manufacturer_part_number      <- apm.mpn
--   catalogue_ref (CRN)           <- apm.catalogue_reference
--   rspl_rev                      <- apm.rspl_rev
--   apn                           <- COALESCE(apm.apn, score.part)
--   F created_in_apm              <- inverse of apm.not_set_up_in_apm
--                                    (not_set_up_in_apm = 1 -> 0, else 1)
--   G multiple_apm_found          <- apm.multiple_apns
--   H incorrect_virtual_setup     <- 1 if any of missing_mpn_network,
--                                    missing_mpn_site, missing_crn, incorrect_mpn = 1
--   missing_mpn_network           <- apm.missing_mpn_network (raw flag behind H)
--   missing_mpn_site              <- apm.missing_mpn_site    (raw flag behind H)
--   missing_crn                   <- apm.missing_crn         (raw flag behind H)
--   incorrect_mpn                 <- apm.incorrect_mpn       (raw flag behind H)
--   I stockout_min                <- score: stockout_days_yr_min_150d > 0
--   J stockout_rep                <- score: stockout_days_yr_rep_150d > 0
--   K no_on_hand                  <- score: site_oh_qty = 0 or NULL
--   L below_min_no_pr             <- score: order_inaction_flag = 1
--   M coming_order_qty_not_enough <- score: back_order_qty > 0 AND
--                                    (back_order_qty + site_oh_qty) < min_level
--   N min_covers_lead_time        <- score: site_oh_qty > min_level AND
--                                    consumption_rate_150d > 0 AND
--                                    (min_level / consumption_rate_150d) > supplier_lead_time
--
-- Base tables:
--   apm setup details : "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--   layer 2 score base: "andes"."ar-performance-n-insights.hw_critical_spares_score_base"

WITH
-- APM setup details (drives the APM-side columns).
-- Grain: one row per site + mpn + catalogue_reference + apn.
-- The raw table is not guaranteed unique even at that grain, so ROW_NUMBER()
-- keeps one deterministic row per key (prefer a populated MPN, then CRN).
apm AS (
  SELECT
    site,
    product,
    mpn,
    catalogue_reference,
    rspl_rev,
    apn,
    not_set_up_in_apm,
    multiple_apns,
    missing_mpn_network,
    missing_mpn_site,
    missing_crn,
    incorrect_mpn
  FROM (
    SELECT
      site,
      product,
      mpn,
      catalogue_reference,
      rspl_rev,
      -- Normalize placeholder APN ('N/A' / blank) to a real NULL so it does not
      -- spuriously join to the score side and does not collide in the key.
      CASE
        WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
        ELSE apn
      END AS apn,
      not_set_up_in_apm,
      multiple_apns,
      missing_mpn_network,
      missing_mpn_site,
      missing_crn,
      incorrect_mpn,
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

-- Layer 2 base scores (drives the score-side columns). Latest snapshot only.
-- Grain: one row per site + apn (part) at the most recent snapshot_date.
score AS (
  SELECT
    site,
    part                AS apn,
    min_level,
    supplier_lead_time,
    site_oh_qty,
    back_order_qty,
    order_inaction_flag,
    consumption_rate_150d,
    stockout_days_yr_min_150d,
    stockout_days_yr_rep_150d
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
)

SELECT
  -- site (present on whichever side the row came from)
  COALESCE(apm.site, s.site)                                AS site,

  -- APM-only attributes (NULL for score-only rows)
  apm.product                                               AS possible_deployed_product,
  apm.mpn                                                   AS manufacturer_part_number,
  apm.catalogue_reference                                   AS catalogue_ref,
  apm.rspl_rev                                              AS rspl_rev,

  -- APN (present on whichever side the row came from)
  COALESCE(apm.apn, s.apn)                                  AS apn,

  -- F  created in APM: inverse of not_set_up_in_apm
  --    (not_set_up_in_apm = 1 -> created_in_apm = 0, and vice versa).
  --    NULL for score-only rows.
  CASE
    WHEN apm.site IS NULL THEN NULL
    WHEN COALESCE(apm.not_set_up_in_apm, 0) = 1 THEN 'N' ELSE 'Y'
  END                                                       AS created_in_apm,

  -- G  multiple APM found  (raw APM flag; NULL for score-only rows)
  CASE
    WHEN apm.site IS NULL THEN NULL
    WHEN COALESCE(apm.multiple_apns, 0) = 1 THEN 'Y' ELSE 'N'
  END                                                       AS multiple_apm_found,

  -- H  incorrect virtual setup: 1 if any of the four APM setup flags = 1
  CASE
    WHEN apm.site IS NULL THEN NULL
    WHEN COALESCE(apm.missing_mpn_network, 0) = 1
      OR COALESCE(apm.missing_mpn_site, 0) = 1
      OR COALESCE(apm.missing_crn, 0) = 1
      OR COALESCE(apm.incorrect_mpn, 0) = 1
    THEN 'Y' ELSE 'N'
  END                                                       AS incorrect_virtual_setup,

  -- Underlying APM setup flags behind H (raw 0/1; NULL for score-only rows)
  CASE WHEN apm.site IS NULL THEN NULL ELSE apm.missing_mpn_network END AS missing_mpn_network,
  CASE WHEN apm.site IS NULL THEN NULL ELSE apm.missing_mpn_site    END AS missing_mpn_site,
  CASE WHEN apm.site IS NULL THEN NULL ELSE apm.missing_crn         END AS missing_crn,
  CASE WHEN apm.site IS NULL THEN NULL ELSE apm.incorrect_mpn       END AS incorrect_mpn,

  -- I  stockout (MIN-based): stockout_days_yr_min_150d > 0
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.stockout_days_yr_min_150d, 0) > 0
    THEN 'Y' ELSE 'N'
  END                                                       AS stockout_min,

  -- J  stockout (rep-time based): stockout_days_yr_rep_150d > 0
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.stockout_days_yr_rep_150d, 0) > 0
    THEN 'Y' ELSE 'N'
  END                                                       AS stockout_rep,

  -- K  no on hand: site_oh_qty is 0 or NULL
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.site_oh_qty, 0) = 0
    THEN 'Y' ELSE 'N'
  END                                                       AS no_on_hand,

  -- L  below MIN no PR: order_inaction_flag = 1
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.order_inaction_flag, 0) = 1
    THEN 'Y' ELSE 'N'
  END                                                       AS below_min_no_pr,

  -- M  coming order qty is not enough:
  --    back order exists but on hand + back order still below MIN  -> 1 else 0
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.back_order_qty, 0) > 0
      AND (COALESCE(s.back_order_qty, 0) + COALESCE(s.site_oh_qty, 0)) < COALESCE(s.min_level, 0)
    THEN 'Y' ELSE 'N'
  END                                                       AS coming_order_qty_not_enough,

  -- N  MIN covers lead time:
  --    on hand above MIN, positive consumption, and days-of-MIN exceed lead time
  CASE
    WHEN s.apn IS NULL THEN NULL
    WHEN COALESCE(s.site_oh_qty, 0) > COALESCE(s.min_level, 0)
      AND COALESCE(s.consumption_rate_150d, 0) > 0
      AND (s.min_level / NULLIF(s.consumption_rate_150d, 0)) > COALESCE(s.supplier_lead_time, 0)
    THEN 'Y' ELSE 'N'
  END                                                       AS min_covers_lead_time

FROM apm
  FULL OUTER JOIN score s
    ON s.site = apm.site
   AND s.apn  = apm.apn
