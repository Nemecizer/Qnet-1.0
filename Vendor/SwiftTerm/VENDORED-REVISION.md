# Vendored SwiftTerm dependency

- Upstream: <https://github.com/migueldeicaza/SwiftTerm>
- Version: 1.13.0
- Revision: `8e7a1e154f470e19c709a00a8768df348ba5fc43`
- License: MIT; see `LICENSE` in this directory.

Only the SwiftTerm library target and its Metal shader are included. The
upstream examples, benchmarks, tests, and documentation plugins are not Qnet
runtime dependencies and are intentionally omitted.

Qnet carries two source adjustments, both in `MetalTerminalRenderer.swift`.
Shader logic and terminal behaviour are unchanged by either.

1. Resource discovery checks both the SwiftPM command-line layout and the
   standard macOS `Contents/Resources` layout. Integration-only.

2. Two `vertices.withUnsafeBytes { memcpy(...) }` closures discard the memcpy
   result (`_ = memcpy(...)`). `withUnsafeBytes` returns whatever its closure
   returns, and a single-expression closure returns that expression, so
   upstream these hand back an `UnsafeMutableRawPointer` that nothing uses --
   two `result of call to 'withUnsafeBytes' is unused` warnings on every
   `swift build`. Semantically identical; the copy still happens.

   Check whether upstream has fixed this before re-applying at the next
   re-vendor; it is the kind of warning a compiler upgrade surfaces and the
   project then fixes on its own.
