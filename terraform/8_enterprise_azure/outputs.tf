output "action_group_id" {
  value = azurerm_monitor_action_group.email.id
}

output "workbook_id" {
  value = azurerm_application_insights_workbook.overview.id
}

output "content_safety_endpoint" {
  value = var.enable_content_safety ? azurerm_cognitive_account.content_safety[0].endpoint : null
}
