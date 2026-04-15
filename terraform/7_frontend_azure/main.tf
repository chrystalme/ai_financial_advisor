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

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
  image  = var.api_container_image != "" ? var.api_container_image : "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
}

# --- API managed identity ------------------------------------------------
resource "azurerm_user_assigned_identity" "api" {
  name                = "alex-api-mi"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "api_kv" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

resource "azurerm_role_assignment" "api_acr" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

resource "azurerm_role_assignment" "api_sb" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.ServiceBus/namespaces/${var.servicebus_namespace}"
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

resource "azurerm_role_assignment" "api_openai" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}"
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}

# --- Container App: alex-api ---------------------------------------------
resource "azurerm_container_app" "api" {
  name                         = "alex-api"
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = data.azurerm_resource_group.rg.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api.id]
  }

  registry {
    server   = split("/", var.acr_id)[length(split("/", var.acr_id)) - 1]
    identity = azurerm_user_assigned_identity.api.id
  }

  template {
    min_replicas = 0
    max_replicas = 10

    container {
      name   = "api"
      image  = local.image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "CLOUD_PROVIDER"
        value = "azure"
      }
      env {
        name  = "CLERK_JWKS_URL"
        value = var.clerk_jwks_url
      }
      env {
        name  = "CLERK_ISSUER"
        value = var.clerk_issuer
      }
      env {
        name  = "POSTGRES_HOST"
        value = var.postgres_host
      }
      env {
        name  = "DB_SECRET_URI"
        value = var.db_secret_uri
      }
      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = "${var.servicebus_namespace}.servicebus.windows.net"
      }
      env {
        name  = "SERVICEBUS_QUEUE"
        value = var.servicebus_queue
      }
      env {
        name  = "AZURE_API_BASE"
        value = var.azure_openai_endpoint
      }
      env {
        name  = "AZURE_OPENAI_DEPLOYMENT"
        value = var.azure_openai_deployment
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# --- Static Web App (default) -------------------------------------------
resource "azurerm_static_web_app" "frontend" {
  count               = var.frontend_host == "swa" ? 1 : 0
  name                = "alex-frontend-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  sku_tier            = "Standard"
  sku_size            = "Standard"
}

# --- Storage + Front Door (alternative) ---------------------------------
resource "azurerm_storage_account" "frontend" {
  count                     = var.frontend_host == "storage" ? 1 : 0
  name                      = "alexfe${local.suffix}"
  resource_group_name       = data.azurerm_resource_group.rg.name
  location                  = var.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  static_website {
    index_document     = "index.html"
    error_404_document = "404.html"
  }
}

resource "azurerm_cdn_frontdoor_profile" "fd" {
  count               = var.frontend_host == "storage" ? 1 : 0
  name                = "alex-fd-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  sku_name            = "Standard_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_endpoint" "fd" {
  count                    = var.frontend_host == "storage" ? 1 : 0
  name                     = "alex-fd-ep-${local.suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd[0].id
}
