import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Where a solver/support-file candidate came from.  Keeping this with each
/// resolution makes run provenance explicit instead of hiding path selection
/// inside the GUI command builder.
enum SolverRuntimeProvenance: String, Codable, Sendable {
    case bundledResources = "bundled app resources"
    case environmentOverride = "QNET_SOLVER_ROOT"
    case nearbyAppBundle = "nearby Qnet.app"
    case sourceTree = "development source tree"
}

struct SolverRuntimeAttempt: Sendable {
    enum Outcome: String, Sendable {
        case notFound = "not found"
        case notExecutable = "not executable"
        case notReadable = "not readable"
        case loaderRejected = "dynamic loader rejected"
        case runtimeUnavailable = "runtime unavailable"
        case selected = "selected"
    }

    let url: URL
    let provenance: SolverRuntimeProvenance
    let outcome: Outcome
    let detail: String
}

struct SolverRuntimeResolution: Sendable {
    let url: URL
    let provenance: SolverRuntimeProvenance
    let probeDetail: String
    /// Interpreter used for script-backed solvers. Native executables and
    /// generic support-file lookups leave this nil.
    let runtimeExecutableURL: URL?

    init(
        url: URL,
        provenance: SolverRuntimeProvenance,
        probeDetail: String,
        runtimeExecutableURL: URL? = nil
    ) {
        self.url = url
        self.provenance = provenance
        self.probeDetail = probeDetail
        self.runtimeExecutableURL = runtimeExecutableURL
    }

    /// Stable, human-readable value suitable for result provenance.
    var provenanceDescription: String {
        var description = "\(provenance.rawValue): \(url.path)"
        if let runtimeExecutableURL {
            description += "; Python runtime: \(runtimeExecutableURL.path)"
        }
        return description
    }
}

struct SolverRuntimeLookup: Sendable {
    let requestedName: String
    let requestedSubdirectory: String
    let resolution: SolverRuntimeResolution?
    let attempts: [SolverRuntimeAttempt]
    let declaredUnavailableReason: String?

    var url: URL? { resolution?.url }

    /// A diagnostic intended for an alert/status pane.  It names the selected
    /// override contract and surfaces the loader's missing-library message.
    var actionableDiagnostic: String {
        if let resolution {
            return "Using \(resolution.provenanceDescription). \(resolution.probeDetail)"
        }

        var lines = [
            "No loadable copy of \(requestedName) was found for \(requestedSubdirectory)."
        ]
        if let declaredUnavailableReason {
            lines.append("This app build declares the solver unavailable: \(declaredUnavailableReason)")
        }

        let useful = attempts.filter { $0.outcome != .notFound }
        if useful.isEmpty {
            lines.append("Searched the app bundle, QNET_SOLVER_ROOT, a nearby Qnet.app, and the development source tree.")
        } else {
            lines.append("Candidates checked:")
            for attempt in useful.prefix(8) {
                lines.append("• \(attempt.url.path) [\(attempt.provenance.rawValue)]: \(attempt.detail)")
            }
        }
        if useful.contains(where: { $0.outcome == .runtimeUnavailable }) {
            lines.append("Install a usable Python 3 runtime and any named modules, then relaunch Qnet.")
        }
        lines.append("Rebuild Qnet.app to bundle its libraries, or point QNET_SOLVER_ROOT at a verified Qnet solver tree.")
        return lines.joined(separator: "\n")
    }
}

/// The interpreter selected by the same ordered preflight used for
/// Python-backed solver scripts.  Startup diagnostics use this directly so
/// they can check Python itself (and optional modules) without pretending a
/// particular solver file is part of the package check.
struct PythonRuntimeResolution: Sendable {
    let executableURL: URL
    let probeDetail: String
}

struct PythonRuntimeAttempt: Sendable {
    let executableURL: URL
    let loadable: Bool
    let detail: String
}

struct PythonRuntimeLookup: Sendable {
    let interpreterName: String
    let requiredModules: [String]
    let resolution: PythonRuntimeResolution?
    let attempts: [PythonRuntimeAttempt]

    var actionableDiagnostic: String {
        if let resolution {
            return resolution.probeDetail
        }
        if attempts.isEmpty {
            return "Python runtime '\(interpreterName)' was not found in PATH or a standard installation location"
        }
        let dependency = requiredModules.isEmpty
            ? "Python interpreter preflight failed"
            : "Python preflight could not import required module(s) \(requiredModules.joined(separator: ", "))"
        let failures = attempts.prefix(4).map { attempt in
            "\(attempt.executableURL.path): \(attempt.detail)"
        }
        return "\(dependency). \(failures.joined(separator: "; "))"
    }
}

