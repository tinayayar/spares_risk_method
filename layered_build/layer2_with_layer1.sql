-- layer2_with_layer1.sql
-- Base table: the Layer 2 score-base output (from layer2_base_scores.sql).
-- Enriched with Layer 1 (RSPL / APM setup) attributes via LEFT JOIN on site + apn.
--
-- Layer 1 is now built from hw_critical_spares_apm_setup_details with a corrected
-- site-to-product mapping. The raw table's product + rspl_rev can assign sites to
-- wrong products (e.g. BOS3 tagged with URL Rev C when it should only have USP and
-- URL Rev D). The target_sites CTE is the authoritative site→product mapping;
-- an INNER JOIN filters out misassigned rows. The corrected product is then
-- collapsed into a comma-separated product_list per site+apn.
--
-- Because Layer 2 is the base and the join is a LEFT JOIN:
--   * every Layer 2 (scored) part is kept
--   * Layer 1 columns are populated where the part also exists in Layer 1,
--     and NULL otherwise
--   * is_rspl_apn is COALESCEd to 0 for parts not found in Layer 1
--
-- Join key: layer2.part (APN) = layer1.apn  AND  layer2.site = layer1.site
--
-- Sources:
--   L2 base : output of layer2_base_scores.sql
--             "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
--   L1 raw  : "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"

WITH
-- Authoritative site → product mapping.
-- USP_EU is normalized to USP for matching (the raw table has no region split).
target_sites AS (
  SELECT site, 'USP' AS product FROM (VALUES
    ('ABQ1'), ('AGS1'), ('AKC1'), ('AUS2'), ('BDL4'), ('BOS3'), ('BWI2'), ('DAB2'),
    ('DEN4'), ('DEN9'), ('DET6'), ('ELP1'), ('FSD1'), ('FWA6'), ('GEG1'),
    ('GYR1'), ('HOU6'), ('IAG1'), ('IGQ1'), ('ILM1'), ('LUK2'), ('MKC6'), ('MLI1'),
    ('MQY1'), ('MTN1'), ('OMA2'), ('ORD5'), ('ORF3'), ('ORF4'), ('ORH3'), ('OXR1'),
    ('PAE2'), ('PDX8'), ('PVD2'), ('RIC4'), ('RIC6'), ('SAN3'), ('SAT3'), ('SAV4'),
    ('SBD6'), ('SBN1'), ('SCK6'), ('SHV1'), ('SYR1'), ('TLH2'), ('TPA4'), ('TYS1'),
    ('VGT1'), ('YEG2'), ('YHM1'), ('YOW3'), ('YXU1'), ('YYC4')
  ) AS t(site)
  UNION ALL
  SELECT site, 'USP' AS product FROM (VALUES
    ('BCN4'), ('BHX2'), ('BRQ2'), ('DSA6'), ('DUS4'), ('EMA2'), ('KTW3'), ('LCY3'),
    ('LYS2'), ('MXP6'), ('NCL1'), ('POZ2'), ('STN6'), ('SVQ1')
  ) AS t(site)
  UNION ALL
  SELECT site, 'URL Rev C' AS product FROM (VALUES
    ('SHV1'), ('ORF3'), ('ORF4')
  ) AS t(site)
  UNION ALL
  SELECT site, 'URL Rev C2' AS product FROM (VALUES
    ('CLE3'), ('BCN4'), ('ORH3'), ('PAE2'), ('DEN9'), ('IAG1'), ('ORF3'), ('ORF4')
  ) AS t(site)
  UNION ALL
  SELECT site, 'URL Rev D' AS product FROM (VALUES
    ('BDL4'), ('BOS3'), ('ILM1'), ('RIC4'), ('SYR1'), ('YOW3'), ('TPA4'), ('MQY1'),
    ('TYS1'), ('DCA1'),
    ('RIC6'), ('LUK2'), ('DUS4')
  ) AS t(site)
),

