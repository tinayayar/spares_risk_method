-- Daily Flash Report: Stock health queries for RSPL target parts
-- Athena syntax
-- Part descriptions from r5catalogue (cat_desc)

-- Query 0: APNs on the target list with min AND max level as NULL in r5stock
WITH target_parts_0 AS (
  SELECT DISTINCT apn AS sto_part, product
  FROM "default"."rspl_target_parts"
  WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c
  GROUP BY cat_part
),
stock_null_minmax AS (
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         sto_minlev, sto_maxqty, CAST(sto_qty AS DOUBLE) AS sto_qty, 'NA' AS region
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_part IN (SELECT sto_part FROM target_parts_0)
    AND sto_minlev IS NULL AND sto_maxqty IS NULL
  UNION ALL
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         sto_minlev, sto_maxqty, CAST(sto_qty AS DOUBLE) AS sto_qty, 'EU' AS region
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_part IN (SELECT sto_part FROM target_parts_0)
    AND sto_minlev IS NULL AND sto_maxqty IS NULL
)
SELECT s.site, s.region, s.sto_part AS apn, t.product, d.part_description,
       MAX(s.sto_class) AS sto_class, MAX(s.sto_qty) AS sto_qty,
       'NULL_MIN_MAX' AS flag
FROM stock_null_minmax s
  LEFT JOIN target_parts_0 t ON t.sto_part = s.sto_part
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
GROUP BY s.site, s.region, s.sto_part, t.product, d.part_description
ORDER BY s.site, s.sto_part;


-- Query 0b: APNs on the target list with sto_qty IS NULL in r5stock (never received)
WITH target_parts_0b AS (
  SELECT DISTINCT apn AS sto_part, product
  FROM "default"."rspl_target_parts"
  WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),
stock_null_qty AS (
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
         sto_qty, 'NA' AS region
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_part IN (SELECT sto_part FROM target_parts_0b) AND sto_qty IS NULL
  UNION ALL
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
         sto_qty, 'EU' AS region
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_part IN (SELECT sto_part FROM target_parts_0b) AND sto_qty IS NULL
)
SELECT s.site, s.region, s.sto_part AS apn, t.product, d.part_description,
       MAX(s.sto_class) AS sto_class, MAX(s.sto_qty) AS sto_qty,
       MAX(s.min_level) AS min_level, MAX(s.max_level) AS max_level,
       'NULL_QTY_IN_STOCK' AS flag
FROM stock_null_qty s
  LEFT JOIN target_parts_0b t ON t.sto_part = s.sto_part
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
GROUP BY s.site, s.region, s.sto_part, t.product, d.part_description
ORDER BY s.site, s.sto_part;


-- Query 1: All APNs with on-hand quantity = 0
WITH target_parts AS (
  SELECT DISTINCT apn AS sto_part FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),
product_lookup AS (
  SELECT DISTINCT apn, product FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
stock_oh_zero AS (
  SELECT site, sto_part, MAX(sto_class) AS sto_class,
         MAX(min_level) AS min_level, MAX(max_level) AS max_level, MAX(site_oh_qty) AS site_oh_qty, region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_parts)
  ) raw
  GROUP BY site, sto_part, region
  HAVING MAX(site_oh_qty) = 0
)
SELECT s.site, s.region, s.sto_part AS apn, p.product, d.part_description,
       s.sto_class, s.site_oh_qty, s.min_level, s.max_level, 'OH_ZERO' AS flag
FROM stock_oh_zero s
  LEFT JOIN product_lookup p ON p.apn = s.sto_part
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
ORDER BY s.site, s.sto_part;


-- Query 2: All APNs with on-hand < min AND no active requisitions
WITH target_parts AS (
  SELECT DISTINCT apn AS sto_part FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),
product_lookup AS (
  SELECT DISTINCT apn, product FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
stock_below_min AS (
  SELECT site, sto_part, MAX(sto_class) AS sto_class,
         MAX(min_level) AS min_level, MAX(max_level) AS max_level, MAX(site_oh_qty) AS site_oh_qty, region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_parts)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_parts)
  ) raw
  GROUP BY site, sto_part, region
  HAVING MAX(site_oh_qty) < MAX(min_level)
),
active_reqs AS (
  SELECT rl.rql_part AS part, rh.req_org AS site,
         COUNT(DISTINCT trim(cast(rl.rql_req AS varchar))) AS active_req_count,
         SUM(CAST(rl.rql_qty AS DOUBLE)) AS active_req_qty,
         MIN(CAST(rh.req_date AS DATE)) AS earliest_req_date
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_parts)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  GROUP BY rl.rql_part, rh.req_org
  UNION ALL
  SELECT rl.rql_part AS part, rh.req_org AS site,
         COUNT(DISTINCT trim(cast(rl.rql_req AS varchar))) AS active_req_count,
         SUM(CAST(rl.rql_qty AS DOUBLE)) AS active_req_qty,
         MIN(CAST(rh.req_date AS DATE)) AS earliest_req_date
  FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT sto_part FROM target_parts)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  GROUP BY rl.rql_part, rh.req_org
)
SELECT s.site, s.region, s.sto_part AS apn, p.product, d.part_description, s.sto_class,
       s.site_oh_qty, s.min_level, s.max_level,
       COALESCE(r.active_req_count, 0) AS active_req_count,
       COALESCE(r.active_req_qty, 0) AS active_req_qty,
       r.earliest_req_date, 'OH_BELOW_MIN' AS flag
