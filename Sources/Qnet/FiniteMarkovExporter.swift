import Foundation

enum FiniteMarkovExportError: LocalizedError {
    case noStations
    case noSources
    case missingBuffer(String)
    case multipleBuffers(String)
    case unsupportedArrival(String, String)
    case invalidArrivalRate(String)
    case unresolvedSource(String)
    case unsupportedService(String, String, String)
    case invalidServiceRate(String, String)
    case routingExceedsOne(String, String, Double)
    case requiresInfiniteBuffers
    case requiresSingleClass
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .noStations:
            return "The network has no service stations."
        case .noSources:
            return "The network has no external arrival source."
        case .missingBuffer(let station):
            return "\(station) needs exactly one upstream buffer so its finite capacity is defined."
        case .multipleBuffers(let station):
            return "\(station) has more than one upstream buffer; the finite Markov solvers require one total capacity per station."
        case .unsupportedArrival(let source, let distribution):
            return "\(source) uses \(distribution) arrivals. The finite Markov solvers require a Poisson process (Poisson or exponential inter-arrivals)."
        case .invalidArrivalRate(let source):
            return "\(source) does not contain a positive finite arrival rate."
        case .unresolvedSource(let source):
            return "\(source) does not route to any service station."
        case .unsupportedService(let station, let customerClass, let distribution):
            return "\(station), \(customerClass) uses \(distribution) service. This method requires exponential service times."
        case .invalidServiceRate(let station, let customerClass):
            return "\(station), \(customerClass) does not contain a positive finite exponential service rate."
        case .routingExceedsOne(let station, let customerClass, let total):
            return "Routing probabilities from \(station) for \(customerClass) total \(DS.Number.format(total, significantDigits: 7)), above 1."
        case .requiresInfiniteBuffers:
            return "This adaptive CTMC method is defined for infinite-buffer networks."
        case .requiresSingleClass:
            return "The adaptive truncated CTMC currently supports one customer class with no class transitions."
        case .encoding(let message):
            return "The finite Markov input could not be encoded: \(message)"
        }
    }
}

/// Converts the visual Qnet document to the versioned JSON inputs used by
/// the sparse exact CTMC and finite-buffer decomposition additions. The
/// exporter is deliberately strict: it rejects non-Markovian primitives
/// instead of silently replacing them by exponential distributions with the
/// same mean.
@MainActor
enum FiniteMarkovExporter {
    private struct StationSpec {
        let id: String
        let name: String
        let servers: Int
        let capacity: Int
        let serviceRates: [String: Double]
    }

    private struct ArrivalSpec {
        let station: String
        let customerClass: String
        let rate: Double
    }

    private struct DestinationSpec {
        let station: String?
        let customerClass: String?
        let probability: Double
        let exits: Bool
    }

    private struct RoutingSpec {
        let fromStation: String
        let fromClass: String
        let destinations: [DestinationSpec]
    }

    private struct Model {
        let classes: [String]
        let stations: [StationSpec]
        let arrivals: [ArrivalSpec]
        let routing: [RoutingSpec]
    }

    static func genericCTMC(
        editor: NetworkEditorModel,
        name: String,
        maxStates: Int = 200_000,
        tolerance: Double = 1e-12
    ) -> Result<String, FiniteMarkovExportError> {
        switch model(editor: editor) {
        case .failure(let error):
            return .failure(error)
        case .success(let model):
            let document: [String: Any] = [
                "schema_version": 1,
                "name": name,
                "blocking": "loss",
                "service_discipline": "fcfs",
                "classes": model.classes,
                "stations": model.stations.map { station in
                    [
                        "id": station.id,
                        "servers": station.servers,
                        "capacity": station.capacity,
                        "service_rates": station.serviceRates
                    ] as [String: Any]
                },
                "external_arrivals": model.arrivals.map { arrival in
                    [
                        "station": arrival.station,
                        "class": arrival.customerClass,
                        "rate": arrival.rate
                    ] as [String: Any]
                },
                "routing": model.routing.map(ctmcRouting),
                "solver": [
                    "tolerance": tolerance,
                    "max_iterations": 200_000,
                    "max_states": maxStates
                ] as [String: Any]
            ]
            return encode(document)
        }
    }

