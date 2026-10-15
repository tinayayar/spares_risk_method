-- layer2_with_layer1.sql
-- Athena variant of layer2_with_layer1_qs.sql.
-- Uses "andes"."schema.table" references and Athena-compatible syntax.
--
-- Base : Layer 2 score base (latest snapshot only)
--        "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
-- Enrich: Layer 1 RSPL / APM setup with corrected site->product mapping
--        "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--
-- Join: FULL OUTER JOIN on site + apn. Includes parts present in EITHER source.
-- Grain: one row per site + product + apn (Layer-2-only parts have product = NULL).
-- snapshot_date is stamped as the run date (today).

WITH
-- Authoritative site -> product mapping.
-- Single source: "andes"."bads.rts_site_to_product_mapping" carries ALL products
-- (USP, URL, SAS, TCC, SPARROW, ...) with product + product_version as separate
-- columns. We build the standardized product label AND a major-version key so
-- the join to the APM table keeps only the version a site actually runs.
--
-- Label (approach B): USP/URL mapped explicitly (version lives in the label);
-- every other product uses product_version directly as the label (e.g.
-- 'TCC 3.1', 'SAS 2.0'), with two renames: USP 'B1+LR' -> 'USP_B1', and
-- Sparrow 'Gen 2.0' -> 'Sparrow 2.0'.
--
-- Version number: the FULL numeric version from product_version, decimals
-- included (TCC 3.0 -> 3.0, TCC 3.1 -> 3.1, SAS 2.5 -> 2.5). The APM table's
-- rspl_rev is also fine-grained (2.2 / 3.0 / 3.1 / 4.0), so matching on the
-- full version keeps ONLY the exact version a site runs (ATL2 = TCC 3.1 keeps
-- rspl_rev 3.1 and drops 2.2 / 3.0 / 4.0). Applied ONLY to non-USP/URL. For
-- USP/URL the version is in the label, so this is NULL on both sides. Products
-- whose APM rspl_rev = 'A' (or whose mapping version has no number) -> NULL ->
-- matched on base product alone.
--
-- machine_count > 0 keeps only active sites. TCIS is excluded (version cannot
-- be reconciled with the APM table). HOU6 has a known upstream issue (lists
-- multiple versions per product) but is intentionally included.
target_sites AS (
  SELECT DISTINCT
    site,
    CASE
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = '6.EU'  THEN 'USP_EU'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = '6.NA'  THEN 'USP'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = 'B1'    THEN 'USP_B1'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = 'B1+LR' THEN 'USP_B1'
      WHEN UPPER(TRIM(product)) = 'USP'                                            THEN 'USP'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'C'     THEN 'URL Rev C'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'C.2'   THEN 'URL Rev C2'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'D'     THEN 'URL Rev D'
      WHEN UPPER(TRIM(product)) = 'SPARROW'                                        THEN 'Sparrow 2.0'
      ELSE TRIM(product_version)
    END AS product,
    -- Base product used as the JOIN key against the APM table (which only has
    -- the bare product name). USP/URL use their standardized label as the key
    -- (the APM side rebuilds the same label); all others use the bare name.
    CASE
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = '6.EU'  THEN 'USP_EU'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = '6.NA'  THEN 'USP'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = 'B1'    THEN 'USP_B1'
      WHEN UPPER(TRIM(product)) = 'USP' AND UPPER(TRIM(product_version)) = 'B1+LR' THEN 'USP_B1'
      WHEN UPPER(TRIM(product)) = 'USP'                                            THEN 'USP'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'C'     THEN 'URL Rev C'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'C.2'   THEN 'URL Rev C2'
      WHEN UPPER(TRIM(product)) = 'URL' AND UPPER(TRIM(product_version)) = 'D'     THEN 'URL Rev D'
      ELSE UPPER(TRIM(product))
    END AS base_product,
    CASE
      WHEN UPPER(TRIM(product)) IN ('USP', 'URL') THEN NULL
      ELSE NULLIF(REGEXP_EXTRACT(TRIM(product_version), '([0-9]+(\.[0-9]+)?)', 1), '')
    END AS version_num
  FROM "andes"."bads.rts_site_to_product_mapping"
  WHERE machine_count > 0
    -- TCIS excluded: its version cannot be reconciled with the APM table
    -- (mapping has no numeric version; APM has rspl_rev 4.0). Dropping it from
    -- the allowlist keeps TCIS out of the RSPL/APM analysis entirely.
    AND UPPER(TRIM(product)) <> 'TCIS'
),

