# Power BI Build Guide (Power BI Service, in the browser)

This project has no Power BI Desktop step — everything below happens at
[app.powerbi.com](https://app.powerbi.com) in a web browser (built and
verified against the Power BI service's current "web modeling" experience
as of November 2026). Where a feature only exists in Power BI Desktop,
that's called out explicitly with the closest thing available on the web.

You need a Power BI account (a free Microsoft/Fabric trial account works)
and the 7 files in `powerbi/data/` (run `python src/export_powerbi.py`
first if that folder is empty).

## 1. Create the semantic model and upload the first table

1. Go to [app.powerbi.com](https://app.powerbi.com) and open (or create) a
   workspace.
2. Select **New item** → under **Store data**, select **Semantic model**.
3. In the connector list, select **CSV**.
4. Select **Upload file** and choose `powerbi/data/dim_date.csv`. Select **Next**.
5. Preview the data, confirm it looks right, then select **Next**.
6. Select **Create a semantic model only** (not "Create a report" — the
   model needs the other 6 tables and its relationships before a report is
   useful). Name the semantic model `Restaurant Sales` and select **Create**.

You land in the **web model editor**, in viewing mode, with one table
(`dim_date`). Switch to **Editing mode** (toggle near the top of the
screen) before continuing.

## 2. Add the remaining 6 tables

You only get the "Create a semantic model only" chooser once, on the very
first table. Everything after that goes through **Get data** on the
model editor's ribbon:

1. With the semantic model open in **Editing mode**, select **Get data** in
   the ribbon.
2. Select **CSV** again, upload the next file, preview it, and select
   **Create** (or **Load**/**Next** depending on which dialog variant you
   see — the effect is the same: it adds the file as a new table).
3. Repeat for all of:
   - `dim_menu_item.csv`
   - `dim_daypart.csv`
   - `dim_channel.csv`
   - `dim_weather.csv`
   - `fact_order_line.csv` (this one is ~539,000 rows — the upload and
     import will take noticeably longer than the small dimension tables)
   - `fact_daily_sales.csv`

You should now see all 7 tables in the **Data pane** on the right.

> **Why upload one-table-at-a-time instead of one combined file?** A real
> warehouse would hand Power BI one CSV per table too — the star schema
> (separate dims and facts) is the point, not an artifact of the export
> step. Note also that Power BI never auto-imports relationships from a
> CSV (CSVs don't carry relationship metadata) — that's always a manual
> step, on the web exactly as it is in Desktop. See step 4.

## 3. Mark `dim_date` as the date table

This is required before `SAMEPERIODLASTYEAR` (used by the `Sales LY`
measure) will work correctly.

1. In the **Data pane**, right-click `dim_date`.
2. Select **Mark as date table** → **Mark as date table**.
3. In the dialog, choose `date` as the date column (not `date_key` — that
   column is an integer, not a date).
4. Select **Save**. Power BI validates that the column has one unique value
   per row and is the right type; this will pass since `dim_date` already
   has exactly one row per calendar day.

## 4. Create the relationships

All six relationships here are **many-to-one, single direction** (filters
flow from the dimension to the fact, never the other way) — the standard
star-schema pattern, and the only direction DAX time-intelligence functions
like `SAMEPERIODLASTYEAR` and `AVERAGEX` + `DATESINPERIOD` are designed to
assume.

In the model editor's relationship diagram, drag a column from one table
onto its matching column in the other table, **or** use **Manage
relationships** in the ribbon → **New relationship**. Create these 6:

| From (many side) | To (one side) |
|---|---|
| `fact_order_line[date_key]` | `dim_date[date_key]` |
| `fact_order_line[item_key]` | `dim_menu_item[item_key]` |
| `fact_order_line[daypart_key]` | `dim_daypart[daypart_key]` |
| `fact_order_line[channel_key]` | `dim_channel[channel_key]` |
| `fact_daily_sales[date_key]` | `dim_date[date_key]` |
| `fact_daily_sales[weather_key]` | `dim_weather[weather_key]` |

For each one, confirm cardinality shows as **Many to one (\*:1)** and
cross-filter direction as **Single**, then select **Ok** (or **Save**, in
the diagram-drag flow) to save it.

> **Interview note:** `dim_date` is shared by both fact tables — that makes
> this technically a *fact constellation* (a.k.a. galaxy schema) rather
> than a single star, which is normal once a warehouse has more than one
> fact table at different grains. It's still "star-schema modeling" in the
> everyday sense people mean when they ask about it.

## 5. Add the measures

In the Data pane, select the table named in each measure's comment in
[`measures.dax`](measures.dax) (e.g. `Total Sales` goes on `fact_daily_sales`),
then select **New measure** in the ribbon. Paste in the measure's full
definition (the formula bar accepts multi-line DAX, including comments —
the DAX editor on the web has the same autocomplete/IntelliSense as
Desktop). Repeat for all 12 measures.

## 6. Build the reports

Once the model has all 7 tables, 6 relationships, and 12 measures, select
**New report** in the model editor's ribbon. This opens the browser report
editor — the same visual-authoring canvas, Visualizations pane, Fields
well, and Filters pane as Desktop, just running in the browser.

### Page 1: "Executive Overview"

**Page-level slicers** (drag onto empty canvas space, apply to both rows below):
- Slicer: `dim_date[year]`
- Slicer: `dim_date[month_name]`

**Row 1 — KPI cards** (Card visual, one measure each):
- `[Total Sales]`
- `[Total Covers]`
- `[Avg Check]`
- `[Orders]`

**Row 2:**
- **Monthly sales vs LY** — Line chart. Axis: `dim_date[date]` (use the
  auto date hierarchy, drilled to Month). Values: `[Total Sales]`,
  `[Sales LY]`.
- **YoY % by month** — Line chart. Axis: same Month level. Values:
  `[Sales YoY %]`. Format the value axis as a percentage.

**Row 3:**
- **Sales by day of week** — Clustered column chart. Axis:
  `dim_date[day_of_week]`. Values: drag `fact_daily_sales[sales]` and change
  its aggregation (click the field in the Values well → **Average**, not
  Sum) so bars show the typical day, not a total skewed by how many of each
  weekday occurred. Sort the axis by `dim_date[day_of_week_num]` (field's
  "..." menu → **Sort by column**) so bars read Sun→Sat instead of
  alphabetically. Add `[Weekend/Weekday Ratio]` as a Card nearby for
  context.
- **Avg sales by weather** — Clustered bar chart. Axis:
  `dim_weather[weather_label]`. Values: `fact_daily_sales[sales]`,
  aggregation set to **Average**.

### Page 2: "Menu & Daypart"

**Page-level slicers:**
- Slicer: `dim_menu_item[category]`
- Slicer: `dim_daypart[daypart]`
- Slicer: `dim_channel[channel]`

**Row 1:**
- **Category share of sales** — Donut chart. Legend: `dim_menu_item[category]`.
  Values: `[Category Share %]` (format as a percentage in the Values well).
- **Food cost % by category** — Clustered column chart. Axis:
  `dim_menu_item[category]`. Values: `[Food Cost %]`, formatted as a
  percentage.

**Row 2:**
- **Top 3 items per category** — Table visual. Columns:
  `dim_menu_item[category]`, `dim_menu_item[item_name]`,
  `[Item Sales Rank]`, `SUM(fact_order_line[net_sales])`. Add a visual-level
  filter: `[Item Sales Rank]` **is less than or equal to** `3`. This
  reproduces `sql/05_analysis.sql`'s `vw_top_items_per_category` view
  directly in the report, just computed with `RANKX` instead of SQL's
  `RANK()`.
- **Daypart x Channel matrix** — Matrix visual. Rows: `dim_daypart[daypart]`
  (sort by `dim_daypart[sort_order]` so it reads Lunch → Afternoon → Dinner
  → Late, not alphabetically). Columns: `dim_channel[channel]`. Values:
  `SUM(fact_order_line[net_sales])` and `[Orders]`.

## Where Desktop has something the web doesn't

Checked against Microsoft's current "Edit semantic models in the Power BI
service" documentation. For this project, the gaps that are actually worth
knowing about:

- **Performance Analyzer** (profiling how long each visual takes to
  render) is Desktop-only. There's no direct web equivalent; the closest
  you can do on the web is watch the Fabric capacity metrics app if your
  workspace has one, or just keep an eye on how snappy the report feels.
- **"View As" roles** (testing row-level security as a specific role
  before publishing) is Desktop-only. This project doesn't use RLS, so it
  doesn't come up here — but if asked in an interview, the web-only
  alternative is to actually sign in as a test user in that role rather
  than simulate it.
- **Q&A setup / synonym editing** and **feature table configuration** are
  Desktop-only. Neither is used in this report.
- Everything else used in this guide — Power Query ("Get data"),
  relationships, DAX measures, marking a date table, and the full report
  canvas (every visual type used above, slicers, filters, formatting) — has
  full parity between Desktop and the web experience used here.
