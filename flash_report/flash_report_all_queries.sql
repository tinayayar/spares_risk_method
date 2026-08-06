-- =============================================================================
-- flash_report_all_queries.sql
-- All datasource queries for the Critical Spares Flash Report
-- Run each query separately in Athena to produce its CSV output.
-- Base CTEs (target_part_sites, part_desc, stock_high_class) are identical
-- across all queries.
--
-- Output mapping:
--   Query 1 → tab1_2_6_datasource.csv  (Zero OH, Below Min No PR, Order Fill)
--   Query 2 → tab3_datasource.csv      (Open PRs > 1 week)
--   Query 3 → tab4_5_datasource.csv    (Replacement rates + Expected vs Actual)
--   tab7_datasource.csv is from external RSC export (not generated here)
-- =============================================================================


-- =============================================================================
-- QUERY 1: tab1_2_6_datasource.csv
-- Zero OH %, Below Min No PR %, Order Fill Rate
-- =============================================================================
WITH target_part_sites AS (
  SELECT DISTINCT t.apn AS sto_part, t.product, s.site
  FROM "default"."rspl_target_parts" t
  INNER JOIN (
    SELECT DISTINCT warehouse_id AS site, 'URL' AS equipment FROM "andes"."am_dps_public.url_machine_daily"
    UNION ALL
    SELECT DISTINCT site, 'USP' AS equipment FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption" WHERE equipment IN ('USP')
    UNION ALL
    SELECT DISTINCT warehouse_id AS site, 'EcoPac' AS equipment FROM "andes"."am_dps_public.ecopac_machine_daily"
  ) s ON LOWER(t.product) = LOWER(s.equipment)
  WHERE t.apn IS NOT NULL
),

part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),

stock_high_class AS (
  SELECT site, sto_part,
         MAX(site_oh_qty) AS site_oh_qty,
         MAX(min_level) AS min_level,
         MAX(max_level) AS max_level,
         MAX(sto_class) AS sto_class,
         region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
  ) raw
  GROUP BY site, sto_part, region
),

active_reqs AS (
  SELECT rl.rql_part AS part, rh.req_org AS site
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  UNION
  SELECT rl.rql_part AS part, rh.req_org AS site
  FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
),

order_fill AS (
  SELECT site, apn,
         SUM(qty_ordered) AS total_ordered,
         SUM(qty_received) AS total_received,
         ROUND(100.0 * SUM(qty_received) / NULLIF(SUM(qty_ordered), 0), 2) AS pct_received
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS apn,
           CAST(l.orl_ordqty AS DOUBLE) AS qty_ordered,
           CAST(l.orl_recvqty AS DOUBLE) AS qty_received
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT sto_part FROM target_part_sites)
      AND rl.ord_org IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS apn,
           CAST(l.orl_ordqty AS DOUBLE) AS qty_ordered,
           CAST(l.orl_recvqty AS DOUBLE) AS qty_received
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT sto_part FROM target_part_sites)
      AND rl.ord_org IN (SELECT site FROM target_part_sites)
  ) orders
  GROUP BY site, apn
),

q1_final AS (
SELECT
  CURRENT_DATE AS snapshot_date,
  tps.site,
  s.region,
  tps.sto_part AS apn,
  tps.product,
  d.part_description,
  s.sto_class,
  s.site_oh_qty,
  s.min_level,
  s.max_level,
  CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END AS is_zero_oh,
  CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level THEN 1 ELSE 0 END AS is_below_min,
  CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END AS is_below_min_no_pr,
  CASE WHEN ar.part IS NOT NULL THEN 1 ELSE 0 END AS has_active_pr,
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) AS site_product_zero_oh_count,
  COUNT(*) OVER (PARTITION BY tps.site, tps.product) AS site_product_total_high,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) / COUNT(*) OVER (PARTITION BY tps.site, tps.product), 2) AS site_product_pct_zero_oh,
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) AS site_product_below_min_no_pr_count,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) / COUNT(*) OVER (PARTITION BY tps.site, tps.product), 2) AS site_product_pct_below_min_no_pr,
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_zero_oh_count,
  COUNT(*) OVER (PARTITION BY tps.product) AS network_product_total_high,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) / COUNT(*) OVER (PARTITION BY tps.product), 2) AS network_product_pct_zero_oh,
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_below_min_no_pr_count,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) / COUNT(*) OVER (PARTITION BY tps.product), 2) AS network_product_pct_below_min_no_pr,
  COALESCE(of.total_ordered, 0) AS total_ordered,
  COALESCE(of.total_received, 0) AS total_received,
  of.pct_received,
  ROUND(100.0 * SUM(COALESCE(of.total_received, 0)) OVER (PARTITION BY tps.site, tps.product) / NULLIF(SUM(COALESCE(of.total_ordered, 0)) OVER (PARTITION BY tps.site, tps.product), 0), 2) AS site_product_pct_received,
  ROUND(100.0 * SUM(COALESCE(of.total_received, 0)) OVER (PARTITION BY tps.product) / NULLIF(SUM(COALESCE(of.total_ordered, 0)) OVER (PARTITION BY tps.product), 0), 2) AS network_product_pct_received,
  -- Criticality 1 part counts
  SUM(CASE WHEN s.sto_class = '01 HIGH' THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) AS site_product_total_critical1,
  SUM(CASE WHEN s.sto_class = '01 HIGH' THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_total_critical1
FROM target_part_sites tps
  LEFT JOIN stock_high_class s ON s.sto_part = tps.sto_part AND s.site = tps.site
  LEFT JOIN part_desc d ON d.cat_part = tps.sto_part
  LEFT JOIN active_reqs ar ON ar.part = tps.sto_part AND ar.site = tps.site
  LEFT JOIN order_fill of ON of.apn = tps.sto_part AND of.site = tps.site
ORDER BY tps.site, tps.product, tps.sto_part
)

