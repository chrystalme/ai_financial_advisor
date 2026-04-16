#!/usr/bin/env python3
"""
GCP Database Reset Script
Drops all tables, recreates schema, loads seed data, and creates test user.
Connects via Cloud SQL Auth Proxy on localhost:5432.
"""

import sys
import os
import argparse
import subprocess
from decimal import Decimal

os.environ.setdefault("CLOUD_PROVIDER", "gcp")

from src.models import Database
from src.schemas import UserCreate, AccountCreate, PositionCreate
from dotenv import load_dotenv

load_dotenv(override=True)


def drop_all_tables(db):
    tables_to_drop = ["positions", "accounts", "jobs", "instruments", "users"]
    print("Dropping existing tables...")
    for table in tables_to_drop:
        try:
            db.execute_raw(f"DROP TABLE IF EXISTS {table} CASCADE")
            print(f"   Dropped {table}")
        except Exception as e:
            print(f"   Error dropping {table}: {e}")
    try:
        db.execute_raw("DROP FUNCTION IF EXISTS update_updated_at_column() CASCADE")
        print("   Dropped update_updated_at_column function")
    except Exception as e:
        print(f"   Error dropping function: {e}")


def create_test_data(db):
    print("\nCreating test user and portfolio...")

    existing = db.users.find_by_clerk_id("test_user_001")
    if existing:
        print("   Test user already exists")
    else:
        db.users.create_user(
            clerk_user_id="test_user_001",
            display_name="Test User",
            years_until_retirement=25,
            target_retirement_income=Decimal("100000"),
        )
        print("   Created test user")

    accounts_data = [
        AccountCreate(
            account_name="401(k)",
            account_purpose="Primary retirement savings",
            cash_balance=Decimal("5000"),
            cash_interest=Decimal("0.045"),
        ),
        AccountCreate(
            account_name="Roth IRA",
            account_purpose="Tax-free retirement savings",
            cash_balance=Decimal("1000"),
            cash_interest=Decimal("0.04"),
        ),
        AccountCreate(
            account_name="Taxable Brokerage",
            account_purpose="General investment account",
            cash_balance=Decimal("2500"),
            cash_interest=Decimal("0.035"),
        ),
    ]

    user_accounts = db.accounts.find_by_user("test_user_001")
    if user_accounts:
        print(f"   User already has {len(user_accounts)} accounts")
        account_ids = [acc["id"] for acc in user_accounts]
    else:
        account_ids = []
        for acc_data in accounts_data:
            v = acc_data.model_dump()
            acc_id = db.accounts.create_account(
                "test_user_001",
                account_name=v["account_name"],
                account_purpose=v["account_purpose"],
                cash_balance=v["cash_balance"],
                cash_interest=v["cash_interest"],
            )
            account_ids.append(acc_id)
            print(f"   Created account: {v['account_name']}")

    if account_ids:
        positions = [
            ("SPY", Decimal("100")),
            ("QQQ", Decimal("50")),
            ("BND", Decimal("200")),
            ("VEA", Decimal("150")),
            ("GLD", Decimal("25")),
        ]

        account_id = account_ids[0]
        existing_positions = db.positions.find_by_account(account_id)
        if existing_positions:
            print(f"   Account already has {len(existing_positions)} positions")
        else:
            for symbol, quantity in positions:
                db.positions.add_position(account_id, symbol, quantity)
                print(f"   Added position: {quantity} shares of {symbol}")


def main():
    parser = argparse.ArgumentParser(description="Reset Alex database (GCP)")
    parser.add_argument("--with-test-data", action="store_true",
                        help="Create test user with sample portfolio")
    parser.add_argument("--skip-drop", action="store_true",
                        help="Skip dropping tables (just reload data)")
    args = parser.parse_args()

    print("Database Reset Script (GCP)")
    print("=" * 50)

    db = Database()

    if not args.skip_drop:
        drop_all_tables(db)

        print("\nRunning migrations...")
        result = subprocess.run(["uv", "run", "run_migrations_gcp.py"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print("Migration failed!")
            print(result.stderr)
            sys.exit(1)
        print("Migrations completed")

    print("\nLoading seed data...")
    result = subprocess.run(["uv", "run", "seed_data_gcp.py"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print("Seed data failed!")
        print(result.stderr)
        sys.exit(1)
    print("Seed data loaded")

    if args.with_test_data:
        create_test_data(db)

    print("\nFinal verification...")
    tables = ["users", "instruments", "accounts", "positions", "jobs"]
    for table in tables:
        result = db.query_raw(f"SELECT COUNT(*) as count FROM {table}")
        count = result[0]["count"] if result else 0
        print(f"   {table}: {count} records")

    print("\n" + "=" * 50)
    print("Database reset complete!")

    if args.with_test_data:
        print("\nTest user created:")
        print("   User ID: test_user_001")
        print("   3 accounts (401k, Roth IRA, Taxable)")
        print("   5 positions in 401k account")


if __name__ == "__main__":
    main()
