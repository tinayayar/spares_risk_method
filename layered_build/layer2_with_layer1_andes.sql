-- layer2_with_layer1_andes.sql
-- Layer 2 score-base enriched with Layer 1 (RSPL / APM setup) attributes.
-- ANDES/SDL onboarding version of layer2_with_layer1.sql -- uses bare
-- (unqualified) table names and Spark SQL types, and casts every output column
-- to the exact Andes sink SDL type so the output dataframe schema matches the
-- sink table version schema.
--
-- Base: Layer 2 score base (all snapshots; partitioned by snapshot_date).
-- Enrichment: Layer 1 deduped to one row per site + apn, LEFT JOINed on
--             site + apn. Layer 1 has no date, so the same current setup
--             attributes attach to every historical snapshot of a part.
--
--   * every Layer 2 (scored) part is kept
--   * product / product_rev are NULL when the part is not in Layer 1
--   * is_rspl_apn is COALESCEd to 0 for parts not found in Layer 1
--   * product / product_rev are aggregated (distinct, comma separated) so the
--     output stays ONE row per site + apn
--
-- Onboarded input datasets (assumed bare names -> original andes source):
--   hw_critical_spares_score_base        <- andes."ar-performance-n-insights.hw_critical_spares_score_base"
--   hw_critical_spares_apm_setup_details <- andes."ar-performance-n-insights.hw_critical_spares_apm_setup_details"

WITH
-- Layer 1 deduped to one row per site + apn (see layer1_dedup_site_apn.sql).
layer1 AS (
  SELECT
    site,
    apn,
    1 AS is_rspl_apn,
    -- Raw product(s) from Layer 1, deduped to one value per site + apn.
    ARRAY_JOIN(
      ARRAY_AGG(DISTINCT NULLIF(TRIM(CAST(product AS STRING)), '')),
      ', '
    ) AS product,
    ARRAY_JOIN(
      ARRAY_AGG(DISTINCT
        TRIM(CONCAT(
          COALESCE(CAST(product  AS STRING), ''),
          ' ',
          COALESCE(CAST(rspl_rev AS STRING), '')
        ))
      ),
      ', '
    ) AS product_rev
  FROM (
    -- Normalize placeholder apn ('N/A' / blank) to a real NULL before grouping;
    -- rspl_rev = 'N/A' -> blank so it does not appear literally in product_rev.
    SELECT
      site,
      product,
      CASE
        WHEN UPPER(TRIM(CAST(rspl_rev AS STRING))) IN ('N/A', 'NA') THEN ''
        ELSE rspl_rev
      END AS rspl_rev,
      CASE
        WHEN UPPER(TRIM(CAST(apn AS STRING))) IN ('N/A', 'NA', '') THEN NULL
        ELSE apn
      END AS apn
    FROM hw_critical_spares_apm_setup_details
  ) src
  WHERE apn IS NOT NULL
  GROUP BY site, apn
),

-- Layer 2 score base, ALL snapshots retained.
layer2 AS (
  SELECT *
  FROM hw_critical_spares_score_base
),

enriched AS (
  SELECT
    l2.*,
    COALESCE(l1.is_rspl_apn, 0) AS is_rspl_apn,
    l1.product,
    l1.product_rev
  FROM layer2 l2
    LEFT JOIN layer1 l1
      ON l1.site = l2.site
     AND l1.apn  = l2.part
)

