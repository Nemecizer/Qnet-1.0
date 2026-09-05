import Foundation
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// The archetype library: the five networks a queueing course, a textbook
// chapter or a first experiment actually starts from, built to order and
// inserted into the canvas in one undoable step.
//
// Why this exists: before it, the only ways to get a runnable network were to
// place every node by hand (27 clicks with hotkeys for a three-station tandem),
// roll dice with Network ▸ Generate Random Network…, or hunt for a bundled
// example. None of those is "show me a tandem line at ρ = 0.9".
//
// Three rules every archetype obeys, because the rest of the app depends on
// them:
//
//   1. **Buffer before station.** `SRBMExporter.computeData` requires exactly
//      one feeding buffer per station (`.stationMissingBuffer` /
//      `.stationMultipleBuffers`), so every station here is fed by its own B_i
//      and by nothing else. Feedback arcs target the *buffer*, never the
//      station.
//   2. **ρ is a parameter, not an accident.** Service rates are back-solved
//      from the traffic equations as μ_i = α_i / (ρ · c_i), so every station
//      of an inserted archetype sits at exactly the ρ the user asked for. That
//      is the same design `RandomNetworkGenerator` uses and the same shape
//      `validation/example_contracts.py` asserts of the bundled examples
//      (λ = 1, μ = 1.1111111, ρ = 0.9).
//   3. **One source, one class, exponential everything.** With infinite
//      buffers that lands the network in the *exact* Jackson branch of
//      `AnalyticalTractability`, so the flag bar's Analytical pill lights and
//      the inserted network has a closed-form answer to compare a solver to.
//      That survives being inserted next to a network that already has a
//      source: the block brings its own stations, so the two classes share no
//      server, and `AnalyticalTractability.singleClassPerStation` recognises
//      the document as two Jackson networks side by side rather than one
//      multi-class network. Drawing a link *between* the two blocks is what
//      ends that, and it should — that document really is multi-class.
//
// Layout comes from `RandomNetworkGenerator.Layout`, so an inserted archetype
// and a generated network are laid out on the same grid.
// ─────────────────────────────────────────────────────────────────────────────

/// The starting networks the gallery offers.
enum NetworkArchetype: String, CaseIterable, Identifiable {
    /// One station with c servers — M/M/c.
    case mmcStation
    /// d stations in series, no feedback.
    case tandemLine
    /// One station splitting evenly into two parallel stations.
    case forkStyleSplit
    /// A tandem line where each station reworks a fraction of its own output.
    case openJacksonFeedback
    /// Two stations with a routing cycle between them.
    case reentrantTwoStation

    var id: String { rawValue }
}

/// The knobs an archetype can expose. A blueprint lists the ones it uses, and
/// the gallery shows exactly those rows — a knob that would not change the
/// network it builds is not offered.
enum ArchetypeKnob: String, CaseIterable, Identifiable {
    case stations
    case servers
    case targetRho
    case feedbackProbability
    case buffers
    case arrivalRate

    var id: String { rawValue }
}

/// The values behind those knobs. Defaults are the useful regime, not the
/// mathematically neutral one: λ = 1 with ρ = 0.9 is what every bundled
/// example uses and what `RandomNetworkGenerator` defaults to.
struct ArchetypeParameters: Equatable {
    var stations = 3
    var servers = 1
    var targetRho = 0.9
    var feedbackProbability = 0.3
    var infiniteBuffers = true
    var bufferCapacity = 10
    var arrivalRate = 1.0

    // Ranges the gallery validates against. ρ stops short of 1 because ρ = 1
    // is the boundary of instability, and the feedback probability stops
    // short of 1 because α = λ / (1 − p) diverges there.
    static let stationRange = 1...12
    static let serverRange = 1...16
    static let rhoRange = 0.05...0.99
    static let feedbackRange = 0.0...0.9
    static let capacityRange = 1...500
    static let arrivalRateRange = 0.001...1000.0

