-- layer2_with_layer1_qs.sql
-- QuickSight/Redshift variant of layer2_with_layer1.sql.
-- Uses andes_bi_ext."schema".table references and Redshift-compatible syntax.
--
-- Base : Layer 2 score base (latest snapshot only)
--        andes_bi_ext."ar-performance-n-insights".hw_critical_spares_score_base
-- Enrich: Layer 1 RSPL / APM setup with corrected site->product mapping
--        andes_bi_ext."ar-performance-n-insights".hw_critical_spares_apm_setup_details
--
-- Join: FULL OUTER JOIN on site + apn. Includes parts present in EITHER source.
-- Grain: one row per site + product + apn (Layer-2-only parts have product = NULL).
-- snapshot_date is stamped as the run date (today).

WITH
-- Authoritative site -> product mapping.
-- USP_EU is normalized to USP for matching (the raw table has no region split).
-- Site lists are expressed as SELECT ... UNION ALL for cross-engine compatibility.
target_sites AS (
  -- USP (NA)
  SELECT 'ABQ1' AS site, 'USP' AS product UNION ALL SELECT 'AGS1', 'USP' UNION ALL
  SELECT 'AKC1', 'USP' UNION ALL SELECT 'AUS2', 'USP' UNION ALL SELECT 'BDL4', 'USP' UNION ALL
  SELECT 'BOS3', 'USP' UNION ALL SELECT 'BWI2', 'USP' UNION ALL SELECT 'DAB2', 'USP' UNION ALL
  SELECT 'DEN4', 'USP' UNION ALL SELECT 'DEN9', 'USP' UNION ALL SELECT 'DET6', 'USP' UNION ALL
  SELECT 'ELP1', 'USP' UNION ALL SELECT 'FSD1', 'USP' UNION ALL SELECT 'FWA6', 'USP' UNION ALL
  SELECT 'GEG1', 'USP' UNION ALL SELECT 'GYR1', 'USP' UNION ALL SELECT 'HOU6', 'USP' UNION ALL
  SELECT 'IAG1', 'USP' UNION ALL SELECT 'IGQ1', 'USP' UNION ALL SELECT 'ILM1', 'USP' UNION ALL
  SELECT 'LUK2', 'USP' UNION ALL SELECT 'MKC6', 'USP' UNION ALL SELECT 'MLI1', 'USP' UNION ALL
  SELECT 'MQY1', 'USP' UNION ALL SELECT 'MTN1', 'USP' UNION ALL SELECT 'OMA2', 'USP' UNION ALL
  SELECT 'ORD5', 'USP' UNION ALL SELECT 'ORF3', 'USP' UNION ALL SELECT 'ORF4', 'USP' UNION ALL
  SELECT 'ORH3', 'USP' UNION ALL SELECT 'OXR1', 'USP' UNION ALL SELECT 'PAE2', 'USP' UNION ALL
  SELECT 'PDX8', 'USP' UNION ALL SELECT 'PVD2', 'USP' UNION ALL SELECT 'RIC4', 'USP' UNION ALL
  SELECT 'RIC6', 'USP' UNION ALL SELECT 'SAN3', 'USP' UNION ALL SELECT 'SAT3', 'USP' UNION ALL
  SELECT 'SAV4', 'USP' UNION ALL SELECT 'SBD6', 'USP' UNION ALL SELECT 'SBN1', 'USP' UNION ALL
  SELECT 'SCK6', 'USP' UNION ALL SELECT 'SHV1', 'USP' UNION ALL SELECT 'SYR1', 'USP' UNION ALL
  SELECT 'TLH2', 'USP' UNION ALL SELECT 'TPA4', 'USP' UNION ALL SELECT 'TYS1', 'USP' UNION ALL
  SELECT 'VGT1', 'USP' UNION ALL SELECT 'YEG2', 'USP' UNION ALL SELECT 'YHM1', 'USP' UNION ALL
  SELECT 'YOW3', 'USP' UNION ALL SELECT 'YXU1', 'USP' UNION ALL SELECT 'YYC4', 'USP' UNION ALL
  -- USP (EU) — normalized to USP
  SELECT 'BCN4', 'USP' UNION ALL SELECT 'BHX2', 'USP' UNION ALL SELECT 'BRQ2', 'USP' UNION ALL
  SELECT 'DSA6', 'USP' UNION ALL SELECT 'DUS4', 'USP' UNION ALL SELECT 'EMA2', 'USP' UNION ALL
  SELECT 'KTW3', 'USP' UNION ALL SELECT 'LCY3', 'USP' UNION ALL SELECT 'LYS2', 'USP' UNION ALL
  SELECT 'MXP6', 'USP' UNION ALL SELECT 'NCL1', 'USP' UNION ALL SELECT 'POZ2', 'USP' UNION ALL
  SELECT 'STN6', 'USP' UNION ALL SELECT 'SVQ1', 'USP' UNION ALL
  -- URL Rev C
  SELECT 'SHV1', 'URL Rev C' UNION ALL SELECT 'ORF3', 'URL Rev C' UNION ALL
  SELECT 'ORF4', 'URL Rev C' UNION ALL
  -- URL Rev C2
  SELECT 'CLE3', 'URL Rev C2' UNION ALL SELECT 'BCN4', 'URL Rev C2' UNION ALL
  SELECT 'ORH3', 'URL Rev C2' UNION ALL SELECT 'PAE2', 'URL Rev C2' UNION ALL
  SELECT 'DEN9', 'URL Rev C2' UNION ALL SELECT 'IAG1', 'URL Rev C2' UNION ALL
  SELECT 'ORF3', 'URL Rev C2' UNION ALL SELECT 'ORF4', 'URL Rev C2' UNION ALL
  -- URL Rev D
  SELECT 'BDL4', 'URL Rev D' UNION ALL SELECT 'BOS3', 'URL Rev D' UNION ALL
  SELECT 'ILM1', 'URL Rev D' UNION ALL SELECT 'RIC4', 'URL Rev D' UNION ALL
  SELECT 'SYR1', 'URL Rev D' UNION ALL SELECT 'YOW3', 'URL Rev D' UNION ALL
  SELECT 'TPA4', 'URL Rev D' UNION ALL SELECT 'MQY1', 'URL Rev D' UNION ALL
  SELECT 'TYS1', 'URL Rev D' UNION ALL SELECT 'DCA1', 'URL Rev D' UNION ALL
  SELECT 'RIC6', 'URL Rev D' UNION ALL SELECT 'LUK2', 'URL Rev D' UNION ALL
  SELECT 'DUS4', 'URL Rev D'
),

