-- dweeb_coming_order.sql (standalone)
-- Based on sales_order.sql, filtered to 3 target part numbers.
-- Adds back_order_qty using Tableau LOD:
--   { FIXED [Part_No], [Site]:
--       SUM( IFNULL({ FIXED [Part_No],[sitename],[ordernumber],[line_id]:
--                      MAX([qtyordered]) }, 0) ) }

WITH Back_orders AS
(
  SELECT "CustomerPONumber",
         "OrderNumber",
         "Item",
         "Line_id",
         CAST("QtyOrdered" AS FLOAT) AS so_qty,
         "LineNumber",
         "ShipLineStatus",
         "OrderLineStatus",
         RIGHT ("ShipToFullAddress",2) AS country,
         CASE
           WHEN RIGHT ("ShipToFullAddress",2) = 'US' OR RIGHT ("ShipToFullAddress",2) = 'CA' THEN 'NA'
           WHEN RIGHT ("ShipToFullAddress",2) = 'JP' THEN 'JP'
           WHEN RIGHT ("ShipToFullAddress",2) = 'AU' THEN 'AU'
           WHEN RIGHT ("ShipToFullAddress",2) = 'GB' THEN 'UK'
           ELSE 'EU'
         END AS Region,
         "ScheduleShipDate",
         "ShipFromOrg",
         ROW_NUMBER() OVER (PARTITION BY "Item","ShipFromOrg" ORDER BY "ScheduleShipDate") AS SO_rank
  FROM ar_dweebs.factsalesorder
  WHERE "ShipLineStatus" IN ('Backordered')
  AND   "ShipFromOrg" IN ('200','202')
  AND   "OrderLineStatus" IN ('AWAITING_SHIPPING')
  AND   "CustomerPONumber" IS NOT NULL
),
PO_DATA AS
(
  SELECT "Item",
         "ShipToOrg",
         CAST(qty AS FLOAT) AS po_qty,
         promise_date,
         ROW_NUMBER() OVER (PARTITION BY "Item","ShipToOrg" ORDER BY promise_date) AS PO_rank
  FROM (SELECT a."Item",
               a."ShipToOrg",
               CASE
                 WHEN b.expectedreceiptdate > CURRENT_TIMESTAMP THEN b.qty
                 ELSE a.qtyordered - a.qtyreceived
               END AS qty,
               COALESCE(CAST(b.actualdeliverydate AS TIMESTAMP),CAST(b.scheduleddeliverydate AS TIMESTAMP),CAST(a.promisedate AS TIMESTAMP)) AS promise_date
        FROM ar_dweebs.factpurchaseorder a
          LEFT JOIN ar_dweebs.facttmsedi b
                 ON a.po = b.ordernumber
                AND a.shiptoorg = b.shiptoorg
                AND a.item = b.item
                AND b.ordertypename = 'Purchase Order'
                AND (a.po_line || '.' || a.shipment_num) = b.linenumber
                AND b.shipstatus NOT IN ('Delivered')
        WHERE a."ShipToOrg" IN ('200','202')
        AND   a."ShippingStatus" IN ('Open')
        UNION ALL
        SELECT "ITEM",
               "SHIPTOORG",
               "Qty",
               COALESCE(CAST(actualdeliverydate AS TIMESTAMP),CAST(scheduleddeliverydate AS TIMESTAMP),CAST(promiseddate AS TIMESTAMP))
        FROM ar_dweebs.facttmsedi
        WHERE ordertypename NOT IN ('Purchase Order')
        AND   shiptoorg IN ('200','202')
        AND   orderstatus IN ('EXPECTED')) AS a
  WHERE promise_date > CURRENT_TIMESTAMP
),
Cum_SO AS
(
  SELECT *,
         SUM(so_qty) OVER (PARTITION BY "Item","ShipFromOrg" ORDER BY SO_rank ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_demand
  FROM Back_orders
),
Cum_PO AS
(
  SELECT *,
         SUM(po_qty) OVER (PARTITION BY "Item","ShipToOrg" ORDER BY PO_rank ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_supply
  FROM PO_DATA
),
matches AS
(
  SELECT so."CustomerPONumber",
         so."OrderNumber",
         so."Line_id",
         so."LineNumber",
         so."Item",
         so."ShipLineStatus",
         so."OrderLineStatus",
         so."ScheduleShipDate",
         so.country,
         so.Region,
         so.so_qty,
         so."ShipFromOrg",
         CAST(po.promise_date AS DATE),
         po.po_qty,
         so.cum_demand,
         po.cum_supply,
         ROW_NUMBER() OVER (PARTITION BY so."OrderNumber",so."LineNumber" ORDER BY po.promise_date) AS match_rank
  FROM Cum_SO AS so
    JOIN Cum_PO AS po
      ON so."Item" = po."Item"
     AND so."ShipFromOrg" = po."ShipToOrg"
     AND po.cum_supply > (so.cum_demand - so.so_qty)
),
Back_orders_final AS
(
  SELECT m."CustomerPONumber",
         m."OrderNumber",
         m."Line_ID",
         m."LineNumber",
         m."Item",
         m."ShipLineStatus",
         m."OrderLineStatus",
         m."ScheduleShipDate" AS SSD,
         m."ShipFromOrg",
         m.country,
         m.region,
         m.so_qty,
         CASE
           WHEN m.promise_date IS NULL THEN 'Low supply; PD TBD'
           WHEN m.region IN ('NA','JP','AU') THEN CAST(TO_CHAR(CAST((m.promise_date +(3 +
             CASE
               WHEN EXTRACT(dow FROM m.promise_date) IN (3,4,5) THEN 2
               WHEN EXTRACT(dow FROM m.promise_date) = 6 THEN 1
               ELSE 0
             END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
           WHEN m.region IN ('EU') THEN CAST(TO_CHAR(CAST((m.promise_date +(7 +
             CASE
               WHEN EXTRACT(dow FROM m.promise_date) = 6 THEN 3
               WHEN EXTRACT(dow FROM m.promise_date) IN (5,4) THEN 4
               ELSE 2
             END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
           WHEN m.region IN ('UK') THEN CAST(TO_CHAR(CAST((m.promise_date +(8 +
             CASE
               WHEN EXTRACT(dow FROM m.promise_date) = 6 THEN 3
               WHEN EXTRACT(dow FROM m.promise_date) IN (5,4,3) THEN 4
               ELSE 2
             END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
         END AS Revised_Ship_Date
  FROM matches AS m
  WHERE m.match_rank = 1
  UNION
  SELECT so."CustomerPONumber",
         so."OrderNumber",
         so."Line_ID",
         so."LineNumber",
         so."Item",
         "ShipLineStatus",
         "OrderLineStatus",
         so."ScheduleShipDate",
         "ShipFromOrg",
         country,
         Region,
         so_qty,
         'Low supply; PD TBD' AS Revised_Ship_Date
  FROM Cum_SO so
  WHERE NOT EXISTS (SELECT 1
                    FROM matches m
                    WHERE m."CustomerPONumber" = so."CustomerPONumber"
                    AND   m."OrderNumber" = so."OrderNumber"
                    AND   m."LineNumber" = so."LineNumber")
),
non_backorders AS
(
  SELECT "CustomerPONumber",
         "OrderNumber",
         "Line_id",
         "LineNumber",
         "Item",
         "ShipLineStatus",
         "OrderLineStatus",
         CAST("ScheduleShipDate" AS DATE),
         "ActualShipmentDate",
         "ShipFromOrg",
         ordercategory,
         CAST("QtyOrdered" AS FLOAT) AS so_qty,
         RIGHT ("ShipToFullAddress",2) AS country,
         CASE
           WHEN RIGHT ("ShipToFullAddress",2) = 'US' OR RIGHT ("ShipToFullAddress",2) = 'CA' THEN 'NA'
           WHEN RIGHT ("ShipToFullAddress",2) = 'JP' THEN 'JP'
           WHEN RIGHT ("ShipToFullAddress",2) = 'AU' THEN 'AU'
           WHEN RIGHT ("ShipToFullAddress",2) = 'GB' THEN 'UK'
           ELSE 'EU'
         END AS Region
  FROM ar_dweebs.factsalesorder
  WHERE NOT ("ShipLineStatus" IN ('Backordered') AND "OrderLineStatus" IN ('AWAITING_SHIPPING'))
  AND   creationdate > CURRENT_TIMESTAMP-INTERVAL '6 months'
  AND   "ShipFromOrg" IN ('200','202')
  AND   "CustomerPONumber" IS NOT NULL
  AND   "OrderLineStatus" != 'AWAITING_RETURN'
),
non_backorders_final AS
(
  SELECT "CustomerPONumber",
         "OrderNumber",
         "Line_ID",
         "LineNumber",
         "Item",
         "ShipLineStatus",
         "OrderLineStatus",
         "ScheduleShipDate" AS SSD,
         "ShipFromOrg",
         country,
         region,
         so_qty,
         CASE
           WHEN "ShipLineStatus" IN ('Cancelled') THEN 'Order Closed'
           WHEN "ShipLineStatus" IN ('Shipped') THEN 'Order Closed'
           WHEN "ShipLineStatus" IN ('Backordered') AND "OrderLineStatus" IN ('SHIPPED','CLOSED','CANCELLED') THEN 'Order Closed'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('ORDER') THEN 'Order Closed'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('RETURN') AND orderlinestatus IN ('CANCELLED','ENTERED','CLOSED') THEN 'Order Closed'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('RETURN') AND orderlinestatus IN ('AWAITING_RETURN') THEN 'Awaiting Return'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('MIXED') AND orderlinestatus IN ('AWAITING_RETURN') THEN 'Awaiting Return'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('MIXED') AND orderlinestatus IN ('CANCELLED') THEN 'Order Closed'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('MIXED') AND orderlinestatus IN ('CLOSED') THEN 'Order Closed'
           WHEN "ShipLineStatus" IS NULL AND ordercategory IN ('MIXED') AND orderlinestatus IN ('ENTERED') THEN 'Returned'
           WHEN "ShipLineStatus" IN ('Ready to Release','Released to Warehouse','Staged/Pick Confirmed') THEN (
             CASE
               WHEN region IN ('NA','JP','AU') THEN CAST(TO_CHAR(CAST(("ScheduleShipDate" +(3 +
                 CASE
                   WHEN EXTRACT(dow FROM scheduleshipdate) IN (3,4,5) THEN 2
                   WHEN EXTRACT(dow FROM scheduleshipdate) = 6 THEN 1
                   ELSE 0
                 END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
               WHEN region IN ('EU') THEN CAST(TO_CHAR(CAST(("ScheduleShipDate" +(7 +
                 CASE
                   WHEN EXTRACT(dow FROM "ScheduleShipDate") = 6 THEN 3
                   WHEN EXTRACT(dow FROM "ScheduleShipDate") IN (5,4) THEN 4
                   ELSE 2
                 END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
               WHEN region IN ('UK') THEN CAST(TO_CHAR(CAST(("ScheduleShipDate" +(8 +
                 CASE
                   WHEN EXTRACT(dow FROM "ScheduleShipDate") = 6 THEN 3
                   WHEN EXTRACT(dow FROM "ScheduleShipDate") IN (5,4,3) THEN 4
                   ELSE 2
                 END )*INTERVAL '1 day') AS DATE),'FMMM/FMDD/YYYY') AS VARCHAR)
             END )
           ELSE 'Order Closed'
         END AS Revised_Ship_Date
  FROM non_backorders
),
revised_shipment AS
(
  SELECT *
  FROM Back_orders_final
  UNION ALL
  SELECT *
  FROM non_backorders_final
),

-- Base output from sales_order.sql with part_no normalization
base_orders AS (
  SELECT f."OrderNumber",
         f."CustomerPONumber",
         f."Line_ID",
         f."Item" AS org_part_no,
         CASE
           WHEN (f."Item" LIKE 'R%' OR f."Item" LIKE '%-FRU') THEN REPLACE(REPLACE(f."Item",'-FRU',''),'R','')
           ELSE f."Item"
         END AS part_no,
         CASE
           WHEN (f."Item" LIKE 'R%' OR f."Item" LIKE '%-FRU') THEN 'Y'
           ELSE 'N'
         END AS "R_part",
         LEFT(f."SiteName",4) AS site,
         CASE
           WHEN RIGHT(f."ShipToFullAddress",2) IN ('US','CA') THEN 'NA'
           WHEN RIGHT(f."ShipToFullAddress",2) = 'JP' THEN 'JP'
           WHEN RIGHT(f."ShipToFullAddress",2) = 'AU' THEN 'AU'
           WHEN RIGHT(f."ShipToFullAddress",2) = 'GB' THEN 'UK'
           ELSE 'EU'
         END AS region,
         CAST(f."QtyOrdered" AS FLOAT) AS qtyordered,
         f."ShipFromOrg",
         f."OrderedDate",
         f."PromiseDate",
         f."OrderLineStatus",
         f."ShipLineStatus",
         f."RequestDate",
         f."OrderType",
         COALESCE(f."ActualShipmentDate",f."ScheduleShipDate") AS shipment_date,
         r.revised_ship_date
  FROM ar_dweebs.factsalesorder f
    LEFT JOIN revised_shipment r
           ON f.ordernumber = r.ordernumber
          AND f.customerponumber = r.customerponumber
          AND f.item = r.item
          AND f.line_id = r.line_id
          AND f.orderlinestatus = r.orderlinestatus
  WHERE f."Open_flag" = 'Y'
    AND f."OrderLineStatus" != 'CLOSED'
    AND f."OrderCategory" != 'RETURN'
    AND f."OrderType" IN ('AR Web Order Internal','AR US Transfer Web Order')
    AND f."OrderLineStatus" != 'CANCELLED'
),

-- Filter to all parts, all regions
filtered AS (
  SELECT *
  FROM base_orders
),

-- Inner LOD: MAX(qtyordered) per (part_no, site, ordernumber, line_id)
qty_per_line AS (
  SELECT part_no,
         site,
         "OrderNumber",
         "Line_ID",
         COALESCE(MAX(qtyordered), 0) AS qty_per_line
  FROM filtered
  GROUP BY part_no, site, "OrderNumber", "Line_ID"
),

-- Outer LOD: SUM of deduped qtys per (part_no, site)
back_order_totals AS (
  SELECT part_no,
         site,
         SUM(qty_per_line) AS back_order_qty
  FROM qty_per_line
  GROUP BY part_no, site
)

SELECT f.*,
       COALESCE(b.back_order_qty, 0) AS back_order_qty
FROM filtered f
  LEFT JOIN back_order_totals b
         ON b.part_no = f.part_no
        AND b.site    = f.site
where revised_ship_date != 'Returned'
ORDER BY revised_ship_date, f.part_no, f.site, f."OrderNumber"
