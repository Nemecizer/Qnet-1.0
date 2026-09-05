#!/usr/bin/env bash
# Verify that a Qnet.app solver runtime is complete and relocatable.

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 /path/to/Qnet.app" >&2
    exit 2
fi

AUDIT_APP="$1"
AUDIT_CONTENTS="$AUDIT_APP/Contents"
AUDIT_RESOURCES="$AUDIT_CONTENTS/Resources"
AUDIT_BIN="$AUDIT_RESOURCES/bin"
AUDIT_FRAMEWORKS="$AUDIT_CONTENTS/Frameworks"
AUDIT_MANIFEST="$AUDIT_RESOURCES/solver-runtime-status-v1.tsv"
AUDIT_REQUIRED_EXECUTABLES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/required_release_executables.txt"
AUDIT_ERRORS=0

audit_fail() {
    printf 'bundle audit: %s\n' "$*" >&2
    AUDIT_ERRORS=$((AUDIT_ERRORS + 1))
}

probe_executable() {
    local probe_target="$1"
    local probe_relative="$2"
    local probe_stderr
    local probe_pid
    local probe_running=1
    local probe_step
    probe_stderr="$(mktemp "${TMPDIR:-/tmp}/qnet-loader-probe.XXXXXX")"

    "$probe_target" --qnet-loadability-probe </dev/null >/dev/null 2>"$probe_stderr" &
    probe_pid=$!
    for probe_step in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$probe_pid" 2>/dev/null; then
            probe_running=0
            break
        fi
        sleep 0.05
    done
    if [[ "$probe_running" -eq 1 ]]; then
        kill -TERM "$probe_pid" 2>/dev/null || true
        sleep 0.05
        kill -KILL "$probe_pid" 2>/dev/null || true
    fi
    wait "$probe_pid" 2>/dev/null || true

    if grep -Eiq \
        'library not loaded|dyld:|dyld\[|symbol not found|dependent dylib|code signature invalid|mapped file has no cdhash|bad cpu type' \
        "$probe_stderr"; then
        probe_message="$(tr '\n' ' ' < "$probe_stderr" | cut -c 1-600)"
        audit_fail "loader rejected $probe_relative: $probe_message"
    fi
    rm -f "$probe_stderr"
}

[[ -d "$AUDIT_APP" ]] || { echo "bundle audit: app not found: $AUDIT_APP" >&2; exit 1; }
[[ -d "$AUDIT_BIN" ]] || { echo "bundle audit: solver directory not found: $AUDIT_BIN" >&2; exit 1; }
[[ -f "$AUDIT_MANIFEST" ]] || { echo "bundle audit: runtime manifest not found: $AUDIT_MANIFEST" >&2; exit 1; }
[[ -r "$AUDIT_REQUIRED_EXECUTABLES" ]] \
    || { echo "bundle audit: required executable inventory not found: $AUDIT_REQUIRED_EXECUTABLES" >&2; exit 1; }

MANIFEST_HEADER="$(sed -n '1p' "$AUDIT_MANIFEST")"
if [[ "$MANIFEST_HEADER" != "QNET_SOLVER_RUNTIME_V1" ]]; then
    audit_fail "unexpected runtime manifest header: $MANIFEST_HEADER"
fi

# The manifest is generated from build_app.sh's own target list, so it cannot
# by itself detect a target accidentally removed from that list.  Compare it
# with this independent GUI/release inventory before trusting any manifest row.
while IFS= read -r required_relative; do
    case "$required_relative" in
        ""|'#'*) continue ;;
    esac
    if ! awk -F '\t' -v required="$required_relative" '
        $1 == "available" && $2 == "executable" && $3 == required { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$AUDIT_MANIFEST"; then
        audit_fail "required GUI executable is not declared available: $required_relative"
    fi
done < "$AUDIT_REQUIRED_EXECUTABLES"

while IFS=$'\t' read -r status kind relative detail; do
    [[ "$status" == "available" || "$status" == "unavailable" ]] || continue
    case "$relative" in
        ""|/*|*../*|../*)
            audit_fail "unsafe or empty manifest path: $relative"
            continue
            ;;
    esac
    target="$AUDIT_BIN/$relative"
    if [[ "$status" == "available" ]]; then
        case "$kind" in
            executable)
                if [[ -x "$target" ]]; then
                    probe_executable "$target" "$relative"
                else
                    audit_fail "declared executable is missing or not executable: $relative"
                fi
                ;;
            support)
                [[ -r "$target" ]] || audit_fail "declared support file is missing or unreadable: $relative"
                ;;
            *)
                audit_fail "unknown manifest kind '$kind' for $relative"
                ;;
        esac
    elif [[ -e "$target" ]]; then
        audit_fail "solver is declared unavailable but a stale copy was bundled: $relative"
    fi
done < "$AUDIT_MANIFEST"

command -v otool >/dev/null 2>&1 || { echo "bundle audit: otool is required" >&2; exit 1; }

# Every non-system absolute path would make the app machine-dependent. Every
# @rpath dependency of a bundled solver/dylib must have a matching Frameworks
# payload. This catches a rewrite that succeeded even though its source dylib
# could not be copied.
while IFS= read -r audit_file; do
    file -b "$audit_file" 2>/dev/null | grep -q 'Mach-O' || continue
    while IFS= read -r dependency_line; do
        dependency="$(printf '%s\n' "$dependency_line" | awk '{print $1}')"
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /usr/lib/*|/System/*|/Library/Apple/*)
                ;;
            @rpath/*)
                dependency_base="$(basename "$dependency")"
                [[ -f "$AUDIT_FRAMEWORKS/$dependency_base" ]] \
                    || audit_fail "unresolved $dependency in ${audit_file#"$AUDIT_APP"/}"
                ;;
            @loader_path/*|@executable_path/*)
                # These are relocatable forms. Qnet's packager currently emits
                # @rpath, but retain compatibility with system toolchains.
                ;;
            /*)
                audit_fail "external absolute dependency $dependency in ${audit_file#"$AUDIT_APP"/}"
                ;;
            *)
                audit_fail "unrecognized dependency $dependency in ${audit_file#"$AUDIT_APP"/}"
                ;;
        esac
    done < <(otool -L "$audit_file" | tail -n +2)
done < <(find "$AUDIT_BIN" "$AUDIT_FRAMEWORKS" -type f -print)

if [[ "$AUDIT_ERRORS" -ne 0 ]]; then
    printf 'bundle audit failed with %d error(s)\n' "$AUDIT_ERRORS" >&2
    exit 1
fi

available_count="$(awk -F '\t' '$1 == "available" { count++ } END { print count + 0 }' "$AUDIT_MANIFEST")"
unavailable_count="$(awk -F '\t' '$1 == "unavailable" { count++ } END { print count + 0 }' "$AUDIT_MANIFEST")"
printf 'Solver bundle audit passed: %s available, %s explicitly unavailable.\n' \
    "$available_count" "$unavailable_count"
