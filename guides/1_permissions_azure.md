# Guide 1 (Azure) — Permissions and Subscription Setup

Azure parallel to `1_permissions.md`. Complete before any other Azure guide.

## Architectural overview

Alex on Azure is a serverless multi-agent system. Most services scale to zero; PostgreSQL and AI Search are the only always-on costs, and PostgreSQL can be stopped between sessions.

```
                    ┌──────────────────────────────────────────────────────────┐
                    │               Next.js Frontend (Clerk)                   │
                    │   Azure Static Web Apps  ──or──  Storage + Front Door    │
                    └────────────────────────┬─────────────────────────────────┘
                                             │ HTTPS + Clerk JWT
                                             ▼
                              ┌──────────────────────────────┐
                              │  alex-api (Container App)    │  FastAPI, Clerk JWT verify
                              └────────┬─────────────────────┘
                                       │ publishes agent jobs
                                       ▼
                              ┌──────────────────────────────┐
                              │  Service Bus: alex-agent-jobs│  (+ built-in DLQ)
                              └────────┬─────────────────────┘
                                       │ Functions trigger binding
                                       ▼
                   ┌───────────────────────────────────────────────────┐
                   │  Planner (Azure Function) orchestrates:           │
                   │    Tagger │ Reporter │ Charter │ Retirement       │
                   │  each = Azure Function, own managed identity      │
                   └──────────┬────────────┬───────────────┬───────────┘
                              │            │               │
                ┌─────────────▼──┐  ┌──────▼────────┐  ┌──▼──────────────────────┐
                │ Azure OpenAI   │  │ Azure AI      │  │ Azure DB for Postgres   │
                │ GPT-4o         │  │ Search        │  │ Flexible Server (PG 16) │
                │ embedding-3-s  │  │ (1536-dim)    │  │  via psycopg + TLS      │
                └────────────────┘  └───────────────┘  └─────────────────────────┘
                                            ▲
                                            │ ingest docs
                                ┌───────────┴────────────┐
                                │  alex-ingest (Azure    │
                                │  Function) behind      │
                                │  APIM + subscription   │
                                │  key                   │
                                └────────────────────────┘

 Researcher (separate long-running path, not part of request flow):
   Container Apps Job cron (optional) → Container App "alex-researcher"
     → GPT-4o via LiteLLM → posts docs to alex-ingest
```

**Per-guide what-gets-built:**

| Guide | Creates | Monthly cost when idle |
|---|---|---|
| 1 (this) | Resource group, providers registered, Entra app + OIDC for GitHub | $0 |
| 2 | **Azure OpenAI** resource, GPT-4o deployment, `text-embedding-3-small` deployment | $0 (pay-per-token) |
| 3 | Storage, **Azure AI Search** (`free` tier), ingest Function, APIM Consumption, Key Vault | $0 on free tier |
| 4 | ACR, Log Analytics, Container Apps Environment, `alex-researcher` Container App, optional cron Job | $0 (scale-to-zero + LA minimum) |
| 5 | **PostgreSQL Flexible Server** (B1ms), Key Vault for creds | ~$12/mo running; $0 stopped |
| 6 | 5 Azure Functions (Planner/Tagger/Reporter/Charter/Retirement), **Service Bus** namespace + queue (+ DLQ) | $0 (Consumption plan) |
| 7 | `alex-api` Container App, Static Web App or Storage+Front Door for frontend | ~$0–10 (Front Door has a floor if used) |
| 8 | Monitor alerts, Action Group, App Insights availability test, workbook, optional Content Safety | $0 |

**Shared-across-all-agents:**
- Each Function and Container App runs under its **own user-assigned managed identity** — no shared client secrets. Roles are least-privilege (`Key Vault Secrets User`, `Azure Service Bus Data Sender/Receiver`, `Cognitive Services OpenAI User`, `AcrPull`).
- Agents authenticate to Azure OpenAI and Service Bus via **managed identity** from the attached MI — no keys in app settings for those paths.
- LiteLLM addresses GPT-4o as `azure/<deployment-name>`; the `azurerm` provider feeds the endpoint/version via env.
- CI auth is **Entra OIDC federated credentials** (step 5 below), not client secrets.

