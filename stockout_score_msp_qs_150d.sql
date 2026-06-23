-- stockout_score_msp_qs_150d.sql
-- Stockout Score Calculation — UIS MSP POC parts across NA and EU sites
-- QuickSight/Redshift variant — uses andes_bi_ext."rme-gdl".tablename schema prefix.
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
  FROM andes_bi_ext."bads".rta_spa_hardware_component_replacement_rate_current
  WHERE apn IS NOT NULL
),

-- Site building type lookup
site_building_type AS (
  SELECT DISTINCT warehouse AS site, building_type
  FROM (
    SELECT warehouse, building_type
    FROM andes_bi_ext."ardatalake".ardl_common_prodna__warehouses_enhanced_lookup
    WHERE building_type IS NOT NULL
    UNION ALL
    SELECT warehouse, building_type
    FROM andes_bi_ext."ardatalake".ardl_common_prodeu__warehouses_enhanced_lookup
    WHERE building_type IS NOT NULL
  ) wh
),

-- Product lookup per apn
apn_product_model AS (
  SELECT DISTINCT apn, product
  FROM andes_bi_ext."bads".rta_spa_hardware_component_replacement_rate_current
  WHERE apn IS NOT NULL
),


-- Part description from catalogue
part_info AS (
  SELECT cat_part AS sto_part,
         MAX(cat_desc) AS part_description,
         region
  FROM (
    SELECT c.cat_part, c.cat_desc, 'NA' AS region
    FROM andes_bi_ext."rme-gdl".r5catalogue_apm_na c
    WHERE c.cat_part IN (SELECT sto_part FROM target_parts)
      AND c.cat_desc IS NOT NULL
    UNION ALL
    SELECT c.cat_part, c.cat_desc, 'EU' AS region
    FROM andes_bi_ext."rme-gdl".r5catalogue_apm_eu c
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
           CAST(st.sto_minlev AS FLOAT) AS min_level,
           CAST(st.sto_maxqty AS FLOAT) AS max_level,
           st.sto_class,
           'NA' AS region
    FROM andes_bi_ext."rme-gdl".r5stock_apm_na st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site,
           st.sto_part,
           CAST(st.sto_minlev AS FLOAT) AS min_level,
           CAST(st.sto_maxqty AS FLOAT) AS max_level,
           st.sto_class,
           'EU' AS region
    FROM andes_bi_ext."rme-gdl".r5stock_apm_eu st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
  ) sto_raw
  GROUP BY site, region, sto_part
),

-- Lead time from catalogue via orders placed by each site
order_lead_times AS (
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS FLOAT)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN andes_bi_ext."rme-gdl".r5catalogue_apm_na
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
    AND l.orl_part IN (SELECT sto_part FROM target_parts)
  UNION ALL
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS FLOAT)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN andes_bi_ext."rme-gdl".r5catalogue_apm_eu
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

-- Replacements from pre-computed work order tables + raw building blocks for other products
-- USP/UIS parts list (for exclusion in raw building blocks)
usp_uis_parts AS (
  SELECT DISTINCT apn AS sto_part
  FROM andes_bi_ext."bads".rta_spa_hardware_component_replacement_rate_current
  WHERE product IN ('USP', 'UIS') AND apn IS NOT NULL
),

