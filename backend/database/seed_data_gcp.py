#!/usr/bin/env python3
"""
GCP seed data loader — connects via Cloud SQL Auth Proxy on localhost:5432.
Start the proxy first:  cloud-sql-proxy $CLOUDSQL_CONNECTION_NAME --port 5432
"""

import os
import json
import psycopg
from src.schemas import InstrumentCreate
from pydantic import ValidationError
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

# Reuse the same INSTRUMENTS list from the AWS seed script
from seed_data import INSTRUMENTS


def insert_instrument(cur, instrument_data):
    try:
        instrument = InstrumentCreate(**instrument_data)
    except ValidationError as e:
        print(f"    Validation error: {e}")
        return False

    v = instrument.model_dump()

    sql = """
        INSERT INTO instruments (
            symbol, name, instrument_type, current_price,
            allocation_regions, allocation_sectors, allocation_asset_class
        ) VALUES (
            %(symbol)s, %(name)s, %(instrument_type)s, %(current_price)s,
            %(allocation_regions)s::jsonb, %(allocation_sectors)s::jsonb,
            %(allocation_asset_class)s::jsonb
        )
        ON CONFLICT (symbol) DO UPDATE SET
            name = EXCLUDED.name,
            instrument_type = EXCLUDED.instrument_type,
            current_price = EXCLUDED.current_price,
            allocation_regions = EXCLUDED.allocation_regions,
            allocation_sectors = EXCLUDED.allocation_sectors,
            allocation_asset_class = EXCLUDED.allocation_asset_class,
            updated_at = NOW()
    """

    try:
        cur.execute(sql, {
            "symbol": v["symbol"],
            "name": v["name"],
            "instrument_type": v["instrument_type"],
            "current_price": v.get("current_price", 0),
            "allocation_regions": json.dumps(v["allocation_regions"]),
            "allocation_sectors": json.dumps(v["allocation_sectors"]),
            "allocation_asset_class": json.dumps(v["allocation_asset_class"]),
        })
        return True
    except Exception as e:
        print(f"    Error: {e}")
        return False


def main():
    print("Seeding Instrument Data")
    print("=" * 50)
    print(f"Loading {len(INSTRUMENTS)} instruments...")

    print("\nVerifying allocation data...")
    all_valid = True
    for inst in INSTRUMENTS:
        try:
            InstrumentCreate(**inst)
        except ValidationError as e:
            print(f"  {inst['symbol']}: {e}")
            all_valid = False

    if not all_valid:
        print("\nSome instruments have invalid allocations. Fix before continuing.")
        exit(1)
    print("  All allocations valid!")

    print("\nInserting instruments...")
    success_count = 0

    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            for inst in INSTRUMENTS:
                print(f"  [{success_count + 1}/{len(INSTRUMENTS)}] {inst['symbol']}: {inst['name'][:40]}...")
                if insert_instrument(cur, inst):
                    print("    Success")
                    success_count += 1
                else:
                    print("    Failed")
            conn.commit()

        with conn.cursor() as cur:
            print("\nVerifying data...")
            cur.execute("SELECT COUNT(*) FROM instruments")
            count = cur.fetchone()[0]
            print(f"  Database now contains {count} instruments")

            cur.execute("SELECT symbol, name FROM instruments ORDER BY symbol LIMIT 5")
            print("\n  Sample instruments:")
            for row in cur.fetchall():
                print(f"    - {row[0]}: {row[1]}")

    print(f"\nSeeding complete: {success_count}/{len(INSTRUMENTS)} instruments loaded")
    print("\nNext steps:")
    print("1. Create test user and portfolio: uv run create_test_data.py")
    print("2. Test database operations: uv run test_db.py")


if __name__ == "__main__":
    main()
