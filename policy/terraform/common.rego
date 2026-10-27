# Shared helpers for every rule that reads a Terraform plan
# (the JSON from `terraform show -json plan.tfplan`).
package terraform.platform

# A resource the plan will create or change.
writes(rc) if {
	some action in rc.change.actions
	action in {"create", "update"}
}

# A resource the plan will delete, including a replace (delete + create).
deletes(rc) if "delete" in rc.change.actions

# A resource's tags, or an empty object when it has none.
tags_of(after) := after.tags if is_object(after.tags)

else := {}

# Who wrote the change. The pipeline passes this in as data.change,
# from the pull request: branches under ai/ or PRs opened by an agent identity.
ai_change if data.change.author_type == "ai-agent"

# Resources that hold customer data or state. Losing one loses data.
stateful_types := {
	"azurerm_storage_account",
	"azurerm_storage_container",
	"azurerm_postgresql_flexible_server",
	"azurerm_cosmosdb_account",
	"azurerm_key_vault",
	"azurerm_servicebus_namespace",
	"azurerm_kubernetes_cluster",
}

# One answer for the pipeline: allowed or not, and why.
decision := {
	"allow": count(deny) == 0,
	"deny": deny,
	"warn": warn,
}
