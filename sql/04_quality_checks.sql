-- Data quality checks. Each one is a SELECT that should return ZERO rows
-- when the warehouse is healthy — any row it does return is itself an
-- example of the problem. build_warehouse.py runs each block below (split
-- on the "-- CHECK:" markers) and fails the build if any of them return rows.

-- CHECK: dim_date primary key (date_key) is unique
SELECT date_key, COUNT(*) AS n
FROM dim_date
GROUP BY date_key
HAVING COUNT(*) > 1;

-- CHECK: dim_menu_item primary key (item_key) is unique
SELECT item_key, COUNT(*) AS n
FROM dim_menu_item
GROUP BY item_key
HAVING COUNT(*) > 1;

-- CHECK: fact_order_line has no orphan date_key (every line's date exists in dim_date)
SELECT fol.*
FROM fact_order_line fol
LEFT JOIN dim_date dd ON fol.date_key = dd.date_key
WHERE dd.date_key IS NULL;

-- CHECK: fact_order_line has no orphan item_key
SELECT fol.*
FROM fact_order_line fol
LEFT JOIN dim_menu_item dm ON fol.item_key = dm.item_key
WHERE dm.item_key IS NULL;

-- CHECK: fact_order_line has no orphan daypart_key
SELECT fol.*
FROM fact_order_line fol
LEFT JOIN dim_daypart ddp ON fol.daypart_key = ddp.daypart_key
WHERE ddp.daypart_key IS NULL;

-- CHECK: fact_order_line has no orphan channel_key
SELECT fol.*
FROM fact_order_line fol
LEFT JOIN dim_channel dc ON fol.channel_key = dc.channel_key
WHERE dc.channel_key IS NULL;

-- CHECK: order lines reconcile to daily_sales.csv's sales total within $1
-- (the tolerance accounts for the per-day cent-rounding done when the
-- order lines were generated — see simulate_transactions.py)
WITH line_totals AS (
    SELECT date_key, SUM(net_sales) AS line_sales
    FROM fact_order_line
    GROUP BY date_key
)
SELECT fds.date_key, fds.sales, COALESCE(lt.line_sales, 0) AS line_sales
FROM fact_daily_sales fds
LEFT JOIN line_totals lt ON fds.date_key = lt.date_key
WHERE NOT fds.is_closed
  AND NOT fds.is_pos_outage
  AND ABS(fds.sales - COALESCE(lt.line_sales, 0)) > 1.0;

-- CHECK: closed or POS-outage days have zero order lines
SELECT DISTINCT fds.date_key
FROM fact_daily_sales fds
JOIN fact_order_line fol ON fds.date_key = fol.date_key
WHERE fds.is_closed OR fds.is_pos_outage;

-- CHECK: no negative amounts on fact_order_line
SELECT *
FROM fact_order_line
WHERE net_sales < 0 OR food_cost < 0 OR quantity <= 0;

-- CHECK: no negative amounts on fact_daily_sales (nulls on outage days are fine)
SELECT *
FROM fact_daily_sales
WHERE (sales IS NOT NULL AND sales < 0)
   OR (covers IS NOT NULL AND covers < 0);
