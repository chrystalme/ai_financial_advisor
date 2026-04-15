output "api_fqdn" {
  value = azurerm_container_app.api.ingress[0].fqdn
}

output "swa_default_hostname" {
  value = var.frontend_host == "swa" ? azurerm_static_web_app.frontend[0].default_host_name : null
}

output "swa_deployment_token" {
  value     = var.frontend_host == "swa" ? azurerm_static_web_app.frontend[0].api_key : null
  sensitive = true
}

output "storage_static_website_url" {
  value = var.frontend_host == "storage" ? azurerm_storage_account.frontend[0].primary_web_endpoint : null
}

output "frontdoor_endpoint_hostname" {
  value = var.frontend_host == "storage" ? azurerm_cdn_frontdoor_endpoint.fd[0].host_name : null
}
