# Guide 7 (Azure) — Frontend and API on Azure

Azure parallel to `7_frontend.md`. Clerk auth is unchanged.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| CloudFront + S3 | Cloud CDN + GCS | Azure Static Web Apps OR Storage static website + Front Door |
| API Gateway + Lambda | API Gateway + Cloud Run | APIM (Consumption) + Container App running FastAPI |
| Clerk | Clerk | Clerk |

**Recommended:** **Azure Static Web Apps** for the frontend — it's purpose-built for Next.js static exports, includes global CDN and free SSL. The Storage + Front Door path is documented as an alternative (`frontend_host` variable).

## 1. Terraform

```bash
cd terraform/7_frontend_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location, clerk_jwks_url, clerk_issuer,
#       frontend_host (swa / storage), servicebus_namespace, postgres_host,
#       db_secret_uri
terraform init && terraform apply
```

Creates:
- Container App `alex-api` running FastAPI (0–10 replicas)
- User-assigned managed identity with Key Vault Secrets User, Service Bus Data Sender, Cognitive Services OpenAI User
- APIM Consumption instance (or reuse from Guide 3 via `apim_name` variable) with a product + subscription for the frontend
- If `frontend_host=swa`: Azure Static Web Apps resource (Standard tier for custom domains)
- If `frontend_host=storage`: Storage account configured as static website + Front Door profile + endpoint

## 2. Frontend build and deploy

```bash
cd frontend
cp .env.local.example .env.local
# set NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, CLERK_SECRET_KEY, NEXT_PUBLIC_API_URL
npm install
npm run build && npm run export        # produces out/
```

Deploy:
- **SWA path**: `npx @azure/static-web-apps-cli deploy ./out --deployment-token <token>` (token from terraform output)
- **Storage path**: `uv run scripts/deploy_azure.py --target=storage`

## 3. API backend

`backend/api/` is a FastAPI app, same as the other tracks. It runs as a Container App with:
- Clerk JWT validation middleware (reads `CLERK_JWKS_URL`)
- PostgreSQL via `DATABASE_URL` Key Vault reference
- Service Bus publishing via MI
- APIM in front enforces subscription key auth

Build/push image (same pattern as Guide 4).

## 4. DNS and SSL

- **SWA**: add custom domain via portal, Azure auto-provisions SSL.
- **Storage + Front Door**: custom domain on the Front Door endpoint, managed cert auto-issues within 15 minutes once DNS is in place.

## Common issues

- **CORS errors** — set `ALLOWED_ORIGINS` env on `alex-api` to include the SWA or Front Door domain.
- **Clerk 401** — `CLERK_JWKS_URL` must match your Clerk instance precisely.
- **APIM `PolicyValidationError`** — subscription key policy may conflict with CORS policy order. Put `<base />` first in both inbound and outbound.
- **SWA free tier hit** — custom domains need Standard tier.

Proceed to `8_enterprise_azure.md`.
