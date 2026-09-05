import Foundation

/// Failures from the visual-network to exact open-BCMP adapter.  The adapter
/// deliberately rejects a model whenever a GUI primitive would require an
/// approximation or would be silently discarded.
enum ProductFormExportError: LocalizedError {
    case finiteBuffers
    case invalidMaximumServers(Int)
    case serverLimit(String, Int, Int)
    case unvisitedStation(String)
    case outgoingFromSink(String, String)
    case incomingToSource(String, String)
    case unsupportedModel(String)
    case internalContract(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .finiteBuffers:
            return "Exact open product form requires infinite-capacity queues. Change Buffer Model to Infinite, or use a finite-buffer method."
        case .invalidMaximumServers(let value):
            return "The product-form server safety limit is \(value). Set it to a positive integer."
        case .serverLimit(let station, let count, let limit):
            return "\(station) has \(count) servers, above the product-form safety limit of \(limit). Raise the explicit limit only if an O(servers) Erlang-C normalization is acceptable."
        case .unvisitedStation(let station):
            return "\(station) is not reachable from any external arrival class. Connect it to an active route or remove it before exact product-form analysis."
        case .outgoingFromSink(let sink, let destination):
            return "Exit sink \(sink) has a positive-probability route to \(destination). Product form treats a sink as final departure; delete that outgoing route."
        case .incomingToSource(let origin, let source):
            return "The route from \(origin) enters source \(source). External sources may create customers but cannot receive routed customers; route to a station or sink instead."
        case .unsupportedModel(let message):
            return message
        case .internalContract(let message):
            return "The strict queue-model adapter produced inconsistent intermediate data: \(message)"
        case .encoding(let message):
            return "The exact open product-form input could not be encoded: \(message)"
        }
    }
}

/// Exports the exact subclass of the visual editor supported by
/// `infinite/BNApf/solver.py` with `model_type = open_bcmp`.
///
/// The GUI currently models service stations as FCFS. Consequently the exact
/// adapter accepts only independent Poisson arrivals, exponential service,
/// class-independent service rates at each station, class-preserving Markov
/// routing, and infinite queue capacities. Multi-server stations are emitted
/// as exact M/M/c FCFS nodes. `RegenerativeExporter` supplies the shared strict
/// Markovian topology/traffic validation; this type only changes the output
/// representation and does not inherit any simulation approximation.
@MainActor
enum ProductFormExporter {
    nonisolated static let defaultMaximumServers = 100_000

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
        let modelType: String
        let name: String
        let description: String
        let stations: [StationDocument]
        let classes: [ClassDocument]
        let solver: SolverDocument

