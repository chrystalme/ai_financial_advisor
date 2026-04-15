# Guide 6 (Azure) — Agent Orchestra on Azure Functions + Service Bus

Azure parallel to `6_agents.md`.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| 5 Lambda functions | 5 Cloud Run functions | 5 Azure Functions (Python, Consumption plan) |
| SQS | Pub/Sub | Azure Service Bus queue `alex-agent-jobs` + DLQ (built-in) |
| S3 package bucket | GCS source bucket | Storage Account blob container for function zips |
| Bedrock Nova Pro | Vertex Gemini 2.5 Pro | Azure OpenAI GPT-4o (`azure/gpt-4o`) |

Backend Python code is unchanged. The `backend/planner/queue.py` abstraction needs an `azure` branch using `azure-servicebus`.

## 1. Terraform

```bash
cd terraform/6_agents_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location,
#       azure_openai_endpoint, azure_openai_key, azure_openai_deployment,
#       postgres_host, db_secret_uri (Key Vault reference from guide 5),
#       azure_search_endpoint, azure_search_key, azure_search_index,
#       polygon_api_key
terraform init && terraform apply
```

Creates:
- Storage account + blob container `functions`
- App Service Plan (Consumption, Linux)
- 5 Function apps: `alex-planner`, `alex-tagger`, `alex-reporter`, `alex-charter`, `alex-retirement`
- Application Insights per app (or shared — controlled by `shared_app_insights`)
- Service Bus namespace + queue `alex-agent-jobs` (max delivery 5 → DLQ)
- User-assigned managed identity per agent
- Role assignments:
  - `Key Vault Secrets User` on the DB secret
  - `Azure Service Bus Data Sender/Receiver` on the namespace
  - `Cognitive Services OpenAI User` on the Azure OpenAI resource

## 2. Package and deploy

```bash
uv run scripts/package_azure.py            # zips each backend/<agent> and uploads to blob
cd terraform/6_agents_azure && terraform apply   # re-apply picks up new package URLs
```

Or deploy directly with `func` CLI:
```bash
cd backend/planner
func azure functionapp publish alex-planner --python
```

## 3. Orchestration flow

```
User Request → APIM → Planner (HTTP-triggered Function)
                          ├─ sends messages to Service Bus queue
                          │    → Tagger (Service Bus-triggered Function)
                          │    → Reporter
                          │    → Charter
                          │    → Retirement
                          └─ aggregates results → PostgreSQL
```

Service Bus has native DLQ — after `max_delivery_count=5`, messages move to the `$DeadLetterQueue`. Inspect with:
```bash
az servicebus queue show -g alex-rg --namespace-name alex-sb -n alex-agent-jobs --query "countDetails.deadLetterMessageCount"
```

## 4. Test locally

```bash
cd backend/planner
MOCK_LAMBDAS=true CLOUD_PROVIDER=azure uv run test_simple.py
```

## 5. Test deployed

```bash
cd backend/planner
CLOUD_PROVIDER=azure uv run test_full.py
```

`test_full.py` routes to Service Bus + Function URLs when `CLOUD_PROVIDER=azure`.

## Common issues

- **`ManagedIdentityCredential authentication unavailable`** — MI not attached to the Function app, or role assignment propagation still pending (wait ~60s after apply).
- **`InvalidOperationException: No connection ...`** — Service Bus connection string missing. With MI auth, use `AzureWebJobsServiceBus__fullyQualifiedNamespace=<ns>.servicebus.windows.net` instead of a connection string.
- **`429 TooManyRequests` from Azure OpenAI** — TPM quota exceeded. Bump deployment capacity (Guide 2 step 4) or switch SKU to `GlobalStandard`.
- **`DeploymentNotFound`** — `AZURE_OPENAI_DEPLOYMENT` env doesn't match what was created. `az cognitiveservices account deployment list`.

Proceed to `7_frontend_azure.md`.
