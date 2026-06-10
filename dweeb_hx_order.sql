-- dweeb_hx_order.sql
-- Average and P80 replenishment time in days across closed orders
-- in the most recent 365 days, aggregated at (part_no, site, region) level.
-- Replenishment time per row =
--   COALESCE("ActualShipmentDate","ScheduleShipDate")
--   - COALESCE("creationdate","ordereddate")
-- Also includes daily order rates at multiple windows.
-- ALL parts included (no part_no filter).
-- Includes product_category from dimistoreitemdetails.

WITH
-- Product category lookup per (part, site)
product_cat AS (
  SELECT "Item", product_category, Site
  FROM (
    SELECT DISTINCT
           CASE
             WHEN (p."Item" LIKE 'R%' OR p."Item" LIKE '%-FRU') THEN REPLACE(REPLACE(p."Item",'-FRU',''),'R','')
             ELSE p."Item"
           END AS "Item",
           sites."Section" AS product_category,
           sites.Site
    FROM ar_dweebs.dimistoreitemdetails p
      LEFT JOIN (
        SELECT DISTINCT TRIM(SPLIT_PART("Site",'-',2)) AS Site, "Section"
        FROM ar_dweebs.dimistoresitesection
      ) sites ON TRIM(SPLIT_PART(p."SectionHierarchy",'>',4)) = sites."Section"
    WHERE sites.Site IS NOT NULL
      AND LENGTH(sites.Site) > 0
      AND sites.Site NOT LIKE '%Global%'
  ) pc
  GROUP BY "Item", product_category, Site
),

-- Main order history aggregation
agg AS (
  SELECT
    CASE
      WHEN ("Item" LIKE 'R%' OR "Item" LIKE '%-FRU') THEN REPLACE(REPLACE("Item",'-FRU',''),'R','')
      ELSE "Item"
    END AS part_no,
    LEFT("SiteName",4) AS site,
    CASE
      WHEN RIGHT("ShipToFullAddress",2) IN ('US','CA') THEN 'NA'
      WHEN RIGHT("ShipToFullAddress",2) = 'JP' THEN 'JP'
      WHEN RIGHT("ShipToFullAddress",2) = 'AU' THEN 'AU'
      WHEN RIGHT("ShipToFullAddress",2) = 'GB' THEN 'UK'
      ELSE 'EU'
    END AS region,
    COUNT(*) AS order_count,
    ROUND(AVG(CAST(CAST("RequestDate" AS DATE) - CAST("OrderedDate" AS DATE) AS FLOAT)), 2) AS avg_rep_time_days,
    MIN(CAST("RequestDate" AS DATE) - CAST("OrderedDate" AS DATE)) AS min_rep_time_days,
    MAX(CAST("RequestDate" AS DATE) - CAST("OrderedDate" AS DATE)) AS max_rep_time_days,
    ROUND(PERCENTILE_CONT(0.80) WITHIN GROUP (ORDER BY CAST("RequestDate" AS DATE) - CAST("OrderedDate" AS DATE)), 2) AS p80_rep_time_days,
    MAX(COALESCE("ActualShipmentDate","ScheduleShipDate")) AS last_shipment_date,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '30' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 30.0, 4) AS last_30d_order,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '60' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 60.0, 4) AS last_60d_order,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '90' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 90.0, 4) AS last_90d_order,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '120' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 120.0, 4) AS last_120d_order,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '150' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 150.0, 4) AS last_150d_order,
    ROUND(SUM(CASE WHEN COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '180' DAY
             THEN CAST("QtyOrdered" AS FLOAT) ELSE 0 END) / 180.0, 4) AS last_180d_order,
    ROUND(SUM(CAST("QtyOrdered" AS FLOAT)) / 365.0, 4) AS last_365d_order
  FROM ar_dweebs.factsalesorder
  WHERE COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '365' DAY
    AND "OrderLineStatus" = 'CLOSED'
    AND "OrderCategory" != 'RETURN'
    AND "OrderType" IN ('AR Web Order Internal','AR US Transfer Web Order')
    AND "OrderLineStatus" != 'CANCELLED'
  GROUP BY 1, 2, 3
)

SELECT
  agg.part_no,
  agg.site,
  agg.region,
  MAX(pc.product_category) AS product_category,
  agg.order_count,
  agg.avg_rep_time_days,
  agg.min_rep_time_days,
  agg.max_rep_time_days,
  agg.p80_rep_time_days,
  agg.last_shipment_date,
  agg.last_30d_order,
  agg.last_60d_order,
  agg.last_90d_order,
  agg.last_120d_order,
  agg.last_150d_order,
  agg.last_180d_order,
  agg.last_365d_order
FROM agg
  LEFT JOIN product_cat pc
         ON pc."Item" = agg.part_no
        AND pc.Site = agg.site
GROUP BY agg.part_no, agg.site, agg.region,
         agg.order_count, agg.avg_rep_time_days,
         agg.min_rep_time_days, agg.max_rep_time_days,
         agg.p80_rep_time_days, agg.last_shipment_date,
         agg.last_30d_order, agg.last_60d_order, agg.last_90d_order,
         agg.last_120d_order, agg.last_150d_order, agg.last_180d_order,
         agg.last_365d_order
ORDER BY agg.part_no, agg.site
