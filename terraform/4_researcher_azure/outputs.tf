output "researcher_fqdn" {
  value = azurerm_container_app.researcher.ingress[0].fqdn
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "managed_identity_id" {
  value = azurerm_user_assigned_identity.researcher.id
}

output "managed_identity_principal_id" {
  value = azurerm_user_assigned_identity.researcher.principal_id
}
