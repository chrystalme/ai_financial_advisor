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
  image  = var.container_image != "" ? var.container_image : "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
}

resource "azurerm_container_registry" "acr" {
  name                = "alex${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "alex-law-${local.suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "env" {
  name                       = "alex-cae"
  location                   = var.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

resource "azurerm_user_assigned_identity" "researcher" {
  name                = "alex-researcher-mi"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "researcher_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.researcher.principal_id
}

resource "azurerm_role_assignment" "researcher_openai_user" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}"
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.researcher.principal_id
}

resource "azurerm_container_app" "researcher" {
  name                         = "alex-researcher"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = data.azurerm_resource_group.rg.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.researcher.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.researcher.id
  }

  secret {
    name  = "azure-openai-key"
    value = var.azure_openai_key
  }

  secret {
    name  = "alex-api-key"
    value = var.alex_api_key
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "researcher"
      image  = local.image
      cpu    = 2.0
      memory = "4Gi"

      env {
        name  = "CLOUD_PROVIDER"
        value = "azure"
      }
      env {
        name  = "AZURE_API_BASE"
        value = var.azure_openai_endpoint
      }
      env {
        name        = "AZURE_API_KEY"
        secret_name = "azure-openai-key"
      }
      env {
        name  = "AZURE_API_VERSION"
        value = "2024-08-01-preview"
      }
      env {
        name  = "AZURE_OPENAI_DEPLOYMENT"
        value = var.azure_openai_deployment
      }
      env {
        name  = "MODEL_ID"
        value = "azure/${var.azure_openai_deployment}"
      }
      env {
        name  = "ALEX_API_ENDPOINT"
        value = var.alex_api_endpoint
      }
      env {
        name        = "ALEX_API_KEY"
        secret_name = "alex-api-key"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
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

# Optional scheduled job
resource "azurerm_container_app_job" "cron" {
  count                        = var.scheduler_enabled ? 1 : 0
  name                         = "alex-researcher-cron"
  location                     = var.location
  resource_group_name          = data.azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  replica_timeout_in_seconds   = 3600
  replica_retry_limit          = 1

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.researcher.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.researcher.id
  }

  schedule_trigger_config {
    cron_expression          = var.schedule_cron
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "researcher-cron"
      image  = local.image
      cpu    = 1.0
      memory = "2Gi"
    }
  }
}
