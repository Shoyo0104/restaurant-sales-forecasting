-- Analytical queries, saved as views so they're always queryable against
-- the finished warehouse (and easy to point a BI tool or `duckdb` CLI at
-- directly). Each one is the kind of question a BI team is actually asked,
-- answered with CTEs and window functions rather than procedural code.

-- vw_monthly_sales_yoy: monthly sales with year-over-year % change.
-- LAG(..., 1) PARTITION BY month lines up "this month" against "the same
-- month last year" without a self-join.
-- YoY is computed on average sales per trading day, not the raw monthly
-- total: the data starts mid-December 2023 and ends mid-July 2026, and POS
-- outages remove a day here and there, so comparing raw totals would report
-- a fake +290% for Dec 2024 (vs. a 9-day Dec 2023). Months the data doesn't
-- fully cover are flagged and get no YoY at all.
CREATE OR REPLACE VIEW vw_monthly_sales_yoy AS
WITH monthly AS (
    SELECT
        dd.year,
        dd.month,
        COUNT(*)                                       AS calendar_days_in_data,
        COUNT(fds.sales) FILTER (WHERE NOT fds.is_closed) AS trading_days,
        SUM(fds.sales)                                 AS monthly_sales
    FROM fact_daily_sales fds
    JOIN dim_date dd ON fds.date_key = dd.date_key
    GROUP BY dd.year, dd.month
),
with_avg AS (
    SELECT
        *,
        -- last_day() gives the month's real length, so a month the data only
        -- partly covers can be told apart from a full one.
        calendar_days_in_data < day(last_day(make_date(year, month, 1))) AS is_partial_month,
        monthly_sales / trading_days AS avg_daily_sales
    FROM monthly
),
with_ly AS (
    SELECT
        *,
        LAG(avg_daily_sales)  OVER (PARTITION BY month ORDER BY year) AS avg_daily_sales_ly,
        LAG(is_partial_month) OVER (PARTITION BY month ORDER BY year) AS ly_is_partial_month
    FROM with_avg
)
SELECT
    year,
    month,
    monthly_sales,
    trading_days,
    is_partial_month,
    ROUND(avg_daily_sales, 2)    AS avg_daily_sales,
    ROUND(avg_daily_sales_ly, 2) AS avg_daily_sales_ly,
    CASE WHEN NOT is_partial_month AND NOT ly_is_partial_month
         THEN ROUND(100.0 * (avg_daily_sales - avg_daily_sales_ly) / avg_daily_sales_ly, 1)
    END AS yoy_pct_change
FROM with_ly
ORDER BY year, month;

-- vw_rolling_sales: 7-day and 28-day trailing average sales.
-- RANGE with a date INTERVAL (not ROWS BETWEEN 6 PRECEDING) so the window
-- always spans 7 calendar days: with ROWS, a skipped outage day would make
-- the "7-day" window silently reach back 8 days. Closed/outage days are
-- excluded, so those days just contribute nothing to the average.
CREATE OR REPLACE VIEW vw_rolling_sales AS
SELECT
    dd.date,
    fds.sales,
    AVG(fds.sales) OVER (ORDER BY dd.date RANGE BETWEEN INTERVAL 6 DAYS PRECEDING AND CURRENT ROW)  AS rolling_7d_avg,
    AVG(fds.sales) OVER (ORDER BY dd.date RANGE BETWEEN INTERVAL 27 DAYS PRECEDING AND CURRENT ROW) AS rolling_28d_avg
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
