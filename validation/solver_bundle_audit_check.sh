#!/usr/bin/env bash

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/qnet-bundle-audit.XXXXXX")"
trap 'rm -rf "$CHECK_SCRATCH"' EXIT

CHECK_APP="$CHECK_SCRATCH/Qnet.app"
CHECK_RESOURCES="$CHECK_APP/Contents/Resources"
CHECK_BIN="$CHECK_RESOURCES/bin"
mkdir -p "$CHECK_BIN/infinite/Test" "$CHECK_BIN/finite/Test" "$CHECK_APP/Contents/Frameworks"

printf '#!/bin/sh\nexit 0\n' > "$CHECK_BIN/infinite/Test/good"
chmod +x "$CHECK_BIN/infinite/Test/good"
printf 'print("ok")\n' > "$CHECK_BIN/finite/Test/support.py"

printf '%s\n' \
    'QNET_SOLVER_RUNTIME_V1' \
    $'available\texecutable\tinfinite/Test/good\ttest executable' \
    $'available\tsupport\tfinite/Test/support.py\ttest support' \
    $'unavailable\texecutable\tinfinite/Test/optional\toptional test solver' \
    > "$CHECK_RESOURCES/solver-runtime-status-v1.tsv"

while IFS= read -r required_relative; do
    case "$required_relative" in
        ""|'#'*) continue ;;
    esac
    required_target="$CHECK_BIN/$required_relative"
    mkdir -p "$(dirname "$required_target")"
    printf '#!/bin/sh\nexit 0\n' > "$required_target"
    chmod +x "$required_target"
    printf 'available\texecutable\t%s\trequired GUI fixture\n' "$required_relative" \
        >> "$CHECK_RESOURCES/solver-runtime-status-v1.tsv"
done < "$CHECK_ROOT/validation/required_release_executables.txt"

"$CHECK_ROOT/validation/solver_bundle_audit.sh" "$CHECK_APP" >/dev/null

# A file may exist while the packager silently omits it from the generated
# manifest.  The independent inventory must still reject that release.
cp "$CHECK_RESOURCES/solver-runtime-status-v1.tsv" "$CHECK_SCRATCH/manifest.complete"
awk -F '\t' '$3 != "infinite/BNArqna/bna_rqna"' \
    "$CHECK_SCRATCH/manifest.complete" > "$CHECK_RESOURCES/solver-runtime-status-v1.tsv"
if "$CHECK_ROOT/validation/solver_bundle_audit.sh" "$CHECK_APP" >/dev/null 2>&1; then
    echo "bundle audit accepted a release that did not declare RQNA" >&2
    exit 1
fi
cp "$CHECK_SCRATCH/manifest.complete" "$CHECK_RESOURCES/solver-runtime-status-v1.tsv"

rm "$CHECK_BIN/finite/Test/support.py"
if "$CHECK_ROOT/validation/solver_bundle_audit.sh" "$CHECK_APP" >/dev/null 2>&1; then
    echo "bundle audit accepted a missing declared support file" >&2
    exit 1
fi
printf 'print("ok")\n' > "$CHECK_BIN/finite/Test/support.py"

printf '#!/bin/sh\nexit 0\n' > "$CHECK_BIN/infinite/Test/optional"
chmod +x "$CHECK_BIN/infinite/Test/optional"
if "$CHECK_ROOT/validation/solver_bundle_audit.sh" "$CHECK_APP" >/dev/null 2>&1; then
    echo "bundle audit accepted a stale unavailable solver" >&2
    exit 1
fi
rm "$CHECK_BIN/infinite/Test/optional"

printf '#!/bin/sh\necho "dyld: Library not loaded: libmissing.dylib" >&2\nexit 134\n' \
    > "$CHECK_BIN/infinite/Test/broken"
chmod +x "$CHECK_BIN/infinite/Test/broken"
printf '%s\n' $'available\texecutable\tinfinite/Test/broken\tbroken loader fixture' \
    >> "$CHECK_RESOURCES/solver-runtime-status-v1.tsv"
if "$CHECK_ROOT/validation/solver_bundle_audit.sh" "$CHECK_APP" >/dev/null 2>&1; then
    echo "bundle audit accepted a loader-rejected executable" >&2
    exit 1
fi

echo "Solver bundle audit checks passed."