**Data flow in one sentence:** a signed-in user calls `alex-api`, which validates the Clerk JWT and enqueues a job on Service Bus; the Planner Function triggers, fans out to the other agents (each calling GPT-4o + PostgreSQL + AI Search as needed), writes results back to PostgreSQL, and the frontend polls for completion.

## 1. Subscription and resource group

In the [Azure Portal](https://portal.azure.com):
1. Confirm you have an **Azure subscription** (Free Trial, Pay-As-You-Go, or MSDN). Note the **Subscription ID**.
2. Set a budget: Cost Management → Budgets → create a $50/month alert. Azure Database for PostgreSQL and Azure AI Search are the biggest line items.

Create a resource group for the project (everything will live here):

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az group create --name alex-rg --location eastus
```

Default region: **`eastus`** — Azure OpenAI model availability is best there and in `swedencentral`. Pick one and stick with it.

## 2. Install the Azure CLI

```bash
# macOS
brew install azure-cli
# Windows: https://learn.microsoft.com/cli/azure/install-azure-cli-windows
# Linux: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az login
az account show
```

## 3. Register required resource providers

Run once per subscription — no-op if already registered:

```bash
for NS in \
  Microsoft.CognitiveServices \
  Microsoft.Search \
  Microsoft.App \
  Microsoft.Web \
  Microsoft.ContainerRegistry \
  Microsoft.ServiceBus \
  Microsoft.DBforPostgreSQL \
  Microsoft.KeyVault \
  Microsoft.Storage \
  Microsoft.Network \
  Microsoft.Insights \
  Microsoft.OperationalInsights \
  Microsoft.ApiManagement \
  Microsoft.Cdn; do
  az provider register --namespace $NS
done
```

## 4. Request Azure OpenAI access

Azure OpenAI is **gated** — unlike Vertex AI:

1. Go to [aka.ms/oai/access](https://aka.ms/oai/access) and submit the access form.
2. Approval is typically 1–3 business days. You need an approved tenant before you can create an Azure OpenAI resource.
3. Once approved, create the resource via Terraform in Guide 2.

While waiting, continue with other setup.

## 5. GitHub Actions auth via OIDC federated credentials (keyless)

**Do not create client secrets (`az ad sp create-for-rbac`) for CI.** Those are long-lived credentials that leak through logs, env dumps, and stale repo secrets. Microsoft's recommended pattern is **OIDC federated credentials** — GitHub mints a short-lived OIDC token, Entra ID exchanges it for a 1-hour access token scoped to the app registration. No client secret to rotate or leak.

For local Terraform you continue running as yourself via `az login`. The following is CI-only.

Set it up once per repo:

```bash
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
RG=alex-rg
GITHUB_REPO="<owner>/<repo>"   # e.g. chrys/alex

# 1. Create an Entra ID app registration + service principal, no secret
APP_ID=$(az ad app create --display-name alex-terraform --query appId -o tsv)
az ad sp create --id $APP_ID >/dev/null
SP_OBJ_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

# 2. Grant roles on the resource group (Contributor + User Access Administrator
#    so Terraform can assign roles to the managed identities it creates)
az role assignment create --assignee-object-id $SP_OBJ_ID \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"

az role assignment create --assignee-object-id $SP_OBJ_ID \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"

# 3. Add a federated credential that trusts your GitHub repo's OIDC token.
#    Each "subject" is a separate federated credential — you typically want
#    one for the main branch (deploy) and one for a GitHub Environment (destroy).
az ad app federated-credential create --id $APP_ID --parameters @- <<JSON
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON

az ad app federated-credential create --id $APP_ID --parameters @- <<JSON
{
  "name": "github-destroy-env",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:environment:destroy",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON

echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$SUB_ID"
```

The **`subject`** field is the security boundary. Entra only issues a token when the incoming OIDC claim matches it exactly. Common subject patterns:

| Trigger | Subject |
|---|---|
| Push to `main` | `repo:<owner>/<repo>:ref:refs/heads/main` |
| Any pull request | `repo:<owner>/<repo>:pull_request` |
| A GitHub Environment | `repo:<owner>/<repo>:environment:<name>` |
| A specific tag | `repo:<owner>/<repo>:ref:refs/tags/<tag>` |

Never use `repo:<owner>/<repo>:*` — that lets any workflow in the repo (including an attacker's fork-PR) impersonate the SP.

### GitHub repo configuration

Add these as **repository variables** (not secrets — none of these are sensitive):
- `AZURE_CLIENT_ID` — the `appId` printed above
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

### Deploy workflow (`.github/workflows/deploy.yml`)

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

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform apply (per guide)
        working-directory: terraform/3_ingestion_azure
        env:
          ARM_USE_OIDC: "true"
          ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
          ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
        run: |
          terraform init
          terraform apply -auto-approve \
            -var="subscription_id=${{ vars.AZURE_SUBSCRIPTION_ID }}"
```

`ARM_USE_OIDC=true` tells the `azurerm` provider to use the GitHub OIDC token directly instead of a client secret. No extra config needed — `azure/login@v2` sets `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and `ACTIONS_ID_TOKEN_REQUEST_URL` which the provider reads.

### Destroy workflow (`.github/workflows/destroy.yml`)

Gate destroy behind `workflow_dispatch` and a GitHub Environment with required reviewers. The federated credential above uses `environment:destroy` as the subject, so only workflows running in that environment can authenticate — a misfiring push can't trigger a destroy.

```yaml
on:
  workflow_dispatch:
    inputs:
      guide:
        description: "Terraform directory to destroy (e.g. 3_ingestion_azure)"
        required: true

permissions:
  contents: read
  id-token: write

jobs:
  destroy:
    runs-on: ubuntu-latest
    environment: destroy   # Repo Settings → Environments → add required reviewers
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
      - working-directory: terraform/${{ inputs.guide }}
        env:
          ARM_USE_OIDC: "true"
          ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
          ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
        run: |
          terraform init
          terraform destroy -auto-approve \
            -var="subscription_id=${{ vars.AZURE_SUBSCRIPTION_ID }}"
```

### Remote Terraform state

Each terraform directory defaults to **local state**. This breaks as soon as CI runs against the same infra — your GitHub Actions runner won't see state created locally, and vice versa. If you plan to use CI, switch to an Azure Storage backend once:

```bash
SUB_ID=$(az account show --query id -o tsv)
RG=alex-rg
SA=alextfstate$(openssl rand -hex 3)    # must be globally unique, lowercase

az storage account create -g $RG -n $SA --sku Standard_LRS --encryption-services blob
az storage container create -n tfstate --account-name $SA --auth-mode login

# Let the Terraform SP read/write state
az role assignment create \
  --assignee-object-id $(az ad sp show --id $AZURE_CLIENT_ID --query id -o tsv) \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -g $RG -n $SA --query id -o tsv)
echo "TFSTATE_STORAGE_ACCOUNT=$SA"
```

Then add to each `terraform/<N>_azure/main.tf`:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "alex-rg"
    storage_account_name = "alextfstateXXXXXX"
    container_name       = "tfstate"
    key                  = "3_ingestion.tfstate"   # unique per directory
    use_oidc             = true
    use_azuread_auth     = true
  }
}
```

Run `terraform init -migrate-state` once to move existing local state to the backend. After that, local dev and CI share the same state.

## 6. Populate `.env`

Add at repo root:

```
CLOUD_PROVIDER=azure
AZURE_SUBSCRIPTION_ID=<subscription-id>
AZURE_RESOURCE_GROUP=alex-rg
AZURE_LOCATION=eastus
AZURE_API_VERSION=2024-08-01-preview
AZURE_OPENAI_DEPLOYMENT=gpt-4o
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
```

`AZURE_API_BASE` and `AZURE_API_KEY` are filled in after Guide 2.

## Common issues

- **`MissingSubscriptionRegistration`** — you forgot `az provider register` for the named namespace. Register it and retry.
- **`The subscription is not registered to use Microsoft.CognitiveServices`** — same root cause, most commonly hits Azure OpenAI.
- **Azure OpenAI creation fails with `Operation returned 403`** — access request not yet approved.
- **Role assignments fail from Terraform** — SP lacks `User Access Administrator`. Add it (see step 5).

Proceed to `2_openai_azure.md`.
