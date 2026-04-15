# Guide 8 (Azure) — Enterprise Grade

Azure parallel to `8_enterprise.md`.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| CloudWatch dashboards + alarms | Cloud Monitoring | Azure Monitor workbook + metric alerts + Application Insights |
| WAF | Cloud Armor | Azure Front Door WAF policy |
| VPC endpoints, GuardDuty | VPC-SC, Security Command Center | Private Endpoints + Microsoft Defender for Cloud |
| LangFuse | LangFuse | LangFuse (unchanged SaaS) |
| Bedrock Guardrails | Vertex safety filters | Azure AI Content Safety + application guardrails |

## 1. Terraform

```bash
cd terraform/8_enterprise_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location, notification_email,
#       openai_resource_name, api_container_app_name, agent_function_apps
terraform init && terraform apply
```

Creates:
- Action Group for email alerts
- Metric alerts:
  - Container App HTTP 5xx rate > 1% (5 min)
  - Service Bus active messages > 50 OR oldest message age > 5 min
  - PostgreSQL CPU > 80% (10 min)
  - Azure OpenAI request failure rate > 5%
- Log Analytics saved query: per-agent task latency
- Azure Monitor Workbook "Alex Overview" with tiles for Container Apps requests/latency, OpenAI usage, PostgreSQL CPU/connections, Service Bus queue depth
- Front Door WAF policy (Microsoft_DefaultRuleSet + rate limiting)
- Availability test against the `alex-api` `/health` endpoint
- Azure AI Content Safety resource + key in Key Vault (for application-layer moderation if wanted)

## 2. LangFuse

Same as the other tracks. Sign up, then set env:
```
LANGFUSE_PUBLIC_KEY=...
LANGFUSE_SECRET_KEY=...
LANGFUSE_HOST=https://us.cloud.langfuse.com
```
Terraform propagates these to every Function and Container App.

## 3. Safety and guardrails

Azure OpenAI has content filters on by default (Microsoft Default RAI). Requests flagged with `content_filter` finish reason are surfaced to the agent; our guardrails layer in `backend/<agent>/guardrails.py` decides whether to retry, fail, or return a safe fallback. The same guardrails code works across all three cloud tracks.

Optionally, Azure AI Content Safety (provisioned here) gives you a dedicated moderation API if you want to pre-screen user input or post-screen agent output beyond the built-in filter.

## 4. Explainability

Per-job trace written to PostgreSQL (same schema across tracks): agent sequence, step I/O, token counts, cost, and LangFuse trace URL. Surfaced in frontend at `/jobs/<id>/trace`.

## 5. Scalability knobs

- Container Apps: `min_replicas=1` on the API to eliminate cold starts (~$15/month per CPU)
- Azure OpenAI: raise TPM per deployment, or switch to `GlobalStandard` SKU for higher limits
- PostgreSQL: scale tier, add read replica (Flexible Server supports up to 5)
- Service Bus: Standard tier if you need topics/subscriptions; Premium for VNet + higher throughput

## Common issues

- **Alerts never fire** — Action Group email not confirmed (check inbox for a Microsoft verification mail).
- **Workbook blank** — give it 5–10 minutes after first traffic; metrics index asynchronously.
- **WAF false positives** — Front Door WAF managed rules can block legitimate Clerk/MI traffic. Start in `Detection` mode, review logs, switch to `Prevention` once clean.
- **Content filter rejecting valid output** — log the `finish_reason`; if it's `content_filter`, evaluate whether to relax filters (only in dev) or re-prompt.

## Teardown

```bash
for D in 8_enterprise_azure 7_frontend_azure 6_agents_azure 5_database_azure 4_researcher_azure 3_ingestion_azure 2_openai_azure; do
  (cd terraform/$D && terraform destroy -auto-approve)
done
```

Biggest cost savings: destroying `3_ingestion_azure` (AI Search) and `5_database_azure` (PostgreSQL). Stopping rather than destroying is faster to resume.
