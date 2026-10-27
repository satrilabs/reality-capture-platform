package terraform.platform_test

import data.terraform.platform

good_tags := {"owner": "team-scans", "cost-center": "cc-4711", "data-region": "eu"}

plan(changes) := {"resource_changes": changes}

change(type, actions, after) := {
	"address": sprintf("%s.this", [type]),
	"mode": "managed",
	"type": type,
	"change": {"actions": actions, "after": after},
}

good_storage := {
	"location": "westeurope",
	"public_network_access_enabled": false,
	"allow_nested_items_to_be_public": false,
	"shared_access_key_enabled": false,
	"min_tls_version": "TLS1_2",
	"account_replication_type": "ZRS",
	"tags": good_tags,
}

human := {"change": {"author_type": "human"}}

agent := {"change": {"author_type": "ai-agent"}}

test_compliant_plan_is_allowed if {
	result := platform.decision with input as plan([change("azurerm_storage_account", ["create"], good_storage)])
		with data.change as human.change
	result.allow
	count(result.warn) == 0
}

test_missing_tags_are_denied if {
	after := object.union(object.remove(good_storage, ["tags"]), {"tags": {"owner": "team-scans"}})
	denies := platform.deny with input as plan([change("azurerm_storage_account", ["create"], after)])
	some msg in denies
	contains(msg, "missing required tags")
	contains(msg, "cost-center")
}

test_null_tags_are_denied if {
	after := object.union(object.remove(good_storage, ["tags"]), {"tags": null})
	denies := platform.deny with input as plan([change("azurerm_storage_account", ["create"], after)])
	some msg in denies
	contains(msg, "missing required tags")
}

test_public_storage_is_denied if {
	after := object.union(good_storage, {"public_network_access_enabled": true})
	denies := platform.deny with input as plan([change("azurerm_storage_account", ["create"], after)])
	some msg in denies
	contains(msg, "public_network_access_enabled")
}

test_eu_data_in_us_region_is_denied if {
	after := object.union(good_storage, {"location": "East US"})
	denies := platform.deny with input as plan([change("azurerm_storage_account", ["create"], after)])
	some msg in denies
	contains(msg, "location 'eastus' is not allowed for data-region 'eu'")
}

test_us_data_in_us_region_is_allowed if {
	after := object.union(good_storage, {"location": "eastus2", "tags": object.union(good_tags, {"data-region": "us"})})
	denies := platform.deny with input as plan([change("azurerm_storage_account", ["create"], after)])
	count(denies) == 0
}

test_global_resource_in_approved_region_is_allowed if {
	after := {"location": "westeurope", "tags": object.union(good_tags, {"data-region": "global"})}
	denies := platform.deny with input as plan([change("azurerm_resource_group", ["create"], after)])
	count(denies) == 0
}

test_unknown_data_region_is_denied if {
	after := {"location": "westeurope", "tags": object.union(good_tags, {"data-region": "apac"})}
	denies := platform.deny with input as plan([change("azurerm_resource_group", ["create"], after)])
	some msg in denies
	contains(msg, "not allowed for data-region 'apac'")
}

owner_grant := change("azurerm_role_assignment", ["create"], {"role_definition_name": "Owner", "principal_id": "abc"})

test_agent_cannot_grant_owner if {
	denies := platform.deny with input as plan([owner_grant]) with data.change as agent.change
	some msg in denies
	contains(msg, "cannot grant 'Owner'")
}

test_agent_can_grant_narrow_role if {
	grant := change("azurerm_role_assignment", ["create"], {"role_definition_name": "Storage Blob Data Reader"})
	denies := platform.deny with input as plan([grant]) with data.change as agent.change
	count(denies) == 0
}

test_human_owner_grant_is_not_blocked_by_ai_rules if {
	denies := platform.deny with input as plan([owner_grant]) with data.change as human.change
	count(denies) == 0
}

test_agent_cannot_replace_storage if {
	replace := change("azurerm_storage_account", ["delete", "create"], good_storage)
	denies := platform.deny with input as plan([replace]) with data.change as agent.change
	some msg in denies
	contains(msg, "cannot delete or replace stateful resources")
}

test_human_delete_of_storage_needs_second_approver if {
	delete := change("azurerm_storage_account", ["delete"], null)
	result := platform.decision with input as plan([delete]) with data.change as human.change
	result.allow
	some msg in result.warn
	contains(msg, "second approver")
}

test_agent_cannot_touch_policy_assignments if {
	assignment := change("azurerm_subscription_policy_assignment", ["delete"], null)
	denies := platform.deny with input as plan([assignment]) with data.change as agent.change
	some msg in denies
	contains(msg, "cannot touch policies or audit logging")
}

test_agent_plan_too_large_is_denied if {
	grants := [change("azurerm_role_assignment", ["create"], {"role_definition_name": "Reader"}) | some _ in numbers.range(1, 26)]
	denies := platform.deny with input as plan(grants) with data.change as agent.change
	some msg in denies
	contains(msg, "plan changes 26 resources")
}

build_pool := {
	"priority": "Spot",
	"auto_scaling_enabled": true,
	"min_count": 0,
	"max_count": 20,
	"tags": object.union(good_tags, {"workload": "build-agents"}),
}

test_spot_build_pool_is_allowed if {
	denies := platform.deny with input as plan([change("azurerm_kubernetes_cluster_node_pool", ["create"], build_pool)])
	count(denies) == 0
}

test_always_on_build_pool_is_denied if {
	pool := object.union(build_pool, {"priority": "Regular", "min_count": 2})
	denies := platform.deny with input as plan([change("azurerm_kubernetes_cluster_node_pool", ["create"], pool)])
	some msg in denies
	contains(msg, "Spot VMs, autoscale and scale to zero")
}

test_geo_redundant_storage_without_reason_warns if {
	after := object.union(good_storage, {"account_replication_type": "GZRS"})
	warns := platform.warn with input as plan([change("azurerm_storage_account", ["create"], after)])
	some msg in warns
	contains(msg, "replication-reason")
}
