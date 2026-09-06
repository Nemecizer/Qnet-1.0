#!/usr/bin/env bash
# Reproduce the two build paths promised by this standalone source package.

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
VERIFY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$VERIFY_ROOT"

fail() {
    printf '2_Qnet verification failed: %s\n' "$*" >&2
    exit 1
}

[[ -f Package.swift ]] || fail "Package.swift is missing"
[[ -f Vendor/SwiftTerm/LICENSE ]] || fail "vendored SwiftTerm is incomplete"
[[ -f infinite/BNArqna/bna_rqna.c ]] || fail "RQNA source is missing"
[[ -f validation/required_release_executables.txt ]] \
    || fail "release inventory is missing"

if grep -Eq 'https?://.*SwiftTerm|github\.com/.*/SwiftTerm' Package.swift; then
    fail "Package.swift unexpectedly depends on a remote SwiftTerm checkout"
fi

VERIFY_MODULE_CACHE="$VERIFY_ROOT/.build/module-cache"
mkdir -p "$VERIFY_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$VERIFY_MODULE_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$VERIFY_MODULE_CACHE}"
if [[ -z "${SDKROOT:-}" ]] \
    && ! printf 'import Foundation\n' | swiftc -typecheck - >/dev/null 2>&1 \
    && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

printf 'Checking the SwiftPM source-run path...\n'
./build_all_algorithms.sh
SWIFT_RUN_ARGS=(run)
if [[ "${QNET_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_RUN_ARGS+=(--disable-sandbox)
fi
VERIFY_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/qnet-source-verify.XXXXXX")"
trap 'rm -f "$VERIFY_OUTPUT"' EXIT
swift "${SWIFT_RUN_ARGS[@]}" Qnet --version > "$VERIFY_OUTPUT"
grep -Fxq 'Qnet 0.90.34' "$VERIFY_OUTPUT" || fail "source version is not 0.90.34"
swift "${SWIFT_RUN_ARGS[@]}" Qnet --dump-help rqna > "$VERIFY_OUTPUT"
grep -Fq 'RQNA — REFINED QUEUEING NETWORK ANALYZER' \
    "$VERIFY_OUTPUT" \
    || fail "swift run did not execute Qnet"

printf 'Building and auditing Qnet.app...\n'
./build_app.sh

[[ -x Qnet.app/Contents/MacOS/Qnet ]] || fail "Qnet.app executable is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Qnet.app/Contents/Info.plist)" == "0.90.34" ]] \
    || fail "app version is not 0.90.34"
[[ "$(Qnet.app/Contents/MacOS/Qnet --version)" == "Qnet 0.90.34" ]] \
    || fail "app executable version is not 0.90.34"
[[ -f Qnet.app/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal ]] \
    || fail "Qnet.app does not contain the SwiftTerm Metal shader"
[[ -x Qnet.app/Contents/Resources/bin/infinite/BNArqna/bna_rqna ]] \
    || fail "Qnet.app does not contain RQNA"
codesign --verify --deep --strict Qnet.app \
    || fail "Qnet.app signature verification failed"
validation/solver_bundle_audit.sh Qnet.app \
    || fail "Qnet.app solver audit failed"
Qnet.app/Contents/Resources/bin/infinite/BNArqna/bna_rqna --selftest \
    || fail "bundled RQNA self-test failed"
validation/rqna_integration_check.sh \
    || fail "RQNA exporter integration failed"
validation/source_distribution_check.sh \
    || fail "source-run packaged-resource resolution failed"
python3 validation/packaged_rqna_examples.py \
    || fail "packaged RQNA examples failed"

printf '2_Qnet source-run and application-bundle verification passed.\n'
