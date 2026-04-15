terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    http    = { source = "hashicorp/http",    version = "~> 3.4"  }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group
}

data "http" "my_ip" {
  count = var.client_ip == "" ? 1 : 0
  url   = "https://api.ipify.org"
}

resource "random_password" "db" {
  length  = 28
  special = false
  upper   = true
  lower   = true
  numeric = true
}

locals {
  password  = var.db_admin_password != "" ? var.db_admin_password : random_password.db.result
  client_ip = var.client_ip != "" ? var.client_ip : trimspace(data.http.my_ip[0].response_body)
  suffix    = substr(md5(data.azurerm_resource_group.rg.id), 0, 6)
}

resource "azurerm_postgresql_flexible_server" "alex" {
  name                   = "alex-db-${local.suffix}"
  resource_group_name    = data.azurerm_resource_group.rg.name
  location               = var.location
  version                = "16"
  administrator_login    = var.db_admin_user
  administrator_password = local.password
  sku_name               = var.db_sku
  storage_mb             = var.db_storage_mb
  zone                   = "1"

  public_network_access_enabled = true

  authentication {
    password_auth_enabled = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "alex" {
  name      = "alex"
  server_id = azurerm_postgresql_flexible_server.alex.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  count            = var.allow_all_azure_services ? 1 : 0
  name             = "AllowAllAzureServices"
  server_id        = azurerm_postgresql_flexible_server.alex.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "client" {
  name             = "AllowClient"
  server_id        = azurerm_postgresql_flexible_server.alex.id
  start_ip_address = local.client_ip
  end_ip_address   = local.client_ip
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "alex-dbkv-${local.suffix}"
  location                   = var.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db" {
  name         = "alex-db-credentials"
  key_vault_id = azurerm_key_vault.kv.id
  value = jsonencode({
    username = var.db_admin_user
    password = local.password
    database = "alex"
    host     = azurerm_postgresql_flexible_server.alex.fqdn
    port     = 5432
    sslmode  = "require"
  })
  depends_on = [azurerm_role_assignment.kv_admin]
}