    static func decomposition(
        editor: NetworkEditorModel,
        name: String,
        blocking: String,
        tolerance: Double = 1e-10,
        maxIterations: Int = 1_000,
        damping: Double = 0.5
    ) -> Result<String, FiniteMarkovExportError> {
        switch model(editor: editor) {
        case .failure(let error):
            return .failure(error)
        case .success(let model):
            let arrivalByClass = Dictionary(grouping: model.arrivals, by: \.customerClass)
            let document: [String: Any] = [
                "schema_version": 1,
                "name": name,
                "blocking": blocking,
                "stations": model.stations.map { station in
                    [
                        "id": station.id,
                        "name": station.name,
                        "servers": station.servers,
                        "capacity": station.capacity,
                        "service_rates": station.serviceRates
                    ] as [String: Any]
                },
                "classes": model.classes.map { customerClass in
                    [
                        "id": customerClass,
                        "name": className(customerClass),
                        "external_arrivals": Dictionary(
                            uniqueKeysWithValues: (arrivalByClass[customerClass] ?? [])
                                .map { ($0.station, $0.rate) }
                        )
                    ] as [String: Any]
                },
                "routes": model.routing.flatMap { row in
                    row.destinations.compactMap { destination -> [String: Any]? in
                        guard !destination.exits,
                              let station = destination.station,
                              let customerClass = destination.customerClass else { return nil }
                        var route: [String: Any] = [
                            "class": row.fromClass,
                            "from": row.fromStation,
                            "to": station,
                            "probability": destination.probability
                        ]
                        if customerClass != row.fromClass {
                            route["to_class"] = customerClass
                        }
                        return route
                    }
                },
                "solver": [
                    "tolerance": tolerance,
                    "max_iterations": maxIterations,
                    "damping": damping
                ] as [String: Any]
            ]
            return encode(document)
        }
    }

