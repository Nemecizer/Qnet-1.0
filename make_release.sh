#!/usr/bin/env bash
#
# make_release.sh — produce a distributable, self-proving Qnet release.
#
# READ THIS FIRST: the standalone .app is built by ./build_app.sh, which has
# always done the whole job — every native solver, the release Swift binary,
# and every Homebrew dylib (libomp, SuiteSparse, HiGHS, gfortran, cJSON …)
# copied into Contents/Frameworks with its load paths rewritten, then ad-hoc
# signed and audited. This script does not re-implement any of that.
#
# What it adds is the part that matters when the .app leaves your Mac:
#
#   1. Runs build_app.sh, then verify_source_package.sh (both build paths,
#      signature, bundle audit, RQNA self-test, all 35 packaged examples).
#   2. PROVES the bundle is standalone rather than asserting it: walks every
#      Mach-O file inside the .app and fails if any of them still links
#      something from /opt/homebrew or /usr/local. This is the check that
#      catches "it runs on my machine" — a developer Mac has the Homebrew
#      libraries, so a bundle that quietly depends on them tests fine locally
#      and dies on the first machine that does not.
#   3. Records the bundle's real minimum macOS, computed from its own Mach-O
#      load commands rather than from a number someone typed in a plist.
#   4. Emits a versioned, checksummed .zip that preserves symlinks and
#      extended attributes (ditto, not zip — a plain `zip` breaks the
#      framework symlinks and strips the signature).
#   5. Re-verifies the SIGNATURE AFTER archiving and re-expanding, because
#      that is the artifact a user actually receives.
#
# Output: dist/Qnet-<version>-arm64.zip plus a .sha256 beside it.
#
# Usage:  ./make_release.sh            full build + verify + package
#         ./make_release.sh --fast     skip verify_source_package.sh (dev loop)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mRelease failed:\033[0m %s\n" "$*" >&2; exit 1; }

APP="$ROOT/Qnet.app"
DIST="$ROOT/dist"

# ── 1. Build ────────────────────────────────────────────────────────────────
log "Building the application bundle"
./build_app.sh >/dev/null || die "build_app.sh failed — run it directly to see why"
[[ -d "$APP" ]] || die "build_app.sh did not produce $APP"
ok "Qnet.app built"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString"
BINARY_VERSION="$("$APP/Contents/MacOS/Qnet" --version | awk '{print $2}')"
[[ "$VERSION" == "$BINARY_VERSION" ]] \
    || die "Info.plist says $VERSION but the binary says $BINARY_VERSION"
ok "version $VERSION agrees between Info.plist and the binary"

# ── 2. Full verification ────────────────────────────────────────────────────
if [[ $FAST -eq 0 ]]; then
    log "Verifying the source package (both build paths, signature, examples)"
    ./verify_source_package.sh >/dev/null || die "verify_source_package.sh failed"
    ok "source-run and bundle verification passed"
else
    warn "--fast: skipped verify_source_package.sh"
fi

# ── 3. Prove the bundle is standalone ───────────────────────────────────────
# A developer Mac HAS /opt/homebrew, so a bundle that still links against it
# launches fine here and fails on a clean machine. Only this check separates
# the two, which is why it is a hard failure and not a warning.
log "Proving no binary inside the bundle depends on Homebrew"
external=""
while IFS= read -r macho; do
    deps="$(otool -L "$macho" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E '^(/opt/homebrew|/usr/local)' || true)"
    if [[ -n "$deps" ]]; then
        external+="    ${macho#$APP/}"$'\n'
        while IFS= read -r d; do external+="        -> $d"$'\n'; done <<<"$deps"
    fi
