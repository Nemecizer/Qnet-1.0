#!/usr/bin/env bash

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD="$CHECK_ROOT/.build/product-form-exporter-check"
# The Clang/SwiftPM module cache deliberately lives OUTSIDE the project tree.
# This project is normally checked out inside a Dropbox CloudStorage provider,
# which exposes the same directory at two paths; a cache written under one path
# and read back under the other yields a swift-frontend SIGSEGV reading a
# Foundation module "built against SDK ''". That failure is intermittent and
# looks exactly like a code defect, which teaches people to re-run until green
# -- and re-running until green is how a real awk parse error survived four
# rounds of review. Keyed by project path so parallel checkouts stay separate,
# and still overridable from the environment.
CHECK_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/qnet-module-cache-$(printf '%s' "$CHECK_ROOT" | shasum -a 256 | cut -c1-12)}"
CHECK_JSON="$CHECK_BUILD/open_bcmp.json"
CHECK_DISJOINT_JSON="$CHECK_BUILD/disjoint_open_bcmp.json"
CHECK_RESULT="$CHECK_BUILD/result.json"

mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CHECK_CACHE}"

swiftc \
    -parse-as-library \
    "$CHECK_ROOT/validation/product_form_exporter/stubs.swift" \
    "$CHECK_ROOT/Sources/Qnet/ProductFormExporter.swift" \
    "$CHECK_ROOT/validation/product_form_exporter/main.swift" \
    -o "$CHECK_BUILD/product_form_exporter_check"

"$CHECK_BUILD/product_form_exporter_check" "$CHECK_JSON" "$CHECK_DISJOINT_JSON"
for model in "$CHECK_JSON" "$CHECK_DISJOINT_JSON"; do
    python3 "$CHECK_ROOT/infinite/BNApf/solver.py" \
        "$model" --json > "$CHECK_RESULT"
    python3 -c '
import json, math, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
assert result["model_type"] == "open_bcmp"
assert result["solver"]["probability_mass"] == 1.0
assert len(result["measures"]["stations"]) == 2
assert all(math.isfinite(item["mean_number"]) for item in result["measures"]["stations"])
assert result["solver"]["maximum_traffic_equation_residual"] < 1e-12
' "$CHECK_RESULT"
done
echo "ProductFormExporter solver-contract check passed."
