import Foundation

/// Detects whether the current network has a known closed-form (or asymptotic
/// product-form) stationary distribution for the station queue lengths.
///
/// Detection precedence (strongest first):
///   1. Open Jackson network                 → exact, M/M/s stationary.
///      (also fires for a document whose K > 1 classes share no station:
///      that is K disjoint Jackson networks drawn side by side, not a
///      multi-class network — see `singleClassPerStation`.)
///   2. Harrison–Williams (1987) skew-symmetry → exact SRBM product form.
///   3. GCDG 2025 Corollary 3 (lower-triangular R) → asymptotic product form.
///   4. GCDG 2025 Corollary 2 (d = 2, P-matrix R) → asymptotic product form.
///   5. GCDG 2025 Corollary 1 (R is an M-matrix) → asymptotic product form.
///
/// Reference:
///   Guang, Chen, Dai, Glynn (2025). "Asymptotic Product-form Steady-state
///   Distribution for SRBM in Multi-scaling Regime." arXiv:2503.19710.
enum AnalyticalTractability {

    // MARK: - Result
    enum Kind: String {
        case exactJackson
        case exactSkewSymmetric
        case asymptoticLowerTriangular
        case asymptotic2D
        case asymptoticMMatrix
        case none
    }

    struct Result {
        let kind: Kind
        let title: String            // short banner title
        let detail: String           // banner subtitle (1–2 lines)
        let means: [Double]          // closed-form E[X_i] when available; empty otherwise
        let meansLabel: String       // header for the analytical column
        let explanation: String      // multi-line text for Analyze Network + help

        var isTractable: Bool { kind != .none }
        var isExact: Bool { kind == .exactJackson || kind == .exactSkewSymmetric }
    }

    // MARK: - Top-level entry point

