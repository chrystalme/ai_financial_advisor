# Guide 6 (GCP) — Agent Orchestra on Cloud Run Functions + Pub/Sub

GCP parallel to `6_agents.md`. The big one.

## What this replaces

| AWS | GCP |
|---|---|
| 5 Lambda functions (Planner, Tagger, Reporter, Charter, Retirement) | 5 Cloud Run functions (2nd gen) with the same names |
| SQS queue | Pub/Sub topic + subscription |
| S3 bucket for Lambda packages | GCS bucket for source zips |
| Bedrock Nova Pro | Vertex AI Gemini 2.5 Pro |

**Backend code is unchanged.** All that differs:
- `lambda_handler.py` keeps its name, but Cloud Run functions invoke it via a small shim — or we expose an HTTP entrypoint. Our packaging script handles this.
- Environment variables: `MODEL_ID=vertex_ai/gemini-2.5-pro`, `VERTEX_PROJECT`, `VERTEX_LOCATION`.
- Queue client switches from `boto3.sqs` to `google.cloud.pubsub_v1` — already abstracted in `backend/planner/queue.py`.

## 1. Terraform

```bash
cd terraform/6_agents_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, cloudsql_connection_name, db_secret_name,
#       vector_index_endpoint_id, vertex_model_id, polygon_api_key
terraform init && terraform apply
```

Creates:
- 5 Cloud Run function services: `alex-planner`, `alex-tagger`, `alex-reporter`, `alex-charter`, `alex-retirement`
- Pub/Sub topic `alex-agent-jobs` + subscription driving the Planner
- GCS bucket `<project>-alex-functions` for source zips
- Dedicated service account per function with least-privilege roles
- Secret Manager access for DB creds, Polygon key, LangFuse keys

## 2. Package and deploy

From repo root:
```bash
uv run scripts/package_gcp.py                  # zips each backend/<agent> into GCS
cd terraform/6_agents_gcp && terraform apply   # re-apply to pick up new source_hash
```

Or let Cloud Build handle it:
```bash
gcloud builds submit backend/planner --tag=us-central1-docker.pkg.dev/$PROJECT_ID/alex/planner:latest
```

## 3. Orchestration flow

```
User Request → API Gateway → Planner (HTTP-triggered Cloud Run function)
                                ├─ publishes jobs to Pub/Sub topic
                                │    → Tagger subscriber
                                │    → Reporter subscriber
                                │    → Charter subscriber
                                │    → Retirement subscriber
                                └─ aggregates results → Cloud SQL
```

Pub/Sub replaces SQS. At-least-once delivery semantics are the same; our idempotency logic in the Planner is unchanged.

## 4. Test locally (mocked)

```bash
cd backend/planner
MOCK_LAMBDAS=true CLOUD_PROVIDER=gcp uv run test_simple.py
```

## 5. Test deployed

```bash
cd backend/planner
uv run test_full.py
```

`test_full.py` reads `CLOUD_PROVIDER` from env and routes to Pub/Sub + Cloud Run URLs instead of SQS + Lambda.

## Common issues

- **`DeadlineExceeded` from Vertex AI** — Gemini 2.5 Pro has high quotas by default but quotas are per-region. Check `gcloud ai quota list`.
- **Pub/Sub messages piling up** — Subscriber function crashed on startup. Check `gcloud run services logs tail alex-<agent>`.
- **`could not translate host name "/cloudsql/..."`** — Forgot `--add-cloudsql-instances` on the Cloud Run function. Terraform sets this; if you deployed manually, add it.
- **LiteLLM can't find credentials** — The Cloud Run SA needs `roles/aiplatform.user`. Do NOT bake a service account key into the image.

Proceed to `7_frontend_gcp.md`.
