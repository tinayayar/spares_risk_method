-- Daily Flash Report: Stock health queries for RSPL target parts
-- Athena syntax
-- Target parts filtered to sites with matching equipment (USP/URL/Ecopac)
-- Part descriptions from r5catalogue (cat_desc)
-- Uses LOWER() for case-insensitive product/equipment matching

-- Query 0: APNs on the target list with min AND max level as NULL in r5stock
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
stock_null_minmax AS (
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         sto_minlev, sto_maxqty, CAST(sto_qty AS DOUBLE) AS sto_qty, 'NA' AS region
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    AND sto_minlev IS NULL AND sto_maxqty IS NULL
  UNION ALL
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         sto_minlev, sto_maxqty, CAST(sto_qty AS DOUBLE) AS sto_qty, 'EU' AS region
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    AND sto_minlev IS NULL AND sto_maxqty IS NULL
)
SELECT s.site, s.region, s.sto_part AS apn, tps.product, d.part_description,
       MAX(s.sto_class) AS sto_class, MAX(s.sto_minlev) AS min_level, MAX(s.sto_maxqty) AS max_level,
       'NULL_MIN_MAX' AS flag
FROM stock_null_minmax s
  INNER JOIN target_part_sites tps ON tps.sto_part = s.sto_part AND tps.site = s.site
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
GROUP BY s.site, s.region, s.sto_part, tps.product, d.part_description
ORDER BY s.site, s.sto_part;


-- Query 0b: APNs on the target list with sto_qty IS NULL in r5stock (never received)
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
stock_null_qty AS (
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
         sto_qty, 'NA' AS region
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    AND sto_qty IS NULL
  UNION ALL
  SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
         CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
         sto_qty, 'EU' AS region
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    AND sto_qty IS NULL
)
SELECT s.site, s.region, s.sto_part AS apn, tps.product, d.part_description,
       MAX(s.sto_class) AS sto_class, MAX(s.sto_qty) AS sto_qty,
       MAX(s.min_level) AS min_level, MAX(s.max_level) AS max_level,
       'NULL_QTY_IN_STOCK' AS flag
FROM stock_null_qty s
  INNER JOIN target_part_sites tps ON tps.sto_part = s.sto_part AND tps.site = s.site
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
GROUP BY s.site, s.region, s.sto_part, tps.product, d.part_description
ORDER BY s.site, s.sto_part;


-- Query 1: All APNs with on-hand quantity = 0
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
stock_oh_zero AS (
  SELECT site, sto_part, MAX(sto_class) AS sto_class,
         MAX(min_level) AS min_level, MAX(max_level) AS max_level, MAX(site_oh_qty) AS site_oh_qty, region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
  ) raw
  GROUP BY site, sto_part, region
  HAVING MAX(site_oh_qty) = 0
)
SELECT s.site, s.region, s.sto_part AS apn, tps.product, d.part_description,
       s.sto_class, s.site_oh_qty, s.min_level, s.max_level, 'OH_ZERO' AS flag
FROM stock_oh_zero s
  INNER JOIN target_part_sites tps ON tps.sto_part = s.sto_part AND tps.site = s.site
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
ORDER BY s.site, s.sto_part;


-- Query 2: All APNs with on-hand < min AND no active requisitions
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
stock_below_min AS (
  SELECT site, sto_part, MAX(sto_class) AS sto_class,
         MAX(min_level) AS min_level, MAX(max_level) AS max_level, MAX(site_oh_qty) AS site_oh_qty, region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class,
           CAST(sto_minlev AS DOUBLE) AS min_level, CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
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
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
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
  WHERE rl.rql_part IN (SELECT sto_part FROM target_part_sites)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  GROUP BY rl.rql_part, rh.req_org
)
SELECT s.site, s.region, s.sto_part AS apn, tps.product, d.part_description, s.sto_class,
       s.site_oh_qty, s.min_level, s.max_level,
       COALESCE(r.active_req_count, 0) AS active_req_count,
       COALESCE(r.active_req_qty, 0) AS active_req_qty,
       r.earliest_req_date, 'OH_BELOW_MIN' AS flag
FROM stock_below_min s
  INNER JOIN target_part_sites tps ON tps.sto_part = s.sto_part AND tps.site = s.site
  LEFT JOIN part_desc d ON d.cat_part = s.sto_part
  LEFT JOIN active_reqs r ON r.part = s.sto_part AND r.site = s.site
WHERE COALESCE(r.active_req_count, 0) = 0
ORDER BY s.site, s.sto_part;