    /// Assesses tractability from an already-computed `SRBMExporter.SRBMData`
    /// plus the raw nodes (needed for Jackson distribution check). The network
    /// is assumed to already pass `SRBMExporter.computeData`.
    ///
    /// `allowGCDG` gates the three GCDG 2025 asymptotic branches (M-matrix,
    /// d=2 P-matrix, lower-triangular). When false, only the *exact* branches
    /// (Jackson, skew-symmetric) are attempted; the detector returns `.none`
    /// if neither matches. This lets the user opt out of the asymptotic
    /// approximation until it is better validated.
    @MainActor
    static func assess(
        data: SRBMExporter.SRBMData,
        nodes: [NetworkNode],
        infiniteBuffers: Bool,
        allowGCDG: Bool = true
    ) -> Result {

        let d = data.d

        // Stability must hold for any of the tractability results to apply.
        var rho = [Double](repeating: 0, count: d)
        for i in 0..<d {
            rho[i] = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : 1.0
            if rho[i] >= 1.0 || rho[i] <= 0 {
                return unstable()
            }
        }

        // ── 1. Exact Jackson ──────────────────────────────────────
        if let jackson = jacksonResult(
            data: data, nodes: nodes, rho: rho, infiniteBuffers: infiniteBuffers
        ) {
            return jackson
        }

        // Build the square reflection matrix from the lower-face columns.
        let R = lowerFaceR(from: data.R, d: d)
        let Gamma = data.gamma
        let mu = data.drift

        // ── 2. Harrison–Williams skew-symmetry ────────────────────
        if let skew = skewSymmetricResult(R: R, Gamma: Gamma, mu: mu, d: d) {
            return skew
        }

        // The remaining three cases are GCDG 2025 *asymptotic* product-form
        // approximations; skip them when the user has disabled the feature.
        guard allowGCDG else {
            return Result(
                kind: .none,
                title: "",
                detail: "",
                means: [],
                meansLabel: "",
                explanation: "No exact closed-form distribution matches this network. GCDG 2025 asymptotic approximation is disabled in Settings ▸ GCDG."
            )
        }

        // ── 3. GCDG Corollary 3: lower-triangular R (with topo-permutation) ───
        // Cor. 3 is stated for lower-triangular R, which corresponds to a
        // feed-forward routing graph numbered in topological order from
        // sources to sinks. The corollary itself only depends on the
        // *existence* of that ordering — if the user's station numbering is
        // out of topo order but the routing graph is still acyclic, we can
        // permute R/Γ/μ into the canonical order, apply Cor. 3, and
        // unpermute the means. So the branch fires for any feed-forward
        // network, not just those happening to be numbered correctly.
        if let perm = permutationForLowerTriangular(R, d: d) {
            let isIdentity = perm.enumerated().allSatisfy { $0.offset == $0.element }
            let R_p = permuteMatrix(R, perm: perm)
            let G_p = permuteMatrix(Gamma, perm: perm)
            let mu_p = perm.map { mu[$0] }
            let m_p = gcdgMeans(R: R_p, Gamma: G_p, mu: mu_p, d: d)
            if !m_p.isEmpty {
                // Unpermute: m_p[a] is the mean of station perm[a] in the
                // original numbering.
                var means = [Double](repeating: 0, count: d)
                for a in 0..<d { means[perm[a]] = m_p[a] }
                let detail = isIdentity
                    ? "Asymptotic product form — GCDG 2025 Cor. 3 (lower-triangular R, feed-forward)"
                    : "Asymptotic product form — GCDG 2025 Cor. 3 (feed-forward, station relabel applied)"
                let reason = isIdentity
                    ? "the reflection matrix R = I − P⊤ is lower-triangular, which arises whenever the network is feed-forward with station numbering respected (e.g. tandem, acyclic layered)."
                    : "the routing graph is acyclic, so the stations can be relabeled in topological order to make R = I − P⊤ lower-triangular. The corollary applies in the relabeled coordinates and the means are unpermuted back to the user's numbering."
                return Result(
                    kind: .asymptoticLowerTriangular,
                    title: "This network is analytically tractable",
                    detail: detail,
                    means: means,
                    meansLabel: "Asymptotic E[X]",
                    explanation: gcdgExplanation(corollary: 3, reason: reason)
                )
            }
        }

        // ── 4. GCDG Corollary 2: 2D P-matrix ──────────────────────
        if d == 2 && isPMatrix(R, d: d) {
            let means = gcdgMeans(R: R, Gamma: Gamma, mu: mu, d: d)
            return Result(
                kind: .asymptotic2D,
                title: "This network is analytically tractable",
                detail: "Asymptotic product form — GCDG 2025 Cor. 2 (d = 2, P-matrix R)",
                means: means,
                meansLabel: "Asymptotic E[X]",
                explanation: gcdgExplanation(
                    corollary: 2,
                    reason: "the network has two stations and the reflection matrix R is a P-matrix."
                )
            )
        }

        // ── 5. GCDG Corollary 1: M-matrix ─────────────────────────
        if isMMatrix(R, d: d) {
            let means = gcdgMeans(R: R, Gamma: Gamma, mu: mu, d: d)
            return Result(
                kind: .asymptoticMMatrix,
                title: "This network is analytically tractable",
                detail: "Asymptotic product form — GCDG 2025 Cor. 1 (R is an M-matrix)",
                means: means,
                meansLabel: "Asymptotic E[X]",
                explanation: gcdgExplanation(
                    corollary: 1,
                    reason: "the reflection matrix R = I − P⊤ is an M-matrix (non-positive off-diagonals, non-negative inverse). Every open GJN-style SRBM satisfies this."
                )
            )
        }

        return Result(
            kind: .none,
            title: "",
            detail: "",
            means: [],
            meansLabel: "",
            explanation: "No known closed-form or asymptotic product-form stationary distribution matches this network's data (Γ, R, μ)."
        )
    }

    // MARK: - Jackson

