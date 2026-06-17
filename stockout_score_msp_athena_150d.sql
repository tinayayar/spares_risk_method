-- stockout_score_msp_athena.sql
-- Stockout Score Calculation — UIS MSP POC parts across NA and EU sites
-- Athena variant — uses "andes"."rme-gdl.tablename" schema prefix.
-- Part inclusion: Amazon PNs from bads.rta_spa_hardware_component_replacement_rate (matched via cat_ref)
--
-- Methodology (all lead times in days, 150d consumption window):
--   replenishment_time     = supplier_lead_time
--   replenishment_demand   = consumption_rate * replenishment_time
--   coverage               = min / replenishment_demand (capped at 1.0)
--   stockout_fraction      = 1 - coverage
--   stockout_days_per_cycle= stockout_fraction * replenishment_time
--   cycle_length_days      = (max - min) / consumption_rate
--   cycles_per_year        = 365 / cycle_length_days
--   total_stockout_days    = cycles_per_year * stockout_days_per_cycle
--   annual_stockout_pct    = total_stockout_days / 365 * 100
--   suggested_score        = annual_stockout_pct

WITH
-- Target parts from bads.rta_spa_hardware_component_replacement_rate table
target_parts AS (
  SELECT DISTINCT apn AS sto_part
  FROM "andes"."bads.rta_spa_hardware_component_replacement_rate_current_union_view"
  WHERE apn IS NOT NULL
),

-- Site building type lookup
site_building_type AS (
  SELECT DISTINCT warehouse AS site, building_type
  FROM (
    SELECT warehouse, building_type
    FROM "andes"."ardatalake.ardl_common_prodna__warehouses_enhanced_lookup"
    WHERE building_type IS NOT NULL
    UNION ALL
    SELECT warehouse, building_type
    FROM "andes"."ardatalake.ardl_common_prodeu__warehouses_enhanced_lookup"
    WHERE building_type IS NOT NULL
  ) wh
),

-- Product lookup per apn
apn_product_model AS (
  SELECT DISTINCT apn, product
  FROM "andes"."bads.rta_spa_hardware_component_replacement_rate_current_union_view"
  WHERE apn IS NOT NULL
),


-- Part description from catalogue
part_info AS (
  SELECT cat_part AS sto_part,
         MAX(cat_desc) AS part_description,
         region
  FROM (
    SELECT c.cat_part, c.cat_desc, 'NA' AS region
    FROM "andes"."rme-gdl.r5catalogue_apm_na" c
    WHERE c.cat_part IN (SELECT sto_part FROM target_parts)
      AND c.cat_desc IS NOT NULL
    UNION ALL
    SELECT c.cat_part, c.cat_desc, 'EU' AS region
    FROM "andes"."rme-gdl.r5catalogue_eu" c
    WHERE c.cat_part IN (SELECT sto_part FROM target_parts)
      AND c.cat_desc IS NOT NULL
  ) cat_d
  GROUP BY cat_part, region
),

-- Stock levels: min/max/current per site
stock AS (
  SELECT site, region, sto_part,
         MAX(min_level)   AS min_level,
         MAX(max_level)   AS max_level,
         MAX(sto_class)   AS sto_class
  FROM (
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site,
           st.sto_part,
           CAST(st.sto_minlev AS DOUBLE) AS min_level,
           CAST(st.sto_maxqty AS DOUBLE) AS max_level,
           st.sto_class,
           'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site,
           st.sto_part,
           CAST(st.sto_minlev AS DOUBLE) AS min_level,
           CAST(st.sto_maxqty AS DOUBLE) AS max_level,
           st.sto_class,
           'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
  ) sto_raw
  GROUP BY site, region, sto_part
),

-- Lead time from catalogue via orders placed by each site
order_lead_times AS (
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS DOUBLE)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'NA' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_na"
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
    AND l.orl_part IN (SELECT sto_part FROM target_parts)
  UNION ALL
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS DOUBLE)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'EU' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN "andes"."rme-gdl.r5catalogue_eu"
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
    AND l.orl_part IN (SELECT sto_part FROM target_parts)
),
lead_time AS (
  SELECT site, part_ordered, region,
         MAX(supplier_lead_time) AS lead_time
  FROM order_lead_times
  WHERE supplier_lead_time IS NOT NULL
  GROUP BY site, part_ordered, region
),

-- Replacements from pre-computed work order tables
replacements AS (
  -- USP parts
  SELECT organization AS site, region, amazon_apn AS amzn_part,
         DATE(trl_date) AS replaced_on,
         CAST(qty_replaced AS DOUBLE) AS qty_replaced
  FROM "andes"."ar-performance-n-insights.hw_usp_replacement_work_orders"
  WHERE amazon_apn IN (SELECT sto_part FROM target_parts)
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
    AND qty_replaced > 0
  UNION ALL
  -- UIS parts
  SELECT organization AS site, region, amazon_apn AS amzn_part,
         DATE(trl_date) AS replaced_on,
         CAST(qty_replaced AS DOUBLE) AS qty_replaced
  FROM "andes"."ar-performance-n-insights.hw_uis_work_orders_na_24_months"
  WHERE amazon_apn IN (SELECT sto_part FROM target_parts)
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
    AND qty_replaced > 0
),

