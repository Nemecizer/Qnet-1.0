import Foundation
import CoreGraphics

/// Produces a random multi-class queueing network that matches a
/// user-specified target utilization. Each customer class gets its own
/// routing matrix; each (station, class) pair gets a random service
/// distribution; external arrival rates are scaled so every station sits
/// near the target ρ.
///
/// Three topology options:
///   - **feedForward** — station i routes only to j > i or sink. Produces
///     lower-triangular R, qualifies for GCDG Corollary 3 (asymptotic
///     product form).
///   - **jacksonFeedback** — base feed-forward plus each station gets a
///     random small feedback probability (0.05–0.20) to one earlier
///     station. R is still an M-matrix.
///   - **generalPMatrix** — each station routes fractionally to every
///     other station with random probabilities summing to ≤ 1 (remainder
///     to sink). R is a general completely-S / P-matrix; exercises the
///     full Dai-Harrison 1992 SRBM theory.
///
/// Layout is one horizontal row (Src₁, Src₂, … on the left, then
/// B₁ → S₁ → B₂ → S₂ → … → Sd → Sink on the right) so the canvas is
/// legible. Feedback links render as arcs.
enum RandomNetworkGenerator {

    enum Topology: Int, CaseIterable {
        case feedForward = 0
        case jacksonFeedback = 1
        case generalPMatrix = 2
        /// Reentrant via class-change — a feed-forward base for the K
        /// primary classes (one per source), plus one feedback edge per
        /// primary class that carries jobs back to an earlier buffer as
        /// a newly derived class. The class-expanded routing graph stays
        /// feed-forward (derived classes continue forward from their
        /// entry point to the sink), so every analytical test in BNET
        /// applies cleanly.
        case reentrantFeedback = 3
    }

    struct Parameters {
        var stations: Int = 4
        var classes: Int = 3
        var infiniteBuffers: Bool = true
        var targetRho: Double = 0.9
        var topology: Topology = .feedForward
        /// Optional deterministic seed. `nil` = system random.
        var seed: UInt64? = nil
    }

    /// Returned by `generate`. Caller pushes (nodes, links, infiniteBuffers)
    /// into an editor to make it the current canvas.
    struct Result {
        let nodes: [NetworkNode]
        let links: [NetworkLink]
        let infiniteBuffers: Bool
    }

    /// The one layout grid a programmatically built network lands on.
    /// Hoisted out of `generate` so `NetworkArchetypeBuilder` can lay an
    /// inserted archetype out on exactly the same rows and columns — a
    /// generated network and an inserted one must not be tellable apart by
    /// their spacing.
    enum Layout {
        /// Y of the single Src → B → S → Sink row. Sources fan out
        /// vertically around it when there is more than one.
        static let yRow = 220.0
        /// X of the source column, and of the first buffer.
        static let xSourceColumn = 80.0
        static let xRowStart = 200.0
        /// Buffer-to-buffer pitch; the station sits at half a step past
        /// its buffer.
        static let xStep = 130.0
        /// Vertical pitch between stacked sources.
        static let sourceSpacing = 64.0
        /// Gap between the last station and the sink.
        static let sinkGap = 40.0
    }