FROM stock_below_min s
  LEFT JOIN product_lookup p ON p.apn = s.sto_part
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
  LEFT JOIN active_reqs r ON r.part = s.sto_part AND r.site = s.site
WHERE COALESCE(r.active_req_count, 0) = 0
ORDER BY s.site, s.sto_part;


-- Query 3: % of spare parts physically received out of total RSPL-ordered quantities
WITH target_parts_3 AS (
  SELECT DISTINCT apn AS sto_part, product FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),
order_fill AS (
  SELECT rl.ord_org AS site, l.orl_part AS apn,
         CAST(l.orl_ordqty AS DOUBLE) AS qty_ordered, CAST(l.orl_recvqty AS DOUBLE) AS qty_received, 'NA' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
      ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts_3)
  UNION ALL
  SELECT rl.ord_org AS site, l.orl_part AS apn,
         CAST(l.orl_ordqty AS DOUBLE) AS qty_ordered, CAST(l.orl_recvqty AS DOUBLE) AS qty_received, 'EU' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
      ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT sto_part FROM target_parts_3)
),
per_part AS (
  SELECT site, region, apn,
         SUM(qty_ordered) AS total_ordered, SUM(qty_received) AS total_received,
         ROUND(100.0 * SUM(qty_received) / NULLIF(SUM(qty_ordered), 0), 2) AS pct_received
  FROM order_fill GROUP BY site, region, apn
)
SELECT p.site, p.region, p.apn, t.product, d.part_description,
       p.total_ordered, p.total_received, p.pct_received,
       SUM(p.total_ordered) OVER (PARTITION BY p.site) AS site_total_ordered,
       SUM(p.total_received) OVER (PARTITION BY p.site) AS site_total_received,
       ROUND(100.0 * SUM(p.total_received) OVER (PARTITION BY p.site) / NULLIF(SUM(p.total_ordered) OVER (PARTITION BY p.site), 0), 2) AS site_pct_received
FROM per_part p
  LEFT JOIN target_parts_3 t ON t.sto_part = p.apn
  LEFT JOIN part_desc d ON d.cat_part = p.apn
ORDER BY p.site, p.apn;


-- Query 4: Target parts with latest open purchase requisition > 1 week old
WITH target_parts_4 AS (
  SELECT DISTINCT apn AS sto_part, product FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
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
  WHERE rl.rql_part IN (SELECT sto_part FROM target_parts_4)
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
  WHERE rl.rql_part IN (SELECT sto_part FROM target_parts_4)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
)
SELECT o.site, o.region, o.apn, t.product, d.part_description,
       o.req_number, o.req_qty, o.req_date, o.days_open
FROM open_reqs_ranked o
  LEFT JOIN target_parts_4 t ON t.sto_part = o.apn
  LEFT JOIN part_desc d ON d.cat_part = o.apn
WHERE o.rn = 1 AND o.days_open > 7
ORDER BY o.days_open DESC, o.site, o.apn;


-- Query 5: Replacement rate for target parts
WITH target_parts_5 AS (
  SELECT DISTINCT apn AS sto_part, product FROM "default"."rspl_target_parts" WHERE apn IS NOT NULL
),
part_desc AS (
  SELECT cat_part, MAX(cat_desc) AS part_description
  FROM (
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
  ) c GROUP BY cat_part
),
consumption_data AS (
  SELECT site, region, apn, DATE(trl_date) AS consumption_date,
         CAST(est_total_consumption AS DOUBLE) AS qty_consumed
  FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption"
  WHERE apn IN (SELECT sto_part FROM target_parts_5)
)
SELECT c.site, c.region, c.apn, t.product, d.part_description,
  SUM(CASE WHEN c.consumption_date >= date_add('day', -30, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) AS consumed_30d,
  SUM(CASE WHEN c.consumption_date >= date_add('day', -60, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) AS consumed_60d,
  SUM(CASE WHEN c.consumption_date >= date_add('day', -90, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) AS consumed_90d,
  SUM(CASE WHEN c.consumption_date >= date_add('day', -150, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) AS consumed_150d,
  SUM(c.qty_consumed) AS consumed_all,
  ROUND(SUM(CASE WHEN c.consumption_date >= date_add('day', -30, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) / 30.0, 4) AS rate_30d,
  ROUND(SUM(CASE WHEN c.consumption_date >= date_add('day', -60, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) / 60.0, 4) AS rate_60d,
  ROUND(SUM(CASE WHEN c.consumption_date >= date_add('day', -90, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) / 90.0, 4) AS rate_90d,
  ROUND(SUM(CASE WHEN c.consumption_date >= date_add('day', -150, CURRENT_DATE) THEN c.qty_consumed ELSE 0 END) / 150.0, 4) AS rate_150d,
  COUNT(CASE WHEN c.consumption_date >= date_add('day', -150, CURRENT_DATE) AND c.qty_consumed > 0 THEN 1 END) AS days_with_consumption_150d
FROM consumption_data c
  LEFT JOIN target_parts_5 t ON t.sto_part = c.apn
  LEFT JOIN part_desc d ON d.cat_part = c.apn
GROUP BY c.site, c.region, c.apn, t.product, d.part_description
HAVING SUM(c.qty_consumed) > 0
ORDER BY c.site, c.apn
