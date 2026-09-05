import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Structured result model

/// The mathematical object a method evaluates. Keeping this separate from
/// the method's marketing name prevents an SRBM result from being presented
/// as an exact result for the original queueing process.
enum ResultModelLayer: String, Codable, CaseIterable, Identifiable, Hashable {
    case queue = "Queueing process"
    case queueApproximation = "Queue approximation"
    case srbm = "SRBM diffusion"
    case bound = "Certified bound"
    case mixed = "Mixed model layers"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .queue: return "Queue"
        case .queueApproximation: return "Approximation"
        case .srbm: return "SRBM"
        case .bound: return "Bound"
        case .mixed: return "Mixed"
        }
    }
}

/// What kind of claim may safely be made about a method's output.
enum ResultFidelity: String, Codable, CaseIterable, Identifiable, Hashable {
    case exactQueue = "Exact queueing result"
    case queueSimulation = "Queue simulation"
    case queueApproximation = "Queueing approximation"
    case srbmAnalytical = "SRBM analytical result"
    case srbmNumerical = "SRBM numerical result"
    case srbmSimulation = "SRBM simulation"
    case srbmBoundRelaxation = "SRBM bound relaxation"
    case certifiedBound = "Certified bound"
    case mixedEvidence = "Mixed-method evidence"

    var id: String { rawValue }
}

/// Stable, user-visible metadata for a solver. `identifier` is the durable
/// key written to the archive; display names may improve without breaking
/// old records.
struct ResultMethodMetadata: Identifiable, Codable, Hashable {
    let identifier: String
    var displayName: String
    var shortName: String
    var layer: ResultModelLayer
    var fidelity: ResultFidelity
    var implementation: String?

    var id: String { identifier }

    init(
        identifier: String,
        displayName: String,
        shortName: String? = nil,
        layer: ResultModelLayer,
        fidelity: ResultFidelity,
        implementation: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.shortName = shortName ?? displayName
        self.layer = layer
        self.fidelity = fidelity
        self.implementation = implementation
    }
}

extension ResultMethodMetadata {
    // Existing methods. Run handlers can use these directly rather than
    // retyping labels and, more importantly, model-layer claims.
    static let monteCarlo = Self(
        identifier: "queue.des", displayName: "Monte Carlo",
        layer: .queue, fidelity: .queueSimulation, implementation: "BNAsim/fBNAsim"
    )
    static let regenerativeMonteCarlo = Self(
        identifier: "queue.regenerative-mc",
        displayName: "Regenerative Monte Carlo",
        shortName: "Regen MC", layer: .queue,
        fidelity: .queueSimulation, implementation: "regenerative_mc"
    )
    static let jackson = Self(
        identifier: "queue.jackson", displayName: "Jackson Product Form",
        shortName: "Jackson", layer: .queue, fidelity: .exactQueue
    )
    static let openProductForm = Self(
        identifier: "queue.open-bcmp-product-form",
        displayName: "Exact Open Product Form",
        shortName: "Product Form", layer: .queue, fidelity: .exactQueue,
        implementation: "product_form/open_bcmp"
    )
    static let qbd = Self(
        identifier: "queue.matrix-analytic-qbd",
        displayName: "Exact Matrix-Analytic QBD",
        shortName: "QBD", layer: .queue, fidelity: .exactQueue,
        implementation: "matrix_analytic/qbd_solver"
    )
    static let finiteCTMC = Self(
        identifier: "queue.finite-ctmc", displayName: "Exact Sparse CTMC",
        shortName: "CTMC", layer: .queue, fidelity: .exactQueue,
        implementation: "generic_ctmc"
    )
    static let finiteDecomposition = Self(
        identifier: "queue-approx.finite-decomposition",
        displayName: "Finite-Buffer Decomposition",
        shortName: "FB Decomp", layer: .queueApproximation,
        fidelity: .queueApproximation, implementation: "fBNAdecomp"
    )
    static let truncatedCTMC = Self(
        identifier: "queue.infinite-truncated-ctmc",
        displayName: "Adaptive Truncated CTMC",
        shortName: "Truncated CTMC", layer: .queue,
        fidelity: .queueApproximation, implementation: "truncated_ctmc"
    )
    static let adaptiveLowRankBAR = Self(
        identifier: "srbm.adaptive-low-rank-bar",
        displayName: "Adaptive Low-Rank BAR",
        shortName: "Low-Rank BAR", layer: .srbm,
        fidelity: .srbmNumerical, implementation: "adaptive_srbm"
    )
    static let barMomentBounds = Self(
        identifier: "srbm.bar-moment-bounds",
        displayName: "BAR Moment Bounds",
        shortName: "BAR Bounds", layer: .srbm,
        fidelity: .srbmBoundRelaxation, implementation: "bar_bounds"
    )
    static let qna = Self(
        identifier: "queue-approx.qna", displayName: "Whitt QNA",
        shortName: "QNA", layer: .queueApproximation, fidelity: .queueApproximation,
        implementation: "BNAqna"
    )
    static let rqna = Self(
        identifier: "queue-approx.rqna", displayName: "Whitt–You RQNA",
        shortName: "RQNA", layer: .queueApproximation, fidelity: .queueApproximation,
        implementation: "BNArqna"
    )
    static let sbd = Self(
        identifier: "queue-approx.sbd", displayName: "Sequential Bottleneck Decomposition",
        shortName: "SBD", layer: .queueApproximation, fidelity: .queueApproximation,
        implementation: "BNAsbd"
    )
    static let spectral = Self(
        identifier: "srbm.spectral", displayName: "Spectral Method",
        shortName: "Spectral", layer: .srbm, fidelity: .srbmNumerical,
        implementation: "BNAsm/fBNAsm"
    )
    static let finiteElement = Self(
        identifier: "srbm.fem", displayName: "Finite Element Method",
        shortName: "FEM", layer: .srbm, fidelity: .srbmNumerical,
        implementation: "BNAfm/fBNAfm"
    )
    static let linearProgram = Self(
        identifier: "srbm.lp", displayName: "BAR Linear Program",
        shortName: "LP", layer: .srbm, fidelity: .srbmNumerical,
        implementation: "BNAlp/fBNAlp"
    )
    static let srbmMLMC = Self(
        identifier: "srbm.mlmc", displayName: "SRBM MLMC",
        shortName: "MLMC", layer: .srbm, fidelity: .srbmSimulation,
        implementation: "BNAmc"
    )
    static let analyticalSRBM = Self(
        identifier: "srbm.product-form", displayName: "SRBM Product Form",
        shortName: "SRBM PF", layer: .srbm, fidelity: .srbmAnalytical
    )
    static let multiClassSRBM = Self(
        identifier: "srbm.multiclass-station", displayName: "Multi-Class SRBM",
        shortName: "MC SRBM", layer: .srbm, fidelity: .srbmNumerical,
        implementation: "multiclass_diffusion/mc_solver"
    )
    static let comparison = Self(
        identifier: "comparison.mixed", displayName: "Method Comparison",
        shortName: "Comparison", layer: .mixed, fidelity: .mixedEvidence
    )
    static let testSet = Self(
        identifier: "benchmark.test-set", displayName: "Test Set",
        layer: .mixed, fidelity: .mixedEvidence
    )
    static let spectralConvergence = Self(
        identifier: "benchmark.spectral-convergence", displayName: "Spectral Convergence",
        shortName: "Convergence", layer: .mixed, fidelity: .mixedEvidence
    )
}

struct ResultUncertainty: Codable, Hashable {
    var standardError: Double?
    var lowerBound: Double?
    var upperBound: Double?
    /// Stored as a fraction (`0.95`), not a percentage.
    var confidenceLevel: Double?
    var sampleSize: Int?