valid_site_product AS (
  SELECT DISTINCT site, product FROM target_sites
),

-- Raw APM table with corrected product label derived from product + rspl_rev.
-- INNER JOIN to valid_site_product drops rows with wrong site/product combos.
layer1_corrected AS (
  SELECT
    d.site,
    CASE
      WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C2' THEN 'URL Rev C2'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
      ELSE NULL
    END AS product,
    d.mpn,
    d.catalogue_reference,
    CASE
      WHEN UPPER(TRIM(CAST(d.apn AS VARCHAR(100)))) IN ('N/A', 'NA', '') THEN NULL
      ELSE d.apn
    END AS apn,
    d.sto_prefmanufactpart,
    d.sto_min_lev,
    d.sto_leadtime,
    d.not_set_up_in_apm,
    d.missing_mpn_network,
    d.missing_mpn_site,
    d.missing_crn,
    d.incorrect_mpn,
    d.multiple_apns,
    -- Row-level rollup: 1 if the MPN has ANY of the five APM setup problems.
    CASE
      WHEN d.missing_mpn_network = 1
        OR d.missing_mpn_site    = 1
        OR d.missing_crn         = 1
        OR d.incorrect_mpn       = 1
        OR d.multiple_apns       = 1
      THEN 1 ELSE 0
    END AS incorrect_apm_setup
  FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_apm_setup_details d
    INNER JOIN valid_site_product v
      ON v.site = d.site
     AND v.product = CASE
           WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C2' THEN 'URL Rev C2'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
           ELSE NULL
         END
),