    @MainActor
    static func generate(_ params: Parameters) -> Result {
        var rng: any RandomNumberGenerator = params.seed.map {
            SeededRNG(seed: $0)
        } ?? SystemRandomNumberGeneratorBox()

        let d = max(1, params.stations)
        let K = max(1, params.classes)

        // ── Layout grid (shared with NetworkArchetypeBuilder) ────
        let ySource = Layout.yRow
        let yRow    = Layout.yRow
        let xSrcStart     = Layout.xSourceColumn
        let xRowStart     = Layout.xRowStart
        let xStep         = Layout.xStep
        let sourceSpacing = Layout.sourceSpacing

        // ── Build nodes ──────────────────────────────────────────
        var sources = [NetworkNode]()
        let srcColumnHeight = Double(K - 1) * sourceSpacing
        let srcYTop = ySource - srcColumnHeight / 2
        for k in 0..<K {
            let y = K == 1 ? ySource : srcYTop + Double(k) * sourceSpacing
            sources.append(NetworkNode(
                kind: .source,
                name: "Src\(k + 1)",
                position: CGPoint(x: xSrcStart, y: y),
                bufferSize: 1,
                distribution: .poisson,
                distributionParameters: "lambda=1.0"
            ))
        }

        var buffers  = [NetworkNode]()
        var stations = [NetworkNode]()
        for i in 0..<d {
            let xB = xRowStart + Double(i) * xStep
            let xS = xB + xStep / 2
            buffers.append(NetworkNode(
                kind: .buffer,
                name: "B\(i + 1)",
                position: CGPoint(x: xB, y: yRow),
                bufferSize: params.infiniteBuffers ? 1 : 10,
                distribution: .exponential,
                distributionParameters: "rate=1.0"
            ))

            // Per-class random service distributions for this station.
            var svc = [Int: ServiceDistributionConfig]()
            for k in 0..<K {
                svc[k] = randomServiceConfig(using: &rng)
            }
            // Default distribution (class 0) is the station's own distribution
            // field; per-class overrides live in serviceDistributions.
            let (defDist, defParams) = (svc[0]!.distribution, svc[0]!.distributionParameters)
            stations.append(NetworkNode(
                kind: .station,
                name: "S\(i + 1)",
                position: CGPoint(x: xS, y: yRow),
                bufferSize: 1,
                distribution: defDist,
                distributionParameters: defParams,
                serviceDistributions: svc
            ))
        }

        let sink = NetworkNode(
            kind: .sink,
            name: "Sink1",
            position: CGPoint(x: xRowStart + Double(d) * xStep + Layout.sinkGap,
                              y: yRow),
            bufferSize: 1,
            distribution: .exponential,
            distributionParameters: "rate=1.0"
        )

        // ── Random per-class routing P^(k) ───────────────────────
        // P[k][i][j] = probability that a class-k job leaving station i
        // goes to station j (for j<d) or to the sink (j == d). Row sums
        // to 1. The topology option determines which (i,j) pairs can
        // have positive probability.
        var P = Array(
            repeating: Array(
                repeating: [Double](repeating: 0, count: d + 1),
                count: d
            ),
            count: K
        )
        // Reentrant topology uses a feed-forward base for primary classes;
        // class-change feedback edges are added in a separate post-pass
        // that produces derived classes with their own routing.
        let routingTopology: Topology =
            (params.topology == .reentrantFeedback) ? .feedForward : params.topology
        for k in 0..<K {
            for i in 0..<d {
                P[k][i] = sampleRoutingRow(
                    i: i, d: d, topology: routingTopology, using: &rng)
            }
        }

        // ── Per-class service rates (what BNET's extractRate returns) ──
        var serviceRate = Array(repeating: [Double](repeating: 1.0, count: d), count: K)
        for k in 0..<K {
            for i in 0..<d {
                serviceRate[k][i] = meanServiceRate(from: stations[i].serviceDistributions[k])
            }
        }

        // ── Target-ρ-at-every-station design ──────────────────────
        // Each class k contributes equal work ρ-share target/K to every
        // station: ρ_i = Σ_k α^(k)_i / μ_{k,i} = target, implied by
        //     α^(k)_i = (target / K) · μ_{k,i}.
        // The external arrival needed at station i for class k solves
        //     λ^(k) = (I − P^(k)⊤) · α_target
        // (inverse of the general traffic equation, valid for any P —
        // feed-forward OR feedback, as long as (I − P⊤) is invertible).
        //
        // If the network has heavy feedback, λ^(k)_i can go negative
        // (upstream pushes more traffic to station i than the target
        // needs). We clamp negatives to 0; the post-scaling pass below
        // then shrinks the whole λ vector so ρ_max ≤ target.
        var lambdaExt = Array(repeating: [Double](repeating: 0, count: d), count: K)
        for k in 0..<K {
            var alphaTarget = [Double](repeating: 0, count: d)
            for i in 0..<d {
                alphaTarget[i] = (params.targetRho / Double(K)) * serviceRate[k][i]
            }
            for i in 0..<d {
                var lam = alphaTarget[i]
                // Sum over ALL j (not just j<i) — handles feedback cycles.
                for j in 0..<d where j != i {
                    lam -= P[k][j][i] * alphaTarget[j]
                }
                lambdaExt[k][i] = max(0.0, lam)
            }
        }

        // ── Verify & renormalise ─────────────────────────────────
        // The backward eq assumes α^(k)_i = (target/K)·μ_{k,i} exactly, but
        // we had to clamp any negative λ_ext^(k)_i to zero when upstream
        // routing alone pushes more than the target. That clamping leaves
        // the downstream station ρ above target. Solve forward with the
        // clamped λ to get the true α, then if the busiest station is hot,
        // rescale all λ by (target / ρ_max) so max ρ = target exactly.
        for _ in 0..<2 {
            var alpha = Array(repeating: [Double](repeating: 0, count: d), count: K)
            for k in 0..<K {
                var A = Array(repeating: [Double](repeating: 0, count: d), count: d)
                for i in 0..<d {
                    for j in 0..<d {
                        A[i][j] = (i == j ? 1.0 : 0.0) - P[k][j][i]
                    }
                }
                alpha[k] = solveLinearSystem(A, lambdaExt[k]) ?? lambdaExt[k]
            }
            var rho = [Double](repeating: 0, count: d)
            for i in 0..<d {
                for k in 0..<K {
                    rho[i] += alpha[k][i] / max(1e-12, serviceRate[k][i])
                }
            }
            let rhoMax = rho.max() ?? 0
            guard rhoMax > params.targetRho + 1e-6 else { break }
            let shrink = params.targetRho / rhoMax
            for k in 0..<K {
                for i in 0..<d { lambdaExt[k][i] *= shrink }
            }
        }

        // ── Reentrant post-process (Phase 2a) ─────────────────────
        // Insert class-change feedback edges and derived classes. After
        // this block, `K_total`, `P`, `serviceRate`, and the stations'
        // per-class serviceDistributions dictionaries all reflect the
        // expanded class set. `classTransitions` records which edges
        // will carry a class change when links are emitted.
        struct ClassTransition {
            let fromClass: Int
            let srcStation: Int
            let toBuffer: Int       // target buffer index (= station index it feeds)
            let toClass: Int        // derived class index
            let prob: Double
        }
        var classTransitions = [ClassTransition]()
        var K_total = K

        // ── Helper: promote a routing entry into a class transition ──
        // Used by every feedback-producing topology to keep the code
        // unified. Creates a derived class with its own feed-forward
        // routing from station `toBuffer` and service distributions at
        // every station. Returns the newly assigned class index.
        @discardableResult
        func addClassTransition(
            fromClass: Int, srcStation: Int, toBuffer: Int, prob: Double
        ) -> Int {
            let derivedClass = K_total
            K_total += 1
            classTransitions.append(ClassTransition(
                fromClass: fromClass, srcStation: srcStation,
                toBuffer: toBuffer, toClass: derivedClass, prob: prob))

            var derivedRows = Array(
                repeating: [Double](repeating: 0, count: d + 1), count: d)
            for i in toBuffer..<d {
                derivedRows[i] = sampleRoutingRow(
                    i: i, d: d, topology: .feedForward, using: &rng)
            }
            P.append(derivedRows)

            var derivedRates = [Double](repeating: 1.0, count: d)
            for i in 0..<d {
                let cfg = randomServiceConfig(using: &rng)
                stations[i].serviceDistributions[derivedClass] = cfg
                derivedRates[i] = meanServiceRate(from: cfg)
            }
            serviceRate.append(derivedRates)
            lambdaExt.append([Double](repeating: 0, count: d))
            return derivedClass
        }

        // ── Universal feedback → class-change conversion ──────────
        // For every feedback-producing topology, harvest routing
        // entries P[k][i][j] with j < i (= backward in station order)
        // and convert each to a class-change edge. This realises the
        // literature's reentrant-line formulation uniformly: every
        // physical feedback cycle becomes a transition in the class-
        // expanded routing graph, which is then purely feed-forward.
        //
        // Feed-forward topology has no such entries — the loop is a
        // no-op, preserving zero-regression behaviour.
        if d >= 2 {
            for k in 0..<K {
                // Collect all feedback targets for this primary class.
                // Limit to one transition per (primary, target) pair by
                // design — if a primary routes to the same target from
                // multiple stations, the LAST-seen station becomes the
                // feedback source and earlier ones are folded in.
                var feedbacksForK: [(i: Int, j: Int, p: Double)] = []
                for i in 0..<d {
                    for j in 0..<i where P[k][i][j] > 1e-9 {
                        feedbacksForK.append((i, j, P[k][i][j]))
                    }
                }
                for fb in feedbacksForK {
                    P[k][fb.i][fb.j] = 0
                    addClassTransition(
                        fromClass: k, srcStation: fb.i,
                        toBuffer: fb.j, prob: fb.p)
                }
            }
        }

        // ── Reentrant-specific extra feedback ─────────────────────
        // The reentrant topology uses a feed-forward sampling base
        // (which produces no feedback entries), so the universal
        // harvest above does nothing for it. Here we explicitly inject
        // one class-change feedback per primary class (with 60 %
        // probability), rooted at a random (srcStation, toBuffer) pair
        // and carrying 10–20 % of the station's sink mass.
        if params.topology == .reentrantFeedback && d >= 2 {
            for k in 0..<K {
                guard Double.random(in: 0...1, using: &rng) < 0.6 else { continue }
                let srcStation = Int.random(in: 1..<d, using: &rng)
                let toBuffer   = Int.random(in: 0..<srcStation, using: &rng)
                let pCC = Double.random(in: 0.10...0.20, using: &rng)

                // Take the feedback probability out of the station's
                // sink mass first; fall back to scaling all non-sink
                // entries if there isn't enough sink probability.
                if P[k][srcStation][d] >= pCC + 1e-9 {
                    P[k][srcStation][d] -= pCC
                } else {
                    let nonSink = P[k][srcStation].prefix(d).reduce(0, +)
                    guard nonSink > pCC + 1e-6 else { continue }
                    let scale = (nonSink - pCC) / nonSink
                    for j in 0..<d { P[k][srcStation][j] *= scale }
                }

                addClassTransition(
                    fromClass: k, srcStation: srcStation,
                    toBuffer: toBuffer, prob: pCC)
            }
        }

        // ── Reentrant stability pass ──────────────────────────────
        // Feedback adds load at every station visited by each derived
        // class. Recompute ρ over the class-expanded system and shrink
        // primary λ_ext if any station exceeds target.
        if K_total > K {
            for _ in 0..<3 {
                // Forward-propagate α̃ given current λ_ext + class
                // transitions.
                var alpha = Array(
                    repeating: [Double](repeating: 0, count: d),
                    count: K_total)
                // Primary classes: α^(k)_i = λ^(k)_i + Σ_{j} P[k][j][i] · α^(k)_j
                // solved per-class via (I − P⊤) α = λ.
                for k in 0..<K {
                    var A = Array(repeating: [Double](repeating: 0, count: d), count: d)
                    for i in 0..<d {
                        for j in 0..<d {
                            A[i][j] = (i == j ? 1.0 : 0.0) - P[k][j][i]
                        }
                    }
                    alpha[k] = solveLinearSystem(A, lambdaExt[k]) ?? lambdaExt[k]
                }
                // Derived classes: their λ is the class-change inflow
                // from the primary class's α at the feedback source.
                for tr in classTransitions {
                    let lam = tr.prob * alpha[tr.fromClass][tr.srcStation]
                    var lamVec = [Double](repeating: 0, count: d)
                    lamVec[tr.toBuffer] = lam
                    var A = Array(repeating: [Double](repeating: 0, count: d), count: d)
                    for i in 0..<d {
                        for j in 0..<d {
                            A[i][j] = (i == j ? 1.0 : 0.0) - P[tr.toClass][j][i]
                        }
                    }
                    alpha[tr.toClass] = solveLinearSystem(A, lamVec) ?? lamVec
                }
                var rho = [Double](repeating: 0, count: d)
                for i in 0..<d {
                    for k in 0..<K_total {
                        rho[i] += alpha[k][i] / max(1e-12, serviceRate[k][i])
                    }
                }
                let rhoMax = rho.max() ?? 0
                guard rhoMax > params.targetRho + 1e-6 else { break }
                let shrink = params.targetRho / rhoMax
                for k in 0..<K {
                    for i in 0..<d { lambdaExt[k][i] *= shrink }
                }
            }
        }

        // ── Write per-source total rate + buffer-split fractions ──
        // Each class has ONE Poisson source whose jobs fan out to every
        // buffer with the fractional probabilities needed to inject
        // λ^(k)_i at station i. Total source rate is the sum of
        // per-station injections; split[k][i] = λ^(k)_i / total.
        var sourceRate  = [Double](repeating: 0, count: K)
        var sourceSplit = Array(repeating: [Double](repeating: 0, count: d), count: K)
        for k in 0..<K {
            let total = lambdaExt[k].reduce(0, +)
            sourceRate[k] = total
            if total > 1e-12 {
                for i in 0..<d { sourceSplit[k][i] = lambdaExt[k][i] / total }
            } else {
                // Degenerate case (shouldn't happen with stable configs):
                // drop all at station 0 so the network is still connected.
                sourceSplit[k][0] = 1.0
            }
        }
        for k in 0..<K {
            sources[k].distributionParameters =
                String(format: "lambda=%.6f", sourceRate[k])
        }

        // ── Build links ──────────────────────────────────────────
        //   source_k → B_i  with prob split[k][i]  (fractional, class k)
        //   source_k  → buffer_i   per class k (when sourceSplit[k][i] > 0)
        //   buffer_i  → station_i  one link per class that actually reaches
        //                          this buffer — so the class-filter view
        //                          shows a continuous Src_k → … → Sink path
        //                          for every class k.
        //   station_i → {buffer_j, sink}  per class k, from the sampled row.
        var links = [NetworkLink]()

        // ── 1. Source → buffer links, per class ───────────────────
        for k in 0..<K {
            for i in 0..<d {
                let p = sourceSplit[k][i]
                if p > 1e-9 {
                    links.append(NetworkLink(
                        fromNodeID: sources[k].id,
                        toNodeID: buffers[i].id,
                        routingProbability: p,
                        customerClass: k
                    ))
                }
            }
        }

        // ── 2. Station → buffer/sink links, per class ─────────────
        // Emitted first so step 3 below can determine which classes
        // actually arrive at each buffer via upstream routing.
        //
        // Class-transition edges (Phase 2a reentrant) are ADDITIONAL
        // outgoing links from the feedback source station — they carry
        // their own probability `tr.prob` with toCustomerClass set to
        // the derived class, and their probability has already been
        // subtracted from the primary class's sink mass above.
        //
        // Derived classes k' ∈ [K, K_total) have their own feed-forward
        // P rows (populated during the reentrant post-process). They are
        // emitted the same way as primary-class rows, with no extra
        // toCustomerClass on outbound links (jobs keep their derived
        // class until they reach the sink).
        for i in 0..<d {
            for k in 0..<K_total {
                for j in 0..<d where j != i {
                    let pij = P[k][i][j]
                    if pij > 1e-9 {
                        links.append(NetworkLink(
                            fromNodeID: stations[i].id,
                            toNodeID: buffers[j].id,
                            routingProbability: pij,
                            customerClass: k
                        ))
                    }
                }
                let pSink = P[k][i][d]
                if pSink > 1e-9 {
                    links.append(NetworkLink(
                        fromNodeID: stations[i].id,
                        toNodeID: sink.id,
                        routingProbability: pSink,
                        customerClass: k
                    ))
                }
            }
            // Append class-transition edges originating at this station.
            for tr in classTransitions where tr.srcStation == i {
                links.append(NetworkLink(
                    fromNodeID: stations[i].id,
                    toNodeID: buffers[tr.toBuffer].id,
                    routingProbability: tr.prob,
                    customerClass: tr.fromClass,
                    toCustomerClass: tr.toClass
                ))
            }
        }

        // ── 3. Buffer → station links, one per reaching class ─────
        // Rule: every buffer with an incoming class-k link emits an
        // outgoing class-k link (prob 1) to its station. Class k reaches
        // buffer i if (a) the source split puts positive class-k mass
        // there, or (b) some station j routes class-k to buffer i.
        // For feed-forward topologies these guarantees ensure every
        // class's visual path runs unbroken Src_k → … → Sink.
        for i in 0..<d {
            var reachingClasses = Set<Int>()
            // Primary classes reach via source split.
            for k in 0..<K where sourceSplit[k][i] > 1e-9 {
                reachingClasses.insert(k)
            }
            // Any class (primary or derived) can reach via upstream
            // station routing.
            for j in 0..<d where j != i {
                for k in 0..<K_total where P[k][j][i] > 1e-9 {
                    reachingClasses.insert(k)
                }
            }
            // Derived classes also reach via class-change feedback edges
            // terminating at this buffer.
            for tr in classTransitions where tr.toBuffer == i {
                reachingClasses.insert(tr.toClass)
            }
            // Safety net: if no class reaches this buffer at all (shouldn't
            // happen with the target-ρ design), still emit a class-0 link
            // so the buffer isn't orphaned.
            if reachingClasses.isEmpty { reachingClasses.insert(0) }
            for k in reachingClasses.sorted() {
                links.append(NetworkLink(
                    fromNodeID: buffers[i].id,
                    toNodeID: stations[i].id,
                    routingProbability: 1.0,
                    customerClass: k
                ))
            }
        }

        let nodes = sources + buffers + stations + [sink]
        return Result(
            nodes: nodes,
            links: links,
            infiniteBuffers: params.infiniteBuffers
        )
    }

