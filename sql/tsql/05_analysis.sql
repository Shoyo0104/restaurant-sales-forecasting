-- SQL Server version of sql/05_analysis.sql: the same 7 views.
-- Two T-SQL rules shape this file:
--   * CREATE VIEW must be the only statement in its batch, hence a GO after
--     every view (CREATE OR ALTER keeps the script re-runnable).
--   * A view can't contain ORDER BY (without TOP), so the ORDER BY clauses
--     from the DuckDB views are gone — sort when you SELECT from the view.

-- vw_monthly_sales_yoy: monthly sales with year-over-year % change, compared
-- on average sales per trading day so partial months (Dec 2023, Jul 2026)
-- and POS-outage days don't produce fake swings. See the DuckDB file.
CREATE OR ALTER VIEW vw_monthly_sales_yoy AS
WITH monthly AS (
    SELECT
        dd.[year],
        dd.[month],
        COUNT(*) AS calendar_days_in_data,
        -- DuckDB's COUNT(...) FILTER (WHERE ...) doesn't exist in T-SQL;
        -- SUM(CASE ... THEN 1 ELSE 0 END) is the standard equivalent.
        SUM(CASE WHEN fds.sales IS NOT NULL AND fds.is_closed = 0 THEN 1 ELSE 0 END) AS trading_days,
        SUM(fds.sales) AS monthly_sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
    GROUP BY dd.[year], dd.[month]
),
with_avg AS (
    SELECT
        *,
        -- EOMONTH gives the month's last date, so DAY() of it is the month length.
        CASE WHEN calendar_days_in_data < DAY(EOMONTH(DATEFROMPARTS([year], [month], 1)))
             THEN 1 ELSE 0 END                AS is_partial_month,
        monthly_sales / NULLIF(trading_days, 0) AS avg_daily_sales
    FROM monthly
),
with_ly AS (
    SELECT
        *,
        LAG(avg_daily_sales)  OVER (PARTITION BY [month] ORDER BY [year]) AS avg_daily_sales_ly,
        LAG(is_partial_month) OVER (PARTITION BY [month] ORDER BY [year]) AS ly_is_partial_month
    FROM with_avg
)
SELECT
    [year],
    [month],
    monthly_sales,
    trading_days,
    is_partial_month,
    ROUND(avg_daily_sales, 2)    AS avg_daily_sales,
    ROUND(avg_daily_sales_ly, 2) AS avg_daily_sales_ly,
    CASE WHEN is_partial_month = 0 AND ly_is_partial_month = 0
         THEN ROUND(100.0 * (avg_daily_sales - avg_daily_sales_ly) / avg_daily_sales_ly, 1)
    END AS yoy_pct_change
FROM with_ly;
GO

-- vw_rolling_sales: 7-day and 28-day trailing averages over *calendar* days.
-- DuckDB does this with RANGE BETWEEN INTERVAL 6 DAYS PRECEDING; T-SQL only
-- supports ROWS (or RANGE without an interval). The workaround is a date
-- spine: fact_daily_sales already has one row for every calendar day,
-- closed and outage days included, so "6 rows back" is exactly "6 days
-- back". Closed/outage days get a NULL sales value, which AVG skips, and
-- they're filtered out only after the window has been computed.
CREATE OR ALTER VIEW vw_rolling_sales AS
WITH spine AS (
    SELECT
        dd.[date],
        CASE WHEN fds.is_closed = 0 AND fds.is_pos_outage = 0 THEN fds.sales END AS sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
),
windowed AS (
    SELECT
        [date],
        sales,
        AVG(sales) OVER (ORDER BY [date] ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)  AS rolling_7d_avg,
        AVG(sales) OVER (ORDER BY [date] ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS rolling_28d_avg
    FROM spine
)
SELECT [date], sales, rolling_7d_avg, rolling_28d_avg
FROM windowed
WHERE sales IS NOT NULL;
GO

-- vw_top_items_per_category: top 3 items per category by net sales (RANK so ties show).
CREATE OR ALTER VIEW vw_top_items_per_category AS
WITH item_sales AS (
    SELECT dm.category, dm.item_name, SUM(fol.net_sales) AS total_sales
    FROM fact_order_line fol
    JOIN dim_menu_item dm ON fol.item_key = dm.item_key
    GROUP BY dm.category, dm.item_name
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY category ORDER BY total_sales DESC) AS sales_rank
    FROM item_sales
)
SELECT category, item_name, total_sales, sales_rank
FROM ranked
WHERE sales_rank <= 3;
GO

