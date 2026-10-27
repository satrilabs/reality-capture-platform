#!/usr/bin/env bash
# Assembles the live demo into _site/: the page, the policies compiled to
# WebAssembly, the example plans and the OPA browser library.
#   scripts/build-site.sh [output-dir]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/_site}"
opa="${OPA:-opa}"
opa_wasm_version="1.10.0"

rm -rf "$out"
mkdir -p "$out/plans" "$out/vendor"
cp "$root"/site/* "$out/"
cp "$root"/examples/plans/*.json "$out/plans/"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$opa" build --target wasm --entrypoint terraform/platform/decision \
	--ignore '*_test.rego' --output "$work/bundle.tar.gz" "$root/policy/terraform"
tar -xzf "$work/bundle.tar.gz" -C "$work" /policy.wasm
cp "$work/policy.wasm" "$out/policy.wasm"

(cd "$work" && npm pack --silent "@open-policy-agent/opa-wasm@$opa_wasm_version" >/dev/null && tar -xzf open-policy-agent-opa-wasm-*.tgz)
cp "$work/package/dist/opa-wasm-browser.esm.js" "$out/vendor/"
cp "$work/package/LICENSE" "$out/vendor/opa-wasm-LICENSE"

echo "Site built in $out"
