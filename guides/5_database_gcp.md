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

## 2. Load schema and seed data

The schema is shared with the AWS track (`backend/database/schema.sql`). Load via Cloud SQL Auth Proxy:

```bash
# In one terminal:
cloud-sql-proxy $CLOUDSQL_CONNECTION_NAME --port 5432

# In another:
cd backend/database
uv run migrate.py                        # applies schema.sql
uv run load_seed_data.py                 # loads the 22 seed ETFs
```

Download the proxy if you don't have it:
```bash
curl -o cloud-sql-proxy https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.13.0/cloud-sql-proxy.darwin.arm64
chmod +x cloud-sql-proxy
```

## 3. How agents connect

Lambda used the Aurora Data API (HTTP). Cloud Run / Cloud Functions connect differently:

- **Cloud Run**: attach the SQL instance via `--add-cloudsql-instances` — the proxy runs in the container automatically.
- **Cloud Functions (2nd gen)**: same flag, connection via Unix socket at `/cloudsql/<connection_name>`.

The shared `backend/database` library should use an env-driven connection string. Terraform sets:
```
DATABASE_URL=postgresql+psycopg://alex_app:<pw>@/alex?host=/cloudsql/<connection_name>
```

## 4. Cost control

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
