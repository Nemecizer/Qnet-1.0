// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Qnet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Qnet", targets: ["Qnet"])
    ],
    dependencies: [
        // Vendored so a clean `swift run` does not need network access or a
        // pre-populated SwiftPM cache.
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "Qnet",
            dependencies: ["SwiftTerm"]
        )
    ]
)
