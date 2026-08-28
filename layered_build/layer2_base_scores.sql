-- layer2_base_scores.sql
-- Layer 2: Base data + score calculations for all target parts
-- target_parts = hw_raw_consumption_daily APNs UNION Layer 1 RSPL APNs
-- Consumption source: hw_raw_consumption_daily
-- Order history: DWEEB (AR) + r5orderlines (non-AR)
-- Depends on: Layer 1 table (rspl_apn_site_mapping)

WITH
-- Target parts: hw_raw_consumption APNs + RSPL APNs from Layer 1
target_parts AS (
  SELECT DISTINCT amazon_apn AS sto_part
  FROM "andes"."ar-performance-n-insights.hw_raw_consumption_daily"
  WHERE amazon_apn IS NOT NULL
  -- UNCOMMENT below once Layer 1 table is built:
  -- UNION
  -- SELECT DISTINCT apn AS sto_part
  -- FROM "andes"."ar-performance-n-insights.rspl_apn_site_mapping"
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

-- Part description + cat_ref from catalogue (one row per sto_part, cat_refs collapsed)
part_info AS (
  SELECT sto_part, part_description, cat_ref_list, region
  FROM (
    SELECT cat_part AS sto_part,
           MAX(cat_desc) AS part_description,
           ARRAY_JOIN(ARRAY_AGG(DISTINCT cat_ref), ', ') AS cat_ref_list,
           region,
           ROW_NUMBER() OVER (PARTITION BY cat_part ORDER BY region) AS rn
    FROM (
      SELECT c.cat_part, c.cat_desc, c.cat_ref, 'NA' AS region
      FROM "andes"."rme-gdl.r5catalogue_apm_na" c
      WHERE c.cat_part IN (SELECT sto_part FROM target_parts)
        AND c.cat_desc IS NOT NULL
      UNION ALL
      SELECT c.cat_part, c.cat_desc, c.cat_ref, 'EU' AS region
      FROM "andes"."rme-gdl.r5catalogue_apm_eu" c
      WHERE c.cat_part IN (SELECT sto_part FROM target_parts)
        AND c.cat_desc IS NOT NULL
    ) cat_d
    GROUP BY cat_part, region
  ) ranked
  WHERE rn = 1
),

-- Stock levels (dedup: prefer NA over EU)
stock AS (
  SELECT site, region, sto_part, min_level, max_level, sto_class
  FROM (
    SELECT site, region, sto_part, min_level, max_level, sto_class,
           ROW_NUMBER() OVER (PARTITION BY site, sto_part ORDER BY CASE region WHEN 'NA' THEN 1 ELSE 2 END) AS rn
    FROM (
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class) AS sto_class, 'NA' AS region
      FROM "andes"."rme-gdl.r5stock_apm_na" st
      WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
      UNION ALL
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class) AS sto_class, 'EU' AS region
      FROM "andes"."rme-gdl.r5stock_apm_eu" st
      WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
    ) sto_raw
  ) ranked
  WHERE rn = 1
),

-- Lead time (site + part level, no region)
lead_time AS (
  SELECT site, part_ordered,
         MAX(supplier_lead_time) AS lead_time
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
           CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_na"
        ON cat_part = l.orl_part AND cat_supplier = l.orl_supplier
    WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
           CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_eu"
        ON cat_part = l.orl_part AND cat_supplier = l.orl_supplier
    WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
  ) olt
  WHERE supplier_lead_time IS NOT NULL
  GROUP BY site, part_ordered
),

-- Consumption from hw_raw_consumption_daily (site + apn level)
consumption AS (
  SELECT organization AS site, amazon_apn AS sto_part,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -30, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_30d,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -60, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_60d,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -90, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_90d,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -120, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_120d,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -150, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_150d,
    SUM(CASE WHEN DATE(trl_date) >= date_add('day', -180, CURRENT_DATE) THEN CAST(qty_consumed AS DOUBLE) ELSE 0 END) AS consumed_180d,
    SUM(CAST(qty_consumed AS DOUBLE)) AS consumed_365d
  FROM "andes"."ar-performance-n-insights.hw_raw_consumption_daily"
  WHERE amazon_apn IN (SELECT sto_part FROM target_parts)
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY organization, amazon_apn
),

