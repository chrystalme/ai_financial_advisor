# GCP deploy / destroy workflows

Two `workflow_dispatch` workflows drive the full GCP stack from GitHub:

| Workflow | Purpose |
|---|---|
| `gcp-deploy.yml` | Applies guides 2 → 8 in order (or a single guide via the `target` input). After guide 7 it builds the Next.js static export and syncs it to the GCS bucket created by Terraform. |
| `gcp-destroy.yml` | Runs `terraform destroy` in reverse order (8 → 2). Empties frontend / functions / docs buckets first so the resource can be removed. Requires typing `DESTROY` into the `confirm` input. |

Both use **Workload Identity Federation** — no JSON service account key is stored anywhere.

## One-time setup: Workload Identity Federation

Create the pool, provider, and service account once (replace `<PROJECT_ID>` and `<GITHUB_ORG>/<REPO>`):

```bash
PROJECT_ID=<PROJECT_ID>
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
REPO=<GITHUB_ORG>/<REPO>

gcloud iam workload-identity-pools create github \
  --project=$PROJECT_ID --location=global --display-name="GitHub pool"

gcloud iam workload-identity-pools providers create-oidc github \
  --project=$PROJECT_ID --location=global --workload-identity-pool=github \
  --display-name="GitHub provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'"

gcloud iam service-accounts create alex-ci \
  --project=$PROJECT_ID --display-name="Alex CI"

# Allow the repo to impersonate the SA via WIF
gcloud iam service-accounts add-iam-policy-binding \
  alex-ci@$PROJECT_ID.iam.gserviceaccount.com \
  --project=$PROJECT_ID \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

# Broad roles required to apply/destroy all 7 terraform dirs.
# Tighten for production — this set is what the guides actually exercise.
for ROLE in \
  roles/editor \
  roles/iam.serviceAccountAdmin \
  roles/iam.securityAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/run.admin \
  roles/cloudfunctions.admin \
  roles/cloudsql.admin \
  roles/aiplatform.admin \
  roles/secretmanager.admin \
  roles/pubsub.admin \
  roles/storage.admin \
  roles/artifactregistry.admin \
  roles/cloudscheduler.admin \
  roles/monitoring.admin \
  roles/compute.loadBalancerAdmin \
  roles/compute.networkAdmin
do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:alex-ci@$PROJECT_ID.iam.gserviceaccount.com" \
    --role=$ROLE --condition=None
done
```

The provider resource name (the value for `GCP_WORKLOAD_IDENTITY_PROVIDER`) is:

```
projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/github
```

## Required GitHub secrets

Configure under **Settings → Secrets and variables → Actions**:

| Secret | Used by | Notes |
|---|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | both | Full resource name from the setup above |
| `GCP_SERVICE_ACCOUNT` | both | `alex-ci@<PROJECT_ID>.iam.gserviceaccount.com` |
| `GCP_PROJECT_ID` | both | |
| `OPENAI_API_KEY` | deploy (4, 6) | OpenAI Agents SDK trace export |
| `SERPER_API_KEY` | deploy (4) | Researcher MCP |
| `POLYGON_API_KEY` | deploy (6) | Stock quotes tool |
| `LANGFUSE_PUBLIC_KEY` | deploy (6) | Optional — pass empty string to disable |
| `LANGFUSE_SECRET_KEY` | deploy (6) | Optional |
| `LANGFUSE_HOST` | deploy (6) | e.g. `https://us.cloud.langfuse.com` |
| `CLERK_JWKS_URL` | deploy (7) | API JWT verification |
| `CLERK_ISSUER` | deploy (7) | API JWT verification |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | deploy (7) | Frontend build-time |
| `CLERK_SECRET_KEY` | deploy (7) | Frontend build-time |
| `NOTIFICATION_EMAIL` | deploy (8) | Monitoring alerts |

## How the runs are wired

- Inputs are chained between guides: each step writes the Terraform outputs it depends on to `/tmp/tfout/<N>.json`, and downstream steps read them with `jq`. If a step is skipped (e.g. deploying only guide 6), the next step falls back to `terraform output` against the earlier directory's state (loaded from the shared GCS state bucket).
- Docker image builds for the researcher, API, and agent Cloud Functions happen inside the existing Terraform `null_resource` local-exec blocks. The workflow runs `gcloud auth configure-docker` up front so those `docker push` calls work.
- The `sed -i ''` calls that existed in `6_agents_gcp/main.tf` and `7_frontend_gcp/main.tf` have been changed to `sed -i.bak` + `rm -f *.bak`, which is portable across BSD (macOS local dev) and GNU (Ubuntu CI) sed.
- After guide 7 applies, the workflow builds `frontend/out/` with `NEXT_PUBLIC_API_URL` set to the freshly deployed Cloud Run URL, rsyncs to the bucket, and uploads extensionless HTML copies so Pages Router routes like `/analysis` resolve correctly through Cloud CDN.
- Destroy order is the exact reverse; each step continues on error so a partial failure doesn't block the rest of the teardown.

## What is **not** removed on destroy

- The Terraform state bucket (`alex-ai-prod-alex-tfstate`) — destroying it would orphan all other state.
- Artifact Registry images — kept so a redeploy doesn't have to rebuild from scratch. Delete manually from the console if you truly want them gone.
