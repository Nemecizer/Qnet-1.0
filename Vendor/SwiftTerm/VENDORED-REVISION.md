# Vendored SwiftTerm dependency

- Upstream: <https://github.com/migueldeicaza/SwiftTerm>
- Version: 1.13.0
- Revision: `8e7a1e154f470e19c709a00a8768df348ba5fc43`
- License: MIT; see `LICENSE` in this directory.

Only the SwiftTerm library target and its Metal shader are included. The
upstream examples, benchmarks, tests, and documentation plugins are not Qnet
runtime dependencies and are intentionally omitted.

Qnet carries one integration-only source adjustment in
`MetalTerminalRenderer.swift`: resource discovery checks both the SwiftPM
command-line layout and the standard macOS `Contents/Resources` layout. Shader
logic and terminal behavior are otherwise unchanged.