consumption AS (
  SELECT site, region, amzn_part AS sto_part,
    SUM(CASE WHEN replaced_on >= date_add('day', -30, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_30d,
    SUM(CASE WHEN replaced_on >= date_add('day', -60, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_60d,
    SUM(CASE WHEN replaced_on >= date_add('day', -90, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_90d,
    SUM(CASE WHEN replaced_on >= date_add('day', -120, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_120d,
    SUM(CASE WHEN replaced_on >= date_add('day', -150, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_150d,
    SUM(CASE WHEN replaced_on >= date_add('day', -180, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_180d,
    SUM(COALESCE(qty_replaced,0)) AS consumed_365d
  FROM replacements
  GROUP BY site, region, amzn_part
),

-- Site inventory
site_inv_raw AS (
  SELECT *, RANK() OVER (PARTITION BY sto_part, site, region ORDER BY sto_updated DESC) rnk
  FROM (
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'NA' AS region, st.sto_part,
           CAST(st.sto_qty AS DOUBLE) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM "andes"."rme-gdl.r5stock_apm_na" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'EU' AS region, st.sto_part,
           CAST(st.sto_qty AS DOUBLE) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM "andes"."rme-gdl.r5stock_apm_eu" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
  ) sto
),
site_inv AS (
  SELECT site, region, sto_part, SUM(sto_qty) AS sto_qty
  FROM site_inv_raw WHERE rnk = 1
  GROUP BY site, region, sto_part
),
site_oh_qty AS (
  SELECT site, region, sto_part, MAX(sto_qty) AS site_oh_qty
  FROM site_inv
  GROUP BY site, region, sto_part
),

-- Order history: received orders aggregated per (part, site, region)
received_orders AS (
  SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         CAST(l.orl_lastsaved AS DATE) AS order_received_date,
         date_diff('day', CAST(rl.ord_created AS DATE), CAST(l.orl_lastsaved AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty, 'NA' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    AND ((rl.ord_status = 'AR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'PR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'AR' AND l.orl_status = 'soft'))
    AND CAST(rl.ord_created AS DATE) >= CURRENT_DATE - INTERVAL '365' DAY
  UNION ALL
  SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         CAST(l.orl_lastsaved AS DATE) AS order_received_date,
         date_diff('day', CAST(rl.ord_created AS DATE), CAST(l.orl_lastsaved AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty, 'EU' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    AND ((rl.ord_status = 'AR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'PR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'AR' AND l.orl_status = 'soft'))
    AND CAST(rl.ord_created AS DATE) >= CURRENT_DATE - INTERVAL '365' DAY
),
order_history AS (
  SELECT site, part_ordered AS sto_part, region,
         COUNT(*) AS order_count,
         ROUND(AVG(CAST(rep_time_days AS DOUBLE)), 2) AS avg_rep_time_days,
         MIN(rep_time_days) AS min_rep_time_days,
         MAX(rep_time_days) AS max_rep_time_days,
         MAX(order_received_date) AS last_received_date,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '30' DAY THEN orl_ordqty ELSE 0 END) / 30.0, 4) AS last_30d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '60' DAY THEN orl_ordqty ELSE 0 END) / 60.0, 4) AS last_60d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '90' DAY THEN orl_ordqty ELSE 0 END) / 90.0, 4) AS last_90d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '120' DAY THEN orl_ordqty ELSE 0 END) / 120.0, 4) AS last_120d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '150' DAY THEN orl_ordqty ELSE 0 END) / 150.0, 4) AS last_150d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '180' DAY THEN orl_ordqty ELSE 0 END) / 180.0, 4) AS last_180d_order,
         ROUND(SUM(orl_ordqty) / 365.0, 4) AS last_365d_order
  FROM received_orders
  GROUP BY site, part_ordered, region
),

-- Coming orders: open/approved orders (back_order_qty per part/site)
coming_order_data AS (
  SELECT l.orl_part AS part_ordered,
         rl.ord_org AS site,
         trim(cast(l.orl_order AS varchar)) AS order_number,
         CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty,
         'NA' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    AND rl.ord_status = 'A'
    AND l.orl_status = 'A'
  UNION ALL
  SELECT l.orl_part AS part_ordered,
         rl.ord_org AS site,
         trim(cast(l.orl_order AS varchar)) AS order_number,
         CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty,
         'EU' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    AND rl.ord_status = 'A'
    AND l.orl_status = 'A'
),
coming_order_qty AS (
  SELECT part_ordered AS sto_part, site, region,
         COUNT(DISTINCT order_number) AS open_order_count,
         SUM(orl_ordqty) AS back_order_qty
  FROM coming_order_data
  GROUP BY part_ordered, site, region
),

metrics AS (
  SELECT s.site, s.region, s.sto_part,
         s.sto_part AS amazon_pn,
         apm.product,
         pi.part_description,
         bt.building_type,
         s.sto_class, s.min_level, s.max_level,
         lt.lead_time AS supplier_lead_time,
         COALESCE(soh.site_oh_qty, 0.0) AS site_oh_qty,
         -- Order history columns
         oh.order_count, oh.avg_rep_time_days, oh.min_rep_time_days, oh.max_rep_time_days,
         oh.last_received_date,
         oh.last_30d_order, oh.last_60d_order, oh.last_90d_order,
         oh.last_120d_order, oh.last_150d_order, oh.last_180d_order, oh.last_365d_order,
         -- Coming order columns
         COALESCE(co.open_order_count, 0) AS open_order_count,
         COALESCE(co.back_order_qty, 0.0) AS back_order_qty,
         c.consumed_30d / 30.0 AS rate_30d, c.consumed_60d / 60.0 AS rate_60d,
         c.consumed_90d / 90.0 AS rate_90d, c.consumed_120d / 120.0 AS rate_120d,
         c.consumed_150d / 150.0 AS rate_150d, c.consumed_180d / 180.0 AS rate_180d,
         c.consumed_365d / 365.0 AS rate_365d,
         c.consumed_30d, c.consumed_60d, c.consumed_90d,
         c.consumed_120d, c.consumed_150d, c.consumed_180d, c.consumed_365d,
         lt.lead_time AS replenishment_time,
         COALESCE(c.consumed_30d / 30.0, 0.0) * lt.lead_time AS replenishment_demand_30d,
         COALESCE(c.consumed_60d / 60.0, 0.0) * lt.lead_time AS replenishment_demand_60d,
         COALESCE(c.consumed_90d / 90.0, 0.0) * lt.lead_time AS replenishment_demand_90d,
         COALESCE(c.consumed_120d / 120.0, 0.0) * lt.lead_time AS replenishment_demand_120d,
         COALESCE(c.consumed_150d / 150.0, 0.0) * lt.lead_time AS replenishment_demand_150d,
         COALESCE(c.consumed_180d / 180.0, 0.0) * lt.lead_time AS replenishment_demand_180d,
         COALESCE(c.consumed_365d / 365.0, 0.0) * lt.lead_time AS replenishment_demand_365d,
         CASE WHEN COALESCE(c.consumed_30d / 30.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_30d / 30.0) ELSE NULL END AS cycle_length_days_30d,
         CASE WHEN COALESCE(c.consumed_60d / 60.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_60d / 60.0) ELSE NULL END AS cycle_length_days_60d,
         CASE WHEN COALESCE(c.consumed_90d / 90.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_90d / 90.0) ELSE NULL END AS cycle_length_days_90d,
         CASE WHEN COALESCE(c.consumed_120d / 120.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_120d / 120.0) ELSE NULL END AS cycle_length_days_120d,
         CASE WHEN COALESCE(c.consumed_150d / 150.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_150d / 150.0) ELSE NULL END AS cycle_length_days_150d,
         CASE WHEN COALESCE(c.consumed_180d / 180.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_180d / 180.0) ELSE NULL END AS cycle_length_days_180d,
         CASE WHEN COALESCE(c.consumed_365d / 365.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_365d / 365.0) ELSE NULL END AS cycle_length_days_365d
  FROM stock s
    LEFT JOIN apn_product_model apm ON apm.apn = s.sto_part
    LEFT JOIN part_info pi ON pi.sto_part = s.sto_part AND pi.region = s.region
    LEFT JOIN site_building_type bt ON bt.site = s.site
    LEFT JOIN consumption c ON c.site = s.site AND c.region = s.region AND c.sto_part = s.sto_part
    LEFT JOIN lead_time lt ON lt.site = s.site AND lt.region = s.region AND lt.part_ordered = s.sto_part
    LEFT JOIN site_oh_qty soh ON soh.site = s.site AND soh.region = s.region AND soh.sto_part = s.sto_part
    LEFT JOIN order_history oh ON oh.site = s.site AND oh.region = s.region AND oh.sto_part = s.sto_part
    LEFT JOIN coming_order_qty co ON co.site = s.site AND co.region = s.region AND co.sto_part = s.sto_part
)
SELECT
  CURRENT_DATE AS snapshot_date,
  site, region, sto_part AS "Part", amazon_pn, product, part_description, building_type,
  sto_class, site_oh_qty, min_level, max_level,
  supplier_lead_time, replenishment_time,

  -- Order history
  order_count, avg_rep_time_days, min_rep_time_days, max_rep_time_days,
  last_received_date,
  last_30d_order, last_60d_order, last_90d_order,
  last_120d_order, last_150d_order, last_180d_order, last_365d_order,

  -- Coming orders
  open_order_count, back_order_qty,

  -- Order inaction flag
  CASE WHEN COALESCE(site_oh_qty, 0.0) < min_level AND COALESCE(back_order_qty, 0) = 0 THEN 1 ELSE 0 END AS order_inaction_flag,

  -- Trend ratio
  ROUND(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE NULL END, 4) AS trend_ratio,

  -- 150d window
  consumed_150d,
  ROUND(rate_150d, 4) AS consumption_rate_150d,
  ROUND(replenishment_demand_150d, 2) AS replenishment_demand_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN LEAST(1.0, min_level / replenishment_demand_150d) ELSE 1.0 END, 4) AS coverage_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_150d) ELSE 0.0 END, 4) AS stockout_fraction_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_150d,
  ROUND(cycle_length_days_150d, 2) AS cycle_length_days_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 THEN 365.0 / cycle_length_days_150d ELSE NULL END, 2) AS cycles_per_year_150d,
  ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2) AS stockout_days_yr_min_150d,
  ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2) AS stockout_days_min_rep_150d,
  GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) AS combined_stockout_days_yr_150d,
  GREATEST(0.0, ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2) - ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) AS stockout_days_yr_rep_150d,
  ROUND(CASE WHEN GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) > 0 THEN ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2) / GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) ELSE NULL END, 4) AS stockout_days_min_share_150d,
  ROUND(CASE WHEN GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) > 0 THEN GREATEST(0.0, ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2) - ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) / GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) ELSE NULL END, 4) AS stockout_days_rep_share_150d,
  SUM(GREATEST(0.0, ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2) - ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2))) OVER (PARTITION BY site) AS site_sum_stockout_days_yr_rep_150d,
  SUM(ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) OVER (PARTITION BY site) AS site_sum_stockout_days_yr_min_150d,
  SUM(GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2))) OVER (PARTITION BY site) AS site_sum_combined_stockout_days_yr_150d,
  GREATEST(0.0, ROUND(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) / 365.0, 4)) AS structural_risk_combo_criticality_150d,
  ROUND(CASE WHEN COALESCE(rate_150d, 0.0) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / rate_150d ELSE NULL END, 2) AS days_of_supply_150d,
  ROUND(CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END, 2) AS adj_days_of_supply_150d,
  ROUND(CASE WHEN supplier_lead_time > 0 AND CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END IS NOT NULL THEN (supplier_lead_time - (CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END)) / supplier_lead_time ELSE NULL END, 4) AS situational_score_150d,
  GREATEST(0.0, ROUND(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * (CASE WHEN supplier_lead_time > 0 AND CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END IS NOT NULL THEN (supplier_lead_time - (CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END)) / supplier_lead_time ELSE NULL END), 4)) AS situational_score_criticality_150d,
  GREATEST(0.0, ROUND(COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * (CASE WHEN supplier_lead_time > 0 AND CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END IS NOT NULL THEN (supplier_lead_time - (CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END)) / supplier_lead_time ELSE NULL END), 0.0) + COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) / 365.0, 0.0), 4)) AS overall_score_criticality_150d,
  GREATEST(0.0, SUM(COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * (CASE WHEN supplier_lead_time > 0 AND CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END IS NOT NULL THEN (supplier_lead_time - (CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END)) / supplier_lead_time ELSE NULL END), 0.0)) OVER (PARTITION BY site)) AS site_sum_situational_score_criticality_150d,
  GREATEST(0.0, SUM(COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) / 365.0, 0.0)) OVER (PARTITION BY site)) AS site_sum_structural_risk_combo_criticality_150d,
  CASE WHEN COALESCE(rate_150d, 0.0) > 0 THEN date_add('day', CAST((COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / rate_150d AS INTEGER), CURRENT_DATE) ELSE NULL END AS depletion_date_150d,
  CASE WHEN COALESCE(rate_150d, 0.0) > 0 AND supplier_lead_time IS NOT NULL THEN date_add('day', CAST((COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / rate_150d - supplier_lead_time AS INTEGER), CURRENT_DATE) ELSE NULL END AS projected_order_date_150d,

  COUNT(*) OVER (PARTITION BY site) AS site_total_part_count

FROM metrics
WHERE COALESCE(consumed_365d, 0) > 0 AND sto_class IN ('01 HIGH', '02 MED', '03 LOW')
ORDER BY sto_part, structural_risk_combo_criticality_150d DESC NULLS LAST, site
