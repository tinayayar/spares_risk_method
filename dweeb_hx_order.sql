-- dweeb_hx_order.sql
-- Average and P80 replenishment time in days across closed orders
-- in the most recent 365 days, aggregated at (part_no, site, region) level.
-- Replenishment time per row =
--   COALESCE("ActualShipmentDate","ScheduleShipDate")
--   - COALESCE("creationdate","ordereddate")
-- Also includes daily order rates at multiple windows.
-- ALL parts included (no part_no filter).

SELECT
  part_no,
  site,
  region,
  order_count,
  avg_rep_time_days,
  min_rep_time_days,
  max_rep_time_days,
  p80_rep_time_days,
  last_shipment_date,
  last_30d_order,
  last_60d_order,
  last_90d_order,
  last_120d_order,
  last_150d_order,
  last_180d_order,
  last_365d_order
FROM (
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
    -- Most recent shipment date per (part, site)
    MAX(COALESCE("ActualShipmentDate","ScheduleShipDate")) AS last_shipment_date,
    -- Daily order rates
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
  FROM ar_dweebs."FactSalesOrder"
  WHERE COALESCE("ActualShipmentDate","ScheduleShipDate") >= CURRENT_DATE - INTERVAL '365' DAY
    AND "OrderLineStatus" = 'CLOSED'
    AND "OrderCategory" != 'RETURN'
    AND "OrderType" IN ('AR Web Order Internal','AR US Transfer Web Order')
    AND "OrderLineStatus" != 'CANCELLED'
  GROUP BY 1, 2, 3
) agg
ORDER BY part_no, site
