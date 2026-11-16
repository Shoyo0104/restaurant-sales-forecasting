-- Dimensions. Each gets a surrogate key (date_key, item_key, ...) rather than
-- joining facts straight to natural keys like the raw date or item name —
-- that's what lets a natural key change upstream (e.g. a menu item gets
-- renamed) without having to rebuild every fact row that points to it.

-- dim_date: one row per calendar day in the simulation window, built
-- straight from stg_daily_sales because that file already has a row for
-- every day in range — closed and POS-outage days included, just with null
-- metrics. date_key is YYYYMMDD as an INTEGER, the standard Power BI/BI
-- convention for a date dimension's surrogate key.
CREATE OR REPLACE TABLE dim_date AS
SELECT
    CAST(strftime(date, '%Y%m%d') AS INTEGER) AS date_key,
    date,
    day_of_week,
    dayofweek(date)                           AS day_of_week_num,  -- 0=Sunday .. 6=Saturday
    is_weekend,
    month,
    monthname(date)                           AS month_name,
    quarter(date)                             AS quarter,
    year(date)                                AS year,
    is_major_holiday,
    is_signature_promo_day,
    is_thanksgiving_special,
    is_christmas_week_special,
    is_summer_deal_active,
    is_grad_season,
    is_major_sporting_event_window,
    is_special_day
FROM stg_daily_sales
ORDER BY date;

-- dim_menu_item: one row per menu item. item_id already comes out of the
-- generator as a small, dense, stable integer, so it's reused directly as
-- the surrogate key here rather than minting a second one that would just
-- track it 1:1 — in a warehouse fed by a real POS, item_id could be
-- reassigned over time, and the surrogate key is what would insulate the
-- fact table from that.
CREATE OR REPLACE TABLE dim_menu_item AS
SELECT
    item_id AS item_key,
    item_id,
    item_name,
    category,
    price,
    food_cost
FROM stg_menu_items
ORDER BY item_id;

-- dim_daypart: small, hand-built dimension. sort_order exists purely so
-- charts/slicers show Lunch -> Afternoon -> Dinner -> Late instead of
-- whatever order alphabetical sorting would give.
CREATE OR REPLACE TABLE dim_daypart AS
SELECT * FROM (VALUES
    (1, 'Lunch',     1),
    (2, 'Afternoon', 2),
    (3, 'Dinner',    3),
    (4, 'Late',      4)
) AS t(daypart_key, daypart, sort_order);

-- dim_channel
CREATE OR REPLACE TABLE dim_channel AS
SELECT * FROM (VALUES
    (1, 'Dine-in'),
    (2, 'Takeout')
) AS t(channel_key, channel);

-- dim_weather: weather_label is just a display-friendly version of the raw
-- code stored on daily_sales.csv (e.g. 'heavy_rain' -> 'Heavy Rain').
CREATE OR REPLACE TABLE dim_weather AS
SELECT * FROM (VALUES
    (1, 'clear',      'Clear'),
    (2, 'rain',       'Rain'),
    (3, 'heavy_rain', 'Heavy Rain'),
    (4, 'snow',       'Snow')
) AS t(weather_key, weather, weather_label);
