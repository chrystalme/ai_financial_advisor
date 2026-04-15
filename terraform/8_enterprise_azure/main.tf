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

# --- Notifications --------------------------------------------------------
resource "azurerm_monitor_action_group" "email" {
  name                = "alex-alerts"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name          = "alex"

  email_receiver {
    name          = "primary"
    email_address = var.notification_email
  }
}

# --- Container Apps 5xx rate ---------------------------------------------
resource "azurerm_monitor_metric_alert" "api_5xx" {
  name                = "alex-api-5xx"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [var.api_container_app_id]
  description         = "alex-api 5xx responses elevated"
  severity            = 2
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# --- Service Bus backlog --------------------------------------------------
resource "azurerm_monitor_metric_alert" "sb_backlog" {
  name                = "alex-sb-backlog"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [var.servicebus_namespace_id]
  description         = "Service Bus queue backlog > 50"
  severity            = 2
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ActiveMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 50
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# --- PostgreSQL CPU -------------------------------------------------------
resource "azurerm_monitor_metric_alert" "pg_cpu" {
  name                = "alex-pg-cpu"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [var.postgres_server_id]
  description         = "PostgreSQL CPU > 80%"
  severity            = 3
  window_size         = "PT10M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# --- Azure OpenAI errors -------------------------------------------------
resource "azurerm_monitor_metric_alert" "openai_errors" {
  name                = "alex-openai-errors"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [var.openai_account_id]
  description         = "Azure OpenAI client error rate > 5%"
  severity            = 2
  window_size         = "PT5M"
  frequency           = "PT1M"

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "ClientErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# --- Availability test ----------------------------------------------------
resource "azurerm_application_insights" "uptime" {
  name                = "alex-uptime-ai-${random_string.suffix.result}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.rg.name
  application_type    = "web"
}

resource "azurerm_application_insights_standard_web_test" "api" {
  name                    = "alex-api-health"
  resource_group_name     = data.azurerm_resource_group.rg.name
  location                = var.location
  application_insights_id = azurerm_application_insights.uptime.id
  geo_locations           = ["us-tx-sn1-azr", "us-il-ch1-azr", "emea-gb-db3-azr"]
  frequency               = 300

  request {
    url = "https://${var.api_fqdn}/health"
  }

  validation_rules {
    expected_status_code = 200
  }
}

# --- Azure AI Content Safety (optional) ----------------------------------
resource "azurerm_cognitive_account" "content_safety" {
  count                         = var.enable_content_safety ? 1 : 0
  name                          = "alex-safety-${random_string.suffix.result}"
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.rg.name
  kind                          = "ContentSafety"
  sku_name                      = "S0"
  custom_subdomain_name         = "alex-safety-${random_string.suffix.result}"
  public_network_access_enabled = true
}

resource "azurerm_key_vault_secret" "content_safety_key" {
  count        = var.enable_content_safety ? 1 : 0
  name         = "alex-content-safety-key"
  key_vault_id = var.key_vault_id
  value        = azurerm_cognitive_account.content_safety[0].primary_access_key
}

# --- Dashboard (Monitor Workbook) ----------------------------------------
resource "azurerm_application_insights_workbook" "overview" {
  name                = "00000000-0000-0000-0000-00000000a1ex"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  display_name        = "Alex Overview"
  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      { type = 1, content = { json = "# Alex Overview\nRequests, latency, queue depth, DB load, OpenAI usage." } },
      { type = 10, content = { chartId = "container-apps-requests", version = "MetricsItem/2.0", size = 0, chartType = 2 } }
    ]
  })
}