-- Site OH qty (no region)
site_oh_qty AS (
  SELECT site, sto_part, MAX(sto_qty) AS site_oh_qty
  FROM (
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
           CAST(st.sto_qty AS DOUBLE) AS sto_qty,
           RANK() OVER (PARTITION BY st.sto_part, SPLIT_PART(st.sto_store, '-', 1) ORDER BY CAST(st.sto_updated AS TIMESTAMP) DESC) AS rnk
    FROM "andes"."rme-gdl.r5stock_apm_na" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
           CAST(st.sto_qty AS DOUBLE) AS sto_qty,
           RANK() OVER (PARTITION BY st.sto_part, SPLIT_PART(st.sto_store, '-', 1) ORDER BY CAST(st.sto_updated AS TIMESTAMP) DESC) AS rnk
    FROM "andes"."rme-gdl.r5stock_apm_eu" st
    WHERE st.sto_part IN (SELECT sto_part FROM target_parts)
  ) ranked
  WHERE rnk = 1
  GROUP BY site, sto_part
),

-- Order history from r5orderlines (for non-AR parts)
order_history AS (
  SELECT site, part_ordered AS sto_part,
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
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
           CAST(rl.ord_created AS DATE) AS order_created_date,
           CAST(l.orl_lastsaved AS DATE) AS order_received_date,
           date_diff('day', CAST(rl.ord_created AS DATE), CAST(l.orl_lastsaved AS DATE)) AS rep_time_days,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
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
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
      AND ((rl.ord_status = 'AR' AND l.orl_status = 'A')
        OR (rl.ord_status = 'PR' AND l.orl_status = 'A')
        OR (rl.ord_status = 'AR' AND l.orl_status = 'soft'))
      AND CAST(rl.ord_created AS DATE) >= CURRENT_DATE - INTERVAL '365' DAY
  ) received_orders
  GROUP BY site, part_ordered
),

-- Coming orders from r5orderlines (for non-AR parts)
coming_order_qty AS (
  SELECT part_ordered AS sto_part, site,
         COUNT(DISTINCT order_number) AS open_order_count,
         SUM(orl_ordqty) AS back_order_qty
  FROM (
    SELECT l.orl_part AS part_ordered, rl.ord_org AS site,
           trim(cast(l.orl_order AS varchar)) AS order_number,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
      AND rl.ord_status = 'A' AND l.orl_status = 'A'
    UNION ALL
    SELECT l.orl_part AS part_ordered, rl.ord_org AS site,
           trim(cast(l.orl_order AS varchar)) AS order_number,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
      AND rl.ord_status = 'A' AND l.orl_status = 'A'
  ) coming_order_data
  GROUP BY part_ordered, site
),

-- Nearest open PO: most recent open order per (part, site)
nearest_open_order AS (
  SELECT sto_part, site, order_number AS nearest_po_number, ord_created_date AS nearest_po_date
  FROM (
    SELECT part_ordered AS sto_part, site, order_number, ord_created_date,
           ROW_NUMBER() OVER (PARTITION BY part_ordered, site ORDER BY ord_created_date DESC) AS rn
    FROM (
      SELECT l.orl_part AS part_ordered, rl.ord_org AS site,
             trim(cast(l.orl_order AS varchar)) AS order_number,
             CAST(rl.ord_created AS DATE) AS ord_created_date
      FROM "andes"."rme-gdl.r5orderlines_apm_na" l
        INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
          ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
        AND rl.ord_status = 'A' AND l.orl_status = 'A'
      UNION ALL
      SELECT l.orl_part AS part_ordered, rl.ord_org AS site,
             trim(cast(l.orl_order AS varchar)) AS order_number,
             CAST(rl.ord_created AS DATE) AS ord_created_date
      FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
        INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
          ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      WHERE l.orl_part IN (SELECT sto_part FROM target_parts)
        AND rl.ord_status = 'A' AND l.orl_status = 'A'
    ) open_orders
  ) ranked
  WHERE rn = 1
),

-- DWEEB order history (for AR parts)
dweeb_hx AS (
  SELECT site, part_no,
         order_count, avg_rep_time_days, min_rep_time_days, max_rep_time_days,
         p80_rep_time_days, last_shipment_date,
         last_30d_order, last_60d_order, last_90d_order,
         last_120d_order, last_150d_order, last_180d_order, last_365d_order
  FROM "andes"."skydatacatalog.dweeb_hx_order"
),

-- DWEEB coming orders (for AR parts)
dweeb_co AS (
  SELECT part_no, site,
         COUNT(DISTINCT "OrderNumber") AS co_open_order_count,
         SUM(qtyordered) AS co_total_qty_on_order,
         MAX(back_order_qty) AS co_back_order_qty
  FROM "andes"."skydatacatalog.dweeb-coming-order"
  WHERE revised_ship_date != 'Returned'
  GROUP BY part_no, site
),