    // MARK: - Topology-aware routing row

    /// Samples one row of the routing matrix for station `i` out of `d`.
    /// Returns an array of length d+1 where entry j<d is P[i→j] (station)
    /// and entry d is P[i→sink]. Always sums to 1.
    private static func sampleRoutingRow(
        i: Int, d: Int, topology: Topology,
        using rng: inout any RandomNumberGenerator
    ) -> [Double] {
        var row = [Double](repeating: 0, count: d + 1)

        switch topology {
        case .feedForward:
            if i == d - 1 {
                row[d] = 1.0
            } else {
                let sinkProb = Double.random(in: 0.55...0.85, using: &rng)
                let rem = 1.0 - sinkProb
                let forwardCount = d - i - 1
                var w = [Double]()
                for _ in 0..<forwardCount { w.append(Double.random(in: 0.2...1.0, using: &rng)) }
                let sum = w.reduce(0, +)
                for (off, wi) in w.enumerated() { row[i + 1 + off] = rem * wi / sum }
                row[d] = sinkProb
            }

        case .jacksonFeedback:
            // Feed-forward base with a light feedback leg. Station i
            // routes `feedbackProb` ∈ [0.05, 0.20] to a randomly chosen
            // earlier station j<i (if any), `sinkProb` to sink, and the
            // remainder split across downstream stations. Station 0 has
            // no upstream to feed back to — behaves feed-forward.
            let sinkProb = Double.random(in: 0.45...0.75, using: &rng)
            var feedbackProb = 0.0
            var feedbackTarget = -1
            if i > 0 {
                feedbackProb = Double.random(in: 0.05...0.20, using: &rng)
                feedbackTarget = Int.random(in: 0..<i, using: &rng)
            }
            let rem = max(0, 1.0 - sinkProb - feedbackProb)

            if i == d - 1 {
                // Last station: no forward stations available.
                row[d] = 1.0 - feedbackProb
                if feedbackTarget >= 0 { row[feedbackTarget] = feedbackProb }
            } else {
                let forwardCount = d - i - 1
                var w = [Double]()
                for _ in 0..<forwardCount { w.append(Double.random(in: 0.2...1.0, using: &rng)) }
                let sum = w.reduce(0, +)
                for (off, wi) in w.enumerated() { row[i + 1 + off] = rem * wi / sum }
                row[d] = sinkProb
                if feedbackTarget >= 0 { row[feedbackTarget] = feedbackProb }
            }

        case .generalPMatrix:
            // Fully general: each station routes to every other station
            // and the sink with random Dirichlet-like weights. We keep
            // the sink share ≥ 0.30 so R = I − P⊤ stays safely
            // completely-S and the network remains stable at target ρ.
            let sinkProb = Double.random(in: 0.30...0.60, using: &rng)
            let rem = 1.0 - sinkProb
            var weights = [Double]()
            for _ in 0..<(d - 1) { weights.append(Double.random(in: 0.1...1.0, using: &rng)) }
            let sum = weights.reduce(0, +)
            var wi = 0
            for j in 0..<d where j != i {
                row[j] = rem * weights[wi] / sum
                wi += 1
            }
            row[d] = sinkProb

        case .reentrantFeedback:
            // Reentrant topology samples a feed-forward row at the per-
            // station level; the class-change feedback edges are added
            // by the reentrant post-pass, not by this sampler. Delegate
            // to the feed-forward case so the same row shape is produced.
            return sampleRoutingRow(i: i, d: d, topology: .feedForward, using: &rng)
        }
        return row
    }

