import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try makeDirectory(url.deletingLastPathComponent())
    try Data(text.utf8).write(to: url)
    if executable {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}

private let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("qnet-runtime-resolver-\(UUID().uuidString)", isDirectory: true)
try makeDirectory(scratch)
defer { try? FileManager.default.removeItem(at: scratch) }

private let resources = scratch.appendingPathComponent("bundle/Resources", isDirectory: true)
private let bundledBad = resources
    .appendingPathComponent("bin/infinite/TestSolver/probe_solver")
try write(
    "#!/bin/sh\necho 'dyld[123]: Library not loaded: /opt/homebrew/lib/libmissing.dylib' >&2\nexit 134\n",
    to: bundledBad,
    executable: true
)

private let override = scratch.appendingPathComponent("override", isDirectory: true)
private let overrideGood = override
    .appendingPathComponent("infinite/TestSolver/probe_solver")
try write("#!/bin/sh\nexit 64\n", to: overrideGood, executable: true)

private let fallbackResolver = SolverRuntimeResolver(
    environment: ["QNET_SOLVER_ROOT": override.path],
    currentDirectoryURL: scratch,
    bundleResourceURL: resources,
    mainExecutableURL: nil
)
private let fallback = fallbackResolver.resolveExecutable(
    name: "probe_solver",
    subdirectory: "TestSolver",
    groups: ["infinite"],
    probeTimeout: 0.2
)
try require(fallback.url == overrideGood, "broken bundled binary did not fall through to override")
try require(
    fallback.resolution?.provenance == .environmentOverride,
    "override provenance was not retained"
)
try require(
    fallback.attempts.contains(where: { $0.outcome == .loaderRejected }),
    "loader rejection was not recorded"
)

private let project = scratch.appendingPathComponent("project", isDirectory: true)
private let nearbyGood = project
    .appendingPathComponent("Qnet.app/Contents/Resources/bin/infinite/TestSolver/nearby")
private let sourceBad = project.appendingPathComponent("infinite/TestSolver/nearby")
try write("#!/bin/sh\nexit 0\n", to: nearbyGood, executable: true)
try write(
    "#!/bin/sh\necho 'dyld: Library not loaded: libstale.dylib' >&2\nexit 134\n",
    to: sourceBad,
    executable: true
)
private let nested = project.appendingPathComponent("work/deep", isDirectory: true)
try makeDirectory(nested)
private let nearbyResolver = SolverRuntimeResolver(
    environment: [:],
    currentDirectoryURL: nested,
    bundleResourceURL: nil,
    mainExecutableURL: nil
)
private let nearby = nearbyResolver.resolveExecutable(
    name: "nearby",
    subdirectory: "TestSolver",
    groups: ["infinite"],
    probeTimeout: 0.2
)
try require(nearby.url == nearbyGood, "nearby app was not preferred over source tree")
try require(
    nearby.resolution?.provenance == .nearbyAppBundle,
    "nearby app provenance was not retained"
)

private let support = override.appendingPathComponent("finite/Support/tool.py")
try write("print('ok')\n", to: support)
private let supportLookup = fallbackResolver.resolveSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"]
)
try require(supportLookup.url == support, "readable support file was not resolved")
try require(
    supportLookup.resolution?.runtimeExecutableURL == nil,
    "generic support lookup unexpectedly required a runtime executable"
)

private let pythonBin = scratch.appendingPathComponent("python-bin", isDirectory: true)
private let goodPython = pythonBin.appendingPathComponent("qnet-python-good")
try write(
    "#!/bin/sh\necho \"$0 (Python test runtime)\"\nexit 0\n",
    to: goodPython,
    executable: true
)
private let pythonResolver = SolverRuntimeResolver(
    environment: [
        "QNET_SOLVER_ROOT": override.path,
        "PATH": pythonBin.path,
    ],
    currentDirectoryURL: scratch,
    bundleResourceURL: nil,
    mainExecutableURL: nil
)
private let pythonLookup = pythonResolver.resolvePythonSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"],
    requiredModules: ["numpy", "numpy", " "],
    interpreterName: "qnet-python-good",
    probeTimeout: 0.2
)
try require(pythonLookup.url == support, "Python support file was not resolved")
try require(
    pythonLookup.resolution?.runtimeExecutableURL == goodPython,
    "Python interpreter provenance was not retained"
)
try require(
    pythonLookup.resolution?.probeDetail.contains("imported modules: numpy") == true,
    "Python module preflight was not recorded"
)
try require(
    pythonLookup.resolution?.provenanceDescription.contains(goodPython.path) == true,
    "Python interpreter path was absent from provenance"
)

