#!/usr/bin/env bash
# Build-and-run contract for the RQNA path exposed by the GUI.

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BINARY="$CHECK_ROOT/infinite/BNArqna/bna_rqna"
CHECK_BUILD="$CHECK_ROOT/.build/rqna-exporter-check"
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
CHECK_HARNESS="$CHECK_BUILD/rqna_exporter_check"
CHECK_EXAMPLE="$CHECK_ROOT/input/examples/3d3ctandem.inf.bnet"
CHECK_INPUT="$(mktemp "${TMPDIR:-/tmp}/qnet-rqna-input.XXXXXX")"
CHECK_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/qnet-rqna-output.XXXXXX")"
CHECK_ERROR="$(mktemp "${TMPDIR:-/tmp}/qnet-rqna-error.XXXXXX")"
trap 'rm -f "$CHECK_INPUT" "$CHECK_OUTPUT" "$CHECK_ERROR"' EXIT

fail() {
    printf 'RQNA integration check failed: %s\n' "$*" >&2
    if [[ -s "$CHECK_ERROR" ]]; then
        sed 's/^/  /' "$CHECK_ERROR" >&2
    fi
    exit 1
}

# The packager and the independent release inventory must both name RQNA.
# Checking both closes the exact gap that let an app ship without this binary.
grep -Fqx '    "infinite/BNArqna:bna_rqna"' "$CHECK_ROOT/build_app.sh" \
    || fail "build_app.sh does not require infinite/BNArqna:bna_rqna"
grep -Fqx 'infinite/BNArqna/bna_rqna' \
    "$CHECK_ROOT/validation/required_release_executables.txt" \
    || fail "the release audit inventory does not require RQNA"

make -C "$CHECK_ROOT/infinite/BNArqna" bna_rqna >/dev/null \
    || fail "the native executable did not build"
"$CHECK_BINARY" --selftest >"$CHECK_OUTPUT" 2>"$CHECK_ERROR" \
    || fail "the native self-test failed"
grep -Fq 'PASS: all tests passed' "$CHECK_OUTPUT" \
    || fail "the native self-test did not report success"

# Compile the production exporter against minimal model stubs, load a real
# three-class GUI document, and pass its complete extended .qna output to the
# native parser.  This covers the boundary that a hand-written legacy fixture
# would miss (tau/alpha/mu/cs/lambda_ext/P_ex/ca0).
mkdir -p "$CHECK_BUILD" "$CHECK_CACHE"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CHECK_CACHE}"
swiftc \
    -parse-as-library \
    "$CHECK_ROOT/validation/rqna_exporter/stubs.swift" \
    "$CHECK_ROOT/Sources/Qnet/QNAExporter.swift" \
    "$CHECK_ROOT/validation/rqna_exporter/main.swift" \
    -o "$CHECK_HARNESS" \
    || fail "the QNAExporter contract harness did not compile"
"$CHECK_HARNESS" "$CHECK_EXAMPLE" "$CHECK_INPUT" >/dev/null \
    || fail "QNAExporter did not produce the RQNA input"

: > "$CHECK_ERROR"
"$CHECK_BINARY" "$CHECK_INPUT" -c >"$CHECK_OUTPUT" 2>"$CHECK_ERROR" \
    || fail "compact analysis did not run"

grep -Fqx 'RQNA (BNArqna)' "$CHECK_OUTPUT" \
    || fail "compact output omitted the RQNA banner"
for metric in 'rho_' 'Gamma_' 'sojourn_' 'E[Q_'; do
    metric_count="$(grep -F -c "$metric" "$CHECK_OUTPUT")"
    [[ "$metric_count" -eq 3 ]] \
        || fail "compact output contains $metric_count $metric rows instead of 3"
done

printf 'RQNA build, self-test, GUI export, compact run, and release contracts passed.\n'
