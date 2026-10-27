output "agent_identity_client_id" {
  description = "Put this on the build-agent service account (azure.workload.identity/client-id)."
  value       = azurerm_user_assigned_identity.agents.client_id
}

output "node_pool_id" {
  value = azurerm_kubernetes_cluster_node_pool.agents.id
}