    init(
        standardError: Double? = nil,
        lowerBound: Double? = nil,
        upperBound: Double? = nil,
        confidenceLevel: Double? = nil,
        sampleSize: Int? = nil
    ) {
        self.standardError = standardError
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.confidenceLevel = confidenceLevel
        self.sampleSize = sampleSize
    }

    var isEmpty: Bool {
        standardError == nil && lowerBound == nil && upperBound == nil
            && confidenceLevel == nil && sampleSize == nil
    }

    /// Half-width of the reported interval, or the standard error when that
    /// is the only spelling a solver gave.
    ///
    /// The two spellings are not interchangeable — a 95 % half-width is
    /// roughly 1.96 standard errors — but they are the same *kind* of
    /// quantity: how wide the uncertainty is. Sorting and the CSV need one
    /// key that exists for both, because a simulator that reports
    /// `value ± h` populates the bounds and leaves `standardError` nil,
    /// which made the Uncertainty column sort every simulation measurement
    /// as `.infinity` — a no-op for exactly the rows that carry an interval.
    /// Nothing here synthesises a standard error from a half-width: the
    /// confidence level needed to convert one into the other is not always
    /// the one that was reported.
    var spread: Double? { halfWidth ?? standardError }

    /// Half-width of the reported interval, present only when both bounds
    /// are. Exported as its own CSV column so a reader can tell a reported
    /// half-width from a reported standard error at a glance.
    var halfWidth: Double? {
        guard let lowerBound, let upperBound else { return nil }
        return (upperBound - lowerBound) / 2
    }
}

/// Method-specific numerical evidence. Unlike a confidence interval, a
/// residual or refinement delta is not statistical uncertainty, so it gets
/// a distinct representation and distinct labels in the UI and export.
struct ResultNumericalEvidence: Codable, Hashable {
    var residual: Double?
    var discretization: String?
    var refinementDelta: Double?
    var convergenceNote: String?

    init(
        residual: Double? = nil,
        discretization: String? = nil,
        refinementDelta: Double? = nil,
        convergenceNote: String? = nil
    ) {
        self.residual = residual
        self.discretization = discretization
        self.refinementDelta = refinementDelta
        self.convergenceNote = convergenceNote
    }

    var isEmpty: Bool {
        residual == nil && discretization == nil
            && refinementDelta == nil && convergenceNote == nil
    }
}

struct ResultMeasurement: Identifiable, Codable, Hashable {
    let id: UUID
    var stationID: UUID?
    var stationName: String
    /// Zero-based internally, displayed one-based. Nil is an aggregate.
    var customerClass: Int?
    var metric: String
    var estimate: Double
    var unit: String
    var uncertainty: ResultUncertainty?
    var numericalEvidence: ResultNumericalEvidence?
    var note: String?

    init(
        id: UUID = UUID(),
        stationID: UUID? = nil,
        stationName: String,
        customerClass: Int? = nil,
        metric: String,
        estimate: Double,
        unit: String = "",
        uncertainty: ResultUncertainty? = nil,
        numericalEvidence: ResultNumericalEvidence? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.stationID = stationID
        self.stationName = stationName
        self.customerClass = customerClass
        self.metric = metric
        self.estimate = estimate
        self.unit = unit
        self.uncertainty = uncertainty?.isEmpty == true ? nil : uncertainty
        self.numericalEvidence = numericalEvidence?.isEmpty == true ? nil : numericalEvidence
        self.note = note
    }

    var classLabel: String { customerClass.map { "C\($0 + 1)" } ?? "All" }
}

/// Immutable queue-network input retained with every run. It supports
/// provenance, cross-launch staleness checks, and a future "rerun exactly"
/// action without depending on whichever document happens to be frontmost.
struct ResultNetworkSnapshot: Codable {
    var nodes: [NetworkNode]
    var links: [NetworkLink]
    var infiniteBuffers: Bool

    @MainActor init(editor: NetworkEditorModel) {
        self.init(nodes: editor.nodes, links: editor.links, infiniteBuffers: editor.infiniteBuffers)
    }

    init(nodes: [NetworkNode], links: [NetworkLink], infiniteBuffers: Bool) {
        // Preserve canvas/export order in the immutable snapshot. A separate
        // canonical ordering is used only when hashing below; sorting the
        // stored nodes itself would silently detach S1…Sn solver rows from
        // the station ordering used when the run was launched.
        self.nodes = nodes
        self.links = links
        self.infiniteBuffers = infiniteBuffers
    }

    var document: NetworkDocument {
        NetworkDocument(nodes: nodes, links: links, infiniteBuffers: infiniteBuffers)
    }

