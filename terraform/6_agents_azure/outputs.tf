output "agent_hostnames" {
  value = { for k, f in azurerm_linux_function_app.agent : k => f.default_hostname }
}

output "servicebus_namespace" {
  value = azurerm_servicebus_namespace.sb.name
}

output "jobs_queue" {
  value = azurerm_servicebus_queue.jobs.name
}

output "package_container_url" {
  value = "https://${azurerm_storage_account.pkg.name}.blob.core.windows.net/${azurerm_storage_container.pkg.name}"
}
