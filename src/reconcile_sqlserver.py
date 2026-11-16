"""
Reconciles the SQL Server build of the warehouse against the DuckDB build:
the same questions asked of both databases, answered independently, then
compared side by side. Writes sql_server/RECONCILIATION.md.

Each comparison is a pair of queries, one per dialect, because the dialects
differ (e.g. LIMIT vs TOP, unquoted vs [bracketed] reserved words).
Money and averages are compared rounded to the cent: DuckDB stores these
as DOUBLE (floating point) and SQL Server as DECIMAL (fixed point), so they
can legitimately differ in the 6th decimal place.

Needs both builds done first (src/build_warehouse.py and
sql_server/run_all.sh) and SQLCMDPASSWORD exported. Run from the project root:
    python src/reconcile_sqlserver.py
"""

import datetime
import os
import subprocess

import duckdb

DUCKDB_PATH = "warehouse/restaurant.duckdb"
OUT_PATH = "sql_server/RECONCILIATION.md"

duck = duckdb.connect(DUCKDB_PATH, read_only=True)


def sqlserver(query):
    """Run a query with sqlcmd and return rows as lists of strings."""
    result = subprocess.run(
        ["sqlcmd", "-S", "localhost", "-U", "sa", "-C", "-d", "RestaurantDW", "-b",
         "-h", "-1", "-W", "-s", "|", "-Q", "SET NOCOUNT ON; " + query],
        capture_output=True, text=True, env=os.environ, check=True,
    )
    # sqlcmd prints informational "Warning: Null value is eliminated..." lines
    # when an aggregate skips NULLs (outage days) — not data, so drop them.
    lines = [l for l in result.stdout.splitlines() if l.strip() and not l.startswith("Warning:")]
    return [l.split("|") for l in lines]


def duckdb_rows(query):
    return [list(r) for r in duck.execute(query).fetchall()]


def norm(value, kind):
    """Bring a value from either database to a comparable form."""
    if value is None or value == "NULL":
        return None
    if kind == "int":
        return int(float(value))
    if kind == "money":
        return round(float(value) + 0.0, 2)
    if kind == "pct":
        return round(float(value), 1)
    return str(value)


def fmt(value, kind):
    if value is None:
        return "NULL"
    if kind == "int":
        return f"{value:,}"
    if kind == "money":
        return f"{value:,.2f}"
    return str(value)


results = []  # (section, label, duckdb_value, sqlserver_value, kind)


def compare_scalar(section, label, duck_q, mssql_q, kind):
    d = norm(duckdb_rows(duck_q)[0][0], kind)
    s = norm(sqlserver(mssql_q)[0][0], kind)
    results.append((section, label, d, s, kind))


# 1. Row counts per table -----------------------------------------------------
TABLES = ["stg_daily_sales", "stg_menu_items", "stg_orders", "stg_order_lines",
          "dim_date", "dim_menu_item", "dim_daypart", "dim_channel", "dim_weather",
          "fact_daily_sales", "fact_order_line"]
for t in TABLES:
    compare_scalar("Row counts", t, f"SELECT COUNT(*) FROM {t}", f"SELECT COUNT(*) FROM {t}", "int")

# 2. Totals --------------------------------------------------------------------
TOTALS = [
    ("Total sales (fact_daily_sales)", "SELECT SUM(sales) FROM fact_daily_sales", "money"),
    ("Total net sales (fact_order_line)", "SELECT SUM(net_sales) FROM fact_order_line", "money"),
    ("Total food cost (fact_order_line)", "SELECT SUM(food_cost) FROM fact_order_line", "money"),
    ("Total covers", "SELECT SUM(covers) FROM fact_daily_sales", "int"),
    ("Distinct orders", "SELECT COUNT(DISTINCT order_id) FROM fact_order_line", "int"),
    ("Total quantity sold", "SELECT SUM(quantity) FROM fact_order_line", "int"),
]
for label, q, kind in TOTALS:
    compare_scalar("Totals", label, q, q, kind)

# 3. Sales by month ------------------------------------------------------------
duck_month = duckdb_rows("""
    SELECT dd.year, dd.month, SUM(fds.sales)
    FROM fact_daily_sales fds JOIN dim_date dd ON fds.date_key = dd.date_key
    GROUP BY dd.year, dd.month ORDER BY dd.year, dd.month
""")
mssql_month = sqlserver("""
    SELECT dd.[year], dd.[month], SUM(fds.sales)
    FROM fact_daily_sales fds JOIN dim_date dd ON fds.date_key = dd.date_key
    GROUP BY dd.[year], dd.[month] ORDER BY dd.[year], dd.[month]
""")
mssql_month_by_key = {(int(y), int(m)): v for y, m, v in mssql_month}
for y, m, v in duck_month:
    results.append(("Sales by month", f"{y}-{m:02d}", norm(v, "money"),
                    norm(mssql_month_by_key.get((y, m)), "money"), "money"))
results.append(("Sales by month", "number of months", len(duck_month), len(mssql_month), "int"))

