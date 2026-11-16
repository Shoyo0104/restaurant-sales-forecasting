# SQL Server (T-SQL) version of the warehouse

The same pipeline as `sql/01`–`05` (same tables, columns, 13 quality checks,
and 7 analysis views), written for Microsoft SQL Server. The DuckDB version
is the one `src/build_warehouse.py` runs; this one exists to show the same
model in the dialect a SQL Server shop uses day to day.

> **Status:** these scripts are syntax-checked with a T-SQL parser
> (`sqlglot`, dialect `tsql`) but have **not yet been executed against a real
> SQL Server instance**. Run them with the steps below and compare against
> the expected results at the bottom.

## Running it on a Mac

SQL Server doesn't run natively on macOS, so it runs in Docker.

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/).
   On an Apple Silicon Mac, turn on **Settings → General → "Use Rosetta for
   x86_64/amd64 emulation"** (the SQL Server image is Intel-only).
2. Install Microsoft's `sqlcmd` command-line tool:

```bash
brew install sqlcmd
```

3. Pick a password for the local `sa` admin account (8+ characters, mixing
   upper/lowercase, digits, and symbols — SQL Server rejects weak ones).
   `sqlcmd` reads it from this environment variable, so it never has to be
   typed on a command line:

```bash
export SQLCMDPASSWORD='<choose-a-strong-password>'
```

4. From the project root, start SQL Server with the repo mounted at `/repo`
   inside the container (that's how `BULK INSERT` gets at the CSVs):

```bash
docker run -d --name restaurant-sql --platform linux/amd64 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$SQLCMDPASSWORD" -p 1433:1433 -v "$PWD":/repo mcr.microsoft.com/mssql/server:2022-latest
```

5. Write CSV copies of the order files (SQL Server can't read parquet):

```bash
python src/export_raw_csv.py
```

6. Create the database (wait ~20 seconds after step 4 for SQL Server to start):

```bash
sqlcmd -S localhost -U sa -C -Q "CREATE DATABASE RestaurantDW"
```

7. Run the five scripts in order. `-v DataDir=/repo/data` fills in the
   `$(DataDir)` variable used by `01_staging.sql`, and `-b` makes `sqlcmd`
   stop with an error code if a script fails (including the quality-check
   `THROW` in `04`):

```bash
for f in sql/tsql/0*.sql; do sqlcmd -S localhost -U sa -C -d RestaurantDW -b -v DataDir=/repo/data -i "$f" || break; done
```

`04_quality_checks.sql` prints a PASS/FAIL table. To look at a view:

```bash
sqlcmd -S localhost -U sa -C -d RestaurantDW -Q "SELECT * FROM vw_weekday_weekend"
```

## DuckDB vs. T-SQL: what had to change

| Topic | DuckDB (`sql/`) | SQL Server (`sql/tsql/`) | Why |
|---|---|---|---|
| Loading files | `read_csv_auto()`, `read_parquet()` in a SELECT | `BULK INSERT` into an all-text `raw_` table, then cast into `stg_` | SQL Server can't read local parquet, and loading text first means one bad value becomes a NULL instead of failing the whole load |
| Build a table from a query | `CREATE OR REPLACE TABLE ... AS SELECT` | `DROP TABLE IF EXISTS` + `SELECT ... INTO` (staging) or `CREATE TABLE` + `INSERT` (dims/facts) | No `CREATE OR REPLACE TABLE` in T-SQL; dims/facts get explicit DDL so keys and types are deliberate |
| Keys | None declared; uniqueness/orphans only caught by checks | `PRIMARY KEY` and `FOREIGN KEY` constraints | The engine enforces grain and referential integrity on insert |
| Re-run order | Any order | Drop facts before dims | A table referenced by a foreign key can't be dropped |
| Booleans | `BOOLEAN`, `NOT is_closed` | `BIT`, `is_closed = 0` | T-SQL has no boolean column type |
| `YYYYMMDD` key | `strftime(date, '%Y%m%d')` | `CONVERT(CHAR(8), date, 112)` | `FORMAT()` exists but runs through .NET and is slow at scale |
| Day of week | `dayofweek()` (0 = Sunday) | `(DATEPART(WEEKDAY, d) + @@DATEFIRST - 1) % 7` | `DATEPART(WEEKDAY)` changes with the server's `SET DATEFIRST` setting |
| Month length | `last_day(make_date(y, m, 1))` | `EOMONTH(DATEFROMPARTS(y, m, 1))` | Function names |
| Conditional count | `COUNT(x) FILTER (WHERE ...)` | `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` | No `FILTER` clause in T-SQL |
| Rolling 7 *calendar* days | `RANGE BETWEEN INTERVAL 6 DAYS PRECEDING` | Date spine (one row per day) + `ROWS BETWEEN 6 PRECEDING`, excluded days as NULL | T-SQL window frames don't support date intervals |
| Views | `CREATE OR REPLACE VIEW`, `ORDER BY` allowed | `CREATE OR ALTER VIEW`, one per batch (`GO`), no `ORDER BY` | T-SQL rules for views |
| Reserved words | `timestamp` usable as a name | `[timestamp]` in brackets | `TIMESTAMP` is reserved in T-SQL |
| Failing the build | `build_warehouse.py` checks each query for rows | Checks logged to a `#temp` table, then `THROW` → `sqlcmd -b` exits non-zero | Keeps the T-SQL pipeline self-contained |

## Expected results

These are the DuckDB outputs. The SQL Server run should match them:

- Row counts: `dim_date` 940, `dim_menu_item` 40, `fact_daily_sales` 940,
  `fact_order_line` 538,991 (91,990 distinct `order_id`s)
- All 13 checks in `04_quality_checks.sql`: PASS
- `vw_weekday_weekend`: $5,501.37 weekday, $11,240.11 weekend, ratio 2.04
- `vw_weather_impact`: Rain −2.5%, Heavy Rain −11.0%, Snow −31.4% vs. Clear
- `vw_top_items_per_category`: Ribeye Steak is #1 in Mains at $410,556.81
- `vw_monthly_sales_yoy`: no YoY for Dec 2023, Dec 2024 (its LY is partial),
  or Jul 2026; full months range from −6.9% (Mar 2026) to +8.3% (Jan 2026)

Small differences in the last decimal place of averages are expected
(`DECIMAL` arithmetic in SQL Server vs. `DOUBLE` in DuckDB); anything bigger
is a real difference worth investigating.
