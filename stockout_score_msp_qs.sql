-- stockout_score_msp_qs.sql
-- Stockout Score Calculation — UIS MSP POC parts across NA and EU sites
-- QuickSight/Redshift variant — uses andes_bi_ext."rme-gdl" schema prefix.
-- Part inclusion: Amazon PNs listed in UIS_amazonPN_POC.csv (matched via cat_ref)
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
-- Target parts from UIS_amazonPN_POC.csv (122 parts)
target_parts AS (
  SELECT '1004310' AS sto_part
  UNION ALL SELECT '1277307'
  UNION ALL SELECT '1941101'
  UNION ALL SELECT '2054712'
  UNION ALL SELECT '2059710'
  UNION ALL SELECT '2059810'
  UNION ALL SELECT '2060510'
  UNION ALL SELECT '2061110'
  UNION ALL SELECT '2063810'
  UNION ALL SELECT '2731100'
  UNION ALL SELECT '2819100'
  UNION ALL SELECT '2888100'
  UNION ALL SELECT '2895503'
  UNION ALL SELECT '2999500'
  UNION ALL SELECT '3805700'
  UNION ALL SELECT '3843209'
  UNION ALL SELECT '3843210'
  UNION ALL SELECT '3843213'
  UNION ALL SELECT '6011850'
  UNION ALL SELECT '6014900'
  UNION ALL SELECT '6015300'
  UNION ALL SELECT '6016000'
  UNION ALL SELECT '6016100'
  UNION ALL SELECT '6018450'
  UNION ALL SELECT '6028910'
  UNION ALL SELECT '6029100'
  UNION ALL SELECT '6031200'
  UNION ALL SELECT '6031800'
  UNION ALL SELECT '6086000'
  UNION ALL SELECT '6087900'
  UNION ALL SELECT '6104082'
  UNION ALL SELECT '6104182'
  UNION ALL SELECT '6106300'
  UNION ALL SELECT '6135300'
  UNION ALL SELECT '6488003'
  UNION ALL SELECT '7177300'
  UNION ALL SELECT '7181017'
  UNION ALL SELECT '7181022'
  UNION ALL SELECT '7181042'
  UNION ALL SELECT '7181046'
  UNION ALL SELECT '7181483'
  UNION ALL SELECT '7181683'
  UNION ALL SELECT '7181921'
  UNION ALL SELECT '7181928'
  UNION ALL SELECT '7293104'
  UNION ALL SELECT '7306706'
  UNION ALL SELECT '7322930'
  UNION ALL SELECT '7549601'
  UNION ALL SELECT '7551200'
  UNION ALL SELECT '7552700'
  UNION ALL SELECT '7560100'
  UNION ALL SELECT '7570212'
  UNION ALL SELECT '7576300'
  UNION ALL SELECT '7621301'
  UNION ALL SELECT '7649353'
  UNION ALL SELECT '7749401'
  UNION ALL SELECT '7845300'
  UNION ALL SELECT '7881350'
  UNION ALL SELECT '7907412'
  UNION ALL SELECT '7907440'
  UNION ALL SELECT '7907700'
  UNION ALL SELECT '7907805'
  UNION ALL SELECT '7909024'
  UNION ALL SELECT '7937600'
  UNION ALL SELECT '7937605'
  UNION ALL SELECT '7951311'
  UNION ALL SELECT '7953506'
  UNION ALL SELECT '7955244'
  UNION ALL SELECT '7974800'
  UNION ALL SELECT '7975700'
  UNION ALL SELECT '7979800'
  UNION ALL SELECT '7992000'
  UNION ALL SELECT '8004521'
  UNION ALL SELECT '8004600'
  UNION ALL SELECT '8012000'
  UNION ALL SELECT '8012001'
  UNION ALL SELECT '8017700'
  UNION ALL SELECT '8020410'
  UNION ALL SELECT '8063430'
  UNION ALL SELECT '8063431'
  UNION ALL SELECT '8087025'
  UNION ALL SELECT '8087214'
  UNION ALL SELECT '8087225'
  UNION ALL SELECT '8140401'
  UNION ALL SELECT '8144666'
  UNION ALL SELECT '8150750'
  UNION ALL SELECT '8167250'
  UNION ALL SELECT '8171000'
  UNION ALL SELECT '8171050'
  UNION ALL SELECT '8178710'
  UNION ALL SELECT '8237500'
  UNION ALL SELECT '8237550'
  UNION ALL SELECT '8243805'
  UNION ALL SELECT '8264200'
  UNION ALL SELECT '8312104'
  UNION ALL SELECT '8317600'
  UNION ALL SELECT '8317700'
  UNION ALL SELECT '9180310'
  UNION ALL SELECT '9180360'
  UNION ALL SELECT '9180363'
  UNION ALL SELECT '9180400'
  UNION ALL SELECT '9180525'
  UNION ALL SELECT '9180550'
  UNION ALL SELECT '9180560'
  UNION ALL SELECT '9180605'
  UNION ALL SELECT '9180610'
  UNION ALL SELECT '9180701'
  UNION ALL SELECT '9180726'
  UNION ALL SELECT '9180751'
  UNION ALL SELECT '9180825'
  UNION ALL SELECT '9180831'
  UNION ALL SELECT '9185040'
  UNION ALL SELECT '9185050'
  UNION ALL SELECT '9185120'
  UNION ALL SELECT '9185125'
  UNION ALL SELECT '9185130'
  UNION ALL SELECT '9185135'
  UNION ALL SELECT '9185140'
  UNION ALL SELECT '9185150'
  UNION ALL SELECT 'P10584-15'
  UNION ALL SELECT 'P10588-05'
  UNION ALL SELECT 'P11711-01'
),

