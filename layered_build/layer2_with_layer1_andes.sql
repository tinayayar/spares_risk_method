-- layer2_with_layer1_andes.sql
-- ANDES/SDL onboarding version of layer2_with_layer1.sql
-- Uses bare (unqualified) table names for Andes onboarding.
--
-- Base : Layer 2 score base (latest snapshot only)
-- Enrich: Layer 1 RSPL / APM setup with corrected site->product mapping
--
-- Join: FULL OUTER JOIN on site + apn. Includes parts present in EITHER source.
-- Grain: one row per site + product + mpn + apn.
--
-- Dependencies (bare names -> original Andes source):
--   hw_critical_spares_target_sites      <- andes."ar-performance-n-insights.hw_critical_spares_target_sites"
--   hw_critical_spares_apm_setup_details <- andes."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--   hw_critical_spares_score_base        <- andes."ar-performance-n-insights.hw_critical_spares_score_base"
--   r5stock_apm_na / r5stock_apm_eu      <- andes."rme-gdl.r5stock_apm_*"
--   r5orderlines_apm_na / r5orderlines_apm_eu <- andes."rme-gdl.r5orderlines_apm_*"
--   r5orders_apm_na / r5orders_apm_eu    <- andes."rme-gdl.r5orders_apm_*"

WITH
-- Authoritative site -> product mapping from reference table.
target_sites AS (
  SELECT site, product
  FROM hw_critical_spares_target_sites
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
      WHEN UPPER(TRIM(CAST(d.apn AS STRING))) IN ('N/A', 'NA', '') THEN NULL
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
    CASE
      WHEN d.missing_mpn_network = 1
        OR d.missing_mpn_site    = 1
        OR d.missing_crn         = 1
        OR d.incorrect_mpn       = 1
        OR d.multiple_apns       = 1
      THEN 1 ELSE 0
    END AS incorrect_apm_setup
  FROM hw_critical_spares_apm_setup_details d
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
  GROUP BY site, product, mpn, apn
),

-- Distinct MPNs not set up in APM, per site + product.
site_product_apm_gap AS (
  SELECT site, product,
         COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) AS not_set_up_mpn_count
  FROM layer1_corrected
  GROUP BY site, product
),

-- Site + product level data-quality counts.
site_product_dq AS (
  SELECT site, product,
         COUNT(DISTINCT CASE WHEN missing_mpn_network = 1 THEN mpn END) AS missing_mpn_network_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_site    = 1 THEN mpn END) AS missing_mpn_site_count,
         COUNT(DISTINCT CASE WHEN missing_crn         = 1 THEN mpn END) AS missing_crn_count,
         COUNT(DISTINCT CASE WHEN incorrect_mpn       = 1 THEN mpn END) AS incorrect_mpn_count,
         COUNT(DISTINCT CASE WHEN multiple_apns       = 1 THEN mpn END) AS multiple_apns_count,
         COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)            AS no_apn_mapped_count,
         COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) AS incorrect_apm_setup_count,
         CASE WHEN COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) >= 50
              THEN 5 ELSE 0 END AS incorrect_apm_setup_penalty,
         CASE WHEN COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END) >= 10
              THEN 5 ELSE 0 END AS no_apn_mapped_penalty
  FROM layer1_corrected
  GROUP BY site, product
),

-- Site-level APM penalty.
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
  FROM hw_critical_spares_score_base
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM hw_critical_spares_score_base
  )
),

-- Live inventory inputs for Layer-1-only parts.
l1_stock AS (
  SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart
  FROM (
    SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart,
           ROW_NUMBER() OVER (PARTITION BY site, sto_part
                              ORDER BY CASE region WHEN 'NA' THEN 1 ELSE 2 END) AS rn
    FROM (
      SELECT SPLIT(st.sto_store, '-')[0] AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class)                  AS sto_class,
             MAX(st.sto_prefmanufactpart)       AS sto_prefmanufactpart,
             'NA' AS region
      FROM r5stock_apm_na st
      GROUP BY SPLIT(st.sto_store, '-')[0], st.sto_part
      UNION ALL
      SELECT SPLIT(st.sto_store, '-')[0] AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class)                  AS sto_class,
             MAX(st.sto_prefmanufactpart)       AS sto_prefmanufactpart,
             'EU' AS region
      FROM r5stock_apm_eu st
      GROUP BY SPLIT(st.sto_store, '-')[0], st.sto_part
    ) sto_raw
  ) ranked
  WHERE rn = 1
),

