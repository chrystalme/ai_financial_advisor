# Guide 4 (GCP) — Researcher Agent on Cloud Run

GCP parallel to `4_researcher.md`. Deploys the long-running market-research agent on Cloud Run (replaces App Runner).

## What this replaces

| AWS | GCP |
|---|---|
| App Runner service | Cloud Run service (min instances=0, CPU-always-allocated while serving) |
| ECR repository | Artifact Registry repository |
| Bedrock Nova Pro via LiteLLM | Vertex AI Gemini 2.5 Pro via LiteLLM (`vertex_ai/gemini-2.5-pro`) |
| EventBridge scheduler (optional) | Cloud Scheduler (optional) |

**Playwright MCP server** runs in the same container as on AWS — it is runtime-agnostic.

## 1. Prerequisites

- Docker Desktop running locally (terraform builds and pushes the image via `local-exec`).
- `gcloud` authenticated (`gcloud auth login` + `gcloud auth application-default login`).

## 2. Terraform (builds and pushes the container as part of apply)

```bash
cd terraform/4_researcher_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, alex_api_endpoint, alex_api_key (from guide 3)
terraform init && terraform apply
```

What terraform does, in order:
1. Creates the Artifact Registry repository `alex`.
2. Runs `gcloud auth configure-docker`, `docker build --platform linux/amd64`, and `docker push` against `backend/researcher/` via a `null_resource` with `local-exec`. Rebuild is triggered whenever any file under `backend/researcher/` changes (hash-based trigger).
3. Creates the Cloud Run service `alex-researcher` (public, IAM-invoker on a service account), the service account with Vertex AI User + Secret Manager Accessor, and an optional Cloud Scheduler job (disabled by default — set `scheduler_enabled=true`).

> **Note on image rollouts:** the Cloud Run resource has `ignore_changes = [template[0].containers[0].image]`, so after a source change terraform will push a new `:latest` image but won't force a new Cloud Run revision. To roll out the new image, run:
>
> ```bash
> gcloud run services update alex-researcher --region=us-central1
> ```

## 3. Configure the agent for Vertex AI

The backend code is shared — we only change environment variables. Cloud Run environment (set by Terraform):
```
CLOUD_PROVIDER=gcp
VERTEX_PROJECT=<project_id>
VERTEX_LOCATION=us-central1
MODEL_ID=vertex_ai/gemini-2.5-pro
ALEX_API_ENDPOINT=...
ALEX_API_KEY=...
```

LiteLLM resolves `vertex_ai/gemini-2.5-pro` using the Cloud Run service account's ADC. No key file mounting needed.

## 4. Smoke test

```bash
REGION=us-central1
RESEARCHER_URL=$(gcloud run services describe alex-researcher --region=$REGION --format='value(status.url)')
curl -X POST "$RESEARCHER_URL/research" \
  -H "Content-Type: application/json" \
  -d '{"topic":"latest AI chip news"}'
```

## 5. (Optional) Scheduled runs

```bash
cd terraform/4_researcher_gcp
terraform apply -var="scheduler_enabled=true" -var="schedule_cron=0 */6 * * *"
```

## Common issues

- **`PERMISSION_DENIED` calling Vertex AI from Cloud Run** — The service account is missing `roles/aiplatform.user`. Terraform grants it; verify in IAM console.
- **Container fails to start** — Usually a Playwright Chromium path issue. Build for `linux/amd64` (important on Apple Silicon).
- **Agent hangs** — Cloud Run default timeout is 300s. For long research runs, increase: `--timeout=3600s`.

Proceed to `5_database_gcp.md`.
