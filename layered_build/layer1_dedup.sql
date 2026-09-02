-- layer1_dedup.sql
-- Dedup Layer 1 (APM setup details) to one row per part/site.
--
-- Source: "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--   columns: site, product, rspl_rev, mpn, catalogue_reference, apn,
--            sto_prefmanufactpart, sto_min_lev, sto_leadtime,
--            not_set_up_in_apm, missing_mpn_network, missing_mpn_site,
--            missing_crn, incorrect_mpn, multiple_apns
--
-- Target grain: one row per unique  site + product_rev + mpn + catalogue_reference + apn
--   product_rev = comma-separated distinct combination of product + rspl_rev
--                 (e.g. "URL C, URL C2")
--
-- Because product and rspl_rev are collapsed into product_rev, we group by
-- site + mpn + catalogue_reference + apn and aggregate product_rev within
-- each group. Flag columns are collapsed with MAX so that a raised flag (1)
-- in any duplicate row surfaces for the deduped row.

SELECT
  site,
  mpn,
  catalogue_reference,
  apn,

  -- product_rev: distinct "product rspl_rev" values, comma separated
  ARRAY_JOIN(
    ARRAY_AGG(DISTINCT
      TRIM(CONCAT(
        COALESCE(CAST(product  AS VARCHAR), ''),
        ' ',
        COALESCE(CAST(rspl_rev AS VARCHAR), '')
      ))
    ),
    ', '
  ) AS product_rev,

  -- Pass-through descriptive field (deterministic pick)
  MAX(sto_prefmanufactpart) AS sto_prefmanufactpart,
  MAX(CAST(sto_min_lev  AS DOUBLE)) AS sto_min_lev,
  MAX(CAST(sto_leadtime AS DOUBLE)) AS sto_leadtime,

  -- Flags: 1 if raised in any duplicate row
  MAX(CAST(not_set_up_in_apm   AS INTEGER)) AS not_set_up_in_apm,
  MAX(CAST(missing_mpn_network AS INTEGER)) AS missing_mpn_network,
  MAX(CAST(missing_mpn_site    AS INTEGER)) AS missing_mpn_site,
  MAX(CAST(missing_crn         AS INTEGER)) AS missing_crn,
  MAX(CAST(incorrect_mpn       AS INTEGER)) AS incorrect_mpn,
  MAX(CAST(multiple_apns       AS INTEGER)) AS multiple_apns

FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
GROUP BY site, mpn, catalogue_reference, apn