-- Layer 1 deduped to one row per site + product + mpn + apn.
-- MPN is part of the grain so countDistinct(mpn) is accurate directly on this
-- dataset. Consequence: when one APN maps to multiple MPNs, that APN's Layer 2
-- score is duplicated across the MPN rows; when multiple APNs map to one MPN,
-- their scores are counted separately. Use countDistinct / max on score columns
-- when aggregating in QuickSight to avoid inflating additive sums.
layer1 AS (
  SELECT
    site,
    product,
    mpn,
    apn,
    1 AS is_rspl_apn,
    MAX(catalogue_reference) AS catalogue_reference,
    MAX(sto_prefmanufactpart) AS sto_prefmanufactpart,
    MAX(sto_min_lev)         AS sto_min_lev,
    MAX(sto_leadtime)        AS sto_leadtime,
    MAX(not_set_up_in_apm)   AS not_set_up_in_apm,
    MAX(missing_mpn_network) AS missing_mpn_network,
    MAX(missing_mpn_site)    AS missing_mpn_site,
    MAX(missing_crn)         AS missing_crn,
    MAX(incorrect_mpn)       AS incorrect_mpn,
    MAX(multiple_apns)       AS multiple_apns,
    MAX(incorrect_apm_setup) AS incorrect_apm_setup
  FROM layer1_corrected
  -- No apn IS NOT NULL filter: MPNs with no APN (not set up in APM) are kept.
  -- Their apn is NULL, so they never match Layer 2 (l1.apn = l2.part) and come
  -- through the full join as Layer-1-only rows with no scores.
  GROUP BY site, product, mpn, apn
),

-- Distinct MPNs not set up in APM, per site + product.
-- Counted from layer1_corrected (all MPNs, including null-APN parts) so the
-- count is complete and unaffected by the APN-keyed grain of layer1.
site_product_apm_gap AS (
  SELECT site, product,
         COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) AS not_set_up_mpn_count
  FROM layer1_corrected
  GROUP BY site, product
),

-- Site + product level data-quality counts: distinct MPNs flagged in each of
-- the five APM setup categories, distinct MPNs with no APN mapped, plus distinct
-- MPNs with any problem (incorrect_apm_setup). Counted from layer1_corrected
-- (all MPNs, including null-APN parts) so the APN fan-out doesn't inflate them.
site_product_dq AS (
  SELECT site, product,
         COUNT(DISTINCT CASE WHEN missing_mpn_network = 1 THEN mpn END) AS missing_mpn_network_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_site    = 1 THEN mpn END) AS missing_mpn_site_count,
         COUNT(DISTINCT CASE WHEN missing_crn         = 1 THEN mpn END) AS missing_crn_count,
         COUNT(DISTINCT CASE WHEN incorrect_mpn       = 1 THEN mpn END) AS incorrect_mpn_count,
         COUNT(DISTINCT CASE WHEN multiple_apns       = 1 THEN mpn END) AS multiple_apns_count,
         -- Distinct MPNs with no APN mapped (apn normalized to NULL upstream).
         COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)            AS no_apn_mapped_count,
         COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) AS incorrect_apm_setup_count,
         -- Site+product penalty: 5 when >= 50 distinct MPNs have any APM setup
         -- problem (incorrect_apm_setup), else 0.
         CASE WHEN COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) >= 50
              THEN 5 ELSE 0 END AS incorrect_apm_setup_penalty,
         -- Site+product penalty: 5 when >= 10 distinct MPNs have no APN mapped,
         -- else 0.
         CASE WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 10
              THEN 5 ELSE 0 END AS no_apn_mapped_penalty
  FROM layer1_corrected
  GROUP BY site, product
),

-- Site-level APM penalty: 5 when the site has >= 10 distinct MPNs not set up in
-- APM, else 0. Counted from layer1_corrected (all MPNs, including null-APN parts).
site_apm_gap AS (
  SELECT site,
         COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) AS site_not_set_up_mpn_count,
         CASE WHEN COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) >= 10
              THEN 5 ELSE 0 END AS site_apm_penalty
  FROM layer1_corrected
  GROUP BY site
),

-- Layer 2 score base, LATEST snapshot only.
layer2 AS (
  SELECT *
  FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_score_base
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_score_base
  )
),

