-- quicksight_mrn_crn_site_apn_matrix_qs.sql
-- QuickSight version of quicksight_mrn_crn_site_apn_matrix.sql.
-- Identical logic; the table reference uses the QuickSight / Athena catalog form
--   andes_bi_ext."ar-performance-n-insights".<table>
-- instead of "andes"."ar-performance-n-insights.<table>".
--
-- PIVOT TABLE (MRN+CRN x site -> APN mapping), filterable by product + rspl_rev.
-- Built ONLY from the APM setup details table.
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
--
-- NOTE ON DIALECT: the andes_bi_ext catalog is Redshift (Redshift Spectrum
-- external schema), NOT Athena/Presto. Redshift has no ARRAY_AGG / ARRAY_JOIN;
-- the string-aggregation function is LISTAGG. This file therefore uses LISTAGG,
-- which is the only structural difference from the Athena base file
-- (quicksight_mrn_crn_site_apn_matrix.sql).
--
-- Base table:
--   apm setup details : andes_bi_ext."ar-performance-n-insights".hw_critical_spares_apm_setup_details

WITH
-- Distinct (product, rspl_rev, site, mrn, crn, apn) facts. Placeholder APNs
-- ('N/A' / blank) normalized to NULL so they can be told apart from real APNs.
-- Rows are KEPT (not dropped) so placeholder-only mappings still surface as
-- red cells. SELECT DISTINCT here also collapses duplicate (…, apn) rows, so
-- LISTAGG below does not need its own DISTINCT.
--
-- Dialect constraints on the andes_bi_ext (federated) engine:
--   * no ARRAY_AGG / ARRAY_JOIN  -> use LISTAGG
--   * LISTAGG cannot sit next to a DISTINCT aggregate in the same SELECT
--   * window functions (… OVER (…)) are NOT supported
-- So the string and the count are produced in TWO separate GROUP BY queries
-- (each with only one kind of aggregate) and joined back together.
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
  FROM andes_bi_ext."ar-performance-n-insights".hw_critical_spares_apm_setup_details
),

-- One row per cell: the comma-separated APN string (LISTAGG only, no DISTINCT
-- aggregate alongside it). APNs already de-duplicated by the apm CTE.
apn_strings AS (
  SELECT
    product, rspl_rev, mrn, crn, site,
    LISTAGG(apn, ', ') WITHIN GROUP (ORDER BY apn) AS apn_joined
  FROM apm
  GROUP BY product, rspl_rev, mrn, crn, site
),

-- One row per cell: the distinct valid APN count plus the MAX of each APM flag
-- (no LISTAGG here, so COUNT DISTINCT and MAX can coexist).
apn_counts AS (
  SELECT
    product, rspl_rev, mrn, crn, site,
    COUNT(DISTINCT apn)      AS apn_count,
    MAX(multiple_apns)       AS multiple_apns,
    MAX(missing_mpn_network) AS missing_mpn_network,
    MAX(missing_mpn_site)    AS missing_mpn_site,
    MAX(missing_crn)         AS missing_crn,
    MAX(incorrect_mpn)       AS incorrect_mpn
  FROM apm
  GROUP BY product, rspl_rev, mrn, crn, site
)

SELECT
  c.product,
  c.rspl_rev,
  c.mrn,
  c.crn,
  c.site,
  -- '(no APN)' when the cell has no valid APN (placeholder-only) -> RED cell.
  CASE
    WHEN c.apn_count = 0 THEN '(no APN)'
    ELSE s.apn_joined
  END                                         AS apn_list,
  -- Count of distinct VALID APNs (0 = red cell).
  c.apn_count                                 AS apn_count,
  -- APM setup flags: 1 if raised in any raw row of this cell, else 0.
  c.multiple_apns                             AS multiple_apns,
  c.missing_mpn_network                       AS missing_mpn_network,
  c.missing_mpn_site                          AS missing_mpn_site,
  c.missing_crn                               AS missing_crn,
  c.incorrect_mpn                             AS incorrect_mpn
FROM apn_counts c
  JOIN apn_strings s
    ON  s.product  = c.product
    AND s.rspl_rev = c.rspl_rev
    AND s.mrn      = c.mrn
    AND s.crn      = c.crn
    AND s.site     = c.site