-- Map target parts (cat_ref values) to internal Amazon part numbers (cat_part)
part_mapping AS (
  SELECT DISTINCT cat_part AS sto_part, UPPER(TRIM(cat_ref)) AS cat_ref, 'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5catalogue_apm_na
  INNER JOIN target_parts tp ON UPPER(TRIM(cat_ref)) = tp.sto_part
  UNION
  SELECT DISTINCT cat_part AS sto_part, UPPER(TRIM(cat_ref)) AS cat_ref, 'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5catalogue_apm_eu
  INNER JOIN target_parts tp ON UPPER(TRIM(cat_ref)) = tp.sto_part
),

-- Part description from catalogue
part_info AS (
  SELECT cat_part AS sto_part,
         MAX(cat_desc) AS part_description,
         region
  FROM (
    SELECT c.cat_part, c.cat_desc, 'NA' AS region
    FROM andes_bi_ext."rme-gdl".r5catalogue_apm_na c
    INNER JOIN part_mapping pm ON c.cat_part = pm.sto_part
    WHERE c.cat_desc IS NOT NULL
    UNION ALL
    SELECT c.cat_part, c.cat_desc, 'EU' AS region
    FROM andes_bi_ext."rme-gdl".r5catalogue_apm_eu c
    INNER JOIN part_mapping pm ON c.cat_part = pm.sto_part
    WHERE c.cat_desc IS NOT NULL
  ) cat_d
  GROUP BY cat_part, region
),

-- Stock levels: min/max/current per site
stock AS (
  SELECT site, region, sto_part,
         MAX(min_level)   AS min_level,
         MAX(max_level)   AS max_level,
         MAX(sto_class)   AS sto_class
  FROM (
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site,
           st.sto_part,
           CAST(st.sto_minlev AS FLOAT) AS min_level,
           CAST(st.sto_maxqty AS FLOAT) AS max_level,
           st.sto_class,
           'NA' AS region
    FROM andes_bi_ext."rme-gdl".r5stock_apm_na st
    INNER JOIN part_mapping pm ON st.sto_part = pm.sto_part
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site,
           st.sto_part,
           CAST(st.sto_minlev AS FLOAT) AS min_level,
           CAST(st.sto_maxqty AS FLOAT) AS max_level,
           st.sto_class,
           'EU' AS region
    FROM andes_bi_ext."rme-gdl".r5stock_apm_eu st
    INNER JOIN part_mapping pm ON st.sto_part = pm.sto_part
  ) sto_raw
  GROUP BY site, region, sto_part
),

