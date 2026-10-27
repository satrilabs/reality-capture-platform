# Extra rules for changes written by an AI coding agent.
# Agents may add and change ordinary resources fast. They may not widen
# access, destroy data, switch off the guardrails or make huge changes.
# Those go to a human.
package terraform.platform

broad_roles := {
	"Owner",
	"Contributor",
	"User Access Administrator",
	"Role Based Access Control Administrator",
}

# Guardrail resources: Azure Policy and the diagnostic settings that feed audit logs.
guardrail_type(type) if startswith(type, "azurerm_policy_")

guardrail_type(type) if endswith(type, "_policy_assignment")

guardrail_type(type) if endswith(type, "_policy_exemption")

guardrail_type("azurerm_monitor_diagnostic_setting")

max_ai_resource_changes := 25

deny contains msg if {
	ai_change
	some rc in input.resource_changes
	writes(rc)
	rc.type == "azurerm_role_assignment"
	role := rc.change.after.role_definition_name
	role in broad_roles
	msg := sprintf("%s: AI-authored changes cannot grant '%s'. Use a narrow role or ask the platform team", [rc.address, role])
}

deny contains msg if {
	ai_change
	some rc in input.resource_changes
	deletes(rc)
	rc.type in stateful_types
	msg := sprintf("%s: AI-authored changes cannot delete or replace stateful resources %v", [rc.address, rc.change.actions])
}

deny contains msg if {
	ai_change
	some rc in input.resource_changes
	rc.change.actions != ["no-op"]
	rc.change.actions != ["read"]
	guardrail_type(rc.type)
	msg := sprintf("%s: AI-authored changes cannot touch policies or audit logging", [rc.address])
}

deny contains msg if {
	ai_change
	changed := [rc |
		some rc in input.resource_changes
		rc.change.actions != ["no-op"]
		rc.change.actions != ["read"]
	]
	count(changed) > max_ai_resource_changes
	msg := sprintf("plan changes %d resources; AI-authored changes are limited to %d, split it up", [count(changed), max_ai_resource_changes])
}

# Humans may delete stateful resources, but the pipeline asks for a second approver.
warn contains msg if {
	not ai_change
	some rc in input.resource_changes
	deletes(rc)
	rc.type in stateful_types
	msg := sprintf("%s: deletes a stateful resource, needs a second approver", [rc.address])
}