-- Raw building blocks for non-USP/UIS products (aligned with replacements_athena.sql)
repl_events AS (
  SELECT evt_code AS event, evt_org AS organization, 'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5events_apm_na
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
  UNION
  SELECT evt_code AS event, evt_org AS organization, 'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5events_apm_eu
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
),
repl_stock AS (
  SELECT rs.sto_part, COALESCE(rs.sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(rs.sto_store,'-',1) site, 'NA' region
  FROM andes_bi_ext."rme-gdl".r5stock_apm_na rs
  WHERE rs.sto_part IN (SELECT sto_part FROM target_parts)
    AND rs.sto_part NOT IN (SELECT sto_part FROM usp_uis_parts)
  UNION
  SELECT rs.sto_part, COALESCE(rs.sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(rs.sto_store,'-',1) site, 'EU' region
  FROM andes_bi_ext."rme-gdl".r5stock_apm_eu rs
  WHERE rs.sto_part IN (SELECT sto_part FROM target_parts)
    AND rs.sto_part NOT IN (SELECT sto_part FROM usp_uis_parts)
),
repl_transactions AS (
  SELECT trl_event, trl_part AS amzn_part, 'NA' AS region,
         MAX(trl_date) AS trl_date, SUM(trl_qty) AS trl_qty
  FROM andes_bi_ext."rme-gdl".r5translines_apm_na
  WHERE trl_part IN (SELECT sto_part FROM target_parts)
    AND trl_part NOT IN (SELECT sto_part FROM usp_uis_parts)
    AND trl_type = 'I'
    AND DATE(trl_date) >= DATEADD('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
  UNION
  SELECT trl_event, trl_part AS amzn_part, 'EU' AS region,
         MAX(trl_date) AS trl_date, SUM(trl_qty) AS trl_qty
  FROM andes_bi_ext."rme-gdl".r5translines_apm_eu
  WHERE trl_part IN (SELECT sto_part FROM target_parts)
    AND trl_part NOT IN (SELECT sto_part FROM usp_uis_parts)
    AND trl_type = 'I'
    AND DATE(trl_date) >= DATEADD('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
),

replacements AS (
  -- USP parts from pre-computed table
  SELECT organization AS site, region, "amazon_apn" AS amzn_part,
         DATE(trl_date) AS replaced_on,
         CAST(qty_replaced AS FLOAT) AS qty_replaced
  FROM andes_bi_ext."ar-performance-n-insights".hw_usp_replacement_work_orders
  WHERE "amazon_apn" IN (SELECT sto_part FROM target_parts)
    AND DATE(trl_date) >= DATEADD('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  UNION ALL
  -- UIS parts from pre-computed table
  SELECT organization AS site, region, "amazon_apn" AS amzn_part,
         DATE(trl_date) AS replaced_on,
         CAST(qty_replaced AS FLOAT) AS qty_replaced
  FROM andes_bi_ext."ar-performance-n-insights".hw_uis_work_orders_na_24_months
  WHERE "amazon_apn" IN (SELECT sto_part FROM target_parts)
    AND DATE(trl_date) >= DATEADD('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  UNION ALL
  -- Other products from raw building blocks (no catalogue/supplier filter)
  SELECT DISTINCT e.organization AS site, e.region, t.amzn_part,
         DATE(t.trl_date) AS replaced_on,
         CAST(t.trl_qty AS FLOAT) AS qty_replaced
  FROM repl_events e
    JOIN repl_transactions t ON t.trl_event = e.event AND e.region = t.region
    JOIN repl_stock s ON t.amzn_part = s.sto_part AND s.site = e.organization
  WHERE t.amzn_part IS NOT NULL
),

consumption AS (
  SELECT site, region, amzn_part AS sto_part,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -30, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_30d,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -60, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_60d,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -90, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_90d,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -120, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_120d,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -150, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_150d,
    SUM(CASE WHEN replaced_on >= DATEADD('day', -180, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_180d,
    SUM(COALESCE(qty_replaced,0)) AS consumed_365d
  FROM replacements
  GROUP BY site, region, amzn_part
),

-- Site inventory
site_inv_raw AS (
  SELECT *, RANK() OVER (PARTITION BY sto_part, site, region ORDER BY sto_updated DESC) rnk
  FROM (
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'NA' AS region, st.sto_part,
           CAST(st.sto_qty AS FLOAT) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM andes_bi_ext."rme-gdl".r5stock_apm_na st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'EU' AS region, st.sto_part,
           CAST(st.sto_qty AS FLOAT) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM andes_bi_ext."rme-gdl".r5stock_apm_eu st
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
         DATEDIFF('day', CAST(rl.ord_created AS DATE), CAST(l.orl_lastsaved AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty, 'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
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
         DATEDIFF('day', CAST(rl.ord_created AS DATE), CAST(l.orl_lastsaved AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty, 'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
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
         ROUND(AVG(CAST(rep_time_days AS FLOAT)), 2) AS avg_rep_time_days,
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
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty,
         'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    AND rl.ord_status = 'A'
    AND l.orl_status = 'A'
  UNION ALL
  SELECT l.orl_part AS part_ordered,
         rl.ord_org AS site,
         trim(cast(l.orl_order AS varchar)) AS order_number,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty,
         'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
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
  SUM(GREATEST(0.0, COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * (CASE WHEN supplier_lead_time > 0 AND CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END IS NOT NULL THEN (supplier_lead_time - (CASE WHEN COALESCE(rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0)) > 0 THEN (COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / (rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(last_150d_order, 0.0) > 0 THEN (COALESCE(last_30d_order, 0.0) - last_150d_order) / last_150d_order ELSE 0.0 END, 0.0))) ELSE NULL END)) / supplier_lead_time ELSE NULL END), 0.0))) OVER (PARTITION BY site) AS site_sum_situational_score_criticality_150d,
  GREATEST(0.0, SUM(COALESCE(CASE sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END * GREATEST(ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(avg_rep_time_days, 0.0) * COALESCE(rate_150d, 0.0) > 0 AND cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, min_level / (avg_rep_time_days * rate_150d))) * avg_rep_time_days * (365.0 / cycle_length_days_150d) ELSE 0.0 END)), 2), ROUND(LEAST(365.0, CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END), 2)) / 365.0, 0.0)) OVER (PARTITION BY site)) AS site_sum_structural_risk_combo_criticality_150d,
  CASE WHEN COALESCE(rate_150d, 0.0) > 0 THEN DATEADD('day', CAST((COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / rate_150d AS INTEGER), CURRENT_DATE) ELSE NULL END AS depletion_date_150d,
  CASE WHEN COALESCE(rate_150d, 0.0) > 0 AND supplier_lead_time IS NOT NULL THEN DATEADD('day', CAST((COALESCE(back_order_qty, 0.0) + COALESCE(site_oh_qty, 0.0)) / rate_150d - supplier_lead_time AS INTEGER), CURRENT_DATE) ELSE NULL END AS projected_order_date_150d,

  COUNT(*) OVER (PARTITION BY site) AS site_total_part_count

FROM metrics
WHERE COALESCE(consumed_365d, 0) > 0 AND sto_class IN ('01 HIGH', '02 MED', '03 LOW')
ORDER BY sto_part, structural_risk_combo_criticality_150d DESC NULLS LAST, site
