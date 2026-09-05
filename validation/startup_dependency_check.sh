#!/usr/bin/env bash

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD="$CHECK_ROOT/.build/startup-dependency-check"
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

mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"

if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CHECK_CACHE}"

grep -Fq '@State private var showStartupDependencyCheck = true' \
    "$CHECK_ROOT/Sources/Qnet/QnetGUIApp.swift" \
    || { echo "startup dependency sheet is not enabled at launch" >&2; exit 1; }
grep -Fq 'StartupDependencyCheckView(' "$CHECK_ROOT/Sources/Qnet/QnetGUIApp.swift" \
    || { echo "startup dependency view is not wired into the app" >&2; exit 1; }
grep -Fq 'DS.Symbol.success' "$CHECK_ROOT/Sources/Qnet/StartupDependencyCheckView.swift" \
    || { echo "available dependencies do not retain a green-check symbol" >&2; exit 1; }

swiftc \
    -parse-as-library \
    "$CHECK_ROOT/Sources/Qnet/SolverRuntimeResolver.swift" \
    "$CHECK_ROOT/Sources/Qnet/StartupDependencyChecker.swift" \
    "$CHECK_ROOT/validation/startup_dependency_check/main.swift" \
    -o "$CHECK_BUILD/startup_dependency_check"

"$CHECK_BUILD/startup_dependency_check"
