# Guide 5 (Azure) — Azure Database for PostgreSQL Flexible Server

Azure parallel to `5_database.md`.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| Aurora Serverless v2 | Cloud SQL | Azure Database for PostgreSQL Flexible Server (B1ms burstable) |
| Data API (HTTP) | Cloud SQL Auth Proxy | Direct psycopg over TLS (public access with firewall rules, or VNet for prod) |
| Secrets Manager | Secret Manager | Key Vault |

**Cost note:** Burstable `B1ms` is ~$12/month. Stop the server between sessions:
```bash
az postgres flexible-server stop -g alex-rg -n alex-db
az postgres flexible-server start -g alex-rg -n alex-db
```

## 1. Terraform

```bash
cd terraform/5_database_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location, db_sku,
#       db_admin_password (or leave empty to auto-generate)
terraform init && terraform apply
terraform output
```

Creates:
- Flexible Server `alex-db`, PostgreSQL 16, Burstable B1ms, 32 GB storage
- Database `alex`, admin user `alex_admin`
- Firewall rule allowing Azure services (`AllowAllAzureServices`) — remove for production
- Firewall rule for your current client IP (detected via `http.icanhazip.com` during apply, overridable)
- Key Vault `alex-kv-<suffix>` with secret `alex-db-credentials` (JSON)
- Private endpoint (optional, controlled by `use_private_endpoint`)

Outputs:
```
POSTGRES_HOST=alex-db.postgres.database.azure.com
POSTGRES_DB=alex
POSTGRES_USER=alex_admin
DB_SECRET_NAME=alex-db-credentials
KEY_VAULT_NAME=alex-kv-...
```

## 2. Load schema and seed data

Schema is shared with the other tracks (`backend/database/schema.sql`).

```bash
cd backend/database
export DATABASE_URL="postgresql+psycopg://alex_admin:<pw>@alex-db.postgres.database.azure.com:5432/alex?sslmode=require"
uv run migrate.py
uv run load_seed_data.py
```

## 3. How agents connect

- **Azure Functions / Container Apps**: pull the connection string from Key Vault via a reference (`@Microsoft.KeyVault(SecretUri=...)`). The MI must have `Key Vault Secrets User` on the Key Vault — Terraform grants this per-agent in Guide 6.
- **Local dev**: use the `DATABASE_URL` env directly.

The shared `backend/database` library reads `DATABASE_URL` and uses psycopg's connection pool. On Azure, `sslmode=require` is mandatory.

## 4. Cost control

```bash
az postgres flexible-server stop -g alex-rg -n alex-db
```
Stopping preserves data; the server auto-starts on first connection attempt after ~60s.

## Common issues

- **`could not translate host name`** — use the full FQDN (`alex-db.postgres.database.azure.com`), not just the server name.
- **`no pg_hba.conf entry`** — firewall rule missing for your IP. Terraform adds the deploy-time IP; your home/office IP may have changed.
- **`SSL off` errors** — add `sslmode=require` to the connection string.
- **Cold-start latency after stop** — first query takes ~60s; subsequent queries are normal.

Proceed to `6_agents_azure.md`.
