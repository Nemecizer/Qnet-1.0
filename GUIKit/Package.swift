// swift-tools-version: 6.2

import PackageDescription

// GUIKit — the Qnet GUI framework, extracted so a new macOS SwiftUI app can
// inherit its look, feel and enforcement on day one.
//
// Two ways to use it, and the first is the one it was designed for:
//
//   1. COPY `Sources/GUIKit/*.swift` into your own app target. Everything is
//      `internal`, which is exactly right inside one module — no annotation
//      churn, no access-control rework, nothing to re-export. This is the
//      "minimal rework" path described in GUI.md.
//
//   2. Depend on it as a package. Then the symbols your app touches need
//      `public`; see GUI.md § "Using GUIKit as a package dependency".
//
// This manifest exists mainly so the kit can be COMPILED ON ITS OWN, which is
// how it is verified: a framework that has never been built apart from its
// parent app is a claim, not a component.
let package = Package(
    name: "GUIKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GUIKit", targets: ["GUIKit"])
    ],
    targets: [
        .target(name: "GUIKit", path: "Sources/GUIKit")
    ]
)
