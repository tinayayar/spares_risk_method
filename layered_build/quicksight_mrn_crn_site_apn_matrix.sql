-- quicksight_mrn_crn_site_apn_matrix.sql
-- QuickSight dataset for a PIVOT TABLE (MRN+CRN x site -> APN mapping),
-- filterable by product + rspl_rev.
-- Built ONLY from the APM setup details table:
--   "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
--
-- Target visual: QuickSight "Pivot table"
--   mrn        -> Rows  (MRN = mpn)
--   crn        -> Rows  (CRN = catalogue_reference)   [second row field]
--   site       -> Columns
--   apn_list   -> Values (aggregation = Min or Max; the value is already the
--                 full comma-separated APN string per cell, so Min/Max just
--                 passes it through unchanged)
--
-- Filter controls (dashboard):
--   product    -> add a control; e.g. product = 'URL'
--   rspl_rev   -> add a control; e.g. rspl_rev = 'C'
--   Selecting product=URL, rspl_rev=C restricts the pivot to only the MRN/CRN
--   and APNs that belong to that product revision.
--
-- Grain: one row per product + rspl_rev + mrn + crn + site.
--   Keeping product + rspl_rev in the grain is what lets the QuickSight
--   controls filter the pivot down to a single product revision. A given
--   MRN+CRN can legitimately appear under more than one product/rev, and those
--   stay as separate rows so each selection shows the correct APN set.
--
--   apn_list  = comma-separated distinct valid APNs found for that MRN+CRN at
--               that site (for the selected product/rev). Handles multiple
--               APNs. When NO valid APN exists (only 'N/A' / blank), this shows
--               the literal '(no APN)' -- these are the RED cells (part exists
--               at the site but has no APN mapped in APM).
--   apn_count = number of distinct VALID APNs. 0 for a red cell, 1 for a normal
--               mapping, >1 for a multiple-APN mapping. Drive conditional
--               formatting off this (apn_count = 0 -> red).
--
-- APM setup flags (per cell, aggregated with MAX = "raised for any row in this
-- MRN+CRN+site cell", matching layer1_dedup.sql). 1 = flag raised, 0 = not:
--   multiple_apns, missing_mpn_network, missing_mpn_site, missing_crn,
--   incorrect_mpn
--
-- Blank vs red:
--   * blank cell   = no row at all for that MRN+CRN at that site (not
--                    applicable there).
--   * '(no APN)'   = the MRN+CRN IS set up at that site but every row has a
--                    placeholder APN -> needs an APN mapped (red).

WITH
-- Distinct (product, rspl_rev, site, mrn, crn, apn) facts + raw APM flags.
-- Placeholder APNs ('N/A' / blank) normalized to NULL so they can be told
-- apart from real APNs. Rows are KEPT (not dropped) so placeholder-only
-- mappings still surface as red cells.
apm AS (
  SELECT DISTINCT
    CAST(product  AS VARCHAR)                 AS product,
    CAST(rspl_rev AS VARCHAR)                 AS rspl_rev,
    site,
    mpn                                       AS mrn,
    catalogue_reference                       AS crn,
    CASE
      WHEN UPPER(TRIM(CAST(apn AS VARCHAR))) IN ('N/A', 'NA', '') THEN NULL
      ELSE CAST(apn AS VARCHAR)
    END                                       AS apn,
    CAST(multiple_apns       AS INTEGER)      AS multiple_apns,
    CAST(missing_mpn_network AS INTEGER)      AS missing_mpn_network,
    CAST(missing_mpn_site    AS INTEGER)      AS missing_mpn_site,
    CAST(missing_crn         AS INTEGER)      AS missing_crn,
    CAST(incorrect_mpn       AS INTEGER)      AS incorrect_mpn
  FROM "andes"."ar-performance-n-insights.hw_critical_spares_apm_setup_details"
)

SELECT
  product,
  rspl_rev,
  mrn,
  crn,
  site,
  -- Valid APNs for this product/rev + MRN+CRN at this site.
  -- ARRAY_AGG(DISTINCT apn) drops NULLs, so a placeholder-only cell aggregates
  -- to an empty array -> ARRAY_JOIN returns '' -> we surface '(no APN)'.
  CASE
    WHEN COUNT(apn) = 0 THEN '(no APN)'
    ELSE ARRAY_JOIN(ARRAY_AGG(DISTINCT apn), ', ')
  END                                         AS apn_list,
  -- Count of distinct VALID APNs (0 = red cell).
  COUNT(DISTINCT apn)                         AS apn_count,
  -- APM setup flags: 1 if raised in any raw row of this cell, else 0.
  MAX(multiple_apns)                          AS multiple_apns,
  MAX(missing_mpn_network)                    AS missing_mpn_network,
  MAX(missing_mpn_site)                       AS missing_mpn_site,
  MAX(missing_crn)                            AS missing_crn,
  MAX(incorrect_mpn)                          AS incorrect_mpn
FROM apm
GROUP BY product, rspl_rev, mrn, crn, site