/// Resolves all external analysis programs through one ordered, auditable
/// policy.  Executables receive a short real launch probe.  A file that has
/// `+x` but fails in dyld is therefore skipped in favor of the next candidate.
final class SolverRuntimeResolver: @unchecked Sendable {
    static let shared = SolverRuntimeResolver()

    private struct RuntimeRoot {
        let url: URL
        let provenance: SolverRuntimeProvenance
    }

    private struct ProbeResult: Sendable {
        let loadable: Bool
        let detail: String
    }

    private struct CachedProbe {
        let size: UInt64
        let modificationTime: TimeInterval
        let result: ProbeResult
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let bundleResourceURL: URL?
    private let mainExecutableURL: URL?
    private let cacheLock = NSLock()
    private var probeCache: [String: CachedProbe] = [:]
    private var pythonProbeCache: [String: CachedProbe] = [:]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = nil,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        mainExecutableURL: URL? = Bundle.main.executableURL
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        self.bundleResourceURL = bundleResourceURL
        self.mainExecutableURL = mainExecutableURL
    }

    func resolveExecutable(
        name: String,
        subdirectory: String,
        groups: [String] = ["finite", "infinite"],
        probeTimeout: TimeInterval = 0.8
    ) -> SolverRuntimeLookup {
        var attempts: [SolverRuntimeAttempt] = []
        let roots = runtimeRoots()

        for candidate in candidates(
            roots: roots,
            name: name,
            subdirectory: subdirectory,
            groups: groups
        ) {
            guard fileManager.fileExists(atPath: candidate.url.path) else {
                attempts.append(SolverRuntimeAttempt(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    outcome: .notFound,
                    detail: SolverRuntimeAttempt.Outcome.notFound.rawValue
                ))
                continue
            }
            guard fileManager.isExecutableFile(atPath: candidate.url.path) else {
                attempts.append(SolverRuntimeAttempt(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    outcome: .notExecutable,
                    detail: "the file exists but lacks execute permission"
                ))
                continue
            }

            let probe = cachedProbe(candidate.url, timeout: probeTimeout)
            guard probe.loadable else {
                attempts.append(SolverRuntimeAttempt(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    outcome: .loaderRejected,
                    detail: probe.detail
                ))
                continue
            }

            attempts.append(SolverRuntimeAttempt(
                url: candidate.url,
                provenance: candidate.provenance,
                outcome: .selected,
                detail: probe.detail
            ))
            return SolverRuntimeLookup(
                requestedName: name,
                requestedSubdirectory: subdirectory,
                resolution: SolverRuntimeResolution(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    probeDetail: probe.detail
                ),
                attempts: attempts,
                declaredUnavailableReason: nil
            )
        }

        return SolverRuntimeLookup(
            requestedName: name,
            requestedSubdirectory: subdirectory,
            resolution: nil,
            attempts: attempts,
            declaredUnavailableReason: unavailableReason(
                roots: roots,
                name: name,
                subdirectory: subdirectory,
                groups: groups
            )
        )
    }

    func resolveSupportFile(
        name: String,
        subdirectory: String,
        groups: [String] = ["finite", "infinite"]
    ) -> SolverRuntimeLookup {
        var attempts: [SolverRuntimeAttempt] = []
        let roots = runtimeRoots()

        for candidate in candidates(
            roots: roots,
            name: name,
            subdirectory: subdirectory,
            groups: groups
        ) {
            guard fileManager.fileExists(atPath: candidate.url.path) else {
                attempts.append(SolverRuntimeAttempt(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    outcome: .notFound,
                    detail: SolverRuntimeAttempt.Outcome.notFound.rawValue
                ))
                continue
            }
            guard fileManager.isReadableFile(atPath: candidate.url.path) else {
                attempts.append(SolverRuntimeAttempt(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    outcome: .notReadable,
                    detail: "the file exists but is not readable"
                ))
                continue
            }

            let detail = "support file is readable"
            attempts.append(SolverRuntimeAttempt(
                url: candidate.url,
                provenance: candidate.provenance,
                outcome: .selected,
                detail: detail
            ))
            return SolverRuntimeLookup(
                requestedName: name,
                requestedSubdirectory: subdirectory,
                resolution: SolverRuntimeResolution(
                    url: candidate.url,
                    provenance: candidate.provenance,
                    probeDetail: detail
                ),
                attempts: attempts,
                declaredUnavailableReason: nil
            )
        }

        return SolverRuntimeLookup(
            requestedName: name,
            requestedSubdirectory: subdirectory,
            resolution: nil,
            attempts: attempts,
            declaredUnavailableReason: unavailableReason(
                roots: roots,
                name: name,
                subdirectory: subdirectory,
                groups: groups
            )
        )
    }