    var fingerprint: String {
        let canonical = ResultNetworkSnapshot(
            nodes: nodes.sorted { $0.id.uuidString < $1.id.uuidString },
            links: links.sorted { $0.id.uuidString < $1.id.uuidString },
            infiniteBuffers: infiniteBuffers
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(canonical) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ResultProvenance: Codable {
    var tabID: UUID
    var networkTitle: String
    var sourceFileURL: String?
    var networkFingerprint: String
    var networkSnapshot: ResultNetworkSnapshot
    var bufferRegime: String
    var parameters: [String: String]
    var seed: UInt64?
    var replicationSeeds: [UInt64]
    var applicationVersion: String
    var solverVersion: String?
    /// Station ids in the exact order used by all solver exporters at launch.
    /// Optional so archives written before structured parsing remain readable.
    var exportStationIDs: [UUID]?

    @MainActor init(
        tabID: UUID,
        networkTitle: String,
        editor: NetworkEditorModel,
        parameters: [String: String] = [:],
        seed: UInt64? = nil,
        replicationSeeds: [UInt64] = [],
        solverVersion: String? = nil
    ) {
        let snapshot = ResultNetworkSnapshot(editor: editor)
        self.tabID = tabID
        self.networkTitle = networkTitle
        self.sourceFileURL = editor.currentFileURL?.absoluteString
        self.networkFingerprint = snapshot.fingerprint
        self.networkSnapshot = snapshot
        self.bufferRegime = snapshot.infiniteBuffers ? "Infinite capacity" : "Finite capacity"
        self.parameters = parameters
        self.seed = seed
        self.replicationSeeds = replicationSeeds
        self.applicationVersion = AppVersion.fullVersion
        self.solverVersion = solverVersion
        self.exportStationIDs = editor.stationsInExportOrder.map(\.id)
    }
}

enum ResultRunStatus: String, Codable, CaseIterable, Hashable {
    case running
    case completed
    case partial
    case failed
    case cancelled

    var label: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .partial: return "Partial"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct ResultRunRecord: Identifiable, Codable {
    let id: UUID
    var method: ResultMethodMetadata
    var provenance: ResultProvenance
    var status: ResultRunStatus
    var startedAt: Date
    var completedAt: Date?
    var elapsedSeconds: Double?
    var measurements: [ResultMeasurement]
    var runEvidence: ResultNumericalEvidence?
    var warnings: [String]
    var failureMessage: String?
    /// Optional solver transcript for audit/debugging. The table never
    /// reparses this field; structured measurements are the source of truth.
    var rawOutput: String?

    init(
        id: UUID = UUID(),
        method: ResultMethodMetadata,
        provenance: ResultProvenance,
        status: ResultRunStatus = .running,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        elapsedSeconds: Double? = nil,
        measurements: [ResultMeasurement] = [],
        runEvidence: ResultNumericalEvidence? = nil,
        warnings: [String] = [],
        failureMessage: String? = nil,
        rawOutput: String? = nil
    ) {
        self.id = id
        self.method = method
        self.provenance = provenance
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.elapsedSeconds = elapsedSeconds
        self.measurements = measurements
        self.runEvidence = runEvidence?.isEmpty == true ? nil : runEvidence
        self.warnings = warnings
        self.failureMessage = failureMessage
        self.rawOutput = rawOutput
    }

    func isStale(comparedWith currentFingerprint: String) -> Bool {
        provenance.networkFingerprint != currentFingerprint
    }
}

extension Notification.Name {
    /// Emitted after a run is first registered. ContentView uses this to
    /// reveal the Results workspace without coupling solver handlers to UI.
    static let qnetResultRunDidBegin = Notification.Name("qnet.results.runDidBegin")
}

// MARK: - Store and persistence

@MainActor
final class ResultsStore: ObservableObject {
    static let shared = ResultsStore()

    private struct Archive: Codable {
        var schemaVersion: Int
        var records: [ResultRunRecord]
    }

    @Published private(set) var records: [ResultRunRecord]
    @Published private(set) var persistenceError: String?

    let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        do {
            records = try Self.load(from: self.storageURL)
            persistenceError = nil
        } catch {
            records = []
            persistenceError = error.localizedDescription
        }
    }

    func records(for tabID: UUID) -> [ResultRunRecord] {
        records.filter { $0.provenance.tabID == tabID }
    }

    func record(id: UUID) -> ResultRunRecord? {
        records.first { $0.id == id }
    }

    /// Register the immutable run context before a process launches.
    /// Returns the run id all later output must use.
    @discardableResult
    func beginRun(
        id: UUID = UUID(),
        tabID: UUID,
        networkTitle: String,
        editor: NetworkEditorModel,
        method: ResultMethodMetadata,
        parameters: [String: String] = [:],
        seed: UInt64? = nil,
        replicationSeeds: [UInt64] = [],
        solverVersion: String? = nil,
        startedAt: Date = Date()
    ) -> UUID {
        let provenance = ResultProvenance(
            tabID: tabID,
            networkTitle: networkTitle,
            editor: editor,
            parameters: parameters,
            seed: seed,
            replicationSeeds: replicationSeeds,
            solverVersion: solverVersion
        )
        let record = ResultRunRecord(
            id: id,
            method: method,
            provenance: provenance,
            startedAt: startedAt
        )
        records.insert(record, at: 0)
        persist()
        NotificationCenter.default.post(
            name: .qnetResultRunDidBegin,
            object: self,
            userInfo: ["tabID": tabID, "runID": record.id]
        )
        return record.id
    }

    func appendMeasurements(_ measurements: [ResultMeasurement], to runID: UUID) {
        mutate(runID) { $0.measurements.append(contentsOf: measurements) }
    }

    func replaceMeasurements(_ measurements: [ResultMeasurement], for runID: UUID) {
        mutate(runID) { $0.measurements = measurements }
    }

    func completeRun(
        _ runID: UUID,
        measurements: [ResultMeasurement]? = nil,
        evidence: ResultNumericalEvidence? = nil,
        warnings: [String] = [],
        rawOutput: String? = nil,
        completedAt: Date = Date()
    ) {
        mutate(runID) { record in
            if let measurements { record.measurements = measurements }
            record.runEvidence = evidence?.isEmpty == true ? nil : evidence
            record.warnings = warnings
            record.rawOutput = rawOutput
            record.status = .completed
            record.completedAt = completedAt
            record.elapsedSeconds = max(0, completedAt.timeIntervalSince(record.startedAt))
        }
    }

    func partialRun(
        _ runID: UUID,
        message: String,
        measurements: [ResultMeasurement]? = nil,
        evidence: ResultNumericalEvidence? = nil,
        warnings: [String] = [],
        rawOutput: String? = nil,
        completedAt: Date = Date()
    ) {
        mutate(runID) { record in
            if let measurements { record.measurements = measurements }
            record.runEvidence = evidence?.isEmpty == true ? nil : evidence
            record.warnings = warnings
            record.failureMessage = message
            record.rawOutput = rawOutput
            record.status = .partial
            record.completedAt = completedAt
            record.elapsedSeconds = max(0, completedAt.timeIntervalSince(record.startedAt))
        }
    }

    func failRun(
        _ runID: UUID,
        message: String,
        rawOutput: String? = nil,
        completedAt: Date = Date()
    ) {
        mutate(runID) { record in
            record.status = .failed
            record.failureMessage = message
            record.rawOutput = rawOutput
            record.completedAt = completedAt
            record.elapsedSeconds = max(0, completedAt.timeIntervalSince(record.startedAt))
        }
    }

    func cancelRun(
        _ runID: UUID,
        rawOutput: String? = nil,
        completedAt: Date = Date()
    ) {
        mutate(runID) { record in
            record.status = .cancelled
            record.rawOutput = rawOutput
            record.completedAt = completedAt
            record.elapsedSeconds = max(0, completedAt.timeIntervalSince(record.startedAt))
        }
    }

    /// Import path for result parsers that already hold a complete record.
    func addCompletedRecord(_ record: ResultRunRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        persist()
    }

    func delete(_ runID: UUID) {
        records.removeAll { $0.id == runID }
        persist()
    }

    func deleteAll(for tabID: UUID) {
        records.removeAll { $0.provenance.tabID == tabID }
        persist()
    }

    func networkDocument(for runID: UUID) -> NetworkDocument? {
        record(id: runID)?.provenance.networkSnapshot.document
    }

    /// Flush is public for application-termination hooks and tests.
    func flush() { persist() }

    private func mutate(_ runID: UUID, _ body: (inout ResultRunRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == runID }) else { return }
        body(&records[index])
        persist()
    }

    private func persist() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Archive(schemaVersion: 1, records: records))
            try data.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private static func load(from url: URL) throws -> [ResultRunRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Archive.self, from: data).records
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Qnet", isDirectory: true)
            .appendingPathComponent("results-v1.json")
    }
}

// MARK: - CSV / JSON export

enum ResultsExport {
    enum Format { case csv, json }

