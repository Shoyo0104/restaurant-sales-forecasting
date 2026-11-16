"""
Writes CSV copies of data/orders.parquet and data/order_lines.parquet for the
SQL Server pipeline in sql/tsql/. SQL Server's BULK INSERT reads CSV but not
parquet, while the DuckDB pipeline reads the parquet files directly — this is
the only extra step the T-SQL version needs.

Run from the project root: `python src/export_raw_csv.py`
"""

import pandas as pd

for name in ["orders", "order_lines"]:
    df = pd.read_parquet(f"data/{name}.parquet")
    if "timestamp" in df.columns:
        # pandas would write nanoseconds (9 decimal places); SQL Server's
        # DATETIME2 accepts at most 7, so the cast in 01_staging.sql would
        # fail. A POS timestamp to the second is plenty.
        df["timestamp"] = df["timestamp"].dt.strftime("%Y-%m-%d %H:%M:%S")
    df.to_csv(f"data/{name}.csv", index=False)
    print(f"Wrote {len(df):,} rows to data/{name}.csv")
