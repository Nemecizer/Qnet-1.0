#!/usr/bin/env bash
# Convenience launcher for a CLT installation with an incompatible default SDK.
set -euo pipefail
RUN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RUN_ROOT"
mkdir -p "$RUN_ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$RUN_ROOT/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$RUN_ROOT/.build/module-cache}"
if [[ -z "${SDKROOT:-}" ]] \
    && ! printf 'import Foundation\n' | swiftc -typecheck - >/dev/null 2>&1 \
    && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
RUN_ARGS=(run)
# Opt-in for a build already enclosed by a managed runner's sandbox.
if [[ "${QNET_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    RUN_ARGS+=(--disable-sandbox)
fi
exec swift "${RUN_ARGS[@]}" Qnet "$@"