valid_site_product AS (
  SELECT DISTINCT site, product FROM target_sites
),

-- Raw APM table with corrected product label derived from product + rspl_rev.
-- INNER JOIN to valid_site_product drops rows with wrong site/product combos.
layer1_corrected AS (
  SELECT
    d.site,
    CASE
      WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C2' THEN 'URL Rev C2'
      WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
      ELSE NULL
    END AS product,
    d.mpn,
    d.catalogue_reference,
    CASE
      WHEN UPPER(TRIM(CAST(d.apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
      ELSE d.apn
    END AS apn,
    d.sto_prefmanufactpart,
    d.sto_min_lev,
    d.sto_leadtime,
    d.not_set_up_in_apm,
    d.missing_mpn_network,
    d.missing_mpn_site,
    d.missing_crn,
    d.incorrect_mpn,
    d.multiple_apns
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details" d
    INNER JOIN valid_site_product v
      ON v.site = d.site
     AND v.product = CASE
           WHEN UPPER(TRIM(d.product)) = 'USP' THEN 'USP'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'  THEN 'URL Rev C'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C2' THEN 'URL Rev C2'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'  THEN 'URL Rev D'
           ELSE NULL
         END
),

-- Layer 1 deduped to one row per site + product + mpn + apn.
-- MPN is part of the grain so countDistinct(mpn) is accurate directly on this
-- dataset. Consequence: when one APN maps to multiple MPNs, that APN's Layer 2
-- score is duplicated across the MPN rows; when multiple APNs map to one MPN,
-- their scores are counted separately. Use countDistinct / max on score columns
-- when aggregating in QuickSight to avoid inflating additive sums.
layer1 AS (
  SELECT
    site,
    product,
    mpn,
    apn,
    1 AS is_rspl_apn,
    MAX(catalogue_reference) AS catalogue_reference,
    MAX(sto_prefmanufactpart) AS sto_prefmanufactpart,
    MAX(sto_min_lev)         AS sto_min_lev,
    MAX(sto_leadtime)        AS sto_leadtime,
    MAX(not_set_up_in_apm)   AS not_set_up_in_apm,
    MAX(missing_mpn_network) AS missing_mpn_network,
    MAX(missing_mpn_site)    AS missing_mpn_site,
    MAX(missing_crn)         AS missing_crn,
    MAX(incorrect_mpn)       AS incorrect_mpn,
    MAX(multiple_apns)       AS multiple_apns
  FROM layer1_corrected
  -- No apn IS NOT NULL filter: MPNs with no APN (not set up in APM) are kept.
  -- Their apn is NULL, so they never match Layer 2 (l1.apn = l2.part) and come
  -- through the full join as Layer-1-only rows with no scores.
  GROUP BY site, product, mpn, apn
),

-- Distinct MPNs not set up in APM, per site + product.
-- Counted from layer1_corrected (all MPNs, including null-APN parts) so the
-- count is complete and unaffected by the APN-keyed grain of layer1.
site_product_apm_gap AS (
  SELECT site, product,
         COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) AS not_set_up_mpn_count
  FROM layer1_corrected
  GROUP BY site, product
),

-- Site-level APM penalty: 5 when the site has >= 10 distinct MPNs not set up in
-- APM, else 0. Counted from layer1_corrected (all MPNs, including null-APN parts).
site_apm_gap AS (
  SELECT site,
         COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) AS site_not_set_up_mpn_count,
         CASE WHEN COUNT(DISTINCT CASE WHEN not_set_up_in_apm = 1 THEN mpn END) >= 10
              THEN 5 ELSE 0 END AS site_apm_penalty
  FROM layer1_corrected
  GROUP BY site
),

-- Layer 2 score base, LATEST snapshot only.
-- The score base retains every snapshot_date (partitioned); we keep only the
-- most recent snapshot so the dashboard reflects the current state and score
-- columns are not multiplied across historical snapshots.
layer2 AS (
  SELECT *
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
)

SELECT
  -- Snapshot date stamped as the run date (today), not sourced from Layer 2.
  -- Populated for every row, including Layer-1-only rows.
  CURRENT_DATE AS snapshot_date,

  -- Key columns COALESCEd across both sides so they are populated whether the
  -- row comes from Layer 2 (scored), Layer 1 (RSPL/APM), or both.
  COALESCE(l2.site, l1.site) AS site,
  COALESCE(l2.part, l1.apn)  AS part,

  -- Remaining Layer 2 score columns (NULL for Layer-1-only parts).
  l2.region,
  l2.amazon_pn,
  l2.part_description,
  l2.cat_ref_list,
  l2.product_list,
  l2.building_type,
  l2.sto_class,
  l2.site_oh_qty,
  l2.min_level,
  l2.max_level,
  l2.supplier_lead_time,
  l2.replenishment_time,
  l2.source,
  l2.order_count,
  l2.avg_rep_time_days,
  l2.min_rep_time_days,
  l2.max_rep_time_days,
  l2.last_received_date,
  l2.last_30d_order,
  l2.last_60d_order,
  l2.last_90d_order,
  l2.last_120d_order,
  l2.last_150d_order,
  l2.last_180d_order,
  l2.last_365d_order,
  l2.open_order_count,
  l2.back_order_qty,
  l2.nearest_po_number,
  l2.order_inaction_flag,
  l2.trend_ratio,
  l2.consumed_150d,
  l2.consumption_rate_150d,
  l2.replenishment_demand_150d,
  l2.coverage_150d,
  l2.stockout_fraction_150d,
  l2.stockout_days_per_cycle_150d,
  l2.cycle_length_days_150d,
  l2.cycles_per_year_150d,
  l2.stockout_days_yr_min_150d,
  l2.stockout_days_min_rep_150d,
  l2.combined_stockout_days_yr_150d,
  l2.structural_risk_combo_criticality_150d,
  l2.days_of_supply_150d,
  l2.depletion_date_150d,
  l2.projected_order_date_150d,
  l2.stockout_days_yr_rep_150d,
  l2.adj_days_of_supply_150d,
  l2.situational_score_150d,
  l2.situational_score_criticality_150d,
  l2.overall_score_criticality_150d,
  l2.ar_region,
  l2.subregion,
  l2.type,
  l2.subtype,

  -- Layer 1 enrichment (NULL for Layer-2-only parts).
  COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
  -- in_score_base = 1 when the part exists in Layer 2 (has scores).
  CASE WHEN l2.part IS NOT NULL THEN 1 ELSE 0 END AS in_score_base,
  l1.product,
  l1.mpn,
  l1.catalogue_reference,
  l1.sto_prefmanufactpart,
  l1.sto_min_lev,
  l1.sto_leadtime,
  l1.not_set_up_in_apm,
  l1.missing_mpn_network,
  l1.missing_mpn_site,
  l1.missing_crn,
  l1.incorrect_mpn,
  l1.multiple_apns,

  -- Distinct MPNs not set up in APM at this site (across all products).
  COALESCE(g.site_not_set_up_mpn_count, 0) AS site_not_set_up_mpn_count,
  -- Site-level APM penalty (5 when site has >= 10 MPNs not set up in APM, else 0).
  COALESCE(g.site_apm_penalty, 0) AS site_apm_penalty,
  -- Distinct MPNs not set up in APM for this site + product.
  COALESCE(gp.not_set_up_mpn_count, 0) AS not_set_up_mpn_count
FROM layer2 l2
  FULL OUTER JOIN layer1 l1
    ON l1.site = l2.site
   AND l1.apn  = l2.part
  LEFT JOIN site_apm_gap g
    ON g.site = COALESCE(l2.site, l1.site)
  LEFT JOIN site_product_apm_gap gp
    ON gp.site = COALESCE(l2.site, l1.site)
   AND gp.product = l1.product
