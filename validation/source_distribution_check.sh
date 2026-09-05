#!/usr/bin/env bash
set -euo pipefail
CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD="$CHECK_ROOT/.build/source-distribution-check"
# Cache outside the tree: see result_output_parser_check.sh for why.
CHECK_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/qnet-module-cache-$(printf '%s' "$CHECK_ROOT" | shasum -a 256 | cut -c1-12)}"
mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"
export CLANG_MODULE_CACHE_PATH="$CHECK_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$CHECK_CACHE"
if [[ -z "${SDKROOT:-}" ]] \
    && ! printf 'import Foundation\n' | swiftc -typecheck - >/dev/null 2>&1 \
    && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
swiftc "$CHECK_ROOT/Sources/Qnet/SolverRuntimeResolver.swift" \
    "$CHECK_ROOT/validation/source_distribution/main.swift" \
    -o "$CHECK_BUILD/check"
"$CHECK_BUILD/check" "$CHECK_ROOT"
