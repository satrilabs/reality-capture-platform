#!/usr/bin/env bash
# Runs the platform policies against a Terraform plan in JSON form.
#   scripts/policy-check.sh <plan.json> <human|ai-agent>
# Exit 0: allowed (warnings may still need a second approver). Exit 1: blocked.
set -euo pipefail

plan="$(realpath "${1:?usage: policy-check.sh <plan.json> <human|ai-agent>}")"
author="${2:?author type: human or ai-agent}"
case "$author" in human | ai-agent) ;; *)
	echo "author type must be human or ai-agent" >&2
	exit 2
	;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
opa="${OPA:-opa}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
context="$workdir/context.json"
printf '{"change":{"author_type":"%s"}}' "$author" >"$context"

# The context is loaded by a relative name: OPA reads "C:\..." as a
# "prefix:path" pair, which would misplace it on Windows.
query() {
	(cd "$workdir" && "$opa" eval --format=raw --input "$plan" --data "$root/policy/terraform" --data context.json "$1")
}

denies="$(query 'concat("\n", sort(data.terraform.platform.deny))')"
warns="$(query 'concat("\n", sort(data.terraform.platform.warn))')"

echo "Policy check for a change by: $author"
if [ -n "$warns" ]; then
	echo
	echo "Warnings:"
	echo "$warns" | sed 's/^/  - /'
fi
if [ -n "$denies" ]; then
	echo
	echo "Blocked:"
	echo "$denies" | sed 's/^/  - /'
	exit 1
fi
echo
echo "Allowed."