-- Metrics: core calculations
metrics AS (
  SELECT s.site, s.region, s.sto_part,
         s.sto_part AS amazon_pn,
         pi.part_description, pi.cat_ref_list,
         -- Derive part_number from first cat_ref (for DWEEB join, internal only)
         CASE
           WHEN UPPER(TRIM(SPLIT_PART(pi.cat_ref_list, ',', 1))) LIKE 'R%' OR UPPER(TRIM(SPLIT_PART(pi.cat_ref_list, ',', 1))) LIKE '%-FRU'
           THEN REPLACE(REPLACE(UPPER(TRIM(SPLIT_PART(pi.cat_ref_list, ',', 1))), '-FRU', ''), 'R', '')
           ELSE UPPER(TRIM(SPLIT_PART(pi.cat_ref_list, ',', 1)))
         END AS part_number,
         bt.building_type,
         s.sto_class, s.min_level, s.max_level,
         lt.lead_time AS supplier_lead_time,
         COALESCE(soh.site_oh_qty, 0.0) AS site_oh_qty,
         -- R5 order history (fallback)
         oh.order_count AS r5_order_count,
         oh.avg_rep_time_days AS r5_avg_rep_time_days,
         oh.min_rep_time_days AS r5_min_rep_time_days,
         oh.max_rep_time_days AS r5_max_rep_time_days,
         oh.last_received_date AS r5_last_received_date,
         oh.last_30d_order AS r5_last_30d_order, oh.last_60d_order AS r5_last_60d_order,
         oh.last_90d_order AS r5_last_90d_order, oh.last_120d_order AS r5_last_120d_order,
         oh.last_150d_order AS r5_last_150d_order, oh.last_180d_order AS r5_last_180d_order,
         oh.last_365d_order AS r5_last_365d_order,
         -- R5 coming orders (fallback)
         COALESCE(co.open_order_count, 0) AS r5_open_order_count,
         COALESCE(co.back_order_qty, 0.0) AS r5_back_order_qty,
         -- Nearest PO
         npo.nearest_po_number,
         -- Consumption
         c.consumed_150d / 150.0 AS rate_150d,
         c.consumed_150d, c.consumed_365d,
         lt.lead_time AS replenishment_time,
         COALESCE(c.consumed_150d / 150.0, 0.0) * lt.lead_time AS replenishment_demand_150d,
         CASE WHEN COALESCE(c.consumed_150d / 150.0, 0.0) > 0
           THEN (s.max_level - s.min_level) / (c.consumed_150d / 150.0) ELSE NULL END AS cycle_length_days_150d
  FROM stock s
    LEFT JOIN part_info pi ON pi.sto_part = s.sto_part
    LEFT JOIN site_building_type bt ON bt.site = s.site
    LEFT JOIN consumption c ON c.site = s.site AND c.sto_part = s.sto_part
    LEFT JOIN lead_time lt ON lt.site = s.site AND lt.part_ordered = s.sto_part
    LEFT JOIN site_oh_qty soh ON soh.site = s.site AND soh.sto_part = s.sto_part
    LEFT JOIN order_history oh ON oh.site = s.site AND oh.sto_part = s.sto_part
    LEFT JOIN coming_order_qty co ON co.site = s.site AND co.sto_part = s.sto_part
    LEFT JOIN nearest_open_order npo ON npo.site = s.site AND npo.sto_part = s.sto_part
)

