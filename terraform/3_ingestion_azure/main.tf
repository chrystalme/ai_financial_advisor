terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
}

# --- Storage --------------------------------------------------------------
resource "azurerm_storage_account" "docs" {
  name                     = "alexdocs${local.suffix}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "docs" {
  name                  = "documents"
  storage_account_name  = azurerm_storage_account.docs.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "functions" {
  name                  = "functions"
  storage_account_name  = azurerm_storage_account.docs.name
  container_access_type = "private"
}

# --- Azure AI Search ------------------------------------------------------
resource "azurerm_search_service" "search" {
  name                = "alex-search-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  sku                 = var.search_sku
  replica_count       = 1
  partition_count     = 1
}

# Index creation is done via the search REST API — Terraform's azurerm provider
# does not yet support vector index schemas. Call uv run scripts/create_search_index.py
# after apply; it reads the output below.

# --- Function app + plan --------------------------------------------------
resource "azurerm_service_plan" "fn" {
  name                = "alex-fnplan-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_application_insights" "ingest" {
  name                = "alex-ingest-ai-${local.suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  application_type    = "web"
}

resource "azurerm_linux_function_app" "ingest" {
  name                       = "alex-ingest-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = var.location
  service_plan_id            = azurerm_service_plan.fn.id
  storage_account_name       = azurerm_storage_account.docs.name
  storage_account_access_key = azurerm_storage_account.docs.primary_access_key

  site_config {
    application_stack {
      python_version = "3.11"
    }
    application_insights_connection_string = azurerm_application_insights.ingest.connection_string
  }

  app_settings = {
    AZURE_API_BASE                  = var.azure_openai_endpoint
    AZURE_API_KEY                   = var.azure_openai_key
    AZURE_API_VERSION               = "2024-08-01-preview"
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT = var.azure_openai_embedding_deployment
    AZURE_SEARCH_ENDPOINT           = "https://${azurerm_search_service.search.name}.search.windows.net"
    AZURE_SEARCH_INDEX              = "alex-docs"
    AZURE_SEARCH_KEY                = azurerm_search_service.search.primary_key
    DOCS_CONTAINER                  = azurerm_storage_container.docs.name
    EMBEDDING_DIMENSIONS            = tostring(var.embedding_dimensions)
  }
}

# --- API Management (Consumption) ----------------------------------------
resource "azurerm_api_management" "apim" {
  name                = "alex-apim-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  publisher_name      = "Alex"
  publisher_email     = "alex@example.com"
  sku_name            = "Consumption_0"
}

resource "azurerm_api_management_api" "ingest" {
  name                = "alex-ingest"
  resource_group_name = data.azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "Alex Ingest"
  path                = ""
  protocols           = ["https"]
  service_url         = "https://${azurerm_linux_function_app.ingest.default_hostname}/api"
  subscription_required = true
}

resource "azurerm_api_management_product" "alex" {
  product_id            = "alex"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = data.azurerm_resource_group.rg.name
  display_name          = "Alex"
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "alex" {
  api_name            = azurerm_api_management_api.ingest.name
  product_id          = azurerm_api_management_product.alex.product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_api_management_subscription" "alex" {
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = data.azurerm_resource_group.rg.name
  product_id          = azurerm_api_management_product.alex.id
  display_name        = "Alex default subscription"
  state               = "active"
}

# --- Key Vault ------------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = "alex-kv-${local.suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  rbac_authorization_enabled = true
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "search_key" {
  name         = "alex-search-admin-key"
  value        = azurerm_search_service.search.primary_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "apim_key" {
  name         = "alex-apim-subscription-key"
  value        = azurerm_api_management_subscription.alex.primary_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.kv_admin]
}
