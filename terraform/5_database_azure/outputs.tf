output "postgres_host" {
  value = azurerm_postgresql_flexible_server.alex.fqdn
}

output "postgres_db" {
  value = azurerm_postgresql_flexible_server_database.alex.name
}

output "postgres_user" {
  value = var.db_admin_user
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "db_secret_name" {
  value = azurerm_key_vault_secret.db.name
}

output "db_secret_uri" {
  value = azurerm_key_vault_secret.db.id
}
