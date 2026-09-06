#!/usr/bin/env bash
#
# build_app.sh — bundles Qnet into a double-clickable Qnet.app
#
# Output: Qnet.app/ inside the project root.
#
# What this does
# --------------
#  1. Reads the checked-in version without changing it. This distribution
#     intentionally remains Qnet 0.90.34 after every rebuild.
#  2. Builds every C analysis binary by running `make` in each
#     subdirectory under finite/ and infinite/.
#  3. Builds the Swift GUI in release mode (target name "Qnet"
#     for SwiftPM, but the produced app bundle and inner executable
#     are renamed to "Qnet").
#  4. Assembles a standard macOS .app bundle:
#        Qnet.app/
#          Contents/
#            Info.plist
#            MacOS/Qnet                   (the Swift executable)
#            Resources/bin/finite/...     (C binaries grouped as in source)
#            Resources/bin/infinite/...
#            Resources/SwiftTerm_SwiftTerm.bundle/
#            Frameworks/                  (homebrew dylibs the C binaries
#                                          link against, with rewritten
#                                          load paths)
#  5. Copies + rewrites every required dylib so the .app runs without
#     depending on /opt/homebrew at runtime.
#  6. Ad-hoc code-signs the bundle so macOS will let you launch it.
#
# Run from anywhere; it cd's into the project root automatically.

set -euo pipefail

# ───────────────────────────────────────────────────────────────────
# Locate project root (this script lives at the project root).
# ───────────────────────────────────────────────────────────────────
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"
PROJECT_ROOT="$(pwd -P)"   # physical, for the reason above

