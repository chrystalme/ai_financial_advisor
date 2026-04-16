#!/usr/bin/env python3
"""
Comprehensive database verification for GCP Cloud SQL.
Connects via Cloud SQL Auth Proxy on localhost:5432.
Start the proxy first:  cloud-sql-proxy $CLOUDSQL_CONNECTION_NAME --port 5432
"""

import os
import json
import psycopg
from dotenv import load_dotenv

load_dotenv(override=True)

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "alex")
DB_USER = os.environ.get("DB_USER", "alex_app")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

if not DB_PASSWORD:
    print("Missing DB_PASSWORD in environment / .env file")
    exit(1)

conninfo = f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} user={DB_USER} password={DB_PASSWORD}"


def execute_query(cur, sql, description):
    print(f"\n{description}")
    print("-" * 50)
    try:
        cur.execute(sql)
        return cur.fetchall()
    except Exception as e:
        print(f"Error: {e}")
        return None


def main():
    print("DATABASE VERIFICATION REPORT")
    print("=" * 70)
    print(f"Database: {DB_NAME} @ {DB_HOST}:{DB_PORT}")
    print("=" * 70)

    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:

            # 1. All tables
            rows = execute_query(cur, """
                SELECT table_name,
                       pg_size_pretty(pg_total_relation_size(quote_ident(table_name)::regclass)) as size
                FROM information_schema.tables
                WHERE table_schema = 'public'
                AND table_type = 'BASE TABLE'
                ORDER BY table_name
            """, "ALL TABLES IN DATABASE")

            if rows:
                print(f"Found {len(rows)} tables:\n")
                for table_name, size in rows:
                    print(f"   {table_name:<20} Size: {size}")

            # 2. Record counts
            rows = execute_query(cur, """
                SELECT 'users' as table_name, COUNT(*) FROM users
                UNION ALL SELECT 'instruments', COUNT(*) FROM instruments
                UNION ALL SELECT 'accounts', COUNT(*) FROM accounts
                UNION ALL SELECT 'positions', COUNT(*) FROM positions
                UNION ALL SELECT 'jobs', COUNT(*) FROM jobs
                ORDER BY table_name
            """, "RECORD COUNTS PER TABLE")

            if rows:
                print("\nTable record counts:\n")
                for table_name, count in rows:
                    status = "OK" if (table_name == "instruments" and count > 0) else "--"
                    print(f"   [{status}] {table_name:<20} {count:,} records")

            # 3. Sample instruments
            rows = execute_query(cur, """
                SELECT symbol, name, instrument_type,
                       allocation_asset_class::text
                FROM instruments
                ORDER BY symbol
                LIMIT 10
            """, "SAMPLE INSTRUMENTS (First 10)")

            if rows:
                print("\nSymbol | Name                                | Type       | Asset Class")
                print("-" * 70)
                for symbol, name, inst_type, asset_class in rows:
                    print(f"{symbol:<6} | {name[:35]:<35} | {inst_type:<10} | {asset_class}")

            # 4. Allocation validation
            rows = execute_query(cur, """
                SELECT symbol,
                       (SELECT SUM(value::numeric) FROM jsonb_each_text(allocation_regions)) as regions_sum,
                       (SELECT SUM(value::numeric) FROM jsonb_each_text(allocation_sectors)) as sectors_sum,
                       (SELECT SUM(value::numeric) FROM jsonb_each_text(allocation_asset_class)) as asset_sum
                FROM instruments
                WHERE symbol IN ('SPY', 'QQQ', 'BND', 'VEA', 'GLD')
            """, "ALLOCATION VALIDATION (Sample ETFs)")

            if rows:
                print("\nVerifying allocations sum to 100%:\n")
                print("Symbol | Regions | Sectors | Assets | Status")
                print("-" * 50)
                for symbol, regions, sectors, assets in rows:
                    regions = float(regions or 0)
                    sectors = float(sectors or 0)
                    assets = float(assets or 0)
                    all_valid = regions == 100 and sectors == 100 and assets == 100
                    status = "Valid" if all_valid else "Invalid"
                    print(f"{symbol:<6} | {regions:>7}% | {sectors:>7}% | {assets:>6}% | {status}")

            # 5. Asset class distribution
            rows = execute_query(cur, """
                SELECT
                    COUNT(*) FILTER (WHERE (allocation_asset_class->>'equity')::numeric = 100) as pure_equity,
                    COUNT(*) FILTER (WHERE (allocation_asset_class->>'fixed_income')::numeric = 100) as pure_bonds,
                    COUNT(*) FILTER (WHERE (allocation_asset_class->>'real_estate')::numeric = 100) as real_estate,
                    COUNT(*) FILTER (WHERE (allocation_asset_class->>'commodities')::numeric = 100) as commodities,
                    COUNT(*) FILTER (WHERE jsonb_typeof(allocation_asset_class) = 'object'
                                    AND (SELECT COUNT(*) FROM jsonb_object_keys(allocation_asset_class)) > 1) as mixed,
                    COUNT(*) as total
                FROM instruments
            """, "ASSET CLASS DISTRIBUTION")

            if rows:
                r = rows[0]
                print("\nInstrument breakdown by asset class:\n")
                print(f"   Pure Equity ETFs:      {r[0]:>3}")
                print(f"   Pure Bond Funds:       {r[1]:>3}")
                print(f"   Real Estate ETFs:      {r[2]:>3}")
                print(f"   Commodity ETFs:        {r[3]:>3}")
                print(f"   Mixed Allocation ETFs: {r[4]:>3}")
                print(f"   " + "-" * 25)
                print(f"   TOTAL INSTRUMENTS:     {r[5]:>3}")

            # 6. Indexes
            rows = execute_query(cur, """
                SELECT schemaname, tablename, indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                AND indexname LIKE 'idx_%'
                ORDER BY tablename, indexname
            """, "DATABASE INDEXES")

            if rows:
                print(f"\nFound {len(rows)} custom indexes:")
                for _, table, idx in rows:
                    print(f"   {table}.{idx}")

            # 7. Triggers
            rows = execute_query(cur, """
                SELECT trigger_name, event_object_table
                FROM information_schema.triggers
                WHERE trigger_schema = 'public'
                ORDER BY event_object_table
            """, "DATABASE TRIGGERS")

            if rows:
                print(f"\nFound {len(rows)} update triggers:")
                for trigger, table in rows:
                    print(f"   {table}: {trigger}")

    print("\n" + "=" * 70)
    print("DATABASE VERIFICATION COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
