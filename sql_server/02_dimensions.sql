-- SQL Server version of sql/02_dimensions.sql.
-- Unlike staging, dimensions get explicit CREATE TABLE with a PRIMARY KEY
-- (named pk_<table>, so a violation names the table instead of an
-- auto-generated PK__dim_chan__DC18D475... string):
-- they're the contract the fact tables and Power BI depend on, so their
-- types and keys are spelled out rather than inferred from a SELECT INTO.

SET NOCOUNT ON;

-- The fact tables hold FOREIGN KEYs pointing at these dimensions, and SQL
-- Server won't drop a table that's still referenced — so on a re-run the
-- facts have to go first. 03_facts.sql recreates them.
DROP TABLE IF EXISTS fact_order_line;
DROP TABLE IF EXISTS fact_daily_sales;
GO

-- ---------------------------------------------------------------- dim_date
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
    date_key                       INT          NOT NULL CONSTRAINT pk_dim_date PRIMARY KEY,
    [date]                         DATE         NOT NULL,
    day_of_week                    NVARCHAR(10) NOT NULL,
    day_of_week_num                TINYINT      NOT NULL,  -- 0 = Sunday .. 6 = Saturday
    is_weekend                     BIT          NOT NULL,
    [month]                        TINYINT      NOT NULL,
    month_name                     NVARCHAR(10) NOT NULL,
    year_month                     CHAR(7)      NOT NULL,  -- 'YYYY-MM'
    [quarter]                      TINYINT      NOT NULL,
    [year]                         SMALLINT     NOT NULL,
    is_major_holiday               BIT          NOT NULL,
    is_signature_promo_day         BIT          NOT NULL,
    is_thanksgiving_special        BIT          NOT NULL,
    is_christmas_week_special      BIT          NOT NULL,
    is_summer_deal_active          BIT          NOT NULL,
    is_grad_season                 BIT          NOT NULL,
    is_major_sporting_event_window BIT          NOT NULL,
    is_special_day                 BIT          NOT NULL
);

INSERT INTO dim_date
SELECT
    -- CONVERT style 112 = 'yyyymmdd'. Preferred over FORMAT(), which goes
    -- through .NET and is much slower on large tables.
    CONVERT(INT, CONVERT(CHAR(8), [date], 112)),
    [date],
    day_of_week,
    -- DATEPART(WEEKDAY) depends on the server's SET DATEFIRST setting.
    -- Adding @@DATEFIRST and taking % 7 always gives 0 = Sunday, whatever
    -- the setting, matching DuckDB's dayofweek().
    (DATEPART(WEEKDAY, [date]) + @@DATEFIRST - 1) % 7,
    is_weekend,
    [month],
    DATENAME(MONTH, [date]),
    -- Style 126 is ISO 8601 ('yyyy-mm-ddThh:mi:ss'); CHAR(7) keeps 'yyyy-mm'.
    CONVERT(CHAR(7), [date], 126),
    DATEPART(QUARTER, [date]),
    YEAR([date]),
    is_major_holiday,
    is_signature_promo_day,
    is_thanksgiving_special,
    is_christmas_week_special,
    is_summer_deal_active,
    is_grad_season,
    is_major_sporting_event_window,
    is_special_day
FROM stg_daily_sales;
GO

-- ---------------------------------------------------------------- dim_menu_item
-- item_id is reused as the surrogate key, same reasoning as the DuckDB version.
DROP TABLE IF EXISTS dim_menu_item;
CREATE TABLE dim_menu_item (
    item_key  INT           NOT NULL CONSTRAINT pk_dim_menu_item PRIMARY KEY,
    item_id   INT           NOT NULL,
    item_name NVARCHAR(100) NOT NULL,
    category  NVARCHAR(50)  NOT NULL,
    price     DECIMAL(10,2) NOT NULL,
    food_cost DECIMAL(10,2) NOT NULL
);

INSERT INTO dim_menu_item (item_key, item_id, item_name, category, price, food_cost)
SELECT item_id, item_id, item_name, category, price, food_cost
FROM stg_menu_items;
GO

-- ---------------------------------------------------------------- small dims
DROP TABLE IF EXISTS dim_daypart;
CREATE TABLE dim_daypart (
    daypart_key INT          NOT NULL CONSTRAINT pk_dim_daypart PRIMARY KEY,
    daypart     NVARCHAR(20) NOT NULL,
    sort_order  TINYINT      NOT NULL
);
INSERT INTO dim_daypart VALUES
    (1, 'Lunch',     1),
    (2, 'Afternoon', 2),
    (3, 'Dinner',    3),
    (4, 'Late',      4);

DROP TABLE IF EXISTS dim_channel;
CREATE TABLE dim_channel (
    channel_key INT          NOT NULL CONSTRAINT pk_dim_channel PRIMARY KEY,
    channel     NVARCHAR(20) NOT NULL
);
INSERT INTO dim_channel VALUES
    (1, 'Dine-in'),
    (2, 'Takeout');

DROP TABLE IF EXISTS dim_weather;
CREATE TABLE dim_weather (
    weather_key   INT          NOT NULL CONSTRAINT pk_dim_weather PRIMARY KEY,
    weather       NVARCHAR(20) NOT NULL,
    weather_label NVARCHAR(20) NOT NULL
);
INSERT INTO dim_weather VALUES
    (1, 'clear',      'Clear'),
    (2, 'rain',       'Rain'),
    (3, 'heavy_rain', 'Heavy Rain'),
    (4, 'snow',       'Snow');
GO
