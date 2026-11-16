-- Two fact tables, at two different grains, rather than one. They answer
-- different questions and forcing them into a single table would mean
-- either losing the order-line detail or repeating day-level metrics
-- (labor_cost_pct) on every line — a classic sign a model needs to be split.

-- fact_order_line: grain = one row per order line. This is what lets Power
-- BI slice sales by menu item, category, daypart, and channel.
-- order_line_id is carried through as a plain attribute (not a surrogate
-- key of its own) purely so the table has a stable sort key — DuckDB's
-- parallel joins don't preserve input row order, so without an explicit
-- ORDER BY, two builds from the same source files can come out byte-
-- different (same rows, different order), which breaks anything that diffs
-- the exported CSVs across runs.
CREATE OR REPLACE TABLE fact_order_line AS
SELECT
    ol.order_line_id,
    dd.date_key,
    dm.item_key,
    ddp.daypart_key,
    dc.channel_key,
    ol.order_id,
    ol.quantity,
    ol.net_sales,
    ol.food_cost
FROM stg_order_lines ol
JOIN stg_orders o     ON ol.order_id = o.order_id
JOIN dim_date dd      ON dd.date = o.date
JOIN dim_menu_item dm ON dm.item_id = ol.item_id
JOIN dim_daypart ddp  ON ddp.daypart = o.daypart
JOIN dim_channel dc   ON dc.channel = o.channel
ORDER BY ol.order_line_id;

-- fact_daily_sales: grain = one row per calendar day (940 rows). Kept
-- separate from fact_order_line rather than derived from it, because it
-- carries labor_cost_pct (no order-line equivalent) and because closed/
-- POS-outage days need to stay visible as explicit rows with null metrics —
-- re-aggregating fact_order_line would silently drop those days instead.
CREATE OR REPLACE TABLE fact_daily_sales AS
SELECT
    dd.date_key,
    dw.weather_key,
    sd.covers,
    sd.sales,
    sd.labor_cost_pct,
    sd.is_closed,
    sd.is_pos_outage
FROM stg_daily_sales sd
JOIN dim_date dd         ON dd.date = sd.date
LEFT JOIN dim_weather dw ON dw.weather = sd.weather
ORDER BY dd.date_key;
