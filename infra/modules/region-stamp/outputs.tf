output "resource_group_name" {
  value = azurerm_resource_group.stamp.name
}

output "storage_account_id" {
  value = azurerm_storage_account.scans.id
}

output "scan_queue_id" {
  value = azurerm_servicebus_queue.scan_uploaded.id
}

output "processor_identity_client_id" {
  value = azurerm_user_assigned_identity.processor.client_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.stamp.id
}
