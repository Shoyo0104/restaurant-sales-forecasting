"""
Writes CSV copies of data/orders.parquet and data/order_lines.parquet for the
SQL Server pipeline in sql_server/. SQL Server's BULK INSERT reads CSV but not
parquet, while the DuckDB pipeline reads the parquet files directly — this is
the only extra step the T-SQL version needs.

Run from the project root: `python src/export_raw_csv.py`
"""

import pandas as pd

for name in ["orders", "order_lines"]:
    df = pd.read_parquet(f"data/{name}.parquet")
    if "timestamp" in df.columns:
        # pandas would write nanoseconds (9 decimal places). SQL Server
        # rounds those to DATETIME2's 7 digits without complaint, but the
        # sub-second part is simulation noise: writing to the second keeps
        # the CSV smaller and loads into DATETIME2(0) exactly as written.
        df["timestamp"] = df["timestamp"].dt.strftime("%Y-%m-%d %H:%M:%S")
    df.to_csv(f"data/{name}.csv", index=False)
    print(f"Wrote {len(df):,} rows to data/{name}.csv")
