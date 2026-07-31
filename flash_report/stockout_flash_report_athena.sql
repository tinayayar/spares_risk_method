-- stockout_flash_report_athena.sql
-- Combined Andes table for daily flash report dashboard
-- Combines Query 6 (zero OH) and Query 7 (below min no PR) into one output
-- Athena variant — bare table names, parameterized dates

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

Final AS (
SELECT
  CURRENT_DATE AS snapshot_date,
  s.site,
  s.region,
  s.sto_part AS apn,
  tps.product,
  d.part_description,
  s.sto_class,
  s.site_oh_qty,
  s.min_level,
  s.max_level,
  -- Zero OH flag
  CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END AS is_zero_oh,
  -- Below min flag
  CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level THEN 1 ELSE 0 END AS is_below_min,
  -- Below min without active PR flag
  CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END AS is_below_min_no_pr,
  -- Has active PR flag
  CASE WHEN ar.part IS NOT NULL THEN 1 ELSE 0 END AS has_active_pr,
  -- Site-level by product: zero OH
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY s.site, tps.product) AS site_product_zero_oh_count,
  COUNT(*) OVER (PARTITION BY s.site, tps.product) AS site_product_total_high,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY s.site, tps.product) / COUNT(*) OVER (PARTITION BY s.site, tps.product), 2) AS site_product_pct_zero_oh,
  -- Site-level by product: below min no PR
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY s.site, tps.product) AS site_product_below_min_no_pr_count,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY s.site, tps.product) / COUNT(*) OVER (PARTITION BY s.site, tps.product), 2) AS site_product_pct_below_min_no_pr,
  -- Network-level by product: zero OH
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_zero_oh_count,
  COUNT(*) OVER (PARTITION BY tps.product) AS network_product_total_high,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) / COUNT(*) OVER (PARTITION BY tps.product), 2) AS network_product_pct_zero_oh,
  -- Network-level by product: below min no PR
  SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) AS network_product_below_min_no_pr_count,
  ROUND(100.0 * SUM(CASE WHEN COALESCE(s.site_oh_qty, 0) < s.min_level AND ar.part IS NULL THEN 1 ELSE 0 END) OVER (PARTITION BY tps.product) / COUNT(*) OVER (PARTITION BY tps.product), 2) AS network_product_pct_below_min_no_pr,
  -- Order fill: % received per part
  COALESCE(of.total_ordered, 0) AS total_ordered,
  COALESCE(of.total_received, 0) AS total_received,
  of.pct_received,
  -- Site-level order fill rate
  ROUND(100.0 * SUM(COALESCE(of.total_received, 0)) OVER (PARTITION BY s.site, tps.product) / NULLIF(SUM(COALESCE(of.total_ordered, 0)) OVER (PARTITION BY s.site, tps.product), 0), 2) AS site_product_pct_received,
  -- Network-level order fill rate
  ROUND(100.0 * SUM(COALESCE(of.total_received, 0)) OVER (PARTITION BY tps.product) / NULLIF(SUM(COALESCE(of.total_ordered, 0)) OVER (PARTITION BY tps.product), 0), 2) AS network_product_pct_received
FROM stock_high_class s
  INNER JOIN target_part_sites tps ON tps.sto_part = s.sto_part AND tps.site = s.site
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
  LEFT JOIN active_reqs ar ON ar.part = s.sto_part AND ar.site = s.site
  LEFT JOIN order_fill of ON of.apn = s.sto_part AND of.site = s.site
ORDER BY s.site, tps.product, s.sto_part
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
CAST(network_product_pct_received AS DECIMAL(10,2)) AS network_product_pct_received
FROM Final;