-- Cast every column to the exact Andes sink SDL type.
SELECT
  CAST(snapshot_date AS TIMESTAMP)                       AS snapshot_date,
  CAST(site AS STRING)                                   AS site,
  CAST(region AS STRING)                                 AS region,
  CAST(part AS STRING)                                   AS part,
  CAST(amazon_pn AS STRING)                              AS amazon_pn,
  CAST(part_description AS STRING)                        AS part_description,
  CAST(cat_ref_list AS STRING)                           AS cat_ref_list,
  CAST(building_type AS STRING)                          AS building_type,
  CAST(sto_class AS STRING)                              AS sto_class,
  CAST(site_oh_qty AS DECIMAL(15,4))                     AS site_oh_qty,
  CAST(min_level AS DECIMAL(15,4))                       AS min_level,
  CAST(max_level AS DECIMAL(15,4))                       AS max_level,
  CAST(supplier_lead_time AS DECIMAL(15,4))              AS supplier_lead_time,
  CAST(replenishment_time AS DECIMAL(15,4))              AS replenishment_time,
  CAST(source AS STRING)                                 AS source,
  CAST(order_count AS INT)                               AS order_count,
  CAST(avg_rep_time_days AS DECIMAL(15,4))               AS avg_rep_time_days,
  CAST(min_rep_time_days AS INT)                         AS min_rep_time_days,
  CAST(max_rep_time_days AS INT)                         AS max_rep_time_days,
  CAST(last_received_date AS TIMESTAMP)                  AS last_received_date,
  CAST(last_30d_order AS DECIMAL(15,4))                  AS last_30d_order,
  CAST(last_60d_order AS DECIMAL(15,4))                  AS last_60d_order,
  CAST(last_90d_order AS DECIMAL(15,4))                  AS last_90d_order,
  CAST(last_120d_order AS DECIMAL(15,4))                 AS last_120d_order,
  CAST(last_150d_order AS DECIMAL(15,4))                 AS last_150d_order,
  CAST(last_180d_order AS DECIMAL(15,4))                 AS last_180d_order,
  CAST(last_365d_order AS DECIMAL(15,4))                 AS last_365d_order,
  CAST(open_order_count AS INT)                          AS open_order_count,
  CAST(back_order_qty AS DECIMAL(15,4))                  AS back_order_qty,
  CAST(nearest_po_number AS STRING)                      AS nearest_po_number,
  CAST(order_inaction_flag AS INT)                       AS order_inaction_flag,
  CAST(trend_ratio AS DECIMAL(15,4))                     AS trend_ratio,
  CAST(consumed_150d AS DECIMAL(15,4))                   AS consumed_150d,
  CAST(consumption_rate_150d AS DECIMAL(15,4))           AS consumption_rate_150d,
  CAST(replenishment_demand_150d AS DECIMAL(15,4))       AS replenishment_demand_150d,
  CAST(coverage_150d AS DECIMAL(15,4))                   AS coverage_150d,
  CAST(stockout_fraction_150d AS DECIMAL(15,4))          AS stockout_fraction_150d,
  CAST(stockout_days_per_cycle_150d AS DECIMAL(15,4))    AS stockout_days_per_cycle_150d,
  CAST(cycle_length_days_150d AS DECIMAL(15,4))          AS cycle_length_days_150d,
  CAST(cycles_per_year_150d AS DECIMAL(15,4))            AS cycles_per_year_150d,
  CAST(stockout_days_yr_min_150d AS DECIMAL(15,4))       AS stockout_days_yr_min_150d,
  CAST(stockout_days_min_rep_150d AS DECIMAL(15,4))      AS stockout_days_min_rep_150d,
  CAST(combined_stockout_days_yr_150d AS DECIMAL(15,4))  AS combined_stockout_days_yr_150d,
  CAST(structural_risk_combo_criticality_150d AS DECIMAL(15,4)) AS structural_risk_combo_criticality_150d,
  CAST(days_of_supply_150d AS DECIMAL(15,4))             AS days_of_supply_150d,
  CAST(depletion_date_150d AS TIMESTAMP)                 AS depletion_date_150d,
  CAST(projected_order_date_150d AS TIMESTAMP)           AS projected_order_date_150d,
  CAST(stockout_days_yr_rep_150d AS DECIMAL(15,4))       AS stockout_days_yr_rep_150d,
  CAST(adj_days_of_supply_150d AS DECIMAL(15,4))         AS adj_days_of_supply_150d,
  CAST(situational_score_150d AS DECIMAL(15,4))          AS situational_score_150d,
  CAST(situational_score_criticality_150d AS DECIMAL(15,4)) AS situational_score_criticality_150d,
  CAST(overall_score_criticality_150d AS DECIMAL(15,4))  AS overall_score_criticality_150d,
  CAST(ar_region AS STRING)                              AS ar_region,
  CAST(subregion AS STRING)                              AS subregion,
  CAST(type AS STRING)                                   AS type,
  CAST(subtype AS STRING)                                AS subtype,

  -- Layer 1 enrichment columns
  CAST(is_rspl_apn AS INT)                               AS is_rspl_apn,
  CAST(product AS STRING)                                AS product,
  CAST(product_rev AS STRING)                            AS product_rev
FROM enriched
