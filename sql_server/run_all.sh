#!/usr/bin/env bash
# Builds the SQL Server version of the warehouse end to end: CSV inputs,
# database, then 01-05 in order. Stops at the first error — including the
# THROW in 04_quality_checks.sql when any check fails.
#
# Needs: the restaurant-sql container running (see sql_server/README.md) and
# SQLCMDPASSWORD exported. Run from the project root:
#     bash sql_server/run_all.sh
set -euo pipefail

: "${SQLCMDPASSWORD:?export SQLCMDPASSWORD first (the sa password the container was started with)}"

python3 src/export_raw_csv.py

# -C trusts the container's self-signed certificate; -b turns any SQL error
# into a non-zero exit code so `set -e` stops the script.
sqlcmd -S localhost -U sa -C -b -Q "IF DB_ID('RestaurantDW') IS NULL CREATE DATABASE RestaurantDW"

for f in sql_server/0*.sql; do
  echo "== $f"
  # DataDir is the repo's data/ folder as the container sees it (mounted at /repo).
  sqlcmd -S localhost -U sa -C -d RestaurantDW -b -W -v DataDir=/repo/data -i "$f"
done

echo "SQL Server build finished: all 13 quality checks passed."
