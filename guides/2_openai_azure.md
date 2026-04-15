# Guide 2 (Azure) — Azure OpenAI for LLM and Embeddings

Azure parallel to `2_sagemaker.md` / `2_vertexai.md`. Provisions the Azure OpenAI resource and model deployments Alex uses throughout.

## What this replaces

| AWS | GCP | Azure |
|---|---|---|
| SageMaker Serverless | Vertex AI managed API | Azure OpenAI resource + per-model "deployments" |
| all-MiniLM-L6-v2 (384) | text-embedding-005 (768) | text-embedding-3-small (1536) |
| (LLM in guide 4) | (LLM in guide 4) | GPT-4o, also provisioned here for reuse |

**Important Azure concept:** in Azure OpenAI, you don't just call a model — you call a **deployment** of a model. The deployment has a name (e.g. `gpt-4o`), a model it maps to (e.g. `gpt-4o` version `2024-08-06`), a SKU (`Standard` or `GlobalStandard`), and capacity (TPM). LiteLLM addresses it as `azure/<deployment_name>`.

## 1. Terraform

```bash
cd terraform/2_openai_azure
cp terraform.tfvars.example terraform.tfvars
# edit: subscription_id, resource_group, location
terraform init && terraform apply
terraform output
```

Creates:
- Cognitive Services account of kind `OpenAI` (SKU `S0`)
- GPT-4o deployment (SKU `GlobalStandard`, capacity 50)
- `text-embedding-3-small` deployment (SKU `Standard`, capacity 120)
- Keys output for downstream guides

Record outputs into `.env`:
```
AZURE_API_BASE=https://<resource-name>.openai.azure.com/
AZURE_API_KEY=<key-from-output>
AZURE_OPENAI_DEPLOYMENT=gpt-4o
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
EMBEDDING_DIMENSIONS=1536
```

## 2. Smoke test

```bash
uv run --with openai python - <<'PY'
import os
from openai import AzureOpenAI
c = AzureOpenAI(
    api_key=os.environ["AZURE_API_KEY"],
    azure_endpoint=os.environ["AZURE_API_BASE"],
    api_version=os.environ.get("AZURE_API_VERSION","2024-08-01-preview"),
)
e = c.embeddings.create(model=os.environ["AZURE_OPENAI_EMBEDDING_DEPLOYMENT"], input=["hello alex"])
print("dims:", len(e.data[0].embedding))
r = c.chat.completions.create(model=os.environ["AZURE_OPENAI_DEPLOYMENT"],
    messages=[{"role":"user","content":"one sentence hello"}])
print(r.choices[0].message.content)
PY
```
Expect `dims: 1536` and a greeting.

## 3. LiteLLM configuration

In `backend/*/agent.py`, LiteLLM uses the Azure route when `CLOUD_PROVIDER=azure`:

```python
model = LitellmModel(
    model=f"azure/{os.environ['AZURE_OPENAI_DEPLOYMENT']}",
    api_base=os.environ["AZURE_API_BASE"],
    api_key=os.environ["AZURE_API_KEY"],
    api_version=os.environ["AZURE_API_VERSION"],
)
```

Unlike Bedrock, Azure OpenAI supports **Structured Outputs AND tool calling in the same Agent** — the LiteLLM limitation noted in CLAUDE.md doesn't apply to Azure. You can use either pattern per the existing code.

## 4. Capacity planning

TPM (tokens per minute) quotas are per-deployment. Defaults are usually fine for course work. If you hit `429`s, bump capacity:

```bash
az cognitiveservices account deployment update \
  --resource-group alex-rg \
  --name <resource-name> \
  --deployment-name gpt-4o \
  --sku-capacity 100
```

## Common issues

- **`DeploymentNotFound`** — the deployment name in env doesn't match what Terraform created. Check `az cognitiveservices account deployment list`.
- **`401 PermissionDenied`** — wrong key (there are two; either works) or wrong endpoint format. Endpoint must end with `/`.
- **`model not found`** — model name vs deployment name confusion. LiteLLM needs the **deployment** name, not the model name.
- **GPT-4o not available in your region** — switch location to `eastus` or `swedencentral`.

Proceed to `3_ingest_azure.md`.
