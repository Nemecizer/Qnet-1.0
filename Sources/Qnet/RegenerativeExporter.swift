import Foundation

enum RegenerativeExportError: LocalizedError {
    case emptyName
    case noStations
    case noSources
    case invalidServerCount(String, Int)
    case missingBuffer(String)
    case multipleBuffers(String)
    case sharedBuffer(String, [String])
    case invalidBufferSize(String, Int)
    case capacityOverflow(String)
    case unsupportedArrival(String, String)
    case invalidArrivalRate(String)
    case unresolvedSource(String)
    case sourceClassMismatch(String, String, String)
    case classTransition(String, String, String, String)
    case unknownClass(String, Int)
    case unsupportedService(String, String, String)
    case invalidServiceRate(String, String)
    case classDependentService(String, String, Double, String, Double)
    case invalidRoutingProbability(String, Double)
    case routingExceedsOne(String, String, Double)
    case missingOrigin
    case missingDestination(String)
    case unsupportedDestination(String, String)
    case bufferWithoutStation(String)
    case bufferWithMultipleStations(String, [String])
    case bufferWithUnsupportedDestination(String, String)
    case bufferConnectionProbability(String, String, Double)
    case closedRouting(String, String)
    case invalidTrafficEquations(String, String)
    case unstableStation(String, Double)
    case invalidStopping(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name for the regenerative simulation input."
        case .noStations:
            return "The network has no service stations. Add at least one station before exporting."
        case .noSources:
            return "The network has no external arrival source. Add at least one source before exporting."
        case .invalidServerCount(let station, let count):
            return "\(station) has \(count) servers. Regenerative simulation requires at least one server at every station."
        case .missingBuffer(let station):
            return "\(station) needs exactly one upstream buffer to define its finite total capacity."
        case .multipleBuffers(let station):
            return "\(station) has more than one upstream buffer. Use one buffer per station before exporting a finite network."
        case .sharedBuffer(let buffer, let stations):
            return "\(buffer) feeds more than one station (\(stations.joined(separator: ", "))). Give each finite station its own upstream buffer."
        case .invalidBufferSize(let buffer, let size):
            return "\(buffer) has waiting capacity \(size). Finite regenerative simulation requires a nonnegative waiting capacity."
        case .capacityOverflow(let station):
            return "\(station)'s server count plus waiting capacity is too large to export. Reduce one of those values."
        case .unsupportedArrival(let source, let distribution):
            return "\(source) uses \(distribution) arrivals. Regenerative simulation requires a Poisson process (Poisson or exponential inter-arrivals)."
        case .invalidArrivalRate(let source):
            return "\(source) does not contain a positive finite arrival rate."
        case .unresolvedSource(let source):
            return "\(source) does not send positive-rate arrivals to a service station. Connect it directly, or through a buffer, to one or more stations."
        case .sourceClassMismatch(let source, let expected, let actual):
            return "A route from \(source) is labelled \(actual), but that source creates \(expected). Change the route to preserve the source class."
        case .classTransition(let from, let to, let incoming, let outgoing):
            return "The route from \(from) to \(to) changes \(incoming) to \(outgoing). Regenerative simulation currently requires class-preserving routing."
        case .unknownClass(let location, let index):
            return "A route from \(location) uses class \(index + 1), but there is no matching external source. Add the source or change the route class."
        case .unsupportedService(let station, let customerClass, let distribution):
            return "\(station), \(customerClass) uses \(distribution) service. Regenerative simulation requires exponential FCFS service."
        case .invalidServiceRate(let station, let customerClass):
            return "\(station), \(customerClass) does not contain a positive finite exponential service rate."
        case .classDependentService(
            let station, let firstClass, let firstRate, let otherClass, let otherRate
        ):
            return "\(station) has class-dependent service rates: \(firstClass) uses \(Self.number(firstRate)) and \(otherClass) uses \(Self.number(otherRate)). Set one common exponential rate for every class at that station."
        case .invalidRoutingProbability(let location, let probability):
            return "A route from \(location) has probability \(Self.number(probability)). Routing probabilities must be finite and between 0 and 1."
        case .routingExceedsOne(let location, let customerClass, let total):
            return "Routing probabilities from \(location) for \(customerClass) total \(Self.number(total)), above 1. Reduce the outgoing probabilities so their sum is at most 1."
        case .missingOrigin:
            return "A route starts at a node that is no longer in the document. Delete that route and reconnect the remaining nodes."
        case .missingDestination(let location):
            return "A route from \(location) points to a node that is no longer in the document. Delete or reconnect that route."
        case .unsupportedDestination(let location, let destination):
            return "A route from \(location) points to source \(destination). Routes may lead only to a station, an upstream buffer, or an exit sink."
        case .bufferWithoutStation(let buffer):
            return "\(buffer) is used as a route destination but does not feed a service station. Connect it to exactly one station."
        case .bufferWithMultipleStations(let buffer, let stations):
            return "\(buffer) is used as a route destination but feeds multiple stations (\(stations.joined(separator: ", "))). Split it into one buffer per station."
        case .bufferWithUnsupportedDestination(let buffer, let destination):
            return "\(buffer) has a positive outgoing route to \(destination). An upstream buffer must feed exactly one service station and have no other positive outgoing routes."
        case .bufferConnectionProbability(let buffer, let station, let probability):
            return "The structural route from \(buffer) to \(station) has probability \(Self.number(probability)). Set it to 1 so every waiting job enters that station."
        case .closedRouting(let customerClass, let station):
            return "\(customerClass) cannot reach an exit from \(station). Lower at least one routing row sum below 1 or add a positive-probability path to a sink."
        case .invalidTrafficEquations(let customerClass, let detail):
            return "The traffic equations for \(customerClass) could not be solved reliably (\(detail)). Add exit probability or move the routing probabilities farther from a closed loop."
        case .unstableStation(let station, let offeredLoad):
            return "\(station) has infinite-buffer offered load \(Self.number(offeredLoad)), but regenerative steady state requires load below 1. Reduce arrivals/routing or add service capacity."
        case .invalidStopping(let message):
            return "The regenerative stopping settings are invalid: \(message)"
        case .encoding(let message):
            return "The regenerative simulation input could not be encoded: \(message)"
        }
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return String(describing: value) }
        return String(format: "%.7g", value)
    }
}