    /// Which customer class visits each station, when no station is visited by
    /// more than one of them — `nil` as soon as one station carries two.
    ///
    /// This is the test that decides whether a `K > 1` document is *really*
    /// multi-class, and it exists because `data.K` counts sources, not
    /// couplings. Two archetypes inserted side by side (File ▸ New from
    /// Archetype… into a canvas that already has a source), or any two
    /// sub-networks that share no station, give K = 2 while every server still
    /// sees exactly one stream.
    ///
    /// When that holds, nothing is being approximated away. The throughput
    /// weights `SRBMExporter.computeData` aggregates with are a 0/1 selection
    /// — μ_effᵢ is a harmonic mixture over classes weighted by
    /// αₖᵢ/αᵢ (`SRBMExporter.swift:269`) and the routing matrix is
    /// mixed the same way (`:303`) — so μ_effᵢ is that one class's rate
    /// exactly and P is that one class's routing matrix exactly. The document
    /// is then the same stochastic object as ONE single-class Jackson network
    /// over the union of the stations, and the class label is bookkeeping.
    ///
    /// Class switching mid-network is covered rather than excluded: a job that
    /// leaves station i as class 1 and is served at station j as class 2 is
    /// still just a routing transition i → j of that combined chain, because
    /// the service rate it meets at j depends only on j.
    ///
    /// Deliberately conservative at the other end: a station genuinely shared
    /// by two classes is rejected here even when both classes are served at
    /// the same exponential rate, which BCMP (1975) station type 1 would still
    /// give a product form. That generalisation is a wider claim of exactness
    /// than this function makes and wants its own verification; disjointness
    /// needs none, because it reduces the document to a network the exact
    /// branch below already handles.
    private static func singleClassPerStation(data: SRBMExporter.SRBMData) -> [Int]? {
        let d = data.d
        guard data.K >= 1, data.alphaPerClass.count == data.K else { return nil }
        var owner = [Int](repeating: 0, count: d)
        for i in 0..<d {
            var visitor: Int?
            for k in 0..<data.K {
                guard i < data.alphaPerClass[k].count else { return nil }
                // A tolerance, not a zero test: a class can reach a station
                // through a chain of routing probabilities and arrive with a
                // throughput that is tiny but genuinely non-zero, and that
                // still puts two streams through the one server.
                guard data.alphaPerClass[k][i] > 1e-12 else { continue }
                if visitor != nil { return nil }
                visitor = k
            }
            // A station no class reaches cannot be Jackson-scored; in practice
            // `assess` has already returned `unstable()` for it, since αᵢ = 0
            // makes ρᵢ = 0 and the stability guard rejects ρ ≤ 0.
            guard let k = visitor else { return nil }
            owner[i] = k
        }
        return owner
    }

    private static func jacksonResult(
        data: SRBMExporter.SRBMData,
        nodes: [NetworkNode],
        rho: [Double],
        infiniteBuffers: Bool
    ) -> Result? {
        guard infiniteBuffers else { return nil }
        guard let classAtStation = singleClassPerStation(data: data) else { return nil }
        let d = data.d
        let disjointClasses = data.K > 1

        // Station order has to match the SRBM data's, because `classAtStation`
        // is indexed by it. `SRBMExporter.computeData` sorts stations by
        // `NodeNaming.sortIndex`; so do we, and we decline the branch rather
        // than guess if the two disagree on how many stations exist.
        let stations = nodes.filter { $0.kind == .station }
            .sorted { NodeNaming.sortIndex($0.name) < NodeNaming.sortIndex($1.name) }
        guard stations.count == d else { return nil }

        // All sources must be Poisson (memoryless inter-arrival).
        let sources = nodes.filter { $0.kind == .source }
        for s in sources {
            switch s.distribution {
            case .poisson, .exponential:
                continue
            default:
                return nil
            }
        }

        // Every station must serve exponentially — but only the class that
        // actually visits it is checked. A per-class override left behind for
        // a class that no longer reaches this station never enters μ_eff
        // (`SRBMExporter.serviceRateForClass` reads exactly one entry per
        // class per station), so it must not decide the branch either.
        for (i, st) in stations.enumerated() {
            if let cfg = st.serviceDistributions[classAtStation[i]] {
                if cfg.distribution != .exponential { return nil }
            } else if st.distribution != .exponential {
                return nil
            }
        }

        // Closed-form M/M/s mean number in system per station.
        var means = [Double](repeating: 0, count: d)
        for i in 0..<d {
            let s = data.numberOfServers[i]
            means[i] = mmsMeanInSystem(rho: rho[i], servers: s)
        }

        let premise = disjointClasses
            ? """
            All inter-arrival and service distributions are exponential and buffers are infinite. \
            This document holds \(data.K) customer classes, but no station is visited by more than \
            one of them, so they are disjoint sub-networks rather than streams competing for a \
            server: every station sees a single exponential class, and the document as a whole is \
            the same stochastic object as one single-class Jackson network over all \(d) stations.
            """
            : """
            All inter-arrival and service distributions are exponential, buffers are infinite, \
            and there is a single customer class.
            """

        return Result(
            kind: .exactJackson,
            title: "This network is analytically tractable",
            detail: disjointClasses
                ? "Open Jackson network — exact M/M/s product form (\(data.K) classes, no shared station)"
                : "Open Jackson network — exact M/M/s product form",
            means: means,
            meansLabel: "Exact E[N]  (Jackson)",
            explanation: """
            \(premise) By Jackson's theorem the stationary \
            joint distribution of station populations factorises; each station i behaves \
            as an independent M/M/sᵢ queue with
                ρᵢ = αᵢ / (sᵢ · μᵢ)  < 1
                E[Nᵢ] = closed-form M/M/sᵢ mean (Erlang-C for sᵢ > 1, ρᵢ/(1−ρᵢ) for sᵢ = 1).
            """
        )
    }