valid_site_product AS (
  SELECT DISTINCT site, product, base_product, version_num FROM target_sites
),

-- Raw APM table joined to the authoritative site->product mapping.
-- The APM table only knows a bare product (TCC, SAS, ...) + rspl_rev, so it
-- cannot by itself reconstruct a fine label like 'TCC 3.1'. Instead we join to
-- valid_site_product on site + a reconciled product key + major version, and
-- take the authoritative label (v.product) from the mapping table.
--
-- Reconciled APM-side key:
--   * USP/URL   -> the explicit standardized label (version lives in the label),
--                  major version = NULL (matches the mapping's NULL).
--   * all others -> base product UPPER(d.product), with major version = leading
--                   integer of rspl_rev ('3' -> 3, '4.0' -> 4, 'A' -> NULL).
--     This drops wrong-version rows (e.g. a TCC-3 site's stray TCC 4.0 rows).
layer1_corrected AS (
  SELECT
    d.site,
    -- Authoritative label from the mapping table (fine version, e.g. 'TCC 3.1').
    v.product AS product,
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
    d.multiple_apns,
    -- Row-level rollup: 1 if the MPN has ANY of the five APM setup problems.
    CASE
      WHEN d.missing_mpn_network = 1
        OR d.missing_mpn_site    = 1
        OR d.missing_crn         = 1
        OR d.incorrect_mpn       = 1
        OR d.multiple_apns       = 1
      THEN 1 ELSE 0
    END AS incorrect_apm_setup
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details" d
    INNER JOIN valid_site_product v
      ON v.site = d.site
     -- Match the mapping-table BASE product key (not the fine label):
     --  * USP/URL  -> the explicit standardized label (version lives in label)
     --  * others   -> the bare product name
     AND v.base_product = CASE
           WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.region))  = 'EU'          THEN 'USP_EU'
           WHEN UPPER(TRIM(d.product)) = 'USP' AND UPPER(TRIM(d.version)) = 'B1'          THEN 'USP_B1'
           WHEN UPPER(TRIM(d.product)) = 'USP'                                            THEN 'USP'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'C'          THEN 'URL Rev C'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) IN ('C2','C.2') THEN 'URL Rev C2'
           WHEN UPPER(TRIM(d.product)) = 'URL' AND UPPER(TRIM(d.rspl_rev)) = 'D'          THEN 'URL Rev D'
           ELSE UPPER(TRIM(d.product))
         END
     -- Full-version filter: enforced ONLY when BOTH sides carry a numeric
     -- version. The APM rspl_rev is fine-grained (2.2 / 3.0 / 3.1 / 4.0), so an
     -- exact match keeps only the version the site runs (ATL2 = TCC 3.1 keeps
     -- rspl_rev 3.1, drops 2.2 / 3.0 / 4.0). When either side has no number
     -- (USP/URL, 'A'-rev products like SPARROW, or mapping versions with no
     -- digit like 'TCIS'), the version is not comparable -> fall back to
     -- matching on base product alone.
     AND (
          v.version_num IS NULL
       OR NULLIF(REGEXP_EXTRACT(TRIM(CAST(d.rspl_rev AS VARCHAR)), '([0-9]+(\.[0-9]+)?)', 1), '') IS NULL
       OR v.version_num
            = NULLIF(REGEXP_EXTRACT(TRIM(CAST(d.rspl_rev AS VARCHAR)), '([0-9]+(\.[0-9]+)?)', 1), '')
         )
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
    MAX(multiple_apns)       AS multiple_apns,
    MAX(incorrect_apm_setup) AS incorrect_apm_setup
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