    /// Resolves a usable Python interpreter independently of any one support
    /// file.  Module checks deliberately search every interpreter candidate:
    /// a Finder-launched app may see Apple's Python first while NumPy lives in
    /// Homebrew's Python, and selecting the first executable alone would
    /// report a false failure.
    func resolvePythonRuntime(
        requiredModules: [String] = [],
        interpreterName: String = "python3",
        probeTimeout: TimeInterval = 2.0
    ) -> PythonRuntimeLookup {
        let modules = normalizedModuleNames(requiredModules)
        let interpreters = executableCandidates(named: interpreterName)
        var attempts: [PythonRuntimeAttempt] = []

        for interpreter in interpreters {
            let probe = cachedPythonProbe(
                interpreter,
                requiredModules: modules,
                timeout: max(0.1, probeTimeout)
            )
            attempts.append(PythonRuntimeAttempt(
                executableURL: interpreter,
                loadable: probe.loadable,
                detail: probe.detail
            ))
            if probe.loadable {
                return PythonRuntimeLookup(
                    interpreterName: interpreterName,
                    requiredModules: modules,
                    resolution: PythonRuntimeResolution(
                        executableURL: interpreter,
                        probeDetail: probe.detail
                    ),
                    attempts: attempts
                )
            }
        }

        return PythonRuntimeLookup(
            interpreterName: interpreterName,
            requiredModules: modules,
            resolution: nil,
            attempts: attempts
        )
    }

    /// Resolves a Python-backed solver and verifies the interpreter contract
    /// before exposing it to the GUI. The generic `resolveSupportFile` API is
    /// intentionally unchanged for non-Python resources.
    ///
    /// Callers should launch `resolution.runtimeExecutableURL` directly with
    /// `-B`, followed by the returned script URL and its solver arguments. The
    /// explicit interpreter path keeps execution consistent with this probe;
    /// `-B` prevents Python from writing bytecode into a signed app bundle.
    func resolvePythonSupportFile(
        name: String,
        subdirectory: String,
        groups: [String] = ["finite", "infinite"],
        requiredModules: [String] = [],
        interpreterName: String = "python3",
        probeTimeout: TimeInterval = 2.0
    ) -> SolverRuntimeLookup {
        let supportLookup = resolveSupportFile(
            name: name,
            subdirectory: subdirectory,
            groups: groups
        )
        guard let supportResolution = supportLookup.resolution else {
            return supportLookup
        }

        let runtimeLookup = resolvePythonRuntime(
            requiredModules: requiredModules,
            interpreterName: interpreterName,
            probeTimeout: probeTimeout
        )
        guard let runtime = runtimeLookup.resolution else {
            return pythonRuntimeFailure(
                supportLookup,
                detail: runtimeLookup.actionableDiagnostic
            )
        }

        let moduleDetail = runtimeLookup.requiredModules.isEmpty
            ? "no optional modules required"
            : "imported modules: \(runtimeLookup.requiredModules.joined(separator: ", "))"
        return SolverRuntimeLookup(
            requestedName: supportLookup.requestedName,
            requestedSubdirectory: supportLookup.requestedSubdirectory,
            resolution: SolverRuntimeResolution(
                url: supportResolution.url,
                provenance: supportResolution.provenance,
                probeDetail: "support file is readable; \(runtime.probeDetail); \(moduleDetail)",
                runtimeExecutableURL: runtime.executableURL
            ),
            attempts: supportLookup.attempts,
            declaredUnavailableReason: supportLookup.declaredUnavailableReason
        )
    }