-- Lead time from catalogue via orders placed by each site
order_lead_times AS (
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS FLOAT)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN andes_bi_ext."rme-gdl".r5catalogue_apm_na
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
    INNER JOIN part_mapping pm ON l.orl_part = pm.sto_part
  UNION ALL
  SELECT rl.ord_org                   AS site,
         l.orl_part                   AS part_ordered,
         CAST(cat_leadtime AS FLOAT)  AS supplier_lead_time,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
    LEFT JOIN andes_bi_ext."rme-gdl".r5catalogue_apm_eu
           ON cat_part     = l.orl_part
          AND cat_supplier = l.orl_supplier
    INNER JOIN part_mapping pm ON l.orl_part = pm.sto_part
),
lead_time AS (
  SELECT site, part_ordered, region,
         MAX(supplier_lead_time) AS lead_time
  FROM order_lead_times
  WHERE supplier_lead_time IS NOT NULL
  GROUP BY site, part_ordered, region
),

-- Replacements building blocks
repl_events AS (
  SELECT evt_code AS event, evt_org AS organization, 'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5events_apm_na
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
  UNION
  SELECT evt_code AS event, evt_org AS organization, 'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5events_apm_eu
  WHERE evt_status = 'C'
    AND evt_type NOT IN ('STAT','XA','IN','PL','AA','MRC','XL','ATF')
),
repl_stock AS (
  SELECT rs.sto_part, COALESCE(rs.sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(rs.sto_store,'-',1) site, 'NA' region
  FROM andes_bi_ext."rme-gdl".r5stock_apm_na rs
  INNER JOIN part_mapping pm ON rs.sto_part = pm.sto_part
  UNION
  SELECT rs.sto_part, COALESCE(rs.sto_prefsup,'N') sto_prefsup,
         SPLIT_PART(rs.sto_store,'-',1) site, 'EU' region
  FROM andes_bi_ext."rme-gdl".r5stock_apm_eu rs
  INNER JOIN part_mapping pm ON rs.sto_part = pm.sto_part
),
repl_transactions AS (
  SELECT trl_event, trl_part AS amzn_part, 'NA' AS region,
         MAX(trl_date) AS trl_date, SUM(trl_qty) AS trl_qty
  FROM andes_bi_ext."rme-gdl".r5translines_apm_na
  INNER JOIN part_mapping pm ON trl_part = pm.sto_part
  WHERE trl_type = 'I'
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
  UNION
  SELECT trl_event, trl_part AS amzn_part, 'EU' AS region,
         MAX(trl_date) AS trl_date, SUM(trl_qty) AS trl_qty
  FROM andes_bi_ext."rme-gdl".r5translines_apm_eu
  INNER JOIN part_mapping pm ON trl_part = pm.sto_part
  WHERE trl_type = 'I'
    AND DATE(trl_date) >= date_add('day', -365, CURRENT_DATE)
    AND DATE(trl_date) <= CURRENT_DATE
  GROUP BY trl_event, trl_part
),
replacements AS (
  SELECT DISTINCT e.organization AS site, e.region, t.amzn_part,
         DATE(t.trl_date) AS replaced_on, e.event AS work_order_id,
         CAST(t.trl_qty AS FLOAT) AS qty_replaced
  FROM repl_events e
    JOIN repl_transactions t ON t.trl_event = e.event AND e.region = t.region
    JOIN repl_stock s ON t.amzn_part = s.sto_part AND s.site = e.organization
  WHERE t.amzn_part IS NOT NULL
),

consumption AS (
  SELECT site, region, amzn_part AS sto_part,
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
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'NA' AS region, st.sto_part,
           CAST(st.sto_qty AS FLOAT) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM andes_bi_ext."rme-gdl".r5stock_apm_na st
    WHERE st.sto_part IN (SELECT DISTINCT sto_part FROM part_mapping)
    UNION ALL
    SELECT SPLIT_PART(st.sto_store, '-', 1) AS site, 'EU' AS region, st.sto_part,
           CAST(st.sto_qty AS FLOAT) AS sto_qty, CAST(st.sto_updated AS TIMESTAMP) AS sto_updated
    FROM andes_bi_ext."rme-gdl".r5stock_apm_eu st
    WHERE st.sto_part IN (SELECT DISTINCT sto_part FROM part_mapping)
  ) sto
),
site_inv AS (
  SELECT site, region, sto_part, SUM(sto_qty) AS sto_qty
  FROM site_inv_raw WHERE rnk = 1
  GROUP BY site, region, sto_part
),
site_oh_qty AS (
  SELECT site, region, sto_part, MAX(sto_qty) AS site_oh_qty
  FROM site_inv
  GROUP BY site, region, sto_part
),

