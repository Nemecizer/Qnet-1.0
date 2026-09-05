#!/bin/bash
# Times the canvas layers' per-frame work on a large network.
#
# Compiles the shipping Sources/Qnet/CanvasGeometry.swift against minimal
# model stubs, so the numbers are the real link router, the real hit
# tester and a faithful copy of GridCanvas's path builder — no SwiftUI
# compositing, no window, no human hand needed.  The reference numbers
# live in the CanvasProfiler doc comment in CanvasGeometry.swift; this is
# how to reproduce them.
#
# For an end-to-end check inside the running app instead, open a large
# network and launch with QNET_CANVAS_PROFILE=1, which prints the same
# two layers' ms/frame every 60 frames while you drag / pan / zoom.
#
# Usage:  validation/canvas_perf/run_canvas_bench.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${TMPDIR:-/tmp}/qnet_canvas_bench"

swiftc -O \
    "$here/model_stubs.swift" \
    "$here/bnet_loader.swift" \
    "$root/Sources/Qnet/CanvasGeometry.swift" \
    "$here/main.swift" \
    -o "$out"

"$out" "$root"
