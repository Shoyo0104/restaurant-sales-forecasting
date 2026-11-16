"""
Exports every dim_ and fact_ table in warehouse/restaurant.duckdb to a CSV
in powerbi/data/ — the files BUILD_GUIDE.md walks through uploading to the
Power BI service as a new semantic model.

Run from the project root, after src/build_warehouse.py:
    python src/build_warehouse.py
    python src/export_powerbi.py
"""

from pathlib import Path

import duckdb

DB_PATH = "warehouse/restaurant.duckdb"
OUT_DIR = Path("powerbi/data")


def main() -> None:
    con = duckdb.connect(DB_PATH, read_only=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # information_schema is queried rather than hand-listing table names, so
    # this script doesn't need editing every time a dim/fact table is added.
    tables = con.execute("""
        SELECT table_name FROM information_schema.tables
        WHERE table_name LIKE 'dim_%' OR table_name LIKE 'fact_%'
        ORDER BY table_name
    """).fetchall()

    for (table_name,) in tables:
        out_path = OUT_DIR / f"{table_name}.csv"
        con.execute(f"COPY {table_name} TO '{out_path}' (HEADER, DELIMITER ',')")
        rows = con.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()[0]
        print(f"Wrote {rows:,} rows to {out_path}")

    con.close()


if __name__ == "__main__":
    main()
