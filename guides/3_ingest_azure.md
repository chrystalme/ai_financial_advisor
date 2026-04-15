# Guide 3 (Azure) — Ingestion Pipeline with Azure AI Search

Azure parallel to `3_ingest.md`.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| S3 Vectors bucket + index | Vertex Vector Search index + endpoint | Azure AI Search service with a vector-enabled index |
| Lambda ingest function | Cloud Run function | Azure Function (Python, Consumption plan) |
| API Gateway with API key | API Gateway with API key | Azure API Management (Consumption tier) with subscription key |
| 384-dim embeddings | 768-dim | 1536-dim (`text-embedding-3-small`) |

**Cost note:** Azure AI Search `basic` SKU is ~$75/month. For course work, use **`free`** tier (50 MB storage, 3 indexes) — sufficient for the seed corpus. Upgrade only if you hit the limit.

## 1. Terraform

```bash
cd terraform/3_ingestion_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location, search_sku (free/basic),
#       azure_openai_endpoint (from guide 2), azure_openai_key, embedding_dimensions (1536)
terraform init && terraform apply
```

Creates:
- Storage account for documents and function source
- Azure AI Search service
- Search index `alex-docs` with HNSW vector field (1536 dims, cosine)
- Azure Function app `alex-ingest` (Linux, Python 3.11, Consumption plan)
- Application Insights for the function
- APIM Consumption instance, product, subscription key
- Key Vault with the search admin key + APIM subscription key

Record outputs:
```
ALEX_API_ENDPOINT=https://<apim-name>.azure-api.net
ALEX_API_KEY=<subscription-key>
AZURE_SEARCH_ENDPOINT=https://<search-name>.search.windows.net
AZURE_SEARCH_INDEX=alex-docs
AZURE_SEARCH_KEY=<from-output>
```

## 2. Test ingestion

```bash
curl -X POST "$ALEX_API_ENDPOINT/ingest" \
  -H "Ocp-Apim-Subscription-Key: $ALEX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"document_id":"test-1","text":"Alex is an AI financial planner.","metadata":{"source":"smoke"}}'
```

APIM uses `Ocp-Apim-Subscription-Key` (not `x-api-key`). The Terraform variable `api_key_header_name` can change this if you want consistency with the other tracks.

Search:
```bash
curl -X POST "$ALEX_API_ENDPOINT/search" \
  -H "Ocp-Apim-Subscription-Key: $ALEX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"financial planning","top_k":3}'
```

## 3. Cost control

Between sessions, stop the Function app (free anyway on Consumption) and the APIM is free on Consumption tier. The only continuous cost is the AI Search service — keep it on `free` until you need more.

## Common issues

- **`SubscriptionKeyNotFound`** — missing header or used the wrong name. APIM default is `Ocp-Apim-Subscription-Key`.
- **`Azure Function: 500, no logs`** — Application Insights not linked, or Python version mismatch. The Terraform pins 3.11.
- **Vector search returns nothing** — index dimensions don't match the embedding model. Must be 1536.
- **Ingest is slow** — `text-embedding-3-small` has a TPM quota; for bulk ingestion, batch embeddings (up to 16 inputs per call).

Proceed to `4_researcher_azure.md`.
