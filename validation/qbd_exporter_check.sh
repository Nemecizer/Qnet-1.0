#!/usr/bin/env bash

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD="$CHECK_ROOT/.build/qbd-exporter-check"
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
CHECK_INPUT="$CHECK_BUILD/feedback-mm1.json"
CHECK_RESULT="$CHECK_BUILD/result.json"
CHECK_HUMAN="$CHECK_BUILD/result.txt"

mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CHECK_CACHE}"

swiftc -parse-as-library \
    "$CHECK_ROOT/validation/qbd_exporter/stubs.swift" \
    "$CHECK_ROOT/Sources/Qnet/QBDExporter.swift" \
    "$CHECK_ROOT/validation/qbd_exporter/main.swift" \
    -o "$CHECK_BUILD/qbd_exporter_check"

"$CHECK_BUILD/qbd_exporter_check" "$CHECK_INPUT"
python3 "$CHECK_ROOT/infinite/matrix_analytic/qbd_solver.py" \
    "$CHECK_INPUT" --compact > "$CHECK_RESULT"
python3 -c '
import json, math, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
rho = 1.0 / (4.0 * (1.0 - 0.5))
expected = rho / (1.0 - rho)
assert abs(result["rate_matrix"][0][0] - rho) < 1e-10
assert abs(result["queue_length"]["mean"] - expected) < 1e-9
assert abs(result["queue_length"]["mean"] - 1.0) < 1e-9
assert result["stability"]["classification"] == "positive_recurrent"
' "$CHECK_RESULT"

python3 "$CHECK_ROOT/infinite/matrix_analytic/qbd_solver.py" \
    "$CHECK_INPUT" --human > "$CHECK_HUMAN"
grep -Eq '^QNET_QBD_METRIC_V1 metric=mean_level estimate=' "$CHECK_HUMAN"
grep -Eq '^QNET_QBD_EVIDENCE_V1 key=stability_classification value=positive_recurrent$' "$CHECK_HUMAN"
echo "QBDExporter closed-form and human-output checks passed."
