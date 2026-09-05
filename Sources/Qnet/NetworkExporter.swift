import Foundation

enum NetworkExportError: LocalizedError {
    case noStations
    case noSource
    case noSink
    case stationMissingBuffer(String)
    case stationMultipleBuffers(String)
    case routingProbabilityExceedsOne(String, Double, Int)
    /// The traffic equations α = λ + P⊤α have no finite solution: some set of
    /// stations routes every job it receives back into itself, so its
    /// throughput is unbounded.  Carries the station whose α is undetermined
    /// and the customer class whose routing does it.
    case trafficEquationsSingular(String, Int)
    case sourceNotConnectedToStation1
    case sourceUnresolvedEntry(String)

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
        case .trafficEquationsSingular(let name, let classIdx):
            return "Routing for \(CustomerClass.label(for: classIdx)) returns every job that reaches \(name) to \(name), so its throughput is unbounded and no arrival rate can be computed. Lower a routing probability on that cycle, or send part of it to a sink."
        case .sourceNotConnectedToStation1:
            return "The source must connect (possibly via a buffer) to station S1."
        case .sourceUnresolvedEntry(let name):
            return "Source \(name) is not connected to a station (directly or via a buffer)."
        }
    }
}

@MainActor
enum NetworkExporter {

    /// Generates the plain-text export string for the queueing network.
    ///
    /// Multi-entry sources: a Qnet source with N outgoing links to N
    /// different entry stations is split into N synthetic simulator
    /// classes — each with its own arrival rate (= source.lambda *
    /// link.probability for Poisson, replicated parameters for other
    /// distributions), its own entry station, and a copy of the original
    /// class's routing matrix and per-station service distributions. For
    /// Poisson sources this is exact (Poisson thinning); for non-Poisson
    /// it independently splits the inter-arrival stream rather than
    /// sample-routing each arrival, which is a small approximation that
    /// keeps the simulator parser unchanged. Without this expansion the
    /// simulator collapses every external class onto a single entry
    /// station and produces dramatically wrong utilizations.
    static func export(
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Result<String, NetworkExportError> {

        // ── Gather node groups ──────────────────────────────────────
        let sources = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        let sinks = nodes.filter { $0.kind == .sink }
        let stations = nodes.filter { $0.kind == .station }
            .sorted { stationIndex($0.name) < stationIndex($1.name) }

        guard !stations.isEmpty else { return .failure(.noStations) }
        guard !sources.isEmpty else { return .failure(.noSource) }
        guard !sinks.isEmpty else { return .failure(.noSink) }

        let qnetClassCount = sources.count
        let d = stations.count

        // ── Pair each station with its upstream buffer ──────────────
        var bufferSizes: [Int] = []
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
            bufferSizes.append(feedingBuffers[0].bufferSize)
        }

        // ── Build station index map ──────────────────────────────
        var stationIDToIndex: [UUID: Int] = [:]
        for (i, s) in stations.enumerated() {
            stationIDToIndex[s.id] = i
        }

        // ── Build per-Qnet-class downstream routing matrices ─────
        // (used for both the synth class table below and any
        // single-class fallback callers.)
        var qnetRoutingMatrices: [[[Double]]] = []
        for classIdx in 0..<qnetClassCount {
            var matrix = Array(repeating: Array(repeating: 0.0, count: d), count: d)
            for (i, station) in stations.enumerated() {
                let outgoing = links.filter { $0.fromNodeID == station.id && $0.customerClass == classIdx }
                for link in outgoing {
                    if let targetStation = resolveTargetStation(
                        from: link.toNodeID, nodes: nodes, links: links, stationIDToIndex: stationIDToIndex
                    ) {
                        matrix[i][targetStation] += link.routingProbability
                    }
                }
                let rowSum = matrix[i].reduce(0, +)
                if rowSum > 1.0 + 1e-9 {
                    return .failure(.routingProbabilityExceedsOne(station.name, rowSum, classIdx))
                }
            }
            qnetRoutingMatrices.append(matrix)
        }

        // ── Expand each source × outgoing-link into a synth class ──
        // Each synth class has its own (entry station, arrival
        // distribution scaled by routing probability, downstream
        // routing matrix, per-station service distributions). This
        // preserves the source's split routing — without it the sim
        // collapses every external arrival onto S1.
        struct SynthClass {
            let qnetClass: Int            // for service / routing lookups
            let entryStation: Int          // 0-indexed station
            let distribution: QueueDistribution
            let parameters: String
        }
        var synth: [SynthClass] = []
        for source in sources {
            let qnetClass = sources.firstIndex(where: { $0.id == source.id }) ?? 0
            let outgoing = links.filter { $0.fromNodeID == source.id }
            guard !outgoing.isEmpty else {
                return .failure(.sourceUnresolvedEntry(source.name))
            }
            // Aggregate by entry-station so two links from the same
            // source to the same station collapse to one synth class.
            var probByEntry: [Int: Double] = [:]
            for link in outgoing {
                guard let entry = resolveTargetStation(
                    from: link.toNodeID, nodes: nodes, links: links,
                    stationIDToIndex: stationIDToIndex
                ) else { continue }
                probByEntry[entry, default: 0.0] += link.routingProbability
            }
            guard !probByEntry.isEmpty else {
                return .failure(.sourceUnresolvedEntry(source.name))
            }
            // Normalize in case the routing probabilities don't sum to
            // exactly 1 due to user-edited inputs.
            let total = probByEntry.values.reduce(0, +)
            guard total > 1e-9 else {
                return .failure(.sourceUnresolvedEntry(source.name))
            }
            for (entry, prob) in probByEntry.sorted(by: { $0.key < $1.key }) {
                let p = prob / total
                let scaledParams = scaleArrivalParameters(
                    distribution: source.distribution,
                    parameters: source.distributionParameters,
                    by: p
                )
                synth.append(SynthClass(
                    qnetClass: qnetClass,
                    entryStation: entry,
                    distribution: source.distribution,
                    parameters: scaledParams
                ))
            }
        }
        let K = synth.count

        // ── Per-(synth, station) class-label and routing maps ──
        // A synth class enters the network as its source's qnetClass,
        // but a re-entrant link (one carrying a `toCustomerClass`
        // relabel) means the *same* customer carries a different bnet
        // class label at a downstream station. Service rates and
        // downstream routing must be looked up by the customer's
        // *current* label, not the originating qnetClass.
        //
        // Without this, sim.txt picks the station's default fallback
        // service distribution for every re-entered class — silently
        // turning a stable ρ=0.7 reentrant network into a ρ>1 one
        // (this is the Kumar-Seidman exporter regression).
        var labelAtStation: [[Int?]] = []  // [synth][station] -> bnet class label
        var routingPerSynth: [[[Double]]] = []  // [synth][from][to] -> prob
        for cls in synth {
            var labels = Array<Int?>(repeating: nil, count: d)
            var matrix = Array(repeating: Array(repeating: 0.0, count: d), count: d)
            labels[cls.entryStation] = cls.qnetClass
            var queue: [(Int, Int)] = [(cls.entryStation, cls.qnetClass)]
            while !queue.isEmpty {
                let (i, label) = queue.removeFirst()
                let station = stations[i]
                let outgoing = links.filter {
                    $0.fromNodeID == station.id && $0.customerClass == label
                }
                for link in outgoing {
                    guard let t = resolveTargetStation(
                        from: link.toNodeID, nodes: nodes, links: links,
                        stationIDToIndex: stationIDToIndex
                    ) else { continue }
                    matrix[i][t] += link.routingProbability
                    let newLabel = link.toCustomerClass ?? link.customerClass
                    if labels[t] == nil {
                        labels[t] = newLabel
                        queue.append((t, newLabel))
                    }
                    // If labels[t] is already set with a different newLabel,
                    // this synth class visits the same station under two
                    // different labels — fBNAsim's per-class service rate
                    // can't capture that, so we keep the first label seen.
                    // True multi-relabel reentrance needs the 4-class
                    // spectral export (fm.in) instead.
                }
            }
            labelAtStation.append(labels)
            routingPerSynth.append(matrix)
        }

        // ── Format output ────────────────────────────────────────
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        var lines: [String] = []

        lines.append("# fBNA Queueing Network Export")
        lines.append("# Generated: \(timestamp)")
        lines.append("")

        lines.append("# num_classes")
        lines.append("\(K)")
        lines.append("")

        lines.append("# dimension")
        lines.append("\(d)")
        lines.append("")

        lines.append("# arrival_distributions")
        for cls in synth {
            lines.append("\(cls.distribution.rawValue) \(cls.parameters)")
        }
        lines.append("")

        // 1-indexed station IDs, one per synth class.
        lines.append("# arrival_stations")
        lines.append(synth.map { String($0.entryStation + 1) }.joined(separator: " "))
        lines.append("")

        lines.append("# servers_per_station")
        lines.append(stations.map { String($0.numberOfServers) }.joined(separator: " "))
        lines.append("")

        // Qnet's `bufferSize` on a buffer node is the waiting-room capacity
        // (excluding the in-service slot). The simulator's `buffer_sizes`
        // field has the same convention (its can_accept adds num_servers
        // separately), so emit the value verbatim. SRBM's total per-station
        // capacity is bufferSize + numberOfServers; the simulator's total
        // is also buffer_sizes + servers_per_station — these now agree.
        lines.append("# buffer_sizes")
        lines.append(bufferSizes.map { String($0) }.joined(separator: " "))
        lines.append("")

        lines.append("# service_distributions")
        for (sIdx, station) in stations.enumerated() {
            var distLine: [String] = []
            for (cIdx, cls) in synth.enumerated() {
                let label = labelAtStation[cIdx][sIdx] ?? cls.qnetClass
                if let config = station.serviceDistributions[label] {
                    distLine.append("\(config.distribution.rawValue) \(config.distributionParameters)")
                } else {
                    distLine.append("\(station.distribution.rawValue) \(station.distributionParameters)")
                }
            }
            lines.append(distLine.joined(separator: " | "))
        }
        lines.append("")

        for idx in 0..<synth.count {
            lines.append("# routing_matrix_class_\(idx + 1)")
            for row in routingPerSynth[idx] {
                lines.append(row.map { String(format: "%.6f", $0) }.joined(separator: " "))
            }
            lines.append("")
        }

        return .success(lines.joined(separator: "\n") + "\n")
    }