-- Site + product level data-quality counts: distinct MPNs flagged in each of
-- the five APM setup categories, distinct MPNs with no APN mapped, plus distinct
-- MPNs with any problem (incorrect_apm_setup). Counted from layer1_corrected
-- (all MPNs, including null-APN parts) so the APN fan-out doesn't inflate them.
site_product_dq AS (
  SELECT site, product,
         -- Total distinct MPNs in this site+product (denominator for the rates).
         COUNT(DISTINCT mpn)                                           AS mpn_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_network = 1 THEN mpn END) AS missing_mpn_network_count,
         COUNT(DISTINCT CASE WHEN missing_mpn_site    = 1 THEN mpn END) AS missing_mpn_site_count,
         COUNT(DISTINCT CASE WHEN missing_crn         = 1 THEN mpn END) AS missing_crn_count,
         COUNT(DISTINCT CASE WHEN incorrect_mpn       = 1 THEN mpn END) AS incorrect_mpn_count,
         COUNT(DISTINCT CASE WHEN multiple_apns       = 1 THEN mpn END) AS multiple_apns_count,
         -- Distinct MPNs with no APN mapped (apn normalized to NULL upstream).
         COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)            AS no_apn_mapped_count,
         COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END) AS incorrect_apm_setup_count,
         -- MPNs with at least one APN mapped (counted once per MPN regardless
         -- of how many APNs it maps to).
         COUNT(DISTINCT CASE WHEN apn IS NOT NULL THEN mpn END)        AS mpn_found_count,

         -- Percentage-based APM setup risk (replaces the old count tiers).
         -- Each is a SHARE of the product's distinct MPNs (0..1):
         --   pct_no_apn        = MPNs with no APN mapped / all MPNs
         --   pct_incorrect     = MPNs with any setup error / all MPNs
         -- (overlap allowed: an MPN can be both unmapped and mis-set-up).
         ROUND(1.0 * COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)
               / NULLIF(COUNT(DISTINCT mpn), 0), 4)                    AS pct_no_apn_mapped,
         ROUND(1.0 * COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END)
               / NULLIF(COUNT(DISTINCT mpn), 0), 4)                    AS pct_incorrect_apm_setup,

         -- Combined site+product APM setup risk score, 0..150 scale:
         --   100 * (1.0 * pct_no_apn_mapped + 0.5 * pct_incorrect_apm_setup)
         -- no-APN weighted 2x incorrect-setup (1.0 vs 0.5): an untracked part
         -- is more serious than a mis-configured one.
         ROUND(100.0 * (
                 1.0 * (1.0 * COUNT(DISTINCT CASE WHEN apn IS NULL THEN mpn END)
                        / NULLIF(COUNT(DISTINCT mpn), 0))
               + 0.5 * (1.0 * COUNT(DISTINCT CASE WHEN incorrect_apm_setup = 1 THEN mpn END)
                        / NULLIF(COUNT(DISTINCT mpn), 0))
               ), 2)                                                   AS apm_setup_risk_score
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
layer2 AS (
  SELECT *
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  WHERE snapshot_date = (
    SELECT MAX(snapshot_date)
    FROM "andes"."ar-performance-n-insights.hw_critical_spares_score_base"
  )
),

-- ---------------------------------------------------------------------------
-- Live inventory inputs for Layer-1-only parts (not in Layer 2).
-- Reading r5stock directly lets parts that exist in Layer 1 but not Layer 2
-- still show on-hand / min / max / sto_class.
-- Grain: one row per site + APN. NA is preferred over EU on conflict.
-- ---------------------------------------------------------------------------
l1_stock AS (
  SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart
  FROM (
    SELECT site, sto_part, site_oh_qty, min_level, max_level, sto_class, sto_prefmanufactpart,
           ROW_NUMBER() OVER (PARTITION BY site, sto_part
                              ORDER BY CASE region WHEN 'NA' THEN 1 ELSE 2 END) AS rn
    FROM (
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class)                  AS sto_class,
             MAX(st.sto_prefmanufactpart)       AS sto_prefmanufactpart,
             'NA' AS region
      FROM "andes"."rme-gdl.r5stock_apm_na" st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
      UNION ALL
      SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, st.sto_part,
             MAX(CAST(st.sto_qty AS DOUBLE))    AS site_oh_qty,
             MAX(CAST(st.sto_minlev AS DOUBLE)) AS min_level,
             MAX(CAST(st.sto_maxqty AS DOUBLE)) AS max_level,
             MAX(st.sto_class)                  AS sto_class,
             MAX(st.sto_prefmanufactpart)       AS sto_prefmanufactpart,
             'EU' AS region
      FROM "andes"."rme-gdl.r5stock_apm_eu" st
      GROUP BY SPLIT_PART(st.sto_store, '-', 1), st.sto_part
    ) sto_raw
  ) ranked
  WHERE rn = 1
),

-- Coming/back orders from r5orderlines, per site + APN.
-- Keyed on orl_part = APN (sto_part). Provides back_order_qty for Layer-1-only
-- parts.
l1_coming_order AS (
  SELECT site, sto_part, SUM(orl_ordqty) AS back_order_qty
  FROM (
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_na" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
        ON TRIM(CAST(l.orl_order AS VARCHAR)) = TRIM(CAST(rl.ord_code AS VARCHAR))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
    UNION ALL
    SELECT rl.ord_org AS site, l.orl_part AS sto_part,
           CAST(l.orl_ordqty AS DOUBLE) AS orl_ordqty
    FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
      INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
        ON TRIM(CAST(l.orl_order AS VARCHAR)) = TRIM(CAST(rl.ord_code AS VARCHAR))
    WHERE rl.ord_status = 'A' AND l.orl_status = 'A'
  ) co
  GROUP BY site, sto_part
),