# SwiftPM target name (matches Package.swift) — produces .build/release/Qnet.
SWIFT_TARGET="Qnet"
# CI and offline validation can reuse an already-resolved SwiftPM scratch
# directory. Ordinary release builds keep the conventional project .build.
SWIFT_SCRATCH_PATH="${QNET_SWIFT_SCRATCH_PATH:-$PROJECT_ROOT/.build}"
if [[ "$SWIFT_SCRATCH_PATH" != /* ]]; then
    SWIFT_SCRATCH_PATH="$PROJECT_ROOT/$SWIFT_SCRATCH_PATH"
fi

# Keep compiler caches inside the selected scratch tree. This makes a copied
# source package independent of permissions on global Swift/Clang caches.
SWIFT_MODULE_CACHE="$SWIFT_SCRATCH_PATH/module-cache"
mkdir -p "$SWIFT_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SWIFT_MODULE_CACHE}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$SWIFT_MODULE_CACHE}"

# A Command Line Tools update can briefly leave the default SDK out of step
# with the active compiler. Prefer the default, but use CLT's retained 15.4 SDK
# when a trivial Foundation import proves that the default is incompatible.
if [[ -z "${SDKROOT:-}" ]] \
    && ! printf 'import Foundation\n' | swiftc -typecheck - >/dev/null 2>&1; then
    if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
        export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    fi
fi
if ! printf 'import Foundation\n' | swiftc -typecheck - >/dev/null 2>&1; then
    printf '%s\n' \
        'ERROR: the active Swift compiler and macOS SDK are incompatible; update Xcode Command Line Tools or set SDKROOT to a matching SDK' >&2
    exit 1
fi

# User-facing app name. The bundle is named ${APP_NAME}.app and the
# inner executable in Contents/MacOS is renamed to match. Keep the
# bundle identifier (further down in the Info.plist heredoc) stable
# across renames so existing Keychain entries (com.bnetgui.ai) keep
# working.
APP_NAME="Qnet"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
BIN_RESOURCE_DIR="$RESOURCES_DIR/bin"

# ───────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  ! %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

# Returns non-zero only for a loader/architecture failure. A solver's normal
# usage error is acceptable here: reaching main proves its dependencies load.
loader_probe() {
    local probe_target="$1"
    local probe_stderr
    local probe_pid
    local probe_running=1
    local probe_step
    probe_stderr="$(mktemp "${TMPDIR:-/tmp}/qnet-build-loader.XXXXXX")"
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
        warn "loader rejected $probe_target: $(tr '\n' ' ' < "$probe_stderr" | cut -c 1-500)"
        rm -f "$probe_stderr"
        return 1
    fi
    rm -f "$probe_stderr"
    return 0
}

require make
require swift
require python3
require otool
require install_name_tool
require codesign
require plutil
require xattr

# ───────────────────────────────────────────────────────────────────
# 0. Preserve the version requested for this source distribution.
# ───────────────────────────────────────────────────────────────────
NEW_VERSION="$(sed -nE \
    's/^[[:space:]]*static let version = "([^"]+)".*$/\1/p' \
    "$PROJECT_ROOT/Sources/Qnet/AppVersion.swift")"
[[ "$NEW_VERSION" == "0.90.34" ]] \
    || die "this source distribution must be version 0.90.34 (found '$NEW_VERSION')"
log "Building Qnet $NEW_VERSION (version preserved)"

# ───────────────────────────────────────────────────────────────────
# 0. Design-system lint — the same gate test.sh runs first. Aborts the
#    release before any compiler runs; see the adoption guide at the top
#    of Sources/Qnet/DesignSystem.swift for what it enforces.
# ───────────────────────────────────────────────────────────────────
log "Running design lint"
"$PROJECT_ROOT/validation/design_lint.sh" \
    || die "design lint failed — fix the listed lines before building a release"

# ───────────────────────────────────────────────────────────────────
# 1. Build every C binary via its Makefile.
# ───────────────────────────────────────────────────────────────────
log "Building C analysis binaries"

# Each entry: "<group>/<subdir>:<binary-name>[, <binary-name>...]"
# group is "finite" or "infinite". The binary names match what the
# Swift `findBinary(name:subdirectory:)` look-up expects.
# Solvers exposed by normal GUI actions. A release is invalid if any of these
# cannot be built and copied; silently shipping a stale/missing helper is what
# caused development runs to fail in dyld.
REQUIRED_C_TARGETS=(
    "infinite/BNAsbd:bna_sbd"
    "infinite/BNAqna:bna_qna"
    "infinite/BNArqna:bna_rqna"
    "infinite/BNAsim:jackson_sim"
    "infinite/BNAsm:bnet"
    "infinite/BNAlp:srbm_lp"
    "infinite/BNAmc:rbm_mlmc"
    "finite/fBNAfm:bna_fm_gauss bna_fm_cbc"
    "finite/fBNAlp:fBNAlp_solver"
    "finite/fBNAsim:fBNAsim"
    "finite/fBNAsm:srbm_solver"
    # The C engines for the three dual-engine methods. Required, not optional:
    # Settings > Solvers > Solver Engine defaults to the C engine, and a release
    # missing them would fall back to Python everywhere and silently be the slow
    # build. The fallback exists for a source checkout, not for a shipped app.
    "infinite/BNArmc:bna_rmc"
    "infinite/BNAqbd:bna_qbd"
    "infinite/BNAtc:bna_tc"
    "finite/fBNAgc:fbna_gc"
)

# Experimental helpers may be absent when their research dependencies are not
# installed. Their absence is recorded in the runtime status manifest so the
# GUI can disable/explain the action instead of exposing a missing command.
OPTIONAL_C_TARGETS=(
    "infinite/BNAmd:mc_solver"
)

# Python solvers launched by the GUI. Keep the source-tree
# layout so `findSupportFile(name:subdirectory:)` uses the same lookup in a
# development checkout and in the bundled app.
PYTHON_SUPPORT_FILES=(
    "finite/fBNActmc/ctmc_dtandem.py"
    "finite/fBNAgc/solver.py"
    "finite/fBNAdecomp/fbna_decomp.py"
    "infinite/BNAtc/truncated_ctmc.py"
    "infinite/BNAalr/low_rank_bar.py"
    "infinite/BNAbb/__init__.py"
    "infinite/BNAbb/bar_bounds.py"
    "infinite/BNAbb/cvxpy_backend.py"
    "infinite/BNAbb/solver.py"
    "infinite/BNAbb/schema.json"
    "infinite/BNArmc/regenerative_mc.py"
    "infinite/BNAqbd/qbd_solver.py"
    "infinite/BNApf/__init__.py"
    "infinite/BNApf/bcmp.py"
    "infinite/BNApf/common.py"
    "infinite/BNApf/kaufman_roberts.py"
    "infinite/BNApf/mixed_bcmp.py"
    "infinite/BNApf/open_bcmp.py"
    "infinite/BNApf/schema.json"
    "infinite/BNApf/solver.py"
)

# Non-standard-library imports required by individual Python solvers. Entries
# are `<support path>:<space-delimited module names>`. They are recorded in the
# runtime manifest and enforced by `resolvePythonSupportFile` when the GUI
# requests that solver; they are not silently treated as bundled modules.
PYTHON_SUPPORT_REQUIREMENTS=(
    "finite/fBNActmc/ctmc_dtandem.py:numpy"
)

python_requirements_for() {
    local requested="$1"
    local entry
    for entry in "${PYTHON_SUPPORT_REQUIREMENTS[@]}"; do
        if [[ "${entry%%:*}" == "$requested" ]]; then
            printf '%s' "${entry#*:}"
            return 0
        fi
    done
    return 0
}

AVAILABLE_C_TARGETS=()
UNAVAILABLE_SOLVER_RECORDS=()

for entry in "${REQUIRED_C_TARGETS[@]}"; do
    dir="${entry%%:*}"
    bins="${entry#*:}"
    log "  $dir"
    if [[ ! -d "$PROJECT_ROOT/$dir" ]]; then
        die "required solver directory $dir not found"
    fi
    (cd "$PROJECT_ROOT/$dir" && make) \
        || die "make failed in $dir"
    # A declared release helper is a hard contract, not a best-effort copy.
    for bin in $bins; do
        if [[ ! -x "$PROJECT_ROOT/$dir/$bin" ]]; then
            die "$dir/$bin was not produced as an executable"
        fi
    done
    AVAILABLE_C_TARGETS+=("$entry")
done

for entry in "${OPTIONAL_C_TARGETS[@]}"; do
    dir="${entry%%:*}"
    bins="${entry#*:}"
    log "  $dir (optional)"
    optional_reason="requires cJSON, SuiteSparse, libomp, and Accelerate; rebuild with those dependencies installed"
    if [[ -d "$PROJECT_ROOT/$dir" ]] && (cd "$PROJECT_ROOT/$dir" && make); then
        optional_complete=1
        for bin in $bins; do
            if [[ ! -x "$PROJECT_ROOT/$dir/$bin" ]] \
                || ! loader_probe "$PROJECT_ROOT/$dir/$bin"; then
                optional_complete=0
            fi
        done
        if [[ "$optional_complete" -eq 1 ]]; then
            AVAILABLE_C_TARGETS+=("$entry")
        else
            warn "$dir did not produce every optional binary; the feature will be disabled"
            for bin in $bins; do
                UNAVAILABLE_SOLVER_RECORDS+=("executable"$'\t'"$dir/$bin"$'\t'"$optional_reason")
            done
        fi
    else
        warn "$dir could not be built; the feature will be disabled"
        for bin in $bins; do
            UNAVAILABLE_SOLVER_RECORDS+=("executable"$'\t'"$dir/$bin"$'\t'"$optional_reason")
        done
    fi
done

for relative in "${PYTHON_SUPPORT_FILES[@]}"; do
    [[ -f "$PROJECT_ROOT/$relative" ]] \
        || die "Python support solver not found: $relative"
done

for requirement in "${PYTHON_SUPPORT_REQUIREMENTS[@]}"; do
    requirement_path="${requirement%%:*}"
    requirement_modules="${requirement#*:}"
    requirement_declared=0
    for relative in "${PYTHON_SUPPORT_FILES[@]}"; do
        if [[ "$relative" == "$requirement_path" ]]; then
            requirement_declared=1
            break
        fi
    done
    [[ "$requirement_declared" -eq 1 ]] \
        || die "Python dependency metadata names undeclared support file: $requirement_path"
    [[ -n "$requirement_modules" ]] \
        || die "Python dependency metadata has no modules: $requirement_path"
    for requirement_module in $requirement_modules; do
        if ! python3 -c \
            'import importlib.util, sys; raise SystemExit(0 if importlib.util.find_spec(sys.argv[1]) else 1)' \
            "$requirement_module"; then
            warn "$requirement_path requires Python module '$requirement_module' at runtime; the GUI preflight will disable it until that module is installed"
        fi
    done
done

# Parse every bundled Python source before assembling the app. This catches a
# truncated or syntactically invalid support module without creating pyc files
# in the repository.
python3 - "${PYTHON_SUPPORT_FILES[@]}" <<'PY'
import ast
import pathlib
import sys

for raw in sys.argv[1:]:
    path = pathlib.Path(raw)
    if path.suffix == ".py":
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY

# ───────────────────────────────────────────────────────────────────
# 2. Build the Swift GUI executable.
# ───────────────────────────────────────────────────────────────────
log "Building Swift GUI (release)"
SWIFT_BUILD_ARGS=(-c release --scratch-path "$SWIFT_SCRATCH_PATH")
if [[ "${QNET_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    # Some managed CI/container environments cannot start Apple's nested
    # sandbox-exec process. This opt-in affects only the local build step.
    SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi
swift build "${SWIFT_BUILD_ARGS[@]}" || die "swift build failed"
SWIFT_EXEC="$SWIFT_SCRATCH_PATH/release/$SWIFT_TARGET"
[[ -x "$SWIFT_EXEC" ]] || die "Swift executable not found at $SWIFT_EXEC"

# ───────────────────────────────────────────────────────────────────
# 3. Reset and create the bundle skeleton.
# ───────────────────────────────────────────────────────────────────
log "Assembling $APP_NAME.app"
# Best-effort cleanup of the legacy bundle name from the BNETGUI era.
# Harmless when absent.
rm -rf "$PROJECT_ROOT/BNETGUI.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$BIN_RESOURCE_DIR"

# 3a. Swift executable. The SwiftPM target name matches the app name
# (CFBundleExecutable=Qnet), so this is a straight copy with no rename.
cp "$SWIFT_EXEC" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# SwiftPM generates a runtime accessor for SwiftTerm's Metal shader. For a
# command-line build it finds this bundle beside the executable. Qnet's vendored
# integration also looks under Bundle.main.resourceURL for a normal signed app.
SWIFTTERM_RESOURCE_BUNDLE="$SWIFT_SCRATCH_PATH/release/SwiftTerm_SwiftTerm.bundle"
[[ -d "$SWIFTTERM_RESOURCE_BUNDLE" ]] \
    || die "SwiftTerm resource bundle not found at $SWIFTTERM_RESOURCE_BUNDLE"
cp -R "$SWIFTTERM_RESOURCE_BUNDLE" \
    "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"
chmod -R u+w "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"
[[ -f "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal" ]] \
    || die "SwiftTerm Metal shader was not copied into the application"

# 3a-bis. App icon — copy assets/AppIcon.icns into Resources/. Generated
# by assets/make_icon.sh from assets/make_icon.swift; regenerate that
# file when you change the design. If the icon file is missing the
# bundle still launches but uses the generic blank-doc icon.
ICON_SRC="$PROJECT_ROOT/assets/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
else
    warn "assets/AppIcon.icns not found — bundle will use default icon."
    warn "(Run assets/make_icon.sh to generate it.)"
fi

# 3a-ter. Example networks — copy input/examples into Resources/examples.
#
# The File menu promises "Open one of the bundled literature networks" and the
# empty canvas offers "Open an Example…" as its only action, but nothing was
# ever bundled: locateExamples() walked up from the working directory,
# which for a Finder-launched .app is `/`, so the panel opened on wherever the
# user happened to be. The Swift side now prefers Bundle.main.resourceURL, so
# this copy is what makes that affordance work in a distributed app.
#
# This is a hard contract, not a best-effort copy: a release whose only
# actionable empty-state button leads nowhere is worse than a release that
# refuses to build. `required_release_executables.txt` is deliberately an
# *executable* inventory and is not the place for documents, so the count is
# asserted here against the source directory.
EXAMPLES_SRC="$PROJECT_ROOT/input/examples"
EXAMPLES_DST="$RESOURCES_DIR/examples"
[[ -d "$EXAMPLES_SRC" ]] || die "example networks not found at $EXAMPLES_SRC"
EXAMPLES_EXPECTED="$(find "$EXAMPLES_SRC" -type f -name '*.bnet' | wc -l | tr -d ' ')"
[[ "$EXAMPLES_EXPECTED" -gt 0 ]] || die "no .bnet documents in $EXAMPLES_SRC"
rm -rf "$EXAMPLES_DST"
mkdir -p "$EXAMPLES_DST"
cp -R "$EXAMPLES_SRC/." "$EXAMPLES_DST/"
chmod -R u+w "$EXAMPLES_DST"
EXAMPLES_BUNDLED="$(find "$EXAMPLES_DST" -type f -name '*.bnet' | wc -l | tr -d ' ')"
[[ "$EXAMPLES_BUNDLED" -eq "$EXAMPLES_EXPECTED" ]] \
    || die "bundled $EXAMPLES_BUNDLED example networks, expected $EXAMPLES_EXPECTED"
log "Bundled $EXAMPLES_BUNDLED example networks into Resources/examples"

# 3b. C binaries — preserve the same group/subdir layout the Swift
# code expects under Resources/bin/.
for entry in "${AVAILABLE_C_TARGETS[@]}"; do
    dir="${entry%%:*}"
    bins="${entry#*:}"
    src_dir="$PROJECT_ROOT/$dir"
    dst_dir="$BIN_RESOURCE_DIR/$dir"
    [[ -d "$src_dir" ]] || continue
    mkdir -p "$dst_dir"
    for bin in $bins; do
        if [[ -x "$src_dir/$bin" ]]; then
            cp "$src_dir/$bin" "$dst_dir/$bin"
            chmod +x "$dst_dir/$bin"
        fi
    done
done

# 3b-bis. Python support solvers. They are invoked through `python3`, so the
# read bit—not an executable bit—is the contract.
for relative in "${PYTHON_SUPPORT_FILES[@]}"; do
    dst="$BIN_RESOURCE_DIR/$relative"
    mkdir -p "$(dirname "$dst")"
    cp "$PROJECT_ROOT/$relative" "$dst"
done

# Machine-readable-enough, dependency-free status manifest. The Swift runtime
# resolver reads unavailable rows to provide a precise explanation. The bundle
# audit below treats every available row as a release completeness contract.
SOLVER_STATUS_MANIFEST="$RESOURCES_DIR/solver-runtime-status-v1.tsv"
{
    printf 'QNET_SOLVER_RUNTIME_V1\n'
    for entry in "${AVAILABLE_C_TARGETS[@]}"; do
        dir="${entry%%:*}"
        bins="${entry#*:}"
        for bin in $bins; do
            printf 'available\texecutable\t%s/%s\tload-probed during runtime resolution\n' "$dir" "$bin"
        done
    done
    for relative in "${PYTHON_SUPPORT_FILES[@]}"; do
        requirements="$(python_requirements_for "$relative")"
        if [[ -n "$requirements" ]]; then
            printf 'available\tsupport\t%s\tPython support file; runtime modules: %s\n' \
                "$relative" "$requirements"
        else
            printf 'available\tsupport\t%s\tstandard-library support file\n' "$relative"
        fi
    done
    # Bash 3.2 under `set -u` treats an expansion of an empty array as an
    # unbound variable. Guard the loop so an installation with every optional
    # solver available produces a valid all-available manifest.
    if [[ "${#UNAVAILABLE_SOLVER_RECORDS[@]}" -gt 0 ]]; then
        for record in "${UNAVAILABLE_SOLVER_RECORDS[@]}"; do
            printf 'unavailable\t%s\n' "$record"
        done
    fi
} > "$SOLVER_STATUS_MANIFEST"

# 3c. Info.plist. CFBundleIdentifier intentionally stays as
# com.bnetgui.app to keep existing Keychain entries (com.bnetgui.ai,
# used by the AI assistant for API keys) accessible after rebrand.
# CFBundleVersion / CFBundleShortVersionString carry the patch number
# so macOS's Finder "Get Info" reports the same version the in-app
# About window shows.
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.bnetgui.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$NEW_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$NEW_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
plutil -lint "$CONTENTS/Info.plist" >/dev/null \
    || die "generated Info.plist is invalid"

# ───────────────────────────────────────────────────────────────────
# 4. Bundle dylib dependencies.
#
# Each C binary may link against /opt/homebrew/lib/lib*.dylib. To make
# the .app portable, we walk the otool -L output, copy each non-system
# dylib into Contents/Frameworks/, and rewrite the binary's load path
# to `@executable_path/../Frameworks/<libname>`. Then we recurse to do
# the same for each copied dylib's own dependencies.
# ───────────────────────────────────────────────────────────────────
log "Bundling dylib dependencies"

# Bash 3.2 (macOS default) has no associative arrays, so we track
# already-processed dylib basenames via a space-delimited string and
# a substring check.
SEEN_BASES=""

is_seen() {
    case " $SEEN_BASES " in *" $1 "*) return 0 ;; esac
    return 1
}
mark_seen() { SEEN_BASES="$SEEN_BASES $1"; }

# Returns 0 if the path is "system" (don't bundle) — i.e. starts with
# /usr/lib, /System/, or is the bundled @rpath placeholder.
is_system_lib() {
    local p="$1"
    case "$p" in
        /usr/lib/*)      return 0 ;;
        /System/*)       return 0 ;;
        /Library/Apple/*) return 0 ;;
    esac
    return 1
}

# Builds the @loader_path-relative LC_RPATH for a binary at $1 so
# `@rpath/<lib>` references resolve to Contents/Frameworks/<lib>.
# Different binaries live at different depths (MacOS/ is 1 deep,
# Resources/bin/<g>/<s>/ is 4 deep, Frameworks/ itself is 1 deep).
relpath_loader_to_frameworks() {
    local target_path="$1"
    local rel="${target_path#"$CONTENTS"/}"
    local dir_part
    dir_part="$(dirname "$rel")"
    [[ "$dir_part" == "." ]] && dir_part=""
    local depth=0
    local cur="$dir_part"
    while [[ -n "$cur" ]]; do
        depth=$((depth + 1))
        if [[ "$cur" == */* ]]; then
            cur="${cur%/*}"
        else
            cur=""
        fi
    done
    local ups=""
    local i
    for ((i=0; i<depth; i++)); do
        ups="${ups}../"
    done
    printf '@loader_path/%sFrameworks' "$ups"
}

