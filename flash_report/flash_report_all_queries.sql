-- =============================================================================
-- flash_report_all_queries.sql
-- Single consolidated query for the RSPL Flash Report (USP + URL Rev C + URL Rev D)
--
-- PREREQUISITE: Run query_mapping_datasource.sql first.
-- Save output to S3 and create table:
--   "default"."rspl_apn_mapping"
--   Columns: apn, site, stock_mpn, mpn_path_source, catalogue_path_source,
--            rspl_mpn, rspl_catref, product, mapping_status
--
-- This query joins the mapping with stock, PR, and order data to produce
-- a single CSV (flash_report_datasource.csv) that feeds the HTML generator.
-- =============================================================================

WITH mapping AS (
  SELECT DISTINCT apn, site, stock_mpn, rspl_mpn, rspl_catref, product, mapping_status, match_confidence
  FROM "default"."rspl_apn_mapping"
),

-- Stock data for matched APNs
stock_data AS (
  SELECT site, sto_part,
         MAX(site_oh_qty) AS site_oh_qty,
         MAX(min_level) AS min_level,
         MAX(max_level) AS max_level,
         MAX(sto_class) AS sto_class,
         MIN(region) AS region
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    WHERE sto_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM mapping)
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site, sto_part,
           CAST(sto_qty AS DOUBLE) AS site_oh_qty,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           sto_class, 'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
    WHERE sto_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
      AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM mapping)
  ) raw
  GROUP BY site, sto_part
),

-- Active purchase requisitions
active_reqs AS (
  SELECT rl.rql_part AS part, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number,
         CAST(rl.rql_qty AS DOUBLE) AS req_qty,
         CAST(rh.req_date AS DATE) AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
  UNION ALL
  SELECT rl.rql_part AS part, rh.req_org AS site,
         trim(cast(rl.rql_req AS varchar)) AS req_number,
         CAST(rl.rql_qty AS DOUBLE) AS req_qty,
         CAST(rh.req_date AS DATE) AS req_date,
         date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS days_open
  FROM "andes"."rme-gdl.r5requislines_apm_eu" rl
    INNER JOIN "andes"."rme-gdl.r5requisitions_apm_eu" rh
      ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rl.rql_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
    AND rh.req_status = 'A' AND rl.rql_status = 'A'
),

-- Keep only most recent PR per site+apn
active_reqs_ranked AS (
  SELECT part, site, req_number, req_qty, req_date, days_open,
         ROW_NUMBER() OVER (PARTITION BY site, part ORDER BY req_date DESC) AS rn
  FROM active_reqs
),

active_reqs_latest AS (
  SELECT part, site, req_number, req_qty, req_date, days_open
  FROM active_reqs_ranked
  WHERE rn = 1
),

-- Order fill data
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
    WHERE l.orl_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
      AND rl.ord_org IN (SELECT site FROM mapping)
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS apn,
           CAST(l.orl_ordqty AS DOUBLE) AS qty_ordered,
           CAST(l.orl_recvqty AS DOUBLE) AS qty_received
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    WHERE l.orl_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
      AND rl.ord_org IN (SELECT site FROM mapping)
  ) orders
  GROUP BY site, apn
),

-- Part descriptions
-- All catalogue description rows (NA + EU), keyed by both cat_part and cat_ref.
cat_desc_rows AS (
  SELECT cat_part, cat_ref, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_na" WHERE cat_desc IS NOT NULL
  UNION ALL
  SELECT cat_part, cat_ref, cat_desc FROM "andes"."rme-gdl.r5catalogue_apm_eu" WHERE cat_desc IS NOT NULL
),

-- Description keyed by the SPECIFIC catalogue reference that matched the part.
-- This is the honest description for that (cat_ref, apn) pair. It replaces the
-- old MAX(cat_desc)-across-all-cat_refs logic, which returned the alphabetically
-- largest string over every cat_ref an APN appears under and so surfaced junk
-- one-off rows (e.g. "TIMING BELT" on an APN that is really a 15A fuse).
desc_by_catref AS (
  SELECT cat_ref, cat_part, MAX(cat_desc) AS part_description
  FROM cat_desc_rows
  GROUP BY cat_ref, cat_part
),

-- Fallback: most common (mode) description per APN. Used when the RSPL part has
-- no catalog_reference, or no description exists under that cat_ref. Mode is
-- robust to the occasional corrupt/mislabeled catalogue row.
desc_mode AS (
  SELECT cat_part, cat_desc AS part_description
  FROM (
    SELECT cat_part, cat_desc,
           ROW_NUMBER() OVER (PARTITION BY cat_part ORDER BY COUNT(*) DESC, cat_desc) AS rn
    FROM cat_desc_rows
    GROUP BY cat_part, cat_desc
  ) t
  WHERE rn = 1
),

