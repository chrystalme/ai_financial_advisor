#!/usr/bin/env python3
"""
Test Cloud SQL connection via Cloud SQL Auth Proxy on localhost:5432.
Start the proxy first:  cloud-sql-proxy $CLOUDSQL_CONNECTION_NAME --port 5432
"""

import os
import sys
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
    print("Get it with: gcloud secrets versions access latest --secret=alex-db-credentials")
    sys.exit(1)

conninfo = f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} user={DB_USER} password={DB_PASSWORD}"


def main():
    print("Cloud SQL Connection Test")
    print("=" * 50)
    print(f"Host: {DB_HOST}:{DB_PORT}")
    print(f"Database: {DB_NAME}")
    print(f"User: {DB_USER}")
    print("-" * 50)

    try:
        conn = psycopg.connect(conninfo)
    except Exception as e:
        print(f"\nConnection failed: {e}")
        print("\nTroubleshooting:")
        print("  1. Is cloud-sql-proxy running? (cloud-sql-proxy <connection_name> --port 5432)")
        print("  2. Is the Cloud SQL instance started? (activation_policy=ALWAYS)")
        print("  3. Is DB_PASSWORD correct?")
        sys.exit(1)

    print("\n1. Testing basic SELECT...")
    with conn.cursor() as cur:
        cur.execute("SELECT 1 AS test, current_timestamp AS server_time")
        row = cur.fetchone()
        print(f"   Connection successful!")
        print(f"   Server time: {row[1]}")

    print("\n2. Checking for existing tables...")
    with conn.cursor() as cur:
        cur.execute("""
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = 'public'
            ORDER BY table_name
        """)
        tables = [r[0] for r in cur.fetchall()]

        if tables:
            print(f"   Found {len(tables)} tables:")
            for t in tables:
                print(f"      - {t}")
        else:
            print("   No tables found (database is empty)")
            print("   Run: uv run run_migrations_gcp.py")

    print("\n3. Checking database info...")
    with conn.cursor() as cur:
        cur.execute("SELECT pg_database_size(%s)", (DB_NAME,))
        size_bytes = cur.fetchone()[0]
        size_mb = size_bytes / (1024 * 1024)
        print(f"   Database size: {size_mb:.2f} MB")

    conn.close()

    print("\n" + "=" * 50)
    print("Cloud SQL connection is working!")
    print("\nNext steps:")
    print("1. Run migrations: uv run run_migrations_gcp.py")
    print("2. Load seed data: uv run seed_data_gcp.py")
    print("3. Verify database: uv run verify_database_gcp.py")


if __name__ == "__main__":
    main()
