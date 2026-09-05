#!/bin/bash
# Fails if any link in any shipped example network is drawn through the
# body of a node it is not attached to.
#
# Compiles the shipping Sources/Qnet/CanvasGeometry.swift against minimal
# model stubs, builds a real CanvasScene per example at zoom 1, and tests
# each routed polyline — the exact stroke the app draws and hit-tests —
# against every non-endpoint node rectangle.
#
# Usage:  validation/canvas_perf/run_routing_check.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${TMPDIR:-/tmp}/qnet_canvas_routing"

swiftc -O \
    "$here/model_stubs.swift" \
    "$here/bnet_loader.swift" \
    "$root/Sources/Qnet/CanvasGeometry.swift" \
    "$here/routing_check.swift" \
    -o "$out"

"$out" "$root"