-- ---------------------------------------------------------------------------
-- Live inventory inputs for Layer-1-only parts (not in Layer 2).
-- Reading r5stock directly lets parts that exist in Layer 1 but not Layer 2
-- still show on-hand / min / max / sto_class.
-- Grain: one row per site + APN. NA is preferred over EU on conflict.
-- ---------------------------------------------------------------------------
l1_stock AS (
  SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart
  FROM (
    SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart,
           ROW_NUMBER() OVER (PARTITION BY site, sto_part
                              ORDER BY CASE region WHEN 'NA' THEN 1 ELSE 2 END) AS rn
    FROM (
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS FLOAT))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS FLOAT)) AS min_level,
             MAX(CAST(st.sto_maxqty AS FLOAT)) AS max_level,
             MAX(st.sto_class)                 AS sto_class,
             MAX(st.sto_prefmanufactpart)      AS sto_prefmanufactpart,
             'NA' AS region
      FROM andes_bi_ext."rme-gdl".r5stock_apm_na st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
      UNION ALL
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS FLOAT))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS FLOAT)) AS min_level,
             MAX(CAST(st.sto_maxqty AS FLOAT)) AS max_level,
             MAX(st.sto_class)                 AS sto_class,
             MAX(st.sto_prefmanufactpart)      AS sto_prefmanufactpart,
             'EU' AS region
      FROM andes_bi_ext."rme-gdl".r5stock_apm_eu st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
    ) sto_raw
  ) ranked
  WHERE rn = 1
),

-- Coming/back orders from r5orderlines, per site + APN.
-- Keyed on orl_part = APN (sto_part). Provides back_order_qty for Layer-1-only
-- parts.
l1_coming_order AS (
  SELECT site, sto_part, SUM(orl_ordqty) AS back_order_qty
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty
    FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
      INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
        ON TRIM(CAST(l.orl_order AS VARCHAR(100))) = TRIM(CAST(rl.ord_code AS VARCHAR(100)))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty
    FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
      INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
        ON TRIM(CAST(l.orl_order AS VARCHAR(100))) = TRIM(CAST(rl.ord_code AS VARCHAR(100)))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
  ) co
  GROUP BY site, sto_part
),

-- Site + product level part count.
-- Counts parts (APNs) by site + product to match the output grain.
-- Uses the same product derivation as the final SELECT: l1.product if available,
-- otherwise l2.product_list for Layer-2-only parts.
-- Used to scale part-level scores to site+product level in QuickSight.
site_product_part_count AS (
  SELECT
    COALESCE(l2.site, l1.site) AS site,
    CASE
      WHEN l1.product IS NULL
        OR TRIM(l1.product) = ''
        OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
      THEN l2.product_list
      ELSE l1.product
    END AS product,
    COUNT(COALESCE(l2.part, l1.apn)) AS sp_part_count
  FROM layer2 l2
    FULL OUTER JOIN layer1 l1
      ON l1.site = l2.site
     AND l1.apn  = l2.part
  GROUP BY COALESCE(l2.site, l1.site),
           CASE
             WHEN l1.product IS NULL
               OR TRIM(l1.product) = ''
               OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
             THEN l2.product_list
             ELSE l1.product
           END
)