    @MainActor
    static func save(
        records: [ResultRunRecord],
        format: Format,
        currentFingerprint: String?
    ) {
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = records.count == 1 ? "qnet-result.csv" : "qnet-results.csv"
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = records.count == 1 ? "qnet-result.json" : "qnet-results.json"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .csv:
                try csv(records: records, currentFingerprint: currentFingerprint)
                    .write(to: url, atomically: true, encoding: .utf8)
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(records).write(to: url, options: .atomic)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func csv(
        records: [ResultRunRecord],
        currentFingerprint: String?
    ) -> String {
        let header = [
            "run_id", "network", "network_fingerprint", "stale", "status",
            "method_id", "method", "model_layer", "fidelity", "started_at",
            "completed_at", "elapsed_seconds", "station_id", "station", "class",
            "metric", "estimate", "unit", "standard_error", "half_width",
            "ci_lower", "ci_upper",
            "confidence_level", "sample_size", "residual", "discretization",
            "refinement_delta", "note", "seed", "parameters", "warnings"
        ]
        var rows = [header.map(escape).joined(separator: ",")]
        let iso = ISO8601DateFormatter()

        for run in records {
            let stale: String
            if let currentFingerprint {
                stale = run.isStale(comparedWith: currentFingerprint) ? "true" : "false"
            } else {
                stale = ""
            }
            let parameterText = run.provenance.parameters.keys.sorted()
                .map { "\($0)=\(run.provenance.parameters[$0] ?? "")" }
                .joined(separator: "; ")
            let measurements = run.measurements.isEmpty
                ? [ResultMeasurement(stationName: "", metric: "", estimate: .nan)]
                : run.measurements

            for measurement in measurements {
                let uncertainty = measurement.uncertainty
                let evidence = measurement.numericalEvidence
                let fields = [
                    run.id.uuidString,
                    run.provenance.networkTitle,
                    run.provenance.networkFingerprint,
                    stale,
                    run.status.rawValue,
                    run.method.identifier,
                    run.method.displayName,
                    run.method.layer.rawValue,
                    run.method.fidelity.rawValue,
                    iso.string(from: run.startedAt),
                    run.completedAt.map(iso.string(from:)) ?? "",
                    number(run.elapsedSeconds),
                    measurement.stationID?.uuidString ?? "",
                    measurement.stationName,
                    measurement.customerClass.map { String($0 + 1) } ?? "",
                    measurement.metric,
                    measurement.estimate.isNaN ? "" : String(measurement.estimate),
                    measurement.unit,
                    number(uncertainty?.standardError),
                    // A simulator reports a half-width, not a standard error,
                    // so `standard_error` stays empty for those rows rather
                    // than carrying a converted value the solver never
                    // reported. `half_width` is the column that is populated.
                    number(uncertainty?.halfWidth),
                    number(uncertainty?.lowerBound),
                    number(uncertainty?.upperBound),
                    number(uncertainty?.confidenceLevel),
                    uncertainty?.sampleSize.map { String($0) } ?? "",
                    number(evidence?.residual ?? run.runEvidence?.residual),
                    evidence?.discretization ?? run.runEvidence?.discretization ?? "",
                    number(evidence?.refinementDelta ?? run.runEvidence?.refinementDelta),
                    measurement.note ?? evidence?.convergenceNote
                        ?? run.runEvidence?.convergenceNote ?? "",
                    run.provenance.seed.map { String($0) } ?? "",
                    parameterText,
                    run.warnings.joined(separator: "; ")
                ]
                rows.append(fields.map(escape).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func copyCSV(records: [ResultRunRecord], currentFingerprint: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            csv(records: records, currentFingerprint: currentFingerprint),
            forType: .string
        )
    }

    private static func number(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The Results pane's one number formatter, and the reason there is only
/// one: a solver *result* is displayed at Settings ▸ Output Format ▸ Output
/// decimals, exactly like the terminal table it was parsed out of. Three
/// private significant-digit copies used to live in this file,
/// so a value the shell showed as `0.667` reappeared here as `0.6666667`
/// and the same run seemed to disagree with itself.
///
/// This is deliberately NOT the rule for a derived model readout (the node
/// inspector's ρ keeps `DS.Number.readoutDigits`) and NOT the rule for a
/// machine export (the CSV keeps full precision). Solver results follow the
/// pref; model readouts and exports do not.
private func resultsNumber(_ value: Double, decimals: Int) -> String {
    DS.Number.display(value, decimals: decimals)
}

// MARK: - Results workspace

struct ResultsWorkspaceView: View {
    let tabID: UUID
    let networkTitle: String

    /// Read here and handed down as a plain `Int`, not as an
    /// `@ObservedObject AppSettings` on each row: a settings object on a row
    /// view re-renders every row of the table on every settings tick, and
    /// only this one value matters to them.
    @AppStorage("output.decimals") private var outputDecimals: Int
        = AppSettings.Defaults.outputDecimals

    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject private var store = ResultsStore.shared
    @ObservedObject private var focusRouter = FocusRouter.shared
    @DSAccessibility private var a11y

    @State private var selectedRunID: UUID?
    @State private var selectedMeasurementID: UUID?
    @State private var searchText = ""
    @State private var layerFilter: LayerFilter = .all
    @State private var runSort: RunSort = .newest
    @State private var measurementSort: MeasurementSort = .station
    @State private var sortAscending = true
    @State private var showDeleteConfirmation = false
    @State private var showRawOutput = false
    @State private var comparisonRunIDs: Set<UUID> = []
    @State private var showingComparison = false
    @FocusState private var searchFocused: Bool

    /// This instance's identity for its `FocusRouter` registrations, so a
    /// late `onDisappear` cannot clear a newer instance's handler.
    @State private var handlerOwner = PaneHandlerOwner()

    private enum LayerFilter: String, CaseIterable, Identifiable {
        case all = "All layers"
        case queue = "Queue"
        case approximation = "Approximation"
        case srbm = "SRBM"
        case bound = "Bound"
        case mixed = "Mixed"
        var id: String { rawValue }

        func includes(_ layer: ResultModelLayer) -> Bool {
            switch self {
            case .all: return true
            case .queue: return layer == .queue
            case .approximation: return layer == .queueApproximation
            case .srbm: return layer == .srbm
            case .bound: return layer == .bound
            case .mixed: return layer == .mixed
            }
        }
    }

    private enum RunSort: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case method = "Method"
        case network = "Network"
        var id: String { rawValue }
    }

    private enum MeasurementSort: String {
        case station, customerClass, metric, estimate, uncertainty, unit
    }

    private var currentFingerprint: String {
        ResultNetworkSnapshot(editor: editor).fingerprint
    }

    private var tabRecords: [ResultRunRecord] {
        store.records(for: tabID)
    }

    private var filteredRuns: [ResultRunRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let runs = tabRecords.filter { run in
            guard layerFilter.includes(run.method.layer) else { return false }
            guard !query.isEmpty else { return true }
            return run.method.displayName.localizedCaseInsensitiveContains(query)
                || run.provenance.networkTitle.localizedCaseInsensitiveContains(query)
                || run.method.fidelity.rawValue.localizedCaseInsensitiveContains(query)
                || run.warnings.contains { $0.localizedCaseInsensitiveContains(query) }
                || run.measurements.contains {
                    $0.stationName.localizedCaseInsensitiveContains(query)
                        || $0.metric.localizedCaseInsensitiveContains(query)
                        || $0.unit.localizedCaseInsensitiveContains(query)
                }
        }
        switch runSort {
        case .newest: return runs.sorted { $0.startedAt > $1.startedAt }
        case .method:
            return runs.sorted {
                $0.method.displayName.localizedStandardCompare($1.method.displayName) == .orderedAscending
            }
        case .network:
            return runs.sorted {
                $0.provenance.networkTitle.localizedStandardCompare($1.provenance.networkTitle) == .orderedAscending
            }
        }
    }

    private var selectedRun: ResultRunRecord? {
        let id = selectedRunID ?? filteredRuns.first?.id
        return filteredRuns.first { $0.id == id }
    }

    private var comparisonRuns: [ResultRunRecord] {
        tabRecords.filter { comparisonRunIDs.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func previousComparableRun(for run: ResultRunRecord) -> ResultRunRecord? {
        tabRecords
            .filter {
                $0.id != run.id
                    && $0.status == .completed
                    && $0.method.identifier == run.method.identifier
                    && $0.provenance.networkFingerprint == run.provenance.networkFingerprint
                    && $0.startedAt < run.startedAt
            }
            .max { $0.startedAt < $1.startedAt }
    }

    private var sortedMeasurements: [ResultMeasurement] {
        guard let run = selectedRun else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = run.measurements.filter { measurement in
            query.isEmpty
                || measurement.stationName.localizedCaseInsensitiveContains(query)
                || measurement.metric.localizedCaseInsensitiveContains(query)
                || measurement.unit.localizedCaseInsensitiveContains(query)
        }
        return values.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch measurementSort {
            case .station:
                comparison = lhs.stationName.localizedStandardCompare(rhs.stationName)
            case .customerClass:
                comparison = compare(lhs.customerClass ?? -1, rhs.customerClass ?? -1)
            case .metric:
                comparison = lhs.metric.localizedStandardCompare(rhs.metric)
            case .estimate:
                comparison = compare(lhs.estimate, rhs.estimate)
            case .uncertainty:
                // Sort by how wide the uncertainty is, whichever spelling
                // produced it — see `ResultUncertainty.spread`. Rows with no
                // uncertainty at all sort last in ascending order.
                comparison = compare(
                    lhs.uncertainty?.spread ?? .infinity,
                    rhs.uncertainty?.spread ?? .infinity
                )
            case .unit:
                comparison = lhs.unit.localizedStandardCompare(rhs.unit)
            }
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return sortAscending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSectionHeader("Results", isFocused: focusRouter.focusedPane == .results) {
                DSBadge(text: "\(tabRecords.count)")
                    .help("\(tabRecords.count) persisted run record\(tabRecords.count == 1 ? "" : "s") for this tab")
            } trailing: {
                comparisonMenu
                exportMenu
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Delete Result",
                    help: "Delete the selected run record",
                    isDestructive: true
                ) { showDeleteConfirmation = true }
                .disabled(selectedRun == nil)
                // Last in the row, after the destructive control: this one
                // changes the window, not the record.
                PaneSoloButton(.results)
            }

            filterBar

            HSplitView {
                runHistory
                    .frame(minWidth: DS.Layout.sidePaneMinWidth,
                           idealWidth: DS.Layout.rightColumnIdealWidth)
                resultDetail
                    .frame(minWidth: DS.Layout.canvasPaneMinWidth)
            }
            .dsContentWell()
        }
        .background(PaneFocusMarker(.results))
        .confirmationDialog(
            "Delete this result?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Result", role: .destructive) {
                if let selectedRunID {
                    store.delete(selectedRunID)
                    self.selectedRunID = filteredRuns.first?.id
                    selectedMeasurementID = nil
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The persisted run record and its measurements will be removed. The network is not changed.")
        }
        .onAppear {
            selectFirstRunIfNeeded()
            FocusRouter.shared.setFocusHandler(.results, owner: handlerOwner.id) { searchFocused = true }
            FocusRouter.shared.setFindHandler(.results, owner: handlerOwner.id) { searchFocused = true }
        }
        .onDisappear {
            FocusRouter.shared.setFocusHandler(.results, owner: handlerOwner.id, nil)
            FocusRouter.shared.setFindHandler(.results, owner: handlerOwner.id, nil)
        }
        .onChange(of: tabID) { _, _ in
            selectedRunID = nil
            selectedMeasurementID = nil
            comparisonRunIDs = []
            showingComparison = false
            showRawOutput = false
            selectFirstRunIfNeeded()
        }
        .onChange(of: filteredRuns.map(\.id)) { _, _ in selectFirstRunIfNeeded() }
        .onChange(of: selectedRunID) { _, _ in showRawOutput = false }
        .onChange(of: selectedMeasurementID) { _, id in selectStation(for: id) }
    }

    private var filterBar: some View {
        HStack(spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: DS.Symbol.find)
                    .foregroundStyle(DS.Color.textSecondary)
                TextField("Filter methods, stations, metrics, or warnings", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Filter results")
                if !searchText.isEmpty {
                    DSIconButton(
                        systemImage: DS.Symbol.clearField,
                        label: "Clear Filter",
                        help: "Clear the results filter"
                    ) { searchText = "" }
                }
            }
            .padding(.leading, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(DS.Color.controlBorder(a11y.contrast),
                            lineWidth: DS.Stroke.hairline(a11y.contrast))
            )

            Picker("Layer", selection: $layerFilter) {
                ForEach(LayerFilter.allCases) { layer in Text(layer.rawValue).tag(layer) }
            }
            .labelsHidden()
            .frame(maxWidth: DS.Layout.rightColumnIdealWidth)
            .accessibilityLabel("Model layer filter")

            Picker("Sort", selection: $runSort) {
                ForEach(RunSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
            }
            .labelsHidden()
            .frame(maxWidth: DS.Layout.sidePaneMinWidth)
            .accessibilityLabel("Sort runs")
        }
        .dsChromeBar(.bottom, horizontal: DS.Spacing.s, vertical: DS.Spacing.xs)
    }

    private var runHistory: some View {
        Group {
            if filteredRuns.isEmpty {
                DSEmptyState(
                    systemImage: tabRecords.isEmpty ? DS.Symbol.numberFormat : DS.Symbol.find,
                    title: tabRecords.isEmpty ? "No Results Yet" : "No Matching Results",
                    message: tabRecords.isEmpty
                        ? "Run a method to create a reproducible record for this network."
                        : "Change the filter to show this tab's other runs."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Color.surfaceRaised)
            } else {
                List(selection: $selectedRunID) {
                    ForEach(filteredRuns) { run in
                        ResultsRunRow(
                            run: run,
                            isStale: run.isStale(comparedWith: currentFingerprint)
                        )
                        .tag(run.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Run history")
            }
        }
    }

    @ViewBuilder
    private var resultDetail: some View {
        if showingComparison, comparisonRuns.count >= 2 {
            ResultsComparisonView(
                runs: comparisonRuns,
                currentFingerprint: currentFingerprint,
                decimals: outputDecimals
            )
            .background(DS.Color.surfaceRaised)
        } else if let run = selectedRun {
            VStack(spacing: 0) {
                ResultsRunSummary(
                    run: run,
                    isStale: run.isStale(comparedWith: currentFingerprint)
                )
                ResultsEvidenceDashboard(
                    run: run,
                    previousRun: previousComparableRun(for: run),
                    decimals: outputDecimals
                )
                measurementTable(run: run)
                if let message = run.failureMessage {
                    ResultsFailureCard(
                        message: message,
                        rawOutput: run.rawOutput,
                        partial: run.status == .partial
                    )
                }
                if !run.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Warnings").font(DS.Font.labelEmphasis)
                        ForEach(run.warnings, id: \.self) { warning in
                            Label(warning, systemImage: DS.Symbol.warning)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.warningText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.s)
                    .overlay(alignment: .top) { DSRule() }
                }
                if let rawOutput = run.rawOutput, !rawOutput.isEmpty {
                    rawOutputDisclosure(rawOutput)
                }
            }
            .background(DS.Color.surfaceRaised)
        } else {
            DSEmptyState(
                systemImage: DS.Symbol.numberFormat,
                title: "No Run Selected",
                message: "Select a run to inspect its measurements."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.surfaceRaised)
        }
    }

    private func measurementTable(run: ResultRunRecord) -> some View {
        Group {
            if run.measurements.isEmpty {
                VStack(spacing: DS.Spacing.s) {
                    if run.status == .running {
                        ProgressView()
                        Text("Waiting for structured measurements…")
                    } else {
                        Text("This run did not produce structured measurements.")
                    }
                }
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        measurementHeader
                        ForEach(sortedMeasurements) { measurement in
                            ResultsMeasurementRow(
                                measurement: measurement,
                                selected: selectedMeasurementID == measurement.id,
                                decimals: outputDecimals
                            ) {
                                selectedMeasurementID = measurement.id
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityLabel("Measurements for \(run.method.displayName)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { DSRule() }
    }

    private var measurementHeader: some View {
        GridRow {
            sortHeader("Station", by: .station, minWidth: DS.Layout.tableCellMinWidth * 2)
            sortHeader("Class", by: .customerClass, minWidth: DS.Layout.tableCellMinWidth)
            sortHeader("Metric", by: .metric, minWidth: DS.Layout.tableCellMinWidth * 3)
            sortHeader("Estimate", by: .estimate, minWidth: DS.Layout.tableCellMinWidth * 2,
                       numeric: true)
            sortHeader("Uncertainty / evidence", by: .uncertainty,
                       minWidth: DS.Layout.tableCellMinWidth * 3)
            sortHeader("Unit", by: .unit, minWidth: DS.Layout.tableCellMinWidth * 2)
        }
        .background(DS.Color.surface)
    }

    /// `numeric` right-aligns the heading over a right-aligned column, so the
    /// label and its sort arrow sit above the digits they name.
    private func sortHeader(
        _ title: String,
        by field: MeasurementSort,
        minWidth: CGFloat,
        numeric: Bool = false
    ) -> some View {
        Button {
            if measurementSort == field { sortAscending.toggle() }
            else { measurementSort = field; sortAscending = true }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(title)
                if measurementSort == field {
                    Text(sortAscending ? "↑" : "↓")
                        .accessibilityHidden(true)
                }
            }
            .font(DS.Font.tableHeader)
            .foregroundStyle(DS.Color.textSecondary)
            .frame(minWidth: minWidth, maxWidth: .infinity,
                   alignment: numeric ? .trailing : .leading)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(measurementSort == field
                            ? (sortAscending ? "ascending" : "descending")
                            : "not selected")
    }

    private var exportMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.export,
            label: "Export results",
            help: "Copy or export the selected structured result"
        ) {
            Button("Copy Selected Run as CSV") {
                if let selectedRun {
                    ResultsExport.copyCSV(
                        records: [selectedRun], currentFingerprint: currentFingerprint
                    )
                }
            }
            .disabled(selectedRun == nil)
            Button("Save Selected Run as CSV…") {
                if let selectedRun {
                    ResultsExport.save(
                        records: [selectedRun], format: .csv,
                        currentFingerprint: currentFingerprint
                    )
                }
            }
            .disabled(selectedRun == nil)
            Button("Save Selected Run as JSON…") {
                if let selectedRun {
                    ResultsExport.save(
                        records: [selectedRun], format: .json,
                        currentFingerprint: currentFingerprint
                    )
                }
            }
            .disabled(selectedRun == nil)
            Divider()
            Button("Save Visible Runs as CSV…") {
                ResultsExport.save(
                    records: filteredRuns, format: .csv,
                    currentFingerprint: currentFingerprint
                )
            }
            .disabled(filteredRuns.isEmpty)
            Button("Save Visible Runs as JSON…") {
                ResultsExport.save(
                    records: filteredRuns, format: .json,
                    currentFingerprint: currentFingerprint
                )
            }
            .disabled(filteredRuns.isEmpty)
        }
        .disabled(tabRecords.isEmpty)
    }

    private var comparisonMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.workflows,
            label: "Compare results",
            help: "Select two or more runs and compare matching measurements"
        ) {
            if filteredRuns.isEmpty {
                Text("No visible runs")
            } else {
                ForEach(filteredRuns) { run in
                    Toggle(isOn: Binding(
                        get: { comparisonRunIDs.contains(run.id) },
                        set: { include in
                            if include { comparisonRunIDs.insert(run.id) }
                            else { comparisonRunIDs.remove(run.id) }
                            if comparisonRunIDs.count < 2 { showingComparison = false }
                        }
                    )) {
                        Text("\(run.method.shortName) · \(run.startedAt.formatted(date: .omitted, time: .shortened))")
                    }
                    .disabled(run.status == .running)
                }
            }
            Divider()
            Toggle("Show Comparison", isOn: $showingComparison)
                .disabled(comparisonRunIDs.count < 2)
            Button("Clear Comparison") {
                comparisonRunIDs = []
                showingComparison = false
            }
            .disabled(comparisonRunIDs.isEmpty)
        }
        .overlay(alignment: .topTrailing) {
            if !comparisonRunIDs.isEmpty {
                DSBadge(text: "\(comparisonRunIDs.count)")
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func rawOutputDisclosure(_ rawOutput: String) -> some View {
        DisclosureGroup(isExpanded: $showRawOutput) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack {
                    Text("Verbatim standard output retained for audit and diagnostics.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    Spacer()
                    Button("Copy Transcript") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(rawOutput, forType: .string)
                    }
                    .buttonStyle(.link)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(rawOutput)
                        .font(DS.Font.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.s)
                }
                .frame(maxHeight: DS.Layout.codeWellMaxHeight)
                .background(DS.Color.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
            }
            .padding(.top, DS.Spacing.xs)
        } label: {
            Text("Solver Transcript")
                .font(DS.Font.labelEmphasis)
        }
        .padding(DS.Spacing.s)
        .overlay(alignment: .top) { DSRule() }
    }

    private func selectFirstRunIfNeeded() {
        guard selectedRunID == nil
                || !filteredRuns.contains(where: { $0.id == selectedRunID }) else { return }
        selectedRunID = filteredRuns.first?.id
        selectedMeasurementID = nil
    }

    private func selectStation(for measurementID: UUID?) {
        guard let measurementID,
              let stationID = selectedRun?.measurements
                .first(where: { $0.id == measurementID })?.stationID,
              editor.nodes.contains(where: { $0.id == stationID }) else { return }
        editor.selectedLinkID = nil
        editor.selectedNodeIDs = []
        editor.selectedNodeID = stationID
    }
}

private struct ResultsComparisonKey: Hashable, Comparable {
    let stationID: UUID?
    let stationName: String
    let customerClass: Int?
    let metric: String
    let unit: String

    init(_ measurement: ResultMeasurement) {
        stationID = measurement.stationID
        stationName = measurement.stationName
        customerClass = measurement.customerClass
        metric = measurement.metric
        unit = measurement.unit
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let left = "\(lhs.stationName)|\(lhs.customerClass ?? -1)|\(lhs.metric)|\(lhs.unit)"
        let right = "\(rhs.stationName)|\(rhs.customerClass ?? -1)|\(rhs.metric)|\(rhs.unit)"
        return left.localizedStandardCompare(right) == .orderedAscending
    }

    var classLabel: String { customerClass.map { "C\($0 + 1)" } ?? "All" }
}

private struct ResultsComparisonView: View {
    let runs: [ResultRunRecord]
    let currentFingerprint: String
    let decimals: Int

    private var keys: [ResultsComparisonKey] {
        Array(Set(runs.flatMap { $0.measurements.map(ResultsComparisonKey.init) })).sorted()
    }

    private var layers: Set<ResultModelLayer> { Set(runs.map(\.method.layer)) }
    private var fingerprints: Set<String> { Set(runs.map { $0.provenance.networkFingerprint }) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Run Comparison")
                        .font(DS.Font.sectionTitle)
                    Spacer()
                    DSBadge(text: "\(runs.count) runs")
                }
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(runs) { run in
                        ResultsStatusChip(
                            label: run.method.shortName,
                            severity: run.method.layer == .queue ? .success
                                : (run.method.layer == .queueApproximation ? .warning : .info)
                        )
                        .help("\(run.method.fidelity.rawValue) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if layers.count > 1 {
                    Label(
                        "These runs cross model layers. Agreement between SRBM methods checks SRBM numerics; it does not independently validate the queueing-process approximation.",
                        systemImage: DS.Symbol.info
                    )
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.infoText)
                }
                if fingerprints.count > 1 {
                    Label(
                        "The selected runs used different network snapshots; differences may reflect changed inputs as well as methods.",
                        systemImage: DS.Symbol.warning
                    )
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warningText)
                }
            }
            .padding(DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)

            DSRule()

            if keys.isEmpty {
                DSEmptyState(
                    systemImage: DS.Symbol.numberFormat,
                    title: "No Comparable Measurements",
                    message: "The selected runs have no structured measurements yet. Their solver transcripts remain available in each run."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            headerCell("Station")
                            headerCell("Class")
                            headerCell("Metric")
                            ForEach(runs) { run in
                                headerCell(run.method.shortName, numeric: true)
                            }
                            headerCell("Range", numeric: true)
                        }
                        ForEach(keys, id: \.self) { key in
                            comparisonRow(key)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityLabel("Comparison of \(runs.count) result runs")
            }
        }
    }

    private func comparisonRow(_ key: ResultsComparisonKey) -> some View {
        let values = runs.map { run in
            run.measurements.first { ResultsComparisonKey($0) == key }?.estimate
        }
        let finiteValues = values.compactMap { $0 }.filter(\.isFinite)
        let spread = finiteValues.count > 1
            ? (finiteValues.max() ?? 0) - (finiteValues.min() ?? 0)
            : nil
        return GridRow {
            bodyCell(key.stationName)
            bodyCell(key.classLabel)
            bodyCell(key.metric)
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, _ in
                bodyCell(
                    values[index].map { resultsNumber($0, decimals: decimals) } ?? "—",
                    numeric: true
                )
            }
            bodyCell(
                spread.map { resultsNumber($0, decimals: decimals) } ?? "—",
                numeric: true
            )
        }
    }

    /// A heading sits over its own column: a numeric column is right-aligned,
    /// so its heading has to be too, or the label floats away from the digits
    /// it names.
    private func headerCell(_ value: String, numeric: Bool = false) -> some View {
        Text(value)
            .font(DS.Font.tableHeader)
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)
            .frame(minWidth: DS.Layout.tableCellMinWidth * 2,
                   maxWidth: .infinity, alignment: numeric ? .trailing : .leading)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .background(DS.Color.surface)
    }

    /// Numeric cells are right-aligned in monospaced digits so magnitudes can
    /// be compared straight down the column, and truncate at the TAIL: a
    /// middle-truncated number (`0.81…457`) reads as a real value and is a
    /// quietly wrong one.
    private func bodyCell(_ value: String, numeric: Bool = false) -> some View {
        Text(value)
            .font(numeric ? DS.Font.number : DS.Font.body)
            .foregroundStyle(DS.Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: DS.Layout.tableCellMinWidth * 2,
                   maxWidth: .infinity, alignment: numeric ? .trailing : .leading)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .overlay(alignment: .bottom) { DSRule() }
    }

}

private struct ResultsRunRow: View {
    let run: ResultRunRecord
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(run.method.shortName)
                    .font(DS.Font.labelEmphasis)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(statusLabel)
            }
            HStack(spacing: DS.Spacing.xs) {
                Text(run.method.layer.shortName)
                Text("·")
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)
            Text("\(run.measurements.count) measurement\(run.measurements.count == 1 ? "" : "s")")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .padding(.vertical, DS.Spacing.xs)
        .help("\(run.method.displayName) · \(run.method.fidelity.rawValue)\(isStale ? " · Network changed since this run" : "")")
    }

    private var statusSymbol: String {
        if isStale { return DS.Symbol.warning }
        switch run.status {
        case .running: return DS.Symbol.pending
        case .completed: return DS.Symbol.success
        case .partial: return DS.Symbol.warning
        case .failed: return DS.Symbol.failure
        case .cancelled: return DS.Symbol.blocked
        }
    }

    private var statusColor: Color {
        if isStale { return DS.Color.warningText }
        switch run.status {
        case .running: return DS.Color.accent
        case .completed: return DS.Color.success
        case .partial: return DS.Color.warningText
        case .failed: return DS.Color.dangerText
        case .cancelled: return DS.Color.textSecondary
        }
    }

    private var statusLabel: String {
        isStale ? "Stale result" : run.status.label
    }
}

private struct ResultsRunSummary: View {
    let run: ResultRunRecord
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(run.method.displayName)
                        .font(DS.Font.sectionTitle)
                    Text(run.method.fidelity.rawValue)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer(minLength: DS.Spacing.s)
                ResultsStatusChip(label: run.status.label, severity: statusSeverity)
                if isStale {
                    ResultsStatusChip(label: "Network changed", severity: .warning)
                        .help("This result remains valid for its saved network snapshot, but the current canvas no longer matches it.")
                }
            }

            HStack(spacing: DS.Spacing.l) {
                summaryItem("Network", run.provenance.networkTitle)
                summaryItem("Capacity", run.provenance.bufferRegime)
                summaryItem("Started", run.startedAt.formatted(date: .abbreviated, time: .standard))
                if let seconds = run.elapsedSeconds {
                    summaryItem("Elapsed", seconds.formatted(.number.precision(.fractionLength(0...3))) + " s")
                }
                summaryItem("Fingerprint", String(run.provenance.networkFingerprint.prefix(12)))
            }

            if !run.provenance.parameters.isEmpty {
                Text(run.provenance.parameters.keys.sorted().map {
                    "\($0)=\(run.provenance.parameters[$0] ?? "")"
                }.joined(separator: "  ·  "))
                .font(DS.Font.monoCaption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(2)
                .help("Complete parameters are retained in JSON exports")
            }
        }
        .padding(DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surfaceRaised)
    }

    private var statusSeverity: StatusSeverity {
        switch run.status {
        case .running: return .info
        case .completed: return .success
        case .partial: return .warning
        case .failed: return .error
        case .cancelled: return .warning
        }
    }

    private func summaryItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(label.uppercased())
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
            Text(value)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
        }
    }
}

