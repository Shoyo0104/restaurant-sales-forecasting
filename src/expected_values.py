"""
Computes, in DuckDB, the numbers each visual on the Power BI "Executive
Overview" page (powerbi/PAGE1_GUIDE.md) should show, and writes them to
powerbi/EXPECTED_VALUES.md so the DAX can be checked against an independent
calculation.

Each query mirrors how the DAX measures in powerbi/measures.dax evaluate:
  - [Total Sales] sums fact_order_line, so the Daypart slicer filters it.
  - [Sales LY] (SAMEPERIODLASTYEAR) keeps every non-date filter (e.g.
    Daypart) and replaces the dates in context with the same dates one year
    earlier. Every context on this page is a contiguous date range (all
    dates, one year, or one month), so the LY range is [start - 1 year,
    end - 1 year] — extended to the month's last day when the context ends
    on a month end, which is how DAX shifts whole months (Feb 2025 -> all
    29 days of Feb 2024).
  - [Avg Daily Sales] averages [Total Sales] per date and skips blanks, i.e.
    days with no matching order lines (closed / POS-outage days).

Run from the project root, after src/build_warehouse.py:
    python src/expected_values.py
"""

import duckdb

DB_PATH = "warehouse/restaurant.duckdb"
OUT_PATH = "powerbi/EXPECTED_VALUES.md"

# The example slicer selection shown alongside the unfiltered numbers.
EXAMPLE_YEAR = 2025
EXAMPLE_DAYPART = "Dinner"

con = duckdb.connect(DB_PATH, read_only=True)

# One row per order line with the attributes the page slices by.
con.execute("""
    CREATE TEMP VIEW lines AS
    SELECT dd.date, dd.year, dd.year_month, dd.day_of_week, dd.day_of_week_num,
           ddp.daypart, dm.category, fol.order_id, fol.net_sales
    FROM fact_order_line fol
    JOIN dim_date dd      ON fol.date_key = dd.date_key
    JOIN dim_daypart ddp  ON fol.daypart_key = ddp.daypart_key
    JOIN dim_menu_item dm ON fol.item_key = dm.item_key
""")


def daypart_filter(daypart):
    return "TRUE" if daypart is None else f"daypart = '{daypart}'"


def sales_between(start, end, daypart):
    """[Total Sales] over a date range, with the Daypart filter applied."""
    return con.execute(
        f"SELECT COALESCE(SUM(net_sales), 0) FROM lines "
        f"WHERE date BETWEEN ? AND ? AND {daypart_filter(daypart)}",
        [start, end],
    ).fetchone()[0]


def ly_range(start, end):
    """Date range SAMEPERIODLASTYEAR returns for a contiguous [start, end]."""
    return con.execute("""
        SELECT CAST(?::DATE - INTERVAL 1 YEAR AS DATE),
               CASE WHEN ?::DATE = last_day(?::DATE)
                    THEN last_day(CAST(?::DATE - INTERVAL 1 YEAR AS DATE))
                    ELSE CAST(?::DATE - INTERVAL 1 YEAR AS DATE) END
    """, [start, end, end, end, end]).fetchone()


def context_dates(year):
    """First and last date in the filter context (whole table, or one year)."""
    where = "TRUE" if year is None else f"year = {year}"
    return con.execute(f"SELECT MIN(date), MAX(date) FROM dim_date WHERE {where}").fetchone()


def money(x):
    return "(blank)" if x is None else f"${x:,.2f}"


def pct(x):
    return "(blank)" if x is None else f"{x:+.2%}"


def kpis(year, daypart):
    start, end = context_dates(year)
    sales = sales_between(start, end, daypart)
    orders = con.execute(
        f"SELECT COUNT(DISTINCT order_id) FROM lines "
        f"WHERE date BETWEEN ? AND ? AND {daypart_filter(daypart)}",
        [start, end],
    ).fetchone()[0]
    ly_start, ly_end = ly_range(start, end)
    ly = sales_between(ly_start, ly_end, daypart)
    return {
        "context": f"{start} to {end}",
        "ly_context": f"{ly_start} to {ly_end}",
        "sales": sales,
        "orders": orders,
        "aov": sales / orders,
        "ly": ly,
        "yoy": (sales - ly) / ly if ly else None,
    }


