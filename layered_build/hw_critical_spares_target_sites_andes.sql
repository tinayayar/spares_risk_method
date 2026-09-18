-- hw_critical_spares_target_sites_andes.sql
-- Reference table mapping sites to products (USP, URL Rev C/C2/D).
-- 
-- This table reads directly from a CSV file in S3.
-- To update the site list:
--   1. Edit the CSV file: hw_critical_spares_target_sites.csv
--   2. Upload to S3: s3://[your-bucket]/reference-data/hw_critical_spares_target_sites.csv
--   3. Re-run the Andes job (or wait for scheduled refresh)
--
-- CSV columns: site, product
-- Example rows:
--   ABQ1,USP
--   BOS3,URL Rev D

SELECT
  CAST(site AS STRING)    AS site,
  CAST(product AS STRING) AS product
FROM RSPL_site_product
WHERE site != 'site'  -- Skip header row