private struct ResultsEvidenceDashboard: View {
    let run: ResultRunRecord
    let previousRun: ResultRunRecord?
    let decimals: Int

    private struct Delta {
        let count: Int
        let maximumAbsolute: Double
        let maximumRelative: Double
        let changedParameters: [String]
    }

    private var statisticalCount: Int {
        run.measurements.filter { $0.uncertainty != nil }.count
    }

    private var residual: Double? {
        run.runEvidence?.residual
            ?? run.measurements.compactMap { $0.numericalEvidence?.residual }.max()
    }

    private var explicitRefinement: Double? {
        run.runEvidence?.refinementDelta
            ?? run.measurements.compactMap { $0.numericalEvidence?.refinementDelta }.max()
    }

    private var crossRunDelta: Delta? {
        guard let previousRun else { return nil }
        let previous = Dictionary(
            uniqueKeysWithValues: previousRun.measurements.map {
                (ResultsComparisonKey($0), $0.estimate)
            }
        )
        var absolute: [Double] = []
        var relative: [Double] = []
        for measurement in run.measurements {
            guard measurement.estimate.isFinite,
                  let older = previous[ResultsComparisonKey(measurement)],
                  older.isFinite else { continue }
            let difference = abs(measurement.estimate - older)
            absolute.append(difference)
            relative.append(difference / max(abs(older), Double.leastNonzeroMagnitude))
        }
        guard !absolute.isEmpty else { return nil }
        let parameterKeys = Set(run.provenance.parameters.keys)
            .union(previousRun.provenance.parameters.keys)
        let changed = parameterKeys.filter {
            run.provenance.parameters[$0] != previousRun.provenance.parameters[$0]
        }.sorted()
        return Delta(
            count: absolute.count,
            maximumAbsolute: absolute.max() ?? 0,
            maximumRelative: relative.max() ?? 0,
            changedParameters: changed
        )
    }