    // MARK: - Random service distribution

    /// Produces a random service distribution whose mean is ≈ 1 and whose
    /// squared coefficient of variation c²_s ∈ [0.15, 1.5] — safely away
    /// from the "near-deterministic" (c²_s < 0.1) and "highly variable"
    /// (c²_s > 4) bands that BNET's analysis flags.
    private static func randomServiceConfig(using rng: inout any RandomNumberGenerator)
        -> ServiceDistributionConfig
    {
        let choice = Int.random(in: 0...3, using: &rng)
        switch choice {
        case 0:
            // Exponential has c²_s = 1 — always safe.
            let rate = Double.random(in: 0.8...1.4, using: &rng)
            return ServiceDistributionConfig(
                distribution: .exponential,
                distributionParameters: String(format: "rate=%.4f", rate))
        case 1:
            // Erlang-k has c²_s = 1/k. k ∈ {2,3} ⇒ c² ∈ {0.33, 0.5}; safe.
            let k = Int.random(in: 2...3, using: &rng)
            // Keep mean ≈ 1: rate = k ⇒ mean = k/rate = 1. Add modest jitter.
            let rate = Double(k) * Double.random(in: 0.9...1.2, using: &rng)
            return ServiceDistributionConfig(
                distribution: .erlang,
                distributionParameters: "k=\(k),rate=\(String(format: "%.4f", rate))")
        case 2:
            // Gamma has c²_s = 1/shape. Keep shape ∈ [1.0, 2.5] so c² ∈
            // [0.4, 1.0]. Mean = shape·scale ≈ 1 ⇒ scale = 1/shape.
            let shape = Double.random(in: 1.0...2.5, using: &rng)
            let scale = Double.random(in: 0.85...1.15, using: &rng) / shape
            return ServiceDistributionConfig(
                distribution: .gamma,
                distributionParameters: String(format: "shape=%.3f,scale=%.3f", shape, scale))
        default:
            // Uniform[a, b] has c²_s = (b-a)²/(3(a+b)²). To keep c² ≳ 0.15
            // we need (b-a)/(a+b) ≳ 0.67, i.e. b ≳ 5a. Pick a ∈ [0.1, 0.3]
            // and b = a + wide so c² stays in [0.15, 0.3].
            let low  = Double.random(in: 0.1...0.3, using: &rng)
            let high = low + Double.random(in: 1.4...2.0, using: &rng)
            return ServiceDistributionConfig(
                distribution: .uniform,
                distributionParameters: String(format: "min=%.3f,max=%.3f", low, high))
        }
    }

