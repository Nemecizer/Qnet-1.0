import Foundation

enum BNANetworkExportError: LocalizedError {
    case noStations
    case noSource
    case noSink
    case stationMissingBuffer(String)
    case stationMultipleBuffers(String)
    case routingProbabilityExceedsOne(String, Double, Int)
    case sourceNotConnectedToStation1

    var errorDescription: String? {
        switch self {
        case .noStations:
            return "The network has no stations."
        case .noSource:
            return "The network has no source node."
        case .noSink:
            return "The network has no sink node."
        case .stationMissingBuffer(let name):
            return "Station \(name) has no buffer feeding into it."
        case .stationMultipleBuffers(let name):
            return "Station \(name) has more than one buffer feeding into it."
        case .routingProbabilityExceedsOne(let name, let sum, let classIdx):
            return "Routing probabilities from \(name) for \(CustomerClass.label(for: classIdx)) sum to \(String(format: "%.4f", sum)), which exceeds 1.0."
        case .sourceNotConnectedToStation1:
            return "The source must connect (possibly via a buffer) to station S1."
        }
    }
}

@MainActor
enum BNANetworkExporter {

    /// Exports the multi-class queueing network as a .sim file for jackson_sim.
    ///
    /// For K customer classes (= K sources) and d stations, the .sim file
    /// contains K*d classes.  Class index (k*d + i) represents customer
    /// class k served at station i.
    static func export(
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Result<String, BNANetworkExportError> {

        // ── Gather node groups ──────────────────────────────────────
        let sources = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        let sinks = nodes.filter { $0.kind == .sink }
        let stations = nodes.filter { $0.kind == .station }
            .sorted { stationIndex($0.name) < stationIndex($1.name) }

        guard !stations.isEmpty else { return .failure(.noStations) }
        guard !sources.isEmpty else { return .failure(.noSource) }
        guard !sinks.isEmpty else { return .failure(.noSink) }

        // Customer-class count — includes derived classes introduced by
        // Phase-1 class-transition links (toCustomerClass on a link).
        let maxLinkClass = links.reduce(-1) { acc, link in
            max(acc, link.customerClass, link.toCustomerClass ?? -1)
        }
        let K = max(sources.count, maxLinkClass + 1)
        let d = stations.count

        // ── Pair each station with its upstream buffer ──────────────
        for station in stations {
            let feedingBuffers = nodes.filter { candidate in
                candidate.kind == .buffer &&
                links.contains { $0.fromNodeID == candidate.id && $0.toNodeID == station.id }
            }
            guard feedingBuffers.count >= 1 else {
                return .failure(.stationMissingBuffer(station.name))
            }
            guard feedingBuffers.count == 1 else {
                return .failure(.stationMultipleBuffers(station.name))
            }
        }

        // ── Verify first source reaches station 1 ────────────────
        if !pathExists(from: sources[0].id, to: stations[0].id, nodes: nodes, links: links) {
            return .failure(.sourceNotConnectedToStation1)
        }

        // ── Build station index map ──────────────────────────────
        var stationIDToIndex: [UUID: Int] = [:]
        for (i, s) in stations.enumerated() {
            stationIDToIndex[s.id] = i
        }

        // ── Build per-class routing in class-expanded space ──────
        // jackson_sim's class vector spans (K · d) virtual classes, one
        // per (customer class, station) pair. A class transition on an
        // outgoing link writes its routing probability at index
        // `exitClass * d + targetStation` instead of
        // `customerClass * d + targetStation` — the simulator already
        // follows this convention natively, so class-change semantics
        // come for free at the format level.
        //
        // classRouting[k][i][(k', j)] = sum of routing probabilities
        // from (class k, station i) to (class k', station j).
        // Encoded as a (K·d)-length vector per originating (k, i).
        let totalClasses = K * d
        var classRouting = Array(
            repeating: Array(repeating: [Double](repeating: 0, count: totalClasses),
                             count: d),
            count: K
        )
        for classIdx in 0..<K {
            for (i, station) in stations.enumerated() {
                let outgoing = links.filter {
                    $0.fromNodeID == station.id && $0.customerClass == classIdx
                }
                for link in outgoing {
                    guard let targetStation = resolveTargetStation(
                        from: link.toNodeID, nodes: nodes, links: links,
                        stationIDToIndex: stationIDToIndex
                    ) else { continue }
                    let exitClass = link.toCustomerClass ?? classIdx
                    guard exitClass >= 0 && exitClass < K else { continue }
                    classRouting[classIdx][i][exitClass * d + targetStation]
                        += link.routingProbability
                }
                let rowSum = classRouting[classIdx][i].reduce(0, +)
                if rowSum > 1.0 + 1e-9 {
                    return .failure(.routingProbabilityExceedsOne(
                        station.name, rowSum, classIdx))
                }
            }
        }

        // ── Per-class, per-station external arrival rates ─────────
        // When a source routes *fractionally* to multiple buffers (e.g.
        // Src1 → B1 p=0.3, Src1 → B2 p=0.4, …), the Poisson arrival
        // process *thins* to rate λ·p at each destination. Previously
        // this exporter flagged each destination with the source's full
        // λ, producing N · λ total arrivals instead of λ — which
        // saturated every generated multi-buffer network. We now compute
        // the thinned rate per (class, station) and pass it to the sim.
        var externalRate = Array(
            repeating: [Double](repeating: 0, count: d),
            count: K
        )
        for (classIdx, source) in sources.enumerated() {
            let srcRate = extractSourceRate(
                distribution: source.distribution,
                parameters: source.distributionParameters
            )
            for link in links where link.fromNodeID == source.id {
                if let idx = resolveTargetStation(
                    from: link.toNodeID, nodes: nodes, links: links,
                    stationIDToIndex: stationIDToIndex
                ) {
                    externalRate[classIdx][idx] += srcRate * link.routingProbability
                }
            }
        }

        // ── Format .sim output ───────────────────────────────────
        var lines = [String]()

        lines.append("# Jackson Network Simulation Input File")
        lines.append("# Generated by BNAGUI")
        lines.append("")
        lines.append("stations \(d)")
        lines.append("classes \(totalClasses)")
        lines.append("customer_classes \(K)")
        lines.append("")

        // Server counts per station
        lines.append("servers \(stations.map { String($0.numberOfServers) }.joined(separator: " "))")
        lines.append("")

        // Class blocks: index = k * d + i
        for k in 0..<K {
            for i in 0..<d {
                let classIndex = k * d + i
                let station = stations[i]
                let classLabel = K > 1
                    ? " (\(CustomerClass.label(for: k)) at \(station.name))"
                    : " (\(station.name))"

                lines.append("# Class \(classIndex)\(classLabel)")
                lines.append("class \(classIndex)")

                // External arrival. Rate is the source's base rate thinned
                // by its routing-probability to this buffer. For Poisson
                // sources thinning is exact; for general renewal sources
                // we scale the rate as an approximation (the simulation
                // is then an exponential surrogate for the arrival SCV
                // of the original process).
                let rate = externalRate[k][i]
                if rate > 1e-12 {
                    lines.append("    arrival exponential \(String(format: "%g", rate))")
                } else {
                    lines.append("    arrival none")
                }

                // Station assignment
                lines.append("    station \(i)")

                // Service distribution (per-class config if available)
                let dist: QueueDistribution
                let params: String
                if let config = station.serviceDistributions[k] {
                    dist = config.distribution
                    params = config.distributionParameters
                } else {
                    dist = station.distribution
                    params = station.distributionParameters
                }
                lines.append("    service \(formatDistribution(distribution: dist, parameters: params))")

                // Routing: totalClasses entries. Honors class transitions —
                // entries outside the k-block appear when an outgoing link
                // has a toCustomerClass different from k.
                let routingVec = classRouting[k][i]
                lines.append("    routing \(routingVec.map { String(format: "%g", $0) }.joined(separator: " "))")

                lines.append("end_class")
                lines.append("")
            }
        }

        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func stationIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    private static func sourceIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    private static func resolveTargetStation(
        from nodeID: UUID,
        nodes: [NetworkNode],
        links: [NetworkLink],
        stationIDToIndex: [UUID: Int]
    ) -> Int? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }

        switch node.kind {
        case .station:
            return stationIDToIndex[node.id]
        case .buffer:
            for link in links where link.fromNodeID == node.id {
                if let target = nodes.first(where: { $0.id == link.toNodeID }),
                   target.kind == .station {
                    return stationIDToIndex[target.id]
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func pathExists(
        from startID: UUID,
        to endID: UUID,
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Bool {
        var visited: Set<UUID> = []
        var queue: [UUID] = [startID]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == endID { return true }
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            for link in links where link.fromNodeID == current {
                queue.append(link.toNodeID)
            }
        }
        return false
    }

    /// Format a distribution for the jackson_sim .sim file.
    private static func formatDistribution(
        distribution: QueueDistribution,
        parameters: String
    ) -> String {
        let p = parseParams(parameters)

        switch distribution {
        case .exponential:
            let rate = p["rate"] ?? 1.0
            return "exponential \(String(format: "%g", rate))"
        case .gamma:
            let shape = p["shape"] ?? 2.0
            let scale = p["scale"] ?? 1.0
            return "gamma \(String(format: "%g", shape)) \(String(format: "%g", scale))"
        case .uniform:
            let lo = p["min"] ?? 0.5
            let hi = p["max"] ?? 1.5
            return "uniform \(String(format: "%g", lo)) \(String(format: "%g", hi))"
        case .constant:
            let value = p["value"] ?? 1.0
            return "deterministic \(String(format: "%g", value))"
        case .weibull:
            let shape = p["shape"] ?? 1.5
            let scale = p["scale"] ?? 1.0
            return "weibull \(String(format: "%g", shape)) \(String(format: "%g", scale))"
        case .erlang:
            let k = Int(p["k"] ?? 2.0)
            let rate = p["rate"] ?? 1.0
            return "erlang \(k) \(String(format: "%g", rate))"
        case .lognormal:
            let mu = p["mu"] ?? 0.0
            let sigma = p["sigma"] ?? 0.25
            return "lognormal \(String(format: "%g", mu)) \(String(format: "%g", sigma))"
        case .pareto:
            let shape = p["shape"] ?? 2.5
            let scale = p["scale"] ?? 1.0
            return "pareto \(String(format: "%g", shape)) \(String(format: "%g", scale))"
        case .poisson:
            // jackson_sim's `exponential X` means RATE = X (mean = 1/X),
            // see infinite/BNAsim/jackson_sim.c line 269. A Poisson
            // process with rate λ has Exp(λ) inter-arrivals — so we
            // pass λ through unchanged.
            let lambda = p["lambda"] ?? 1.0
            return "exponential \(String(format: "%g", lambda))"
        }
    }

    /// Returns the source's arrival rate (events per unit time) for the
    /// purpose of routing-probability thinning. Mirrors
    /// `BNASRBMExporter.extractRate` — for non-Poisson sources we treat
    /// `rate = 1 / mean` as the Poisson-equivalent rate.
    private static func extractSourceRate(
        distribution: QueueDistribution, parameters: String
    ) -> Double {
        let p = parseParams(parameters)
        switch distribution {
        case .exponential:
            return p["rate"] ?? 1.0
        case .poisson:
            return p["lambda"] ?? 1.0
        case .gamma:
            let shape = p["shape"] ?? 2.0
            let scale = p["scale"] ?? 1.0
            return 1.0 / (shape * scale)
        case .uniform:
            let lo = p["min"] ?? 0.5
            let hi = p["max"] ?? 1.5
            return 2.0 / (lo + hi)
        case .constant:
            let v = p["value"] ?? 1.0
            return v > 0 ? 1.0 / v : 0.0
        case .weibull:
            let shape = p["shape"] ?? 1.5
            let scale = p["scale"] ?? 1.0
            return 1.0 / (scale * tgamma(1.0 + 1.0 / shape))
        case .erlang:
            let k = p["k"] ?? 2.0
            let rate = p["rate"] ?? 1.0
            return rate / k
        case .lognormal:
            let mu = p["mu"] ?? 0.0
            let sigma = p["sigma"] ?? 0.25
            return 1.0 / exp(mu + sigma * sigma / 2.0)
        case .pareto:
            let a = p["shape"] ?? 2.5
            let s = p["scale"] ?? 1.0
            return a > 1.0 ? (a - 1.0) / (a * s) : 0.0
        }
    }

    private static func parseParams(_ s: String) -> [String: Double] {
        var result = [String: Double]()
        for pair in s.split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2,
               let val = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                result[String(parts[0]).trimmingCharacters(in: .whitespaces)] = val
            }
        }
        return result
    }
}
