# Guide 3 (GCP) — Ingestion Pipeline with Vertex AI Vector Search

GCP parallel to `3_ingest.md`. Builds the document-ingestion Cloud Function backed by Vertex AI Vector Search.

## What this replaces

| AWS | GCP |
|---|---|
| S3 Vectors bucket + index | Vertex AI Vector Search index + index endpoint |
| Lambda ingest function | Cloud Run function (2nd gen) |
| API Gateway with API key | API Gateway with API key |
| 384-dim embeddings | 768-dim embeddings (`text-embedding-005`) |

Vertex AI Vector Search is not as cheap as S3 Vectors — an index endpoint charges roughly $0.10/hr when deployed. For course/dev work, plan to deploy when working and **undeploy** the index endpoint between sessions (keep the index itself — redeploy is fast).

## 1. Terraform

```bash
cd terraform/3_ingestion_gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, region, embedding_dimensions (768)
terraform init && terraform apply
terraform output
```

This creates:
- GCS bucket for document storage and index staging
- Vertex AI Matching Engine index (`STREAM_UPDATE`, 768-dim, cosine distance)
- Index endpoint (public, no VPC for simplicity)
- Deployed index on the endpoint
- Cloud Run function `alex-ingest` using the shared `backend/ingest` code
- API Gateway in front of the function with an API key
- Secret Manager entry for the API key

Record the outputs (API endpoint URL, API key, index ID, endpoint ID) into `.env`:

```
ALEX_API_ENDPOINT=https://...
ALEX_API_KEY=...
VECTOR_INDEX_ID=...
VECTOR_INDEX_ENDPOINT_ID=...
DEPLOYED_INDEX_ID=alex_docs_v1
```

## 2. Test ingestion

```bash
curl -X POST "$ALEX_API_ENDPOINT/ingest" \
  -H "x-api-key: $ALEX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"document_id":"test-1","text":"Alex is an AI financial planner.","metadata":{"source":"smoke"}}'
```

Then search:
```bash
curl -X POST "$ALEX_API_ENDPOINT/search" \
  -H "x-api-key: $ALEX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"financial planning agent","top_k":3}'
```

## 3. Cost control

Between work sessions:
```bash
cd terraform/3_ingestion_gcp
terraform apply -var="index_deployed=false"   # undeploys endpoint, keeps index
```
Or simply `terraform destroy` and re-apply — index rebuild is fast for small corpora.

## Common issues

- **`INVALID_ARGUMENT: dimensions mismatch`** — Your embeddings don't match `embedding_dimensions` in tfvars. Must be 768 for `text-embedding-005`.
- **Slow first-query latency** — The deployed index takes ~10 min to become queryable after apply. Check `gcloud ai index-endpoints describe`.
- **403 on API Gateway** — Pass the API key in `x-api-key` header (not a query param).

Proceed to `4_researcher_gcp.md`.
