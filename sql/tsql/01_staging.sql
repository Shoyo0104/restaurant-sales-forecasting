-- SQL Server version of sql/01_staging.sql.
-- Run with sqlcmd (or SSMS in SQLCMD mode): $(DataDir) is a sqlcmd variable
-- holding the folder with the CSVs *as the SQL Server process sees it*
-- (inside Docker that's the mounted path, e.g. /repo/data — see README.md).
--
-- Two steps instead of DuckDB's one: BULK INSERT lands every file into an
-- all-text raw_ table first, then the stg_ table casts the types. Loading
-- straight into typed columns would make the whole load fail on the first
-- odd value (e.g. the empty sales field on a POS-outage day), whereas
-- TRY_CAST on text turns those into NULLs we can see and check.

SET NOCOUNT ON;

-- ---------------------------------------------------------------- daily sales
DROP TABLE IF EXISTS raw_daily_sales;
CREATE TABLE raw_daily_sales (
    [date] NVARCHAR(100), is_weekend NVARCHAR(100), is_major_holiday NVARCHAR(100),
    is_signature_promo_day NVARCHAR(100), is_thanksgiving_special NVARCHAR(100),
    is_christmas_week_special NVARCHAR(100), is_closed NVARCHAR(100),
    is_summer_deal_active NVARCHAR(100), is_grad_season NVARCHAR(100),
    is_major_sporting_event_window NVARCHAR(100), is_special_day NVARCHAR(100),
    day_of_week NVARCHAR(100), [month] NVARCHAR(100), weather NVARCHAR(100),
    covers NVARCHAR(100), avg_check NVARCHAR(100), sales NVARCHAR(100),
    labor_cost_pct NVARCHAR(100), is_pos_outage NVARCHAR(100)
);

-- FIRSTROW = 2 skips the header; '0x0a' because the files use Unix line endings.
BULK INSERT raw_daily_sales FROM '$(DataDir)/daily_sales.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');

DROP TABLE IF EXISTS stg_daily_sales;
-- SELECT INTO (create the table from the query) is fine for staging tables:
-- they're rebuilt on every run and nothing else depends on their exact DDL.
-- TRY_CAST(... AS BIT) understands 'True'/'False'. NULLIF(x, '') guards
-- against empty fields arriving as '' instead of NULL.
SELECT
    CAST([date] AS DATE)                                     AS [date],
    TRY_CAST(is_weekend AS BIT)                              AS is_weekend,
    TRY_CAST(is_major_holiday AS BIT)                        AS is_major_holiday,
    TRY_CAST(is_signature_promo_day AS BIT)                  AS is_signature_promo_day,
    TRY_CAST(is_thanksgiving_special AS BIT)                 AS is_thanksgiving_special,
    TRY_CAST(is_christmas_week_special AS BIT)               AS is_christmas_week_special,
    TRY_CAST(is_closed AS BIT)                               AS is_closed,
    TRY_CAST(is_summer_deal_active AS BIT)                   AS is_summer_deal_active,
    TRY_CAST(is_grad_season AS BIT)                          AS is_grad_season,
    TRY_CAST(is_major_sporting_event_window AS BIT)          AS is_major_sporting_event_window,
    TRY_CAST(is_special_day AS BIT)                          AS is_special_day,
    day_of_week,
    CAST([month] AS TINYINT)                                 AS [month],
    weather,
    -- covers arrives as text like '755.0' (pandas writes the column as float
    -- because outage days are NaN), so go through DECIMAL to get to INT.
    CAST(TRY_CAST(NULLIF(covers, '') AS DECIMAL(10, 1)) AS INT) AS covers,
    TRY_CAST(NULLIF(avg_check, '') AS DECIMAL(10, 2))        AS avg_check,
    TRY_CAST(NULLIF(sales, '') AS DECIMAL(12, 2))            AS sales,
    TRY_CAST(NULLIF(labor_cost_pct, '') AS DECIMAL(6, 4))    AS labor_cost_pct,
    TRY_CAST(is_pos_outage AS BIT)                           AS is_pos_outage
INTO stg_daily_sales
FROM raw_daily_sales;
GO

-- ---------------------------------------------------------------- menu items
DROP TABLE IF EXISTS raw_menu_items;
CREATE TABLE raw_menu_items (
    item_id NVARCHAR(100), item_name NVARCHAR(100), category NVARCHAR(100),
    price NVARCHAR(100), food_cost NVARCHAR(100)
);

BULK INSERT raw_menu_items FROM '$(DataDir)/menu_items.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');

DROP TABLE IF EXISTS stg_menu_items;
SELECT
    CAST(item_id AS INT)              AS item_id,
    item_name,
    category,
    CAST(price AS DECIMAL(10, 2))     AS price,
    CAST(food_cost AS DECIMAL(10, 2)) AS food_cost
INTO stg_menu_items
FROM raw_menu_items;
GO

-- ---------------------------------------------------------------- orders
-- orders.csv / order_lines.csv come from src/export_raw_csv.py (SQL Server
-- can't read the parquet files the DuckDB pipeline uses).
DROP TABLE IF EXISTS raw_orders;
CREATE TABLE raw_orders (
    order_id NVARCHAR(100), [date] NVARCHAR(100), [timestamp] NVARCHAR(100),
    daypart NVARCHAR(100), channel NVARCHAR(100), party_size NVARCHAR(100)
);

BULK INSERT raw_orders FROM '$(DataDir)/orders.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');

DROP TABLE IF EXISTS stg_orders;
-- [timestamp] is bracketed because TIMESTAMP is a reserved word in T-SQL.
SELECT
    CAST(order_id AS INT)            AS order_id,
    CAST([date] AS DATE)             AS [date],
    CAST([timestamp] AS DATETIME2(0)) AS [timestamp],
    daypart,
    channel,
    CAST(party_size AS INT)          AS party_size
INTO stg_orders
FROM raw_orders;
GO

-- ---------------------------------------------------------------- order lines
DROP TABLE IF EXISTS raw_order_lines;
CREATE TABLE raw_order_lines (
    order_line_id NVARCHAR(100), order_id NVARCHAR(100), item_id NVARCHAR(100),
    quantity NVARCHAR(100), unit_price NVARCHAR(100), net_sales NVARCHAR(100),
    food_cost NVARCHAR(100)
);

BULK INSERT raw_order_lines FROM '$(DataDir)/order_lines.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

DROP TABLE IF EXISTS stg_order_lines;
SELECT
    CAST(order_line_id AS INT)        AS order_line_id,
    CAST(order_id AS INT)             AS order_id,
    CAST(item_id AS INT)              AS item_id,
    CAST(quantity AS INT)             AS quantity,
    CAST(unit_price AS DECIMAL(10, 2)) AS unit_price,
    CAST(net_sales AS DECIMAL(10, 2)) AS net_sales,
    CAST(food_cost AS DECIMAL(10, 2)) AS food_cost
INTO stg_order_lines
FROM raw_order_lines;
GO
