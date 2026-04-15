output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "openai_resource_name" {
  value = azurerm_cognitive_account.openai.name
}

output "openai_primary_key" {
  value     = azurerm_cognitive_account.openai.primary_access_key
  sensitive = true
}

output "chat_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}

output "embedding_deployment_name" {
  value = azurerm_cognitive_deployment.embedding.name
}

output "embedding_dimensions" {
  value = 1536
}