    /// Approximate mean service rate for a distribution.
    /// Uses mean = E[S] then returns 1/E[S] as the effective per-server rate.
    private static func meanServiceRate(from cfg: ServiceDistributionConfig?) -> Double {
        guard let cfg else { return 1.0 }
        let p = parseParams(cfg.distributionParameters)
        switch cfg.distribution {
        case .exponential:
            let rate = p["rate"] ?? 1.0
            return max(1e-6, rate)
        case .erlang:
            let k = p["k"] ?? 2.0
            let rate = p["rate"] ?? 1.0
            // Erlang mean = k / rate
            return max(1e-6, rate / k)
        case .gamma:
            let shape = p["shape"] ?? 2.0
            let scale = p["scale"] ?? 0.5
            return max(1e-6, 1.0 / (shape * scale))
        case .uniform:
            let lo = p["min"] ?? 0.5
            let hi = p["max"] ?? 1.5
            return max(1e-6, 2.0 / (lo + hi))
        case .constant:
            let v = p["value"] ?? 1.0
            return max(1e-6, 1.0 / v)
        case .weibull, .lognormal, .pareto, .poisson:
            return 1.0   // not used as station service; safe fallback
        }
    }

    private static func parseParams(_ s: String) -> [String: Double] {
        var out = [String: Double]()
        for token in s.split(separator: ",") {
            let pair = token.split(separator: "=")
            if pair.count == 2, let v = Double(pair[1].trimmingCharacters(in: .whitespaces)) {
                out[String(pair[0]).trimmingCharacters(in: .whitespaces)] = v
            }
        }
        return out
    }

