-- =============================================================================
-- Universal MPN/CatRef to APN Mapping (USP + URL Rev C + URL Rev D)
-- Input: "default"."rspl_target_parts" (USP) + "default"."rspl_target_parts_URL" (URL)
-- Sites: hardcoded per product (update as needed)
--
-- Logic:
--   Path 1: r5stock sto_prefmanufactpart = MPN (network-wide, no site filter)
--   Path 2: r5catalogue cat_ref = CatRef (network-wide)
--   UNION candidates, then check which exist at target sites (within 2 years).
--   Color-classify each candidate at each site:
--     GREEN  = site's local sto_prefmanufactpart matches the RSPL MPN (or NULL)
--     YELLOW = site's local sto_prefmanufactpart is a different non-null value
--   For each (rspl_mpn, rspl_catref, site) group: prefer GREEN, fall back to YELLOW.
--
-- Output: apn, site, stock_mpn, mpn_path_source, catalogue_path_source,
--         rspl_mpn, rspl_catref, product, mapping_status, match_confidence
-- =============================================================================

WITH rspl AS (
  -- USP parts (NA) — routed to NA USP sites only
  SELECT DISTINCT mpn, catalog_reference, 'USP' AS product
  FROM "default"."rspl_target_parts"
  WHERE mpn IS NOT NULL AND mpn != ''
  UNION ALL
  -- USP parts (EU) — routed to EU USP sites only. Internal 'USP_EU' tag keeps the
  -- two USP part lists from bleeding across regions; it is normalized back to
  -- 'USP' in the final output so the report shows a single USP product.
  SELECT DISTINCT mpn, catalog_reference, 'USP_EU' AS product
  FROM "default"."rspl_target_parts_usp_eu"
  WHERE mpn IS NOT NULL AND mpn != ''
  UNION ALL
  -- URL parts (Rev C, C2, and D)
  SELECT DISTINCT mpn, catalog_reference,
    CASE WHEN product = 'URL_C' THEN 'URL Rev C'
         WHEN product = 'URL_C2' THEN 'URL Rev C2'
         WHEN product = 'URL_D' THEN 'URL Rev D'
         ELSE product END AS product
  FROM "default"."rspl_target_parts_URL"
  WHERE mpn IS NOT NULL AND mpn != ''
),

target_sites AS (
  -- USP NA sites (54) — use "default"."rspl_target_parts"
  SELECT site, 'USP' AS product FROM (VALUES
    ('ABQ1'), ('AGS1'), ('AKC1'), ('AUS2'), ('BDL4'), ('BOS3'), ('BWI2'), ('DAB2'),
    ('DEN4'), ('DEN9'), ('DET6'), ('DSA6'), ('ELP1'), ('FSD1'), ('FWA6'), ('GEG1'),
    ('GYR1'), ('HOU6'), ('IAG1'), ('IGQ1'), ('ILM1'), ('LUK2'), ('MKC6'), ('MLI1'),
    ('MQY1'), ('MTN1'), ('OMA2'), ('ORD5'), ('ORF3'), ('ORF4'), ('ORH3'), ('OXR1'),
    ('PAE2'), ('PDX8'), ('PVD2'), ('RIC4'), ('RIC6'), ('SAN3'), ('SAT3'), ('SAV4'),
    ('SBD6'), ('SBN1'), ('SCK6'), ('SHV1'), ('SYR1'), ('TLH2'), ('TPA4'), ('TYS1'),
    ('VGT1'), ('YEG2'), ('YHM1'), ('YOW3'), ('YXU1'), ('YYC4')
  ) AS t(site)
  UNION ALL
  -- USP EU sites (13) — use "default"."rspl_target_parts_usp_eu"
  SELECT site, 'USP_EU' AS product FROM (VALUES
    ('BCN4'), ('BHX2'), ('BRQ2'), ('DUS4'), ('EMA2'), ('KTW3'), ('LCY3'), ('LYS2'),
    ('MXP6'), ('NCL1'), ('POZ2'), ('STN6'), ('SVQ1')
  ) AS t(site)
  UNION ALL
  -- URL Rev C sites (3)
  SELECT site, 'URL Rev C' AS product FROM (VALUES
    ('SHV1'), ('ORF3'), ('ORF4')
  ) AS t(site)
  UNION ALL
  -- URL Rev C2 sites (8) — ORF3/ORF4 have both Rev C and Rev C2
  SELECT site, 'URL Rev C2' AS product FROM (VALUES
    ('CLE3'), ('BCN4'), ('ORH3'), ('PAE2'), ('DEN9'), ('IAG1'), ('ORF3'), ('ORF4')
  ) AS t(site)
  UNION ALL
  -- URL Rev D sites (13) — 10 live + 3 upcoming (RIC6, LUK2, DUS4)
  SELECT site, 'URL Rev D' AS product FROM (VALUES
    ('BDL4'), ('BOS3'), ('ILM1'), ('RIC4'), ('SYR1'), ('YOW3'), ('TPA4'), ('MQY1'),
    ('TYS1'), ('DCA1'),
    ('RIC6'), ('LUK2'), ('DUS4')
  ) AS t(site)
),

