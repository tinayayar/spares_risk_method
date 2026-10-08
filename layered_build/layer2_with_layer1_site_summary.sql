-- layer2_with_layer1_site_summary.sql
-- Site-level summary view aggregated from layer2_with_layer1.
-- Sums across all products at each site (no APN de-duplication across products).
--
-- Grain: one row per site + is_rspl_apn (2 rows per site: RSPL vs non-RSPL parts).
-- Use case: Site-level dashboard showing total risk burden across all programs,
--           with ability to filter/compare RSPL vs non-RSPL parts.

WITH
-- Reuse the same target_sites, layer1_corrected, layer1, site_product_dq, etc.
-- from layer2_with_layer1.sql (copy the relevant CTEs here for standalone execution).

-- Authoritative site -> product mapping.
-- Reads from two Andes tables:
--   1. hw_critical_spares_target_sites: USP and URL products (already standardized)
--   2. hw_spares_ar_install_base: Other products (Robin, etc.) — uppercased here
-- Products are standardized to uppercase (e.g., 'USP', 'USP_B1', 'URL Rev D', 'ROBIN', 'CARDINAL').
target_sites AS (
  -- USP and URL from target_sites table (already standardized format)
  SELECT site, product
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_target_sites"
  
  UNION
  
  -- Other products from install_base — UPPER() to standardize case
  SELECT DISTINCT site, UPPER(TRIM(product)) AS product
  FROM "andes"."ar-performance-n-insights.hw_spares_ar_install_base"
  WHERE machine_cnt > 0  -- Only sites with active machines
),

valid_site_product AS (
  SELECT DISTINCT site, product FROM target_sites
),

layer1_corrected AS (
  SELECT
    d.site,
    CASE
      -- USP: split by region and version
      WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.region)) = 'EU' THEN 'USP_EU'
      WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.version)) = 'B1' THEN 'USP_B1'
      WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
      -- URL: split by rspl_rev (handle both 'C2' and 'C.2' variants)
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) IN ('C2', 'C.2') THEN 'URL Rev C2'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
      -- Other products: uppercase the product name directly
      ELSE UPPER(TRIM(d.product))
    END AS product,
    d.mpn,
    d.catalogue_reference,
    CASE
      WHEN UPPER(TRIM(CAST(d.apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
      ELSE d.apn
    END AS apn,
    d.not_set_up_in_apm,
    d.missing_mpn_network,
    d.missing_mpn_site,
    d.missing_crn,
    d.incorrect_mpn,
    d.multiple_apns,
    CASE
      WHEN d.missing_mpn_network = 1 OR d.missing_mpn_site = 1 OR d.missing_crn = 1
        OR d.incorrect_mpn = 1 OR d.multiple_apns = 1
      THEN 1 ELSE 0
    END AS incorrect_apm_setup
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details" d
    INNER JOIN valid_site_product v
      ON v.site = d.site
     AND v.product = CASE
           -- USP: split by region and version
           WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.region)) = 'EU' THEN 'USP_EU'
           WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.version)) = 'B1' THEN 'USP_B1'
           WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
           -- URL: split by rspl_rev (handle both 'C2' and 'C.2' variants)
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) IN ('C2', 'C.2') THEN 'URL Rev C2'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
           -- Other products: uppercase the product name directly
           ELSE UPPER(TRIM(d.product))
         END
),

layer1 AS (
  SELECT
    site, product, mpn, apn,
    1 AS is_rspl_apn,
    MAX(catalogue_reference) AS catalogue_reference,
    MAX(not_set_up_in_apm)   AS not_set_up_in_apm,
    MAX(missing_mpn_network) AS missing_mpn_network,
    MAX(missing_mpn_site)    AS missing_mpn_site,
    MAX(missing_crn)         AS missing_crn,
    MAX(incorrect_mpn)       AS incorrect_mpn,
    MAX(multiple_apns)       AS multiple_apns,
    MAX(incorrect_apm_setup) AS incorrect_apm_setup
  FROM layer1_corrected
  GROUP BY site, product, mpn, apn
),