    /// Expected number in system for an M/M/s queue with offered load a = ρ·s.
    /// Uses Erlang-C; reduces to ρ/(1-ρ) when s = 1.
    private static func mmsMeanInSystem(rho: Double, servers: Int) -> Double {
        let s = max(1, servers)
        if s == 1 { return rho / (1.0 - rho) }
        let a = rho * Double(s)                     // offered load
        // Erlang-C probability of waiting
        var sum = 0.0
        var term = 1.0
        for n in 0..<s {
            if n > 0 { term *= a / Double(n) }
            sum += term
        }
        let aS_over_sFact = term * a / Double(s)    // a^s / s!
        let C = aS_over_sFact / (1.0 - rho) /
                (sum + aS_over_sFact / (1.0 - rho))
        let Lq = C * rho / (1.0 - rho)              // mean in queue
        return Lq + a                                // mean in system = Lq + ρs
    }

    // MARK: - Harrison–Williams skew-symmetry (1987)

    /// Test 2Γ = R · diag(Γ/R_ii) + diag(Γ/R_ii) · R⊤ element-wise.
    /// If it holds, the SRBM has a product exponential stationary distribution
    /// with E[Zₖ] = Γₖₖ / (2 Rₖₖ δₖ) where δ = −R⁻¹μ.
    private static func skewSymmetricResult(
        R: [[Double]], Gamma: [[Double]], mu: [Double], d: Int
    ) -> Result? {

        // D_ii = Γ_ii / R_ii must be finite and positive.
        var D = [Double](repeating: 0, count: d)
        for i in 0..<d {
            guard R[i][i] > 1e-12, Gamma[i][i] > 1e-12 else { return nil }
            D[i] = Gamma[i][i] / R[i][i]
        }

        let tol = 1e-6
        for i in 0..<d {
            for j in 0..<d {
                let lhs = 2.0 * Gamma[i][j]
                let rhs = R[i][j] * D[j] + D[i] * R[j][i]
                let scale = max(1.0, abs(lhs), abs(rhs))
                if abs(lhs - rhs) > tol * scale { return nil }
            }
        }

        // δ = −R⁻¹ μ
        guard let delta = solveLinearSystem(R, negate(mu), d: d) else { return nil }
        for k in 0..<d { if delta[k] <= 0 { return nil } }

        var means = [Double](repeating: 0, count: d)
        for k in 0..<d { means[k] = Gamma[k][k] / (2.0 * R[k][k] * delta[k]) }

        return Result(
            kind: .exactSkewSymmetric,
            title: "This network is analytically tractable",
            detail: "SRBM skew-symmetric case — Harrison–Williams 1987 exact product form",
            means: means,
            meansLabel: "Exact E[X]  (skew-sym)",
            explanation: """
            The SRBM data (Γ, R) satisfy the Harrison–Williams (1987) skew-symmetry condition
                2 Γ = R · diag(Γ/Rᵢᵢ) + diag(Γ/Rᵢᵢ) · R⊤,
            so the stationary distribution of Z is a product of independent exponentials with
                E[Zₖ] = Γₖₖ / (2 Rₖₖ δₖ),   δ = −R⁻¹μ.
            """
        )
    }