# 4. Top 5 items by sales (LIMIT in DuckDB, TOP in T-SQL) ----------------------
duck_top = duckdb_rows("""
    SELECT dm.item_name, SUM(fol.net_sales) AS s
    FROM fact_order_line fol JOIN dim_menu_item dm ON fol.item_key = dm.item_key
    GROUP BY dm.item_name ORDER BY s DESC LIMIT 5
""")
mssql_top = sqlserver("""
    SELECT TOP 5 dm.item_name, SUM(fol.net_sales) AS s
    FROM fact_order_line fol JOIN dim_menu_item dm ON fol.item_key = dm.item_key
    GROUP BY dm.item_name ORDER BY s DESC
""")
for rank, ((d_name, d_sales), (s_name, s_sales)) in enumerate(zip(duck_top, mssql_top), start=1):
    results.append(("Top 5 items by sales", f"#{rank} item", d_name, s_name, "text"))
    results.append(("Top 5 items by sales", f"#{rank} sales", norm(d_sales, "money"), norm(s_sales, "money"), "money"))

# 5. Row count of each analysis view --------------------------------------------
VIEWS = ["vw_monthly_sales_yoy", "vw_rolling_sales", "vw_top_items_per_category",
         "vw_category_share", "vw_weekday_weekend", "vw_daypart_channel_mix", "vw_weather_impact"]
for v in VIEWS:
    compare_scalar("View row counts", v, f"SELECT COUNT(*) FROM {v}", f"SELECT COUNT(*) FROM {v}", "int")

# 6. Key values inside the views (spot checks) ----------------------------------
SPOT = [
    ("vw_weekday_weekend: weekend/weekday ratio", "SELECT weekend_weekday_ratio FROM vw_weekday_weekend", "money"),
    ("vw_weekday_weekend: avg weekday sales", "SELECT avg_weekday_sales FROM vw_weekday_weekend", "money"),
    ("vw_weather_impact: Snow % vs clear", "SELECT pct_vs_clear FROM vw_weather_impact WHERE weather_label = 'Snow'", "pct"),
    ("vw_weather_impact: Heavy Rain % vs clear", "SELECT pct_vs_clear FROM vw_weather_impact WHERE weather_label = 'Heavy Rain'", "pct"),
    ("vw_monthly_sales_yoy: months with a YoY value", "SELECT COUNT(yoy_pct_change) FROM vw_monthly_sales_yoy", "int"),
    ("vw_monthly_sales_yoy: sum of YoY % values", "SELECT SUM(yoy_pct_change) FROM vw_monthly_sales_yoy", "pct"),
    ("vw_rolling_sales: sum of 7-day averages", "SELECT SUM(rolling_7d_avg) FROM vw_rolling_sales", "money"),
    ("vw_rolling_sales: sum of 28-day averages", "SELECT SUM(rolling_28d_avg) FROM vw_rolling_sales", "money"),
    ("vw_category_share: Mains food cost %", "SELECT food_cost_pct FROM vw_category_share WHERE category = 'Mains'", "pct"),
    ("vw_top_items_per_category: #1 in Mains", "SELECT item_name FROM vw_top_items_per_category WHERE category = 'Mains' AND sales_rank = 1", "text"),
    ("vw_daypart_channel_mix: total orders", "SELECT SUM(orders) FROM vw_daypart_channel_mix", "int"),
]
for label, q, kind in SPOT:
    compare_scalar("Key view values", label, q, q, kind)

# --- write the report ---------------------------------------------------------
def matches(d, s, kind):
    return d == s


version = sqlserver("SELECT @@VERSION")[0][0].split(" - ")[0] + " " + sqlserver(
    "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)) + ' ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))")[0][0]
n_match = sum(matches(d, s, k) for _, _, d, s, k in results)

out = [
    "# SQL Server vs. DuckDB reconciliation",
    "",
    "Generated by `src/reconcile_sqlserver.py`, which asks both databases the",
    "same questions independently and compares the answers.",
    "",
    f"- **Run on:** {datetime.date.today().isoformat()}",
    f"- **SQL Server:** {version}, in Docker (linux/amd64 image under Rosetta on Apple Silicon)",
    f"- **DuckDB:** {duckdb.__version__}",
    f"- **Result:** {n_match} of {len(results)} comparisons match"
    + (" — all match." if n_match == len(results) else " — see the MISMATCH rows."),
    "",
    "Money and averages are compared rounded to the cent (DuckDB uses floating",
    "point, SQL Server fixed-point `DECIMAL`, so raw values can differ in the",
    "6th decimal place). Percentages are compared to one decimal, as the views",
    "round them. Counts and text are compared exactly.",
    "",
]
section = None
for sec, label, d, s, kind in results:
    if sec != section:
        section = sec
        out += ["", f"## {sec}", "", "| Check | DuckDB | SQL Server | Result |", "|---|---|---|---|"]
    out.append(f"| {label} | {fmt(d, kind)} | {fmt(s, kind)} | {'match' if matches(d, s, kind) else '**MISMATCH**'} |")
out.append("")

with open(OUT_PATH, "w") as f:
    f.write("\n".join(out))
print(f"{n_match} of {len(results)} comparisons match. Wrote {OUT_PATH}")