-- Site + product + is_rspl_apn level data-quality counts (from layer1_corrected).
-- Note: DQ counts only apply to RSPL parts (is_rspl_apn = 1) since they come from Layer 1.
site_product_dq AS (
  SELECT site, product,
         COUNT(DISTINCT mpn) AS mpn_count,
         COUNT(DISTINCT CASE WHEN apn IS NOT NULL THEN apn END) AS apn_with_mapping_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_network = 1 THEN mpn END) AS missing_mpn_network_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_site    = 1 THEN mpn END) AS missing_mpn_site_count,
         COUNT(DISTINCT CASE WHEN missing_crn         = 1 THEN mpn END) AS missing_crn_count,
         COUNT(DISTINCT CASE WHEN incorrect_mpn       = 1 THEN mpn END) AS incorrect_mpn_count,
         COUNT(DISTINCT CASE WHEN multiple_apns       = 1 THEN mpn END) AS multiple_apns_count,
         COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)             AS no_apn_mapped_count,
         COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) AS incorrect_apm_setup_count,
         CASE WHEN COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) >= 50
              THEN 5 ELSE 0 END AS incorrect_apm_setup_penalty,
         -- Graduated tiers (Option 1) on distinct MPNs with no APN mapped --
         -- same bands as layer2_with_layer1.sql so the two files agree:
         --   >=50 -> 10,  >=25 -> 8,  >=10 -> 5,  >=1 -> 2,  0 -> 0.
         CASE
           WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 50 THEN 10
           WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 25 THEN 8
           WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 10 THEN 5
           WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 1  THEN 2
           ELSE 0
         END AS no_apn_mapped_penalty
  FROM layer1_corrected
  GROUP BY site, product
),

layer2 AS (
  SELECT *
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
),

l1_stock AS (
  SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class
  FROM (
    SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class,
           ROW_NUMBER() OVER (PARTITION BY site, sto_part ORDER BY CASE region WHEN 'NA' THEN 1 ELSE 2 END) AS rn
    FROM (
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE)) AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class) AS sto_class,
             'NA' AS region
      FROM "andes"."rme-gdl.r5stock_apm_na" st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
      UNION ALL
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE)) AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class) AS sto_class,
             'EU' AS region
      FROM "andes"."rme-gdl.r5stock_apm_eu" st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
    ) sto_raw
  ) ranked
  WHERE rn = 1
),

l1_coming_order AS (
  SELECT site, sto_part, SUM(orl_ordqty) AS back_order_qty
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS sto_part, CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON TRIM(CAST(l.orl_order AS VARCHAR)) = TRIM(CAST(rl.ord_code AS VARCHAR))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS sto_part, CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON TRIM(CAST(l.orl_order AS VARCHAR)) = TRIM(CAST(rl.ord_code AS VARCHAR))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
  ) co
  GROUP BY site, sto_part
),