SELECT
  CAST(snapshot_date AS TIMESTAMP) AS snapshot_date,
  CAST(site AS VARCHAR(10)) AS site,
  CAST(region AS VARCHAR(10)) AS region,
  CAST(apn AS VARCHAR(50)) AS apn,
  CAST(product AS VARCHAR(20)) AS product,
  CAST(part_description AS VARCHAR(500)) AS part_description,
  CAST(sto_class AS VARCHAR(10)) AS sto_class,
  CAST(site_oh_qty AS INT) AS site_oh_qty,
  CAST(min_level AS INT) AS min_level,
  CAST(max_level AS INT) AS max_level,
  CAST(is_zero_oh AS INT) AS is_zero_oh,
  CAST(is_below_min AS INT) AS is_below_min,
  CAST(is_below_min_no_pr AS INT) AS is_below_min_no_pr,
  CAST(has_active_pr AS INT) AS has_active_pr,
  CAST(site_product_zero_oh_count AS INT) AS site_product_zero_oh_count,
  CAST(site_product_total_high AS INT) AS site_product_total_high,
  CAST(site_product_pct_zero_oh AS DECIMAL(10,2)) AS site_product_pct_zero_oh,
  CAST(site_product_below_min_no_pr_count AS INT) AS site_product_below_min_no_pr_count,
  CAST(site_product_pct_below_min_no_pr AS DECIMAL(10,2)) AS site_product_pct_below_min_no_pr,
  CAST(network_product_zero_oh_count AS INT) AS network_product_zero_oh_count,
  CAST(network_product_total_high AS INT) AS network_product_total_high,
  CAST(network_product_pct_zero_oh AS DECIMAL(10,2)) AS network_product_pct_zero_oh,
  CAST(network_product_below_min_no_pr_count AS INT) AS network_product_below_min_no_pr_count,
  CAST(network_product_pct_below_min_no_pr AS DECIMAL(10,2)) AS network_product_pct_below_min_no_pr,
  CAST(total_ordered AS INT) AS total_ordered,
  CAST(total_received AS INT) AS total_received,
  CAST(pct_received AS DECIMAL(10,2)) AS pct_received,
  CAST(site_product_pct_received AS DECIMAL(10,2)) AS site_product_pct_received,
  CAST(network_product_pct_received AS DECIMAL(10,2)) AS network_product_pct_received,
  CAST(site_product_total_critical1 AS INT) AS site_product_total_critical1,
  CAST(network_product_total_critical1 AS INT) AS network_product_total_critical1
FROM q1_final;


-- =============================================================================
-- QUERY 2: tab3_datasource.csv
-- Open Purchase Requisitions > 1 week old
-- =============================================================================
WITH target_part_sites AS (
  SELECT DISTINCT t.apn AS sto_part, t.product, s.site
  FROM "default"."rspl_target_parts" t
  INNER JOIN (
    SELECT DISTINCT warehouse_id AS site, 'URL' AS equipment FROM "andes"."am_dps_public.url_machine_daily"
    UNION ALL
    SELECT DISTINCT site, 'USP' AS equipment FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption" WHERE equipment IN ('USP')
    UNION ALL
    SELECT DISTINCT warehouse_id AS site, 'EcoPac' AS equipment FROM "andes"."am_dps_public.ecopac_machine_daily"
  ) s ON LOWER(t.product) = LOWER(s.equipment)
  WHERE t.apn IS NOT NULL
),