-- All unique sites across all products (for stock lookups)
all_target_sites AS (
  SELECT DISTINCT site FROM target_sites
),

-- =========================================================================
-- PATH 1: Find APNs via sto_prefmanufactpart (network-wide, no site filter)
-- =========================================================================
mpn_to_apn AS (
  SELECT DISTINCT sto_part AS apn, sto_prefmanufactpart AS mpn
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_prefmanufactpart IN (SELECT mpn FROM rspl)
  UNION
  SELECT DISTINCT sto_part AS apn, sto_prefmanufactpart AS mpn
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_prefmanufactpart IN (SELECT mpn FROM rspl)
),

-- =========================================================================
-- PATH 2: Find APNs via r5catalogue cat_ref (network-wide)
-- =========================================================================
catref_to_apn AS (
  SELECT DISTINCT cat_part AS apn, cat_ref AS catref
  FROM "andes"."rme-gdl.r5catalogue_apm_na"
  WHERE cat_ref IN (SELECT catalog_reference FROM rspl WHERE catalog_reference IS NOT NULL AND catalog_reference != '')
  UNION
  SELECT DISTINCT cat_part AS apn, cat_ref AS catref
  FROM "andes"."rme-gdl.r5catalogue_apm_eu"
  WHERE cat_ref IN (SELECT catalog_reference FROM rspl WHERE catalog_reference IS NOT NULL AND catalog_reference != '')
),

-- =========================================================================
-- UNION all candidate APNs
-- =========================================================================
all_candidate_apns AS (
  SELECT DISTINCT apn FROM mpn_to_apn
  UNION
  SELECT DISTINCT apn FROM catref_to_apn
),

-- =========================================================================
-- CHECK which candidates exist at target sites (within 2 years)
-- =========================================================================
stock_at_sites AS (
  SELECT DISTINCT
    sto_part AS apn,
    SPLIT_PART(sto_store, '-', 1) AS site,
    sto_prefmanufactpart AS stock_mpn
  FROM "andes"."rme-gdl.r5stock_apm_na"
  WHERE sto_part IN (SELECT apn FROM all_candidate_apns)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM all_target_sites)
    AND sto_lastsaved >= CURRENT_TIMESTAMP - INTERVAL '730' DAY
  UNION ALL
  SELECT DISTINCT
    sto_part AS apn,
    SPLIT_PART(sto_store, '-', 1) AS site,
    sto_prefmanufactpart AS stock_mpn
  FROM "andes"."rme-gdl.r5stock_apm_eu"
  WHERE sto_part IN (SELECT apn FROM all_candidate_apns)
    AND SPLIT_PART(sto_store, '-', 1) IN (SELECT site FROM all_target_sites)
    AND sto_lastsaved >= CURRENT_TIMESTAMP - INTERVAL '730' DAY
)

-- =========================================================================
-- COLOR-CLASSIFY every candidate match, then prefer GREEN, fall back to YELLOW
-- =========================================================================
-- Per the flowchart:
--   GREEN  = APN present at site AND local sto_prefmanufactpart matches
--            RSPL MPN (or local label is NULL — treated as no contradiction)
--   YELLOW = APN present at site AND local sto_prefmanufactpart is a
--            DIFFERENT non-null value than the RSPL MPN
-- Rule: for each (rspl_mpn, rspl_catref, site) group, if any GREEN row exists
-- we keep only the GREEN rows; otherwise we keep the YELLOW rows.

