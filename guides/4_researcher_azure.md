# Guide 4 (Azure) — Researcher Agent on Container Apps

Azure parallel to `4_researcher.md`.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| App Runner | Cloud Run | Azure Container Apps (scale-to-zero, HTTP ingress) |
| ECR | Artifact Registry | Azure Container Registry (ACR) |
| Bedrock Nova Pro | Vertex Gemini 2.5 Pro | Azure OpenAI GPT-4o (`azure/gpt-4o`) |
| EventBridge (optional) | Cloud Scheduler (optional) | Logic Apps / Container Apps Jobs with cron (optional) |

Container Apps is the cleanest fit for long-running agent containers. Azure Functions would also work but has harder limits on container shape and Playwright dependencies.

## 1. Terraform

```bash
cd terraform/4_researcher_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location,
#       alex_api_endpoint, alex_api_key (from guide 3),
#       azure_openai_endpoint, azure_openai_key (from guide 2)
terraform init && terraform apply
```

Creates:
- ACR `alex<suffix>` (names must be globally unique)
- Log Analytics workspace + Container Apps Environment
- User-assigned managed identity for the researcher
- Container App `alex-researcher` (0–3 replicas, HTTP ingress, 2 CPU / 4 GiB)
- ACR Pull role assignment on the MI
- Cognitive Services User role on the MI (for managed-identity auth to Azure OpenAI if you prefer over key)
- Container Apps Job `alex-researcher-cron` (disabled by default)

## 2. Build and push

```bash
RG=alex-rg
ACR=$(az acr list -g $RG --query "[0].name" -o tsv)
az acr login -n $ACR

cd backend/researcher
docker build --platform linux/amd64 -t $ACR.azurecr.io/researcher:latest .
docker push $ACR.azurecr.io/researcher:latest

az containerapp update \
  --name alex-researcher \
  --resource-group $RG \
  --image $ACR.azurecr.io/researcher:latest
```

## 3. Runtime configuration

Terraform sets the following env on the Container App:
```
CLOUD_PROVIDER=azure
AZURE_API_BASE=<openai-endpoint>
AZURE_API_KEY=<secret ref>
AZURE_API_VERSION=2024-08-01-preview
AZURE_OPENAI_DEPLOYMENT=gpt-4o
MODEL_ID=azure/gpt-4o
ALEX_API_ENDPOINT=<apim>
ALEX_API_KEY=<secret ref>
```

`AZURE_API_KEY` and `ALEX_API_KEY` are stored as Container Apps secrets and referenced by name.

## 4. Smoke test

```bash
URL=$(az containerapp show -n alex-researcher -g alex-rg --query properties.configuration.ingress.fqdn -o tsv)
curl -X POST "https://$URL/research" \
  -H "Content-Type: application/json" \
  -d '{"topic":"latest AI chip news"}'
```

## 5. (Optional) Scheduled runs

```bash
cd terraform/4_researcher_azure
terraform apply -var="scheduler_enabled=true" -var="schedule_cron=0 */6 * * *"
```

The Container Apps Job uses the same image and runs on the cron expression.

## Common issues

- **Cold starts on first request** — scale-to-zero is on. Set `min_replicas=1` in tfvars if you want it warm.
- **`ImagePullBackOff`** — MI missing `AcrPull` on ACR. Terraform grants it; verify in the ACR IAM blade.
- **Playwright Chromium fails to launch** — build the image on `linux/amd64` (matters on Apple Silicon).
- **Timeout** — Container Apps request timeout defaults to 300s; for longer research, use the Jobs pattern instead of HTTP.

Proceed to `5_database_azure.md`.