    /// Clamped copy — the builder never trusts a caller to have validated.
    func clamped() -> ArchetypeParameters {
        var p = self
        p.stations = min(max(stations, Self.stationRange.lowerBound), Self.stationRange.upperBound)
        p.servers = min(max(servers, Self.serverRange.lowerBound), Self.serverRange.upperBound)
        p.targetRho = min(max(targetRho, Self.rhoRange.lowerBound), Self.rhoRange.upperBound)
        p.feedbackProbability = min(max(feedbackProbability, Self.feedbackRange.lowerBound),
                                    Self.feedbackRange.upperBound)
        p.bufferCapacity = min(max(bufferCapacity, Self.capacityRange.lowerBound),
                               Self.capacityRange.upperBound)
        p.arrivalRate = min(max(arrivalRate, Self.arrivalRateRange.lowerBound),
                            Self.arrivalRateRange.upperBound)
        return p
    }
}

/// A tiny picture of an archetype for the gallery tile: every node and link
/// of the built network, with the positions normalised into the unit square.
///
/// It is derived from `NetworkArchetypeBuilder.build` rather than drawn by
/// hand, so the tile cannot drift from the network the tile inserts — a
/// hand-drawn stencil that no longer matches its template is exactly the
/// failure mode a picture is supposed to prevent.
struct ArchetypeSchematic {
    /// One node, as its kind and its position in the unit square (x → right,
    /// y → down, matching canvas coordinates).
    struct Marker {
        let kind: NodeKind
        let point: CGPoint
    }

    /// One link. `isLoop` is a station's own feedback arc (P[i][i] > 0);
    /// `isBackward` is a routing arc that returns upstream — the two shapes
    /// that tell "Fork and Merge" and "Re-entrant Pair" apart at a glance.
    struct Edge {
        let from: CGPoint
        let to: CGPoint
        let isLoop: Bool
        var isBackward: Bool { !isLoop && to.x <= from.x }
    }

    let markers: [Marker]
    let edges: [Edge]
}

/// One entry in the gallery: what it is called, what it draws, and which
/// knobs it answers to.
struct ArchetypeBlueprint: Identifiable {
    let id: NetworkArchetype
    /// Section the gallery files it under.
    let group: String
    let title: String
    /// The route in one line — "Src1 → B1 → S1 → … → Sink1".
    let subtitle: String
    /// A `DS.Symbol` value. Never a literal SF Symbol name (design_lint).
    let systemImage: String
    let knobs: [ArchetypeKnob]

    func uses(_ knob: ArchetypeKnob) -> Bool { knobs.contains(knob) }
}

@MainActor
enum NetworkArchetypeBuilder {

    // MARK: - Catalogue

    static let blueprints: [ArchetypeBlueprint] = [
        ArchetypeBlueprint(
            id: .mmcStation,
            group: "Single Station",
            title: "M/M/c Station",
            subtitle: "Src1 → B1 → S1 → Sink1, with c parallel servers",
            systemImage: DS.Symbol.multilevel,
            knobs: [.servers, .targetRho, .arrivalRate, .buffers]
        ),
        ArchetypeBlueprint(
            id: .tandemLine,
            group: "Lines",
            title: "Tandem Line",
            subtitle: "Src1 → B1 → S1 → … → Sd → Sink1, every station at the same ρ",
            systemImage: DS.Symbol.link,
            knobs: [.stations, .servers, .targetRho, .arrivalRate, .buffers]
        ),
        ArchetypeBlueprint(
            id: .forkStyleSplit,
            group: "Lines",
            title: "Fork and Merge",
            subtitle: "S1 splits its output evenly into S2 and S3, both to Sink1",
            systemImage: DS.Symbol.paneSplit,
            knobs: [.servers, .targetRho, .arrivalRate, .buffers]
        ),
        ArchetypeBlueprint(
            id: .openJacksonFeedback,
            group: "Feedback",
            title: "Line with Rework",
            subtitle: "Every station returns a fraction p of its output to its own buffer",
            systemImage: DS.Symbol.network,
            knobs: [.stations, .servers, .targetRho, .feedbackProbability, .arrivalRate, .buffers]
        ),
        ArchetypeBlueprint(
            id: .reentrantTwoStation,
            group: "Feedback",
            title: "Re-entrant Pair",
            subtitle: "S1 → S2, and S2 sends a fraction p back to B1 — a two-station cycle",
            systemImage: DS.Symbol.reentrant,
            knobs: [.servers, .targetRho, .feedbackProbability, .arrivalRate, .buffers]
        ),
    ]