        enum CodingKeys: String, CodingKey {
            case name, description, stations, classes, solver
            case schemaVersion = "schema_version"
            case modelType = "model_type"
        }
    }

    private struct StationDocument: Encodable {
        let id: String
        let type: String
        let servers: Int
        let serviceTimes: [String: Double]

        enum CodingKeys: String, CodingKey {
            case id, type, servers
            case serviceTimes = "service_times"
        }
    }

    private struct ClassDocument: Encodable {
        let id: String
        let externalArrivalRates: [String: Double]
        let routing: [RoutingRow]

        enum CodingKeys: String, CodingKey {
            case id, routing
            case externalArrivalRates = "external_arrival_rates"
        }
    }

    private struct RoutingRow: Encodable {
        let fromStation: String
        let destinations: [RouteDestination]
        let exitProbability: Double

        enum CodingKeys: String, CodingKey {
            case destinations
            case fromStation = "from_station"
            case exitProbability = "exit_probability"
        }
    }

    private struct RouteDestination: Encodable {
        let station: String
        let probability: Double
    }

    private struct SolverDocument: Encodable {
        let maxServers: Int

        enum CodingKeys: String, CodingKey {
            case maxServers = "max_servers"
        }
    }

    static func export(
        editor: NetworkEditorModel,
        name: String,
        maximumServers: Int = defaultMaximumServers
    ) -> Result<String, ProductFormExportError> {
        guard editor.infiniteBuffers else { return .failure(.finiteBuffers) }
        guard maximumServers > 0 else {
            return .failure(.invalidMaximumServers(maximumServers))
        }

        // These two topologies otherwise disappear while translating the
        // source/sink boundary. Reject them before the shared adapter can
        // treat them as visually irrelevant decoration.
        let nodeByID = Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })
        for link in editor.links where link.routingProbability > 0 {
            guard let origin = nodeByID[link.fromNodeID],
                  let destination = nodeByID[link.toNodeID] else {
                // The shared strict adapter supplies its more specific
                // missing-endpoint error below.
                continue
            }
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
            return .failure(.unsupportedModel(productFormMessage(error)))
        case .success(let value):
            strictJSON = value
        }

        let strict: StrictNetwork
        do {
            strict = try JSONDecoder().decode(StrictNetwork.self, from: Data(strictJSON.utf8))
        } catch {
            return .failure(.internalContract(error.localizedDescription))
        }

        guard !strict.nodes.isEmpty, !strict.classes.isEmpty else {
            return .failure(.internalContract("the station or class list is empty"))
        }
        let stationIDs = strict.nodes.map(\.id)
        let stationIDSet = Set(stationIDs)
        let classIDs = strict.classes.map(\.id)
        guard stationIDSet.count == stationIDs.count else {
            return .failure(.internalContract("station identifiers are not unique"))
        }
        guard Set(classIDs).count == classIDs.count else {
            return .failure(.internalContract("class identifiers are not unique"))
        }

        // open_bcmp intentionally rejects explicit routing rows that are not
        // reachable from that class's external arrivals. Compute the same
        // reachability relation here, then emit only meaningful rows/service
        // times. This is essential for disjoint multiclass subnetworks.
        var reachableByClass: [String: Set<String>] = [:]
        for customerClass in strict.classes {
            guard !customerClass.externalArrivalRates.isEmpty,
                  customerClass.externalArrivalRates.values.allSatisfy({
                      $0.isFinite && $0 > 0
                  }),
                  Set(customerClass.externalArrivalRates.keys)
                    .isSubset(of: stationIDSet) else {
                return .failure(.internalContract(
                    "class \(customerClass.id) has invalid external arrival rates"
                ))
            }
            guard Set(customerClass.routing.keys).isSubset(of: stationIDSet) else {
                return .failure(.internalContract(
                    "class \(customerClass.id) has a routing row for an unknown station"
                ))
            }
            var reachable = Set(customerClass.externalArrivalRates.keys)
            var frontier = Array(reachable)
            while let source = frontier.popLast() {
                let destinations = customerClass.routing[source] ?? [:]
                guard Set(destinations.keys).isSubset(of: stationIDSet),
                      destinations.values.allSatisfy({
                          $0.isFinite && $0 > 0 && $0 <= 1
                      }) else {
                    return .failure(.internalContract(
                        "class \(customerClass.id) has invalid routing from \(source)"
                    ))
                }
                for destination in destinations.keys
                    where reachable.insert(destination).inserted {
                    frontier.append(destination)
                }
            }
            reachableByClass[customerClass.id] = reachable
        }

        let visitedStations = reachableByClass.values.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }
        if let unvisitedIndex = stationIDs.firstIndex(where: {
            !visitedStations.contains($0)
        }) {
            let displayName = editor.stationsInExportOrder.indices.contains(unvisitedIndex)
                ? editor.stationsInExportOrder[unvisitedIndex].name
                : stationIDs[unvisitedIndex]
            return .failure(.unvisitedStation(displayName))
        }

        var stations: [StationDocument] = []
        for (index, node) in strict.nodes.enumerated() {
            guard node.servers > 0,
                  node.serviceRate.isFinite,
                  node.serviceRate > 0 else {
                return .failure(.internalContract(
                    "station \(node.id) has invalid servers or service rate"
                ))
            }
            if node.servers > maximumServers {
                let displayName = editor.stationsInExportOrder.indices.contains(index)
                    ? editor.stationsInExportOrder[index].name
                    : node.id
                return .failure(.serverLimit(
                    displayName, node.servers, maximumServers
                ))
            }
            let meanServiceTime = 1 / node.serviceRate
            guard meanServiceTime.isFinite, meanServiceTime > 0 else {
                return .failure(.internalContract(
                    "station \(node.id) has a non-finite mean service time"
                ))
            }
            stations.append(StationDocument(
                id: node.id,
                type: "fcfs",
                servers: node.servers,
                serviceTimes: Dictionary(
                    uniqueKeysWithValues: classIDs.compactMap { classID in
                        reachableByClass[classID]?.contains(node.id) == true
                            ? (classID, meanServiceTime)
                            : nil
                    }
                )
            ))
        }

        var classes: [ClassDocument] = []
        for customerClass in strict.classes {
            var routingRows: [RoutingRow] = []
            let reachable = reachableByClass[customerClass.id] ?? []
            for stationID in stationIDs where reachable.contains(stationID) {
                let rawDestinations = customerClass.routing[stationID] ?? [:]
                guard Set(rawDestinations.keys).isSubset(of: stationIDSet),
                      rawDestinations.values.allSatisfy({
                          $0.isFinite && $0 > 0 && $0 <= 1
                      }) else {
                    return .failure(.internalContract(
                        "class \(customerClass.id) has invalid routing from \(stationID)"
                    ))
                }
                let internalProbability = rawDestinations.values.reduce(0, +)
                guard internalProbability.isFinite,
                      internalProbability <= 1 + 1e-12 else {
                    return .failure(.internalContract(
                        "class \(customerClass.id) routing from \(stationID) exceeds one"
                    ))
                }
                let exitProbability = max(0, min(1, 1 - internalProbability))
                let destinations = stationIDs.compactMap { destinationID in
                    rawDestinations[destinationID].map {
                        RouteDestination(station: destinationID, probability: $0)
                    }
                }
                routingRows.append(RoutingRow(
                    fromStation: stationID,
                    destinations: destinations,
                    exitProbability: exitProbability
                ))
            }
            classes.append(ClassDocument(
                id: customerClass.id,
                externalArrivalRates: customerClass.externalArrivalRates,
                routing: routingRows
            ))
        }

        let document = InputDocument(
            schemaVersion: 1,
            modelType: "open_bcmp",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: "Exact open FCFS BCMP/Jackson model exported from Qnet; M/M/c local factors are normalized analytically without state-space truncation.",
            stations: stations,
            classes: classes,
            solver: SolverDocument(maxServers: maximumServers)
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

    /// Reword shared strict-model failures at the exact method's level. The
    /// underlying predicates are intentionally shared so simulation and
    /// product form cannot drift on what “Poisson/exponential open network”
    /// means.
    private static func productFormMessage(_ error: RegenerativeExportError) -> String {
        let original = error.localizedDescription
        return original
            .replacingOccurrences(
                of: "Regenerative simulation requires",
                with: "Exact open product form requires"
            )
            .replacingOccurrences(
                of: "Regenerative simulation currently requires",
                with: "Exact open product form requires"
            )
            .replacingOccurrences(
                of: "regenerative steady state requires",
                with: "an exact open product-form steady state requires"
            )
            .replacingOccurrences(
                of: "regenerative simulation input",
                with: "exact open product-form input"
            )
    }
}