done < <(find "$APP" -type f \( -perm -111 -o -name '*.dylib' \) -exec sh -c \
            'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \; 2>/dev/null)

if [[ -n "$external" ]]; then
    printf '%s' "$external" >&2
    die "the bundle is NOT standalone — the files above link outside it"
fi
DYLIBS="$(find "$APP/Contents/Frameworks" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
ok "no external dependencies; $DYLIBS libraries bundled in Contents/Frameworks"

# ── 4. Minimum macOS, computed from the bundle itself ───────────────────────
log "Computing the real minimum macOS from the bundled Mach-O files"
MINOS="$(find "$APP" -type f \( -perm -111 -o -name '*.dylib' \) -exec sh -c \
    'file -b "$1" | grep -q Mach-O && otool -l "$1" 2>/dev/null | awk "/minos/ {print \$2}"' _ {} \; \
    2>/dev/null | sort -V | tail -1)"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Qnet" 2>/dev/null || echo unknown)"
ok "architectures: $ARCHS"
ok "minimum macOS required by the bundled binaries: ${MINOS:-unknown}"
[[ "$ARCHS" == *x86_64* ]] || warn "Apple silicon only — Intel Macs cannot run this build"

# ── 5. Signature ────────────────────────────────────────────────────────────
log "Verifying the code signature"
codesign --verify --deep --strict "$APP" || die "signature verification failed"
# Capture first, match second. `codesign -dv … | grep -q` looks correct and is
# not: grep -q exits on the first match, codesign takes SIGPIPE, and `pipefail`
# then makes the whole pipeline non-zero — so the adhoc branch is skipped and
# the script cheerfully reports a real identity. It is a race on the pipe
# buffer, so it passes in isolation and fails in the script. Never pipe into
# `grep -q` under `set -o pipefail` when the verdict matters.
SIGINFO="$(codesign -dv "$APP" 2>&1 || true)"
if grep -q 'Signature=adhoc' <<<"$SIGINFO"; then
    warn "ad-hoc signed: Gatekeeper will warn on first launch on another Mac."
    warn "For public distribution see 'Notarization' at the foot of this script."
else
    ok "signed with a real identity"
fi

# ── 6. Package ──────────────────────────────────────────────────────────────
# ditto, not zip: the Frameworks directory contains symlinks and the bundle
# carries extended attributes and a signature, all of which a plain `zip`
# quietly damages. `ditto -c -k --keepParent` is what Apple's own notarization
# workflow expects.
log "Packaging"
mkdir -p "$DIST"
ARCHIVE="$DIST/Qnet-${VERSION}-${ARCHS// /-}.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE" || die "ditto failed"
shasum -a 256 "$ARCHIVE" | sed "s|$DIST/||" > "$ARCHIVE.sha256"
ok "wrote ${ARCHIVE#$ROOT/} ($(du -h "$ARCHIVE" | cut -f1 | tr -d ' '))"

# ── 7. Verify the artifact a USER receives, not the one we built ────────────
log "Re-verifying the signature after a round trip through the archive"
ROUNDTRIP="$(mktemp -d "${TMPDIR:-/tmp}/qnet-release-check.XXXXXX")"
trap 'rm -rf "$ROUNDTRIP"' EXIT
ditto -x -k "$ARCHIVE" "$ROUNDTRIP" || die "could not expand the archive"
codesign --verify --deep --strict "$ROUNDTRIP/Qnet.app" \
    || die "signature did not survive archiving — do not ship this"
# Same capture-then-match rule as the signature check above.
UNPACKED_VERSION="$("$ROUNDTRIP/Qnet.app/Contents/MacOS/Qnet" --version 2>&1 || true)"
[[ "$UNPACKED_VERSION" == "Qnet $VERSION" ]] \
    || die "the unpacked app reports '$UNPACKED_VERSION', expected 'Qnet $VERSION'"
EXAMPLES="$(find "$ROUNDTRIP/Qnet.app" -name '*.bnet' | wc -l | tr -d ' ')"
ok "unpacked app verifies, reports Qnet $VERSION, carries $EXAMPLES example networks"

log "Release ready"
printf '  %s\n  %s\n\n' "${ARCHIVE#$ROOT/}" "${ARCHIVE#$ROOT/}.sha256"

cat <<'NOTARIZE'
  Notarization — required before this runs cleanly on someone else's Mac
  ---------------------------------------------------------------------
  An ad-hoc signature is enough for you and for anyone willing to
  Control-click ▸ Open once. For an unremarkable double-click on a stranger's
  Mac, Apple must have seen the build. That needs a paid Developer ID:

    1. Re-sign with your Developer ID and a hardened runtime:
         codesign --force --deep --options runtime --timestamp \
                  --sign "Developer ID Application: YOUR NAME (TEAMID)" Qnet.app
       Then re-run this script from step 6 to repackage.

    2. Submit and wait for the ticket:
         xcrun notarytool submit dist/Qnet-<version>-arm64.zip \
               --apple-id you@example.com --team-id TEAMID \
               --password <app-specific-password> --wait

    3. Staple the ticket to the app, then repackage so the archive carries it:
         xcrun stapler staple Qnet.app
         ditto -c -k --sequesterRsrc --keepParent Qnet.app dist/Qnet-<version>-arm64.zip

  Until then, tell users to Control-click the app and choose Open the first
  time. That is a real instruction, not a workaround to be embarrassed about —
  it is how unsigned open-source Mac software has always been distributed.
NOTARIZE