-- Site launch dates
site_launch AS (
  SELECT code AS site, launch_date
  FROM "andes"."ar-performance-n-insights.rts_rcc_facilities"
),

-- Open Purchase Orders (ord_status IN ('A','PR') AND orl_status = 'A')
open_pos AS (
  SELECT rl.ord_org AS site, l.orl_part AS apn,
         trim(cast(l.orl_order AS varchar)) AS po_number,
         CAST(l.orl_ordqty AS DOUBLE) AS po_qty_ordered,
         CAST(l.orl_recvqty AS DOUBLE) AS po_qty_received,
         CAST(l.orl_ordqty AS DOUBLE) - CAST(l.orl_recvqty AS DOUBLE) AS po_qty_outstanding,
         CAST(rl.ord_date AS DATE) AS po_date
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
      ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
    AND rl.ord_org IN (SELECT site FROM mapping)
    AND rl.ord_status IN ('A', 'PR')
    AND l.orl_status = 'A'
  UNION ALL
  SELECT rl.ord_org AS site, l.orl_part AS apn,
         trim(cast(l.orl_order AS varchar)) AS po_number,
         CAST(l.orl_ordqty AS DOUBLE) AS po_qty_ordered,
         CAST(l.orl_recvqty AS DOUBLE) AS po_qty_received,
         CAST(l.orl_ordqty AS DOUBLE) - CAST(l.orl_recvqty AS DOUBLE) AS po_qty_outstanding,
         CAST(rl.ord_date AS DATE) AS po_date
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
      ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT apn FROM mapping WHERE apn IS NOT NULL)
    AND rl.ord_org IN (SELECT site FROM mapping)
    AND rl.ord_status IN ('A', 'PR')
    AND l.orl_status = 'A'
),

-- Keep only most recent open PO per site+apn
open_pos_ranked AS (
  SELECT site, apn, po_number, po_qty_ordered, po_qty_received, po_qty_outstanding, po_date,
         ROW_NUMBER() OVER (PARTITION BY site, apn ORDER BY po_date DESC) AS rn
  FROM open_pos
),

open_pos_latest AS (
  SELECT site, apn, po_number, po_qty_ordered, po_qty_received, po_qty_outstanding, po_date
  FROM open_pos_ranked
  WHERE rn = 1
)

-- =============================================================================
-- FINAL OUTPUT: One row per APN+site (or per MPN+site for "No APN found")
-- =============================================================================
SELECT
  m.site,
  s.region,
  m.product,
  m.rspl_mpn AS mpn,
  m.rspl_catref AS catalog_reference,
  m.apn AS r5_apn,
  COALESCE(dcr.part_description, dmo.part_description) AS part_description,
  s.sto_class,
  s.site_oh_qty,
  s.min_level,
  s.max_level,
  -- KPI flags
  CASE WHEN COALESCE(s.site_oh_qty, 0) = 0 AND m.apn IS NOT NULL THEN 1 ELSE 0 END AS is_zero_oh,
  CASE WHEN COALESCE(s.site_oh_qty, 0) <= COALESCE(s.min_level, 0) AND s.min_level > 0 THEN 1 ELSE 0 END AS is_below_min,
  CASE WHEN COALESCE(s.site_oh_qty, 0) <= COALESCE(s.min_level, 0) AND s.min_level > 0 AND ar.part IS NULL THEN 1 ELSE 0 END AS is_below_min_no_pr,
  CASE WHEN ar.part IS NOT NULL THEN 1 ELSE 0 END AS has_active_pr,
  -- PR details
  ar.req_number,
  ar.req_qty,
  ar.req_date,
  ar.days_open,
  -- Order fill
  COALESCE(of.total_ordered, 0) AS total_ordered,
  COALESCE(of.total_received, 0) AS total_received,
  of.pct_received,
  -- Mapping info
  m.mapping_status,
  m.stock_mpn,
  m.match_confidence,
  -- Site info
  sl.launch_date,
  -- Open PO details
  op.po_number,
  op.po_qty_ordered,
  op.po_qty_received,
  op.po_qty_outstanding,
  op.po_date
FROM mapping m
  LEFT JOIN stock_data s ON s.sto_part = m.apn AND s.site = m.site
  LEFT JOIN desc_by_catref dcr ON dcr.cat_part = m.apn AND dcr.cat_ref = m.rspl_catref
  LEFT JOIN desc_mode dmo ON dmo.cat_part = m.apn
  LEFT JOIN active_reqs_latest ar ON ar.part = m.apn AND ar.site = m.site
  LEFT JOIN order_fill of ON of.apn = m.apn AND of.site = m.site
  LEFT JOIN site_launch sl ON sl.site = m.site
  LEFT JOIN open_pos_latest op ON op.apn = m.apn AND op.site = m.site
ORDER BY m.site, m.rspl_mpn, m.apn;
