-- quicksight_apm_review_visual.sql
-- QuickSight dataset for the APM review visual.
--
-- Column layout (matches the spreadsheet mock A..O):
--   A  site                                  <- apm.site
--   B  possible deployed product             <- apm.product
--   C  confirmed deployed product            <- apm.rspl_rev
--   D  manufacturer part number              <- apm.mpn
--   E  catalogue ref                         <- apm.catalogue_reference
--   F  APN                                    <- apm.apn
--   G  created in APM                         <- apm.not_set_up_in_apm
--   H  Multiple APM found                     <- apm.multiple_apns
--   I  Incorrect virtual setup                <- apm.incorrect_mpn
--   J  Min/Max need review                    <- layer 2 (derived)
--   K  Lead time need review                  <- layer 2 (derived)
--   L  stockout                               <- layer 2 (derived)
--   M  below MIN no PR                         <- layer 2 (derived: order_inaction_flag)
--   N  the coming order qty is not enough      <- layer 2 (derived)
--   O  insufficient MIN coverage               <- layer 2 (derived)
--
-- Base tables:
--   layer 2 base scores : "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
--   apm setup details   : "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--       columns: site, product, rspl_rev, mpn, catalogue_reference, apn,
--                sto_prefmanufactpart, sto_min_lev, sto_leadtime,
--                not_set_up_in_apm, missing_mpn_network, missing_mpn_site,
--                missing_crn, incorrect_mpn, multiple_apns
--
-- Join key: site + apn.

WITH
-- APM setup details drives columns A..I.
-- Dedup to one row per (site, apn): the source table is not guaranteed unique
-- on that grain, so without this the LEFT JOIN to layer2 would fan out (one
-- copy of the review flags per duplicate APM row) and the visual would show
-- repeated site/apn rows.
--
-- IMPORTANT: the ORDER BY below decides WHICH row survives per (site, apn).
-- Replace it with the correct tie-breaker for this table's grain, e.g.:
--   - latest snapshot:        ORDER BY snapshot_date DESC
--   - prefer populated MPN:   ORDER BY (CASE WHEN mpn IS NOT NULL THEN 0 ELSE 1 END)
-- The current placeholder keeps rows with a non-null MPN first, then falls back
-- to catalogue_reference, which is deterministic but may not match your intent.
apm AS (
  SELECT
    site,
    product,
    rspl_rev,
    mpn,
    catalogue_reference,
    apn,
    not_set_up_in_apm,
    multiple_apns,
    incorrect_mpn
  FROM (
    SELECT
      site,
      product,
      rspl_rev,
      mpn,
      catalogue_reference,
      apn,
      not_set_up_in_apm,
      multiple_apns,
      incorrect_mpn,
      ROW_NUMBER() OVER (
        PARTITION BY site, apn
        ORDER BY
          CASE WHEN mpn IS NOT NULL THEN 0 ELSE 1 END,
          catalogue_reference
      ) AS rn
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
  ) apm_ranked
  WHERE rn = 1
),

-- Layer 2 base scores supply the derived review flags J..O.
-- layer2 is already one row per (site, part) from its build, so no dedup needed.
layer2 AS (
  SELECT
    site,
    part                AS apn,
    min_level,
    max_level,
    supplier_lead_time,
    site_oh_qty,
    back_order_qty,
    open_order_count,
    order_inaction_flag,
    coverage_150d,
    stockout_fraction_150d,
    combined_stockout_days_yr_150d
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
)

SELECT
  -- A..F
  apm.site                                                  AS site,
  apm.product                                               AS possible_deployed_product,
  apm.rspl_rev                                              AS confirmed_deployed_product,
  apm.mpn                                                   AS manufacturer_part_number,
  apm.catalogue_reference                                   AS catalogue_ref,
  apm.apn                                                   AS apn,

  -- G, H, I  (from APM setup details)
  apm.not_set_up_in_apm                                     AS created_in_apm,
  apm.multiple_apns                                         AS multiple_apm_found,
  apm.incorrect_mpn                                         AS incorrect_virtual_setup,

  -- J  Min/Max need review:
  --    MIN or MAX missing, or MIN >= MAX (invalid replenishment setup)
  CASE
    WHEN l2.min_level IS NULL OR l2.max_level IS NULL
      OR l2.min_level >= l2.max_level
    THEN 'Y' ELSE 'N'
  END                                                       AS min_max_need_review,

  -- K  Lead time need review: lead time missing or non-positive
  CASE
    WHEN l2.supplier_lead_time IS NULL OR l2.supplier_lead_time <= 0
    THEN 'Y' ELSE 'N'
  END                                                       AS lead_time_need_review,

  -- L  stockout: model projects some stockout over the cycle
  CASE
    WHEN COALESCE(l2.stockout_fraction_150d, 0) > 0
      OR COALESCE(l2.combined_stockout_days_yr_150d, 0) > 0
    THEN 'Y' ELSE 'N'
  END                                                       AS stockout,

  -- M  below MIN no PR: on hand below MIN and no open order / back order
  CASE
    WHEN COALESCE(l2.order_inaction_flag, 0) = 1
    THEN 'Y' ELSE 'N'
  END                                                       AS below_min_no_pr,

  -- N  the coming order qty is not enough:
  --    on hand below MIN, an order exists, but on hand + back order still < MIN
  CASE
    WHEN COALESCE(l2.site_oh_qty, 0) < l2.min_level
      AND COALESCE(l2.open_order_count, 0) > 0
      AND COALESCE(l2.site_oh_qty, 0) + COALESCE(l2.back_order_qty, 0) < l2.min_level
    THEN 'Y' ELSE 'N'
  END                                                       AS coming_order_qty_not_enough,

  -- O  insufficient MIN coverage: MIN does not fully cover replenishment demand
  CASE
    WHEN COALESCE(l2.coverage_150d, 1.0) < 1.0
    THEN 'Y' ELSE 'N'
  END                                                       AS insufficient_min_coverage

FROM apm
  LEFT JOIN layer2 l2
    ON l2.site = apm.site
   AND l2.apn  = apm.apn