-- Site + product level part count.
-- Counts parts (APNs) by site + product to match the output grain.
-- Uses l1.product directly (no fallback). Layer-2-only parts have NULL product.
-- Used to scale part-level scores to site+product level in QuickSight.
site_product_part_count AS (
  SELECT
    COALESCE(l2.site, l1.site) AS site,
    l1.product,
    COUNT(COALESCE(l2.part, l1.apn)) AS sp_part_count
  FROM layer2 l2
    FULL OUTER JOIN layer1 l1
      ON l1.site = l2.site
     AND l1.apn  = l2.part
  GROUP BY COALESCE(l2.site, l1.site), l1.product
),

-- Site + product level counts for inventory/review status categories.
-- Joins layer2 + layer1 + l1_stock + l1_coming_order to compute the same
-- inventory-based flags used in the final SELECT.
site_product_status_counts AS (
  SELECT
    COALESCE(l2.site, l1.site) AS site,
    l1.product,
    -- MIN/MAX review: stockout_days_yr_min_150d > 0
    COUNT(CASE WHEN COALESCE(l2.stockout_days_yr_min_150d, 0) > 0 THEN 1 END) AS sp_need_min_max_review_count,
    -- Lead time review: stockout_days_yr_rep_150d > 0
    COUNT(CASE WHEN COALESCE(l2.stockout_days_yr_rep_150d, 0) > 0 THEN 1 END) AS sp_need_lead_time_review_count,
    -- Stockout no PO: OH = 0 AND no PO (only for parts with APN)
    COUNT(CASE 
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 
      THEN 1 
    END) AS sp_stockout_no_po_count,
    -- Stockout with PO: OH = 0 AND PO exists
    COUNT(CASE 
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 
      THEN 1 
    END) AS sp_stockout_with_po_count,
    -- Below MIN no PO: 0 < OH <= MIN AND no PO
    COUNT(CASE 
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 
      THEN 1 
    END) AS sp_below_min_no_po_count,
    -- Below MIN with PO: 0 < OH <= MIN AND PO exists
    COUNT(CASE 
      WHEN COALESCE(l2.part, l1.apn) IS NOT NULL
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
       AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
       AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 
      THEN 1 
    END) AS sp_below_min_with_po_count
  FROM layer2 l2
    FULL OUTER JOIN layer1 l1
      ON l1.site = l2.site
     AND l1.apn  = l2.part
    LEFT JOIN l1_stock ls
      ON ls.site = COALESCE(l2.site, l1.site)
     AND ls.sto_part = COALESCE(l2.part, l1.apn)
    LEFT JOIN l1_coming_order lco
      ON lco.site = COALESCE(l2.site, l1.site)
     AND lco.sto_part = COALESCE(l2.part, l1.apn)
  GROUP BY COALESCE(l2.site, l1.site), l1.product
)

