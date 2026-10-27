output "endpoint_hostnames" {
  description = "Data region => public hostname."
  value       = { for region, endpoint in azurerm_cdn_frontdoor_endpoint.region : region => endpoint.host_name }
}
