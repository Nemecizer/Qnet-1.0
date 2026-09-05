import Foundation

enum QBDExportError: LocalizedError {
    case finiteBuffers
    case stationCount(Int)
    case sourceCount(Int)
    case serverCount(String, Int)
    case invalidOptions(String)
    case outgoingFromSink(String, String)
    case incomingToSource(String, String)
    case unsupportedModel(String)
    case internalContract(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .finiteBuffers:
            return "The exact one-phase QBD mapping requires an infinite-capacity queue. Change Buffer Model to Infinite."
        case .stationCount(let count):
            return "The current QBD adapter supports exactly one service station; this network has \(count). Use product form or another network method for multiple stations."
        case .sourceCount(let count):
            return "The current QBD adapter supports exactly one external customer class/source; this network has \(count)."
        case .serverCount(let station, let count):
            return "\(station) has \(count) servers. The current scalar QBD level mapping is exact only for one exponential server (M/M/1)."
        case .invalidOptions(let message):
            return "The QBD reporting settings are invalid: \(message)"
        case .outgoingFromSink(let sink, let destination):
            return "Exit sink \(sink) routes back to \(destination). A sink must be final departure for the one-queue QBD mapping."
        case .incomingToSource(let origin, let source):
            return "The route from \(origin) enters external source \(source). Route feedback to the station, not to its source."
        case .unsupportedModel(let message):
            return message
        case .internalContract(let message):
            return "The strict M/M/1 adapter produced inconsistent intermediate data: \(message)"
        case .encoding(let message):
            return "The QBD input could not be encoded: \(message)"
        }
    }
}

struct QBDExportOptions: Equatable, Sendable {
    let maximumIterations: Int
    let maximumReportLevel: Int
    let tailLevels: [Int]

    init(
        maximumIterations: Int = 100_000,
        maximumReportLevel: Int = 20,
        tailLevels: [Int] = [0, 1, 2, 5, 10, 20]
    ) {
        self.maximumIterations = maximumIterations
        self.maximumReportLevel = maximumReportLevel
        self.tailLevels = tailLevels
    }
}

/// Maps the GUI's strict open M/M/1 subclass to a scalar, level-independent
/// CTMC QBD. With station feedback probability p, only a non-feedback service
/// completion changes customer count, so the downward rate is μ(1-p).
@MainActor
enum QBDExporter {
    private struct StrictNetwork: Decodable {
        let nodes: [StrictNode]
        let classes: [StrictClass]
    }

    private struct StrictNode: Decodable {
        let id: String
        let servers: Int
        let serviceRate: Double

        enum CodingKeys: String, CodingKey {
            case id, servers
            case serviceRate = "service_rate"
        }
    }

    private struct StrictClass: Decodable {
        let id: String
        let externalArrivalRates: [String: Double]
        let routing: [String: [String: Double]]

        enum CodingKeys: String, CodingKey {
            case id, routing
            case externalArrivalRates = "external_arrival_rates"
        }
    }

    private struct InputDocument: Encodable {
        let schemaVersion: Int
        let process: String
        let name: String
        let boundary: BoundaryDocument
        let interior: InteriorDocument
        let solver: SolverDocument

        enum CodingKeys: String, CodingKey {
            case process, name, boundary, interior, solver
            case schemaVersion = "schema_version"
        }
    }

    private struct BoundaryDocument: Encodable {
        let level0Same: [[Double]]
        let level0Up: [[Double]]
        let level1Down: [[Double]]
        let level1Same: [[Double]]

        enum CodingKeys: String, CodingKey {
            case level0Same = "level_0_same"
            case level0Up = "level_0_up"
            case level1Down = "level_1_down"
            case level1Same = "level_1_same"
        }
    }

    private struct InteriorDocument: Encodable {
        let down: [[Double]]
        let same: [[Double]]
        let up: [[Double]]
    }

    private struct SolverDocument: Encodable {
        let maxIterations: Int
        let maxReportLevel: Int
        let tailLevels: [Int]

        enum CodingKeys: String, CodingKey {
            case maxIterations = "max_iterations"
            case maxReportLevel = "max_report_level"
            case tailLevels = "tail_levels"
        }
    }

