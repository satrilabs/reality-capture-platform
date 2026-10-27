# The only shared, global piece. Front Door gives one entry point with a
# web firewall, and sends each customer to their own region's stamp.
# An EU hostname only ever has EU origins, so a failover can never move
# EU data to the US.

resource "azurerm_cdn_frontdoor_profile" "edge" {
  name                = "afd-rcp-${var.environment}"
  resource_group_name = var.resource_group_name
  sku_name            = "Premium_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "region" {
  for_each                 = var.regions
  name                     = "rcp-${each.key}-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.edge.id
  tags                     = merge(var.tags, { data-region = each.key })
}

resource "azurerm_cdn_frontdoor_origin_group" "region" {
  for_each                 = var.regions
  name                     = "og-${each.key}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.edge.id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/healthz"
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "GET"
  }
}

# Each region lists only its own origins, for example two zones or two
# clusters inside the EU, never an origin from the other region.
resource "azurerm_cdn_frontdoor_origin" "region" {
  for_each = merge([
    for region, cfg in var.regions : {
      for index, host in cfg.origin_hosts : "${region}-${index}" => {
        region = region
        host   = host
      }
    }
  ]...)

  name                           = "origin-${each.key}"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.region[each.value.region].id
  host_name                      = each.value.host
  origin_host_header             = each.value.host
  certificate_name_check_enabled = true
  enabled                        = true
}

resource "azurerm_cdn_frontdoor_route" "region" {
  for_each                      = var.regions
  name                          = "route-${each.key}"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.region[each.key].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.region[each.key].id
  cdn_frontdoor_origin_ids      = [for key, origin in azurerm_cdn_frontdoor_origin.region : origin.id if startswith(key, "${each.key}-")]
  supported_protocols           = ["Https"]
  https_redirect_enabled        = false
  patterns_to_match             = ["/*"]
  forwarding_protocol           = "HttpsOnly"
  link_to_default_domain        = true
}

resource "azurerm_cdn_frontdoor_firewall_policy" "edge" {
  name                = "wafrcp${var.environment}"
  resource_group_name = var.resource_group_name
  sku_name            = azurerm_cdn_frontdoor_profile.edge.sku_name
  mode                = "Prevention"
  tags                = var.tags

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.1"
    action  = "Block"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "edge" {
  name                     = "waf"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.edge.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.edge.id

      association {
        patterns_to_match = ["/*"]

        dynamic "domain" {
          for_each = azurerm_cdn_frontdoor_endpoint.region
          content {
            cdn_frontdoor_domain_id = domain.value.id
          }
        }
      }
    }
  }
}
