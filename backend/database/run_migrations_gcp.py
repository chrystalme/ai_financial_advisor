#!/usr/bin/env python3
"""
GCP migration runner — connects via Cloud SQL Auth Proxy on localhost:5432.
Start the proxy first:  cloud-sql-proxy $CLOUDSQL_CONNECTION_NAME --port 5432
"""

import os
import psycopg
from dotenv import load_dotenv

load_dotenv(override=True)

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "alex")
DB_USER = os.environ.get("DB_USER", "alex_app")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

if not DB_PASSWORD:
    raise ValueError("DB_PASSWORD must be set (check terraform output or Secret Manager)")

conninfo = f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} user={DB_USER} password={DB_PASSWORD}"

statements = [
    'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"',
    """CREATE TABLE IF NOT EXISTS users (
        clerk_user_id VARCHAR(255) PRIMARY KEY,
        display_name VARCHAR(255),
        years_until_retirement INTEGER,
        target_retirement_income DECIMAL(12,2),
        asset_class_targets JSONB DEFAULT '{"equity": 70, "fixed_income": 30}',
        region_targets JSONB DEFAULT '{"north_america": 50, "international": 50}',
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS instruments (
        symbol VARCHAR(20) PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        instrument_type VARCHAR(50),
        current_price DECIMAL(12,4),
        allocation_regions JSONB DEFAULT '{}',
        allocation_sectors JSONB DEFAULT '{}',
        allocation_asset_class JSONB DEFAULT '{}',
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS accounts (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        clerk_user_id VARCHAR(255) REFERENCES users(clerk_user_id) ON DELETE CASCADE,
        account_name VARCHAR(255) NOT NULL,
        account_purpose TEXT,
        cash_balance DECIMAL(12,2) DEFAULT 0,
        cash_interest DECIMAL(5,4) DEFAULT 0,
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS positions (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
        symbol VARCHAR(20) REFERENCES instruments(symbol),
        quantity DECIMAL(20,8) NOT NULL,
        as_of_date DATE DEFAULT CURRENT_DATE,
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW(),
        UNIQUE(account_id, symbol)
    )""",
    """CREATE TABLE IF NOT EXISTS jobs (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        clerk_user_id VARCHAR(255) REFERENCES users(clerk_user_id) ON DELETE CASCADE,
        job_type VARCHAR(50) NOT NULL,
        status VARCHAR(20) DEFAULT 'pending',
        request_payload JSONB,
        report_payload JSONB,
        charts_payload JSONB,
        retirement_payload JSONB,
        summary_payload JSONB,
        error_message TEXT,
        created_at TIMESTAMP DEFAULT NOW(),
        started_at TIMESTAMP,
        completed_at TIMESTAMP,
        updated_at TIMESTAMP DEFAULT NOW()
    )""",
    "CREATE INDEX IF NOT EXISTS idx_accounts_user ON accounts(clerk_user_id)",
    "CREATE INDEX IF NOT EXISTS idx_positions_account ON positions(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_positions_symbol ON positions(symbol)",
    "CREATE INDEX IF NOT EXISTS idx_jobs_user ON jobs(clerk_user_id)",
    "CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status)",
    """CREATE OR REPLACE FUNCTION update_updated_at_column()
    RETURNS TRIGGER AS $$
    BEGIN
        NEW.updated_at = NOW();
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql""",
    """CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()""",
    """CREATE TRIGGER update_instruments_updated_at BEFORE UPDATE ON instruments
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()""",
    """CREATE TRIGGER update_accounts_updated_at BEFORE UPDATE ON accounts
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()""",
    """CREATE TRIGGER update_positions_updated_at BEFORE UPDATE ON positions
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()""",
    """CREATE TRIGGER update_jobs_updated_at BEFORE UPDATE ON jobs
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()""",
]

print("Running database migrations...")
print("=" * 50)

success_count = 0
error_count = 0

with psycopg.connect(conninfo) as conn:
    conn.autocommit = True
    with conn.cursor() as cur:
        for i, stmt in enumerate(statements, 1):
            stmt_type = "statement"
            for kw in ["TABLE", "INDEX", "TRIGGER", "FUNCTION", "EXTENSION"]:
                if f"CREATE {kw}" in stmt.upper() or f"CREATE OR REPLACE {kw}" in stmt.upper():
                    stmt_type = kw.lower()
                    break

            first_line = next(l for l in stmt.split("\n") if l.strip())[:60]
            print(f"\n[{i}/{len(statements)}] Creating {stmt_type}...")
            print(f"    {first_line}...")

            try:
                cur.execute(stmt)
                print("    Success")
                success_count += 1
            except psycopg.errors.DuplicateObject:
                print("    Already exists (skipping)")
                success_count += 1
            except Exception as e:
                print(f"    Error: {e}")
                error_count += 1

print("\n" + "=" * 50)
print(f"Migration complete: {success_count} successful, {error_count} errors")

if error_count == 0:
    print("\nAll migrations completed successfully!")
    print("\nNext steps:")
    print("1. Load seed data: uv run seed_data_gcp.py")
    print("2. Test database: uv run verify_database.py")
else:
    print(f"\nSome statements failed. Check errors above.")
