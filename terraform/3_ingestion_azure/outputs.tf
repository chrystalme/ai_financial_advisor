output "apim_gateway_url" {
  value = azurerm_api_management.apim.gateway_url
}

output "apim_subscription_key" {
  value     = azurerm_api_management_subscription.alex.primary_key
  sensitive = true
}

output "search_endpoint" {
  value = "https://${azurerm_search_service.search.name}.search.windows.net"
}

output "search_admin_key" {
  value     = azurerm_search_service.search.primary_key
  sensitive = true
}

output "ingest_function_hostname" {
  value = azurerm_linux_function_app.ingest.default_hostname
}

output "docs_container" {
  value = azurerm_storage_container.docs.name
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}
