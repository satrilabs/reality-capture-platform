# Customer scan data stays in the region the customer signed up in.
# An EU project must never land in a US region, and the other way round.
package terraform.platform

allowed_locations := {
	"eu": {"westeurope", "northeurope", "germanywestcentral"},
	"us": {"eastus", "eastus2", "westus3"},
	"global": {"global"},
}

deny contains msg if {
	some rc in input.resource_changes
	writes(rc)
	raw := object.get(rc.change.after, "location", null)
	is_string(raw)
	location := replace(lower(raw), " ", "")
	location != "global"
	region := object.get(tags_of(rc.change.after), "data-region", "none")
	not location in object.get(allowed_locations, region, set())
	msg := sprintf("%s: location '%s' is not allowed for data-region '%s'", [rc.address, location, region])
}
