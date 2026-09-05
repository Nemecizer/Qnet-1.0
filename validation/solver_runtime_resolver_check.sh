#!/usr/bin/env bash

set -euo pipefail

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD="$CHECK_DIR/.build/solver-runtime-resolver-check"
# Cache outside the tree: see result_output_parser_check.sh for why.
CHECK_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/qnet-module-cache-$(printf '%s' "$CHECK_DIR" | shasum -a 256 | cut -c1-12)}"

mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"

if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CHECK_CACHE}"

grep -Fqx '    "finite/fBNActmc/ctmc_dtandem.py"' "$CHECK_DIR/build_app.sh" \
    || { echo "ctmc_dtandem.py is absent from the bundle support list" >&2; exit 1; }
grep -Fqx '    "finite/fBNActmc/ctmc_dtandem.py:numpy"' "$CHECK_DIR/build_app.sh" \
    || { echo "ctmc_dtandem.py NumPy dependency metadata is absent" >&2; exit 1; }
[[ -f "$CHECK_DIR/finite/fBNActmc/ctmc_dtandem.py" ]] \
    || { echo "ctmc_dtandem.py source is absent" >&2; exit 1; }

swiftc \
    "$CHECK_DIR/Sources/Qnet/SolverRuntimeResolver.swift" \
    "$CHECK_DIR/validation/solver_runtime_resolver/main.swift" \
    -o "$CHECK_BUILD/solver_runtime_resolver_check"

"$CHECK_BUILD/solver_runtime_resolver_check"
