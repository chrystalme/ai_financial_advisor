# Guide 7 (GCP) — Frontend and API on GCP

GCP parallel to `7_frontend.md`. Clerk authentication is identical across both tracks.

## What this replaces

| AWS | GCP |
|---|---|
| CloudFront + S3 static site | Cloud CDN + Cloud Storage bucket (with load balancer) |
| API Gateway + Lambda backend | API Gateway (GCP) + Cloud Run backend service |
| Clerk auth | Clerk auth (unchanged) |

An alternative simpler path: **deploy the Next.js frontend to Vercel or Firebase Hosting and only use GCP for the API.** This is often a better choice for students — the GCS + load balancer + Cloud CDN setup has more moving parts than it's worth for a static Next.js export. The Terraform in `terraform/7_frontend_gcp/` supports both modes via `frontend_host = "gcs" | "external"`.

## 1. Terraform

```bash
cd terraform/7_frontend_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, clerk_jwks_url, clerk_issuer, frontend_host
terraform init && terraform apply
```

Creates:
- Cloud Run service `alex-api` (FastAPI backend)
- API Gateway in front of `alex-api`, validating Clerk JWTs via a custom authorizer in the API
- If `frontend_host=gcs`: GCS bucket `<project>-alex-frontend`, global HTTPS load balancer, Cloud CDN, managed SSL cert

## 2. Frontend build and deploy

The frontend is unchanged Next.js Pages Router (required by Clerk).

```bash
cd frontend
cp .env.local.example .env.local
# set NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, CLERK_SECRET_KEY, NEXT_PUBLIC_API_URL
npm install
npm run build && npm run export     # produces out/
```

Deploy:
- **GCS + CDN path**: `uv run scripts/deploy_gcp.py --target=gcs`
- **Vercel path**: `npx vercel --prod` from `frontend/`

## 3. API backend

`backend/api/` is a FastAPI app, same as the AWS track. It runs as a Cloud Run service with:
- Clerk JWT validation middleware (reads `CLERK_JWKS_URL`)
- Cloud SQL connection via `--add-cloudsql-instances`
- Pub/Sub publishing to kick off agent jobs

Deploy:
```bash
gcloud run deploy alex-api \
  --source=backend/api \
  --region=us-central1 \
  --allow-unauthenticated
```
(API Gateway in front enforces the actual auth.)

## 4. DNS

Point your domain at the load balancer IP from terraform output `frontend_lb_ip`. Managed SSL will auto-provision within ~30 minutes once DNS resolves.

## Common issues

- **CORS errors in browser** — Set `ALLOWED_ORIGINS` env on `alex-api` to include your frontend domain.
- **Clerk JWT validation fails** — `CLERK_JWKS_URL` in the API must match your Clerk instance exactly, including trailing path.
- **Managed SSL stuck on `PROVISIONING`** — DNS hasn't propagated yet. Wait and re-check with `gcloud compute ssl-certificates describe`.

Proceed to `8_enterprise_gcp.md`.