    // MARK: - GCDG 2025 formulas

    /// Computes asymptotic means m_k = uₖ'Γuₖ / (2 uₖ' R_{:,k}) per Theorem 1
    /// / eqs. (2.4)–(2.6). `uₖ` is built triangularly: the first k−1 entries
    /// solve  Σ_{j<k} w_{jk} R_{j,ℓ} + R_{k,ℓ} = 0  for ℓ = 1..k−1.
    ///
    /// Note on accuracy: these are *asymptotic* means for the
    /// multi-scaling regime where δᵢ = rⁱ → 0. For networks that don't
    /// satisfy the regime (mixed ρ, finite distance from heavy traffic,
    /// re-entrant multi-class structure), these values can differ
    /// substantially from the actual queueing-system means — the
    /// `meansLabel` of "Asymptotic E[X]" and the popover detail line
    /// signal this. Compare against algorithms or simulation for
    /// verification on any specific network.
    ///
    /// Returns empty array on any numerical failure.
    private static func gcdgMeans(
        R: [[Double]], Gamma: [[Double]], mu: [Double], d: Int
    ) -> [Double] {
        var means = [Double](repeating: 0, count: d)

        for k in 0..<d {
            var u = [Double](repeating: 0, count: d)
            u[k] = 1.0

            if k >= 1 {
                // Build (k×k) system  A w = b  where
                //   A[ℓ][j] = R[j][ℓ]    j,ℓ = 0..k-1   (note: paper is 1-indexed)
                //   b[ℓ]    = -R[k][ℓ]
                var A = Array(repeating: [Double](repeating: 0, count: k), count: k)
                var b = [Double](repeating: 0, count: k)
                for ell in 0..<k {
                    for j in 0..<k {
                        A[ell][j] = R[j][ell]
                    }
                    b[ell] = -R[k][ell]
                }
                guard let w = solveLinearSystem(A, b, d: k) else { return [] }
                for j in 0..<k { u[j] = w[j] }
            }

            // numerator  uᵀ Γ u
            var num = 0.0
            for i in 0..<d {
                var rowSum = 0.0
                for j in 0..<d { rowSum += Gamma[i][j] * u[j] }
                num += u[i] * rowSum
            }
            // denominator  2 · uᵀ R_{:,k}
            var denom = 0.0
            for i in 0..<d { denom += u[i] * R[i][k] }
            denom *= 2.0

            guard abs(denom) > 1e-14 else { return [] }
            means[k] = num / denom
            if !means[k].isFinite { return [] }
        }

        _ = mu  // drift enters only through the skew-sym branch; kept for sig parity
        return means
    }

    // MARK: - Routing-graph topology

    /// Returns true if the routing matrix `P` (entries `P[i][j]` = probability
    /// that a customer leaving station i routes to station j) contains any
    /// directed cycle, including self-loops. Topology only — magnitudes don't
    /// matter beyond the threshold.
    ///
    /// Used by:
    ///   * the run-comparison regime banner to flag QNA as "may degrade
    ///     under heavy feedback",
    ///   * the network editor to surface a feedback indicator,
    ///   * GCDG Cor. 3 to decide whether the routing graph is acyclic and
    ///     therefore admits a topological relabeling.
    static func hasRoutingCycles(_ P: [[Double]]) -> Bool {
        let d = P.count
        // Self-loops are trivial cycles.
        for i in 0..<d where P[i][i] > 1e-12 { return true }
        // Kahn's algorithm: peel zero-in-degree nodes; if anything remains,
        // a cycle exists.
        var inDeg = [Int](repeating: 0, count: d)
        for i in 0..<d {
            for j in 0..<d where i != j && P[i][j] > 1e-12 {
                inDeg[j] += 1
            }
        }
        var queue = (0..<d).filter { inDeg[$0] == 0 }
        var removed = 0
        while !queue.isEmpty {
            let u = queue.removeFirst()
            removed += 1
            for v in 0..<d where u != v && P[u][v] > 1e-12 {
                inDeg[v] -= 1
                if inDeg[v] == 0 { queue.append(v) }
            }
        }
        return removed < d
    }