    // MARK: - Linear solve (Gauss w/ partial pivot)

    private static func solveLinearSystem(
        _ A: [[Double]], _ b: [Double]
    ) -> [Double]? {
        let n = b.count
        guard n > 0 else { return [] }
        var M = A
        var rhs = b
        for i in 0..<n {
            var piv = i
            var best = abs(M[i][i])
            for r in (i + 1)..<n where abs(M[r][i]) > best {
                best = abs(M[r][i]); piv = r
            }
            if best < 1e-14 { return nil }
            if piv != i {
                M.swapAt(i, piv); rhs.swapAt(i, piv)
            }
            for r in (i + 1)..<n {
                let f = M[r][i] / M[i][i]
                if f == 0 { continue }
                for c in i..<n { M[r][c] -= f * M[i][c] }
                rhs[r] -= f * rhs[i]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = rhs[i]
            for c in (i + 1)..<n { s -= M[i][c] * x[c] }
            x[i] = s / M[i][i]
        }
        return x
    }
}

// MARK: - RNG helpers

/// Deterministic SplitMix64 for reproducible generation with a user seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed != 0 ? seed : 0xdeadbeef }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

private struct SystemRandomNumberGeneratorBox: RandomNumberGenerator {
    var inner = SystemRandomNumberGenerator()
    mutating func next() -> UInt64 { inner.next() }
}