-- Order history: received orders aggregated per (part, site, region)
received_orders AS (
  SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         CAST(rl.ord_updated AS DATE) AS order_received_date,
         DATEDIFF('day', CAST(rl.ord_created AS DATE), CAST(rl.ord_updated AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty, 'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT DISTINCT sto_part FROM part_mapping)
    AND ((rl.ord_status = 'AR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'PR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'AR' AND l.orl_status = 'soft'))
    AND CAST(rl.ord_created AS DATE) >= CURRENT_DATE - INTERVAL '365' DAY
  UNION ALL
  SELECT rl.ord_org AS site, l.orl_part AS part_ordered,
         CAST(rl.ord_created AS DATE) AS order_created_date,
         CAST(rl.ord_updated AS DATE) AS order_received_date,
         DATEDIFF('day', CAST(rl.ord_created AS DATE), CAST(rl.ord_updated AS DATE)) AS rep_time_days,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty, 'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT DISTINCT sto_part FROM part_mapping)
    AND ((rl.ord_status = 'AR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'PR' AND l.orl_status = 'A')
      OR (rl.ord_status = 'AR' AND l.orl_status = 'soft'))
    AND CAST(rl.ord_created AS DATE) >= CURRENT_DATE - INTERVAL '365' DAY
),
order_history AS (
  SELECT site, part_ordered AS sto_part, region,
         COUNT(*) AS order_count,
         ROUND(AVG(CAST(rep_time_days AS FLOAT)), 2) AS avg_rep_time_days,
         MIN(rep_time_days) AS min_rep_time_days,
         MAX(rep_time_days) AS max_rep_time_days,
         MAX(order_received_date) AS last_received_date,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '30' DAY THEN orl_ordqty ELSE 0 END) / 30.0, 4) AS last_30d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '60' DAY THEN orl_ordqty ELSE 0 END) / 60.0, 4) AS last_60d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '90' DAY THEN orl_ordqty ELSE 0 END) / 90.0, 4) AS last_90d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '120' DAY THEN orl_ordqty ELSE 0 END) / 120.0, 4) AS last_120d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '150' DAY THEN orl_ordqty ELSE 0 END) / 150.0, 4) AS last_150d_order,
         ROUND(SUM(CASE WHEN order_created_date >= CURRENT_DATE - INTERVAL '180' DAY THEN orl_ordqty ELSE 0 END) / 180.0, 4) AS last_180d_order,
         ROUND(SUM(orl_ordqty) / 365.0, 4) AS last_365d_order
  FROM received_orders
  GROUP BY site, part_ordered, region
),

-- Coming orders: open/approved orders (back_order_qty per part/site)
coming_order_data AS (
  SELECT l.orl_part AS part_ordered,
         rl.ord_org AS site,
         trim(cast(l.orl_order AS varchar)) AS order_number,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty,
         'NA' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_na l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_na rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT DISTINCT sto_part FROM part_mapping)
    AND rl.ord_status = 'A'
    AND l.orl_status = 'A'
  UNION ALL
  SELECT l.orl_part AS part_ordered,
         rl.ord_org AS site,
         trim(cast(l.orl_order AS varchar)) AS order_number,
         CAST(l.orl_ordqty AS FLOAT) AS orl_ordqty,
         'EU' AS region
  FROM andes_bi_ext."rme-gdl".r5orderlines_apm_eu l
    INNER JOIN andes_bi_ext."rme-gdl".r5orders_apm_eu rl
            ON trim(cast(l.orl_order AS varchar)) = trim(cast(rl.ord_code AS varchar))
  WHERE l.orl_part IN (SELECT DISTINCT sto_part FROM part_mapping)
    AND rl.ord_status = 'A'
    AND l.orl_status = 'A'
),
coming_order_qty AS (
  SELECT part_ordered AS sto_part, site, region,
         COUNT(DISTINCT order_number) AS open_order_count,
         SUM(orl_ordqty) AS back_order_qty
  FROM coming_order_data
  GROUP BY part_ordered, site, region
),