/// Sequential fixed-width settings written explicitly into schema-version 1
/// input. The defaults mirror `regenerative_mc.py`, so a saved input records
/// the stopping contract instead of relying on implicit parser defaults.
struct RegenerativeStoppingOptions: Equatable, Sendable {
    let confidence: Double
    let absoluteHalfWidth: Double
    let relativeHalfWidth: Double
    let minimumCycles: Int
    let minimumEffectiveCycles: Double
    let minimumPositiveCycles: Int
    let checkEveryCycles: Int
    let maximumCycles: Int
    let maximumEvents: Int
    let maximumSimulatedTime: Double
    let maximumCycleTime: Double
    let maximumEventsPerCycle: Int
    let maximumWallSeconds: Double

    init(
        confidence: Double = 0.95,
        absoluteHalfWidth: Double = 0.02,
        relativeHalfWidth: Double = 0.05,
        minimumCycles: Int = 200,
        minimumEffectiveCycles: Double = 30,
        minimumPositiveCycles: Int = 5,
        checkEveryCycles: Int = 50,
        maximumCycles: Int = 100_000,
        maximumEvents: Int = 10_000_000,
        maximumSimulatedTime: Double = 1_000_000_000,
        maximumCycleTime: Double = 10_000_000,
        maximumEventsPerCycle: Int = 2_000_000,
        maximumWallSeconds: Double = 120
    ) {
        self.confidence = confidence
        self.absoluteHalfWidth = absoluteHalfWidth
        self.relativeHalfWidth = relativeHalfWidth
        self.minimumCycles = minimumCycles
        self.minimumEffectiveCycles = minimumEffectiveCycles
        self.minimumPositiveCycles = minimumPositiveCycles
        self.checkEveryCycles = checkEveryCycles
        self.maximumCycles = maximumCycles
        self.maximumEvents = maximumEvents
        self.maximumSimulatedTime = maximumSimulatedTime
        self.maximumCycleTime = maximumCycleTime
        self.maximumEventsPerCycle = maximumEventsPerCycle
        self.maximumWallSeconds = maximumWallSeconds
    }
}