    private func pythonRuntimeFailure(
        _ supportLookup: SolverRuntimeLookup,
        detail: String
    ) -> SolverRuntimeLookup {
        let attempts = supportLookup.attempts.map { attempt in
            guard attempt.outcome == .selected else { return attempt }
            return SolverRuntimeAttempt(
                url: attempt.url,
                provenance: attempt.provenance,
                outcome: .runtimeUnavailable,
                detail: detail
            )
        }
        return SolverRuntimeLookup(
            requestedName: supportLookup.requestedName,
            requestedSubdirectory: supportLookup.requestedSubdirectory,
            resolution: nil,
            attempts: attempts,
            declaredUnavailableReason: supportLookup.declaredUnavailableReason
        )
    }

    private func normalizedModuleNames(_ rawNames: [String]) -> [String] {
        var seen: Set<String> = []
        return rawNames.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private func executableCandidates(named rawName: String) -> [URL] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }

        var candidates: [URL] = []
        if name.contains("/") {
            let explicit = name.hasPrefix("/")
                ? URL(fileURLWithPath: name, isDirectory: false)
                : currentDirectoryURL.appendingPathComponent(name, isDirectory: false)
            candidates.append(explicit)
        } else {
            let searchPath = environment["PATH"] ?? ""
            for component in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
                let directory = component.isEmpty
                    ? currentDirectoryURL
                    : URL(fileURLWithPath: String(component), isDirectory: true)
                candidates.append(directory.appendingPathComponent(name, isDirectory: false))
            }
            if name == "python3" {
                candidates.append(URL(fileURLWithPath: "/usr/bin/python3"))
                candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/python3"))
                candidates.append(URL(fileURLWithPath: "/usr/local/bin/python3"))
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  fileManager.isExecutableFile(atPath: standardized.path)
            else { return nil }
            return standardized
        }
    }

    // MARK: - Candidate roots

    private func runtimeRoots() -> [RuntimeRoot] {
        var roots: [RuntimeRoot] = []

        // A packaged app must be self-contained and is always authoritative.
        if let resourceURL = bundleResourceURL {
            appendRoot(
                resourceURL.appendingPathComponent("bin", isDirectory: true),
                provenance: .bundledResources,
                to: &roots
            )
        }

        // The override accepts either a project root, Resources/bin, or an
        // app bundle path.  All normalized forms retain override provenance.
        if let raw = environment["QNET_SOLVER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let override = URL(fileURLWithPath: raw, isDirectory: true)
            if override.pathExtension == "app" {
                appendRoot(
                    override.appendingPathComponent("Contents/Resources/bin", isDirectory: true),
                    provenance: .environmentOverride,
                    to: &roots
                )
            }
            appendRoot(override, provenance: .environmentOverride, to: &roots)
            appendRoot(
                override.appendingPathComponent("bin", isDirectory: true),
                provenance: .environmentOverride,
                to: &roots
            )
            appendRoot(
                override.appendingPathComponent("Contents/Resources/bin", isDirectory: true),
                provenance: .environmentOverride,
                to: &roots
            )
        }

        // `swift run` commonly executes beside a previously verified release
        // bundle.  Prefer that bundle over unrelocated source-tree binaries.
        for anchor in searchAnchors() {
            for ancestor in ancestors(of: anchor, limit: 7) {
                appendRoot(
                    ancestor.appendingPathComponent(
                        "Qnet.app/Contents/Resources/bin", isDirectory: true
                    ),
                    provenance: .nearbyAppBundle,
                    to: &roots
                )
            }
        }

        // Source binaries are last because their absolute Homebrew links may
        // no longer match the current machine even while the +x bit remains.
        for anchor in searchAnchors() {
            for ancestor in ancestors(of: anchor, limit: 7) {
                appendRoot(ancestor, provenance: .sourceTree, to: &roots)
            }
        }

        var seen: Set<String> = []
        return roots.filter { root in
            let key = "\(root.provenance.rawValue)|\(root.url.standardizedFileURL.path)"
            return seen.insert(key).inserted
        }
    }

    private func searchAnchors() -> [URL] {
        var values = [currentDirectoryURL]
        if let executable = mainExecutableURL {
            values.append(executable.deletingLastPathComponent())
        }
        var seen: Set<String> = []
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func ancestors(of start: URL, limit: Int) -> [URL] {
        var result: [URL] = []
        var current = start.standardizedFileURL
        for _ in 0..<limit {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }

    private func appendRoot(
        _ url: URL,
        provenance: SolverRuntimeProvenance,
        to roots: inout [RuntimeRoot]
    ) {
        roots.append(RuntimeRoot(url: url.standardizedFileURL, provenance: provenance))
    }

    private func candidates(
        roots: [RuntimeRoot],
        name: String,
        subdirectory: String,
        groups: [String]
    ) -> [RuntimeRoot] {
        var values: [RuntimeRoot] = []
        var seen: Set<String> = []
        for root in roots {
            for group in groups {
                let candidate = root.url
                    .appendingPathComponent(group, isDirectory: true)
                    .appendingPathComponent(subdirectory, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .standardizedFileURL
                let key = "\(root.provenance.rawValue)|\(candidate.path)"
                if seen.insert(key).inserted {
                    values.append(RuntimeRoot(url: candidate, provenance: root.provenance))
                }
            }
            let direct = root.url
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL
            let key = "\(root.provenance.rawValue)|\(direct.path)"
            if seen.insert(key).inserted {
                values.append(RuntimeRoot(url: direct, provenance: root.provenance))
            }
        }
        return values
    }

    // MARK: - Loader probe

    private func cachedProbe(_ url: URL, timeout: TimeInterval) -> ProbeResult {
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = url.standardizedFileURL.path

        cacheLock.lock()
        if let cached = probeCache[key],
           cached.size == size,
           cached.modificationTime == modificationTime {
            cacheLock.unlock()
            return cached.result
        }
        cacheLock.unlock()

        let result = launchProbe(url, timeout: max(0.1, timeout))
        cacheLock.lock()
        probeCache[key] = CachedProbe(
            size: size,
            modificationTime: modificationTime,
            result: result
        )
        cacheLock.unlock()
        return result
    }

    private func cachedPythonProbe(
        _ interpreter: URL,
        requiredModules: [String],
        timeout: TimeInterval
    ) -> ProbeResult {
        let attributes = (try? fileManager.attributesOfItem(atPath: interpreter.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let moduleKey = requiredModules.joined(separator: "\u{1f}")
        let key = "\(interpreter.standardizedFileURL.path)|\(moduleKey)|\(String(format: "%.6f", timeout))"

        cacheLock.lock()
        if let cached = pythonProbeCache[key],
           cached.size == size,
           cached.modificationTime == modificationTime {
            cacheLock.unlock()
            return cached.result
        }
        cacheLock.unlock()

        let result = launchPythonProbe(
            interpreter,
            requiredModules: requiredModules,
            timeout: timeout
        )
        cacheLock.lock()
        pythonProbeCache[key] = CachedProbe(
            size: size,
            modificationTime: modificationTime,
            result: result
        )
        cacheLock.unlock()
        return result
    }

    private func launchPythonProbe(
        _ interpreter: URL,
        requiredModules: [String],
        timeout: TimeInterval
    ) -> ProbeResult {
        let token = UUID().uuidString
        let stdoutURL = fileManager.temporaryDirectory
            .appendingPathComponent("qnet-python-probe-\(token).out")
        let stderrURL = fileManager.temporaryDirectory
            .appendingPathComponent("qnet-python-probe-\(token).err")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil) else {
            return ProbeResult(
                loadable: false,
                detail: "could not create temporary files for the Python preflight"
            )
        }
        guard fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            try? fileManager.removeItem(at: stdoutURL)
            return ProbeResult(
                loadable: false,
                detail: "could not create temporary files for the Python preflight"
            )
        }
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return ProbeResult(
                loadable: false,
                detail: "could not open Python preflight output: \(error.localizedDescription)"
            )
        }

        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = interpreter
        process.arguments = [
            "-B",
            "-c",
            "import importlib, sys; "
                + "[importlib.import_module(name) for name in sys.argv[1:]]; "
                + "print(f'{sys.executable} (Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro})')"
        ] + requiredModules
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.currentDirectoryURL = currentDirectoryURL
        var probeEnvironment = environment
        probeEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = probeEnvironment
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            return ProbeResult(
                loadable: false,
                detail: "could not launch \(interpreter.path): \(error.localizedDescription)"
            )
        }

        var timedOut = false
        var terminated = true
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) == .timedOut {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                if completed.wait(timeout: .now() + 0.2) == .timedOut {
                    terminated = false
                }
            }
        }

        stdoutHandle.closeFile()
        stderrHandle.closeFile()
        let stdout = ((try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = ((try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if timedOut {
            let suffix = terminated ? "" : "; process did not terminate promptly after SIGKILL"
            return ProbeResult(
                loadable: false,
                detail: "Python preflight timed out after \(String(format: "%.2f", timeout)) seconds\(suffix)"
            )
        }

        let status = process.terminationStatus
        guard status == 0 else {
            let rawMessage = stderr.isEmpty ? stdout : stderr
            let compact = compactProbeMessage(rawMessage)
            let suffix = compact.isEmpty ? "" : ": \(compact)"
            return ProbeResult(
                loadable: false,
                detail: "Python preflight exited with status \(status)\(suffix)"
            )
        }

        return ProbeResult(
            loadable: true,
            detail: stdout.isEmpty
                ? "Python preflight passed with \(interpreter.path)"
                : "Python preflight passed with \(compactProbeMessage(stdout))"
        )
    }

    private func compactProbeMessage(_ message: String) -> String {
        String(
            message
                .split(whereSeparator: \Character.isNewline)
                .prefix(8)
                .joined(separator: " ")
                .prefix(800)
        )
    }

    private func launchProbe(_ url: URL, timeout: TimeInterval) -> ProbeResult {
        let process = Process()
        let stderr = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = url
        process.arguments = ["--qnet-loadability-probe"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.currentDirectoryURL = url.deletingLastPathComponent()
        var probeEnvironment = environment
        probeEnvironment["QNET_RUNTIME_PROBE"] = "1"
        process.environment = probeEnvironment
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            return ProbeResult(
                loadable: false,
                detail: "could not launch: \(error.localizedDescription)"
            )
        }

        let deadline = DispatchTime.now() + timeout
        if completed.wait(timeout: deadline) == .timedOut {
            // Reaching user code for the whole probe interval proves dyld
            // usually completed. Stop before a legacy program can do real
            // work, then still inspect stderr: under CPU pressure the
            // termination callback can arrive after the deadline even when
            // dyld already printed a fatal loader error and exited.
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) == .timedOut {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = completed.wait(timeout: .now() + 0.2)
            }
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let loaderFailure = loaderFailureMessage(from: message) {
                return ProbeResult(loadable: false, detail: loaderFailure)
            }
            return ProbeResult(
                loadable: true,
                detail: "dynamic loader probe passed (process reached user code)"
            )
        }

        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let loaderFailure = loaderFailureMessage(from: message) {
            return ProbeResult(loadable: false, detail: loaderFailure)
        }

        // A usage error is expected because old solvers do not share a help
        // flag.  Exiting from main still demonstrates that the loader worked.
        let status = process.terminationStatus
        return ProbeResult(
            loadable: true,
            detail: "dynamic loader probe passed (probe exit status \(status))"
        )
    }

    private func loaderFailureMessage(from stderr: String) -> String? {
        let lower = stderr.lowercased()
        let markers = [
            "library not loaded",
            "dyld:",
            "dyld[",
            "symbol not found",
            "dependent dylib",
            "code signature invalid",
            "mapped file has no cdhash",
            "bad cpu type in executable",
            "exec format error"
        ]
        guard markers.contains(where: lower.contains) else { return nil }
        let compact = stderr
            .split(whereSeparator: \Character.isNewline)
            .prefix(8)
            .joined(separator: " ")
        return compact.isEmpty ? "the dynamic loader rejected the executable" : compact
    }

    // MARK: - Build status manifest

    private func unavailableReason(
        roots: [RuntimeRoot],
        name: String,
        subdirectory: String,
        groups: [String]
    ) -> String? {
        let suffixes = Set(groups.map { "\($0)/\(subdirectory)/\(name)" })
        for root in roots where root.provenance == .bundledResources
            || root.provenance == .nearbyAppBundle
            || root.provenance == .environmentOverride {
            for manifest in manifestCandidates(for: root.url) {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
                    continue
                }
                for line in text.split(whereSeparator: \Character.isNewline) {
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard fields.count >= 4, fields[0] == "unavailable" else { continue }
                    let relative = String(fields[2])
                    if suffixes.contains(relative) {
                        return String(fields[3])
                    }
                }
            }
        }
        return nil
    }

    private func manifestCandidates(for root: URL) -> [URL] {
        let name = "solver-runtime-status-v1.tsv"
        return [
            root.appendingPathComponent(name),
            root.deletingLastPathComponent().appendingPathComponent(name),
            root.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(name)
        ]
    }
}
