# Scan data is customer data, and for public safety customers it is
# court evidence. Storage is private, keyless and encrypted in transit.
package terraform.platform

storage_rules := [
	{
		"attr": "public_network_access_enabled",
		"want": false,
		"why": "reach scan data only through Front Door and private endpoints",
	},
	{
		"attr": "allow_nested_items_to_be_public",
		"want": false,
		"why": "no anonymous blob access",
	},
	{
		"attr": "shared_access_key_enabled",
		"want": false,
		"why": "Entra ID only, no account keys that can leak",
	},
	{
		"attr": "min_tls_version",
		"want": "TLS1_2",
		"why": "no old TLS",
	},
]

deny contains msg if {
	some rc in input.resource_changes
	writes(rc)
	rc.type == "azurerm_storage_account"
	some rule in storage_rules
	object.get(rc.change.after, rule.attr, null) != rule.want
	msg := sprintf("%s: %s must be %v (%s)", [rc.address, rule.attr, rule.want, rule.why])
}