/// Converts a visual Qnet document to the narrow Markovian model accepted by
/// `infinite/regenerative_mc/regenerative_mc.py`. Unsupported primitives are
/// rejected rather than silently approximated.
@MainActor
enum RegenerativeExporter {
    private static let routingTolerance = 1e-12
    private static let exitPathTolerance = 1e-14
    private static let rateTolerance = 1e-10

    private struct NodeDocument: Encodable {
        let id: String
        let servers: Int
        let serviceRate: Double
        let capacity: Int?

        enum CodingKeys: String, CodingKey {
            case id, servers, capacity
            case serviceRate = "service_rate"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(servers, forKey: .servers)
            try container.encode(serviceRate, forKey: .serviceRate)
            if let capacity {
                try container.encode(capacity, forKey: .capacity)
            } else {
                try container.encodeNil(forKey: .capacity)
            }
        }
    }

    private struct ClassDocument: Encodable {
        let id: String
        let externalArrivalRates: [String: Double]
        let routing: [String: [String: Double]]

        enum CodingKeys: String, CodingKey {
            case id, routing
            case externalArrivalRates = "external_arrival_rates"
        }
    }

    private struct RandomDocument: Encodable {
        let baseSeed: UInt64
        let stream: UInt64

        enum CodingKeys: String, CodingKey {
            case baseSeed = "base_seed"
            case stream
        }
    }

    private struct RareEventDocument: Encodable {
        let method: String
    }

    private struct StoppingDocument: Encodable {
        let confidence: Double
        let absoluteHalfWidth: Double
        let relativeHalfWidth: Double
        let monitoredMetrics: [String]
        let minimumCycles: Int
        let minimumEffectiveCycles: Double
        let minimumPositiveCycles: Int
        let checkEveryCycles: Int
        let maximumCycles: Int
        let maximumEvents: Int
        let maximumSimulatedTime: Double
        let maximumCycleTime: Double
        let maximumEventsPerCycle: Int
        let maximumWallSeconds: Double

        enum CodingKeys: String, CodingKey {
            case confidence
            case absoluteHalfWidth = "absolute_half_width"
            case relativeHalfWidth = "relative_half_width"
            case monitoredMetrics = "monitored_metrics"
            case minimumCycles = "minimum_cycles"
            case minimumEffectiveCycles = "minimum_effective_cycles"
            case minimumPositiveCycles = "minimum_positive_cycles"
            case checkEveryCycles = "check_every_cycles"
            case maximumCycles = "maximum_cycles"
            case maximumEvents = "maximum_events"
            case maximumSimulatedTime = "maximum_simulated_time"
            case maximumCycleTime = "maximum_cycle_time"
            case maximumEventsPerCycle = "maximum_events_per_cycle"
            case maximumWallSeconds = "maximum_wall_seconds"
        }
    }