private var realPythonEnvironment = ProcessInfo.processInfo.environment
realPythonEnvironment["QNET_SOLVER_ROOT"] = override.path
private let realPythonResolver = SolverRuntimeResolver(
    environment: realPythonEnvironment,
    currentDirectoryURL: scratch,
    bundleResourceURL: nil,
    mainExecutableURL: nil
)
private let realPythonLookup = realPythonResolver.resolvePythonSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"],
    requiredModules: ["json"],
    probeTimeout: 2.0
)
try require(realPythonLookup.url == support, "real Python preflight failed")
try require(
    realPythonLookup.resolution?.runtimeExecutableURL != nil,
    "real Python preflight did not retain its interpreter"
)

private let missingPython = pythonResolver.resolvePythonSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"],
    interpreterName: "qnet-python-missing",
    probeTimeout: 0.2
)
try require(missingPython.url == nil, "missing Python interpreter unexpectedly resolved")
try require(
    missingPython.actionableDiagnostic.contains("Python runtime 'qnet-python-missing' was not found"),
    "missing Python interpreter diagnostic was not actionable"
)
try require(
    missingPython.attempts.contains(where: { $0.outcome == .runtimeUnavailable }),
    "missing Python runtime was not classified"
)

private let dependencyPython = pythonBin.appendingPathComponent("qnet-python-no-module")
try write(
    "#!/bin/sh\necho \"ModuleNotFoundError: No module named 'numpy'\" >&2\nexit 1\n",
    to: dependencyPython,
    executable: true
)
private let dependencyLookup = pythonResolver.resolvePythonSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"],
    requiredModules: ["numpy"],
    interpreterName: "qnet-python-no-module",
    probeTimeout: 0.2
)
try require(dependencyLookup.url == nil, "missing Python module unexpectedly resolved")
try require(
    dependencyLookup.actionableDiagnostic.contains("No module named 'numpy'"),
    "missing Python module diagnostic omitted the import error"
)

private let hangingPython = pythonBin.appendingPathComponent("qnet-python-hangs")
try write(
    "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n",
    to: hangingPython,
    executable: true
)
private let timeoutStart = ProcessInfo.processInfo.systemUptime
private let timeoutLookup = pythonResolver.resolvePythonSupportFile(
    name: "tool.py",
    subdirectory: "Support",
    groups: ["finite"],
    interpreterName: "qnet-python-hangs",
    probeTimeout: 0.1
)
private let timeoutElapsed = ProcessInfo.processInfo.systemUptime - timeoutStart
try require(timeoutLookup.url == nil, "timed-out Python preflight unexpectedly resolved")
try require(
    timeoutLookup.actionableDiagnostic.contains("timed out"),
    "Python timeout diagnostic was not surfaced"
)
try require(timeoutElapsed < 1.25, "Python timeout probe exceeded its bound")

private let manifest = resources.appendingPathComponent("solver-runtime-status-v1.tsv")
try write(
    "QNET_SOLVER_RUNTIME_V1\nunavailable\texecutable\tinfinite/multiclass_diffusion/mc_solver\trequires research dependencies\n",
    to: manifest
)
private let unavailableResolver = SolverRuntimeResolver(
    environment: [:],
    currentDirectoryURL: scratch,
    bundleResourceURL: resources,
    mainExecutableURL: nil
)
private let unavailable = unavailableResolver.resolveExecutable(
    name: "mc_solver",
    subdirectory: "multiclass_diffusion",
    groups: ["infinite"],
    probeTimeout: 0.2
)
try require(unavailable.url == nil, "unavailable solver unexpectedly resolved")
try require(
    unavailable.declaredUnavailableReason == "requires research dependencies",
    "unavailable manifest reason was not surfaced"
)

print("SolverRuntimeResolver checks passed.")
