# Guide 5 (GCP) — Cloud SQL for PostgreSQL

GCP parallel to `5_database.md`.

## What this replaces

| AWS | GCP |
|---|---|
| Aurora Serverless v2 PostgreSQL | Cloud SQL for PostgreSQL 16 (`db-f1-micro` or `db-custom-1-3840`) |
| Data API (HTTP) | Cloud SQL Auth Proxy + psycopg (no VPC complexity) |
| Secrets Manager | Secret Manager (Google) |

**Important cost note:** Cloud SQL has no true serverless/scale-to-zero option. Even the smallest instance costs ~$7–15/month continuously. Stop the instance when not in use:
```bash
gcloud sql instances patch alex-db --activation-policy=NEVER   # stop
gcloud sql instances patch alex-db --activation-policy=ALWAYS  # start
```

Consider **AlloyDB Omni on Cloud Run** or **Neon via Vercel Marketplace** for cheaper dev options — but Cloud SQL is the canonical path.

## 1. Terraform

```bash
cd terraform/5_database_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, db_tier, db_password (or use generated)
terraform init && terraform apply
terraform output
```

Creates:
- Cloud SQL PostgreSQL 16 instance `alex-db`
- Database `alex`, user `alex_app`
- Secret Manager secret `alex-db-credentials` (JSON with connection params)
- (No VPC — uses public IP with authorized networks + SSL, simpler for the course)

Outputs record:
```
CLOUDSQL_CONNECTION_NAME=project:region:alex-db
CLOUDSQL_INSTANCE_IP=...
DB_SECRET_NAME=alex-db-credentials
```

## 2. Connect and test

Install the Cloud SQL Auth Proxy if you don't have it:
```bash
brew install cloud-sql-proxy
```

Get your database password from Secret Manager:
```bash
gcloud secrets versions access latest --secret=alex-db-credentials | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])"
```

In one terminal, start the proxy (keep it running):
```bash
cloud-sql-proxy <CLOUDSQL_CONNECTION_NAME from terraform output> --port 5432
```

In another terminal, export credentials and test:
```bash
cd backend/database
export DB_PASSWORD="<password from above>"
uv run test_db_gcp.py                    # verify connection works
```

## 3. Load schema and seed data

```bash
cd backend/database
uv run run_migrations_gcp.py             # creates schema (17 statements)
uv run seed_data_gcp.py                  # loads the 22 seed ETFs
uv run verify_database_gcp.py            # full verification report
```

| Script | Purpose |
|---|---|
| `test_db_gcp.py` | Quick connection test, lists tables |
| `run_migrations_gcp.py` | Creates tables, indexes, triggers |
| `seed_data_gcp.py` | Loads 22 ETF instruments with allocations |
| `verify_database_gcp.py` | Full report: counts, allocations, indexes, triggers |

## 4. How agents connect

Lambda used the Aurora Data API (HTTP). Cloud Run / Cloud Functions connect differently:

- **Cloud Run**: attach the SQL instance via `--add-cloudsql-instances` — the proxy runs in the container automatically.
- **Cloud Functions (2nd gen)**: same flag, connection via Unix socket at `/cloudsql/<connection_name>`.

The shared `backend/database` library should use an env-driven connection string. Terraform sets:
```
DATABASE_URL=postgresql+psycopg://alex_app:<pw>@/alex?host=/cloudsql/<connection_name>
```

## 5. Cost control

Stop the instance between sessions:
```bash
gcloud sql instances patch alex-db --activation-policy=NEVER
```
Or `terraform destroy` — but re-creating takes 10–15 minutes.

## Common issues

- **`connection refused` from Cloud Run** — Missing `--add-cloudsql-instances` on the service, or the SA lacks `roles/cloudsql.client`.
- **Slow first connect** — Cloud SQL cold-starts when stopped for a while; wait 1–2 minutes after starting.
- **SSL errors from local** — Use the Auth Proxy, don't try to connect directly over the public IP.

Proceed to `6_agents_gcp.md`.
