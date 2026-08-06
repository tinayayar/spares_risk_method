-- stockout_combined_athena.sql
-- Combined AR + MSP stockout score table (QuickSight/Redshift)
-- Unions both sources, tags with source column, recalculates site-level aggregations
-- No deduplication — parts appearing in both tables will have two rows

WITH
msp_parts AS (
  SELECT
    snapshot_date, site, region, part, amazon_pn, product, part_description, building_type,
    sto_class, site_oh_qty, min_level, max_level,
    supplier_lead_time, replenishment_time,
    order_count, avg_rep_time_days, min_rep_time_days, max_rep_time_days, last_received_date,
    last_30d_order, last_60d_order, last_90d_order,
    last_120d_order, last_150d_order, last_180d_order, last_365d_order,
    open_order_count, back_order_qty,
    earliest_open_order_date, nearest_po_number,
    order_inaction_flag, trend_ratio,
    consumed_150d, consumption_rate_150d, replenishment_demand_150d,
    coverage_150d, stockout_fraction_150d, stockout_days_per_cycle_150d,
    cycle_length_days_150d, cycles_per_year_150d,
    stockout_days_yr_min_150d, stockout_days_min_rep_150d,
    combined_stockout_days_yr_150d, stockout_days_yr_rep_150d,
    stockout_days_min_share_150d, stockout_days_rep_share_150d,
    structural_risk_combo_criticality_150d,
    days_of_supply_150d, adj_days_of_supply_150d,
    situational_score_150d, situational_score_criticality_150d,
    overall_score_criticality_150d,
    depletion_date_150d, projected_order_date_150d,
    'MSP' AS source
  FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_msp
),

ar_parts AS (
  SELECT
    hcsa1.snapshot_date, hcsa1.site, hcsa1.region, hcsa1.amzn_part AS part, hcsa1.amzn_part AS amazon_pn,
    ii1.product_category AS product, hcsa1.part_description, hcsa1.building_type,
    hcsa1.sto_class, hcsa1.site_oh_qty, hcsa1.min_level, hcsa1.max_level,
    hcsa1.supplier_lead_time, hcsa1.replenishment_time,
    hcsa1.hx_order_count AS order_count, hcsa1.hx_avg_rep_time_days AS avg_rep_time_days,
    hcsa1.hx_min_rep_time_days AS min_rep_time_days, hcsa1.hx_max_rep_time_days AS max_rep_time_days,
    hcsa1.hx_last_shipment_date AS last_received_date,
    hcsa1.hx_last_30d_order AS last_30d_order, hcsa1.hx_last_60d_order AS last_60d_order,
    hcsa1.hx_last_90d_order AS last_90d_order, hcsa1.hx_last_120d_order AS last_120d_order,
    hcsa1.hx_last_150d_order AS last_150d_order, hcsa1.hx_last_180d_order AS last_180d_order,
    hcsa1.hx_last_365d_order AS last_365d_order,
    hcsa1.co_open_order_count AS open_order_count, hcsa1.co_back_order_qty AS back_order_qty,
    NULL AS earliest_open_order_date, NULL AS nearest_po_number,
    hcsa1.order_inaction_flag, hcsa1.trend_ratio,
    hcsa1.consumed_150d, hcsa1.consumption_rate_150d, hcsa1.replenishment_demand_150d,
    hcsa1.coverage_150d, hcsa1.stockout_fraction_150d, hcsa1.stockout_days_per_cycle_150d,
    hcsa1.cycle_length_days_150d, hcsa1.cycles_per_year_150d,
    hcsa1.stockout_days_yr_min_150d, hcsa1.stockout_days_min_rep_150d,
    hcsa1.combined_stockout_days_yr_150d, hcsa1.stockout_days_yr_rep_150d,
    hcsa1.stockout_days_min_share_150d, hcsa1.stockout_days_rep_share_150d,
    hcsa1.structural_risk_combo_criticality_150d,
    hcsa1.days_of_supply_150d, hcsa1.adj_days_of_supply_150d,
    hcsa1.situational_score_150d, hcsa1.situational_score_criticality_150d,
    hcsa1.overall_score_criticality_150d,
    hcsa1.depletion_date_150d, hcsa1.projected_order_date_150d,
    'AR' AS source
  FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_ar AS hcsa1
  LEFT JOIN (
    SELECT site, item, product_category,
           ROW_NUMBER() OVER (PARTITION BY site, item ORDER BY LENGTH(product_category) DESC) AS rn
    FROM andes_bi_ext."skydatacatalog"."istore-inventory"
    WHERE product_category IS NOT NULL
  ) ii1 ON hcsa1.site = ii1.site AND hcsa1.part_number = ii1.item AND ii1.rn = 1
),

combined AS (
  SELECT * FROM msp_parts
  UNION ALL
  SELECT * FROM ar_parts
),

-- Dedup: if a part+site exists in both AR and MSP, keep MSP
deduped AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY site, part ORDER BY CASE source WHEN 'MSP' THEN 1 ELSE 2 END) AS dedup_rn
  FROM combined
)

SELECT
  c.*,
  -- Recalculated site-level aggregations across all parts (AR + MSP combined)
  COUNT(*) OVER (PARTITION BY c.site) AS site_total_part_count,
  SUM(COALESCE(c.combined_stockout_days_yr_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_combined_stockout_days_yr_150d,
  SUM(COALESCE(c.stockout_days_yr_min_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_stockout_days_yr_min_150d,
  SUM(COALESCE(c.stockout_days_yr_rep_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_stockout_days_yr_rep_150d,
  SUM(COALESCE(c.stockout_days_min_rep_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_stockout_days_min_rep_150d,
  SUM(COALESCE(c.structural_risk_combo_criticality_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_structural_risk_combo_criticality_150d,
  SUM(COALESCE(c.situational_score_criticality_150d, 0.0)) OVER (PARTITION BY c.site) AS site_sum_situational_score_criticality_150d,
  SUM(CASE WHEN c.stockout_days_min_share_150d > 0 THEN 1 ELSE 0 END) OVER (PARTITION BY c.site) AS site_count_parts_min_share_gt0,
  SUM(CASE WHEN c.stockout_days_rep_share_150d > 0 THEN 1 ELSE 0 END) OVER (PARTITION BY c.site) AS site_count_parts_rep_share_gt0,
  SUM(CASE WHEN c.site_oh_qty = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY c.site) AS site_count_parts_zero_oh,
  SUM(CASE WHEN c.order_inaction_flag = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY c.site) AS site_count_parts_order_inaction,
  SUM(CASE WHEN COALESCE(c.back_order_qty, 0) > 0 AND (COALESCE(c.back_order_qty, 0) + COALESCE(c.site_oh_qty, 0)) < COALESCE(c.min_level, 0) THEN 1 ELSE 0 END) OVER (PARTITION BY c.site) AS site_count_parts_backorder_below_min
FROM deduped c
WHERE c.dedup_rn = 1
ORDER BY c.site, c.source, c.combined_stockout_days_yr_150d DESC NULLS LAST