part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),

stock_high_class AS (
  SELECT site, sto_part,
         MAX(site_oh_qty) AS site_oh_qty,
         MAX(min_level) AS min_level,
         MAX(max_level) AS max_level,
         MAX(sto_class) AS sto_class,
         MAX(region) AS region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
  ) raw
  GROUP BY site, sto_part
),

open_reqs_ranked AS (
  SELECT rl.rql_part AS apn, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number, CAST(rl.rql_qty AS DOUBLE) AS req_qty,
         CAST(rh.req_date AS DATE) AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open, 'NA' AS region,
         ROW_NUMBER() OVER (PARTITION BY rh.req_org, rl.rql_part ORDER BY rh.req_date DESC) AS rn
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
    AND rh.req_org IN (SELECT site FROM target_part_sites)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  UNION ALL
  SELECT rl.rql_part AS apn, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number, CAST(rl.rql_qty AS DOUBLE) AS req_qty,
         CAST(rh.req_date AS DATE) AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open, 'EU' AS region,
         ROW_NUMBER() OVER (PARTITION BY rh.req_org, rl.rql_part ORDER BY rh.req_date DESC) AS rn
  FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
    AND rh.req_org IN (SELECT site FROM target_part_sites)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
)

SELECT o.site, o.region, o.apn, tps.product, d.part_description, sc.sto_class,
       o.req_number, o.req_qty, o.req_date, o.days_open
FROM open_reqs_ranked o
  INNER JOIN target_part_sites tps ON tps.sto_part = o.apn AND tps.site = o.site
  LEFT JOIN part_desc d ON d.cat_part = o.apn
  LEFT JOIN stock_high_class sc ON sc.sto_part = o.apn AND sc.site = o.site
WHERE o.rn = 1 AND o.days_open > 7
ORDER BY o.days_open DESC, o.site, o.apn;


-- =============================================================================
-- QUERY 3: tab4_5_datasource.csv
-- Combined: Replacement rates (30/60/90/150d) + Expected vs Actual failure rate
-- Starts from target_part_sites (full RSPL denominator)
-- Used by Tab 4 (Top 10 replacement — filter to sto_class = '01 HIGH' in Python)
-- and Tab 5 (Expected vs Actual failure rate)
-- =============================================================================
WITH target_part_sites AS (
  SELECT DISTINCT t.apn AS sto_part, t.product, s.site
  FROM "default"."rspl_target_parts" t
  INNER JOIN (
    SELECT DISTINCT warehouse_id AS site, 'URL' AS equipment FROM "andes"."am_dps_public.url_machine_daily"
    UNION ALL
    SELECT DISTINCT site, 'USP' AS equipment FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption" WHERE equipment IN ('USP')
    UNION ALL
    SELECT DISTINCT warehouse_id AS site, 'EcoPac' AS equipment FROM "andes"."am_dps_public.ecopac_machine_daily"
  ) s ON LOWER(t.product) = LOWER(s.equipment)
  WHERE t.apn IS NOT NULL
),

part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),

stock_high_class AS (
  SELECT site, sto_part,
         MAX(site_oh_qty) AS site_oh_qty,
         MAX(min_level) AS min_level,
         MAX(max_level) AS max_level,
         MAX(sto_class) AS sto_class,
         region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
  ) raw
  GROUP BY site, sto_part, region
),

lead_time AS (
  SELECT site, part_ordered, region,
         APPROX_PERCENTILE(supplier_lead_time, 0.5) AS supplier_lead_time
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
           CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time, 'NA' AS region
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_na"
        ON cat_part = l.orl_part AND cat_supplier = l.orl_supplier
    WHERE l.orl_part IN (SELECT sto_part FROM target_part_sites)
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
           CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time, 'EU' AS region
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
      LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_eu"
        ON cat_part = l.orl_part AND cat_supplier = l.orl_supplier
  ) olt
  WHERE supplier_lead_time IS NOT NULL
  GROUP BY site, part_ordered, region
),

consumption_data AS (
  SELECT site, apn, DATE(trl_date) AS consumption_date,
         CAST(est_total_consumption AS DOUBLE) AS qty_consumed
  FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption"
  WHERE apn IN (SELECT sto_part FROM target_part_sites)
    AND site IN (SELECT site FROM target_part_sites)
),