def monthly(year, daypart):
    where = "TRUE" if year is None else f"year = {year}"
    months = con.execute(
        f"SELECT year_month, MIN(date), MAX(date) FROM dim_date WHERE {where} "
        f"GROUP BY year_month ORDER BY year_month"
    ).fetchall()
    rows = []
    for ym, start, end in months:
        sales = sales_between(start, end, daypart)
        ly_start, ly_end = ly_range(start, end)
        ly = sales_between(ly_start, ly_end, daypart)
        rows.append((ym, sales or None, ly or None))  # 0 means "no rows" -> blank in Power BI
    return rows


def by_weekday(year, daypart):
    year_filter = "TRUE" if year is None else f"year = {year}"
    return con.execute(f"""
        WITH daily AS (
            SELECT date, day_of_week, day_of_week_num, SUM(net_sales) AS sales
            FROM lines
            WHERE {year_filter} AND {daypart_filter(daypart)}
            GROUP BY date, day_of_week, day_of_week_num
        )
        SELECT day_of_week, AVG(sales), COUNT(*)
        FROM daily
        GROUP BY day_of_week, day_of_week_num
        ORDER BY day_of_week_num
    """).fetchall()


def by_category(year, daypart):
    year_filter = "TRUE" if year is None else f"year = {year}"
    return con.execute(f"""
        SELECT category, SUM(net_sales) AS sales
        FROM lines
        WHERE {year_filter} AND {daypart_filter(daypart)}
        GROUP BY category
        ORDER BY sales DESC
    """).fetchall()


def section(title, year, daypart):
    k = kpis(year, daypart)
    out = [f"## {title}", ""]
    out += [
        f"Date context: {k['context']}. `[Sales LY]` compares against {k['ly_context']}.",
        "",
        "### KPI cards",
        "",
        "| Card | Expected value |",
        "|---|---|",
        f"| Total Sales | {money(k['sales'])} |",
        f"| Orders | {k['orders']:,} |",
        f"| Avg Order Value | {money(k['aov'])} |",
        f"| Sales YoY % | {pct(k['yoy'])} (LY = {money(k['ly'])}) |",
        "",
        "### Line chart: monthly Sales vs Sales LY",
        "",
        "| year_month | Total Sales | Sales LY |",
        "|---|---|---|",
    ]
    out += [f"| {ym} | {money(s)} | {money(ly)} |" for ym, s, ly in monthly(year, daypart)]
    out += [
        "",
        "### Bar chart: Avg Daily Sales by day of week",
        "",
        "| Day | Avg Daily Sales | Days averaged |",
        "|---|---|---|",
    ]
    out += [f"| {d} | {money(a)} | {n} |" for d, a, n in by_weekday(year, daypart)]
    out += [
        "",
        "### Bar chart: Total Sales by menu category",
        "",
        "| Category | Total Sales |",
        "|---|---|",
    ]
    out += [f"| {c} | {money(s)} |" for c, s in by_category(year, daypart)]
    out.append("")
    return out


lines_md = [
    "# Expected values: Executive Overview page",
    "",
    "Generated by `src/expected_values.py` from the DuckDB warehouse — an",
    "independent calculation to check the Power BI page against. Power BI",
    "cards round for display (e.g. `$6.65M`); hover over a value, or turn",
    "off display units in the Format pane, to compare to the cent.",
    "",
    "Things that are expected, not bugs:",
    "",
    "- **Unfiltered Sales YoY %** compares all 2.6 years of data against the",
    "  dates one year earlier, which only cover about 1.6 years — so the",
    "  unfiltered card is large and not meaningful. Select a year first; the",
    "  card is built to be read with the Year slicer set.",
    "- **Sales LY is blank for Dec 2023 – Nov 2024 on the line chart**: the",
    "  data starts on 23 Dec 2023, so those months have no prior year.",
    "  **Dec 2024's LY** covers only 23–31 Dec 2023.",
    "- **Jul 2026 is a partial month** (1–19 Jul); its LY is 1–19 Jul 2025.",
    "",
]
lines_md += section("Unfiltered (no slicer selected)", None, None)
lines_md += section(f"Example: Year = {EXAMPLE_YEAR}, Daypart = {EXAMPLE_DAYPART}", EXAMPLE_YEAR, EXAMPLE_DAYPART)

with open(OUT_PATH, "w") as f:
    f.write("\n".join(lines_md))
print(f"Wrote {OUT_PATH}")
