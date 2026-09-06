#!/usr/bin/env bash
# Convenience launcher for a CLT installation with an incompatible default SDK.
set -euo pipefail
# Physical paths, not the ones the caller happened to type.
#
# A directory reached through a symlink has two spellings, and Clang records the
# spelling it SAW in each module-cache entry. Build once through
# ~/Library/CloudStorage/Dropbox/... and once through ~/Dropbox/... -- the same
# directory, because macOS makes the second a symlink to the first -- and the
# next compile fails with "module '_DarwinFoundation1' is defined in both", then
# the SDK probe below segfaults and reports a compiler/SDK mismatch that does
# not exist. `pwd -P` collapses the two spellings to one so the cache has a
# single name for each module.
RUN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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
