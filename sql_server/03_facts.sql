-- SQL Server version of sql/03_facts.sql. Same two facts at the same two
-- grains; the difference is that the keys are enforced by the engine:
-- the PRIMARY KEY guarantees the grain (one row per line / per day) and
-- each FOREIGN KEY makes an orphan key fail the INSERT outright, instead of
-- only being caught later by a quality check.

SET NOCOUNT ON;

DROP TABLE IF EXISTS fact_order_line;
DROP TABLE IF EXISTS fact_daily_sales;
GO

-- ---------------------------------------------------------------- fact_order_line
CREATE TABLE fact_order_line (
    order_line_id INT           NOT NULL CONSTRAINT pk_fact_order_line PRIMARY KEY,
    date_key      INT           NOT NULL CONSTRAINT fk_fact_order_line_date    REFERENCES dim_date (date_key),
    item_key      INT           NOT NULL CONSTRAINT fk_fact_order_line_item    REFERENCES dim_menu_item (item_key),
    daypart_key   INT           NOT NULL CONSTRAINT fk_fact_order_line_daypart REFERENCES dim_daypart (daypart_key),
    channel_key   INT           NOT NULL CONSTRAINT fk_fact_order_line_channel REFERENCES dim_channel (channel_key),
    order_id      INT           NOT NULL,
    quantity      INT           NOT NULL,
    net_sales     DECIMAL(10,2) NOT NULL,
    food_cost     DECIMAL(10,2) NOT NULL
);

-- No ORDER BY needed (the DuckDB version has one): the clustered primary
-- key on order_line_id already fixes how rows are stored, and SQL Server
-- never promises a row order to a reader that doesn't ask for one anyway.
INSERT INTO fact_order_line
    (order_line_id, date_key, item_key, daypart_key, channel_key, order_id, quantity, net_sales, food_cost)
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
JOIN dim_date dd      ON dd.[date] = o.[date]
JOIN dim_menu_item dm ON dm.item_id = ol.item_id
JOIN dim_daypart ddp  ON ddp.daypart = o.daypart
JOIN dim_channel dc   ON dc.channel = o.channel;
GO

-- ---------------------------------------------------------------- fact_daily_sales
-- weather_key is left nullable to mirror the DuckDB LEFT JOIN; the quality
-- checks are what flag a NULL there.
CREATE TABLE fact_daily_sales (
    date_key       INT           NOT NULL CONSTRAINT pk_fact_daily_sales PRIMARY KEY
                                          CONSTRAINT fk_fact_daily_sales_date REFERENCES dim_date (date_key),
    weather_key    INT           NULL     CONSTRAINT fk_fact_daily_sales_weather REFERENCES dim_weather (weather_key),
    covers         INT           NULL,
    sales          DECIMAL(12,2) NULL,
    labor_cost_pct DECIMAL(6,4)  NULL,
    is_closed      BIT           NOT NULL,
    is_pos_outage  BIT           NOT NULL
);

INSERT INTO fact_daily_sales
    (date_key, weather_key, covers, sales, labor_cost_pct, is_closed, is_pos_outage)
SELECT
    dd.date_key,
    dw.weather_key,
    sd.covers,
    sd.sales,
    sd.labor_cost_pct,
    sd.is_closed,
    sd.is_pos_outage
FROM stg_daily_sales sd
JOIN dim_date dd         ON dd.[date] = sd.[date]
LEFT JOIN dim_weather dw ON dw.weather = sd.weather;
GO
