# Guide 1 (GCP) — Permissions and Project Setup

This is the GCP/Vertex AI parallel to `1_permissions.md`. Complete this before any other GCP guide.

## Architectural overview

Alex on GCP is a serverless multi-agent system. Everything scales to zero except the vector index endpoint and Cloud SQL (which you stop between sessions).

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                  Next.js Frontend (Clerk)                │
                    │   Cloud Storage + Cloud CDN  ──or──  Vercel / external   │
                    └────────────────────────┬─────────────────────────────────┘
                                             │ HTTPS + Clerk JWT
                                             ▼
                              ┌──────────────────────────────┐
                              │   alex-api (Cloud Run svc)   │   FastAPI, Clerk JWT verify
                              └────────┬─────────────────────┘
                                       │ publishes agent jobs
                                       ▼
                              ┌──────────────────────────────┐
                              │   Pub/Sub: alex-agent-jobs   │  (+ DLQ)
                              └────────┬─────────────────────┘
                                       │ push subscription
                                       ▼
                   ┌───────────────────────────────────────────────────┐
                   │  Planner (Cloud Run fn) orchestrates:             │
                   │    Tagger │ Reporter │ Charter │ Retirement       │
                   │  each = Cloud Run fn, own service account         │
                   └──────────┬────────────┬───────────────┬───────────┘
                              │            │               │
                ┌─────────────▼──┐  ┌──────▼────────┐  ┌──▼────────────────┐
                │ Vertex AI      │  │ Vertex Vector │  │ Cloud SQL (PG 16) │
                │ Gemini 2.5 Pro │  │ Search index  │  │  via Auth Proxy / │
                │ Embeddings 005 │  │  (768-dim)    │  │  /cloudsql socket │
                └────────────────┘  └───────────────┘  └───────────────────┘
                                            ▲
                                            │ ingest docs
                                ┌───────────┴────────────┐
                                │  alex-ingest (Cloud    │
                                │  Run fn) behind        │
                                │  API Gateway + key     │
                                └────────────────────────┘

 Researcher (separate long-running path, not part of request flow):
   Cloud Scheduler (optional) → Cloud Run service "alex-researcher"
     → Gemini via LiteLLM → posts docs to alex-ingest
```

**Per-guide what-gets-built:**

| Guide | Creates | Monthly cost when idle |
|---|---|---|
| 1 (this) | GCP project, APIs enabled, Terraform SA, WIF for GitHub | $0 |
| 2 | Nothing durable (embedding model is managed) | $0 |
| 3 | GCS buckets, Vertex Vector Search index + **deployed endpoint**, ingest function, API Gateway, API-key secret | ~$75/mo while endpoint deployed — undeploy between sessions |
| 4 | Artifact Registry, Cloud Run service `alex-researcher`, optional Scheduler | $0 (scale-to-zero) |
| 5 | **Cloud SQL PostgreSQL 16**, databases, Key Vault for creds | ~$10/mo running; $0 stopped |
| 6 | 5 Cloud Run functions (Planner/Tagger/Reporter/Charter/Retirement), Pub/Sub topic + DLQ | $0 (per-invocation) |
| 7 | `alex-api` Cloud Run service, optional GCS+CDN frontend + load balancer | ~$0–5 (LB has a floor if used) |
| 8 | Monitoring dashboard, alert policies, uptime check, log-based metric | $0 |

**Shared-across-all-agents:**
- Each function/service runs under its **own dedicated SA** — no shared superuser identity. Roles are least-privilege (`aiplatform.user`, `cloudsql.client`, `secretmanager.secretAccessor`, `pubsub.publisher`).
- Agents authenticate to Vertex AI and Cloud SQL via **Application Default Credentials on the attached SA** — no service-account keys, no secrets in code.
- LiteLLM addresses Gemini as `vertex_ai/gemini-2.5-pro`; ADC handles auth.
- CI auth is **Workload Identity Federation** (step 5 below), not JSON keys.

**Data flow in one sentence:** a signed-in user calls `alex-api`, which validates the Clerk JWT and drops a job on Pub/Sub; the Planner pulls it, fans out to the other agents (each calling Gemini + Cloud SQL + Vector Search as needed), writes results back to Cloud SQL, and the frontend polls for completion.

## 1. Create a GCP project

In the [Cloud Console](https://console.cloud.google.com/):
1. Create a new project, e.g. `alex-ai-prod`. Note the **Project ID** (not the name) — you will use this everywhere.
2. Link a billing account. Set a budget alert (Billing → Budgets & alerts) at e.g. $50/month — Alex is cheap but Cloud SQL is the biggest line item.

## 2. Install and configure the gcloud CLI

```bash
# macOS
brew install --cask google-cloud-sdk
# Windows / Linux: https://cloud.google.com/sdk/docs/install

gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>
gcloud config set compute/region us-central1     # pick one, stick with it
gcloud auth application-default login             # ADC for local Python/LiteLLM
```

Verify:
```bash
gcloud config list
gcloud auth list
```

## 3. Enable required APIs

Run once per project:
```bash
gcloud services enable \
  aiplatform.googleapis.com \
  run.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  pubsub.googleapis.com \
  cloudscheduler.googleapis.com \
  apigateway.googleapis.com \
  servicecontrol.googleapis.com \
  servicemanagement.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  storage.googleapis.com \
  compute.googleapis.com
```

## 4. Create a Terraform service account

Terraform runs under a dedicated service account so permissions are scoped and auditable.

```bash
PROJECT_ID=$(gcloud config get-value project)
gcloud iam service-accounts create alex-terraform \
  --display-name="Alex Terraform"

SA="alex-terraform@${PROJECT_ID}.iam.gserviceaccount.com"

# Roles required across all guides. In a real org you'd scope these tighter.
for ROLE in \
  roles/aiplatform.admin \
  roles/run.admin \
  roles/cloudfunctions.admin \
  roles/artifactregistry.admin \
  roles/cloudsql.admin \
  roles/secretmanager.admin \
  roles/pubsub.admin \
  roles/cloudscheduler.admin \
  roles/apigateway.admin \
  roles/storage.admin \
  roles/iam.serviceAccountUser \
  roles/iam.serviceAccountAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/monitoring.admin \
  roles/logging.admin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA" --role="$ROLE" --condition=None
done
```

For local dev you can simply run Terraform as your own user via ADC.

## 5. GitHub Actions auth via Workload Identity Federation (keyless)

**Do not generate service-account JSON keys for CI.** They're long-lived credentials that leak through logs, env dumps, and stale repo secrets. Google's recommended pattern is **Workload Identity Federation (WIF)** — GitHub mints a short-lived OIDC token, GCP exchanges it for a 1-hour access token scoped to the SA. No secret to rotate, no key to leak.

Set it up once per repo:

```bash
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
SA="alex-terraform@${PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_REPO="<owner>/<repo>"   # e.g. chrys/alex

# 1. Create a Workload Identity Pool
gcloud iam workload-identity-pools create github-pool \
  --location=global \
  --display-name="GitHub Actions"

# 2. Create an OIDC provider inside the pool for GitHub
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor" \
  --attribute-condition="assertion.repository == '${GITHUB_REPO}'"

# 3. Let the GitHub repo impersonate the Terraform SA
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_REPO}"