SELECT
  -- Snapshot date stamped as the run date (today), populated for every row.
  CURRENT_DATE AS snapshot_date,

  -- Key columns COALESCEd across both sides.
  COALESCE(l2.site, l1.site) AS site,
  COALESCE(l2.part, l1.apn)  AS part,

  -- Layer 2 score columns (NULL for Layer-1-only parts).
  l2.region,
  l2.amazon_pn,
  l2.part_description,
  l2.cat_ref_list,
  l2.product_list,
  l2.building_type,
  -- Inventory columns: prefer Layer 2 and fall back to live l1_stock so
  -- Layer-1-only parts (absent from Layer 2) still show on-hand / min / max / class.
  COALESCE(l2.sto_class, ls.sto_class)     AS sto_class,
  COALESCE(l2.site_oh_qty, ls.site_oh_qty) AS site_oh_qty,
  COALESCE(l2.min_level, ls.min_level)     AS min_level,
  COALESCE(l2.max_level, ls.max_level)     AS max_level,
  l2.supplier_lead_time,
  l2.replenishment_time,
  l2.source,
  l2.order_count,
  l2.avg_rep_time_days,
  l2.min_rep_time_days,
  l2.max_rep_time_days,
  l2.last_received_date,
  l2.last_30d_order,
  l2.last_60d_order,
  l2.last_90d_order,
  l2.last_120d_order,
  l2.last_150d_order,
  l2.last_180d_order,
  l2.last_365d_order,
  l2.open_order_count,
  -- Back order qty: prefer Layer 2 and fall back to live l1_coming_order for
  -- Layer-1-only parts.
  COALESCE(l2.back_order_qty, lco.back_order_qty) AS back_order_qty,
  l2.nearest_po_number,
  l2.order_inaction_flag,
  l2.trend_ratio,
  l2.consumed_150d,
  l2.consumption_rate_150d,
  l2.replenishment_demand_150d,
  l2.coverage_150d,
  l2.stockout_fraction_150d,
  l2.stockout_days_per_cycle_150d,
  l2.cycle_length_days_150d,
  l2.cycles_per_year_150d,
  l2.stockout_days_yr_min_150d,
  l2.stockout_days_min_rep_150d,
  l2.combined_stockout_days_yr_150d,
  l2.structural_risk_combo_criticality_150d,
  l2.days_of_supply_150d,
  l2.depletion_date_150d,
  l2.projected_order_date_150d,
  l2.stockout_days_yr_rep_150d,
  l2.adj_days_of_supply_150d,

  -- Situational tier indicators (1/0 flags for each tier).
  -- NULL for parts with no APN (can't look up inventory without APN).
  -- NULL OH is treated as stockout (no stock record = effectively zero on hand).
  -- OH = 0 or NULL AND no PO (most critical)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS is_stockout_no_po,
  -- OH = 0 or NULL (PO exists)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS is_stockout_with_po,
  -- 0 < OH ≤ MIN AND no PO
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS is_below_min_no_po,
  -- 0 < OH ≤ MIN (PO exists)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS is_below_min_with_po,

  -- Situational score (tiered severity, 0-1 scale) — computed from the COALESCEd
  -- inventory columns so both Layer-2 and Layer-1-only parts get a score.
  -- NULL for parts with no APN (can't look up inventory without APN).
  -- NULL OH is treated as stockout (no stock record = effectively zero on hand).
  --   1.00  on-hand = 0 or NULL AND no PO
  --   0.75  on-hand = 0 or NULL (PO exists)
  --   0.50  0 < on-hand <= MIN AND no PO
  --   0.25  0 < on-hand <= MIN (PO exists)
  --   0.00  on-hand > MIN
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
    ELSE 0.00
  END AS situational_score_150d,

  -- Situational score criticality = sto_class weight × situational tier.
  -- NULL for parts with no APN.
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    ELSE ROUND(
      (CASE COALESCE(l2.sto_class, ls.sto_class)
         WHEN '01 HIGH' THEN 1.0
         WHEN '02 MED'  THEN 0.75
         WHEN '03 LOW'  THEN 0.5
         ELSE 0.25
       END)
      * CASE
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
          ELSE 0.00
        END
    , 4)
  END AS situational_score_criticality_150d,

  -- Overall score criticality = situational criticality + structural criticality.
  -- NULL for parts with no APN.
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    ELSE GREATEST(0.0, ROUND(
      (CASE COALESCE(l2.sto_class, ls.sto_class)
         WHEN '01 HIGH' THEN 1.0
         WHEN '02 MED'  THEN 0.75
         WHEN '03 LOW'  THEN 0.5
         ELSE 0.25
       END)
      * CASE
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
          ELSE 0.00
        END
      + COALESCE(l2.structural_risk_combo_criticality_150d, 0.0)
    , 4))
  END AS overall_score_criticality_150d,

  l2.ar_region,
  l2.subregion,
  l2.type,
  l2.subtype,

  -- Layer 1 enrichment (NULL for Layer-2-only parts).
  COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
  CASE WHEN l2.part IS NOT NULL THEN 1 ELSE 0 END AS in_score_base,
  -- Corrected Layer 1 product, falling back to Layer 2's product_list when the
  -- Layer 1 product is null/blank/NA (e.g. Layer-2-only rows). product_list is
  -- taken whole (may be comma-separated). Display fallback only; the site+product
  -- aggregation CTEs still key on the raw l1.product.
  CASE
    WHEN l1.product IS NULL
      OR TRIM(l1.product) = ''
      OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
    THEN l2.product_list
    ELSE l1.product
  END AS product,
  l1.mpn,
  l1.catalogue_reference,
  l1.sto_prefmanufactpart,
  -- APM MPN from r5stock (sto_prefmanufactpart). Falls back for Layer-1-only parts.
  ls.sto_prefmanufactpart AS apm_mpn,
  l1.sto_min_lev,
  l1.sto_leadtime,
  l1.not_set_up_in_apm,
  l1.missing_mpn_network,
  l1.missing_mpn_site,
  l1.missing_crn,
  l1.incorrect_mpn,
  l1.multiple_apns,
  -- Row-level: 1 if this MPN has any of the five APM setup problems.
  l1.incorrect_apm_setup,

  -- Site + product level counts of distinct flagged MPNs per category.
  COALESCE(pd.missing_mpn_network_count, 0) AS sp_missing_mpn_network_count,
  COALESCE(pd.missing_mpn_site_count, 0)    AS sp_missing_mpn_site_count,
  COALESCE(pd.missing_crn_count, 0)         AS sp_missing_crn_count,
  COALESCE(pd.incorrect_mpn_count, 0)       AS sp_incorrect_mpn_count,
  COALESCE(pd.multiple_apns_count, 0)       AS sp_multiple_apns_count,
  COALESCE(pd.no_apn_mapped_count, 0)       AS sp_no_apn_mapped_count,
  COALESCE(pd.incorrect_apm_setup_count, 0) AS sp_incorrect_apm_setup_count,
  -- Site+product penalty: 5 when sp_incorrect_apm_setup_count >= 50, else 0.
  COALESCE(pd.incorrect_apm_setup_penalty, 0) AS sp_incorrect_apm_setup_penalty,
  -- Site+product penalty: 5 when sp_no_apn_mapped_count >= 10, else 0.
  COALESCE(pd.no_apn_mapped_penalty, 0)     AS sp_no_apn_mapped_penalty,

  -- Distinct MPNs not set up in APM at this site (across all products).
  COALESCE(g.site_not_set_up_mpn_count, 0) AS site_not_set_up_mpn_count,
  -- Site-level APM penalty (5 when site has >= 10 MPNs not set up in APM, else 0).
  COALESCE(g.site_apm_penalty, 0) AS site_apm_penalty,
  -- Distinct MPNs not set up in APM for this site + product.
  COALESCE(gp.not_set_up_mpn_count, 0) AS not_set_up_mpn_count,

  -- Site + product level part count (for scaling part-level scores).
  COALESCE(spc.sp_part_count, 0) AS sp_part_count
FROM layer2 l2
  FULL OUTER JOIN layer1 l1
    ON l1.site = l2.site
   AND l1.apn  = l2.part
  LEFT JOIN site_apm_gap g
    ON g.site = COALESCE(l2.site, l1.site)
  LEFT JOIN site_product_apm_gap gp
    ON gp.site = COALESCE(l2.site, l1.site)
   AND gp.product = l1.product
  LEFT JOIN site_product_dq pd
    ON pd.site = COALESCE(l2.site, l1.site)
   AND pd.product = l1.product
  -- Live inventory + coming-order inputs for Layer-1-only parts, keyed on
  -- the resolved site + part (works for Layer-2-only, Layer-1-only, and both).
  LEFT JOIN l1_stock ls
    ON ls.site = COALESCE(l2.site, l1.site)
   AND ls.sto_part = COALESCE(l2.part, l1.apn)
  LEFT JOIN l1_coming_order lco
    ON lco.site = COALESCE(l2.site, l1.site)
   AND lco.sto_part = COALESCE(l2.part, l1.apn)
  LEFT JOIN site_product_part_count spc
    ON spc.site = COALESCE(l2.site, l1.site)
   AND spc.product = CASE
         WHEN l1.product IS NULL
           OR TRIM(l1.product) = ''
           OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
         THEN l2.product_list
         ELSE l1.product
       END