    static func export(
        editor: NetworkEditorModel,
        name: String,
        options: QBDExportOptions = .init()
    ) -> Result<String, QBDExportError> {
        guard editor.infiniteBuffers else { return .failure(.finiteBuffers) }
        let stations = editor.stationsInExportOrder
        guard stations.count == 1 else {
            return .failure(.stationCount(stations.count))
        }
        let sources = editor.nodes.filter { $0.kind == .source }
        guard sources.count == 1 else {
            return .failure(.sourceCount(sources.count))
        }
        guard stations[0].numberOfServers == 1 else {
            return .failure(.serverCount(
                stations[0].name, stations[0].numberOfServers
            ))
        }
        if let problem = validate(options) { return .failure(problem) }

        let nodeIDs = editor.nodes.map(\.id)
        guard Set(nodeIDs).count == nodeIDs.count else {
            return .failure(.internalContract(
                "the document contains duplicate node identifiers"
            ))
        }
        let nodeByID = Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })
        for link in editor.links where link.routingProbability > 0 {
            guard let origin = nodeByID[link.fromNodeID],
                  let destination = nodeByID[link.toNodeID] else { continue }
            if origin.kind == .sink {
                return .failure(.outgoingFromSink(origin.name, destination.name))
            }
            if destination.kind == .source {
                return .failure(.incomingToSource(origin.name, destination.name))
            }
        }

        let strictJSON: String
        switch RegenerativeExporter.export(editor: editor, name: name) {
        case .failure(let error):
            return .failure(.unsupportedModel(qbdMessage(error)))
        case .success(let output):
            strictJSON = output
        }

        let strict: StrictNetwork
        do {
            strict = try JSONDecoder().decode(StrictNetwork.self, from: Data(strictJSON.utf8))
        } catch {
            return .failure(.internalContract(error.localizedDescription))
        }
        guard strict.nodes.count == 1, strict.classes.count == 1 else {
            return .failure(.internalContract(
                "expected one exported station and one exported class"
            ))
        }
        let node = strict.nodes[0]
        let customerClass = strict.classes[0]
        guard node.servers == 1,
              node.serviceRate.isFinite,
              node.serviceRate > 0 else {
            return .failure(.internalContract("invalid exponential service rate"))
        }
        guard customerClass.externalArrivalRates.count == 1,
              let externalRate = customerClass.externalArrivalRates[node.id],
              externalRate.isFinite,
              externalRate > 0 else {
            return .failure(.internalContract(
                "the external arrival rate does not target the sole station"
            ))
        }
        let route = customerClass.routing[node.id] ?? [:]
        guard route.keys.allSatisfy({ $0 == node.id }),
              route.values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }) else {
            return .failure(.internalContract(
                "routing contains a destination outside the sole station"
            ))
        }
        let feedbackProbability = route[node.id] ?? 0
        guard feedbackProbability < 1 else {
            return .failure(.unsupportedModel(
                "Feedback probability is one, so no customer can depart. Add a positive exit probability."
            ))
        }
        let downwardRate = node.serviceRate * (1 - feedbackProbability)
        guard downwardRate.isFinite, downwardRate > 0 else {
            return .failure(.internalContract(
                "the non-feedback service-completion rate is not positive and finite"
            ))
        }
        let trafficIntensity = externalRate / downwardRate
        guard trafficIntensity.isFinite, trafficIntensity < 1 else {
            return .failure(.unsupportedModel(
                "The effective M/M/1 load is \(number(trafficIntensity)); steady state requires external rate / [service rate × (1 − feedback)] < 1."
            ))
        }

        let sameRate = -(externalRate + downwardRate)
        let document = InputDocument(
            schemaVersion: 1,
            process: "continuous_time_qbd",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            boundary: BoundaryDocument(
                level0Same: [[-externalRate]],
                level0Up: [[externalRate]],
                level1Down: [[downwardRate]],
                level1Same: [[sameRate]]
            ),
            interior: InteriorDocument(
                down: [[downwardRate]],
                same: [[sameRate]],
                up: [[externalRate]]
            ),
            solver: SolverDocument(
                maxIterations: options.maximumIterations,
                maxReportLevel: options.maximumReportLevel,
                tailLevels: Array(Set(options.tailLevels)).sorted()
            )
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            guard let output = String(data: data, encoding: .utf8) else {
                return .failure(.encoding("UTF-8 conversion failed."))
            }
            return .success(output + "\n")
        } catch {
            return .failure(.encoding(error.localizedDescription))
        }
    }

    private static func validate(_ options: QBDExportOptions) -> QBDExportError? {
        guard options.maximumIterations > 0 else {
            return .invalidOptions("maximum iterations must be positive.")
        }
        guard options.maximumReportLevel >= 0 else {
            return .invalidOptions("maximum report level cannot be negative.")
        }
        guard options.tailLevels.allSatisfy({ $0 >= 0 }) else {
            return .invalidOptions("tail levels must be nonnegative integers.")
        }
        return nil
    }

    private static func qbdMessage(_ error: RegenerativeExportError) -> String {
        error.localizedDescription
            .replacingOccurrences(
                of: "Regenerative simulation currently requires",
                with: "The exact one-phase QBD mapping requires"
            )
            .replacingOccurrences(
                of: "Regenerative simulation requires",
                with: "The exact one-phase QBD mapping requires"
            )
            .replacingOccurrences(
                of: "regenerative steady state requires",
                with: "the exact QBD steady state requires"
            )
            .replacingOccurrences(
                of: "regenerative simulation input",
                with: "QBD input"
            )
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.7g", value) : String(describing: value)
    }
}
