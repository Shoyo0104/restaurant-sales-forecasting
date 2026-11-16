-- Analytical queries, saved as views so they're always queryable against
-- the finished warehouse (and easy to point a BI tool or `duckdb` CLI at
-- directly). Each one is the kind of question a BI team is actually asked,
-- answered with CTEs and window functions rather than procedural code.

-- vw_monthly_sales_yoy: monthly sales with year-over-year % change.
-- LAG(..., 1) PARTITION BY month lines up "this month" against "the same
-- month last year" without a self-join.
CREATE OR REPLACE VIEW vw_monthly_sales_yoy AS
WITH monthly AS (
    SELECT dd.year, dd.month, SUM(fds.sales) AS monthly_sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
    WHERE NOT fds.is_closed AND NOT fds.is_pos_outage
    GROUP BY dd.year, dd.month
)
SELECT
    year,
    month,
    monthly_sales,
    LAG(monthly_sales) OVER (PARTITION BY month ORDER BY year) AS monthly_sales_ly,
    ROUND(
        100.0 * (monthly_sales - LAG(monthly_sales) OVER (PARTITION BY month ORDER BY year))
        / LAG(monthly_sales) OVER (PARTITION BY month ORDER BY year),
        1
    ) AS yoy_pct_change
FROM monthly
ORDER BY year, month;

-- vw_rolling_sales: 7-day and 28-day trailing average sales. Windows are
-- defined over calendar order, not row count, but since outage days are
-- excluded (no sales value to average) the window silently skips those
-- gaps rather than mis-measuring the usual 7/28-day span — a known, minor
-- simplification worth calling out in an interview.
CREATE OR REPLACE VIEW vw_rolling_sales AS
SELECT
    dd.date,
    fds.sales,
    AVG(fds.sales) OVER (ORDER BY dd.date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)  AS rolling_7d_avg,
    AVG(fds.sales) OVER (ORDER BY dd.date ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS rolling_28d_avg
FROM fact_daily_sales fds
JOIN dim_date dd ON fds.date_key = dd.date_key
WHERE NOT fds.is_closed AND NOT fds.is_pos_outage
ORDER BY dd.date;

-- vw_top_items_per_category: top 3 items per category by net sales.
-- RANK() (not ROW_NUMBER()) so a tie for 3rd place shows both rows instead
-- of arbitrarily picking one.
CREATE OR REPLACE VIEW vw_top_items_per_category AS
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
WHERE sales_rank <= 3
ORDER BY category, sales_rank;

-- vw_category_share: each category's share of total sales and its food
-- cost %. SUM(...) OVER () (no PARTITION BY) gives the grand total sales
-- on every row so the share can be computed without a second query.
CREATE OR REPLACE VIEW vw_category_share AS
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
FROM cat
ORDER BY category_sales DESC;

-- vw_weekday_weekend: average sales on weekdays vs weekends, and the ratio
-- between them (the number the original daily simulation was calibrated
-- against — see the main README's "Calibration approach" table).
CREATE OR REPLACE VIEW vw_weekday_weekend AS
WITH wk AS (
    SELECT dd.is_weekend, AVG(fds.sales) AS avg_sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
    WHERE NOT fds.is_closed AND NOT fds.is_pos_outage
    GROUP BY dd.is_weekend
)
SELECT
    MAX(CASE WHEN NOT is_weekend THEN avg_sales END) AS avg_weekday_sales,
    MAX(CASE WHEN is_weekend THEN avg_sales END)     AS avg_weekend_sales,
    ROUND(
        MAX(CASE WHEN is_weekend THEN avg_sales END) / MAX(CASE WHEN NOT is_weekend THEN avg_sales END),
        2
    ) AS weekend_weekday_ratio
FROM wk;

-- vw_daypart_channel_mix: sales and order counts by daypart x channel,
-- broken out by month, for the "Menu & Daypart" report page's matrix visual.
CREATE OR REPLACE VIEW vw_daypart_channel_mix AS
SELECT
    dd.year,
    dd.month,
    ddp.daypart,
    ddp.sort_order AS daypart_sort_order,
    dc.channel,
    SUM(fol.net_sales)            AS sales,
    COUNT(DISTINCT fol.order_id)  AS orders
FROM fact_order_line fol
JOIN dim_date dd     ON fol.date_key = dd.date_key
JOIN dim_daypart ddp ON fol.daypart_key = ddp.daypart_key
JOIN dim_channel dc  ON fol.channel_key = dc.channel_key
GROUP BY dd.year, dd.month, ddp.daypart, ddp.sort_order, dc.channel
ORDER BY dd.year, dd.month, ddp.sort_order, dc.channel;

-- vw_weather_impact: average daily sales by weather type, and the % swing
-- versus clear days (the baseline the daily simulation's weather
-- multipliers were calibrated against).
CREATE OR REPLACE VIEW vw_weather_impact AS
WITH weather_avg AS (
    SELECT dw.weather_label, AVG(fds.sales) AS avg_sales
    FROM fact_daily_sales fds
    JOIN dim_weather dw ON fds.weather_key = dw.weather_key
    WHERE NOT fds.is_closed AND NOT fds.is_pos_outage
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
FROM weather_avg
ORDER BY avg_sales DESC;
