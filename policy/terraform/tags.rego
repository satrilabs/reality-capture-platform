# Every resource must say who owns it, who pays for it and which
# data region it belongs to. Without these, cost per customer and
# data residency cannot be reported.
package terraform.platform

required_tags := {"owner", "cost-center", "data-region"}

deny contains msg if {
	some rc in input.resource_changes
	writes(rc)
	startswith(rc.type, "azurerm_")
	"tags" in object.keys(rc.change.after)
	tags := tags_of(rc.change.after)
	present := {key | some key, _ in tags}
	missing := required_tags - present
	count(missing) > 0
	msg := sprintf("%s: missing required tags %v", [rc.address, sort(missing)])
}
