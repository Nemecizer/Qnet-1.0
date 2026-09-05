import Combine
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Why a dependency appears in the startup checklist.  Release builds and
/// source-tree runs intentionally have different catalogs: a release bundles
/// its native libraries, while a developer must have the matching Homebrew
/// formulae before rebuilding the solvers.
enum StartupDependencyScope: String, Sendable {
    case runtime = "Runtime"
    case optional = "Optional"
    case bundled = "Bundled"
    case developer = "Developer"
}

enum StartupDependencyProbe: Equatable, Sendable {
    case homebrew
    case brewFormula(String)
    case python(requiredModules: [String], validationCode: String)
    case bundledExecutable(name: String, subdirectory: String, groups: [String])
}

struct StartupDependencyRequirement: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let scope: StartupDependencyScope
    let probe: StartupDependencyProbe
    /// Formulae needed to repair this capability in a source build.  The UI
    /// combines and de-duplicates these into one copyable `brew install` line.
    let brewFormulae: [String]
    /// Dependencies without a Homebrew formula (currently CVXPY) remain
    /// explicit instead of being hidden or assigned a command that cannot
    /// install them.
    let supplementalInstallCommands: [String]

    init(
        id: String,
        name: String,
        summary: String,
        scope: StartupDependencyScope,
        probe: StartupDependencyProbe,
        brewFormulae: [String] = [],
        supplementalInstallCommands: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.scope = scope
        self.probe = probe
        self.brewFormulae = brewFormulae
        self.supplementalInstallCommands = supplementalInstallCommands
    }
}

enum StartupDependencyStatus: Equatable, Sendable {
    case pending
    case checking
    case available(String)
    case missing(String)
    case timedOut(String)

