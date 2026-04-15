# Guide 2 (GCP) — Vertex AI Embeddings

GCP parallel to `2_sagemaker.md`. Deploys the embedding capability Alex uses for document ingestion and semantic search.

## What this replaces

| SageMaker track                        | Vertex AI track                                                            |
| -------------------------------------- | -------------------------------------------------------------------------- |
| SageMaker Serverless endpoint          | No endpoint to deploy — Vertex hosts `text-embedding-005` as a managed API |
| HuggingFace all-MiniLM-L6-v2 (384-dim) | Google `text-embedding-005` (768-dim, better quality)                      |
| Pay per invocation + cold-start        | Pay per 1k characters, no cold-start                                       |

There is no Terraform to apply for this guide on GCP — the embedding model is a managed endpoint. Instead you verify access and record the values in `.env`.

## 1. Verify access

```bash
gcloud ai models list-publishers --region=$GOOGLE_CLOUD_REGION | grep -i embedding
```

Test a call:

```bash
uv run --with google-cloud-aiplatform python - <<'PY'
from vertexai.language_models import TextEmbeddingModel
import vertexai, os
vertexai.init(project=os.environ["GOOGLE_CLOUD_PROJECT"], location=os.environ["GOOGLE_CLOUD_REGION"])
m = TextEmbeddingModel.from_pretrained("text-embedding-005")
e = m.get_embeddings(["hello alex"])[0]
print("dims:", len(e.values), "first:", e.values[:4])
PY
```

Expect `dims: 768`.

## 2. Configure dimensions downstream

**IMPORTANT:** Vertex embeddings are 768-dimensional while the SageMaker guide used 384. The vector index in Guide 3 must be created with matching dimensions — do not copy the 384 from the AWS guide.

Add to `.env`:

```
EMBEDDING_DIMENSIONS=768
```

## 3. (Optional) Pin a newer model

If Google releases a newer embedding model during the course, you can swap by changing `VERTEX_EMBEDDING_MODEL`. Recreate the vector index (Guide 3) if the dimension changes.

## 4. Terraform

The `terraform/2_vertexai_gcp/` directory exists for symmetry and enables the Vertex AI API explicitly (idempotent), but creates no long-lived resources:

```bash
cd terraform/2_vertexai_gcp
cp terraform.tfvars.example terraform.tfvars   # set project_id, region
terraform init && terraform apply
```

Proceed to `3_ingest_gcp.md`.
