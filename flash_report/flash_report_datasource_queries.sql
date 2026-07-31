-- Flash Report Data Source Queries (Athena)
-- Query 4 → tab3_datasource.csv
-- Query 5 → tab4_datasource.csv
-- Query 8 → tab5_datasource.csv


-- Query 4: Target parts with latest open purchase requisition > 1 week old
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
  LEFT JOIN (
    SELECT site, sto_part, MAX(sto_class) AS sto_class FROM (
      SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class
      FROM "andes"."rme-gdl.r5stock_apm_na"
      UNION ALL
      SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class
      FROM "andes"."rme-gdl.r5stock_apm_eu"
    ) raw GROUP BY site, sto_part
  ) sc ON sc.sto_part = o.apn AND sc.site = o.site
WHERE o.rn = 1 AND o.days_open > 7
ORDER BY o.days_open DESC, o.site, o.apn;



-- Query 5: Replacement rate for target parts
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
consumption_data AS (
  SELECT site, region, apn, DATE(trl_date) AS consumption_date,
         CAST(est_total_consumption AS DOUBLE) AS qty_consumed
  FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption"
  WHERE apn IN (SELECT sto_part FROM target_part_sites)
    AND site IN (SELECT site FROM target_part_sites)
)
SELECT c.site, c.region, c.apn, tps.product, d.part_description, sc.sto_class,
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
  INNER JOIN target_part_sites tps ON tps.sto_part = c.apn AND tps.site = c.site
  LEFT JOIN part_desc d ON d.cat_part = c.apn
  LEFT JOIN (
    SELECT site, sto_part, MAX(sto_class) AS sto_class FROM (
      SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class FROM "andes"."rme-gdl.r5stock_apm_na"
      UNION ALL
      SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part, sto_class FROM "andes"."rme-gdl.r5stock_apm_eu"
    ) raw GROUP BY site, sto_part
  ) sc ON sc.sto_part = c.apn AND sc.site = c.site
GROUP BY c.site, c.region, c.apn, tps.product, d.part_description, sc.sto_class
HAVING SUM(c.qty_consumed) > 0
ORDER BY c.site, c.apn





-- Query 8: Expected vs Actual failure rate per part per site
-- Expected failure rate = MIN / supplier_lead_time (daily rate implied by min level setting)
-- Actual failure rate = consumed_180d / 180 (daily replacement rate over last 180 days)
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
stock_info AS (
  SELECT site, sto_part, MAX(min_level) AS min_level, MAX(sto_class) AS sto_class, region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_minlev AS DOUBLE) AS min_level, sto_class, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT sto_part FROM target_part_sites)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM target_part_sites)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_minlev AS DOUBLE) AS min_level, sto_class, 'EU' AS region
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
consumption AS (
  SELECT site, apn,
         SUM(CASE WHEN DATE(trl_date) >= date_add('day', -180, CURRENT_DATE) THEN CAST(est_total_consumption AS DOUBLE) ELSE 0 END) AS consumed_180d,
         ROUND(SUM(CASE WHEN DATE(trl_date) >= date_add('day', -180, CURRENT_DATE) THEN CAST(est_total_consumption AS DOUBLE) ELSE 0 END) / 180.0, 4) AS actual_daily_rate
  FROM "andes"."ar-performance-n-insights.hw_part_family_site_equipment_consumption"
  WHERE apn IN (SELECT sto_part FROM target_part_sites)
    AND site IN (SELECT site FROM target_part_sites)
  GROUP BY site, apn
)
SELECT
  st.site, st.region, st.sto_part AS apn, tps.product, d.part_description, st.sto_class,
  st.min_level,
  lt.supplier_lead_time,
  -- Expected daily failure rate (implied by min level / lead time)
  ROUND(CASE WHEN COALESCE(lt.supplier_lead_time, 0) > 0 THEN st.min_level / lt.supplier_lead_time ELSE NULL END, 4) AS expected_daily_rate,
  -- Actual daily failure rate (180d)
  c.actual_daily_rate,
  c.consumed_180d,
  -- Ratio: actual / expected (>1 means failing faster than min was set for)
  ROUND(CASE WHEN st.min_level > 0 AND COALESCE(lt.supplier_lead_time, 0) > 0
    THEN c.actual_daily_rate / (st.min_level / lt.supplier_lead_time)
    ELSE NULL END, 4) AS actual_vs_expected_ratio
FROM stock_info st
  INNER JOIN target_part_sites tps ON tps.sto_part = st.sto_part AND tps.site = st.site
  LEFT JOIN part_desc d ON d.cat_part = st.sto_part
  LEFT JOIN lead_time lt ON lt.site = st.site AND lt.part_ordered = st.sto_part AND lt.region = st.region
  LEFT JOIN consumption c ON c.site = st.site AND c.apn = st.sto_part
ORDER BY actual_vs_expected_ratio DESC NULLS LAST, st.site, st.sto_part