    /// Gallery section order, derived from the catalogue so adding a
    /// blueprint cannot leave it out of the grid.
    static var groups: [String] {
        var seen = Set<String>()
        return blueprints.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    static func blueprint(for archetype: NetworkArchetype) -> ArchetypeBlueprint {
        // Every case is in the catalogue; the fallback keeps the accessor
        // non-optional for a view body.
        blueprints.first { $0.id == archetype } ?? blueprints[0]
    }

    /// Where the block's top-left corner sits on an empty canvas: the same
    /// source column and row a generated network uses.
    /// `nonisolated` because it is a default argument of `build(_:_:origin:)`,
    /// and a default argument is evaluated in the CALLER's context — a
    /// main-actor-isolated constant there is a hard error under Swift 6.
    nonisolated static let canvasOrigin = CGPoint(x: RandomNetworkGenerator.Layout.xSourceColumn,
                                                  y: RandomNetworkGenerator.Layout.yRow)

    /// Vertical offset of a parallel branch from the main row. Half a
    /// station column, so a fork reads as a fork at 100 % zoom without
    /// pushing the sink off the visible canvas.
    private static let branchOffset = 90.0

    // MARK: - Schematic

    /// The gallery tile's picture of `archetype`.
    ///
    /// Built at the CATALOGUE defaults, not at the user's current knobs: the
    /// tile is the archetype's identity and has to stay still while the knobs
    /// are being set — the footer's summary line is what carries the live
    /// numbers. Cached because a `View` body asks for it on every keystroke
    /// in the knob column.
    static func schematic(for archetype: NetworkArchetype) -> ArchetypeSchematic {
        if let cached = schematicCache[archetype] { return cached }
        let made = makeSchematic(archetype)
        schematicCache[archetype] = made
        return made
    }

    private static var schematicCache: [NetworkArchetype: ArchetypeSchematic] = [:]

    private static func makeSchematic(_ archetype: NetworkArchetype) -> ArchetypeSchematic {
        let net = build(archetype, ArchetypeParameters())
        let xs = net.nodes.map(\.position.x)
        let ys = net.nodes.map(\.position.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return ArchetypeSchematic(markers: [], edges: [])
        }
        // A one-row archetype has zero height; centre it on the mid-line
        // rather than dividing by zero.
        let spanX = maxX - minX
        let spanY = maxY - minY
        func unit(_ p: CGPoint) -> CGPoint {
            CGPoint(x: spanX > 0 ? (p.x - minX) / spanX : 0.5,
                    y: spanY > 0 ? (p.y - minY) / spanY : 0.5)
        }

        var byID: [UUID: CGPoint] = [:]
        var markers: [ArchetypeSchematic.Marker] = []
        for node in net.nodes {
            let point = unit(node.position)
            byID[node.id] = point
            markers.append(.init(kind: node.kind, point: point))
        }
        let edges: [ArchetypeSchematic.Edge] = net.links.compactMap { link in
            guard let from = byID[link.fromNodeID], let to = byID[link.toNodeID] else { return nil }
            return .init(from: from, to: to, isLoop: link.fromNodeID == link.toNodeID)
        }
        return ArchetypeSchematic(markers: markers, edges: edges)
    }

    // MARK: - Build

    /// Builds the archetype as a detached (nodes, links, buffer-regime)
    /// triple. Nothing here touches an editor: the caller hands the result to
    /// `NetworkEditorModel.insertSubnetwork(...)`, which owns naming, ids and
    /// undo.
    ///
    /// `RandomNetworkGenerator.Result` is reused verbatim so no new type
    /// crosses into the editor.
    static func build(
        _ archetype: NetworkArchetype,
        _ params: ArchetypeParameters,
        origin: CGPoint = canvasOrigin
    ) -> RandomNetworkGenerator.Result {
        let p = params.clamped()
        switch archetype {
        case .mmcStation:          return buildChain(p, stations: 1, origin: origin)
        case .tandemLine:          return buildChain(p, stations: p.stations, origin: origin)
        case .openJacksonFeedback: return buildRework(p, origin: origin)
        case .reentrantTwoStation: return buildReentrantPair(p, origin: origin)
        case .forkStyleSplit:      return buildFork(p, origin: origin)
        }
    }

    /// One-line summary of what `build` would produce, for the gallery's
    /// footer and for the status line the insert writes. Reads the built
    /// network rather than re-deriving it, so it cannot drift from it.
    static func summary(
        _ archetype: NetworkArchetype,
        _ params: ArchetypeParameters
    ) -> String {
        let p = params.clamped()
        let net = build(archetype, p)
        let stations = net.nodes.filter { $0.kind == .station }.count
        let rho = DS.Number.display(p.targetRho, decimals: 3)
        return "\(stations) station\(stations == 1 ? "" : "s"), "
            + "\(net.nodes.count) nodes, \(net.links.count) links, "
            + "λ = \(DS.Number.display(p.arrivalRate, decimals: 3)), "
            + "ρ = \(rho) at every station"
    }

    // MARK: - Individual archetypes

    /// Src1 → B1 → S1 → B2 → S2 → … → Sink1, no feedback.
    ///
    /// Every station carries the whole external stream, so α_i = λ and
    /// μ_i = λ / (ρ · c) at every station.
    private static func buildChain(
        _ p: ArchetypeParameters, stations d: Int, origin: CGPoint
    ) -> RandomNetworkGenerator.Result {
        var assembly = Assembly(params: p, origin: origin)
        let source = assembly.addSource(rate: p.arrivalRate, row: 0)
        let mu = serviceRate(throughput: p.arrivalRate, params: p)

        var previous: NetworkNode?
        for i in 0..<d {
            let pair = assembly.addStage(index: i + 1, column: i, row: 0, serviceRate: mu)
            if let previous {
                assembly.link(from: previous, to: pair.buffer)
            } else {
                assembly.link(from: source, to: pair.buffer)
            }
            previous = pair.station
        }
        let sink = assembly.addSink(column: d, row: 0)
        if let previous { assembly.link(from: previous, to: sink) }
        return assembly.result()
    }

    /// A tandem line where each station returns a fraction p of its output to
    /// its OWN buffer — the rework / retry loop, and the diagonal
    /// P[i][i] = p that the solvers, the warnings and Network ▸ Analyze
    /// Network already speak about.
    ///
    /// Traffic: α_i = λ + p·α_i at the head and α_i = (1−p)·α_{i−1} + p·α_i
    /// after it, so every station carries α = λ / (1 − p) and one service
    /// rate holds for the whole line.
    private static func buildRework(
        _ p: ArchetypeParameters, origin: CGPoint
    ) -> RandomNetworkGenerator.Result {
        let d = p.stations
        let forward = 1.0 - p.feedbackProbability
        let alpha = p.arrivalRate / max(forward, 1e-9)
        let mu = serviceRate(throughput: alpha, params: p)

        var assembly = Assembly(params: p, origin: origin)
        let source = assembly.addSource(rate: p.arrivalRate, row: 0)

        var stages: [Assembly.Stage] = []
        for i in 0..<d {
            stages.append(assembly.addStage(index: i + 1, column: i, row: 0, serviceRate: mu))
        }
        let sink = assembly.addSink(column: d, row: 0)

        assembly.link(from: source, to: stages[0].buffer)
        for (i, stage) in stages.enumerated() {
            // The rework arc first: it is the reason this archetype exists,
            // and link order is the order the inspector lists them in.
            if p.feedbackProbability > 0 {
                assembly.link(from: stage.station, to: stage.buffer,
                              probability: p.feedbackProbability)
            }
            if i + 1 < stages.count {
                assembly.link(from: stage.station, to: stages[i + 1].buffer, probability: forward)
            } else {
                assembly.link(from: stage.station, to: sink, probability: forward)
            }
        }
        return assembly.result()
    }

    /// Two stations with a cycle between them: S1 → S2, and S2 returns a
    /// fraction p of its output to B1. Both stations carry
    /// α = λ / (1 − p), so one service rate again holds for both.
    private static func buildReentrantPair(
        _ p: ArchetypeParameters, origin: CGPoint
    ) -> RandomNetworkGenerator.Result {
        let forward = 1.0 - p.feedbackProbability
        let alpha = p.arrivalRate / max(forward, 1e-9)
        let mu = serviceRate(throughput: alpha, params: p)

        var assembly = Assembly(params: p, origin: origin)
        let source = assembly.addSource(rate: p.arrivalRate, row: 0)
        let first = assembly.addStage(index: 1, column: 0, row: 0, serviceRate: mu)
        let second = assembly.addStage(index: 2, column: 1, row: 0, serviceRate: mu)
        let sink = assembly.addSink(column: 2, row: 0)

        assembly.link(from: source, to: first.buffer)
        assembly.link(from: first.station, to: second.buffer)
        if p.feedbackProbability > 0 {
            assembly.link(from: second.station, to: first.buffer,
                          probability: p.feedbackProbability)
        }
        assembly.link(from: second.station, to: sink, probability: forward)
        return assembly.result()
    }

    /// S1 splits its output evenly between two parallel stations, both of
    /// which drain to the sink. α_1 = λ and α_2 = α_3 = λ/2, so the two
    /// branch stations are served at half the entry station's rate and all
    /// three still sit at ρ.
    private static func buildFork(
        _ p: ArchetypeParameters, origin: CGPoint
    ) -> RandomNetworkGenerator.Result {
        let half = 0.5
        var assembly = Assembly(params: p, origin: origin)
        let source = assembly.addSource(rate: p.arrivalRate, row: 0)
        let entry = assembly.addStage(
            index: 1, column: 0, row: 0,
            serviceRate: serviceRate(throughput: p.arrivalRate, params: p))
        let branchRate = serviceRate(throughput: p.arrivalRate * half, params: p)
        let upper = assembly.addStage(index: 2, column: 1, row: -1, serviceRate: branchRate)
        let lower = assembly.addStage(index: 3, column: 1, row: 1, serviceRate: branchRate)
        let sink = assembly.addSink(column: 2, row: 0)

        assembly.link(from: source, to: entry.buffer)
        assembly.link(from: entry.station, to: upper.buffer, probability: half)
        assembly.link(from: entry.station, to: lower.buffer, probability: half)
        assembly.link(from: upper.station, to: sink)
        assembly.link(from: lower.station, to: sink)
        return assembly.result()
    }

    // MARK: - Rates

    /// The one rate rule: μ = α / (ρ · c). Back-solving the service rate from
    /// the throughput the traffic equations give is what makes ρ a knob
    /// rather than an outcome.
    private static func serviceRate(throughput alpha: Double, params p: ArchetypeParameters) -> Double {
        alpha / (p.targetRho * Double(p.servers))
    }

    /// Rate as a parameter string. Up to eight significant digits, with a
    /// decimal point always present, so λ = 1 reads "1.0" and μ = λ/0.9
    /// reads "1.1111111" — exactly the spelling the bundled examples use.
    private static func rateLiteral(_ value: Double) -> String {
        let text = String(format: "%.8g", value)
        return (text.contains(".") || text.contains("e")) ? text : text + ".0"
    }

    // MARK: - Assembly

    /// Accumulates nodes and links on the shared layout grid. The source has
    /// its own column; column i is the i-th buffer/station pair, and the sink
    /// takes the column past the last one. `row` is a signed offset in branch
    /// heights from the main row, so a fork's two branches sit at ∓1.
    @MainActor
    private struct Assembly {
        let params: ArchetypeParameters
        let origin: CGPoint
        var nodes: [NetworkNode] = []
        var links: [NetworkLink] = []

        struct Stage {
            let buffer: NetworkNode
            let station: NetworkNode
        }

        private var dx: Double { Double(origin.x) - RandomNetworkGenerator.Layout.xSourceColumn }
        private var dy: Double { Double(origin.y) - RandomNetworkGenerator.Layout.yRow }

        private func point(x: Double, row: Int) -> CGPoint {
            CGPoint(x: x + dx,
                    y: RandomNetworkGenerator.Layout.yRow
                       + Double(row) * NetworkArchetypeBuilder.branchOffset + dy)
        }

        private func bufferX(column: Int) -> Double {
            RandomNetworkGenerator.Layout.xRowStart
                + Double(column) * RandomNetworkGenerator.Layout.xStep
        }

        mutating func addSource(rate: Double, row: Int) -> NetworkNode {
            // Poisson, not exponential: every bundled example spells an
            // arrival process this way and MethodAdvisor's Poisson-sources
            // test looks for it.
            let node = NetworkNode(
                kind: .source,
                name: "Src1",
                position: point(x: RandomNetworkGenerator.Layout.xSourceColumn, row: row),
                bufferSize: 1,
                distribution: .poisson,
                distributionParameters: "lambda=" + NetworkArchetypeBuilder.rateLiteral(rate)
            )
            nodes.append(node)
            return node
        }

        mutating func addStage(index: Int, column: Int, row: Int, serviceRate mu: Double) -> Stage {
            let xB = bufferX(column: column)
            let buffer = NetworkNode(
                kind: .buffer,
                name: "B\(index)",
                position: point(x: xB, row: row),
                // A buffer's own bufferSize is the queue capacity and is
                // read only in the finite-buffer regime; 1 is what the
                // generator writes for an infinite-buffer network.
                bufferSize: params.infiniteBuffers ? 1 : params.bufferCapacity,
                distribution: .exponential,
                distributionParameters: "rate=1.0"
            )
            let station = NetworkNode(
                kind: .station,
                name: "S\(index)",
                position: point(x: xB + RandomNetworkGenerator.Layout.xStep / 2, row: row),
                bufferSize: 1,
                numberOfServers: params.servers,
                distribution: .exponential,
                distributionParameters: "rate=" + NetworkArchetypeBuilder.rateLiteral(mu)
            )
            nodes.append(buffer)
            nodes.append(station)
            // The B_i → S_i link is emitted HERE, not by the callers: it is
            // the pairing `SRBMExporter.computeData` demands of every station
            // (exactly one feeding buffer), so no archetype gets to forget it.
            links.append(NetworkLink(
                fromNodeID: buffer.id,
                toNodeID: station.id,
                routingProbability: 1.0,
                customerClass: 0
            ))
            return Stage(buffer: buffer, station: station)
        }

        mutating func addSink(column: Int, row: Int) -> NetworkNode {
            let node = NetworkNode(
                kind: .sink,
                name: "Sink1",
                position: point(x: bufferX(column: column) + RandomNetworkGenerator.Layout.sinkGap,
                                row: row),
                bufferSize: 1,
                distribution: .exponential,
                distributionParameters: "rate=1.0"
            )
            nodes.append(node)
            return node
        }

        mutating func link(from: NetworkNode, to: NetworkNode, probability: Double = 1.0) {
            links.append(NetworkLink(
                fromNodeID: from.id,
                toNodeID: to.id,
                routingProbability: probability,
                customerClass: 0
            ))
        }

        func result() -> RandomNetworkGenerator.Result {
            RandomNetworkGenerator.Result(
                nodes: nodes,
                links: links,
                infiniteBuffers: params.infiniteBuffers
            )
        }
    }
}