SELECT
  -- Snapshot date stamped as the run date (today), populated for every row.
  CURRENT_DATE AS snapshot_date,

  -- Key columns COALESCEd across both sides.
  COALESCE(l2.site, l1.site) AS site,
  COALESCE(l2.part, l1.apn)  AS part,

  -- Layer 2 score columns (NULL for Layer-1-only parts).
  -- Region derived from rts_rcc_facilities.address_country: NA for US/Canada/Mexico, EU otherwise.
  COALESCE(
    l2.region,
    CASE WHEN fac.address_country IN ('United States', 'US', 'USA', 'Canada', 'Mexico') THEN 'NA' ELSE 'EU' END
  ) AS region,
  l2.amazon_pn,
  l2.part_description,
  l2.cat_ref_list,
  l2.product_list,
  l2.building_type,
  -- Inventory columns: prefer Layer 2 and fall back to live l1_stock so
  -- Layer-1-only parts (absent from Layer 2) still show on-hand / min / max / class.
  COALESCE(l2.sto_class, ls.sto_class)     AS sto_class,
  COALESCE(l2.site_oh_qty, ls.site_oh_qty) AS site_oh_qty,
  COALESCE(l2.min_level, ls.min_level)     AS min_level,
  COALESCE(l2.max_level, ls.max_level)     AS max_level,
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
  -- Back order qty: prefer Layer 2 and fall back to live l1_coming_order for
  -- Layer-1-only parts.
  COALESCE(l2.back_order_qty, lco.back_order_qty) AS back_order_qty,
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

  -- Situational tier indicators (1/0 flags for each tier).
  -- NULL for parts with no APN (can't look up inventory without APN).
  -- NULL OH is treated as stockout (no stock record = effectively zero on hand).
  -- OH = 0 or NULL AND no PO (most critical)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS is_stockout_no_po,
  -- OH = 0 or NULL (PO exists)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS is_stockout_with_po,
  -- 0 < OH ≤ MIN AND no PO
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1
    ELSE 0
  END AS is_below_min_no_po,
  -- 0 < OH ≤ MIN (PO exists)
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) > 0
         AND COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) > 0 THEN 1
    ELSE 0
  END AS is_below_min_with_po,

  -- Situational score (tiered severity, 0-1 scale) — computed from the COALESCEd
  -- inventory columns so both Layer-2 and Layer-1-only parts get a score.
  -- NULL for parts with no APN (can't look up inventory without APN).
  -- NULL OH is treated as stockout (no stock record = effectively zero on hand).
  --   1.00  on-hand = 0 or NULL AND no PO
  --   0.75  on-hand = 0 or NULL (PO exists)
  --   0.50  0 < on-hand <= MIN AND no PO
  --   0.25  0 < on-hand <= MIN (PO exists)
  --   0.00  on-hand > MIN
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
         AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
    WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
    ELSE 0.00
  END AS situational_score_150d,

  -- Situational score criticality = sto_class weight × situational tier.
  -- NULL for parts with no APN.
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    ELSE ROUND(
      (CASE COALESCE(l2.sto_class, ls.sto_class)
         WHEN '01 HIGH' THEN 1.0
         WHEN '02 MED'  THEN 0.75
         WHEN '03 LOW'  THEN 0.5
         ELSE 0.25
       END)
      * CASE
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
          ELSE 0.00
        END
    , 4)
  END AS situational_score_criticality_150d,

  -- Overall score criticality = situational criticality + structural criticality.
  -- NULL for parts with no APN.
  CASE
    WHEN COALESCE(l2.part, l1.apn) IS NULL THEN NULL
    ELSE GREATEST(0.0, ROUND(
      (CASE COALESCE(l2.sto_class, ls.sto_class)
         WHEN '01 HIGH' THEN 1.0
         WHEN '02 MED'  THEN 0.75
         WHEN '03 LOW'  THEN 0.5
         ELSE 0.25
       END)
      * CASE
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 1.00
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) = 0 THEN 0.75
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0)
               AND COALESCE(l2.back_order_qty, lco.back_order_qty, 0.0) = 0 THEN 0.50
          WHEN COALESCE(l2.site_oh_qty, ls.site_oh_qty, 0.0) <= COALESCE(l2.min_level, ls.min_level, 0.0) THEN 0.25
          ELSE 0.00
        END
      + COALESCE(l2.structural_risk_combo_criticality_150d, 0.0)
    , 4))
  END AS overall_score_criticality_150d,

  COALESCE(l2.ar_region, fac.region) AS ar_region,
  COALESCE(l2.subregion, fac.subregion) AS subregion,
  COALESCE(l2.type, fac.type) AS type,
  COALESCE(l2.subtype, fac.subtype) AS subtype,

  -- Layer 1 enrichment (NULL for Layer-2-only parts).
  COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
  CASE WHEN l2.part IS NOT NULL THEN 1 ELSE 0 END AS in_score_base,
  -- Corrected Layer 1 product. NULL for Layer-2-only rows (no fallback).
  l1.product,
  l1.mpn,
  l1.catalogue_reference,
  l1.sto_prefmanufactpart,
  -- APM MPN from r5stock (sto_prefmanufactpart). Falls back for Layer-1-only parts.
  ls.sto_prefmanufactpart AS apm_mpn,
  l1.sto_min_lev,
  l1.sto_leadtime,
  l1.not_set_up_in_apm,
  l1.missing_mpn_network,
  l1.missing_mpn_site,
  l1.missing_crn,
  l1.incorrect_mpn,
  l1.multiple_apns,
  -- Row-level: 1 if this MPN has any of the five APM setup problems.
  l1.incorrect_apm_setup,

  -- Site + product level counts of distinct flagged MPNs per category.
  COALESCE(pd.missing_mpn_network_count, 0) AS sp_missing_mpn_network_count,
  COALESCE(pd.missing_mpn_site_count, 0)    AS sp_missing_mpn_site_count,
  COALESCE(pd.missing_crn_count, 0)         AS sp_missing_crn_count,
  COALESCE(pd.incorrect_mpn_count, 0)       AS sp_incorrect_mpn_count,
  COALESCE(pd.multiple_apns_count, 0)       AS sp_multiple_apns_count,
  COALESCE(pd.no_apn_mapped_count, 0)       AS sp_no_apn_mapped_count,
  COALESCE(pd.incorrect_apm_setup_count, 0) AS sp_incorrect_apm_setup_count,
  -- Distinct MPNs with at least one APN mapped at this site+product.
  COALESCE(pd.mpn_found_count, 0)           AS sp_mpn_found_count,
  -- Total distinct MPNs at this site+product (denominator for the rates below).
  COALESCE(pd.mpn_count, 0)                 AS sp_mpn_count,
  -- Percentage-based APM setup risk (share of MPNs, 0..1).
  COALESCE(pd.pct_no_apn_mapped, 0)         AS sp_pct_no_apn_mapped,
  COALESCE(pd.pct_incorrect_apm_setup, 0)   AS sp_pct_incorrect_apm_setup,
  -- Combined site+product APM setup risk = 100*(1.0*pct_no_apn + 0.5*pct_incorrect).
  COALESCE(pd.apm_setup_risk_score, 0)      AS sp_apm_setup_risk_score,

  -- Distinct MPNs not set up in APM at this site (across all products).
  COALESCE(g.site_not_set_up_mpn_count, 0) AS site_not_set_up_mpn_count,
  -- Site-level APM penalty (5 when site has >= 10 MPNs not set up in APM, else 0).
  COALESCE(g.site_apm_penalty, 0) AS site_apm_penalty,
  -- Distinct MPNs not set up in APM for this site + product.
  COALESCE(gp.not_set_up_mpn_count, 0) AS not_set_up_mpn_count,

  -- Site + product level part count (for scaling part-level scores).
  COALESCE(spc.sp_part_count, 0) AS sp_part_count,

  -- Site + product level counts for inventory/review status categories.
  COALESCE(spsc.sp_need_min_max_review_count, 0) AS sp_need_min_max_review_count,
  COALESCE(spsc.sp_need_lead_time_review_count, 0) AS sp_need_lead_time_review_count,
  COALESCE(spsc.sp_stockout_no_po_count, 0) AS sp_stockout_no_po_count,
  COALESCE(spsc.sp_stockout_with_po_count, 0) AS sp_stockout_with_po_count,
  COALESCE(spsc.sp_below_min_no_po_count, 0) AS sp_below_min_no_po_count,
  COALESCE(spsc.sp_below_min_with_po_count, 0) AS sp_below_min_with_po_count
