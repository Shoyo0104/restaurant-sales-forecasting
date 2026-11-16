"""
Builds warehouse/restaurant.duckdb by running sql/01_staging.sql through
sql/05_analysis.sql in order, then fails loudly if any check in
sql/04_quality_checks.sql returns rows (a non-empty result IS the failure —
see the comment above each query in that file for what it's checking).

Run from the project root: `python src/build_warehouse.py`
"""

import re
import sys
from pathlib import Path

import duckdb

DB_PATH = "warehouse/restaurant.duckdb"
SQL_DIR = Path("sql")

TABLES_TO_REPORT = [
    "stg_daily_sales", "stg_menu_items", "stg_orders", "stg_order_lines",
    "dim_date", "dim_menu_item", "dim_daypart", "dim_channel", "dim_weather",
    "fact_order_line", "fact_daily_sales",
]


def _has_sql(statement: str) -> bool:
    """True if `statement` has any non-comment, non-blank content."""
    code_lines = [line for line in statement.splitlines() if not line.strip().startswith("--")]
    return bool("".join(code_lines).strip())


def run_statements(con: duckdb.DuckDBPyConnection, sql_text: str) -> None:
    """DuckDB's execute() runs one statement at a time, so split the file on
    ';' and run each CREATE/SELECT in order."""
    for statement in sql_text.split(";"):
        statement = statement.strip()
        if _has_sql(statement):
            con.execute(statement)


def run_quality_checks(con: duckdb.DuckDBPyConnection, sql_text: str) -> bool:
    """Each check is a '-- CHECK: <label>' comment followed by a query that
    must return zero rows. Returns True only if every check passed."""
    # Splitting on the capturing group alternates [label, query, label, query, ...]
    blocks = re.split(r"--\s*CHECK:\s*(.+)", sql_text)[1:]
    all_passed = True
    print("\n--- Quality checks ---")
    for label, query in zip(blocks[0::2], blocks[1::2]):
        query = query.strip().rstrip(";")
        if not query:
            continue
        bad_rows = con.execute(query).fetchall()
        passed = len(bad_rows) == 0
        all_passed &= passed
        status = "PASS" if passed else f"FAIL ({len(bad_rows)} row(s))"
        print(f"[{status}] {label.strip()}")
    return all_passed


def main() -> None:
    Path("warehouse").mkdir(exist_ok=True)
    con = duckdb.connect(DB_PATH)

    print("--- Building staging, dimension, and fact tables ---")
    for step in ["01_staging.sql", "02_dimensions.sql", "03_facts.sql"]:
        run_statements(con, (SQL_DIR / step).read_text())
        print(f"ran {step}")

    checks_passed = run_quality_checks(con, (SQL_DIR / "04_quality_checks.sql").read_text())

    print("\n--- Building analysis views ---")
    run_statements(con, (SQL_DIR / "05_analysis.sql").read_text())
    print("ran 05_analysis.sql")

    print("\n--- Row counts ---")
    for table in TABLES_TO_REPORT:
        count = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"{table:<20} {count:>10,}")

    con.close()

    if not checks_passed:
        print("\nOne or more quality checks FAILED — see above. Aborting.")
        sys.exit(1)

    print(f"\nAll quality checks passed. {DB_PATH} is ready.")


if __name__ == "__main__":
    main()
