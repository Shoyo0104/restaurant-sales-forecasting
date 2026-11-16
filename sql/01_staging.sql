-- Staging layer: load the raw files as-is, casting to sane types.
-- Keeping this as its own layer (rather than building dims/facts straight
-- off the files) means a change in the source format only touches this one
-- file — the rest of the pipeline keeps reading from stable table names.

CREATE OR REPLACE TABLE stg_daily_sales AS
SELECT
    CAST(date AS DATE)                     AS date,
    is_weekend,
    is_major_holiday,
    is_signature_promo_day,
    is_thanksgiving_special,
    is_christmas_week_special,
    is_closed,
    is_summer_deal_active,
    is_grad_season,
    is_major_sporting_event_window,
    is_special_day,
    day_of_week,
    CAST(month AS INTEGER)                 AS month,
    weather,
    covers,
    avg_check,
    sales,
    labor_cost_pct,
    is_pos_outage
FROM read_csv_auto('data/daily_sales.csv');

CREATE OR REPLACE TABLE stg_menu_items AS
SELECT
    CAST(item_id AS INTEGER)               AS item_id,
    item_name,
    category,
    CAST(price AS DECIMAL(10,2))           AS price,
    CAST(food_cost AS DECIMAL(10,2))       AS food_cost
FROM read_csv_auto('data/menu_items.csv');

CREATE OR REPLACE TABLE stg_orders AS
SELECT
    CAST(order_id AS INTEGER)              AS order_id,
    CAST(date AS DATE)                     AS date,
    timestamp,
    daypart,
    channel,
    CAST(party_size AS INTEGER)            AS party_size
FROM read_parquet('data/orders.parquet');

CREATE OR REPLACE TABLE stg_order_lines AS
SELECT
    CAST(order_line_id AS INTEGER)         AS order_line_id,
    CAST(order_id AS INTEGER)              AS order_id,
    CAST(item_id AS INTEGER)               AS item_id,
    CAST(quantity AS INTEGER)              AS quantity,
    CAST(unit_price AS DECIMAL(10,2))      AS unit_price,
    CAST(net_sales AS DECIMAL(10,2))       AS net_sales,
    CAST(food_cost AS DECIMAL(10,2))       AS food_cost
FROM read_parquet('data/order_lines.parquet');