# Rewrite every non-system dylib reference in `$1` to `@rpath/<base>`
# (always at least as short as the original homebrew path, so no
# Mach-O header padding is required) and add a single LC_RPATH that
# tells dyld where Frameworks/ actually is. Copies any new dylib
# into Frameworks/ and recurses on it.
process_binary() {
    local target="$1"
    [[ -f "$target" ]] || return 0

    # Add the rpath entry. Suppress the harmless "code signature
    # will be invalidated" warning, but surface real errors (e.g. the
    # binary lacks header pad space — caller should rebuild it with
    # `-Wl,-headerpad_max_install_names`).
    local rpath_value
    rpath_value="$(relpath_loader_to_frameworks "$target")"
    install_name_tool -add_rpath "$rpath_value" "$target" 2>&1 \
        | grep -v -E 'invalidate the code signature' >&2 || true

    while IFS= read -r line; do
        local lib_path
        lib_path="$(printf '%s\n' "$line" | awk '{print $1}')"
        [[ -z "$lib_path" ]] && continue
        [[ "$lib_path" == "$target:" ]] && continue
        is_system_lib "$lib_path" && continue

        local base
        base="$(basename "$lib_path")"
        local new_ref="@rpath/$base"

        # Skip the no-op rewrite — saves a pointless invocation and
        # keeps the change list deterministic.
        if [[ "$lib_path" != "$new_ref" ]]; then
            install_name_tool -change "$lib_path" "$new_ref" "$target" 2>/dev/null || true
        fi

        if ! is_seen "$base"; then
            # Resolve from a real on-disk path. @rpath / relative refs
            # can't be copied directly; try a few common Homebrew
            # prefixes.
            local source_path="$lib_path"
            case "$source_path" in
                @rpath/*|@loader_path/*|@executable_path/*)
                    source_path=""
                    ;;
            esac
            if [[ "$source_path" != /* ]]; then
                source_path=""
            fi
            if [[ -z "$source_path" ]]; then
                # Standard Homebrew prefixes plus gcc/gfortran's
                # @rpath-resolved current/version directories. Globbed
                # patterns expand at runtime so any installed gcc
                # version contributes its libquadmath / libgcc_s.
                for prefix in \
                    /opt/homebrew/lib \
                    /opt/homebrew/opt/libomp/lib \
                    /opt/homebrew/opt/gcc/lib/gcc/current \
                    /opt/homebrew/Cellar/gcc/*/lib/gcc/current \
                    /opt/homebrew/Cellar/gcc@*/*/lib/gcc/* \
                    /usr/local/lib
                do
                    if [[ -f "$prefix/$base" ]]; then
                        source_path="$prefix/$base"
                        break
                    fi
                done
            fi
            if [[ -n "$source_path" && -f "$source_path" ]]; then
                cp -f "$source_path" "$FRAMEWORKS_DIR/$base"
                chmod u+w "$FRAMEWORKS_DIR/$base"
                install_name_tool -id "@rpath/$base" \
                    "$FRAMEWORKS_DIR/$base" 2>/dev/null || true
                mark_seen "$base"
                process_binary "$FRAMEWORKS_DIR/$base"
            else
                warn "could not locate dylib $base referenced by $target"
            fi
        fi
    done < <(otool -L "$target" | tail -n +2)
}

# Walk every executable inside the bundle. macOS find wants `-perm +0111`
# or `-perm -u+x`; the latter is portable.
find "$MACOS_DIR" "$BIN_RESOURCE_DIR" -type f -perm -u+x | while read -r f; do
    # Executable Python scripts are text files and must never be handed to
    # install_name_tool merely because `file` describes them as executable.
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    process_binary "$f"
done

# ───────────────────────────────────────────────────────────────────
# Reflect the actual deployment targets of bundled Homebrew libraries in the
# app metadata. The GUI's macOS 14 minimum does not lower a dylib's minimum.
python3 - "$APP_BUNDLE" <<'PY'
import pathlib
import plistlib
import re
import subprocess
import sys
app = pathlib.Path(sys.argv[1])
versions = [(14, 0)]
for relative in ('Contents/MacOS', 'Contents/Frameworks', 'Contents/Resources/bin'):
    for candidate in (app / relative).rglob('*'):
        if not candidate.is_file():
            continue
        if not candidate.name.endswith('.dylib') and not candidate.stat().st_mode & 0o111:
            continue
        result = subprocess.run(['otool', '-l', str(candidate)], capture_output=True, text=True)
        if result.returncode:
            continue
        for block in result.stdout.split('Load command '):
            if 'cmd LC_BUILD_VERSION' in block:
                match = re.search(r'\bminos ([0-9.]+)', block)
            elif 'cmd LC_VERSION_MIN_MACOSX' in block:
                match = re.search(r'\bversion ([0-9.]+)', block)
            else:
                continue
            if match:
                versions.append(tuple(map(int, match.group(1).split('.'))))
minimum = '.'.join(map(str, max(versions)))
info = app / 'Contents/Info.plist'
with info.open('rb') as stream:
    metadata = plistlib.load(stream)
metadata['LSMinimumSystemVersion'] = minimum
with info.open('wb') as stream:
    plistlib.dump(metadata, stream, sort_keys=False)
print('App minimum macOS from bundled executable/library metadata:', minimum)
PY
if [[ -d "$PROJECT_ROOT/ThirdPartyLicenses" ]]; then
    cp -R "$PROJECT_ROOT/ThirdPartyLicenses" "$RESOURCES_DIR/ThirdPartyLicenses"
    chmod -R u+w "$RESOURCES_DIR/ThirdPartyLicenses"
fi

# 5. Ad-hoc code sign the bundle.
#
# Without this, Gatekeeper on a fresh Mac will refuse to launch the
# app ("damaged"). Ad-hoc signing is enough for local distribution; a
# notarized DMG would need a Developer ID and `xcrun notarytool`.
# ───────────────────────────────────────────────────────────────────
log "Code-signing $APP_NAME.app (ad-hoc)"

# Cloud-sync and copied icon resources can carry Finder/resource-fork xattrs
# that codesign rejects as unsealed detritus. Remove them only from the newly
# assembled bundle immediately before signing.
xattr -cr "$APP_BUNDLE"

# Sign the dylibs first, then any inner binaries, then the bundle.
find "$FRAMEWORKS_DIR" -name '*.dylib' -exec \
    codesign --force --sign - --timestamp=none {} \; 2>/dev/null || true

while IFS= read -r inner_executable; do
    # codesign stores signatures for executable text scripts in extended
    # attributes. Those attributes are fragile when an app is zipped, copied,
    # or synced, and the scripts are resources rather than Mach-O code anyway.
    file -b "$inner_executable" 2>/dev/null | grep -q "Mach-O" || continue
    codesign --force --sign - --timestamp=none "$inner_executable"
done < <(find "$BIN_RESOURCE_DIR" -type f -perm -u+x -print)

codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" \
    || die "final app signature verification failed"

# Signing is the final mutation of native payloads. Audit afterward so the
# loader probe sees valid signatures as well as the final relocated libraries.
# This fails the release for a missing declared helper, a stale optional helper,
# a non-system absolute dependency, an unresolved @rpath, or a loader error.
"$PROJECT_ROOT/validation/solver_bundle_audit.sh" "$APP_BUNDLE" \
    || die "post-sign solver bundle audit failed"

log "Done."
echo ""
echo "  Created: $APP_BUNDLE"
echo "  Drag-and-drop into /Applications, or double-click to launch."
echo ""
echo "  Note: ad-hoc signing means the first launch may show a"
echo "  \"developer cannot be verified\" dialog. Right-click → Open"
echo "  to dismiss it once; subsequent launches are silent."