, matched_colored AS (
  SELECT
    s.apn,
    s.site,
    s.stock_mpn,
    m.mpn AS mpn_path_source,
    c.catref AS catalogue_path_source,
    COALESCE(m.mpn, r_mpn.mpn, r_cat.mpn) AS rspl_mpn,
    COALESCE(r_mpn.catalog_reference, r_cat.catalog_reference) AS rspl_catref,
    COALESCE(r_mpn.product, r_cat.product) AS product,
    CASE
      WHEN m.mpn IS NOT NULL AND c.catref IS NOT NULL THEN 'APN found by both MPN and catalogue reference'
      WHEN m.mpn IS NOT NULL AND c.catref IS NULL THEN 'APN found by only MPN'
      WHEN m.mpn IS NULL AND c.catref IS NOT NULL THEN 'APN found by only catalogue reference'
      ELSE 'APN found'
    END AS mapping_status,
    CASE
      WHEN s.stock_mpn IS NULL THEN 'GREEN'
      WHEN s.stock_mpn = COALESCE(r_mpn.mpn, r_cat.mpn) THEN 'GREEN'
      ELSE 'YELLOW'
    END AS match_confidence
  FROM stock_at_sites s
    LEFT JOIN mpn_to_apn m ON s.apn = m.apn
    LEFT JOIN catref_to_apn c ON s.apn = c.apn
    LEFT JOIN rspl r_mpn ON r_mpn.mpn = m.mpn
    LEFT JOIN rspl r_cat ON r_cat.catalog_reference = c.catref AND r_mpn.mpn IS NULL
  WHERE EXISTS (
    SELECT 1 FROM target_sites ts
    WHERE ts.site = s.site
      AND ts.product = COALESCE(r_mpn.product, r_cat.product)
  )
),

-- Flag which (rspl_mpn, rspl_catref, site) groups have at least one GREEN row
matched_with_group_flag AS (
  SELECT
    mc.*,
    MAX(CASE WHEN match_confidence = 'GREEN' THEN 1 ELSE 0 END)
      OVER (PARTITION BY rspl_mpn, rspl_catref, site) AS group_has_green
  FROM matched_colored mc
)

-- =========================================================================
-- FINAL OUTPUT
-- =========================================================================

-- Matched: keep GREEN rows always; keep YELLOW rows only when no GREEN
-- exists for the same (rspl_mpn, rspl_catref, site) group.
SELECT
  apn,
  site,
  stock_mpn,
  mpn_path_source,
  catalogue_path_source,
  rspl_mpn,
  rspl_catref,
  CASE WHEN product = 'USP_EU' THEN 'USP' ELSE product END AS product,
  mapping_status,
  match_confidence
FROM matched_with_group_flag
WHERE match_confidence = 'GREEN'
   OR (match_confidence = 'YELLOW' AND group_has_green = 0)

UNION ALL

-- Not found: RSPL MPNs with no candidate APN at a target site
SELECT
  CAST(NULL AS VARCHAR) AS apn,
  nf.site,
  CAST(NULL AS VARCHAR) AS stock_mpn,
  CAST(NULL AS VARCHAR) AS mpn_path_source,
  CAST(NULL AS VARCHAR) AS catalogue_path_source,
  nf.mpn AS rspl_mpn,
  nf.catalog_reference AS rspl_catref,
  CASE WHEN nf.product = 'USP_EU' THEN 'USP' ELSE nf.product END AS product,
  'No APN found' AS mapping_status,
  CAST(NULL AS VARCHAR) AS match_confidence
FROM (
  SELECT r.mpn, r.catalog_reference, r.product, ts.site
  FROM rspl r
  INNER JOIN target_sites ts ON ts.product = r.product
) nf
LEFT JOIN (
  SELECT DISTINCT
    COALESCE(m.mpn, r2.mpn) AS mpn,
    s.site
  FROM stock_at_sites s
  LEFT JOIN mpn_to_apn m ON s.apn = m.apn
  LEFT JOIN catref_to_apn c ON s.apn = c.apn
  LEFT JOIN rspl r2 ON r2.catalog_reference = c.catref
) found ON found.mpn = nf.mpn AND found.site = nf.site
WHERE found.mpn IS NULL

ORDER BY product, site, rspl_mpn, apn;
