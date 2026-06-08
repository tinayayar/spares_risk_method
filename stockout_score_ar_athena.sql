-- stockout_score_ar_athena.sql
-- Stockout Score Calculation — ALL parts across NA and EU sites
-- Athena variant — uses "andes"."rme-gdl.tablename" schema prefix.
-- Part inclusion aligned with replacements_athena.sql:
--   NA suppliers: ('11115682','13294497')
--   EU suppliers: ('11115682','13294497','39418040')
--
-- Methodology (all lead times in days, 150d consumption window):
--   replenishment_time     = supplier_lead_time
--   replenishment_demand   = consumption_rate * replenishment_time
--   coverage               = min / replenishment_demand (capped at 1.0)
--   stockout_fraction      = 1 - coverage
--   stockout_days_per_cycle= stockout_fraction * replenishment_time
--   cycle_length_days      = (max - min) / consumption_rate
--   cycles_per_year        = 365 / cycle_length_days
--   total_stockout_days    = cycles_per_year * stockout_days_per_cycle
--   annual_stockout_pct    = total_stockout_days / 365 * 100
--   suggested_score        = annual_stockout_pct

WITH
-- Site building type lookup
site_building_type AS (
  SELECT DISTINCT warehouse AS site, building_type
  FROM (
    SELECT warehouse, building_type
    FROM "andes"."ardatalake.ardl_common_prodna__warehouses_enhanced_lookup"
    WHERE building_type IS NOT NULL
    UNION ALL
    SELECT warehouse, building_type
    FROM "andes"."ardatalake.ardl_common_prodeu__warehouses_enhanced_lookup"
    WHERE building_type IS NOT NULL
  ) wh
),

-- Part description from catalogue
part_info AS (
  SELECT cat_part AS sto_part,
         MAX(cat_desc) AS part_description,
         region
  FROM (
    SELECT cat_part, cat_desc, 'NA' AS region
    FROM "andes"."rme-gdl.r5catalogue_apm_na"
    WHERE SUBSTRING(cat_supplier,1,8) IN ('11115682','13294497')
      AND cat_desc IS NOT NULL
    UNION ALL
    SELECT cat_part, cat_desc, 'EU' AS region
    FROM "andes"."rme-gdl.r5catalogue_eu"
    WHERE SUBSTRING(cat_supplier,1,8) IN ('11115682','13294497','39418040')
      AND cat_desc IS NOT NULL
  ) cat_d
  GROUP BY cat_part, region
),

-- Stock levels: min/max/current per site
stock AS (
  SELECT site, region, sto_part,
         MAX(min_level)   AS min_level,
         MAX(max_level)   AS max_level,
         SUM(current_qty) AS current_qty,
         MAX(sto_class)   AS sto_class
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site,
           sto_part,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE)    AS current_qty,
           sto_class,
           'NA' AS region
    FROM "andes"."rme-gdl.r5stock_apm_na"
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site,
           sto_part,
           CAST(sto_minlev AS DOUBLE) AS min_level,
           CAST(sto_maxqty AS DOUBLE) AS max_level,
           CAST(sto_qty AS DOUBLE)    AS current_qty,
           sto_class,
           'EU' AS region
    FROM "andes"."rme-gdl.r5stock_apm_eu"
  ) sto_raw
  GROUP BY site, region, sto_part
),

-- Lead time from catalogue via orders placed by each site
order_lead_times AS (
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'NA' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_na" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_na" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN "andes"."rme-gdl.r5catalogue_apm_na"
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
  UNION ALL
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS DOUBLE) AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'EU' AS region
  FROM "andes"."rme-gdl.r5orderlines_apm_eu" l
    INNER JOIN "andes"."rme-gdl.r5orders_apm_eu" rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN "andes"."rme-gdl.r5catalogue_eu"
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
),
lead_time AS (
  SELECT site,
         part_ordered,
         region,
         MAX(supplier_lead_time) AS lead_time
  FROM order_lead_times
  WHERE supplier_lead_time IS NOT NULL
  GROUP BY site, part_ordered, region
),