SELECT
  CURRENT_DATE AS snapshot_date,
  m.site, m.region, m.sto_part AS part, m.amazon_pn, m.part_description, m.cat_ref_list,
  m.building_type, m.sto_class, m.site_oh_qty, m.min_level, m.max_level,
  m.supplier_lead_time, m.replenishment_time,

  -- Source: AR if in DWEEB, otherwise not AR
  CASE WHEN hx.part_no IS NOT NULL THEN 'AR' ELSE 'not AR' END AS source,

  -- Order history: prefer DWEEB for AR parts, fall back to r5
  COALESCE(hx.order_count, m.r5_order_count) AS order_count,
  COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) AS avg_rep_time_days,
  COALESCE(hx.min_rep_time_days, m.r5_min_rep_time_days) AS min_rep_time_days,
  COALESCE(hx.max_rep_time_days, m.r5_max_rep_time_days) AS max_rep_time_days,
  COALESCE(CAST(CAST(hx.last_shipment_date AS TIMESTAMP) AS DATE), m.r5_last_received_date) AS last_received_date,
  COALESCE(hx.last_30d_order, m.r5_last_30d_order) AS last_30d_order,
  COALESCE(hx.last_60d_order, m.r5_last_60d_order) AS last_60d_order,
  COALESCE(hx.last_90d_order, m.r5_last_90d_order) AS last_90d_order,
  COALESCE(hx.last_120d_order, m.r5_last_120d_order) AS last_120d_order,
  COALESCE(hx.last_150d_order, m.r5_last_150d_order) AS last_150d_order,
  COALESCE(hx.last_180d_order, m.r5_last_180d_order) AS last_180d_order,
  COALESCE(hx.last_365d_order, m.r5_last_365d_order) AS last_365d_order,

  -- Coming orders: prefer DWEEB for AR parts
  COALESCE(dco.co_open_order_count, m.r5_open_order_count) AS open_order_count,
  COALESCE(dco.co_back_order_qty, m.r5_back_order_qty) AS back_order_qty,
  m.nearest_po_number,

  -- Order inaction flag
  CASE WHEN COALESCE(m.site_oh_qty, 0.0) < m.min_level
        AND COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0) = 0
       THEN 1 ELSE 0 END AS order_inaction_flag,

  -- Trend ratio (uses order rates)
  ROUND(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0
    THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order)
    ELSE NULL END, 4) AS trend_ratio,

  -- 150d consumption metrics
  m.consumed_150d,
  ROUND(m.rate_150d, 4) AS consumption_rate_150d,
  ROUND(m.replenishment_demand_150d, 2) AS replenishment_demand_150d,
  ROUND(CASE WHEN m.replenishment_demand_150d > 0 THEN LEAST(1.0, m.min_level / m.replenishment_demand_150d) ELSE 1.0 END, 4) AS coverage_150d,
  ROUND(CASE WHEN m.replenishment_demand_150d > 0 THEN 1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d) ELSE 0.0 END, 4) AS stockout_fraction_150d,
  ROUND(CASE WHEN m.replenishment_demand_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_150d,
  ROUND(m.cycle_length_days_150d, 2) AS cycle_length_days_150d,
  ROUND(CASE WHEN m.cycle_length_days_150d > 0 THEN 365.0 / m.cycle_length_days_150d ELSE NULL END, 2) AS cycles_per_year_150d,
  ROUND(LEAST(365.0, CASE WHEN m.cycle_length_days_150d > 0 AND m.replenishment_demand_150d > 0 THEN (365.0 / m.cycle_length_days_150d) * ((1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time) ELSE 0.0 END), 2) AS stockout_days_yr_min_150d,

  -- Stockout days using actual avg rep time
  ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days), 0.0) * COALESCE(m.rate_150d, 0.0) > 0 AND m.cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / (COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * m.rate_150d))) * COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * (365.0 / m.cycle_length_days_150d) ELSE 0.0 END)), 2) AS stockout_days_min_rep_150d,

  -- Combined stockout days
  GREATEST(
    ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days), 0.0) * COALESCE(m.rate_150d, 0.0) > 0 AND m.cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / (COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * m.rate_150d))) * COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * (365.0 / m.cycle_length_days_150d) ELSE 0.0 END)), 2),
    ROUND(LEAST(365.0, CASE WHEN m.cycle_length_days_150d > 0 AND m.replenishment_demand_150d > 0 THEN (365.0 / m.cycle_length_days_150d) * ((1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time) ELSE 0.0 END), 2)
  ) AS combined_stockout_days_yr_150d,

  -- Structural risk combo criticality
  GREATEST(0.0, ROUND(CASE m.sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END *
    GREATEST(
      ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days), 0.0) * COALESCE(m.rate_150d, 0.0) > 0 AND m.cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / (COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * m.rate_150d))) * COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * (365.0 / m.cycle_length_days_150d) ELSE 0.0 END)), 2),
      ROUND(LEAST(365.0, CASE WHEN m.cycle_length_days_150d > 0 AND m.replenishment_demand_150d > 0 THEN (365.0 / m.cycle_length_days_150d) * ((1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time) ELSE 0.0 END), 2)
    ) / 365.0, 4)) AS structural_risk_combo_criticality_150d,

  -- Days of supply
  ROUND(CASE WHEN COALESCE(m.rate_150d, 0.0) > 0 THEN (COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / m.rate_150d ELSE NULL END, 2) AS days_of_supply_150d,

  -- Depletion date
  CASE WHEN COALESCE(m.rate_150d, 0.0) > 0 THEN date_add('day', CAST((COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / m.rate_150d AS INTEGER), CURRENT_DATE) ELSE NULL END AS depletion_date_150d,

  -- Projected order date
  CASE WHEN COALESCE(m.rate_150d, 0.0) > 0 AND m.supplier_lead_time IS NOT NULL THEN date_add('day', CAST((COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / m.rate_150d - m.supplier_lead_time AS INTEGER), CURRENT_DATE) ELSE NULL END AS projected_order_date_150d,

  -- Stockout days yr rep
  GREATEST(0.0, ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days), 0.0) * COALESCE(m.rate_150d, 0.0) > 0 AND m.cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / (COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * m.rate_150d))) * COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * (365.0 / m.cycle_length_days_150d) ELSE 0.0 END)), 2) - ROUND(LEAST(365.0, CASE WHEN m.cycle_length_days_150d > 0 AND m.replenishment_demand_150d > 0 THEN (365.0 / m.cycle_length_days_150d) * ((1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time) ELSE 0.0 END), 2)) AS stockout_days_yr_rep_150d,

  -- Adj days of supply
  ROUND(CASE WHEN COALESCE(m.rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)) > 0
    THEN (COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / (m.rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)))
    ELSE NULL END, 2) AS adj_days_of_supply_150d,

  -- Situational score
  ROUND(CASE WHEN m.supplier_lead_time > 0 AND COALESCE(m.rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)) > 0
    THEN (m.supplier_lead_time - (COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / (m.rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)))) / m.supplier_lead_time
    ELSE NULL END, 4) AS situational_score_150d,

  -- Situational score criticality
  GREATEST(0.0, ROUND(CASE m.sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END *
    CASE WHEN m.supplier_lead_time > 0 AND COALESCE(m.rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)) > 0
      THEN (m.supplier_lead_time - (COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / (m.rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)))) / m.supplier_lead_time
      ELSE NULL END, 4)) AS situational_score_criticality_150d,

  -- Overall score criticality = situational + structural
  GREATEST(0.0, ROUND(
    COALESCE(CASE m.sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END *
      CASE WHEN m.supplier_lead_time > 0 AND COALESCE(m.rate_150d, 0.0) * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)) > 0
        THEN (m.supplier_lead_time - (COALESCE(COALESCE(dco.co_back_order_qty, m.r5_back_order_qty), 0.0) + COALESCE(m.site_oh_qty, 0.0)) / (m.rate_150d * (1.0 + COALESCE(CASE WHEN COALESCE(COALESCE(hx.last_150d_order, m.r5_last_150d_order), 0.0) > 0 THEN (COALESCE(COALESCE(hx.last_30d_order, m.r5_last_30d_order), 0.0) - COALESCE(hx.last_150d_order, m.r5_last_150d_order)) / COALESCE(hx.last_150d_order, m.r5_last_150d_order) ELSE 0.0 END, 0.0)))) / m.supplier_lead_time
        ELSE NULL END, 0.0)
    + COALESCE(CASE m.sto_class WHEN '01 HIGH' THEN 1.0 WHEN '02 MED' THEN 0.75 WHEN '03 LOW' THEN 0.5 ELSE 0.25 END *
      GREATEST(
        ROUND(LEAST(365.0, GREATEST(0.0, CASE WHEN COALESCE(COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days), 0.0) * COALESCE(m.rate_150d, 0.0) > 0 AND m.cycle_length_days_150d > 0 THEN (1.0 - LEAST(1.0, m.min_level / (COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * m.rate_150d))) * COALESCE(hx.avg_rep_time_days, m.r5_avg_rep_time_days) * (365.0 / m.cycle_length_days_150d) ELSE 0.0 END)), 2),
        ROUND(LEAST(365.0, CASE WHEN m.cycle_length_days_150d > 0 AND m.replenishment_demand_150d > 0 THEN (365.0 / m.cycle_length_days_150d) * ((1.0 - LEAST(1.0, m.min_level / m.replenishment_demand_150d)) * m.replenishment_time) ELSE 0.0 END), 2)
      ) / 365.0, 0.0)
  , 4)) AS overall_score_criticality_150d,


  -- Facility attributes
  fac.region AS ar_region,
  fac.subregion,
  fac.type,
  fac.subtype

FROM metrics m
  LEFT JOIN dweeb_hx hx ON hx.site = m.site AND hx.part_no = m.part_number
  LEFT JOIN dweeb_co dco ON dco.site = m.site AND dco.part_no = m.part_number
  LEFT JOIN "andes"."ar-performance-n-insights.rts_rcc_facilities" fac ON fac.code = m.site
WHERE m.sto_class IN ('01 HIGH', '02 MED', '03 LOW')
