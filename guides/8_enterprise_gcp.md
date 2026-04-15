# Guide 8 (GCP) — Enterprise Grade

GCP parallel to `8_enterprise.md`. Observability, security, scalability, and guardrails.

## What this replaces

| AWS | GCP |
|---|---|
| CloudWatch dashboards + alarms | Cloud Monitoring dashboards + alerting policies |
| WAF | Cloud Armor |
| VPC endpoints, GuardDuty | VPC Service Controls, Security Command Center |
| LangFuse | LangFuse (unchanged — SaaS) |
| Bedrock Guardrails | Vertex AI Safety Filters (built-in) + application-layer guardrails |

## 1. Terraform

```bash
cd terraform/8_enterprise_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, notification_email, vertex_model_id
terraform init && terraform apply
```

Creates:
- Cloud Monitoring dashboard `alex-overview` with panels for:
  - Cloud Run request count / latency / error rate (per service)
  - Vertex AI prediction count and latency
  - Cloud SQL CPU / connections / storage
  - Pub/Sub unacked message age
- Alerting policies:
  - Cloud Run 5xx rate > 1% for 5 min
  - Pub/Sub oldest-unacked > 5 min
  - Cloud SQL CPU > 80% for 10 min
  - Vertex AI error rate > 5%
- Log-based metric for agent task latency
- Cloud Armor policy attached to the frontend LB (rate limiting, basic OWASP rules)
- Uptime check on the `alex-api` health endpoint

## 2. LangFuse

Identical to AWS track. Sign up at langfuse.com, create a project, set:
```
LANGFUSE_PUBLIC_KEY=...
LANGFUSE_SECRET_KEY=...
LANGFUSE_HOST=https://us.cloud.langfuse.com
```
Terraform puts these into Cloud Run env vars for every agent.

## 3. Safety and guardrails

Vertex AI Gemini has built-in safety filters (harm categories). They're enabled by default. To tune per-call, pass `safety_settings` via LiteLLM — see `backend/planner/agent.py` for the pattern.

Application-layer guardrails (input validation, PII scrubbing, output sanity checks) live in `backend/<agent>/guardrails.py` and are shared across both cloud tracks.

## 4. Explainability

For each job, the Planner writes a trace record to Cloud SQL with:
- Which agents ran and in what order
- Input/output of each step
- Token counts and costs (Vertex API returns usage metadata)
- LangFuse trace URL

The frontend surfaces this via `/jobs/<id>/trace`.

## 5. Scalability knobs

- Cloud Run: `--min-instances=1` on the API to kill cold starts (costs ~$10/month per service)
- Vertex AI: request quota increases via `gcloud alpha services quota update`
- Cloud SQL: scale tier or enable read replicas for heavy reporter workloads
- Pub/Sub: default quotas are vastly above what this project needs

## Common issues

- **Alerts not firing** — Notification channel not confirmed. Check email for a Google confirmation link.
- **Dashboard blank** — Metrics take 5–10 min to populate after first traffic.
- **Vertex safety filter rejecting legitimate output** — Log the `finish_reason`; if it's `SAFETY`, relax `BLOCK_ONLY_HIGH` → `BLOCK_NONE` (only in dev).

## Teardown

```bash
# Reverse order
for D in 8_enterprise_gcp 7_frontend_gcp 6_agents_gcp 5_database_gcp 4_researcher_gcp 3_ingestion_gcp 2_vertexai_gcp; do
  (cd terraform/$D && terraform destroy -auto-approve)
done
```

Biggest cost savings: destroying `3_ingestion_gcp` (index endpoint) and `5_database_gcp` (Cloud SQL instance).