    private var shouldShow: Bool {
        statisticalCount > 0 || residual != nil || explicitRefinement != nil
            || crossRunDelta != nil || run.method.fidelity == .queueSimulation
    }

    @ViewBuilder
    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Quality Evidence")
                    .font(DS.Font.labelEmphasis)
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    if statisticalCount > 0 {
                        evidenceItem(
                            "Statistical uncertainty",
                            "Reported for \(statisticalCount) of \(run.measurements.count) measurements"
                        )
                    } else if run.method.fidelity == .queueSimulation {
                        evidenceItem(
                            "Uncertainty missing",
                            "Treat point estimates cautiously; no interval or standard error was parsed."
                        )
                    }
                    if let residual {
                        evidenceItem(
                            "Numerical residual",
                            resultsNumber(residual, decimals: decimals)
                        )
                    }
                    if let explicitRefinement {
                        evidenceItem(
                            "Reported refinement Δ",
                            resultsNumber(explicitRefinement, decimals: decimals)
                        )
                    }
                    if let delta = crossRunDelta {
                        evidenceItem(
                            "Change from prior matching run",
                            "max |Δ| \(resultsNumber(delta.maximumAbsolute, decimals: decimals)) · max relative \(percent(delta.maximumRelative))"
                        )
                        .help(crossRunHelp(delta))
                    }
                }
                Text("Residuals and cross-run changes are numerical evidence, not statistical confidence intervals or queue-model error bounds.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.subtleFill)
            .overlay(alignment: .top) { DSRule() }
        }
    }

    private func evidenceItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(label.uppercased())
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
            Text(value)
                .font(DS.Font.monoCaption)
                .foregroundStyle(DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func crossRunHelp(_ delta: Delta) -> String {
        let parameterNote = delta.changedParameters.isEmpty
            ? "The recorded solver parameters are unchanged."
            : "Changed parameters: \(delta.changedParameters.joined(separator: ", "))."
        return "Compared \(delta.count) matching measurements with the most recent older run of the same method and network snapshot. \(parameterNote)"
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...3)))
    }
}