-- Replacements building blocks — aligned with replacements_athena.sql
repl_events AS (
  SELECT evt_code AS event,
         evt_org  AS organization,
         'NA' AS region
  FROM "andes"."rme-gdl.r5events_apm_na"
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
  UNION
  SELECT evt_code AS event,
         evt_org  AS organization,
         'EU' AS region
  FROM "andes"."rme-gdl.r5events_apm_eu"
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
),
repl_stock AS (
  SELECT sto_part,
         COALESCE(sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(sto_store,'-',1) site,
         'NA' region
  FROM "andes"."rme-gdl.r5stock_apm_na"
  UNION
  SELECT sto_part,
         COALESCE(sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(sto_store,'-',1) site,
         'NA' region
  FROM "andes"."rme-gdl.r5stock_apm_eu"
),
repl_catalogue AS (
  SELECT DISTINCT cat_part,
         UPPER(TRIM(cat_ref)) cat_ref,
         cat_supplier,
         'NA' AS region
  FROM "andes"."rme-gdl.r5catalogue_apm_na"
  WHERE SUBSTRING(cat_supplier,1,8) IN ('11115682','13294497')
    AND cat_ref IS NOT NULL
    AND LENGTH(cat_ref) > 4
  GROUP BY 1, 2, 3
  UNION
  SELECT DISTINCT cat_part,
         UPPER(TRIM(cat_ref)) cat_ref,
         cat_supplier,
         'EU' AS region
  FROM "andes"."rme-gdl.r5catalogue_apm_eu"
  WHERE SUBSTRING(cat_supplier,1,8) IN ('11115682','13294497','39418040')
    AND cat_ref IS NOT NULL
    AND LENGTH(cat_ref) > 4
  GROUP BY 1, 2, 3
),
repl_transactions AS (
  SELECT trl_event,
         trl_part AS amzn_part,
         'NA' AS region,
         MAX(trl_date) AS trl_date,
         SUM(trl_qty) AS trl_qty
  FROM "andes"."rme-gdl.r5translines_apm_na"
  WHERE trl_type = 'I'
    AND trl_part IS NOT NULL
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
  UNION
  SELECT trl_event,
         trl_part AS amzn_part,
         'EU' AS region,
         MAX(trl_date) AS trl_date,
         SUM(trl_qty) AS trl_qty
  FROM "andes"."rme-gdl.r5translines_apm_eu"
  WHERE trl_type = 'I'
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
),
replacements AS (
  SELECT DISTINCT
         e.organization AS site,
         e.region,
         t.amzn_part,
         c.cat_ref,
         DATE(t.trl_date) AS replaced_on,
         e.event AS work_order_id,
         CAST(t.trl_qty AS DOUBLE) AS qty_replaced
  FROM repl_events e
    JOIN repl_transactions t
      ON t.trl_event = e.event
     AND e.region = t.region
    JOIN repl_stock s
      ON t.amzn_part = s.sto_part
     AND s.site = e.organization
    JOIN repl_catalogue c
      ON t.amzn_part = c.cat_part
     AND (s.sto_prefsup = c.cat_supplier OR s.sto_prefsup = 'N')
     AND s.region = c.region
  WHERE t.amzn_part IS NOT NULL
),

-- Part number: strip R-prefix or -FRU suffix from cat_ref
part_number AS (
  SELECT DISTINCT
         amzn_part AS sto_part,
         CASE
           WHEN cat_ref LIKE 'R%' OR cat_ref LIKE '%-FRU'
           THEN REPLACE(REPLACE(cat_ref, '-FRU', ''), 'R', '')
           ELSE cat_ref
         END AS part_number,
         region
  FROM replacements
),

consumption AS (
  SELECT site,
         region,
         amzn_part AS sto_part,
    SUM(CASE WHEN replaced_on >= date_add('day', -30, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_30d,
    SUM(CASE WHEN replaced_on >= date_add('day', -60, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_60d,
    SUM(CASE WHEN replaced_on >= date_add('day', -90, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_90d,
    SUM(CASE WHEN replaced_on >= date_add('day', -120, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_120d,
    SUM(CASE WHEN replaced_on >= date_add('day', -150, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_150d,
    SUM(CASE WHEN replaced_on >= date_add('day', -180, CURRENT_DATE) THEN COALESCE(qty_replaced,0) ELSE 0 END) AS consumed_180d,
    SUM(COALESCE(qty_replaced,0)) AS consumed_365d
  FROM replacements
  GROUP BY site, region, amzn_part
),

-- Site inventory
site_inv_raw AS (
  SELECT *, RANK() OVER (PARTITION BY sto_part, site, region ORDER BY sto_updated DESC) rnk
  FROM (
    SELECT SPLIT_PART(sto_store, '-', 1) AS site,
           'NA' AS region,
           sto_part,
           CAST(sto_qty AS DOUBLE) AS sto_qty,
           CAST(sto_updated AS TIMESTAMP) AS sto_updated
    FROM "andes"."rme-gdl.r5stock_apm_na"
    UNION ALL
    SELECT SPLIT_PART(sto_store, '-', 1) AS site,
           'EU' AS region,
           sto_part,
           CAST(sto_qty AS DOUBLE) AS sto_qty,
           CAST(sto_updated AS TIMESTAMP) AS sto_updated
    FROM "andes"."rme-gdl.r5stock_apm_eu"
  ) sto
),
site_inv_cat AS (
  SELECT DISTINCT cat_part, UPPER(TRIM(cat_ref)) AS cat_ref, 'NA' AS region
  FROM "andes"."rme-gdl.r5catalogue_apm_na"
  WHERE cat_ref IS NOT NULL
  UNION ALL
  SELECT DISTINCT cat_part, UPPER(TRIM(cat_ref)) AS cat_ref, 'EU' AS region
  FROM "andes"."rme-gdl.r5catalogue_eu"
  WHERE cat_ref IS NOT NULL
),
site_inv AS (
  SELECT i.site, i.region, i.sto_part, c.cat_ref,
         SUM(i.sto_qty) AS sto_qty,
         SUM(CASE WHEN c.cat_ref LIKE 'R%' THEN i.sto_qty END) AS r_part_stock
  FROM site_inv_raw i
    JOIN site_inv_cat c ON i.sto_part = c.cat_part AND i.region = c.region
  WHERE i.rnk = 1
  GROUP BY i.site, i.region, i.sto_part, c.cat_ref
),
site_oh_qty AS (
  SELECT site, region, sto_part,
         MAX(site_oh_qty) AS site_oh_qty,
         SUM(r_part_stock_inner) AS r_part_stock
  FROM (
    SELECT site, region, sto_part, cat_ref,
           MAX(sto_qty) AS site_oh_qty,
           MAX(r_part_stock) AS r_part_stock_inner
    FROM site_inv
    GROUP BY site, region, sto_part, cat_ref
  ) per_cat_ref
  GROUP BY site, region, sto_part
),

metrics AS (
  SELECT s.site,
         s.region,
         s.sto_part,
         pi.part_description,
         pn.part_number,
         bt.building_type,
         s.current_qty,
         s.sto_class,
         s.min_level,
         s.max_level,
         lt.lead_time AS supplier_lead_time,
         COALESCE(soh.site_oh_qty, 0.0) AS site_oh_qty,
         COALESCE(soh.r_part_stock, 0.0) AS r_part_stock,
         -- Consumption rates
         c.consumed_30d / 30.0   AS rate_30d,
         c.consumed_60d / 60.0   AS rate_60d,
         c.consumed_90d / 90.0   AS rate_90d,
         c.consumed_120d / 120.0 AS rate_120d,
         c.consumed_150d / 150.0 AS rate_150d,
         c.consumed_180d / 180.0 AS rate_180d,
         c.consumed_365d / 365.0 AS rate_365d,
         c.consumed_30d, c.consumed_60d, c.consumed_90d,
         c.consumed_120d, c.consumed_150d, c.consumed_180d, c.consumed_365d,
         -- Replenishment time
         lt.lead_time AS replenishment_time,
         -- Per-window replenishment demand
         COALESCE(c.consumed_30d / 30.0, 0.0) * lt.lead_time AS replenishment_demand_30d,
         COALESCE(c.consumed_60d / 60.0, 0.0) * lt.lead_time AS replenishment_demand_60d,
         COALESCE(c.consumed_90d / 90.0, 0.0) * lt.lead_time AS replenishment_demand_90d,
         COALESCE(c.consumed_120d / 120.0, 0.0) * lt.lead_time AS replenishment_demand_120d,
         COALESCE(c.consumed_150d / 150.0, 0.0) * lt.lead_time AS replenishment_demand_150d,
         COALESCE(c.consumed_180d / 180.0, 0.0) * lt.lead_time AS replenishment_demand_180d,
         COALESCE(c.consumed_365d / 365.0, 0.0) * lt.lead_time AS replenishment_demand_365d,
         -- Per-window cycle length
         CASE WHEN COALESCE(c.consumed_30d / 30.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_30d / 30.0) ELSE NULL END AS cycle_length_days_30d,
         CASE WHEN COALESCE(c.consumed_60d / 60.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_60d / 60.0) ELSE NULL END AS cycle_length_days_60d,
         CASE WHEN COALESCE(c.consumed_90d / 90.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_90d / 90.0) ELSE NULL END AS cycle_length_days_90d,
         CASE WHEN COALESCE(c.consumed_120d / 120.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_120d / 120.0) ELSE NULL END AS cycle_length_days_120d,
         CASE WHEN COALESCE(c.consumed_150d / 150.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_150d / 150.0) ELSE NULL END AS cycle_length_days_150d,
         CASE WHEN COALESCE(c.consumed_180d / 180.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_180d / 180.0) ELSE NULL END AS cycle_length_days_180d,
         CASE WHEN COALESCE(c.consumed_365d / 365.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_365d / 365.0) ELSE NULL END AS cycle_length_days_365d
  FROM stock s
    LEFT JOIN part_info pi
           ON pi.sto_part = s.sto_part
          AND pi.region   = s.region
    LEFT JOIN part_number pn
           ON pn.sto_part = s.sto_part
          AND pn.region   = s.region
    LEFT JOIN consumption c
           ON c.site     = s.site
          AND c.region   = s.region
          AND c.sto_part = s.sto_part
    LEFT JOIN lead_time lt
           ON lt.site         = s.site
          AND lt.region       = s.region
          AND lt.part_ordered = s.sto_part
    LEFT JOIN site_oh_qty soh
           ON soh.site     = s.site
          AND soh.region   = s.region
          AND soh.sto_part = s.sto_part
    LEFT JOIN site_building_type bt
           ON bt.site = s.site
)
SELECT
  CURRENT_DATE AS snapshot_date,
  site, region, sto_part AS amzn_part, part_description, part_number, building_type,
  current_qty, sto_class,
  site_oh_qty, r_part_stock,
  min_level, max_level,
  supplier_lead_time,
  replenishment_time,

  -- === 30d window ===
  consumed_30d,
  ROUND(rate_30d, 4) AS consumption_rate_30d,
  ROUND(replenishment_demand_30d, 2) AS replenishment_demand_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN LEAST(1.0, min_level / replenishment_demand_30d) ELSE 1.0 END, 4) AS coverage_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_30d) ELSE 0.0 END, 4) AS stockout_fraction_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_30d,
  ROUND(cycle_length_days_30d, 2) AS cycle_length_days_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 THEN 365.0 / cycle_length_days_30d ELSE NULL END, 2) AS cycles_per_year_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 AND replenishment_demand_30d > 0
        THEN (365.0 / cycle_length_days_30d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 AND replenishment_demand_30d > 0
        THEN (365.0 / cycle_length_days_30d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 AND replenishment_demand_30d > 0
        THEN (365.0 / cycle_length_days_30d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_30d,

  -- === 60d window ===
  consumed_60d,
  ROUND(rate_60d, 4) AS consumption_rate_60d,
  ROUND(replenishment_demand_60d, 2) AS replenishment_demand_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN LEAST(1.0, min_level / replenishment_demand_60d) ELSE 1.0 END, 4) AS coverage_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_60d) ELSE 0.0 END, 4) AS stockout_fraction_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_60d,
  ROUND(cycle_length_days_60d, 2) AS cycle_length_days_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 THEN 365.0 / cycle_length_days_60d ELSE NULL END, 2) AS cycles_per_year_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 AND replenishment_demand_60d > 0
        THEN (365.0 / cycle_length_days_60d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 AND replenishment_demand_60d > 0
        THEN (365.0 / cycle_length_days_60d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 AND replenishment_demand_60d > 0
        THEN (365.0 / cycle_length_days_60d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_60d,

  -- === 90d window ===
  consumed_90d,
  ROUND(rate_90d, 4) AS consumption_rate_90d,
  ROUND(replenishment_demand_90d, 2) AS replenishment_demand_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN LEAST(1.0, min_level / replenishment_demand_90d) ELSE 1.0 END, 4) AS coverage_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_90d) ELSE 0.0 END, 4) AS stockout_fraction_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_90d,
  ROUND(cycle_length_days_90d, 2) AS cycle_length_days_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 THEN 365.0 / cycle_length_days_90d ELSE NULL END, 2) AS cycles_per_year_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 AND replenishment_demand_90d > 0
        THEN (365.0 / cycle_length_days_90d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 AND replenishment_demand_90d > 0
        THEN (365.0 / cycle_length_days_90d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 AND replenishment_demand_90d > 0
        THEN (365.0 / cycle_length_days_90d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_90d,

  -- === 120d window ===
  consumed_120d,
  ROUND(rate_120d, 4) AS consumption_rate_120d,
  ROUND(replenishment_demand_120d, 2) AS replenishment_demand_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN LEAST(1.0, min_level / replenishment_demand_120d) ELSE 1.0 END, 4) AS coverage_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_120d) ELSE 0.0 END, 4) AS stockout_fraction_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_120d,
  ROUND(cycle_length_days_120d, 2) AS cycle_length_days_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 THEN 365.0 / cycle_length_days_120d ELSE NULL END, 2) AS cycles_per_year_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 AND replenishment_demand_120d > 0
        THEN (365.0 / cycle_length_days_120d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 AND replenishment_demand_120d > 0
        THEN (365.0 / cycle_length_days_120d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 AND replenishment_demand_120d > 0
        THEN (365.0 / cycle_length_days_120d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_120d,

  -- === 150d window ===
  consumed_150d,
  ROUND(rate_150d, 4) AS consumption_rate_150d,
  ROUND(replenishment_demand_150d, 2) AS replenishment_demand_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN LEAST(1.0, min_level / replenishment_demand_150d) ELSE 1.0 END, 4) AS coverage_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_150d) ELSE 0.0 END, 4) AS stockout_fraction_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_150d,
  ROUND(cycle_length_days_150d, 2) AS cycle_length_days_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 THEN 365.0 / cycle_length_days_150d ELSE NULL END, 2) AS cycles_per_year_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0
        THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0
        THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0
        THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_150d,

  -- === 180d window ===
  consumed_180d,
  ROUND(rate_180d, 4) AS consumption_rate_180d,
  ROUND(replenishment_demand_180d, 2) AS replenishment_demand_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN LEAST(1.0, min_level / replenishment_demand_180d) ELSE 1.0 END, 4) AS coverage_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_180d) ELSE 0.0 END, 4) AS stockout_fraction_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_180d,
  ROUND(cycle_length_days_180d, 2) AS cycle_length_days_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 THEN 365.0 / cycle_length_days_180d ELSE NULL END, 2) AS cycles_per_year_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 AND replenishment_demand_180d > 0
        THEN (365.0 / cycle_length_days_180d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 AND replenishment_demand_180d > 0
        THEN (365.0 / cycle_length_days_180d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 AND replenishment_demand_180d > 0
        THEN (365.0 / cycle_length_days_180d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_180d,

  -- === 365d window ===
  consumed_365d,
  ROUND(rate_365d, 4) AS consumption_rate_365d,
  ROUND(replenishment_demand_365d, 2) AS replenishment_demand_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN LEAST(1.0, min_level / replenishment_demand_365d) ELSE 1.0 END, 4) AS coverage_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_365d) ELSE 0.0 END, 4) AS stockout_fraction_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_365d,
  ROUND(cycle_length_days_365d, 2) AS cycle_length_days_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 THEN 365.0 / cycle_length_days_365d ELSE NULL END, 2) AS cycles_per_year_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 AND replenishment_demand_365d > 0
        THEN (365.0 / cycle_length_days_365d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time)
        ELSE 0.0 END, 2) AS total_stockout_days_per_year_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 AND replenishment_demand_365d > 0
        THEN (365.0 / cycle_length_days_365d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS annual_stockout_pct_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 AND replenishment_demand_365d > 0
        THEN (365.0 / cycle_length_days_365d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time) / 365.0 * 100
        ELSE 0.0 END, 2) AS suggested_score_365d

FROM metrics
WHERE COALESCE(consumed_365d, 0) > 0 AND sto_class IN ('01 HIGH', '02 MED', '03 LOW')
ORDER BY sto_part, suggested_score_150d DESC NULLS LAST, site, part_number