    var needsAttention: Bool {
        switch self {
        case .missing, .timedOut: return true
        case .pending, .checking, .available: return false
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct StartupDependencyItem: Identifiable, Equatable, Sendable {
    let requirement: StartupDependencyRequirement
    var status: StartupDependencyStatus
    var id: String { requirement.id }
}

enum StartupDependencyEvent: Equatable, Sendable {
    case checking(String)
    case completed(String, StartupDependencyStatus)
    case finished
}

typealias StartupDependencyProbeFunction = @Sendable (
    StartupDependencyRequirement
) async -> StartupDependencyStatus

enum StartupDependencyCatalog {
    /// The source-build list is also selectable from a validation harness via
    /// an environment override; ordinary users never need to set it.
    static var isPackagedApplication: Bool {
        switch ProcessInfo.processInfo.environment["QNET_STARTUP_CHECK_MODE"] {
        case "packaged": return true
        case "development": return false
        default: return Bundle.main.bundleURL.pathExtension == "app"
        }
    }

    static var current: [StartupDependencyRequirement] {
        requirements(packaged: isPackagedApplication)
    }

    static func requirements(packaged: Bool) -> [StartupDependencyRequirement] {
        var result: [StartupDependencyRequirement] = []

        if !packaged {
            result.append(StartupDependencyRequirement(
                id: "developer.homebrew",
                name: "Homebrew",
                summary: "Installs the numerical libraries used when Qnet's native solvers are built from source.",
                scope: .developer,
                probe: .homebrew
            ))
        }

        result.append(contentsOf: [
            StartupDependencyRequirement(
                id: "runtime.python",
                name: "Python 3",
                summary: "Runs the product-form, CTMC, QBD, decomposition, regenerative, adaptive SRBM, and BAR methods.",
                scope: .runtime,
                probe: .python(
                    requiredModules: [],
                    validationCode: "import sys; assert sys.version_info >= (3, 9), 'Qnet requires Python 3.9 or newer'; print(f'Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
                ),
                brewFormulae: ["python"]
            ),
            StartupDependencyRequirement(
                id: "optional.numpy",
                name: "NumPy",
                summary: "Enables the exact dense tandem CTMC in finite-buffer comparisons.",
                scope: .optional,
                probe: .python(
                    requiredModules: ["numpy"],
                    validationCode: "import numpy as np; print(f'NumPy {np.__version__}')"
                ),
                brewFormulae: ["numpy"]
            ),
            StartupDependencyRequirement(
                id: "optional.cvxpy",
                name: "CVXPY with an SDP solver",
                summary: "Adds numerical candidates for general BAR moment bounds; exact BAR cases work without it.",
                scope: .optional,
                probe: .python(
                    requiredModules: ["numpy", "cvxpy"],
                    validationCode: "import cvxpy as cp; choices = sorted({'SCS', 'CLARABEL', 'CVXOPT', 'MOSEK'} & set(cp.installed_solvers())); assert choices, 'CVXPY has no supported SDP solver'; print(f'CVXPY {cp.__version__}; solver {choices[0]}')"
                ),
                supplementalInstallCommands: ["python3 -m pip install cvxpy"]
            ),
        ])

        if packaged {
            result.append(contentsOf: bundledRequirements)
        } else {
            result.append(contentsOf: developerRequirements)
        }
        return result
    }

    private static let developerRequirements: [StartupDependencyRequirement] = [
        StartupDependencyRequirement(
            id: "developer.libomp",
            name: "libomp",
            summary: "OpenMP runtime used by simulation, finite-element, spectral, and LP solver builds.",
            scope: .developer,
            probe: .brewFormula("libomp"),
            brewFormulae: ["libomp"]
        ),
        StartupDependencyRequirement(
            id: "developer.suite-sparse",
            name: "SuiteSparse",
            summary: "Sparse linear algebra used by spectral, finite-element, MLMC, and multiclass solver builds.",
            scope: .developer,
            probe: .brewFormula("suite-sparse"),
            brewFormulae: ["suite-sparse"]
        ),
        StartupDependencyRequirement(
            id: "developer.highs",
            name: "HiGHS",
            summary: "Default open-source backend compiled into the infinite- and finite-buffer LP solvers.",
            scope: .developer,
            probe: .brewFormula("highs"),
            brewFormulae: ["highs"]
        ),
        StartupDependencyRequirement(
            id: "developer.gcc13",
            name: "GCC 13",
            summary: "Compiler and runtime expected by the infinite-buffer spectral solver's current build file.",
            scope: .developer,
            probe: .brewFormula("gcc@13"),
            brewFormulae: ["gcc@13"]
        ),
        StartupDependencyRequirement(
            id: "optional.cjson",
            name: "cJSON",
            summary: "Builds the experimental multiclass workload-diffusion solver.",
            scope: .optional,
            probe: .brewFormula("cjson"),
            brewFormulae: ["cjson"]
        ),
    ]

    /// A release checks the loadability of a representative bundled solver,
    /// not the developer's local Homebrew cellar.  Formula names remain on
    /// each row solely as repair guidance for rebuilding an incomplete app.
    private static let bundledRequirements: [StartupDependencyRequirement] = [
        StartupDependencyRequirement(
            id: "bundled.rqna",
            name: "RQNA solver",
            summary: "Bundled robust queueing-network analyzer used by Run Whitt–You RQNA.",
            scope: .bundled,
            probe: .bundledExecutable(
                name: "bna_rqna", subdirectory: "BNArqna", groups: ["infinite"]
            )
        ),
        StartupDependencyRequirement(
            id: "bundled.libomp",
            name: "libomp",
            summary: "Bundled OpenMP runtime for the native simulation engines.",
            scope: .bundled,
            probe: .bundledExecutable(
                name: "jackson_sim", subdirectory: "BNAsim", groups: ["infinite"]
            ),
            brewFormulae: ["libomp"]
        ),
        StartupDependencyRequirement(
            id: "bundled.suite-sparse",
            name: "SuiteSparse",
            summary: "Bundled sparse numerical libraries for the spectral solver.",
            scope: .bundled,
            probe: .bundledExecutable(
                name: "bnet", subdirectory: "BNAsm", groups: ["infinite"]
            ),
            brewFormulae: ["suite-sparse"]
        ),
        StartupDependencyRequirement(
            id: "bundled.highs",
            name: "HiGHS",
            summary: "Bundled linear-programming backend for the orthant LP method.",
            scope: .bundled,
            probe: .bundledExecutable(
                name: "srbm_lp", subdirectory: "BNAlp", groups: ["infinite"]
            ),
            brewFormulae: ["highs", "libomp"]
        ),
        StartupDependencyRequirement(
            id: "bundled.gcc13",
            name: "GCC 13 runtime",
            summary: "Bundled compiler runtime used by the infinite-buffer spectral solver.",
            scope: .bundled,
            probe: .bundledExecutable(
                name: "bnet", subdirectory: "BNAsm", groups: ["infinite"]
            ),
            brewFormulae: ["gcc@13"]
        ),
        StartupDependencyRequirement(
            id: "optional.cjson",
            name: "cJSON",
            summary: "Bundled only when the experimental multiclass workload-diffusion solver was built.",
            scope: .optional,
            probe: .bundledExecutable(
                name: "mc_solver", subdirectory: "BNAmd", groups: ["infinite"]
            ),
            brewFormulae: ["cjson", "suite-sparse", "libomp"]
        ),
    ]
}

@MainActor
final class StartupDependencyChecker: ObservableObject {
    @Published private(set) var items: [StartupDependencyItem]
    @Published private(set) var currentID: String?
    @Published private(set) var lastCheckedID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var hasRun = false
    private(set) var events: [StartupDependencyEvent] = []

    private let minimumVisibleNanoseconds: UInt64
    private let probe: StartupDependencyProbeFunction

    init(
        requirements: [StartupDependencyRequirement] = StartupDependencyCatalog.current,
        minimumVisibleNanoseconds: UInt64 = 180_000_000,
        probe: @escaping StartupDependencyProbeFunction = { requirement in
            await StartupDependencySystemProbe.probe(requirement)
        }
    ) {
        items = requirements.map { StartupDependencyItem(requirement: $0, status: .pending) }
        self.minimumVisibleNanoseconds = minimumVisibleNanoseconds
        self.probe = probe
    }

    var currentRequirement: StartupDependencyRequirement? {
        guard let currentID else { return nil }
        return items.first(where: { $0.id == currentID })?.requirement
    }

    var lastCheckedRequirement: StartupDependencyRequirement? {
        guard let lastCheckedID else { return nil }
        return items.first(where: { $0.id == lastCheckedID })?.requirement
    }

    var attentionCount: Int {
        items.filter { $0.status.needsAttention }.count
    }

    var availableCount: Int {
        items.filter { $0.status.isAvailable }.count
    }

    var missingBrewFormulae: [String] {
        orderedUnique(
            items.filter { $0.status.needsAttention }
                .flatMap(\.requirement.brewFormulae)
        )
    }

    var brewInstallCommand: String? {
        let formulae = missingBrewFormulae
        guard !formulae.isEmpty else { return nil }
        return "brew install \(formulae.joined(separator: " "))"
    }

    var supplementalInstallCommands: [String] {
        orderedUnique(
            items.filter { $0.status.needsAttention }
                .flatMap(\.requirement.supplementalInstallCommands)
        )
    }

    var homebrewIsMissing: Bool {
        items.contains { item in
            item.id == "developer.homebrew" && item.status.needsAttention
        }
    }

    func runIfNeeded() async {
        guard !hasRun else { return }
        await run()
    }

    func rerun() async {
        guard !isRunning else { return }
        items = items.map { StartupDependencyItem(requirement: $0.requirement, status: .pending) }
        currentID = nil
        lastCheckedID = nil
        hasRun = false
        events.removeAll(keepingCapacity: true)
        await run()
    }

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            currentID = nil
            isRunning = false
            hasRun = true
            events.append(.finished)
        }

        for index in items.indices {
            let requirement = items[index].requirement
            currentID = requirement.id
            items[index].status = .checking
            events.append(.checking(requirement.id))
            await Task.yield()

            let started = DispatchTime.now().uptimeNanoseconds
            let result = await probe(requirement)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed < minimumVisibleNanoseconds {
                try? await Task.sleep(nanoseconds: minimumVisibleNanoseconds - elapsed)
            }

            items[index].status = result
            lastCheckedID = requirement.id
            events.append(.completed(requirement.id, result))
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private enum StartupDependencySystemProbe {
    static func probe(
        _ requirement: StartupDependencyRequirement
    ) async -> StartupDependencyStatus {
        await Task.detached(priority: .utility) {
            probeSynchronously(requirement)
        }.value
    }

    private static func probeSynchronously(
        _ requirement: StartupDependencyRequirement
    ) -> StartupDependencyStatus {
        switch requirement.probe {
        case .homebrew:
            guard let brew = brewExecutableURL() else {
                return .missing("Homebrew was not found. Install it first, then run the commands below.")
            }
            let result = run(brew, arguments: ["--version"], timeout: 2.0)
            return status(
                from: result,
                availableFallback: "Homebrew is ready.",
                missingFallback: "Homebrew could not be started."
            )

        case .brewFormula(let formula):
            guard let brew = brewExecutableURL() else {
                return .missing("Homebrew was not found, so \(formula) could not be checked.")
            }
            let result = run(
                brew,
                arguments: ["list", "--versions", formula],
                timeout: 2.0
            )
            if result.timedOut {
                return .timedOut("The Homebrew check for \(formula) timed out.")
            }
            if let launchError = result.launchError {
                return .missing("Homebrew could not check \(formula): \(launchError)")
            }
            guard result.exitStatus == 0, !result.standardOutput.isEmpty else {
                return .missing("\(formula) is not installed by Homebrew.")
            }
            return .available(compact(result.standardOutput))

        case .python(let requiredModules, let validationCode):
            let lookup = SolverRuntimeResolver.shared.resolvePythonRuntime(
                requiredModules: requiredModules,
                probeTimeout: 2.0
            )
            guard let runtime = lookup.resolution else {
                let diagnostic = lookup.actionableDiagnostic
                if diagnostic.localizedCaseInsensitiveContains("timed out") {
                    return .timedOut(compact(diagnostic))
                }
                return .missing(compact(diagnostic))
            }
            let result = run(
                runtime.executableURL,
                arguments: ["-B", "-c", validationCode],
                timeout: 2.0,
                extraEnvironment: ["PYTHONDONTWRITEBYTECODE": "1"]
            )
            return status(
                from: result,
                availableFallback: runtime.probeDetail,
                missingFallback: "The Python capability check failed."
            )

        case .bundledExecutable(let name, let subdirectory, let groups):
            let lookup = SolverRuntimeResolver.shared.resolveExecutable(
                name: name,
                subdirectory: subdirectory,
                groups: groups,
                probeTimeout: 0.8
            )
            guard let resolution = lookup.resolution,
                  resolution.provenance == .bundledResources else {
                let detail = lookup.declaredUnavailableReason
                    ?? "This Qnet.app does not contain a loadable \(name) component."
                return .missing(compact(detail))
            }
            return .available("Bundled with Qnet; the component passed its launch check.")
        }
    }

    private struct CommandResult: Sendable {
        let exitStatus: Int32?
        let standardOutput: String
        let standardError: String
        let timedOut: Bool
        let launchError: String?
    }

    private static func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        extraEnvironment: [String: String] = [:]
    ) -> CommandResult {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("qnet-dependency-\(token).out")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("qnet-dependency-\(token).err")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            return CommandResult(
                exitStatus: nil,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: "temporary output files could not be created"
            )
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            return CommandResult(
                exitStatus: nil,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: error.localizedDescription
            )
        }

        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = standardPath + ":" + (environment["PATH"] ?? "")
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            outputHandle.closeFile()
            errorHandle.closeFile()
            return CommandResult(
                exitStatus: nil,
                standardOutput: "",
                standardError: "",
                timedOut: false,
                launchError: error.localizedDescription
            )
        }

        var timedOut = false
        if completed.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) == .timedOut {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = completed.wait(timeout: .now() + 0.2)
            }
        }

