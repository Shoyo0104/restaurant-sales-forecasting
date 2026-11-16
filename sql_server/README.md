# SQL Server (T-SQL) version of the warehouse

The same pipeline as `sql/01`–`05` (same tables, columns, 13 quality checks,
and 7 analysis views), written for Microsoft SQL Server, with primary and
foreign key constraints the DuckDB version doesn't have.

**Verified on SQL Server:** built end to end on Microsoft SQL Server 2022
(RTM-CU28, Developer Edition) in Docker on an Apple Silicon Mac. All 13
quality checks pass, and all 78 comparisons against the DuckDB build match
— see [`RECONCILIATION.md`](RECONCILIATION.md). An empty database to a full
warehouse takes about 6 seconds.

## Running it on a Mac

SQL Server doesn't run natively on macOS, so it runs in Docker.

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   and open it once. On Apple Silicon, check **Settings → General → "Use
   Rosetta for x86_64/amd64 emulation"** is on: the SQL Server image is
   Intel-only and runs under Rosetta.
2. Install Microsoft's `sqlcmd` command-line tool:

```bash
brew install sqlcmd
```

3. Pick a password for the local `sa` admin account (8+ characters, mixing
   upper/lowercase, digits, and symbols — SQL Server rejects weak ones).
   `sqlcmd` reads it from this environment variable:

```bash
export SQLCMDPASSWORD='<choose-a-strong-password>'
```

4. From the project root, start SQL Server with the repo mounted at `/repo`
   inside the container (that's how `BULK INSERT` reads the CSVs).
   `ACCEPT_EULA=Y` accepts Microsoft's SQL Server Developer Edition license:

```bash
docker run -d --name restaurant-sql --platform linux/amd64 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$SQLCMDPASSWORD" -p 1433:1433 -v "$PWD":/repo mcr.microsoft.com/mssql/server:2022-latest
```

5. Wait ~15 seconds for SQL Server to start, then build everything with one
   command. It writes the CSV inputs, creates the `RestaurantDW` database,
   and runs `01`–`05` in order, stopping at the first error (including the
   `THROW` in `04` if any quality check fails):

```bash
bash sql_server/run_all.sh
```

6. Compare against the DuckDB build (needs `python src/build_warehouse.py`
   run first). This rewrites `RECONCILIATION.md`:

```bash
python src/reconcile_sqlserver.py
```

To look at a view:

```bash
sqlcmd -S localhost -U sa -C -d RestaurantDW -Q "SELECT * FROM vw_weekday_weekend"
```

When you're done, `docker stop restaurant-sql` stops SQL Server, and
`docker start restaurant-sql` brings it back with the data intact.

## Run log

What happened when the scripts first ran on a real SQL Server, including
fixes made beforehand from documentation and whether they turned out to be
needed:

| # | When | What | Outcome |
|---|---|---|---|
| 1 | Before first run | Removed `CODEPAGE = '65001'` from every `BULK INSERT` | **Needed.** Re-tested on SQL Server 2022 for Linux: `Msg 16202 ... 'CODEPAGE' is not supported on the 'Linux' platform`. The CSVs are plain ASCII, so no code page is required. |
| 2 | Before first run | `src/export_raw_csv.py` writes order timestamps to the second instead of pandas' 9 decimal places | **Not needed.** Re-tested: SQL Server 2022 rounds 9-digit fractions to `DATETIME2`'s 7 without error. Kept, because the sub-second part is noise; the code comment now says so. |
| 3 | First run | `01`–`05` all succeeded on the first attempt; all 13 checks passed | No fix needed. Staging NULL counts (7/10/7/13) and totals matched the source CSV exactly. |
| 4 | After first run | Named every constraint (`pk_dim_date`, `fk_fact_order_line_item`, …) | Improvement. SQL Server had auto-named them (e.g. `FK__fact_orde__item___49C3F6B7`), which made the FK violation message unreadable. |
| 5 | After first run | Added `run_all.sh` and rebuilt from a dropped database | One-command rebuild works; ~6 seconds end to end. |
| 6 | Failure-path test | Inserted a negative-amount order line, ran `04` | 2 checks FAILED (negative amount; that day no longer reconciled), `THROW` fired, `sqlcmd -b` exited with code 1. Row removed afterwards. |
| 7 | Failure-path test | Inserted an order line with a non-existent `item_key` | Rejected by the foreign key (`Msg 547`) before reaching the checks. |

## DuckDB vs. T-SQL: what had to change

| Topic | DuckDB (`sql/`) | SQL Server (`sql_server/`) | Why |
|---|---|---|---|
| Loading files | `read_csv_auto()`, `read_parquet()` in a SELECT | `BULK INSERT` into an all-text `raw_` table, then cast into `stg_` | SQL Server can't read local parquet, and loading text first means one bad value becomes a NULL instead of failing the whole load |
| Build a table from a query | `CREATE OR REPLACE TABLE ... AS SELECT` | `DROP TABLE IF EXISTS` + `SELECT ... INTO` (staging) or `CREATE TABLE` + `INSERT` (dims/facts) | No `CREATE OR REPLACE TABLE` in T-SQL; dims/facts get explicit DDL so keys and types are deliberate |
| Keys | None declared; uniqueness/orphans only caught by checks | Named `PRIMARY KEY` and `FOREIGN KEY` constraints | The engine enforces grain and referential integrity on insert |
| Re-run order | Any order | Drop facts before dims | A table referenced by a foreign key can't be dropped |
| Booleans | `BOOLEAN`, `NOT is_closed` | `BIT`, `is_closed = 0` | T-SQL has no boolean column type |
| `YYYYMMDD` key | `strftime(date, '%Y%m%d')` | `CONVERT(CHAR(8), date, 112)` | `FORMAT()` exists but runs through .NET and is slow at scale |
| Day of week | `dayofweek()` (0 = Sunday) | `(DATEPART(WEEKDAY, d) + @@DATEFIRST - 1) % 7` | `DATEPART(WEEKDAY)` changes with the server's `SET DATEFIRST` setting |
| Month length | `last_day(make_date(y, m, 1))` | `EOMONTH(DATEFROMPARTS(y, m, 1))` | Function names |
| Conditional count | `COUNT(x) FILTER (WHERE ...)` | `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` | No `FILTER` clause in T-SQL |
| Rolling 7 *calendar* days | `RANGE BETWEEN INTERVAL 6 DAYS PRECEDING` | Date spine (one row per day) + `ROWS BETWEEN 6 PRECEDING`, excluded days as NULL | T-SQL window frames don't support date intervals |
| Views | `CREATE OR REPLACE VIEW`, `ORDER BY` allowed | `CREATE OR ALTER VIEW`, one per batch (`GO`), no `ORDER BY` | T-SQL rules for views |
| Top N rows | `ORDER BY ... LIMIT 5` | `SELECT TOP 5 ... ORDER BY` | Used in the reconciliation's top-5-items query |
| String concatenation | `||` | `+` | Used in the reconciliation's server-version query |
| Reserved words | `timestamp`, `year`, `month` usable bare | `[timestamp]`, `[year]`, `[month]` in brackets | `TIMESTAMP` is reserved; brackets on the others avoid ambiguity with the type/function names |
| Failing the build | `build_warehouse.py` checks each query for rows | Checks logged to a `#temp` table, then `THROW` → `sqlcmd -b` exits non-zero | Keeps the T-SQL pipeline self-contained |
| Number precision | `DOUBLE` for sales from the CSV | `DECIMAL(12,2)` | Averages differ in the 6th decimal (e.g. 6546.313021 vs 6546.313020), so the reconciliation compares to the cent |
