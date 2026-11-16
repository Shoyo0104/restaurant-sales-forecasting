-- SQL Server version of sql/04_quality_checks.sql: the same 13 checks.
-- Each inner query is the same "returns zero rows when healthy" query as the
-- DuckDB version; here each one is wrapped in COUNT(*) and logged to a temp
-- table, so the script reports PASS/FAIL itself and THROWs at the end if
-- anything failed. Run with `sqlcmd -b` and that THROW becomes a non-zero
-- exit code — the T-SQL equivalent of build_warehouse.py failing the build.
--
-- With PRIMARY/FOREIGN KEY constraints in place (02/03), the uniqueness and
-- orphan checks can't fail as long as the constraints are trusted. They stay
-- anyway: in practice teams disable constraints for fast bulk loads
-- (ALTER TABLE ... NOCHECK CONSTRAINT), and these checks still catch what
-- that lets through.

SET NOCOUNT ON;

DROP TABLE IF EXISTS #check_results;
CREATE TABLE #check_results (
    check_id   INT IDENTITY(1, 1) PRIMARY KEY,
    check_name NVARCHAR(200) NOT NULL,
    bad_rows   INT           NOT NULL
);

-- CHECK: dim_date primary key (date_key) is unique
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'dim_date primary key (date_key) is unique', COUNT(*)
FROM (SELECT date_key FROM dim_date GROUP BY date_key HAVING COUNT(*) > 1) AS bad;

-- CHECK: dim_menu_item primary key (item_key) is unique
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'dim_menu_item primary key (item_key) is unique', COUNT(*)
FROM (SELECT item_key FROM dim_menu_item GROUP BY item_key HAVING COUNT(*) > 1) AS bad;

-- CHECK: fact_daily_sales grain holds (exactly one row per date_key)
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_daily_sales grain holds (one row per date_key)', COUNT(*)
FROM (SELECT date_key FROM fact_daily_sales GROUP BY date_key HAVING COUNT(*) > 1) AS bad;

-- CHECK: fact_order_line grain holds (exactly one row per order_line_id)
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_order_line grain holds (one row per order_line_id)', COUNT(*)
FROM (SELECT order_line_id FROM fact_order_line GROUP BY order_line_id HAVING COUNT(*) > 1) AS bad;

-- CHECK: fact_daily_sales has no orphan or missing weather_key
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_daily_sales has no orphan or missing weather_key', COUNT(*)
FROM fact_daily_sales fds
LEFT JOIN dim_weather dw ON fds.weather_key = dw.weather_key
WHERE dw.weather_key IS NULL;

-- CHECK: fact_order_line has no orphan date_key
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_order_line has no orphan date_key', COUNT(*)
FROM fact_order_line fol
LEFT JOIN dim_date dd ON fol.date_key = dd.date_key
WHERE dd.date_key IS NULL;

-- CHECK: fact_order_line has no orphan item_key
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_order_line has no orphan item_key', COUNT(*)
FROM fact_order_line fol
LEFT JOIN dim_menu_item dm ON fol.item_key = dm.item_key
WHERE dm.item_key IS NULL;

-- CHECK: fact_order_line has no orphan daypart_key
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_order_line has no orphan daypart_key', COUNT(*)
FROM fact_order_line fol
LEFT JOIN dim_daypart ddp ON fol.daypart_key = ddp.daypart_key
WHERE ddp.daypart_key IS NULL;

-- CHECK: fact_order_line has no orphan channel_key
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'fact_order_line has no orphan channel_key', COUNT(*)
FROM fact_order_line fol
LEFT JOIN dim_channel dc ON fol.channel_key = dc.channel_key
WHERE dc.channel_key IS NULL;

-- CHECK: order lines reconcile to daily_sales.csv's sales total within $1
-- (a CTE has to come before the INSERT in T-SQL, and the statement before a
-- WITH must end in a semicolon)
WITH line_totals AS (
    SELECT date_key, SUM(net_sales) AS line_sales
    FROM fact_order_line
    GROUP BY date_key
)
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'order lines reconcile to daily sales within $1', COUNT(*)
FROM fact_daily_sales fds
LEFT JOIN line_totals lt ON fds.date_key = lt.date_key
WHERE fds.is_closed = 0
  AND fds.is_pos_outage = 0
  AND ABS(fds.sales - COALESCE(lt.line_sales, 0)) > 1.0;

-- CHECK: closed or POS-outage days have zero order lines
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'closed or POS-outage days have zero order lines', COUNT(DISTINCT fds.date_key)
FROM fact_daily_sales fds
JOIN fact_order_line fol ON fds.date_key = fol.date_key
WHERE fds.is_closed = 1 OR fds.is_pos_outage = 1;

-- CHECK: no negative amounts on fact_order_line
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'no negative amounts on fact_order_line', COUNT(*)
FROM fact_order_line
WHERE net_sales < 0 OR food_cost < 0 OR quantity <= 0;

-- CHECK: no negative amounts on fact_daily_sales (NULLs on outage days are fine)
-- (a comparison with NULL is never true, so outage-day NULLs drop out without
-- needing the explicit IS NOT NULL the DuckDB version spells out)
INSERT INTO #check_results (check_name, bad_rows)
SELECT 'no negative amounts on fact_daily_sales', COUNT(*)
FROM fact_daily_sales
WHERE sales < 0 OR covers < 0;

SELECT
    check_name,
    bad_rows,
    CASE WHEN bad_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM #check_results
ORDER BY check_id;

IF EXISTS (SELECT 1 FROM #check_results WHERE bad_rows > 0)
    THROW 50000, 'One or more data-quality checks failed - see the results above.', 1;
GO
