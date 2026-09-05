#!/usr/bin/env bash
#
# make_pkg.sh — build a double-clickable macOS installer for Qnet.
#
# Produces dist/Qnet-<version>-arm64.pkg, which installs Qnet.app into
# /Applications. The user double-clicks it, clicks through the installer, and
# Qnet is in their Applications folder and Launchpad.
#
# Relationship to the other scripts:
#   build_app.sh    builds the standalone Qnet.app (all dylibs bundled)
#   make_release.sh packages that app as a .zip for people who drag-and-drop
#   make_pkg.sh     packages the same app as an installer for people who don't
#
# Both distribution scripts refuse to package an app that still links against
# Homebrew, because that is the failure a developer Mac cannot detect by
# running it: /opt/homebrew is present here and absent on the target.
#
# Usage:
#   ./make_pkg.sh              build the app first, then the installer
#   ./make_pkg.sh --no-build   package the existing Qnet.app as-is

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

NO_BUILD=0
[[ "${1:-}" == "--no-build" ]] && NO_BUILD=1

log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mInstaller build failed:\033[0m %s\n" "$*" >&2; exit 1; }

APP="$ROOT/Qnet.app"
DIST="$ROOT/dist"
PKG_IDENTIFIER="com.bnetgui.qnet.pkg"

# ── 1. The app ──────────────────────────────────────────────────────────────
if [[ $NO_BUILD -eq 0 ]]; then
    log "Building Qnet.app"
    ./build_app.sh >/dev/null || die "build_app.sh failed — run it directly to see why"
    ok "built"
else
    warn "--no-build: packaging the existing Qnet.app"
fi
[[ -d "$APP" ]] || die "$APP does not exist. Run ./build_app.sh first."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
BINARY_VERSION="$("$APP/Contents/MacOS/Qnet" --version 2>&1 | awk '{print $2}')"
[[ "$VERSION" == "$BINARY_VERSION" ]] \
    || die "Info.plist says $VERSION but the binary says $BINARY_VERSION"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Qnet" 2>/dev/null || echo unknown)"
ok "Qnet $VERSION ($APP_ID), $ARCHS"

# ── 2. Refuse to ship a non-standalone app ──────────────────────────────────
log "Checking the bundle carries its own libraries"
external=""
while IFS= read -r macho; do
    deps="$(otool -L "$macho" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E '^(/opt/homebrew|/usr/local)' || true)"
    [[ -n "$deps" ]] && external+="    ${macho#$APP/}"$'\n'
done < <(find "$APP" -type f \( -perm -111 -o -name '*.dylib' \) -exec sh -c \
            'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \; 2>/dev/null)
if [[ -n "$external" ]]; then
    printf '%s' "$external" >&2
    die "these files link outside the bundle; the installer would produce a broken app"
fi
DYLIBS="$(find "$APP/Contents/Frameworks" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
EXAMPLES="$(find "$APP" -name '*.bnet' | wc -l | tr -d ' ')"
ok "self-contained: $DYLIBS bundled libraries, $EXAMPLES example networks"

# The minimum macOS the installer will enforce, taken from the binaries
# themselves rather than from a number typed into a plist.
MINOS="$(find "$APP" -type f \( -perm -111 -o -name '*.dylib' \) -exec sh -c \
    'file -b "$1" | grep -q Mach-O && otool -l "$1" 2>/dev/null | awk "/minos/ {print \$2}"' _ {} \; \
    2>/dev/null | sort -V | tail -1)"
MINOS="${MINOS:-14.0}"
ok "minimum macOS computed from the bundled binaries: $MINOS"

# NOTE: the source app is deliberately NOT signature-checked here. This project
# is normally kept in a Dropbox CloudStorage folder, and Dropbox stamps
# com.dropbox.attrs, com.dropbox.internal and com.apple.FinderInfo onto every
# file it syncs. codesign rejects FinderInfo as "resource fork, Finder
# information, or similar detritus", so a bundle that verified at build time
# stops verifying once Dropbox has touched it — with nothing actually wrong
# inside. The staged copy below is cleaned and then checked, because the staged
# copy is what goes into the installer.

# ── 3. Stage ────────────────────────────────────────────────────────────────
# pkgbuild copies everything under --root, so the staging directory must hold
# the app and nothing else. Copy with ditto to preserve the signature and the
# Frameworks symlinks; cp -R would damage both.
log "Staging"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/root"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Qnet.app" || die "ditto failed while staging"

# Strip inherited extended attributes from the staging copy. Safe for a bundle:
# its signature lives in Contents/_CodeSignature and inside the Mach-O files,
# never in an xattr, so clearing them removes only the sync metadata. Done on
# the copy, never on the user's app.
DIRTY="$(find "$STAGE/Qnet.app" -exec sh -c 'xattr "$1" 2>/dev/null | grep -q . && echo x' _ {} \; 2>/dev/null | wc -l | tr -d ' ')"
xattr -cr "$STAGE/Qnet.app" 2>/dev/null || true
[[ "$DIRTY" -gt 0 ]] && ok "cleared inherited extended attributes from $DIRTY staged files"

codesign --verify --deep --strict "$STAGE/Qnet.app" \
    || die "the staged app's signature does not verify — rebuild with ./build_app.sh"
ok "staged, signature verifies"

# ── 4. Installer presentation ───────────────────────────────────────────────
RES="$WORK/resources"
mkdir -p "$RES"
cp "$ROOT/LICENSE" "$RES/license.txt"

cat > "$RES/welcome.html" <<HTML
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{font:13px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;color:#1d1d1f}
h2{font-size:15px;margin:0 0 8px}p{margin:0 0 10px;line-height:1.5}
ul{margin:0 0 10px 18px;padding:0}li{margin-bottom:4px}code{font:12px ui-monospace,Menlo,monospace}</style>
</head><body>
<h2>Qnet $VERSION</h2>
<p>Qnet builds queueing networks on a canvas and solves their steady state with
seventeen numerical methods &mdash; exact Markov-chain solutions, two-moment
approximations, discrete-event simulation, and diffusion (SRBM) numerics &mdash;
then compares what those methods disagree about.</p>
<p>This installer places <strong>Qnet.app</strong> in your Applications folder.
Everything it needs is inside the app: $DYLIBS native libraries and
$EXAMPLES example networks. No Homebrew packages are required to run it.</p>
<ul>
<li>Requires macOS $MINOS or later, Apple silicon ($ARCHS).</li>
<li>Python 3 is needed only for the Python-backed methods; the app reports
which are available at startup.</li>
</ul>
</body></html>
HTML

cat > "$RES/conclusion.html" <<HTML
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{font:13px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;color:#1d1d1f}
h2{font-size:15px;margin:0 0 8px}p{margin:0 0 10px;line-height:1.5}
.note{background:#fff4e5;border-left:3px solid #c77700;padding:9px 11px;margin:0 0 10px}
code{font:12px ui-monospace,Menlo,monospace}</style>
</head><body>
<h2>Installed</h2>
<p>Qnet is now in your Applications folder.</p>
<div class="note">
<strong>The first launch needs one extra step.</strong> This build is ad-hoc
signed rather than notarized by Apple, so macOS will refuse an ordinary
double-click the first time. <strong>Control-click Qnet in Applications, choose
Open, and confirm once.</strong> Every launch after that is normal.
</div>
<p>To get started, choose <strong>File &rsaquo; New from Archetype&hellip;</strong>
for a ready-made network, or <strong>File &rsaquo; Open Example&hellip;</strong>
for one of the $EXAMPLES bundled models.</p>
</body></html>
HTML
ok "welcome, license and post-install panes written"

# ── 5. Build ────────────────────────────────────────────────────────────────
log "Building the component package"
COMPONENT="$WORK/Qnet-component.pkg"
pkgbuild \
    --root "$STAGE" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    --ownership recommended \
    "$COMPONENT" >/dev/null || die "pkgbuild failed"
ok "component built"

# The distribution file is what makes the installer refuse to run on a machine
# that cannot execute the app, instead of installing a bundle that then fails
# to launch with no explanation.
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Qnet $VERSION</title>
    <organization>com.bnetgui</organization>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="license.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="$ARCHS"/>
    <allowed-os-versions>
        <os-version min="$MINOS"/>
    </allowed-os-versions>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Qnet">
        <pkg-ref id="$PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$PKG_IDENTIFIER" version="$VERSION" onConclusion="none">Qnet-component.pkg</pkg-ref>
</installer-gui-script>
XML

log "Building the installer"
mkdir -p "$DIST"
PKG="$DIST/Qnet-${VERSION}-${ARCHS// /-}.pkg"
rm -f "$PKG" "$PKG.sha256"
productbuild \
    --distribution "$WORK/distribution.xml" \
    --package-path "$WORK" \
    --resources "$RES" \
    "$PKG" >/dev/null || die "productbuild failed"
ok "wrote ${PKG#$ROOT/} ($(du -h "$PKG" | cut -f1 | tr -d ' '))"

# ── 6. Sign, if an installer identity exists ────────────────────────────────
# Capture then match: never pipe into `grep -q` under `set -o pipefail`, because
# grep exits on the first match, the producer takes SIGPIPE, and the pipeline
# reports failure even though the match succeeded.
IDENTITIES="$(security find-identity -v 2>/dev/null || true)"
INSTALLER_ID="$(printf '%s' "$IDENTITIES" | grep 'Developer ID Installer' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
if [[ -n "$INSTALLER_ID" ]]; then
    log "Signing the installer"
    productsign --sign "$INSTALLER_ID" "$PKG" "$PKG.signed" || die "productsign failed"
    mv "$PKG.signed" "$PKG"
    ok "signed with: $INSTALLER_ID"
else
    warn "no 'Developer ID Installer' certificate — the installer is UNSIGNED."
    warn "See 'Distributing this installer' at the foot of this script."
fi

# ── 7. Verify the artifact a user receives ──────────────────────────────────
log "Verifying the installer"
EXPANDED="$WORK/expanded"
pkgutil --expand-full "$PKG" "$EXPANDED" || die "the package will not expand"
PAYLOAD_APP="$(find "$EXPANDED" -name 'Qnet.app' -maxdepth 4 -type d | head -1)"
[[ -n "$PAYLOAD_APP" ]] || die "no Qnet.app found inside the package payload"
codesign --verify --deep --strict "$PAYLOAD_APP" \
    || die "the app inside the package does not verify — do not ship this"
PAYLOAD_VERSION="$("$PAYLOAD_APP/Contents/MacOS/Qnet" --version 2>&1 || true)"
[[ "$PAYLOAD_VERSION" == "Qnet $VERSION" ]] \
    || die "the packaged app reports '$PAYLOAD_VERSION', expected 'Qnet $VERSION'"
PAYLOAD_EXAMPLES="$(find "$PAYLOAD_APP" -name '*.bnet' | wc -l | tr -d ' ')"
ok "payload verifies, reports Qnet $VERSION, carries $PAYLOAD_EXAMPLES examples"

INSTALL_TO="$(pkgutil --payload-files "$PKG" 2>/dev/null | head -1 || true)"
ok "installs to /Applications${INSTALL_TO#.}"

shasum -a 256 "$PKG" | sed "s|$DIST/||" > "$PKG.sha256"
ok "checksum written"

log "Installer ready"
printf '  %s\n  %s\n\n' "${PKG#$ROOT/}" "${PKG#$ROOT/}.sha256"

cat <<'NOTES'
  Installing it
  -------------
  Double-click the .pkg and follow the installer. Qnet lands in /Applications.

  Because this build is ad-hoc signed rather than notarized, the FIRST launch
  of the installed app needs: Control-click Qnet.app in Applications → Open →
  confirm. The installer's final pane says so too.

  On another Mac, macOS may also refuse to open the unsigned .pkg itself by
  double-click. Control-click the .pkg → Open works, as does:
      installer -pkg Qnet-<version>-arm64.pkg -target /

  Distributing this installer properly
  ------------------------------------
  Two separate certificates are involved, and they are not interchangeable:
    • "Developer ID Application" signs Qnet.app
    • "Developer ID Installer"   signs the .pkg
  Both come with a paid Apple Developer account. With them:

    1. codesign --force --deep --options runtime --timestamp \
                --sign "Developer ID Application: NAME (TEAMID)" Qnet.app
    2. ./make_pkg.sh --no-build        # productsign picks the installer cert up
    3. xcrun notarytool submit dist/Qnet-<version>-arm64.pkg \
             --apple-id you@example.com --team-id TEAMID \
             --password <app-specific-password> --wait
    4. xcrun stapler staple dist/Qnet-<version>-arm64.pkg

  After stapling, the .pkg and the app it installs both open on a first
  double-click with no warnings.
NOTES