private struct ResultsFailureCard: View {
    let message: String
    let rawOutput: String?
    let partial: Bool

    private var guidance: (diagnosis: String, action: String) {
        let text = ([message, rawOutput ?? ""].joined(separator: "\n")).lowercased()
        if partial {
            return (
                message,
                "Use the retained estimates as provisional evidence only. Review the convergence or fallback note, then increase the relevant safeguard or choose the recommended scalable method."
            )
        }
        if text.contains("not found") || text.contains("no such file") {
            return (
                "The selected solver executable could not be located.",
                "Build the algorithm from its folder, then run it again. If it was moved, restore the Qnet folder layout."
            )
        }
        if text.contains("permission denied") {
            return (
                "macOS refused to launch or read a required solver file.",
                "Check that the executable and its input folder are readable and executable, then retry."
            )
        }
        if text.contains("unstable") || text.contains("not positive recurrent")
            || text.contains("rho >=") || text.contains("ρ ≥") {
            return (
                "The supplied network does not satisfy this method's steady-state stability condition.",
                "Use Analyze Network to inspect station load, then reduce offered load or increase service capacity before rerunning."
            )
        }
        if text.contains("singular") || text.contains("ill-conditioned")
            || text.contains("nan") || text.contains("not finite") {
            return (
                "The numerical system became singular or non-finite.",
                "Check the network warnings and method assumptions. Then retry with a coarser, well-scaled discretization before refining."
            )
        }
        if text.contains("infeasible") || text.contains("unbounded") {
            return (
                "The optimization model did not yield a bounded feasible solution.",
                "Check SRBM stability and boundary conventions, then increase the grid or basis gradually and rerun."
            )
        }
        if text.contains("killed") || text.contains("signal 9")
            || text.contains("status 137") || text.contains("out of memory") {
            return (
                "The process was likely stopped because the selected resolution exceeded available resources.",
                "Reduce degree, mesh, grid, basis size, or parallel workers, then refine one setting at a time."
            )
        }
        if text.contains("timeout") || text.contains("timed out") {
            return (
                "The solver did not finish within its allowed time.",
                "Lower the run length or discretization for a diagnostic run, then increase it gradually."
            )
        }
        return (
            message,
            "Open the Solver Transcript below, start with its last error line, and verify the active network's warnings and method assumptions before rerunning."
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(partial ? "Partial Result" : "Run Failed",
                  systemImage: partial ? DS.Symbol.warning : DS.Symbol.failure)
                .font(DS.Font.labelEmphasis)
                .foregroundStyle(partial ? DS.Color.warningText : DS.Color.dangerText)
            Text(guidance.diagnosis)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textPrimary)
            Text("Next step: \(guidance.action)")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.s)
        .background(DS.Color.tintFill(partial ? DS.Color.warning : DS.Color.danger))
        .overlay(alignment: .top) { DSRule() }
    }
}