# 4. Print the provider resource name — you'll paste this into GitHub
echo "WIF_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
echo "WIF_SERVICE_ACCOUNT=${SA}"
```

The `attribute-condition` is the security boundary — without it, **any** GitHub repo could mint tokens for your SA. Always constrain by `assertion.repository` (and optionally `assertion.ref` to limit to `main`, or `assertion.environment` if you use GitHub Environments).

**Tighten further for production**: also require the token to come from a protected branch or a specific environment:

```
--attribute-condition="assertion.repository == '${GITHUB_REPO}' && assertion.ref == 'refs/heads/main'"
```

### GitHub repo configuration

Add these as **repository variables** (not secrets — they're not sensitive):
- `GCP_WIF_PROVIDER` = the `projects/.../providers/github-provider` string above
- `GCP_SERVICE_ACCOUNT` = `alex-terraform@<project>.iam.gserviceaccount.com`
- `GCP_PROJECT_ID` = your project id

### Workflow skeleton (`.github/workflows/deploy.yml`)

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write   # required for OIDC — without this, auth fails

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

      - uses: google-github-actions/setup-gcloud@v2

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform apply (per guide)
        working-directory: terraform/3_ingestion_gcp
        run: |
          terraform init
          terraform apply -auto-approve \
            -var="project_id=${{ vars.GCP_PROJECT_ID }}"
```

### Destroy workflow (`.github/workflows/destroy.yml`)

Gate destroy behind `workflow_dispatch` and a GitHub Environment with required reviewers — a destroy job firing on a bad push is how course projects become expensive lessons.

```yaml
on:
  workflow_dispatch:
    inputs:
      guide:
        description: "Terraform directory to destroy (e.g. 3_ingestion_gcp)"
        required: true

permissions:
  contents: read
  id-token: write

jobs:
  destroy:
    runs-on: ubuntu-latest
    environment: destroy   # configure in repo Settings → Environments with required reviewers
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}
      - uses: hashicorp/setup-terraform@v3
      - working-directory: terraform/${{ inputs.guide }}
        run: terraform init && terraform destroy -auto-approve -var="project_id=${{ vars.GCP_PROJECT_ID }}"
```

### Remote Terraform state

Each terraform directory defaults to **local state**. This breaks as soon as CI runs against the same infra — your GitHub Actions runner won't see state created locally, and vice versa. If you plan to use CI, switch to a GCS backend once:

```bash
gsutil mb -l us-central1 gs://${PROJECT_ID}-alex-tfstate
gsutil versioning set on gs://${PROJECT_ID}-alex-tfstate
gcloud storage buckets add-iam-policy-binding gs://${PROJECT_ID}-alex-tfstate \
  --member="serviceAccount:${SA}" --role=roles/storage.objectAdmin
```

Then add to each `terraform/<N>_gcp/main.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "YOUR_PROJECT_ID-alex-tfstate"
    prefix = "3_ingestion"   # unique per directory
  }
}
```

Run `terraform init -migrate-state` once to move existing local state into GCS. After that, local dev and CI share the same state.

## 6. Vertex AI model access (managed, no access request)

Unlike Bedrock, Vertex AI does not require per-model access requests — enabling the API grants access to Gemini and embedding models in your project. Do verify:

```bash
gcloud ai models list --region=us-central1
```

Default model for Alex: **`gemini-2.5-pro`** (reasoning) and **`gemini-2.5-flash`** (fast path). Default embedding model: **`text-embedding-005`** (768-dim).

## 7. Populate `.env`

Create `/.env` at repo root if it doesn't exist, and add:

```
CLOUD_PROVIDER=gcp
GOOGLE_CLOUD_PROJECT=<your-project-id>
GOOGLE_CLOUD_REGION=us-central1
VERTEX_MODEL_ID=gemini-2.5-pro
VERTEX_EMBEDDING_MODEL=text-embedding-005
```

LiteLLM reads Google credentials from Application Default Credentials automatically — no `AWS_REGION_NAME` equivalent required. However you will pass `vertex_project` and `vertex_location` via env vars into Cloud Run / Cloud Functions in later guides.

## Common issues

- **`PERMISSION_DENIED: ... has not been used in project ...`** — You skipped `gcloud services enable`. Enable the API named in the error.
- **`quota project not set`** — Re-run `gcloud auth application-default login` and then `gcloud auth application-default set-quota-project <PROJECT_ID>`.
- **Terraform 403 on a specific resource** — The Terraform SA is missing a role; add it with `add-iam-policy-binding`.

Proceed to `2_vertexai.md`.