FROM layer2 l2
  FULL OUTER JOIN layer1 l1
    ON l1.site = l2.site
   AND l1.apn  = l2.part
  LEFT JOIN site_apm_gap g
    ON g.site = COALESCE(l2.site, l1.site)
  LEFT JOIN site_product_apm_gap gp
    ON gp.site = COALESCE(l2.site, l1.site)
   AND gp.product = l1.product
  LEFT JOIN site_product_dq pd
    ON pd.site = COALESCE(l2.site, l1.site)
   AND pd.product = l1.product
  -- Live inventory + coming-order inputs for Layer-1-only parts, keyed on
  -- the resolved site + part (works for Layer-2-only, Layer-1-only, and both).
  LEFT JOIN l1_stock ls
    ON ls.site = COALESCE(l2.site, l1.site)
   AND ls.sto_part = COALESCE(l2.part, l1.apn)
  LEFT JOIN l1_coming_order lco
    ON lco.site = COALESCE(l2.site, l1.site)
   AND lco.sto_part = COALESCE(l2.part, l1.apn)
  LEFT JOIN site_product_part_count spc
    ON spc.site = COALESCE(l2.site, l1.site)
   AND spc.product = l1.product
  LEFT JOIN site_product_status_counts spsc
    ON spsc.site = COALESCE(l2.site, l1.site)
   AND spsc.product = l1.product
  -- Facility attributes for ar_region, subregion, type, subtype.
  LEFT JOIN "andes"."ar-performance-n-insights.rts_rcc_facilities" fac
    ON fac.code = COALESCE(l2.site, l1.site)