-- Row-level data with is_rspl_apn flag.
-- Used for aggregating scores and status counts by site + is_rspl_apn.
row_data AS (
  SELECT
    COALESCE(l2.site, l1.site) AS site,
    CASE
      WHEN l1.product IS NULL OR TRIM(l1.product) = '' OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
      THEN l2.product_list
      ELSE l1.product
    END AS product,
    -- is_rspl_apn: 1 if part is from Layer 1 (RSPL), 0 if Layer-2-only
    COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
    l1.mpn,
    COALESCE(l2.part, l1.apn) AS part,
    l2.structural_risk_combo_criticality_150d,
    -- Situational score computed from inventory
    CASE
      WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
      ELSE ROUND(
        (CASE COALESCE(l2.sto_class, ls.sto_class)
           WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25
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
    -- Status indicators
    CASE WHEN COALESCE(l2.stockout_days_yr_min_150d, 0) > 0 THEN 1 ELSE 0 END AS need_min_max_review,
    CASE WHEN COALESCE(l2.stockout_days_yr_rep_150d, 0) > 0 THEN 1 ELSE 0 END AS need_lead_time_review,
    CASE
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
      ELSE 0
    END AS is_stockout_no_po,
    CASE
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
      ELSE 0
    END AS is_stockout_with_po,
    CASE
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
      ELSE 0
    END AS is_below_min_no_po,
    CASE
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
      ELSE 0
    END AS is_below_min_with_po
  FROM layer2 l2
    FULL OUTER JOIN layer1 l1 ON l1.site = l2.site AND l1.apn = l2.part
    LEFT JOIN l1_stock ls ON ls.site = COALESCE(l2.site, l1.site) AND ls.sto_part = COALESCE(l2.part, l1.apn)
    LEFT JOIN l1_coming_order lco ON lco.site = COALESCE(l2.site, l1.site) AND lco.sto_part = COALESCE(l2.part, l1.apn)
),

-- Site + product + is_rspl_apn level aggregation.
site_product_rspl_agg AS (
  SELECT
    site,
    product,
    is_rspl_apn,
    COUNT(DISTINCT mpn) AS sp_mpn_count,
    COUNT(DISTINCT part) AS sp_apn_count,
    SUM(COALESCE(structural_risk_combo_criticality_150d, 0)) AS sp_sum_structural_score,
    SUM(COALESCE(situational_score_criticality_150d, 0)) AS sp_sum_situational_score,
    SUM(need_min_max_review) AS sp_need_min_max_review_count,
    SUM(need_lead_time_review) AS sp_need_lead_time_review_count,
    SUM(is_stockout_no_po) AS sp_stockout_no_po_count,
    SUM(is_stockout_with_po) AS sp_stockout_with_po_count,
    SUM(is_below_min_no_po) AS sp_below_min_no_po_count,
    SUM(is_below_min_with_po) AS sp_below_min_with_po_count
  FROM row_data
  GROUP BY site, product, is_rspl_apn
),

-- Join with DQ counts (only applicable to RSPL parts).
site_product_rspl_full AS (
  SELECT
    a.site,
    a.product,
    a.is_rspl_apn,
    a.sp_mpn_count,
    a.sp_apn_count,
    a.sp_sum_structural_score,
    a.sp_sum_situational_score,
    a.sp_need_min_max_review_count,
    a.sp_need_lead_time_review_count,
    a.sp_stockout_no_po_count,
    a.sp_stockout_with_po_count,
    a.sp_below_min_no_po_count,
    a.sp_below_min_with_po_count,
    -- DQ counts only for RSPL parts; NULL for non-RSPL
    CASE WHEN a.is_rspl_apn = 1 THEN COALESCE(d.no_apn_mapped_count, 0) ELSE NULL END AS sp_no_apn_mapped_count,
    CASE WHEN a.is_rspl_apn = 1 THEN COALESCE(d.incorrect_apm_setup_count, 0) ELSE NULL END AS sp_incorrect_apm_setup_count,
    CASE WHEN a.is_rspl_apn = 1 THEN COALESCE(d.incorrect_apm_setup_penalty, 0) ELSE NULL END AS sp_incorrect_apm_setup_penalty,
    CASE WHEN a.is_rspl_apn = 1 THEN COALESCE(d.no_apn_mapped_penalty, 0) ELSE NULL END AS sp_no_apn_mapped_penalty,
    -- APM setup risk = 7 * no-APN-mapped penalty + incorrect-setup penalty.
    -- no-APN is weighted x7 (the priority signal); incorrect-setup enters at
    -- weight 1 (secondary). (NULL for non-RSPL.)
    CASE WHEN a.is_rspl_apn = 1 
         THEN 7 * COALESCE(d.no_apn_mapped_penalty, 0) + COALESCE(d.incorrect_apm_setup_penalty, 0)
         ELSE NULL 
    END AS sp_apm_setup_risk_score
  FROM site_product_rspl_agg a
    LEFT JOIN site_product_dq d ON d.site = a.site AND d.product = a.product AND a.is_rspl_apn = 1
)

-- ============================================================================
-- SITE-LEVEL SUMMARY: Aggregate by site + is_rspl_apn.
-- Output: 2 rows per site (one for RSPL parts, one for non-RSPL parts).
-- ============================================================================
SELECT
  CURRENT_DATE AS snapshot_date,
  site,
  is_rspl_apn,
  
  -- Facility attributes (join to get region, type, etc.)
  COALESCE(fac.region, 'Unknown') AS ar_region,
  COALESCE(fac.subregion, 'Unknown') AS subregion,
  COALESCE(fac.type, 'Unknown') AS type,
  COALESCE(fac.subtype, 'Unknown') AS subtype,
  CASE WHEN fac.address_country IN ('United States', 'US', 'USA', 'Canada', 'Mexico') THEN 'NA' ELSE 'EU' END AS region,
  
  -- Product count at site (for this RSPL category)
  COUNT(DISTINCT product) AS site_product_count,
  
  -- MPN and APN counts (sum across products)
  SUM(sp_mpn_count) AS site_mpn_count,
  SUM(sp_apn_count) AS site_apn_count,
  
  -- Structural and situational score sums
  SUM(sp_sum_structural_score) AS site_sum_structural_score,
  SUM(sp_sum_situational_score) AS site_sum_situational_score,
  
  -- Scaled scores
  ROUND(100.0 * SUM(sp_sum_structural_score) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_scaled_structural_score,
  ROUND(100.0 * SUM(sp_sum_situational_score) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_scaled_situational_score,
  
  -- APM setup risk score, NORMALIZED by the number of (RSPL) products at the
  -- site: SUM(sp_apm_setup_risk_score) / COUNT(DISTINCT product). This removes
  -- the "site looks worse just because it has more products" bias -- it is the
  -- average APM-setup penalty per product. COUNT(DISTINCT product) is RSPL-only
  -- on this row because the final SELECT groups by site + is_rspl_apn, and the
  -- penalty is non-NULL only for the is_rspl_apn = 1 row. (NULL for non-RSPL.)
  ROUND(SUM(sp_apm_setup_risk_score) * 1.0 / NULLIF(COUNT(DISTINCT product), 0), 2)
    AS site_apm_setup_risk_score,
  -- Component penalties, normalized by product count the SAME way as the
  -- combined score above, so the two components add up to site_apm_setup_risk_score.
  ROUND(SUM(sp_incorrect_apm_setup_penalty) * 1.0 / NULLIF(COUNT(DISTINCT product), 0), 2)
    AS site_incorrect_apm_setup_penalty,
  ROUND(SUM(sp_no_apn_mapped_penalty) * 1.0 / NULLIF(COUNT(DISTINCT product), 0), 2)
    AS site_no_apn_mapped_penalty,
  
  -- Total score = scaled_structural + scaled_situational + apm_setup_risk,
  -- where apm_setup_risk = (7 * no_apn_penalty + incorrect_setup_penalty)
  -- already baked into sp_apm_setup_risk_score and normalized per product. The
  -- APM term is the SAME per-product-normalized value as the standalone
  -- site_apm_setup_risk_score column, so the two stay consistent.
  -- For non-RSPL parts, APM setup risk is excluded (treated as 0).
  ROUND(
    COALESCE(100.0 * SUM(sp_sum_structural_score) / NULLIF(SUM(sp_apn_count), 0), 0)
    + COALESCE(100.0 * SUM(sp_sum_situational_score) / NULLIF(SUM(sp_apn_count), 0), 0)
    + COALESCE(SUM(sp_apm_setup_risk_score) * 1.0 / NULLIF(COUNT(DISTINCT product), 0), 0)
  , 2) AS site_total_score,
  
  -- MPN-based counts (only for RSPL parts)
  SUM(sp_no_apn_mapped_count) AS site_no_apn_mapped_count,
  SUM(sp_incorrect_apm_setup_count) AS site_incorrect_apm_setup_count,
  
  -- MPN-based percentages (only for RSPL parts)
  ROUND(100.0 * SUM(sp_no_apn_mapped_count) / NULLIF(SUM(sp_mpn_count), 0), 2) AS site_pct_mpn_no_apn_mapped,
  ROUND(100.0 * SUM(sp_incorrect_apm_setup_count) / NULLIF(SUM(sp_mpn_count), 0), 2) AS site_pct_mpn_incorrect_apm_setup,
  
  -- APN-based status counts
  SUM(sp_need_min_max_review_count) AS site_need_min_max_review_count,
  SUM(sp_need_lead_time_review_count) AS site_need_lead_time_review_count,
  SUM(sp_stockout_no_po_count) AS site_stockout_no_po_count,
  SUM(sp_stockout_with_po_count) AS site_stockout_with_po_count,
  SUM(sp_below_min_no_po_count) AS site_below_min_no_po_count,
  SUM(sp_below_min_with_po_count) AS site_below_min_with_po_count,
  
  -- APN-based percentages
  ROUND(100.0 * SUM(sp_need_min_max_review_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_need_min_max_review,
  ROUND(100.0 * SUM(sp_need_lead_time_review_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_need_lead_time_review,
  ROUND(100.0 * SUM(sp_stockout_no_po_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_stockout_no_po,
  ROUND(100.0 * SUM(sp_stockout_with_po_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_stockout_with_po,
  ROUND(100.0 * SUM(sp_below_min_no_po_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_below_min_no_po,
  ROUND(100.0 * SUM(sp_below_min_with_po_count) / NULLIF(SUM(sp_apn_count), 0), 2) AS site_pct_apn_below_min_with_po

FROM site_product_rspl_full spf
  LEFT JOIN "andes"."ar-performance-n-insights.rts_rcc_facilities" fac
    ON fac.code = spf.site
GROUP BY
  site,
  is_rspl_apn,
  fac.region,
  fac.subregion,
  fac.type,
  fac.subtype,
  fac.address_country