    /// Versioned input for the adaptive infinite-state CTMC truncation. This
    /// is intentionally narrower than the finite CTMC exporter: population
    /// counts are Markov only for a single class with exponential service.
    static func truncatedInfiniteCTMC(
        editor: NetworkEditorModel,
        name: String,
        initialTotalCap: Int = 8,
        maxTotalCap: Int = 64,
        maxStates: Int = 200_000
    ) -> Result<String, FiniteMarkovExportError> {
        guard editor.infiniteBuffers else { return .failure(.requiresInfiniteBuffers) }
        let stations = editor.stationsInExportOrder
        guard !stations.isEmpty else { return .failure(.noStations) }
        let sources = editor.nodes.filter { $0.kind == .source }
            .sorted { NodeNaming.sortIndex($0.name) < NodeNaming.sortIndex($1.name) }
        guard !sources.isEmpty else { return .failure(.noSources) }

        let classIndices = Set(
            sources.map { editor.customerClassIndex(for: $0.id) }
            + stations.flatMap { Array($0.serviceDistributions.keys) }
            + editor.links.flatMap { [$0.customerClass, $0.exitClass] }
        )
        guard classIndices.allSatisfy({ $0 == 0 }),
              !editor.links.contains(where: { $0.hasClassTransition }) else {
            return .failure(.requiresSingleClass)
        }

        let stationIndex = Dictionary(
            uniqueKeysWithValues: stations.enumerated().map { ($0.element.id, $0.offset) }
        )
        let nodeByID = Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })
        var external = [Double](repeating: 0, count: stations.count)
        for source in sources {
            let parameters = QueueDistribution.parseParameterStrings(source.distributionParameters)
            let rate: Double?
            switch source.distribution {
            case .poisson: rate = parameters["lambda"].flatMap(Double.init)
            case .exponential: rate = parameters["rate"].flatMap(Double.init)
            default:
                return .failure(.unsupportedArrival(source.name, source.distribution.displayName))
            }
            guard let rate, rate.isFinite, rate > 0 else {
                return .failure(.invalidArrivalRate(source.name))
            }
            var resolved = false
            for link in editor.links where link.fromNodeID == source.id
                    && link.routingProbability > 0 {
                guard let destination = resolveStation(
                    link.toNodeID, nodeByID: nodeByID,
                    links: editor.links, stationIndex: stationIndex
                ) else { continue }
                external[destination] += rate * link.routingProbability
                resolved = true
            }
            guard resolved else { return .failure(.unresolvedSource(source.name)) }
        }

        var routing = Array(
            repeating: [Double](repeating: 0, count: stations.count),
            count: stations.count
        )
        var nodeDocuments: [[String: Any]] = []
        for (index, station) in stations.enumerated() {
            let config = station.serviceDistributions[0]
                ?? ServiceDistributionConfig(
                    distribution: station.distribution,
                    distributionParameters: station.distributionParameters
                )
            guard config.distribution == .exponential else {
                return .failure(.unsupportedService(
                    station.name, CustomerClass.label(for: 0), config.distribution.displayName
                ))
            }
            let parameters = QueueDistribution.parseParameterStrings(config.distributionParameters)
            guard let serviceRate = parameters["rate"].flatMap(Double.init),
                  serviceRate.isFinite, serviceRate > 0 else {
                return .failure(.invalidServiceRate(station.name, CustomerClass.label(for: 0)))
            }
            let outgoing = editor.links.filter {
                $0.fromNodeID == station.id && $0.customerClass == 0
            }
            let total = outgoing.reduce(0.0) { $0 + $1.routingProbability }
            guard total <= 1 + 1e-9 else {
                return .failure(.routingExceedsOne(
                    station.name, CustomerClass.label(for: 0), total
                ))
            }
            for link in outgoing where link.routingProbability > 0 {
                if let destination = resolveStation(
                    link.toNodeID, nodeByID: nodeByID,
                    links: editor.links, stationIndex: stationIndex
                ) {
                    routing[index][destination] += link.routingProbability
                }
            }
            nodeDocuments.append([
                "name": station.name,
                "external_arrival_rate": external[index],
                "service_rate_per_server": serviceRate,
                "servers": station.numberOfServers
            ])
        }

        let document: [String: Any] = [
            "schema_version": 1,
            "process": "open_single_class_markovian_network",
            "name": name,
            "nodes": nodeDocuments,
            "routing": routing,
            "solver": [
                "initial_total_cap": max(1, initialTotalCap),
                "max_total_cap": max(initialTotalCap, maxTotalCap),
                "growth_factor": 1.6,
                "minimum_cap_increment": 2,
                "max_states": max(1, maxStates),
                "stationary_tolerance": 1e-13,
                "stationary_max_iterations": 200_000,
                "boundary_mass_tolerance": 1e-8,
                "refinement_relative_tolerance": 1e-7,
                "stability_tolerance": 1e-12,
                "routing_tolerance": 1e-12,
                "tail_levels": [0, 1, 5, 10, 20],
                "top_state_count": 0,
                "include_state_probabilities": false
            ] as [String: Any]
        ]
        return encode(document)
    }

    private static func model(
        editor: NetworkEditorModel
    ) -> Result<Model, FiniteMarkovExportError> {
        let stations = editor.stationsInExportOrder
        guard !stations.isEmpty else { return .failure(.noStations) }
        let sources = editor.nodes.filter { $0.kind == .source }
            .sorted { NodeNaming.sortIndex($0.name) < NodeNaming.sortIndex($1.name) }
        guard !sources.isEmpty else { return .failure(.noSources) }

        let stationIndex = Dictionary(
            uniqueKeysWithValues: stations.enumerated().map { ($0.element.id, $0.offset) }
        )
        let nodeByID = Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })

        var classIndices = Set<Int>()
        for source in sources { classIndices.insert(editor.customerClassIndex(for: source.id)) }
        for station in stations { classIndices.formUnion(station.serviceDistributions.keys) }
        for link in editor.links {
            classIndices.insert(link.customerClass)
            classIndices.insert(link.exitClass)
        }
        let maximumClass = max(classIndices.max() ?? 0, 0)
        let classes = (0...maximumClass).map(classID)

        var stationSpecs: [StationSpec] = []
        for (index, station) in stations.enumerated() {
            let feedingBuffers = editor.nodes.filter { candidate in
                guard candidate.kind == .buffer else { return false }
                return editor.links.contains {
                    $0.fromNodeID == candidate.id && $0.toNodeID == station.id
                }
            }
            guard !feedingBuffers.isEmpty else {
                return .failure(.missingBuffer(station.name))
            }
            guard feedingBuffers.count == 1 else {
                return .failure(.multipleBuffers(station.name))
            }

            var rates: [String: Double] = [:]
            for classIndex in 0...maximumClass {
                let config = station.serviceDistributions[classIndex]
                    ?? ServiceDistributionConfig(
                        distribution: station.distribution,
                        distributionParameters: station.distributionParameters
                    )
                guard config.distribution == .exponential else {
                    return .failure(.unsupportedService(
                        station.name,
                        CustomerClass.label(for: classIndex),
                        config.distribution.displayName
                    ))
                }
                let parameters = QueueDistribution.parseParameterStrings(
                    config.distributionParameters
                )
                guard let rate = parameters["rate"].flatMap(Double.init),
                      rate.isFinite, rate > 0 else {
                    return .failure(.invalidServiceRate(
                        station.name, CustomerClass.label(for: classIndex)
                    ))
                }
                rates[classID(classIndex)] = rate
            }
            stationSpecs.append(StationSpec(
                id: stationID(index),
                name: station.name,
                servers: station.numberOfServers,
                capacity: station.numberOfServers + feedingBuffers[0].bufferSize,
                serviceRates: rates
            ))
        }

        var arrivals: [ArrivalSpec] = []
        for source in sources {
            let sourceClass = editor.customerClassIndex(for: source.id)
            let parameters = QueueDistribution.parseParameterStrings(
                source.distributionParameters
            )
            let rate: Double?
            switch source.distribution {
            case .poisson: rate = parameters["lambda"].flatMap(Double.init)
            case .exponential: rate = parameters["rate"].flatMap(Double.init)
            default:
                return .failure(.unsupportedArrival(
                    source.name, source.distribution.displayName
                ))
            }
            guard let rate, rate.isFinite, rate > 0 else {
                return .failure(.invalidArrivalRate(source.name))
            }
            var resolved = false
            for link in editor.links where link.fromNodeID == source.id
                    && link.routingProbability > 0 {
                guard let destination = resolveStation(
                    link.toNodeID, nodeByID: nodeByID,
                    links: editor.links, stationIndex: stationIndex
                ) else { continue }
                resolved = true
                arrivals.append(ArrivalSpec(
                    station: stationID(destination),
                    customerClass: classID(link.hasClassTransition ? link.exitClass : sourceClass),
                    rate: rate * link.routingProbability
                ))
            }
            guard resolved else { return .failure(.unresolvedSource(source.name)) }
        }

        var routing: [RoutingSpec] = []
        for (fromIndex, station) in stations.enumerated() {
            for classIndex in 0...maximumClass {
                let outgoing = editor.links.filter {
                    $0.fromNodeID == station.id && $0.customerClass == classIndex
                }
                guard !outgoing.isEmpty else { continue }
                let total = outgoing.reduce(0.0) { $0 + $1.routingProbability }
                guard total <= 1 + 1e-9 else {
                    return .failure(.routingExceedsOne(
                        station.name, CustomerClass.label(for: classIndex), total
                    ))
                }
                var destinations: [DestinationSpec] = []
                for link in outgoing where link.routingProbability > 0 {
                    if let destination = resolveStation(
                        link.toNodeID, nodeByID: nodeByID,
                        links: editor.links, stationIndex: stationIndex
                    ) {
                        destinations.append(DestinationSpec(
                            station: stationID(destination),
                            customerClass: classID(link.exitClass),
                            probability: link.routingProbability,
                            exits: false
                        ))
                    } else {
                        destinations.append(DestinationSpec(
                            station: nil, customerClass: nil,
                            probability: link.routingProbability, exits: true
                        ))
                    }
                }
                routing.append(RoutingSpec(
                    fromStation: stationID(fromIndex),
                    fromClass: classID(classIndex),
                    destinations: destinations
                ))
            }
        }
        return .success(Model(
            classes: classes, stations: stationSpecs,
            arrivals: aggregate(arrivals), routing: routing
        ))
    }

    private static func resolveStation(
        _ nodeID: UUID,
        nodeByID: [UUID: NetworkNode],
        links: [NetworkLink],
        stationIndex: [UUID: Int]
    ) -> Int? {
        guard let node = nodeByID[nodeID] else { return nil }
        if node.kind == .station { return stationIndex[node.id] }
        guard node.kind == .buffer else { return nil }
        for link in links where link.fromNodeID == node.id {
            if let target = nodeByID[link.toNodeID], target.kind == .station {
                return stationIndex[target.id]
            }
        }
        return nil
    }

    private static func aggregate(_ arrivals: [ArrivalSpec]) -> [ArrivalSpec] {
        let grouped = Dictionary(grouping: arrivals) {
            "\($0.station)|\($0.customerClass)"
        }
        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            return ArrivalSpec(
                station: first.station,
                customerClass: first.customerClass,
                rate: group.reduce(0) { $0 + $1.rate }
            )
        }.sorted {
            ($0.station, $0.customerClass) < ($1.station, $1.customerClass)
        }
    }

    private static func ctmcRouting(_ row: RoutingSpec) -> [String: Any] {
        [
            "from_station": row.fromStation,
            "from_class": row.fromClass,
            "destinations": row.destinations.map { destination in
                if destination.exits {
                    return [
                        "exit": true,
                        "probability": destination.probability
                    ] as [String: Any]
                }
                return [
                    "station": destination.station ?? "",
                    "class": destination.customerClass ?? row.fromClass,
                    "probability": destination.probability
                ] as [String: Any]
            }
        ]
    }

    private static func encode(
        _ document: [String: Any]
    ) -> Result<String, FiniteMarkovExportError> {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            guard let string = String(data: data, encoding: .utf8) else {
                return .failure(.encoding("UTF-8 conversion failed."))
            }
            return .success(string + "\n")
        } catch {
            return .failure(.encoding(error.localizedDescription))
        }
    }

    private static func stationID(_ index: Int) -> String { "s\(index + 1)" }
    private static func classID(_ index: Int) -> String { "c\(index + 1)" }
    private static func className(_ identifier: String) -> String {
        guard identifier.hasPrefix("c"),
              let number = Int(identifier.dropFirst()) else { return identifier }
        return CustomerClass.label(for: max(number - 1, 0))
    }
}
