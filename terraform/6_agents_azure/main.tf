terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group
}

data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
}

# --- Storage for function packages ---------------------------------------
resource "azurerm_storage_account" "pkg" {
  name                     = "alexfnpkg${local.suffix}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "pkg" {
  name                  = "functions"
  storage_account_name  = azurerm_storage_account.pkg.name
  container_access_type = "private"
}

# --- Service Bus ---------------------------------------------------------
resource "azurerm_servicebus_namespace" "sb" {
  name                = "alex-sb-${local.suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard"
}

resource "azurerm_servicebus_queue" "jobs" {
  name                        = "alex-agent-jobs"
  namespace_id                = azurerm_servicebus_namespace.sb.id
  max_delivery_count          = 5
  dead_lettering_on_message_expiration = true
  lock_duration               = "PT5M"
}

# --- App Service Plan (shared Consumption) -------------------------------
resource "azurerm_service_plan" "fn" {
  name                = "alex-agents-plan-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_application_insights" "shared" {
  count               = var.shared_app_insights ? 1 : 0
  name                = "alex-agents-ai-${local.suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  application_type    = "web"
}

# --- Per-agent MI ---------------------------------------------------------
resource "azurerm_user_assigned_identity" "agent" {
  for_each            = toset(var.agents)
  name                = "alex-${each.key}-mi"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "agent_kv" {
  for_each             = toset(var.agents)
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agent[each.key].principal_id
}

resource "azurerm_role_assignment" "agent_sb_sender" {
  for_each             = toset(var.agents)
  scope                = azurerm_servicebus_namespace.sb.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.agent[each.key].principal_id
}

resource "azurerm_role_assignment" "agent_sb_receiver" {
  for_each             = toset(var.agents)
  scope                = azurerm_servicebus_namespace.sb.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.agent[each.key].principal_id
}

resource "azurerm_role_assignment" "agent_openai" {
  for_each             = toset(var.agents)
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}"
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.agent[each.key].principal_id
}

# --- Function apps -------------------------------------------------------
resource "azurerm_linux_function_app" "agent" {
  for_each                   = toset(var.agents)
  name                       = "alex-${each.key}-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = var.location
  service_plan_id            = azurerm_service_plan.fn.id
  storage_account_name       = azurerm_storage_account.pkg.name
  storage_account_access_key = azurerm_storage_account.pkg.primary_access_key

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent[each.key].id]
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
    application_insights_connection_string = var.shared_app_insights ? azurerm_application_insights.shared[0].connection_string : null
  }

  app_settings = {
    CLOUD_PROVIDER                    = "azure"
    AZURE_API_BASE                    = var.azure_openai_endpoint
    AZURE_API_KEY                     = "@Microsoft.KeyVault(SecretUri=${var.db_secret_uri})" # placeholder; real secret below
    AZURE_API_VERSION                 = "2024-08-01-preview"
    AZURE_OPENAI_DEPLOYMENT           = var.azure_openai_deployment
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT = var.azure_openai_embedding_deployment
    MODEL_ID                          = "azure/${var.azure_openai_deployment}"
    POSTGRES_HOST                     = var.postgres_host
    DB_SECRET_URI                     = var.db_secret_uri
    AZURE_SEARCH_ENDPOINT             = var.azure_search_endpoint
    AZURE_SEARCH_INDEX                = var.azure_search_index
    AZURE_SEARCH_KEY                  = var.azure_search_key
    POLYGON_API_KEY                   = var.polygon_api_key
    POLYGON_PLAN                      = var.polygon_plan
    SERVICEBUS_NAMESPACE              = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
    SERVICEBUS_QUEUE                  = azurerm_servicebus_queue.jobs.name
    AzureWebJobsServiceBus__fullyQualifiedNamespace = "${azurerm_servicebus_namespace.sb.name}.servicebus.windows.net"
    LANGFUSE_PUBLIC_KEY               = var.langfuse_public_key
    LANGFUSE_SECRET_KEY               = var.langfuse_secret_key
    LANGFUSE_HOST                     = var.langfuse_host
    OPENAI_API_KEY                    = var.openai_api_key
  }
}