-- vw_category_share: category share of sales (SUM() OVER () = grand total) and food cost %.
CREATE OR ALTER VIEW vw_category_share AS
WITH cat AS (
    SELECT dm.category, SUM(fol.net_sales) AS category_sales, SUM(fol.food_cost) AS category_food_cost
    FROM fact_order_line fol
    JOIN dim_menu_item dm ON fol.item_key = dm.item_key
    GROUP BY dm.category
)
SELECT
    category,
    category_sales,
    category_food_cost,
    ROUND(100.0 * category_sales / SUM(category_sales) OVER (), 1) AS pct_of_total_sales,
    ROUND(100.0 * category_food_cost / category_sales, 1)          AS food_cost_pct
FROM cat;
GO

-- vw_weekday_weekend: average weekday vs weekend sales and the ratio.
-- BIT columns compare to 0/1; T-SQL has no NOT on a bare BIT like DuckDB's booleans.
CREATE OR ALTER VIEW vw_weekday_weekend AS
WITH wk AS (
    SELECT dd.is_weekend, AVG(fds.sales) AS avg_sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
    WHERE fds.is_closed = 0 AND fds.is_pos_outage = 0
    GROUP BY dd.is_weekend
)
SELECT
    MAX(CASE WHEN is_weekend = 0 THEN avg_sales END) AS avg_weekday_sales,
    MAX(CASE WHEN is_weekend = 1 THEN avg_sales END) AS avg_weekend_sales,
    ROUND(
        MAX(CASE WHEN is_weekend = 1 THEN avg_sales END) / MAX(CASE WHEN is_weekend = 0 THEN avg_sales END),
        2
    ) AS weekend_weekday_ratio
FROM wk;
GO

-- vw_daypart_channel_mix: sales and orders by daypart x channel, by month.
CREATE OR ALTER VIEW vw_daypart_channel_mix AS
SELECT
    dd.[year],
    dd.[month],
    ddp.daypart,
    ddp.sort_order               AS daypart_sort_order,
    dc.channel,
    SUM(fol.net_sales)           AS sales,
    COUNT(DISTINCT fol.order_id) AS orders
FROM fact_order_line fol
JOIN dim_date dd     ON fol.date_key = dd.date_key
JOIN dim_daypart ddp ON fol.daypart_key = ddp.daypart_key
JOIN dim_channel dc  ON fol.channel_key = dc.channel_key
GROUP BY dd.[year], dd.[month], ddp.daypart, ddp.sort_order, dc.channel;
GO

-- vw_weather_impact: average daily sales by weather and % vs clear days.
CREATE OR ALTER VIEW vw_weather_impact AS
WITH weather_avg AS (
    SELECT dw.weather_label, AVG(fds.sales) AS avg_sales
    FROM fact_daily_sales fds
    JOIN dim_weather dw ON fds.weather_key = dw.weather_key
    WHERE fds.is_closed = 0 AND fds.is_pos_outage = 0
    GROUP BY dw.weather_label
)
SELECT
    weather_label,
    avg_sales,
    ROUND(
        100.0 * (avg_sales - MAX(CASE WHEN weather_label = 'Clear' THEN avg_sales END) OVER ())
        / MAX(CASE WHEN weather_label = 'Clear' THEN avg_sales END) OVER (),
        1
    ) AS pct_vs_clear
FROM weather_avg;
GO