private struct ResultsStatusChip: View {
    let label: String
    let severity: StatusSeverity

    var body: some View {
        Label(label, systemImage: severity.symbolName)
            .font(DS.Font.caption)
            .foregroundStyle(severity.color)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.chipHeight)
            .background(
                Capsule().fill(DS.Color.tintFill(severity.color))
            )
    }
}

private struct ResultsMeasurementRow: View {
    let measurement: ResultMeasurement
    let selected: Bool
    let decimals: Int
    let action: () -> Void
    @DSAccessibility private var a11y

    var body: some View {
        GridRow {
            cell(measurement.stationName, minWidth: DS.Layout.tableCellMinWidth * 2)
            cell(measurement.classLabel, minWidth: DS.Layout.tableCellMinWidth)
            cell(measurement.metric, minWidth: DS.Layout.tableCellMinWidth * 3)
            cell(resultsNumber(measurement.estimate, decimals: decimals),
                 minWidth: DS.Layout.tableCellMinWidth * 2, numeric: true)
            cell(evidenceLabel, minWidth: DS.Layout.tableCellMinWidth * 3, monospaced: true)
            cell(measurement.unit.isEmpty ? "—" : measurement.unit,
                 minWidth: DS.Layout.tableCellMinWidth * 2)
        }
        .background(selected ? DS.Color.selectionFill(a11y.contrast) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("Select Station"), action)
        .help(measurement.note ?? evidenceHelp)
    }

    /// `numeric` right-aligns the cell in monospaced digits so the estimates
    /// line up on their decimal point down the column; `monospaced` is for
    /// mixed text that still wants a fixed pitch (the evidence column reads
    /// "95% [0.812, 0.815]"), and stays left-aligned.
    ///
    /// Every cell truncates at the TAIL. Middle truncation renders a clipped
    /// number as `0.81…457`, which reads as a perfectly plausible value —
    /// there is no worse way to shorten a number than to make the short form
    /// look real.
    private func cell(
        _ value: String,
        minWidth: CGFloat,
        monospaced: Bool = false,
        numeric: Bool = false
    ) -> some View {
        Text(value)
            .font(numeric ? DS.Font.number : (monospaced ? DS.Font.mono : DS.Font.body))
            .foregroundStyle(DS.Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: minWidth, maxWidth: .infinity,
                   alignment: numeric ? .trailing : .leading)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .overlay(alignment: .bottom) { DSRule() }
    }

    private var evidenceLabel: String {
        if let uncertainty = measurement.uncertainty {
            if let lower = uncertainty.lowerBound, let upper = uncertainty.upperBound {
                let level = uncertainty.confidenceLevel.map {
                    String(format: "%.0f%% ", $0 * 100)
                } ?? ""
                return "\(level)[\(fmt(lower)), \(fmt(upper))]"
            }
            if let standardError = uncertainty.standardError {
                return "SE \(fmt(standardError))"
            }
        }
        if let evidence = measurement.numericalEvidence {
            if let residual = evidence.residual { return "residual \(fmt(residual))" }
            if let delta = evidence.refinementDelta { return "Δ \(fmt(delta))" }
            if let discretization = evidence.discretization { return discretization }
        }
        return "—"
    }

    private var evidenceHelp: String {
        var parts: [String] = []
        if let uncertainty = measurement.uncertainty {
            // The interval comes first and is spelled out: a simulator reports
            // a half-width, so an interval is the usual — often the only —
            // uncertainty a measurement carries, and a tooltip that mentioned
            // only the standard error said "none was reported" beside a cell
            // visibly showing one.
            if let lower = uncertainty.lowerBound, let upper = uncertainty.upperBound {
                let level = uncertainty.confidenceLevel
                    .map { String(format: "%.0f%% confidence interval", $0 * 100) }
                    ?? "Interval"
                parts.append("\(level): [\(fmt(lower)), \(fmt(upper))]")
            }
            if let se = uncertainty.standardError { parts.append("Standard error: \(fmt(se))") }
            if let n = uncertainty.sampleSize { parts.append("Sample size: \(n)") }
        }
        if let evidence = measurement.numericalEvidence {
            if let residual = evidence.residual { parts.append("Residual: \(fmt(residual))") }
            if let note = evidence.convergenceNote { parts.append(note) }
        }
        return parts.isEmpty ? "No uncertainty or numerical evidence was reported" : parts.joined(separator: " · ")
    }

    /// Local spelling of the shared formatter, only because the evidence
    /// strings below interpolate it half a dozen times in one line.
    private func fmt(_ value: Double) -> String {
        resultsNumber(value, decimals: decimals)
    }
}