    // MARK: - Matrix-property tests

    /// Finds a permutation `π` such that the relabeled reflection matrix
    /// `R_new[a][b] = R[π[a]][π[b]]` is lower-triangular, i.e., the
    /// routing graph is acyclic and `π` is a topological order from
    /// upstream to downstream stations. Returns `nil` if the graph
    /// contains any cycle (including self-loops).
    ///
    /// Recall `R = I − Pᵀ`, so:
    ///   - `R[i][j] = -P[j][i]` for i ≠ j (off-diagonal),
    ///   - `R[i][i] = 1 − P[i][i]`.
    /// A directed edge `u → v` in the routing graph corresponds to
    /// `P[u][v] > 0`, i.e., `R[v][u] < 0`. Self-loop at `u` ⇔ `R[u][u] < 1`.
    private static func permutationForLowerTriangular(
        _ R: [[Double]], d: Int
    ) -> [Int]? {
        // Self-loop ⇒ no triangularization possible.
        for u in 0..<d where 1.0 - R[u][u] > 1e-9 { return nil }
        // In-degree of v = number of u with edge u → v in routing graph
        //                = number of u ≠ v with R[v][u] < -1e-12.
        var inDeg = [Int](repeating: 0, count: d)
        for v in 0..<d {
            for u in 0..<d where u != v && -R[v][u] > 1e-12 {
                inDeg[v] += 1
            }
        }
        var queue = (0..<d).filter { inDeg[$0] == 0 }
        var order = [Int]()
        order.reserveCapacity(d)
        while !queue.isEmpty {
            let u = queue.removeFirst()
            order.append(u)
            for v in 0..<d where u != v && -R[v][u] > 1e-12 {
                inDeg[v] -= 1
                if inDeg[v] == 0 { queue.append(v) }
            }
        }
        return order.count == d ? order : nil
    }

    /// Returns `M[π[a]][π[b]]` for all `a, b`.
    private static func permuteMatrix(_ M: [[Double]], perm: [Int]) -> [[Double]] {
        let d = perm.count
        var out = Array(repeating: [Double](repeating: 0, count: d), count: d)
        for a in 0..<d {
            for b in 0..<d { out[a][b] = M[perm[a]][perm[b]] }
        }
        return out
    }

    /// An M-matrix has non-positive off-diagonal entries, positive diagonal,
    /// and a non-negative inverse. For our reflection matrices R = I − Pᵀ,
    /// the structural check alone is sufficient (P sub-stochastic ⇒ M-matrix)
    /// but we also verify via the inverse test for robustness.
    private static func isMMatrix(_ R: [[Double]], d: Int) -> Bool {
        for i in 0..<d {
            if R[i][i] <= 1e-12 { return false }
            for j in 0..<d where j != i {
                if R[i][j] > 1e-9 { return false }
            }
        }
        guard let Rinv = invertMatrix(R, d: d) else { return false }
        for i in 0..<d {
            for j in 0..<d {
                if Rinv[i][j] < -1e-9 { return false }
            }
        }
        return true
    }

    /// P-matrix test: all principal minors > 0. Feasible for d ≤ 6 by
    /// enumerating 2^d − 1 subsets; refuses otherwise (returns false).
    private static func isPMatrix(_ R: [[Double]], d: Int) -> Bool {
        guard d >= 1 && d <= 6 else { return false }
        let n = 1 << d
        for mask in 1..<n {
            var idx = [Int]()
            for i in 0..<d where (mask >> i) & 1 == 1 { idx.append(i) }
            let k = idx.count
            var sub = Array(repeating: [Double](repeating: 0, count: k), count: k)
            for a in 0..<k {
                for b in 0..<k { sub[a][b] = R[idx[a]][idx[b]] }
            }
            let det = determinant(sub, n: k)
            if det <= 1e-12 { return false }
        }
        return true
    }

