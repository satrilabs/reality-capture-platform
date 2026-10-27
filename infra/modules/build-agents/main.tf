# A node pool that exists only while pipeline jobs run. KEDA starts one
# agent pod per queued job (see platform/build-agents); the cluster
# autoscaler adds Spot nodes for them and removes the nodes when idle.

resource "azurerm_kubernetes_cluster_node_pool" "agents" {
  name                  = var.name
  kubernetes_cluster_id = var.kubernetes_cluster_id
  vm_size               = var.vm_size
  os_type               = var.os_type
  vnet_subnet_id        = var.subnet_id

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.max_nodes

  # Only agent pods land here, and agent pods land nowhere else.
  node_labels = { "workload" = "build-agents" }
  node_taints = [
    "workload=build-agents:NoSchedule",
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  os_disk_type    = "Ephemeral"
  os_disk_size_gb = var.os_disk_size_gb

  tags = merge(var.tags, { workload = "build-agents" })
}

# The identity agents use to push images and artefacts. Federated to the
# agent service account, so no secret ever sits in the cluster.
resource "azurerm_user_assigned_identity" "agents" {
  name                = "id-${var.name}-agents"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "agents" {
  name                = "build-agents"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.agents.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${var.namespace}:build-agent"
}

resource "azurerm_role_assignment" "agents_acr_push" {
  scope                = var.container_registry_id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.agents.principal_id
}
