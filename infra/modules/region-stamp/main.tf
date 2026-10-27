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

# Scan data. Private, keyless, zone-redundant inside the region only:
# copying scans to another region would break data residency.
resource "azurerm_storage_account" "scans" {
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
    versioning_enabled = true

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
  name                  = "raw-scans"
  storage_account_id    = azurerm_storage_account.scans.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "processed" {
  name                  = "processed"
  storage_account_id    = azurerm_storage_account.scans.id
  container_access_type = "private"
}

# Scans are hot while a project is active, then rarely opened.
# Moving them down the tiers is the biggest storage cost lever.
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
        tier_to_cool_after_days_since_last_access_time_greater_than    = var.cool_after_days
        tier_to_cold_after_days_since_last_access_time_greater_than    = var.cold_after_days
        tier_to_archive_after_days_since_last_access_time_greater_than = var.archive_after_days
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
}

# Every finished upload becomes a message on a queue. Processing workers
# scale on queue length, so a burst of uploads never drops work.
# Standard tier has no private endpoints, so keys are switched off and only
# Entra identities can connect. Premium with a private endpoint when volume pays for it.
resource "azurerm_servicebus_namespace" "stamp" {
  name                          = "sb-${local.name}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.stamp.name
  sku                           = "Standard"
  local_auth_enabled            = false
  public_network_access_enabled = true
  minimum_tls_version           = "1.2"
  tags                          = local.tags
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