consumption_agg AS (
  SELECT site, apn,
    SUM(CASE WHEN consumption_date >= date_add('day', -30, CURRENT_DATE) THEN qty_consumed ELSE 0 END) AS consumed_30d,
    SUM(CASE WHEN consumption_date >= date_add('day', -60, CURRENT_DATE) THEN qty_consumed ELSE 0 END) AS consumed_60d,
    SUM(CASE WHEN consumption_date >= date_add('day', -90, CURRENT_DATE) THEN qty_consumed ELSE 0 END) AS consumed_90d,
    SUM(CASE WHEN consumption_date >= date_add('day', -150, CURRENT_DATE) THEN qty_consumed ELSE 0 END) AS consumed_150d,
    SUM(CASE WHEN consumption_date >= date_add('day', -180, CURRENT_DATE) THEN qty_consumed ELSE 0 END) AS consumed_180d,
    SUM(qty_consumed) AS consumed_all,
    ROUND(SUM(CASE WHEN consumption_date >= date_add('day', -30, CURRENT_DATE) THEN qty_consumed ELSE 0 END) / 30.0, 4) AS rate_30d,
    ROUND(SUM(CASE WHEN consumption_date >= date_add('day', -60, CURRENT_DATE) THEN qty_consumed ELSE 0 END) / 60.0, 4) AS rate_60d,
    ROUND(SUM(CASE WHEN consumption_date >= date_add('day', -90, CURRENT_DATE) THEN qty_consumed ELSE 0 END) / 90.0, 4) AS rate_90d,
    ROUND(SUM(CASE WHEN consumption_date >= date_add('day', -150, CURRENT_DATE) THEN qty_consumed ELSE 0 END) / 150.0, 4) AS rate_150d,
    ROUND(SUM(CASE WHEN consumption_date >= date_add('day', -180, CURRENT_DATE) THEN qty_consumed ELSE 0 END) / 180.0, 4) AS actual_daily_rate,
    COUNT(CASE WHEN consumption_date >= date_add('day', -150, CURRENT_DATE) AND qty_consumed > 0 THEN 1 END) AS days_with_consumption_150d
  FROM consumption_data
  GROUP BY site, apn
)

SELECT
  tps.site,
  sc.region,
  tps.sto_part AS apn,
  tps.product,
  d.part_description,
  sc.sto_class,
  sc.min_level,
  lt.supplier_lead_time,
  -- Consumption rates
  ca.consumed_30d,
  ca.consumed_60d,
  ca.consumed_90d,
  ca.consumed_150d,
  ca.consumed_180d,
  ca.consumed_all,
  ca.rate_30d,
  ca.rate_60d,
  ca.rate_90d,
  ca.rate_150d,
  ca.actual_daily_rate,
  ca.days_with_consumption_150d,
  -- Expected vs Actual
  ROUND(CASE WHEN COALESCE(lt.supplier_lead_time, 0) > 0 AND COALESCE(sc.min_level, 0) > 0
    THEN sc.min_level / lt.supplier_lead_time ELSE NULL END, 4) AS expected_daily_rate,
  ROUND(CASE WHEN COALESCE(sc.min_level, 0) > 0 AND COALESCE(lt.supplier_lead_time, 0) > 0
    THEN ca.actual_daily_rate / (sc.min_level / lt.supplier_lead_time)
    ELSE NULL END, 4) AS actual_vs_expected_ratio,
  -- Flags and pre-computed totals
  CASE WHEN sc.min_level IS NOT NULL AND lt.supplier_lead_time IS NOT NULL THEN 1 ELSE 0 END AS has_min_and_lt,
  COUNT(*) OVER (PARTITION BY tps.site, tps.product) AS site_product_total_parts,
  SUM(CASE WHEN sc.min_level IS NOT NULL AND lt.supplier_lead_time IS NOT NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.site, tps.product) AS site_product_parts_with_min_lt,
  COUNT(*) OVER (PARTITION BY tps.product) AS network_product_total_parts,
  SUM(CASE WHEN sc.min_level IS NOT NULL AND lt.supplier_lead_time IS NOT NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_parts_with_min_lt
FROM target_part_sites tps
  LEFT JOIN stock_high_class sc ON sc.sto_part = tps.sto_part AND sc.site = tps.site
  LEFT JOIN part_desc d ON d.cat_part = tps.sto_part
  LEFT JOIN lead_time lt ON lt.site = tps.site AND lt.part_ordered = tps.sto_part AND lt.region = sc.region
  LEFT JOIN consumption_agg ca ON ca.site = tps.site AND ca.apn = tps.sto_part
ORDER BY actual_vs_expected_ratio DESC NULLS LAST, tps.site, tps.sto_part;
