# Cost rules that pay for themselves at scale.
package terraform.platform

# Build agents run only while a job runs, on Spot capacity.
deny contains msg if {
	some rc in input.resource_changes
	writes(rc)
	rc.type == "azurerm_kubernetes_cluster_node_pool"
	object.get(tags_of(rc.change.after), "workload", "") == "build-agents"
	not cheap_build_pool(rc.change.after)
	msg := sprintf("%s: build agent pools must use Spot VMs, autoscale and scale to zero", [rc.address])
}

cheap_build_pool(pool) if {
	pool.priority == "Spot"
	pool.auto_scaling_enabled == true
	pool.min_count == 0
}

# Scan data is written once and read less every month. Geo-redundant
# replication doubles the storage bill, so it needs a reason on record.
warn contains msg if {
	some rc in input.resource_changes
	writes(rc)
	rc.type == "azurerm_storage_account"
	rc.change.after.account_replication_type in {"GRS", "RAGRS", "GZRS", "RAGZRS"}
	not "replication-reason" in object.keys(tags_of(rc.change.after))
	msg := sprintf("%s: geo-redundant storage doubles cost; add a replication-reason tag", [rc.address])
}