        outputHandle.closeFile()
        errorHandle.closeFile()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        return CommandResult(
            exitStatus: process.isRunning ? nil : process.terminationStatus,
            standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut,
            launchError: nil
        )
    }

    private static func status(
        from result: CommandResult,
        availableFallback: String,
        missingFallback: String
    ) -> StartupDependencyStatus {
        if result.timedOut {
            return .timedOut("The check did not finish within two seconds.")
        }
        if let launchError = result.launchError {
            return .missing("\(missingFallback) \(launchError)")
        }
        if result.exitStatus == 0 {
            let detail = result.standardOutput.isEmpty
                ? availableFallback
                : compact(result.standardOutput)
            return .available(detail)
        }
        let detail = result.standardError.isEmpty
            ? (result.standardOutput.isEmpty ? missingFallback : result.standardOutput)
            : result.standardError
        return .missing(compact(detail))
    }

    private static func brewExecutableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
           !prefix.isEmpty {
            candidates.append(
                URL(fileURLWithPath: prefix, isDirectory: true)
                    .appendingPathComponent("bin/brew", isDirectory: false)
            )
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in searchPath.split(separator: ":") where !component.isEmpty {
            candidates.append(
                URL(fileURLWithPath: String(component), isDirectory: true)
                    .appendingPathComponent("brew", isDirectory: false)
            )
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/brew"))
        candidates.append(URL(fileURLWithPath: "/home/linuxbrew/.linuxbrew/bin/brew"))

        var seen: Set<String> = []
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            return seen.insert(path).inserted && fileManager.isExecutableFile(atPath: path)
        }?.standardizedFileURL
    }

    private static func compact(_ value: String) -> String {
        String(
            value
                .split(whereSeparator: \Character.isNewline)
                .prefix(4)
                .joined(separator: " ")
                .prefix(600)
        )
    }
}