-- Coming/back orders from r5orderlines.
l1_coming_order AS (
  SELECT site, sto_part, SUM(orl_ordqty) AS back_order_qty
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM r5orderlines_apm_na l
      INNER JOIN r5orders_apm_na rl
        ON TRIM(CAST(l.orl_order AS STRING)) = TRIM(CAST(rl.ord_code AS STRING))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM r5orderlines_apm_eu l
      INNER JOIN r5orders_apm_eu rl
        ON TRIM(CAST(l.orl_order AS STRING)) = TRIM(CAST(rl.ord_code AS STRING))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
  ) co
  GROUP BY site, sto_part
),

-- Site + product level part count.
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

-- Cast every column to exact Andes sink SDL type.
SELECT
  CAST(CURRENT_DATE AS TIMESTAMP) AS snapshot_date,
  CAST(COALESCE(l2.site, l1.site) AS STRING) AS site,
  CAST(COALESCE(l2.part, l1.apn) AS STRING)  AS part,
  CAST(l2.region AS STRING) AS region,
  CAST(l2.amazon_pn AS STRING) AS amazon_pn,
  CAST(l2.part_description AS STRING) AS part_description,
  CAST(l2.cat_ref_list AS STRING) AS cat_ref_list,
  CAST(l2.product_list AS STRING) AS product_list,
  CAST(l2.building_type AS STRING) AS building_type,
  CAST(COALESCE(l2.sto_class, ls.sto_class) AS STRING) AS sto_class,
  CAST(COALESCE(l2.site_oh_qty, ls.site_oh_qty) AS DECIMAL(15,4)) AS site_oh_qty,
  CAST(COALESCE(l2.min_level, ls.min_level) AS DECIMAL(15,4)) AS min_level,
  CAST(COALESCE(l2.max_level, ls.max_level) AS DECIMAL(15,4)) AS max_level,
  CAST(l2.supplier_lead_time AS DECIMAL(15,4)) AS supplier_lead_time,
  CAST(l2.replenishment_time AS DECIMAL(15,4)) AS replenishment_time,
  CAST(l2.source AS STRING) AS source,
  CAST(l2.order_count AS INT) AS order_count,
  CAST(l2.avg_rep_time_days AS DECIMAL(15,4)) AS avg_rep_time_days,
  CAST(l2.min_rep_time_days AS INT) AS min_rep_time_days,
  CAST(l2.max_rep_time_days AS INT) AS max_rep_time_days,
  CAST(l2.last_received_date AS TIMESTAMP) AS last_received_date,
  CAST(l2.last_30d_order AS DECIMAL(15,4)) AS last_30d_order,
  CAST(l2.last_60d_order AS DECIMAL(15,4)) AS last_60d_order,
  CAST(l2.last_90d_order AS DECIMAL(15,4)) AS last_90d_order,
  CAST(l2.last_120d_order AS DECIMAL(15,4)) AS last_120d_order,
  CAST(l2.last_150d_order AS DECIMAL(15,4)) AS last_150d_order,
  CAST(l2.last_180d_order AS DECIMAL(15,4)) AS last_180d_order,
  CAST(l2.last_365d_order AS DECIMAL(15,4)) AS last_365d_order,
  CAST(l2.open_order_count AS INT) AS open_order_count,
  CAST(COALESCE(l2.back_order_qty, lco.back_order_qty) AS DECIMAL(15,4)) AS back_order_qty,
  CAST(l2.nearest_po_number AS STRING) AS nearest_po_number,
  CAST(l2.order_inaction_flag AS INT) AS order_inaction_flag,
  CAST(l2.trend_ratio AS DECIMAL(15,4)) AS trend_ratio,
  CAST(l2.consumed_150d AS DECIMAL(15,4)) AS consumed_150d,
  CAST(l2.consumption_rate_150d AS DECIMAL(15,4)) AS consumption_rate_150d,
  CAST(l2.replenishment_demand_150d AS DECIMAL(15,4)) AS replenishment_demand_150d,
  CAST(l2.coverage_150d AS DECIMAL(15,4)) AS coverage_150d,
  CAST(l2.stockout_fraction_150d AS DECIMAL(15,4)) AS stockout_fraction_150d,
  CAST(l2.stockout_days_per_cycle_150d AS DECIMAL(15,4)) AS stockout_days_per_cycle_150d,
  CAST(l2.cycle_length_days_150d AS DECIMAL(15,4)) AS cycle_length_days_150d,
  CAST(l2.cycles_per_year_150d AS DECIMAL(15,4)) AS cycles_per_year_150d,
  CAST(l2.stockout_days_yr_min_150d AS DECIMAL(15,4)) AS stockout_days_yr_min_150d,
  CAST(l2.stockout_days_min_rep_150d AS DECIMAL(15,4)) AS stockout_days_min_rep_150d,
  CAST(l2.combined_stockout_days_yr_150d AS DECIMAL(15,4)) AS combined_stockout_days_yr_150d,
  CAST(l2.structural_risk_combo_criticality_150d AS DECIMAL(15,4)) AS structural_risk_combo_criticality_150d,
  CAST(l2.days_of_supply_150d AS DECIMAL(15,4)) AS days_of_supply_150d,
  CAST(l2.depletion_date_150d AS TIMESTAMP) AS depletion_date_150d,
  CAST(l2.projected_order_date_150d AS TIMESTAMP) AS projected_order_date_150d,
  CAST(l2.stockout_days_yr_rep_150d AS DECIMAL(15,4)) AS stockout_days_yr_rep_150d,
  CAST(l2.adj_days_of_supply_150d AS DECIMAL(15,4)) AS adj_days_of_supply_150d,

  -- Situational tier indicators
  CAST(CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS INT) AS is_stockout_no_po,
  CAST(CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS INT) AS is_stockout_with_po,
  CAST(CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS INT) AS is_below_min_no_po,
  CAST(CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS INT) AS is_below_min_with_po,

  -- Situational scores
  CAST(CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
    ELSE 0.00
  END AS DECIMAL(15,4)) AS situational_score_150d,

  CAST(CASE
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
  END AS DECIMAL(15,4)) AS situational_score_criticality_150d,

  CAST(CASE
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
  END AS DECIMAL(15,4)) AS overall_score_criticality_150d,

  CAST(l2.ar_region AS STRING) AS ar_region,
  CAST(l2.subregion AS STRING) AS subregion,
  CAST(l2.type AS STRING) AS type,
  CAST(l2.subtype AS STRING) AS subtype,

  -- Layer 1 enrichment
  CAST(COALESCE(l1.is_rspl_apn, 0) AS INT) AS is_rspl_apn,
  CAST(CASE WHEN l2.part IS NOT NULL THEN 1 ELSE 0 END AS INT) AS in_score_base,
  CAST(CASE
    WHEN l1.product IS NULL
      OR TRIM(l1.product) = ''
      OR UPPER(TRIM(l1.product)) IN ('N/A', 'NA')
    THEN l2.product_list
    ELSE l1.product
  END AS STRING) AS product,
  CAST(l1.mpn AS STRING) AS mpn,
  CAST(l1.catalogue_reference AS STRING) AS catalogue_reference,
  CAST(l1.sto_prefmanufactpart AS STRING) AS sto_prefmanufactpart,
  CAST(ls.sto_prefmanufactpart AS STRING) AS apm_mpn,
  CAST(l1.sto_min_lev AS DECIMAL(15,4)) AS sto_min_lev,
  CAST(l1.sto_leadtime AS DECIMAL(15,4)) AS sto_leadtime,
  CAST(l1.not_set_up_in_apm AS INT) AS not_set_up_in_apm,
  CAST(l1.missing_mpn_network AS INT) AS missing_mpn_network,
  CAST(l1.missing_mpn_site AS INT) AS missing_mpn_site,
  CAST(l1.missing_crn AS INT) AS missing_crn,
  CAST(l1.incorrect_mpn AS INT) AS incorrect_mpn,
  CAST(l1.multiple_apns AS INT) AS multiple_apns,
  CAST(l1.incorrect_apm_setup AS INT) AS incorrect_apm_setup,

  -- Site + product level counts
  CAST(COALESCE(pd.missing_mpn_network_count, 0) AS INT) AS sp_missing_mpn_network_count,
  CAST(COALESCE(pd.missing_mpn_site_count, 0) AS INT) AS sp_missing_mpn_site_count,
  CAST(COALESCE(pd.missing_crn_count, 0) AS INT) AS sp_missing_crn_count,
  CAST(COALESCE(pd.incorrect_mpn_count, 0) AS INT) AS sp_incorrect_mpn_count,
  CAST(COALESCE(pd.multiple_apns_count, 0) AS INT) AS sp_multiple_apns_count,
  CAST(COALESCE(pd.no_apn_mapped_count, 0) AS INT) AS sp_no_apn_mapped_count,
  CAST(COALESCE(pd.incorrect_apm_setup_count, 0) AS INT) AS sp_incorrect_apm_setup_count,
  CAST(COALESCE(pd.incorrect_apm_setup_penalty, 0) AS INT) AS sp_incorrect_apm_setup_penalty,
  CAST(COALESCE(pd.no_apn_mapped_penalty, 0) AS INT) AS sp_no_apn_mapped_penalty,
  CAST(COALESCE(g.site_not_set_up_mpn_count, 0) AS INT) AS site_not_set_up_mpn_count,
  CAST(COALESCE(g.site_apm_penalty, 0) AS INT) AS site_apm_penalty,
  CAST(COALESCE(gp.not_set_up_mpn_count, 0) AS INT) AS not_set_up_mpn_count,
  CAST(COALESCE(spc.sp_part_count, 0) AS INT) AS sp_part_count

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
