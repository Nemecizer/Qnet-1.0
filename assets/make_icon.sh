#!/usr/bin/env bash
#
# make_icon.sh — regenerates the Qnet app icons from make_icon.swift.
#
# WHAT THE APP ACTUALLY SHIPS: one appearance.
#
# `build_app.sh` copies `assets/AppIcon.icns` into Resources/ and the
# Info.plist names it with CFBundleIconFile. An .icns file cannot carry
# light / dark / tinted variants at all — that needs an asset catalog
# compiled by `actool` into Resources/Assets.car plus CFBundleIconName, and
# the SwiftPM bundle has no asset catalog. So Qnet has ONE app-icon
# appearance, and the blue plate is designed to sit correctly on both a
# light and a dark Dock rather than to be swapped for a dark variant.
#
# The dark and tinted renders are therefore REFERENCE ARTEFACTS, not
# shipping ones. They exist so a designer can see what the motif looks like
# under the other two appearances (and because the tinted mask is the best
# check that the motif carries its structure without colour), and so that
# adopting an asset catalog later is a build change rather than a design
# one. Nothing in the product reads them, so they are gitignored and only
# rendered on request:
#
#   ./make_icon.sh                writes assets/AppIcon.icns — SHIPPING, the
#                                 one artefact build_app.sh bundles; nothing else.
#   ./make_icon.sh --reference    also writes the reference renders:
#     assets/AppIcon-dark.icns      the motif on the dark plate.
#     assets/AppIcon-tinted.icns    the monochrome mask.
#     assets/AppIcon.appiconset/    a ready-made `actool` input carrying all
#                                   three appearances, for the day someone
#                                   wires up an asset catalog.
#   ./make_icon.sh [--reference] <dir>   additionally keeps the individual
#                                 light PNGs in <dir> (handy for eyeballing
#                                 the 16 / 32 / 128 px results).
#
# Pipeline, per appearance:
#   1. make_icon <px> <out.png> --appearance <a>   once per iconset slot —
#      the script draws a size-appropriate design (see the tiers documented
#      at the top of make_icon.swift) instead of downscaling a single master.
#      Each render prints the motif's pixel bounding box and its fill
#      against the 80 % safe area, and exits 5 if the motif leaves the safe
#      area or 6 if it fills less than 55 % of it in either axis — which
#      aborts this script (set -e). Both claims are checked, not assumed:
#      "inside the safe area" used to pass for a motif that was a 5-px band
#      across an empty 16-px plate.
#
#      Add --preview to a single render to print an ASCII map of the result
#      and eyeball the small tiers without opening an image editor.
#   2. iconutil -c icns ...                        pack into the .icns
#
#   Every render at ≥ 256 px also measures the queue bars and the two
#   arrowhead gaps back from the pixels and exits 7 if they disagree with
#   the layout (see make_icon.swift).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REFERENCE=0
KEEP_DIR=""
for arg in "$@"; do
    case "$arg" in
        --reference) REFERENCE=1 ;;
        -h|--help)
            echo "usage: make_icon.sh [--reference] [keep-dir]" >&2
            exit 64 ;;
        *) KEEP_DIR="$arg" ;;
    esac
done
if [[ -n "$KEEP_DIR" ]]; then
    mkdir -p "$KEEP_DIR"
fi

# Compile once so the thirty renders don't each pay the interpreter start-up.
echo "==> Compiling make_icon.swift…"
swiftc -O -o "$WORK/make_icon" make_icon.swift

# Apple's required iconset slots (pixels:logical:filename).
declare -a SIZES=(
    "16:16:icon_16x16.png"
    "32:16:icon_16x16@2x.png"
    "32:32:icon_32x32.png"
    "64:32:icon_32x32@2x.png"
    "128:128:icon_128x128.png"
    "256:128:icon_128x128@2x.png"
    "256:256:icon_256x256.png"
    "512:256:icon_256x256@2x.png"
    "512:512:icon_512x512.png"
    "1024:512:icon_512x512@2x.png"
)

# render <appearance> <output.icns> [keep]
render_appearance() {
    local appearance="$1" out="$2" keep="${3:-}"
    local iconset="$WORK/$appearance.iconset"
    mkdir -p "$iconset"

    echo "==> Rendering '$appearance' iconset (motif bbox vs. 80 % safe area)…"
    for spec in "${SIZES[@]}"; do
        IFS=":" read -r px _logical name <<< "$spec"
        "$WORK/make_icon" "$px" "$iconset/$name" --appearance "$appearance"
        if [[ -n "$keep" ]]; then
            cp "$iconset/$name" "$keep/$name"
        fi
    done

    echo "==> Packing $(basename "$out")…"
    iconutil -c icns "$iconset" -o "$out"
}

render_appearance light  "$SCRIPT_DIR/AppIcon.icns" "$KEEP_DIR"

if [[ $REFERENCE -eq 0 ]]; then
    ls -la "$SCRIPT_DIR"/AppIcon.icns
    echo
    echo "Shipping artefact: AppIcon.icns. Run with --reference for the dark and"
    echo "tinted renders and the appiconset (gitignored; nothing in the build reads them)."
    echo "Done."
    exit 0
fi

render_appearance dark   "$SCRIPT_DIR/AppIcon-dark.icns"
render_appearance tinted "$SCRIPT_DIR/AppIcon-tinted.icns"

# ── Asset catalog carrying all three appearances ─────────────────────────
# Reference artefact, gitignored, consumed by nothing — see the header. It
# is written with --reference so that "adopt an asset catalog" is a
# build_app.sh change (run actool over this folder into Resources/Assets.car
# and set CFBundleIconName) rather than a design change.
SET="$SCRIPT_DIR/AppIcon.appiconset"
rm -rf "$SET"
mkdir -p "$SET"

emit_catalog_entry() {
    local appearance="$1" suffix="$2"
    for spec in "${SIZES[@]}"; do
        IFS=":" read -r px logical name <<< "$spec"
        cp "$WORK/$appearance.iconset/$name" "$SET/${suffix}${name}"
    done
}
emit_catalog_entry light  ""
emit_catalog_entry dark   "dark_"
emit_catalog_entry tinted "tinted_"

{
    echo '{'
    echo '  "images" : ['
    first=1
    for appearance in light dark tinted; do
        case "$appearance" in
            light)  prefix=""       ; appearance_json="" ;;
            dark)   prefix="dark_"  ; appearance_json='"appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], ' ;;
            tinted) prefix="tinted_"; appearance_json='"appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], ' ;;
        esac
        for spec in "${SIZES[@]}"; do
            IFS=":" read -r px logical name <<< "$spec"
            scale=$(( px / logical ))
            [[ $first -eq 0 ]] && echo '    },'
            first=0
            echo '    {'
            printf '      %s"filename" : "%s%s",\n' "$appearance_json" "$prefix" "$name"
            echo '      "idiom" : "mac",'
            printf '      "scale" : "%dx",\n' "$scale"
            printf '      "size" : "%dx%d"\n' "$logical" "$logical"
        done
    done
    echo '    }'
    echo '  ],'
    echo '  "info" : { "author" : "make_icon.sh", "version" : 1 }'
    echo '}'
} > "$SET/Contents.json"

ls -la "$SCRIPT_DIR"/AppIcon*.icns
echo "Asset catalog: $SET  (reference only — nothing in the build reads it)"
echo
echo "Shipping artefact: AppIcon.icns.  AppIcon-dark.icns, AppIcon-tinted.icns"
echo "and the appiconset are reference renders (gitignored); an .icns cannot"
echo "carry appearance variants and the bundle has no asset catalog."
echo "Done."
