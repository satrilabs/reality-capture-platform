# One region stamp: everything a region needs to take scan uploads,
# queue them for processing and keep the data in that region.
# EU and US customers each get their own stamp; nothing is shared but the edge.

locals {
  name = "rcp-${var.data_region}-${var.environment}"
  tags = merge(var.tags, {
    data-region = var.data_region
    environment = var.environment
  })
}

resource "azurerm_resource_group" "stamp" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "stamp" {
  name                = "vnet-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.stamp.name
  address_space       = [var.address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.stamp.name
  virtual_network_name = azurerm_virtual_network.stamp.name
  address_prefixes     = [cidrsubnet(var.address_space, 4, 0)]
}

# Only traffic from inside the VNet reaches the private endpoints.
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${local.name}-private-endpoints"
  location            = var.location
  resource_group_name = azurerm_resource_group.stamp.name
  tags                = local.tags

  security_rule {
    name                       = "allow-vnet-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# Without this zone the storage name would still resolve to its public
# address, and private access would silently fail.
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.stamp.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "link-${local.name}"
  resource_group_name   = azurerm_resource_group.stamp.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.stamp.id
  tags                  = local.tags
}

# Scan data. Private, keyless, zone-redundant: survives the loss of a
# datacentre. Geo-redundancy doubles the bill for data that is rarely read
# again, so it is opted into per tier (the policy asks for a reason).
# Azure's region pairs stay inside the EU and inside the US, so residency
# holds either way; versioning and soft delete cover mistakes.
resource "azurerm_storage_account" "scans" {
  #checkov:skip=CKV_AZURE_206:ZRS by default; geo-redundancy doubles storage cost and is opted into per tier with a replication-reason tag
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys by default; customer-managed keys are an option per tier, not a baseline
  #checkov:skip=CKV_AZURE_33:the queue service of this account is not used; uploads are queued in Service Bus
  name                            = substr(replace("st${local.name}scans", "-", ""), 0, 24)
  location                        = var.location
  resource_group_name             = azurerm_resource_group.stamp.name
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled       = true
    last_access_time_enabled = true # the tiering rules below need it

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = merge(local.tags, { workload = "scan-data" })
}

resource "azurerm_storage_container" "raw" {
  #checkov:skip=CKV2_AZURE_21:reads, writes and deletes are logged by the blob-audit diagnostic setting on the blob service
  name                  = "raw-scans"
  storage_account_id    = azurerm_storage_account.scans.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "processed" {
  #checkov:skip=CKV2_AZURE_21:reads, writes and deletes are logged by the blob-audit diagnostic setting on the blob service
  name                  = "processed"
  storage_account_id    = azurerm_storage_account.scans.id
  container_access_type = "private"
}

# Scans are hot while a project is active, then rarely opened. Moving
# them down the tiers is the biggest storage cost lever (docs/cost.md).
# Archive is not offered on zone-redundant accounts, so cold is the last
# tier here; a reopened project moves back to hot on first read.
resource "azurerm_storage_management_policy" "scans" {
  storage_account_id = azurerm_storage_account.scans.id

  rule {
    name    = "tier-down-scans"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["raw-scans/", "processed/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than = var.cool_after_days
        tier_to_cold_after_days_since_last_access_time_greater_than = var.cold_after_days
        auto_tier_to_hot_from_cool_enabled                          = true
      }

      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

resource "azurerm_private_endpoint" "scans_blob" {
  name                = "pe-${local.name}-blob"
  location            = var.location
  resource_group_name = azurerm_resource_group.stamp.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.scans.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

# Every read, write and delete of scan data is logged: who opened which
# customer's scans is an audit question (and court evidence for public safety).
resource "azurerm_monitor_diagnostic_setting" "scans_blob" {
  name                       = "blob-audit"
  target_resource_id         = "${azurerm_storage_account.scans.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.stamp.id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }
}

# Every finished upload becomes a message on a queue. Processing workers
# scale on queue length, so a burst of uploads never drops work.
# Standard tier has no private endpoints, so keys are switched off and only
# Entra identities can connect. Premium with a private endpoint when volume pays for it.
resource "azurerm_servicebus_namespace" "stamp" {
  #checkov:skip=CKV_AZURE_204:Standard tier has no private endpoints; keys are off, so only Entra identities can connect
  #checkov:skip=CKV_AZURE_201:customer-managed keys need the Premium tier
  #checkov:skip=CKV_AZURE_199:double encryption needs the Premium tier
  name                          = "sb-${local.name}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.stamp.name
  sku                           = "Standard"
  local_auth_enabled            = false
  public_network_access_enabled = true
  minimum_tls_version           = "1.2"
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_servicebus_queue" "scan_uploaded" {
  name                                 = "scan-uploaded"
  namespace_id                         = azurerm_servicebus_namespace.stamp.id
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
  lock_duration                        = "PT5M"
}

resource "azurerm_eventgrid_system_topic" "scans" {
  name                   = "egst-${local.name}-scans"
  location               = var.location
  resource_group_name    = azurerm_resource_group.stamp.name
  source_arm_resource_id = azurerm_storage_account.scans.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
  tags                   = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "eventgrid_to_queue" {
  scope                = azurerm_servicebus_queue.scan_uploaded.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.scans.identity[0].principal_id
}

resource "azurerm_eventgrid_system_topic_event_subscription" "scan_uploaded" {
  name                = "scan-uploaded"
  system_topic        = azurerm_eventgrid_system_topic.scans.name
  resource_group_name = azurerm_resource_group.stamp.name

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/raw-scans/"
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  service_bus_queue_endpoint_id = azurerm_servicebus_queue.scan_uploaded.id

  depends_on = [azurerm_role_assignment.eventgrid_to_queue]
}

# The processor's identity: read raw scans, write processed output,
# take messages off the queue. Nothing else.
resource "azurerm_user_assigned_identity" "processor" {
  name                = "id-${local.name}-processor"
  location            = var.location
  resource_group_name = azurerm_resource_group.stamp.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "processor_blob" {
  scope                = azurerm_storage_account.scans.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.processor.principal_id
}

resource "azurerm_role_assignment" "processor_queue" {
  scope                = azurerm_servicebus_queue.scan_uploaded.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.processor.principal_id
}

resource "azurerm_log_analytics_workspace" "stamp" {
  name                = "log-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.stamp.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = local.tags
}