metrics AS (
  SELECT s.site, s.region, s.sto_part,
         pm.cat_ref AS amazon_pn,
         pi.part_description,
         s.sto_class, s.min_level, s.max_level,
         lt.lead_time AS supplier_lead_time,
         COALESCE(soh.site_oh_qty, 0.0) AS site_oh_qty,
         -- Order history columns
         oh.order_count, oh.avg_rep_time_days, oh.min_rep_time_days, oh.max_rep_time_days,
         oh.last_received_date,
         oh.last_30d_order, oh.last_60d_order, oh.last_90d_order,
         oh.last_120d_order, oh.last_150d_order, oh.last_180d_order, oh.last_365d_order,
         -- Coming order columns
         COALESCE(co.open_order_count, 0) AS open_order_count,
         COALESCE(co.back_order_qty, 0.0) AS back_order_qty,
         c.consumed_30d / 30.0 AS rate_30d, c.consumed_60d / 60.0 AS rate_60d,
         c.consumed_90d / 90.0 AS rate_90d, c.consumed_120d / 120.0 AS rate_120d,
         c.consumed_150d / 150.0 AS rate_150d, c.consumed_180d / 180.0 AS rate_180d,
         c.consumed_365d / 365.0 AS rate_365d,
         c.consumed_30d, c.consumed_60d, c.consumed_90d,
         c.consumed_120d, c.consumed_150d, c.consumed_180d, c.consumed_365d,
         lt.lead_time AS replenishment_time,
         COALESCE(c.consumed_30d / 30.0, 0.0) * lt.lead_time AS replenishment_demand_30d,
         COALESCE(c.consumed_60d / 60.0, 0.0) * lt.lead_time AS replenishment_demand_60d,
         COALESCE(c.consumed_90d / 90.0, 0.0) * lt.lead_time AS replenishment_demand_90d,
         COALESCE(c.consumed_120d / 120.0, 0.0) * lt.lead_time AS replenishment_demand_120d,
         COALESCE(c.consumed_150d / 150.0, 0.0) * lt.lead_time AS replenishment_demand_150d,
         COALESCE(c.consumed_180d / 180.0, 0.0) * lt.lead_time AS replenishment_demand_180d,
         COALESCE(c.consumed_365d / 365.0, 0.0) * lt.lead_time AS replenishment_demand_365d,
         CASE WHEN COALESCE(c.consumed_30d / 30.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_30d / 30.0) ELSE NULL END AS cycle_length_days_30d,
         CASE WHEN COALESCE(c.consumed_60d / 60.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_60d / 60.0) ELSE NULL END AS cycle_length_days_60d,
         CASE WHEN COALESCE(c.consumed_90d / 90.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_90d / 90.0) ELSE NULL END AS cycle_length_days_90d,
         CASE WHEN COALESCE(c.consumed_120d / 120.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_120d / 120.0) ELSE NULL END AS cycle_length_days_120d,
         CASE WHEN COALESCE(c.consumed_150d / 150.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_150d / 150.0) ELSE NULL END AS cycle_length_days_150d,
         CASE WHEN COALESCE(c.consumed_180d / 180.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_180d / 180.0) ELSE NULL END AS cycle_length_days_180d,
         CASE WHEN COALESCE(c.consumed_365d / 365.0, 0.0) > 0 THEN (s.max_level - s.min_level) / (c.consumed_365d / 365.0) ELSE NULL END AS cycle_length_days_365d
  FROM stock s
    LEFT JOIN part_mapping pm ON pm.sto_part = s.sto_part AND pm.region = s.region
    LEFT JOIN part_info pi ON pi.sto_part = s.sto_part AND pi.region = s.region
    LEFT JOIN consumption c ON c.site = s.site AND c.region = s.region AND c.sto_part = s.sto_part
    LEFT JOIN lead_time lt ON lt.site = s.site AND lt.region = s.region AND lt.part_ordered = s.sto_part
    LEFT JOIN site_oh_qty soh ON soh.site = s.site AND soh.region = s.region AND soh.sto_part = s.sto_part
    LEFT JOIN order_history oh ON oh.site = s.site AND oh.region = s.region AND oh.sto_part = s.sto_part
    LEFT JOIN coming_order_qty co ON co.site = s.site AND co.region = s.region AND co.sto_part = s.sto_part
)
SELECT
  CURRENT_DATE AS snapshot_date,
  site, region, sto_part AS "Part", amazon_pn, part_description,
  sto_class, site_oh_qty, min_level, max_level,
  supplier_lead_time, replenishment_time,

  -- Order history
  order_count, avg_rep_time_days, min_rep_time_days, max_rep_time_days,
  last_received_date,
  last_30d_order, last_60d_order, last_90d_order,
  last_120d_order, last_150d_order, last_180d_order, last_365d_order,

  -- Coming orders
  open_order_count, back_order_qty,

  consumed_30d, ROUND(rate_30d, 4) AS consumption_rate_30d, ROUND(replenishment_demand_30d, 2) AS replenishment_demand_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN LEAST(1.0, min_level / replenishment_demand_30d) ELSE 1.0 END, 4) AS coverage_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_30d) ELSE 0.0 END, 4) AS stockout_fraction_30d,
  ROUND(CASE WHEN replenishment_demand_30d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_30d,
  ROUND(cycle_length_days_30d, 2) AS cycle_length_days_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 THEN 365.0 / cycle_length_days_30d ELSE NULL END, 2) AS cycles_per_year_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 AND replenishment_demand_30d > 0 THEN (365.0 / cycle_length_days_30d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_30d,
  ROUND(CASE WHEN cycle_length_days_30d > 0 AND replenishment_demand_30d > 0 THEN (365.0 / cycle_length_days_30d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_30d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_30d,

  consumed_60d, ROUND(rate_60d, 4) AS consumption_rate_60d, ROUND(replenishment_demand_60d, 2) AS replenishment_demand_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN LEAST(1.0, min_level / replenishment_demand_60d) ELSE 1.0 END, 4) AS coverage_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_60d) ELSE 0.0 END, 4) AS stockout_fraction_60d,
  ROUND(CASE WHEN replenishment_demand_60d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_60d,
  ROUND(cycle_length_days_60d, 2) AS cycle_length_days_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 THEN 365.0 / cycle_length_days_60d ELSE NULL END, 2) AS cycles_per_year_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 AND replenishment_demand_60d > 0 THEN (365.0 / cycle_length_days_60d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_60d,
  ROUND(CASE WHEN cycle_length_days_60d > 0 AND replenishment_demand_60d > 0 THEN (365.0 / cycle_length_days_60d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_60d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_60d,

  consumed_90d, ROUND(rate_90d, 4) AS consumption_rate_90d, ROUND(replenishment_demand_90d, 2) AS replenishment_demand_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN LEAST(1.0, min_level / replenishment_demand_90d) ELSE 1.0 END, 4) AS coverage_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_90d) ELSE 0.0 END, 4) AS stockout_fraction_90d,
  ROUND(CASE WHEN replenishment_demand_90d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_90d,
  ROUND(cycle_length_days_90d, 2) AS cycle_length_days_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 THEN 365.0 / cycle_length_days_90d ELSE NULL END, 2) AS cycles_per_year_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 AND replenishment_demand_90d > 0 THEN (365.0 / cycle_length_days_90d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_90d,
  ROUND(CASE WHEN cycle_length_days_90d > 0 AND replenishment_demand_90d > 0 THEN (365.0 / cycle_length_days_90d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_90d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_90d,

  consumed_120d, ROUND(rate_120d, 4) AS consumption_rate_120d, ROUND(replenishment_demand_120d, 2) AS replenishment_demand_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN LEAST(1.0, min_level / replenishment_demand_120d) ELSE 1.0 END, 4) AS coverage_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_120d) ELSE 0.0 END, 4) AS stockout_fraction_120d,
  ROUND(CASE WHEN replenishment_demand_120d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_120d,
  ROUND(cycle_length_days_120d, 2) AS cycle_length_days_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 THEN 365.0 / cycle_length_days_120d ELSE NULL END, 2) AS cycles_per_year_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 AND replenishment_demand_120d > 0 THEN (365.0 / cycle_length_days_120d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_120d,
  ROUND(CASE WHEN cycle_length_days_120d > 0 AND replenishment_demand_120d > 0 THEN (365.0 / cycle_length_days_120d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_120d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_120d,

  consumed_150d, ROUND(rate_150d, 4) AS consumption_rate_150d, ROUND(replenishment_demand_150d, 2) AS replenishment_demand_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN LEAST(1.0, min_level / replenishment_demand_150d) ELSE 1.0 END, 4) AS coverage_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_150d) ELSE 0.0 END, 4) AS stockout_fraction_150d,
  ROUND(CASE WHEN replenishment_demand_150d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_150d,
  ROUND(cycle_length_days_150d, 2) AS cycle_length_days_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 THEN 365.0 / cycle_length_days_150d ELSE NULL END, 2) AS cycles_per_year_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_150d,
  ROUND(CASE WHEN cycle_length_days_150d > 0 AND replenishment_demand_150d > 0 THEN (365.0 / cycle_length_days_150d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_150d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_150d,

  consumed_180d, ROUND(rate_180d, 4) AS consumption_rate_180d, ROUND(replenishment_demand_180d, 2) AS replenishment_demand_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN LEAST(1.0, min_level / replenishment_demand_180d) ELSE 1.0 END, 4) AS coverage_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_180d) ELSE 0.0 END, 4) AS stockout_fraction_180d,
  ROUND(CASE WHEN replenishment_demand_180d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_180d,
  ROUND(cycle_length_days_180d, 2) AS cycle_length_days_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 THEN 365.0 / cycle_length_days_180d ELSE NULL END, 2) AS cycles_per_year_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 AND replenishment_demand_180d > 0 THEN (365.0 / cycle_length_days_180d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_180d,
  ROUND(CASE WHEN cycle_length_days_180d > 0 AND replenishment_demand_180d > 0 THEN (365.0 / cycle_length_days_180d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_180d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_180d,

  consumed_365d, ROUND(rate_365d, 4) AS consumption_rate_365d, ROUND(replenishment_demand_365d, 2) AS replenishment_demand_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN LEAST(1.0, min_level / replenishment_demand_365d) ELSE 1.0 END, 4) AS coverage_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN 1.0 - LEAST(1.0, min_level / replenishment_demand_365d) ELSE 0.0 END, 4) AS stockout_fraction_365d,
  ROUND(CASE WHEN replenishment_demand_365d > 0 THEN (1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time ELSE 0.0 END, 2) AS stockout_days_per_cycle_365d,
  ROUND(cycle_length_days_365d, 2) AS cycle_length_days_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 THEN 365.0 / cycle_length_days_365d ELSE NULL END, 2) AS cycles_per_year_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 AND replenishment_demand_365d > 0 THEN (365.0 / cycle_length_days_365d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time) ELSE 0.0 END, 2) AS total_stockout_days_per_year_365d,
  ROUND(CASE WHEN cycle_length_days_365d > 0 AND replenishment_demand_365d > 0 THEN (365.0 / cycle_length_days_365d) * ((1.0 - LEAST(1.0, min_level / replenishment_demand_365d)) * replenishment_time) / 365.0 * 100 ELSE 0.0 END, 2) AS suggested_score_365d

FROM metrics
WHERE COALESCE(consumed_365d, 0) > 0 AND sto_class = '01 HIGH'
ORDER BY sto_part, suggested_score_150d DESC NULLS LAST, site
