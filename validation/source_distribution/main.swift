import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

require(CommandLine.arguments.count == 2, "Supply the distribution root")
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resolver = SolverRuntimeResolver(
    environment: [:],
    currentDirectoryURL: root,
    bundleResourceURL: nil,
    mainExecutableURL: root.appendingPathComponent(".build/debug/Qnet")
)
let inventory = try String(
    contentsOf: root.appendingPathComponent("validation/required_release_executables.txt"),
    encoding: .utf8
)
var checked = 0
for raw in inventory.split(separator: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let parts = line.split(separator: "/").map(String.init)
    require(parts.count == 3, "Unexpected inventory entry: \(line)")
    let lookup = resolver.resolveExecutable(
        name: parts[2], subdirectory: parts[1], groups: [parts[0]]
    )
    require(lookup.resolution?.provenance == .nearbyAppBundle,
            "Source launch did not select the packaged solver: \(lookup.actionableDiagnostic)")
    checked += 1
}
let resourceRoots = [
    root.appendingPathComponent("Qnet.app/Contents/Resources"),
    root.appendingPathComponent(".build/debug")
]
for resourceRoot in resourceRoots {
    let url = resourceRoot.appendingPathComponent("SwiftTerm_SwiftTerm.bundle")
    guard let bundle = Bundle(url: url),
          let shader = bundle.url(forResource: "Shaders", withExtension: "metal") else {
        fatalError("Shader is not discoverable as a Foundation bundle: \(url.path)")
    }
    require(FileManager.default.isReadableFile(atPath: shader.path), "Shader unreadable")
}
print("Source distribution: \(checked) packaged executables resolved without an environment override; app/debug shader bundles discoverable.")