    /// Scales the arrival rate of a source by `factor` so a split
    /// routing-probability becomes a thinned arrival stream. Poisson is
    /// exact (Poisson thinning); for other distributions we leave the
    /// distribution shape unchanged and (best-effort) scale rate / scale
    /// parameters so the mean inter-arrival time is divided by `factor`.
    /// Falls back to verbatim parameters when no shape-preserving scaling
    /// is defined for that distribution — in that case the synth split is
    /// an approximation and the comparison should treat sim's marginals
    /// for those streams as best-effort.
    private static func scaleArrivalParameters(
        distribution: QueueDistribution,
        parameters: String,
        by factor: Double
    ) -> String {
        let parsed = QueueDistribution.parseParameterStrings(parameters)
        switch distribution {
        case .poisson:
            // poisson lambda=L  →  lambda=L*factor
            if let lam = Double(parsed["lambda"] ?? "") {
                return String(format: "lambda=%.6f", lam * factor)
            }
        case .exponential:
            // exponential rate=R  →  rate=R*factor (same mean scaling)
            if let r = Double(parsed["rate"] ?? "") {
                return String(format: "rate=%.6f", r * factor)
            }
        default:
            break
        }
        return parameters
    }

    // MARK: - Helpers

    /// Extracts the numeric suffix from a station name like "S3" → 3.
    private static func stationIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    /// Extracts the numeric suffix from a source name like "Src2" → 2.
    private static func sourceIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    /// Resolves which station a source feeds. Walks the source's first
    /// outgoing link; if the target is a station, that's the entry; if
    /// the target is a buffer, walks one more hop to the station behind
    /// the buffer. Returns nil if no path of this shape exists.
    private static func resolveEntryStationFromSource(
        source: NetworkNode,
        nodes: [NetworkNode],
        links: [NetworkLink],
        stationIDToIndex: [UUID: Int]
    ) -> Int? {
        // Pick the first outgoing link. Sources are conventionally
        // single-output (one source per class), so this should be
        // deterministic. If a source has multiple outgoing links the
        // first one wins — pathological topology, GUI normally doesn't
        // produce this.
        guard let firstLink = links.first(where: { $0.fromNodeID == source.id }) else {
            return nil
        }
        return resolveTargetStation(
            from: firstLink.toNodeID,
            nodes: nodes, links: links,
            stationIDToIndex: stationIDToIndex
        )
    }

    /// Given a link target node, resolves which station it ultimately feeds.
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

    /// Simple BFS to check whether a directed path exists between two nodes.
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
}