    // MARK: - Linear algebra helpers

    /// Gaussian elimination with partial pivoting. Returns nil if singular.
    private static func solveLinearSystem(
        _ A: [[Double]], _ b: [Double], d: Int
    ) -> [Double]? {
        guard d > 0 else { return [] }
        var M = A
        var rhs = b
        for i in 0..<d {
            // pivot
            var piv = i
            var best = abs(M[i][i])
            for r in (i+1)..<d where abs(M[r][i]) > best {
                best = abs(M[r][i]); piv = r
            }
            if best < 1e-14 { return nil }
            if piv != i {
                M.swapAt(i, piv)
                rhs.swapAt(i, piv)
            }
            // eliminate
            for r in (i+1)..<d {
                let f = M[r][i] / M[i][i]
                if f == 0 { continue }
                for c in i..<d { M[r][c] -= f * M[i][c] }
                rhs[r] -= f * rhs[i]
            }
        }
        // back-substitute
        var x = [Double](repeating: 0, count: d)
        for i in stride(from: d - 1, through: 0, by: -1) {
            var s = rhs[i]
            for c in (i+1)..<d { s -= M[i][c] * x[c] }
            x[i] = s / M[i][i]
        }
        return x
    }

    private static func invertMatrix(_ A: [[Double]], d: Int) -> [[Double]]? {
        var inv = Array(repeating: [Double](repeating: 0, count: d), count: d)
        for k in 0..<d {
            var e = [Double](repeating: 0, count: d)
            e[k] = 1
            guard let col = solveLinearSystem(A, e, d: d) else { return nil }
            for i in 0..<d { inv[i][k] = col[i] }
        }
        return inv
    }

    private static func determinant(_ A: [[Double]], n: Int) -> Double {
        if n == 1 { return A[0][0] }
        if n == 2 { return A[0][0] * A[1][1] - A[0][1] * A[1][0] }
        var M = A
        var det = 1.0
        for i in 0..<n {
            var piv = i
            var best = abs(M[i][i])
            for r in (i+1)..<n where abs(M[r][i]) > best {
                best = abs(M[r][i]); piv = r
            }
            if best < 1e-14 { return 0 }
            if piv != i { M.swapAt(i, piv); det = -det }
            det *= M[i][i]
            for r in (i+1)..<n {
                let f = M[r][i] / M[i][i]
                for c in i..<n { M[r][c] -= f * M[i][c] }
            }
        }
        return det
    }

    // MARK: - Misc helpers

    private static func negate(_ v: [Double]) -> [Double] { v.map { -$0 } }

    /// `SRBMExporter.SRBMData.R` is stored in d×2d interleaved column ordering:
    /// column 2k is the lower-face reflection direction, column 2k+1 is the
    /// upper-face direction. The Harrison–Williams / GCDG tests use only the
    /// lower-face columns, which form the classical d×d reflection matrix.
    private static func lowerFaceR(from R2d: [[Double]], d: Int) -> [[Double]] {
        var R = Array(repeating: [Double](repeating: 0, count: d), count: d)
        for i in 0..<d {
            for k in 0..<d { R[i][k] = R2d[i][2 * k] }
        }
        return R
    }

    private static func unstable() -> Result {
        Result(
            kind: .none,
            title: "",
            detail: "",
            means: [],
            meansLabel: "",
            explanation: "Tractability analysis not applied: one or more stations are unstable (ρ ≥ 1) or receive no traffic."
        )
    }

    private static func gcdgExplanation(corollary: Int, reason: String) -> String {
        """
        Under the GCDG 2025 multi-scaling regime (traffic-slackness δᵢ = rⁱ), the stationary \
        distribution of the scaled SRBM converges to a product of independent exponentials \
        with explicit means mₖ = uₖ⊤Γuₖ / (2 uₖ⊤R_{:,k}) (Theorem 1, eqs. 2.4–2.6). Corollary \
        \(corollary) applies because \(reason)
        Reference: Guang, Chen, Dai, Glynn (2025). arXiv:2503.19710, Remark 2 & Cor. \(corollary).
        """
    }
}
