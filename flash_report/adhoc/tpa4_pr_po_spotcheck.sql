-- =============================================================================
-- TPA4 PR/PO spot-check for a few parts
-- =============================================================================
-- Shows EVERY purchase requisition and order line for the chosen parts at TPA4,
-- not just the "latest open" ones the flash report keeps. Use it to audit what
-- is really behind a heatmap cell (all PRs/POs, any status, with dates/qtys).
--
-- Input: you give MPN and/or CatRef (what the heatmap shows). The PR/PO tables
--        key on APN, so we first resolve MPN/CRN -> APN via the published
--        default.rspl_apn_mapping table (scoped to TPA4), then join PR + PO.
--
-- TPA4 is a NA site -> _apm_na tables. Read-only. Run in Athena.
-- Edit the two VALUES lists below (leave CRN blank '' if you only know the MPN).
-- =============================================================================

WITH wanted AS (
  -- >>> EDIT: the parts you want to check (MPN, CatRef). CRN optional ('').
  SELECT mpn, crn FROM (VALUES
    ('EXAMPLE-MPN-1', ''),
    ('EXAMPLE-MPN-2', '10400880')
  ) AS t(mpn, crn)
),

-- Resolve the wanted parts to their APNs at TPA4 (from the published mapping).
part_apns AS (
  SELECT DISTINCT
    m.rspl_mpn   AS mpn,
    m.rspl_catref AS crn,
    m.apn,
    m.product,
    m.mapping_status
  FROM default.rspl_apn_mapping m
  JOIN wanted w
    ON trim(m.rspl_mpn) = trim(w.mpn)
   AND (w.crn = '' OR trim(m.rspl_catref) = trim(w.crn))
  WHERE m.site = 'TPA4'
    AND m.apn IS NOT NULL
),

-- Every requisition line for those APNs at TPA4 (any status).
reqs AS (
  SELECT
    rh.req_org                              AS site,
    rl.rql_part                             AS apn,
    trim(cast(rl.rql_req AS varchar))       AS req_number,
    rh.req_status,
    rl.rql_status,
    CAST(rl.rql_qty AS DOUBLE)              AS req_qty,
    CAST(rh.req_date AS DATE)               AS req_date,
    date_diff('day', CAST(rh.req_date AS DATE), CURRENT_DATE) AS req_days_open
  FROM "andes"."rme-gdl.r5requislines_apm_na" rl
  JOIN "andes"."rme-gdl.r5requisitions_apm_na" rh
    ON trim(cast(rl.rql_req AS varchar)) = trim(cast(rh.req_code AS varchar))
  WHERE rh.req_org = 'TPA4'
    AND rl.rql_part IN (SELECT apn FROM part_apns)
),

-- Every order line for those APNs at TPA4 (any status).
pos AS (
  SELECT
    rl.ord_org                              AS site,
    l.orl_part                              AS apn,
    trim(cast(l.orl_order AS varchar))      AS po_number,
    rl.ord_status,
    l.orl_status,
    CAST(l.orl_ordqty AS DOUBLE)            AS po_qty_ordered,
    CAST(l.orl_recvqty AS DOUBLE)           AS po_qty_received,
    CAST(l.orl_ordqty AS DOUBLE) - CAST(l.orl_recvqty AS DOUBLE) AS po_qty_outstanding,
    CAST(rl.ord_date AS DATE)               AS po_date
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
  JOIN "andes"."rme-gdl.r5orders_apm_na" rl
    ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE rl.ord_org = 'TPA4'
    AND l.orl_part IN (SELECT apn FROM part_apns)
)

-- One row per PR and per PO, labeled so you can read them together.
SELECT
  p.mpn,
  p.crn,
  p.apn,
  p.product,
  p.mapping_status,
  'PR'            AS record_type,
  r.req_number    AS doc_number,
  r.req_status    AS header_status,
  r.rql_status    AS line_status,
  r.req_qty       AS qty_ordered,
  CAST(NULL AS DOUBLE) AS qty_received,
  CAST(NULL AS DOUBLE) AS qty_outstanding,
  r.req_date      AS doc_date,
  r.req_days_open AS days_open
FROM part_apns p
JOIN reqs r ON r.apn = p.apn

UNION ALL

SELECT
  p.mpn,
  p.crn,
  p.apn,
  p.product,
  p.mapping_status,
  'PO'            AS record_type,
  o.po_number     AS doc_number,
  o.ord_status    AS header_status,
  o.orl_status    AS line_status,
  o.po_qty_ordered    AS qty_ordered,
  o.po_qty_received   AS qty_received,
  o.po_qty_outstanding AS qty_outstanding,
  o.po_date       AS doc_date,
  date_diff('day', o.po_date, CURRENT_DATE) AS days_open
FROM part_apns p
JOIN pos o ON o.apn = p.apn

ORDER BY mpn, apn, record_type, doc_date DESC;