    private struct InputDocument: Encodable {
        let schemaVersion: Int
        let process: String
        let name: String
        let nodes: [NodeDocument]
        let classes: [ClassDocument]
        let initialJobs: [String: [String: Int]]
        let random: RandomDocument
        let stopping: StoppingDocument
        let rareEvent: RareEventDocument

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case process, name, nodes, classes, random, stopping
            case initialJobs = "initial_jobs"
            case rareEvent = "rare_event"
        }
    }

    private enum ResolvedDestination {
        case station(Int)
        case exit
    }

    private enum TrafficEquationError: Error {
        case singular
        case negativeRate
        case illConditioned(Double, Double)
        case nonfinite

        var detail: String {
            switch self {
            case .singular:
                return "the routing matrix is closed or numerically singular"
            case .negativeRate:
                return "the solution contains a negative arrival rate"
            case .illConditioned(let residual, let tolerance):
                return "residual \(String(format: "%.7g", residual)) exceeds tolerance \(String(format: "%.7g", tolerance))"
            case .nonfinite:
                return "the numerical solution is not finite"
            }
        }
    }

    static func export(
        editor: NetworkEditorModel,
        name: String,
        baseSeed: UInt64 = 20_260_904,
        stream: UInt64 = 0,
        stopping: RegenerativeStoppingOptions = .init()
    ) -> Result<String, RegenerativeExportError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.emptyName) }
        if let error = validate(stopping) { return .failure(error) }

        let stations = editor.stationsInExportOrder
        guard !stations.isEmpty else { return .failure(.noStations) }
        let sources = editor.nodes.filter { $0.kind == .source }
            .sorted { NodeNaming.sortIndex($0.name) < NodeNaming.sortIndex($1.name) }
        guard !sources.isEmpty else { return .failure(.noSources) }

        let nodeByID = Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })
        let stationIndex = Dictionary(
            uniqueKeysWithValues: stations.enumerated().map { ($0.element.id, $0.offset) }
        )
        let classCount = sources.count

        for station in stations where station.numberOfServers <= 0 {
            return .failure(.invalidServerCount(station.name, station.numberOfServers))
        }

        for link in editor.links {
            guard let origin = nodeByID[link.fromNodeID] else {
                return .failure(.missingOrigin)
            }
            guard nodeByID[link.toNodeID] != nil else {
                return .failure(.missingDestination(origin.name))
            }
            guard link.routingProbability.isFinite,
                  (0...1).contains(link.routingProbability) else {
                return .failure(.invalidRoutingProbability(
                    origin.name, link.routingProbability
                ))
            }
            guard link.routingProbability > 0 else { continue }
            if link.hasClassTransition {
                let from = origin.name
                let to = nodeByID[link.toNodeID]?.name ?? "a missing node"
                return .failure(.classTransition(
                    from,
                    to,
                    classLabel(link.customerClass),
                    classLabel(link.exitClass)
                ))
            }
            if origin.kind == .source || origin.kind == .station {
                guard (0..<classCount).contains(link.customerClass) else {
                    return .failure(.unknownClass(origin.name, link.customerClass))
                }
            }
        }

        var capacities = [Int?](repeating: nil, count: stations.count)
        if !editor.infiniteBuffers {
            var stationsByBuffer: [UUID: [String]] = [:]
            for (index, station) in stations.enumerated() {
                let feedingBuffers = editor.nodes.filter { candidate in
                    candidate.kind == .buffer && editor.links.contains {
                        $0.fromNodeID == candidate.id
                            && $0.toNodeID == station.id
                            && $0.routingProbability > 0
                    }
                }
                guard !feedingBuffers.isEmpty else {
                    return .failure(.missingBuffer(station.name))
                }
                guard feedingBuffers.count == 1 else {
                    return .failure(.multipleBuffers(station.name))
                }
                let buffer = feedingBuffers[0]
                switch resolveBuffer(
                    buffer,
                    nodeByID: nodeByID,
                    links: editor.links,
                    stationIndex: stationIndex
                ) {
                case .failure(let error):
                    return .failure(error)
                case .success(let destination) where destination != index:
                    return .failure(.bufferWithMultipleStations(
                        buffer.name,
                        [station.name, stations[destination].name].sorted()
                    ))
                case .success:
                    break
                }
                guard buffer.bufferSize >= 0 else {
                    return .failure(.invalidBufferSize(buffer.name, buffer.bufferSize))
                }
                stationsByBuffer[buffer.id, default: []].append(station.name)
                let (capacity, overflow) = station.numberOfServers
                    .addingReportingOverflow(buffer.bufferSize)
                guard !overflow else {
                    return .failure(.capacityOverflow(station.name))
                }
                capacities[index] = capacity
            }
            if let shared = stationsByBuffer.first(where: { $0.value.count > 1 }),
               let buffer = nodeByID[shared.key] {
                return .failure(.sharedBuffer(buffer.name, shared.value.sorted()))
            }
        }

        var nodeDocuments: [NodeDocument] = []
        for (index, station) in stations.enumerated() {
            var reference: (customerClass: String, rate: Double)?
            for classIndex in 0..<classCount {
                let label = classLabel(classIndex)
                let config = station.serviceDistributions[classIndex]
                    ?? ServiceDistributionConfig(
                        distribution: station.distribution,
                        distributionParameters: station.distributionParameters
                    )
                guard config.distribution == .exponential else {
                    return .failure(.unsupportedService(
                        station.name, label, config.distribution.displayName
                    ))
                }
                let parameters = QueueDistribution.parseParameterStrings(
                    config.distributionParameters
                )
                guard let rate = parameters["rate"].flatMap(Double.init),
                      rate.isFinite, rate > 0 else {
                    return .failure(.invalidServiceRate(station.name, label))
                }
                if let reference,
                   !ratesMatch(reference.rate, rate) {
                    return .failure(.classDependentService(
                        station.name,
                        reference.customerClass,
                        reference.rate,
                        label,
                        rate
                    ))
                }
                if reference == nil { reference = (label, rate) }
            }
            guard let serviceRate = reference?.rate else {
                return .failure(.invalidServiceRate(station.name, classLabel(0)))
            }
            nodeDocuments.append(NodeDocument(
                id: stationID(index),
                servers: station.numberOfServers,
                serviceRate: serviceRate,
                capacity: capacities[index]
            ))
        }

        var externalByClass = Array(
            repeating: [String: Double](), count: classCount
        )
        for (classIndex, source) in sources.enumerated() {
            let parameters = QueueDistribution.parseParameterStrings(
                source.distributionParameters
            )
            let rate: Double?
            switch source.distribution {
            case .poisson:
                rate = parameters["lambda"].flatMap(Double.init)
            case .exponential:
                rate = parameters["rate"].flatMap(Double.init)
            default:
                return .failure(.unsupportedArrival(
                    source.name, source.distribution.displayName
                ))
            }
            guard let rate, rate.isFinite, rate > 0 else {
                return .failure(.invalidArrivalRate(source.name))
            }

            let outgoing = editor.links.filter { $0.fromNodeID == source.id }
            for link in outgoing where link.routingProbability > 0
                    && link.customerClass != classIndex {
                return .failure(.sourceClassMismatch(
                    source.name,
                    classLabel(classIndex),
                    classLabel(link.customerClass)
                ))
            }
            let total = outgoing.reduce(0.0) { $0 + $1.routingProbability }
            guard total <= 1 + routingTolerance else {
                return .failure(.routingExceedsOne(
                    source.name, classLabel(classIndex), total
                ))
            }
            let normalization = total > 1 ? total : 1
            for link in outgoing where link.routingProbability > 0 {
                switch resolve(
                    link.toNodeID,
                    from: source.name,
                    nodeByID: nodeByID,
                    links: editor.links,
                    stationIndex: stationIndex
                ) {
                case .failure(let error):
                    return .failure(error)
                case .success(.exit):
                    continue
                case .success(.station(let destination)):
                    let id = stationID(destination)
                    externalByClass[classIndex][id, default: 0]
                        += rate * link.routingProbability / normalization
                }
            }
            guard !externalByClass[classIndex].isEmpty else {
                return .failure(.unresolvedSource(source.name))
            }
        }

        var classDocuments: [ClassDocument] = []
        var routingMatrices: [[[Double]]] = []
        for classIndex in 0..<classCount {
            var matrix = Array(
                repeating: [Double](repeating: 0, count: stations.count),
                count: stations.count
            )
            var rows: [String: [String: Double]] = [:]
            for (fromIndex, station) in stations.enumerated() {
                let outgoing = editor.links.filter {
                    $0.fromNodeID == station.id && $0.customerClass == classIndex
                }
                let total = outgoing.reduce(0.0) { $0 + $1.routingProbability }
                guard total <= 1 + routingTolerance else {
                    return .failure(.routingExceedsOne(
                        station.name, classLabel(classIndex), total
                    ))
                }
                let normalization = total > 1 ? total : 1
                var destinations: [String: Double] = [:]
                for link in outgoing where link.routingProbability > 0 {
                    switch resolve(
                        link.toNodeID,
                        from: station.name,
                        nodeByID: nodeByID,
                        links: editor.links,
                        stationIndex: stationIndex
                    ) {
                    case .failure(let error):
                        return .failure(error)
                    case .success(.exit):
                        continue
                    case .success(.station(let destination)):
                        let probability = link.routingProbability / normalization
                        matrix[fromIndex][destination] += probability
                        destinations[stationID(destination), default: 0] += probability
                    }
                }
                rows[stationID(fromIndex)] = destinations
            }
            if let closedIndex = firstStationWithoutExitPath(matrix) {
                return .failure(.closedRouting(
                    classLabel(classIndex), stations[closedIndex].name
                ))
            }
            classDocuments.append(ClassDocument(
                id: classID(classIndex),
                externalArrivalRates: externalByClass[classIndex],
                routing: rows
            ))
            routingMatrices.append(matrix)
        }

        var totalTraffic = [Double](repeating: 0, count: stations.count)
        for classIndex in 0..<classCount {
            let external = stations.indices.map {
                externalByClass[classIndex][stationID($0)] ?? 0
            }
            do {
                let rates = try trafficRates(
                    routing: routingMatrices[classIndex], external: external
                )
                for stationIndex in stations.indices {
                    totalTraffic[stationIndex] += rates[stationIndex]
                }
            } catch let error as TrafficEquationError {
                return .failure(.invalidTrafficEquations(
                    classLabel(classIndex), error.detail
                ))
            } catch {
                return .failure(.invalidTrafficEquations(
                    classLabel(classIndex), error.localizedDescription
                ))
            }
        }
        if editor.infiniteBuffers {
            for index in stations.indices {
                let serviceCapacity = Double(nodeDocuments[index].servers)
                    * nodeDocuments[index].serviceRate
                let offeredLoad = totalTraffic[index] / serviceCapacity
                guard offeredLoad.isFinite else {
                    return .failure(.invalidTrafficEquations(
                        "all classes", "the offered load at \(stations[index].name) is not finite"
                    ))
                }
                guard offeredLoad < 1 - routingTolerance else {
                    return .failure(.unstableStation(
                        stations[index].name, offeredLoad
                    ))
                }
            }
        }

        let document = InputDocument(
            schemaVersion: 1,
            process: "open_markovian_queueing_network",
            name: trimmedName,
            nodes: nodeDocuments,
            classes: classDocuments,
            initialJobs: [:],
            random: RandomDocument(baseSeed: baseSeed, stream: stream),
            stopping: stoppingDocument(stopping),
            rareEvent: RareEventDocument(method: "none")
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            guard let string = String(data: data, encoding: .utf8) else {
                return .failure(.encoding("UTF-8 conversion failed."))
            }
            return .success(string + "\n")
        } catch {
            return .failure(.encoding(error.localizedDescription))
        }
    }

    private static func resolve(
        _ destinationID: UUID,
        from location: String,
        nodeByID: [UUID: NetworkNode],
        links: [NetworkLink],
        stationIndex: [UUID: Int]
    ) -> Result<ResolvedDestination, RegenerativeExportError> {
        guard let destination = nodeByID[destinationID] else {
            return .failure(.missingDestination(location))
        }
        switch destination.kind {
        case .station:
            guard let index = stationIndex[destination.id] else {
                return .failure(.missingDestination(location))
            }
            return .success(.station(index))
        case .sink:
            return .success(.exit)
        case .source:
            return .failure(.unsupportedDestination(location, destination.name))
        case .buffer:
            return resolveBuffer(
                destination,
                nodeByID: nodeByID,
                links: links,
                stationIndex: stationIndex
            ).map(ResolvedDestination.station)
        }
    }

    /// A buffer is a structural waiting-room connector, not a probabilistic
    /// service stage. Requiring its one active station edge to have probability
    /// one prevents the exporter from silently discarding buffer branches.
    private static func resolveBuffer(
        _ buffer: NetworkNode,
        nodeByID: [UUID: NetworkNode],
        links: [NetworkLink],
        stationIndex: [UUID: Int]
    ) -> Result<Int, RegenerativeExportError> {
        let outgoing = links.filter {
            $0.fromNodeID == buffer.id && $0.routingProbability > 0
        }
        guard !outgoing.isEmpty else {
            return .failure(.bufferWithoutStation(buffer.name))
        }
        var stationIDs = Set<UUID>()
        for link in outgoing {
            guard let destination = nodeByID[link.toNodeID] else {
                return .failure(.missingDestination(buffer.name))
            }
            guard destination.kind == .station else {
                return .failure(.bufferWithUnsupportedDestination(
                    buffer.name, destination.name
                ))
            }
            guard abs(link.routingProbability - 1) <= routingTolerance else {
                return .failure(.bufferConnectionProbability(
                    buffer.name, destination.name, link.routingProbability
                ))
            }
            stationIDs.insert(destination.id)
        }
        guard stationIDs.count == 1 else {
            let names = stationIDs.compactMap { nodeByID[$0]?.name }.sorted()
            return .failure(.bufferWithMultipleStations(buffer.name, names))
        }
        guard let stationID = stationIDs.first,
              let index = stationIndex[stationID] else {
            return .failure(.bufferWithoutStation(buffer.name))
        }
        return .success(index)
    }

    /// Solves `lambda = external + lambda P` using the same scaled
    /// partial-pivot and residual policy as the regenerative parser.
    private static func trafficRates(
        routing: [[Double]],
        external: [Double]
    ) throws -> [Double] {
        let count = routing.count
        guard count > 0,
              external.count == count,
              routing.allSatisfy({ $0.count == count }) else {
            throw TrafficEquationError.singular
        }
        let equations = (0..<count).map { row in
            (0..<count).map { column in
                (row == column ? 1.0 : 0.0) - routing[column][row]
            }
        }
        var rates = try solveLinear(equations, external)
        guard rates.allSatisfy(\.isFinite) else {
            throw TrafficEquationError.nonfinite
        }
        let tolerance = 2e-11 * max(1, rates.max() ?? 0)
        guard (rates.min() ?? 0) >= -tolerance else {
            throw TrafficEquationError.negativeRate
        }
        rates = rates.map { max(0, $0) }
        var residual = 0.0
        for destination in 0..<count {
            let routed = (0..<count).reduce(0.0) {
                $0 + rates[$1] * routing[$1][destination]
            }
            residual = max(
                residual,
                abs(rates[destination] - external[destination] - routed)
            )
        }
        guard residual <= tolerance else {
            throw TrafficEquationError.illConditioned(residual, tolerance)
        }
        return rates
    }

    private static func solveLinear(
        _ matrix: [[Double]],
        _ rightHandSide: [Double]
    ) throws -> [Double] {
        let count = matrix.count
        var augmented = matrix.indices.map {
            matrix[$0] + [rightHandSide[$0]]
        }
        var scales = matrix.map { row in
            row.map(abs).max() ?? 0
        }
        guard scales.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw TrafficEquationError.singular
        }

        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(augmented[$0][column]) / scales[$0]
                    < abs(augmented[$1][column]) / scales[$1]
            }) else {
                throw TrafficEquationError.singular
            }
            let floor = 16 * Double.ulpOfOne * Double(count) * scales[pivot]
            guard abs(augmented[pivot][column]) > floor else {
                throw TrafficEquationError.singular
            }
            if pivot != column {
                augmented.swapAt(pivot, column)
                scales.swapAt(pivot, column)
            }
            let pivotValue = augmented[column][column]
            for row in (column + 1)..<count {
                let factor = augmented[row][column] / pivotValue
                augmented[row][column] = 0
                if column + 1 <= count {
                    for index in (column + 1)...count {
                        augmented[row][index] -= factor * augmented[column][index]
                    }
                }
            }
        }

        var answer = [Double](repeating: 0, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var remainder = augmented[row][count]
            if row + 1 < count {
                for column in (row + 1)..<count {
                    remainder -= augmented[row][column] * answer[column]
                }
            }
            answer[row] = remainder / augmented[row][row]
        }
        guard answer.allSatisfy(\.isFinite) else {
            throw TrafficEquationError.nonfinite
        }
        return answer
    }

    private static func firstStationWithoutExitPath(_ routing: [[Double]]) -> Int? {
        var canExit = Set(
            routing.indices.filter {
                routing[$0].reduce(0, +) < 1 - exitPathTolerance
            }
        )
        var changed = true
        while changed {
            changed = false
            for source in routing.indices where !canExit.contains(source) {
                if routing[source].indices.contains(where: {
                    routing[source][$0] > 0 && canExit.contains($0)
                }) {
                    canExit.insert(source)
                    changed = true
                }
            }
        }
        return routing.indices.first { !canExit.contains($0) }
    }

    private static func validate(
        _ options: RegenerativeStoppingOptions
    ) -> RegenerativeExportError? {
        guard options.confidence.isFinite,
              options.confidence > 0.5,
              options.confidence < 1 else {
            return .invalidStopping("confidence must be finite and strictly between 0.5 and 1.")
        }
        guard options.absoluteHalfWidth.isFinite,
              options.absoluteHalfWidth >= 0,
              options.relativeHalfWidth.isFinite,
              options.relativeHalfWidth >= 0,
              options.absoluteHalfWidth > 0 || options.relativeHalfWidth > 0 else {
            return .invalidStopping("half-width targets must be nonnegative and at least one must be positive.")
        }
        guard options.minimumCycles >= 30 else {
            return .invalidStopping("minimumCycles must be at least 30 for the regenerative t interval.")
        }
        guard options.minimumEffectiveCycles.isFinite,
              options.minimumEffectiveCycles > 0,
              options.minimumEffectiveCycles <= Double(options.minimumCycles) else {
            return .invalidStopping("minimumEffectiveCycles must be positive and no greater than minimumCycles.")
        }
        guard options.minimumPositiveCycles > 0 else {
            return .invalidStopping("minimumPositiveCycles must be positive.")
        }
        guard options.checkEveryCycles > 0 else {
            return .invalidStopping("checkEveryCycles must be positive.")
        }
        guard options.maximumCycles >= options.minimumCycles else {
            return .invalidStopping("maximumCycles cannot be less than minimumCycles.")
        }
        guard options.maximumEvents > 0 else {
            return .invalidStopping("maximumEvents must be positive.")
        }
        guard options.maximumSimulatedTime.isFinite,
              options.maximumSimulatedTime > 0 else {
            return .invalidStopping("maximumSimulatedTime must be positive and finite.")
        }
        guard options.maximumCycleTime.isFinite,
              options.maximumCycleTime > 0 else {
            return .invalidStopping("maximumCycleTime must be positive and finite.")
        }
        guard options.maximumEventsPerCycle > 0 else {
            return .invalidStopping("maximumEventsPerCycle must be positive.")
        }
        guard options.maximumWallSeconds.isFinite,
              options.maximumWallSeconds > 0 else {
            return .invalidStopping("maximumWallSeconds must be positive and finite.")
        }
        return nil
    }

    private static func stoppingDocument(
        _ options: RegenerativeStoppingOptions
    ) -> StoppingDocument {
        StoppingDocument(
            confidence: options.confidence,
            absoluteHalfWidth: options.absoluteHalfWidth,
            relativeHalfWidth: options.relativeHalfWidth,
            monitoredMetrics: ["mean_number_in_system"],
            minimumCycles: options.minimumCycles,
            minimumEffectiveCycles: options.minimumEffectiveCycles,
            minimumPositiveCycles: options.minimumPositiveCycles,
            checkEveryCycles: options.checkEveryCycles,
            maximumCycles: options.maximumCycles,
            maximumEvents: options.maximumEvents,
            maximumSimulatedTime: options.maximumSimulatedTime,
            maximumCycleTime: options.maximumCycleTime,
            maximumEventsPerCycle: options.maximumEventsPerCycle,
            maximumWallSeconds: options.maximumWallSeconds
        )
    }

    private static func ratesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= rateTolerance * max(1, max(abs(lhs), abs(rhs)))
    }

    private static func stationID(_ index: Int) -> String { "s\(index + 1)" }
    private static func classID(_ index: Int) -> String { "c\(index + 1)" }
    private static func classLabel(_ index: Int) -> String {
        CustomerClass.label(for: max(index, 0))
    }
}
