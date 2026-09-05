import Foundation

enum SRBMExportError: LocalizedError {
    case networkError(NetworkExportError)
    case infiniteMean(String)
    case infiniteVariance(String)
    case degenerateCovariance

    var errorDescription: String? {
        switch self {
        case .networkError(let e):
            return e.localizedDescription
        case .infiniteMean(let name):
            return "\(name) has a distribution with infinite mean (e.g. Pareto with shape <= 1)."
        case .infiniteVariance(let name):
            return "\(name) has a distribution with infinite variance (e.g. Pareto with shape <= 2)."
        case .degenerateCovariance:
            return "The covariance matrix is zero (all distributions are constant with deterministic routing). SRBM requires randomness."
        }
    }
}

@MainActor
enum SRBMExporter {

    // MARK: - Internal Data

    /// Computed SRBM parameters shared by all export formats.
    struct SRBMData {
        let d: Int
        let K: Int                      // number of customer classes
        let drift: [Double]
        let gamma: [[Double]]
        let R: [[Double]]               // interleaved column ordering
        let aVec: [Double]
        let serviceRates: [Double]      // effective per-server service rates
        let numberOfServers: [Int]
        let alpha: [Double]             // total throughput per station
        let alphaPerClass: [[Double]]   // per-class throughput [K][d]
        let aggregatedP: [[Double]]     // aggregated routing matrix d×d
        let capacity: [Double]          // station capacities (s_i * μ_eff_i)
        let classExternalArrivals: [Double]  // lambda_k per class
        let classExternalArrivalRates: [[Double]] // lambda_ext[k][i]
        let classServiceRates: [[Double]]    // mu[k][i] per class/station
        let arrivalSCVs: [Double]            // external arrival SCV per class
        let effectiveServiceSCVs: [Double]   // aggregated service SCV per station
    }

    // MARK: - Public

    /// Computes SRBM data from the network model (shared by all export formats).
    ///
    /// Supports multiple customer classes (K sources = K classes) and multiple
    /// servers per station.  Uses station-aggregated SRBM with:
    ///   - Per-class traffic equations: α_k = (I - (P^(k))^T)^{-1} λ^{ext}_k
    ///   - Throughput-weighted aggregation of routing and service rates
    ///   - Drift: b_i = α_i - c_i  (throughput minus capacity)
    ///   - Covariance: Harrison-Reiman decomposition Σ = A + (I-P^T)diag(B)(I-P) + Σ_routing
    ///   - Reflection: `infiniteBuffers=true` uses Harrison-Reiman (I − Pᵀ) at the
    ///     lower face + wall at the upper face; `false` uses manufacturing blocking.
    static func computeData(
        nodes: [NetworkNode],
        links: [NetworkLink],
        infiniteBuffers: Bool = false,
        lossModeCorrection: Bool = false,
        basModeCorrection: Bool = false
    ) -> Result<SRBMData, SRBMExportError> {

        // ── Gather and validate network structure ─────────────────
        let sources  = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        let sinks    = nodes.filter { $0.kind == .sink }
        let stations = nodes.filter { $0.kind == .station }
            .sorted { stationIndex($0.name) < stationIndex($1.name) }

        guard !stations.isEmpty else {
            return .failure(.networkError(.noStations))
        }
        guard !sources.isEmpty else {
            return .failure(.networkError(.noSource))
        }
        guard !sinks.isEmpty else {
            return .failure(.networkError(.noSink))
        }

        // ── Customer-class count ─────────────────────────────────
        // K = max(sources.count, highest class index referenced in any
        // link + 1). Derived classes (Phase 1 class transitions) have no
        // source — they enter mid-network via toCustomerClass on an
        // upstream link — so sources.count alone under-counts K when any
        // link carries a class transition.
        let maxLinkClass = links.reduce(-1) { acc, link in
            max(acc, link.customerClass, link.toCustomerClass ?? -1)
        }
        let K = max(sources.count, maxLinkClass + 1)
        let d = stations.count

        // ── Pair each station with its upstream buffer ────────────
        var bufferSizes = [Int]()
        for station in stations {
            let feedingBuffers = nodes.filter { candidate in
                candidate.kind == .buffer &&
                links.contains { $0.fromNodeID == candidate.id && $0.toNodeID == station.id }
            }
            guard feedingBuffers.count >= 1 else {
                return .failure(.networkError(.stationMissingBuffer(station.name)))
            }
            guard feedingBuffers.count == 1 else {
                return .failure(.networkError(.stationMultipleBuffers(station.name)))
            }
            bufferSizes.append(feedingBuffers[0].bufferSize)
        }

        // ── Verify first source reaches station 1 ────────────────
        let firstStation = stations[0]
        if !pathExists(from: sources[0].id, to: firstStation.id, nodes: nodes, links: links) {
            return .failure(.networkError(.sourceNotConnectedToStation1))
        }

        // ── Build station index map ──────────────────────────────
        var stationIDToIndex = [UUID: Int]()
        for (i, s) in stations.enumerated() {
            stationIDToIndex[s.id] = i
        }

        // ── Per-class external arrival rate vectors ──────────────
        // lambdaExt[k][i] = external arrival rate of class k at station i
        var lambdaExt = Array(repeating: Array(repeating: 0.0, count: d), count: K)

        var arrivalSCVs = [Double](repeating: 1.0, count: K)
        for (k, source) in sources.enumerated() {
            let rate = extractRate(distribution: source.distribution,
                                   parameters: source.distributionParameters)
            if rate <= 0 {
                return .failure(.infiniteMean(source.name))
            }
            let scv = extractSCV(distribution: source.distribution,
                                 parameters: source.distributionParameters)
            if scv.isInfinite {
                return .failure(.infiniteVariance(source.name))
            }
            arrivalSCVs[k] = scv
            let outLinks = links.filter { $0.fromNodeID == source.id }
            for link in outLinks {
                if let stationIdx = resolveTargetStation(
                    from: link.toNodeID, nodes: nodes, links: links,
                    stationIDToIndex: stationIDToIndex
                ) {
                    lambdaExt[k][stationIdx] += rate * link.routingProbability
                }
            }
        }
        // Derived classes (no source, arrivals only via upstream class
        // transitions) keep arrivalSCVs[k] = 1.0 default — they have no
        // external renewal arrival process, so the value is nominal.

        // ── Per-class routing matrices ───────────────────────────
        var P_class = [[[Double]]]()
        for classIdx in 0..<K {
            var matrix = Array(repeating: Array(repeating: 0.0, count: d), count: d)
            for (i, station) in stations.enumerated() {
                let outgoing = links.filter {
                    $0.fromNodeID == station.id && $0.customerClass == classIdx
                }
                for link in outgoing {
                    if let targetIdx = resolveTargetStation(
                        from: link.toNodeID, nodes: nodes, links: links,
                        stationIDToIndex: stationIDToIndex
                    ) {
                        matrix[i][targetIdx] += link.routingProbability
                    }
                }
                let rowSum = matrix[i].reduce(0, +)
                if rowSum > 1.0 + 1e-9 {
                    return .failure(.networkError(
                        .routingProbabilityExceedsOne(station.name, rowSum, classIdx)))
                }
            }
            P_class.append(matrix)
        }

        // ── Solve per-class traffic equations ────────────────────
        // Default path (no class transitions): each class's traffic
        // equation decouples — solve K independent d×d systems
        //     α_k = (I − (P^(k))⊤)⁻¹ λ^{ext}_k
        // Class-transition path: when any link carries a class change,
        // jobs can cross class boundaries mid-network and the per-class
        // systems are coupled. Build the expanded (K·d)×(K·d) routing
        // matrix P̃ (indexed by pairs (k, i)) and solve α̃ once:
        //     P̃[(k,i)][(k',j)] = Σ(links from station i with customerClass=k,
        //                          resolving to station j, toCustomerClass=k')
        //                          link.routingProbability
        //     α̃ = (I − P̃⊤)⁻¹ λ̃,   λ̃[(k,i)] = lambdaExt[k][i]
        // For zero-transition networks the expanded matrix is block-
        // diagonal and produces the same α as the per-class solves.
        var alphaPerClass = Array(repeating: Array(repeating: 0.0, count: d), count: K)
        let hasClassTransitions = links.contains { link in
            guard let to = link.toCustomerClass else { return false }
            return to != link.customerClass
        }

        if !hasClassTransitions {
            // PRE-PHASE-1 PATH (unchanged) — each class solved independently.
            for k in 0..<K {
                let solved = solveTrafficEquations(
                    P: P_class[k], externalRates: lambdaExt[k], d: d)
                if let bad = solved.singularIndex {
                    return .failure(.networkError(
                        .trafficEquationsSingular(stations[bad].name, k)))
                }
                alphaPerClass[k] = solved.alpha
            }
        } else {
            // Class-expanded solve.
            let N = K * d
            var P_ex = Array(repeating: [Double](repeating: 0, count: N), count: N)
            for (i, station) in stations.enumerated() {
                let outgoing = links.filter { $0.fromNodeID == station.id }
                for link in outgoing {
                    guard let targetIdx = resolveTargetStation(
                        from: link.toNodeID, nodes: nodes, links: links,
                        stationIDToIndex: stationIDToIndex
                    ) else { continue }
                    let fromClass = link.customerClass
                    let toClass   = link.toCustomerClass ?? link.customerClass
                    guard fromClass >= 0 && fromClass < K,
                          toClass   >= 0 && toClass   < K else { continue }
                    P_ex[fromClass * d + i][toClass * d + targetIdx]
                        += link.routingProbability
                }
            }
            var lambda_ex = [Double](repeating: 0, count: N)
            for k in 0..<K {
                for i in 0..<d { lambda_ex[k * d + i] = lambdaExt[k][i] }
            }
            let solved = solveTrafficEquations(
                P: P_ex, externalRates: lambda_ex, d: N)
            if let bad = solved.singularIndex {
                // The expanded system is indexed by (class, station) pairs.
                return .failure(.networkError(
                    .trafficEquationsSingular(stations[bad % d].name, bad / d)))
            }
            let alpha_ex = solved.alpha
            for k in 0..<K {
                for i in 0..<d { alphaPerClass[k][i] = alpha_ex[k * d + i] }
            }
        }

        // ── Total throughput per station ─────────────────────────
        var alpha = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            for k in 0..<K {
                alpha[i] += alphaPerClass[k][i]
            }
        }

        // ── Server counts ────────────────────────────────────────
        var serverCounts = [Int]()
        for station in stations {
            serverCounts.append(station.numberOfServers)
        }

        // ── Effective service rate and SCV (throughput-weighted) ──
        // Mixture service distribution: each arrival at station i draws
        // from class k with probability α^(k)_i / α_i. Correct effective
        // service RATE is the harmonic mean (reciprocal of mean service
        // time of the mixture), not the arithmetic mean of per-class
        // rates, which over-estimates μ_eff and under-reports ρ:
        //   m1_i = E[S_i]  = Σ_k (α_k_i/α_i) · (1/μ_{i,k})
        //   m2_i = E[S_i²] = Σ_k (α_k_i/α_i) · (1+c²_{s,i,k}) · (1/μ_{i,k})²
        //   μ_eff_i = 1 / m1_i
        //   c²_{s,eff,i} = (m2_i − m1_i²) / m1_i²
        var muEff = Array(repeating: 0.0, count: d)
        var scvEff = Array(repeating: 0.0, count: d)
        for (i, station) in stations.enumerated() {
            if alpha[i] > 1e-15 {
                var m1 = 0.0
                var m2 = 0.0
                for k in 0..<K {
                    let weight = alphaPerClass[k][i] / alpha[i]
                    let mu_ik = serviceRateForClass(station: station, classIdx: k)
                    let scv_ik = serviceSCVForClass(station: station, classIdx: k)
                    guard mu_ik > 0 else {
                        return .failure(.infiniteMean(station.name))
                    }
                    let meanSvc = 1.0 / mu_ik
                    m1 += weight * meanSvc
                    m2 += weight * (1.0 + scv_ik) * meanSvc * meanSvc
                }
                guard m1 > 0 else {
                    return .failure(.infiniteMean(station.name))
                }
                muEff[i] = 1.0 / m1
                scvEff[i] = max(0.0, (m2 - m1 * m1) / (m1 * m1))
            } else {
                muEff[i] = serviceRateForClass(station: station, classIdx: 0)
                scvEff[i] = serviceSCVForClass(station: station, classIdx: 0)
            }
            if muEff[i] <= 0 {
                return .failure(.infiniteMean(station.name))
            }
            if scvEff[i].isInfinite {
                return .failure(.infiniteVariance(station.name))
            }
        }

        // ── Aggregated routing matrix ────────────────────────────
        // P_ij = Σ_k (α_k_i / α_i) * P^(k)_{ij}
        var P = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            if alpha[i] > 1e-15 {
                for j in 0..<d {
                    for k in 0..<K {
                        P[i][j] += (alphaPerClass[k][i] / alpha[i]) * P_class[k][i][j]
                    }
                }
            }
        }

        // ── Station capacity: c_i = s_i * μ_eff_i ───────────────
        var capacity = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            capacity[i] = Double(serverCounts[i]) * muEff[i]
        }

        // ── Loss-mode correction (optional) ──────────────────────
        // The default SRBM hypercube model is closer to a "production
        // blocking" reflection than to true M/G/c/K loss. For loss-mode
        // simulator comparisons (Run Comparison's `-l` flag) the SRBM
        // over-predicts queues because it doesn't shrink the throughput
        // when buffers fill. Apply an iterative QNA-style correction:
        //   α_arrive_j = λ_ext_j + Σ_i α_arrive_i · (1 − P_loss_i) · P_ij
        //   P_loss_i   = M/M/1/K(α_arrive_i / capacity_i, K_i = buf_i + s_i)
        //   α_throughput_i = α_arrive_i · (1 − P_loss_i)
        // Use α_throughput as the SRBM "α" so drift = α_thru − capacity is
        // pushed further negative when losses are non-trivial. Capacity,
        // muEff, and the per-class routing matrices are unchanged (the
        // loss is class-blind FCFS so mix weights survive).
        if lossModeCorrection && !infiniteBuffers {
            var alphaArrive = alphaPerClass
            let maxIter = 30
            let tol = 1e-7
            for _ in 0..<maxIter {
                // Total offered load → P_loss per station.
                var totalArrive = [Double](repeating: 0, count: d)
                for i in 0..<d {
                    for k in 0..<K { totalArrive[i] += alphaArrive[k][i] }
                }
                var pLoss = [Double](repeating: 0, count: d)
                for i in 0..<d where capacity[i] > 1e-15 {
                    let rho = totalArrive[i] / capacity[i]
                    let cap = bufferSizes[i] + serverCounts[i]
                    pLoss[i] = mm1kBlockingProb(rho: rho, K: cap)
                }
                // Re-solve per-class with effective routing
                // P_eff[i][j] = P_class[k][i][j] · (1 − P_loss[i]).
                var alphaArriveNew = Array(
                    repeating: [Double](repeating: 0, count: d), count: K)
                var maxDelta = 0.0
                for k in 0..<K {
                    var P_eff = Array(
                        repeating: [Double](repeating: 0, count: d), count: d)
                    for i in 0..<d {
                        let factor = 1.0 - pLoss[i]
                        for j in 0..<d {
                            P_eff[i][j] = P_class[k][i][j] * factor
                        }
                    }
                    let solved = solveTrafficEquations(
                        P: P_eff, externalRates: lambdaExt[k], d: d)
                    if let bad = solved.singularIndex {
                        return .failure(.networkError(
                            .trafficEquationsSingular(stations[bad].name, k)))
                    }
                    alphaArriveNew[k] = solved.alpha
                    for i in 0..<d {
                        let delta = abs(alphaArriveNew[k][i] - alphaArrive[k][i])
                        if delta > maxDelta { maxDelta = delta }
                    }
                }
                alphaArrive = alphaArriveNew
                if maxDelta < tol { break }
            }
            // Final α_throughput per class = α_arrive × (1 − P_loss).
            var totalArrive = [Double](repeating: 0, count: d)
            for i in 0..<d {
                for k in 0..<K { totalArrive[i] += alphaArrive[k][i] }
            }
            var pLoss = [Double](repeating: 0, count: d)
            for i in 0..<d where capacity[i] > 1e-15 {
                let rho = totalArrive[i] / capacity[i]
                let cap = bufferSizes[i] + serverCounts[i]
                pLoss[i] = mm1kBlockingProb(rho: rho, K: cap)
            }
            for k in 0..<K {
                for i in 0..<d {
                    alphaPerClass[k][i] = alphaArrive[k][i] * (1.0 - pLoss[i])
                }
            }
            for i in 0..<d {
                alpha[i] = 0
                for k in 0..<K { alpha[i] += alphaPerClass[k][i] }
            }
        }

        // ── BAS-mode correction (optional) ───────────────────────
        // Mutually exclusive with the loss correction above — BAS is
        // back-pressure, Loss is forward rejection. Approximates BAS by
        // inflating effective service time at upstream stations when
        // downstream buffers fill:
        //   μ_eff_i_BAS = μ_eff_i · (1 − Σ_j P_ij · P̂(B_j full))
        //   capacity_i  = s_i · μ_eff_i_BAS    (shrinks ⇒ drift up)
        // This is less principled than the Loss correction (no clean
        // Markovian formula for BAS), but it closes part of the ~10%
        // BAS gap vs simulator without requiring reflection-matrix
        // surgery. P_block is estimated from M/M/1/K at the current
        // offered load, capped at ρ ≤ 0.999 so the iteration stays
        // stable when a downstream station is fully blocked.
        if basModeCorrection && !infiniteBuffers && !lossModeCorrection {
            // Dampening factor — the raw "μ → μ(1 − P_block)" over-shoots
            // at upstream stations because compounding P_block estimates
            // from already-corrected downstream queues amplifies the
            // effect. Empirically, β ≈ 0.5 brings the average per-
            // station error in line with the un-corrected case while
            // dramatically improving bottleneck-station accuracy. Below
            // 0.3 the correction barely fires; above 0.7 it over-shoots
            // by 20%+ upstream. β = 0.5 is the documented choice.
            let beta = 0.5
            let muEffBase = muEff
            let maxIter = 30
            let tol = 1e-7
            for _ in 0..<maxIter {
                var pBlock = [Double](repeating: 0, count: d)
                for i in 0..<d where capacity[i] > 1e-15 {
                    let rho = min(alpha[i] / capacity[i], 0.999)
                    let cap = bufferSizes[i] + serverCounts[i]
                    pBlock[i] = mm1kBlockingProb(rho: rho, K: cap)
                }
                var maxDelta = 0.0
                for i in 0..<d {
                    var blockSum = 0.0
                    for j in 0..<d {
                        blockSum += P[i][j] * pBlock[j]
                    }
                    // Floor at 0.05 — server can never effectively idle
                    // more than 95% of the time even with full downstream
                    // blocking (stability guard for the SRBM solver).
                    let factor = max(0.05, 1.0 - beta * blockSum)
                    let newMu = muEffBase[i] * factor
                    let newCap = Double(serverCounts[i]) * newMu
                    maxDelta = max(maxDelta, abs(newCap - capacity[i]))
                    capacity[i] = newCap
                    muEff[i] = newMu
                }
                if maxDelta < tol { break }
            }
        }

        // ── Drift: b_i = α_i - c_i ──────────────────────────────
        var drift = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            drift[i] = alpha[i] - capacity[i]
        }

        // ── Covariance: Harrison-Reiman decomposition ────────────
        // Σ = A + (I-P^T)diag(B)(I-P) + Σ_routing
        let gamma = computeCovariance(
            P: P, lambdaExt: lambdaExt, arrivalSCVs: arrivalSCVs,
            capacity: capacity, effectiveServiceSCVs: scvEff, d: d)

        // ── Reflection matrix ────────────────────────────────────
        let R = computeReflectionMatrix(P: P, d: d, infiniteBuffers: infiniteBuffers)

        // ── Hypercube dimensions ─────────────────────────────────
        // Total per-station capacity for the SRBM workload variable X_i is
        //   buffer.bufferSize  (queue slots, excluding the server)
        // + numberOfServers   (server slots)
        // The simulator enforces this same total, so e.g. an M/M/1/K queue
        // with buffer.bufferSize = 10 simulates as K = 11 (10 in queue + 1
        // in service). Previously aVec was just bufferSizes[i], which made
        // the polynomial methods solve the SRBM on a one-too-small box and
        // disagreed with the simulator by an offset that grew as buffers
        // shrank. For an infinite-buffer network this code path is unused
        // (aVec is unused for the orthant case).
        var aVec = [Double](repeating: 0, count: d)
        for i in 0..<d {
            aVec[i] = Double(bufferSizes[i] + serverCounts[i])
        }

        // ── Per-class external arrival rates ───────────────────
        var classLambda = [Double](repeating: 0, count: K)
        for k in 0..<K {
            classLambda[k] = lambdaExt[k].reduce(0, +)
        }

        // ── Per-class service rates ────────────────────────────
        var classMu = Array(repeating: [Double](repeating: 0, count: d), count: K)
        for k in 0..<K {
            for (i, station) in stations.enumerated() {
                classMu[k][i] = serviceRateForClass(station: station, classIdx: k)
            }
        }

        return .success(SRBMData(
            d: d, K: K, drift: drift, gamma: gamma, R: R, aVec: aVec,
            serviceRates: muEff, numberOfServers: serverCounts,
            alpha: alpha, alphaPerClass: alphaPerClass,
            aggregatedP: P, capacity: capacity,
            classExternalArrivals: classLambda,
            classExternalArrivalRates: lambdaExt,
            classServiceRates: classMu,
            arrivalSCVs: arrivalSCVs,
            effectiveServiceSCVs: scvEff
        ))
    }

    /// Exports the queueing network as an SRBM input file for fbna.c / fBNAsm.
    ///
    /// Output format (all numbers, blank-line separated):
    ///   d
    ///   theta_1 ... theta_d           (drift vector)
    ///   Gamma_{11} ... Gamma_{1d}     (covariance matrix, d rows)
    ///   R_{11} ... R_{1,2d}           (reflection matrix, d rows, interleaved columns)
    ///   a_1 ... a_d                   (hypercube dimensions)
    static func export(
        nodes: [NetworkNode],
        links: [NetworkLink],
        infiniteBuffers: Bool = false,
        lossModeCorrection: Bool = false,
        basModeCorrection: Bool = false
    ) -> Result<String, SRBMExportError> {
        let result = computeData(
            nodes: nodes, links: links,
            infiniteBuffers: infiniteBuffers,
            lossModeCorrection: lossModeCorrection,
            basModeCorrection: basModeCorrection)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return .success(formatInterleaved(data: data))
        }
    }

    /// Exports for fBNAsm (spectral method): interleaved R + polynomial degree + service rates + customer class data.
    static func exportForSpectral(
        nodes: [NetworkNode],
        links: [NetworkLink],
        infiniteBuffers: Bool = false,
        degree: Int = 8,
        lossModeCorrection: Bool = false,
        basModeCorrection: Bool = false
    ) -> Result<String, SRBMExportError> {
        let result = computeData(
            nodes: nodes, links: links,
            infiniteBuffers: infiniteBuffers,
            lossModeCorrection: lossModeCorrection,
            basModeCorrection: basModeCorrection)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            var text = formatInterleaved(data: data)
            text += "\(degree)\n"
            text += "\n"
            text += data.serviceRates.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            text += "customer_classes \(data.K)\n"
            text += "\n"
            // alpha_total per station
            text += data.alpha.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            // lambda_k per class
            text += data.classExternalArrivals.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            // alpha[k][i] — per-class throughput (K rows x d cols)
            for k in 0..<data.K {
                text += data.alphaPerClass[k].map { formatValue($0) }.joined(separator: " ") + "\n"
            }
            text += "\n"
            // mu[k][i] — per-class service rate (K rows x d cols)
            for k in 0..<data.K {
                text += data.classServiceRates[k].map { formatValue($0) }.joined(separator: " ") + "\n"
            }
            text += "\n"
            return .success(text)
        }
    }

    /// Exports for fBNAfm (finite element): grouped R + mesh sizes + service rates + customer class data.
    static func exportForFiniteElement(
        nodes: [NetworkNode],
        links: [NetworkLink],
        infiniteBuffers: Bool = false,
        meshSize: Int = 10,
        lossModeCorrection: Bool = false,
        basModeCorrection: Bool = false
    ) -> Result<String, SRBMExportError> {
        let result = computeData(
            nodes: nodes, links: links,
            infiniteBuffers: infiniteBuffers,
            lossModeCorrection: lossModeCorrection,
            basModeCorrection: basModeCorrection)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            var text = formatGrouped(data: data)
            let meshSizes = Array(repeating: "\(meshSize)", count: data.d)
            text += meshSizes.joined(separator: " ") + "\n"
            text += "\n"
            text += data.serviceRates.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            text += "customer_classes \(data.K)\n"
            text += "\n"
            text += data.alpha.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            text += data.classExternalArrivals.map { formatValue($0) }.joined(separator: " ") + "\n"
            text += "\n"
            for k in 0..<data.K {
                text += data.alphaPerClass[k].map { formatValue($0) }.joined(separator: " ") + "\n"
            }
            text += "\n"
            for k in 0..<data.K {
                text += data.classServiceRates[k].map { formatValue($0) }.joined(separator: " ") + "\n"
            }
            text += "\n"
            return .success(text)
        }
    }

    /// Recommended (gridN, basisM) for fBNAlp at the given dimensionality.
    /// Mirrors `BNASRBMExporter.recommendedBNAlpGrid` but with finite-buffer
    /// presets — the LP has 2d boundary blocks instead of d, so we keep n a
    /// little smaller at higher d to keep the LP comfortably inside HiGHS.
    static func recommendedFiniteLPGrid(forDimension d: Int) -> (Int, Int) {
        switch d {
        case ...1:  return (64, 8)
        case 2:     return (20, 6)
        case 3:     return (12, 4)
        case 4:     return ( 8, 3)
        default:    return ( 6, 3)
        }
    }

    /// Exports for fBNAlp (finite-buffer LP): keyword-driven input matching
    /// `Qnet/finite/fBNAlp/src/srbm_params.c`. Uses interleaved R block + per-axis
    /// upper_bounds from the buffer sizes (data.aVec).
    static func exportForFiniteLP(
        nodes: [NetworkNode],
        links: [NetworkLink],
        gridN: Int = 0,
        basisM: Int = 0,
        gridType: String = "uniform",
        solver: String = "highs",
        outputPrefix: String? = nil,
        smoothnessWeight: Double = 0.0,
        basisNormalize: Bool = false,
        lossModeCorrection: Bool = false,
        basModeCorrection: Bool = false
    ) -> Result<String, SRBMExportError> {
        let result = computeData(
            nodes: nodes, links: links,
            infiniteBuffers: false,
            lossModeCorrection: lossModeCorrection,
            basModeCorrection: basModeCorrection)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return .success(formatFiniteLPInput(
                data: data,
                gridN: gridN,
                basisM: basisM,
                gridType: gridType,
                solver: solver,
                outputPrefix: outputPrefix,
                smoothnessWeight: smoothnessWeight,
                basisNormalize: basisNormalize))
        }
    }

    /// Builds the keyword-driven fBNAlp input string from already-computed
    /// SRBM primitives.  `gridN`/`basisM` of 0 mean "auto-scale by dimension"
    /// via `recommendedFiniteLPGrid`.
    static func formatFiniteLPInput(
        data: SRBMData,
        gridN: Int,
        basisM: Int,
        gridType: String,
        solver: String,
        outputPrefix: String? = nil,
        smoothnessWeight: Double = 0.0,
        basisNormalize: Bool = false
    ) -> String {
        let rec = recommendedFiniteLPGrid(forDimension: data.d)
        let n = gridN > 0 ? gridN : rec.0
        let m = basisM > 0 ? basisM : rec.1

        var lines = [String]()
        lines.append("# Qnet -> fBNAlp finite-buffer SRBM input")
        lines.append("# d = \(data.d), buffers = " +
                     data.aVec.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        lines.append("")

        lines.append("dimension  \(data.d)")
        lines.append("grid_n     \(n)")
        lines.append("basis_m    \(m)")
        lines.append("grid_type  \(gridType)")
        lines.append("solver     \(solver)")
        if let prefix = outputPrefix { lines.append("output_prefix \(prefix)") }
        if smoothnessWeight > 0 { lines.append("smoothness_weight \(smoothnessWeight)") }
        if basisNormalize       { lines.append("basis_normalize 1") }
        lines.append("")

        lines.append("drift")
        lines.append("  " + data.drift.map { formatValue($0) }.joined(separator: "  "))
        lines.append("")

        lines.append("covariance")
        for row in data.gamma {
            lines.append("  " + row.map { formatValue($0) }.joined(separator: "  "))
        }
        lines.append("")

        // data.R is already in interleaved [lower_0, upper_0, lower_1, upper_1, ...] form.
        lines.append("reflection_form interleaved")
        lines.append("reflection")
        for row in data.R {
            lines.append("  " + row.map { formatValue($0) }.joined(separator: "  "))
        }
        lines.append("")

        lines.append("upper_bounds")
        lines.append("  " + data.aVec.map { formatValue($0) }.joined(separator: "  "))
        lines.append("")

        // Per-station effective service rate (μ_eff_i = 1 / E[service]).
        // The C-side solver uses this to print rho_i, Gamma_i, sojourn_i —
        // matching the spectral/FEM output so all three appear in the same
        // Run Comparison table.
        if !data.serviceRates.isEmpty {
            lines.append("service_rates")
            lines.append("  " + data.serviceRates.map { formatValue($0) }.joined(separator: "  "))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// Formats SRBM data with interleaved R columns (for fBNAsm).
    /// Columns: [lower₀, upper₀, lower₁, upper₁, ...]
    private static func formatInterleaved(data: SRBMData) -> String {
        var lines = [String]()
        lines.append("\(data.d)")
        lines.append("")
        lines.append(data.drift.map { formatValue($0) }.joined(separator: " "))
        lines.append("")
        for row in data.gamma {
            lines.append(row.map { formatValue($0) }.joined(separator: " "))
        }
        lines.append("")
        for row in data.R {
            lines.append(row.map { formatValue($0) }.joined(separator: " "))
        }
        lines.append("")
        lines.append(data.aVec.map { formatValue($0) }.joined(separator: " "))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Formats SRBM data with grouped R columns (for fBNAfm).
    /// Columns: [lower₀, lower₁, ..., upper₀, upper₁, ...]
    private static func formatGrouped(data: SRBMData) -> String {
        let d = data.d
        // Convert interleaved → grouped column ordering
        var groupedR = Array(repeating: Array(repeating: 0.0, count: 2 * d), count: d)
        for row in 0..<d {
            for j in 0..<(2 * d) {
                let interleavedCol: Int
                if j < d {
                    interleavedCol = 2 * j       // lower face j
                } else {
                    interleavedCol = 2 * (j - d) + 1  // upper face (j-d)
                }
                groupedR[row][j] = data.R[row][interleavedCol]
            }
        }

        var lines = [String]()
        lines.append("\(d)")
        lines.append("")
        lines.append(data.drift.map { formatValue($0) }.joined(separator: " "))
        lines.append("")
        for row in data.gamma {
            lines.append(row.map { formatValue($0) }.joined(separator: " "))
        }
        lines.append("")
        for row in groupedR {
            lines.append(row.map { formatValue($0) }.joined(separator: " "))
        }
        lines.append("")
        lines.append(data.aVec.map { formatValue($0) }.joined(separator: " "))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Distribution Parameter Extraction

    /// Parses "key1=val1,key2=val2" into a dictionary.
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

    /// Returns the rate (1 / mean) for the given distribution.
    private static func extractRate(distribution: QueueDistribution, parameters: String) -> Double {
        let p = parseParams(parameters)
        switch distribution {
        case .exponential:
            return p["rate"] ?? 1.0
        case .gamma:
            let shape = p["shape"] ?? 2.0
            let scale = p["scale"] ?? 1.0
            return 1.0 / (shape * scale)
        case .uniform:
            let lo = p["min"] ?? 0.5
            let hi = p["max"] ?? 1.5
            return 2.0 / (lo + hi)
        case .constant:
            let value = p["value"] ?? 1.0
            return value > 0 ? 1.0 / value : 0.0
        case .weibull:
            let shape = p["shape"] ?? 1.5
            let scale = p["scale"] ?? 1.0
            return 1.0 / (scale * tgamma(1.0 + 1.0 / shape))
        case .erlang:
            let k    = p["k"] ?? 2.0
            let rate = p["rate"] ?? 1.0
            return rate / k
        case .lognormal:
            let mu    = p["mu"] ?? 0.0
            let sigma = p["sigma"] ?? 0.25
            return 1.0 / exp(mu + sigma * sigma / 2.0)
        case .pareto:
            let alpha = p["shape"] ?? 2.5
            let xm    = p["scale"] ?? 1.0
            if alpha <= 1.0 { return 0.0 }
            return (alpha - 1.0) / (alpha * xm)
        case .poisson:
            // Poisson(λ) generates events at rate λ per unit time. The
            // inter-arrival distribution is Exp(λ) with mean 1/λ — but the
            // RATE (events/time) is λ, which is what `extractRate` returns.
            // (A prior bug here inverted this and produced ρ inflated by
            // 1/λ² in every multi-class analysis.)
            return p["lambda"] ?? 1.0
        }
    }

    /// Returns the squared coefficient of variation (variance / mean^2) for the given distribution.
    private static func extractSCV(distribution: QueueDistribution, parameters: String) -> Double {
        let p = parseParams(parameters)
        switch distribution {
        case .exponential:
            return 1.0
        case .gamma:
            let shape = p["shape"] ?? 2.0
            return 1.0 / shape
        case .uniform:
            let a = p["min"] ?? 0.5
            let b = p["max"] ?? 1.5
            let diff = b - a
            let sum  = a + b
            return (diff * diff) / (3.0 * sum * sum)
        case .constant:
            return 0.0
        case .weibull:
            let k  = p["shape"] ?? 1.5
            let g1 = tgamma(1.0 + 1.0 / k)
            let g2 = tgamma(1.0 + 2.0 / k)
            return (g2 - g1 * g1) / (g1 * g1)
        case .erlang:
            let k = p["k"] ?? 2.0
            return 1.0 / k
        case .lognormal:
            let sigma = p["sigma"] ?? 0.25
            return exp(sigma * sigma) - 1.0
        case .pareto:
            let alpha = p["shape"] ?? 2.5
            if alpha <= 2.0 { return .infinity }
            return 1.0 / (alpha * (alpha - 2.0))
        case .poisson:
            // A Poisson process has Exp(λ) inter-arrivals, which have
            // SCV = 1 regardless of λ. (Prior bug: returned 1/λ, which
            // happened to equal 1 for λ=1 and hid the issue.)
            return 1.0
        }
    }

    // MARK: - SRBM Parameter Computation

    /// Solves (I - P^T) * x = rhs for x (per-class throughput rates).
    /// M/M/1/K loss-queue blocking probability. K is total system capacity
    /// (= buffer slots + server slots). For ρ ≠ 1:
    ///   P(N=K) = ρ^K · (1 − ρ) / (1 − ρ^(K+1))
    /// For ρ = 1: 1/(K+1). Used by the loss-mode correction iteration as
    /// a per-station blocking estimate; class-blind FCFS so the same rate
    /// applies to every customer class arriving at station i.
    private static func mm1kBlockingProb(rho: Double, K: Int) -> Double {
        guard K >= 1, rho > 0 else { return 0 }
        if abs(rho - 1.0) < 1e-9 { return 1.0 / Double(K + 1) }
        let r = rho
        let kk = Double(K)
        // Guard against pow overflow at very large ρ (the iteration can
        // momentarily push offered ρ above 1 before convergence).
        let rPowK = pow(r, kk)
        let rPowK1 = rPowK * r
        let denom = 1.0 - rPowK1
        guard abs(denom) > 1e-15 else {
            return rPowK / (rPowK + 1.0)  // fallback for ρ ≈ 1
        }
        let p = rPowK * (1.0 - r) / denom
        return min(max(p, 0), 1)
    }

    /// Solves α = λ + P⊤α by Gaussian elimination with partial pivoting.
    ///
    /// `singularIndex` is the smallest variable the system does not
    /// determine, or nil when it determines all of them.  It matters
    /// because a *closed* routing cycle — every job leaving a set of
    /// stations comes straight back to it, which the Link tool has always
    /// allowed and one self-loop at p = 1.0 is enough to build — makes
    /// I − P⊤ singular, and the equation α = λ + α has no finite solution:
    /// the station is unbounded, not merely busy.  This function used to
    /// skip the division in that case and hand back the right-hand side,
    /// i.e. the *external* arrival rate, which every caller then read as a
    /// solved throughput: a network that cannot be stable was reported at
    /// ρ = 0.9 with an "exact" mean queue length beside it.  Reporting the
    /// index lets `computeData` name the station and refuse instead.
    ///
    /// The test is exactly where the old code skipped a division, so it
    /// calls nothing singular that used to be solved.
    private static func solveTrafficEquations(
        P: [[Double]], externalRates rhs_in: [Double], d: Int
    ) -> (alpha: [Double], singularIndex: Int?) {
        // Build A = I - P^T
        var A = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                A[i][j] = (i == j ? 1.0 : 0.0) - P[j][i]
            }
        }

        var rhs = rhs_in

        // Gaussian elimination with partial pivoting
        for col in 0..<d {
            var maxVal = abs(A[col][col])
            var maxRow = col
            for row in (col + 1)..<d {
                if abs(A[row][col]) > maxVal {
                    maxVal = abs(A[row][col])
                    maxRow = row
                }
            }
            if maxRow != col {
                A.swapAt(col, maxRow)
                rhs.swapAt(col, maxRow)
            }
            let pivot = A[col][col]
            if abs(pivot) < 1e-15 { continue }

            for row in (col + 1)..<d {
                let factor = A[row][col] / pivot
                for j in col..<d {
                    A[row][j] -= factor * A[col][j]
                }
                rhs[row] -= factor * rhs[col]
            }
        }

        // Back substitution
        var x = Array(repeating: 0.0, count: d)
        var singular: Int? = nil
        for i in stride(from: d - 1, through: 0, by: -1) {
            x[i] = rhs[i]
            for j in (i + 1)..<d {
                x[i] -= A[i][j] * x[j]
            }
            if abs(A[i][i]) > 1e-15 {
                x[i] /= A[i][i]
            } else {
                // Row swaps permute rows, never columns, so column i is
                // still variable α_i and the index names a station.
                singular = i
            }
        }
        return (x, singular)
    }

    /// Harrison-Reiman covariance decomposition extended for multi-class:
    ///   Σ = A + (I - P^T) diag(B) (I - P) + Σ_routing
    ///
    /// where A_{ii} = Σ_k λ^{ext}_{k,i} × SCV_a_k  (external arrival variance),
    ///       B_i  = c_i × SCV_s_eff_i               (service variance rate),
    ///       Σ_routing[i][j] = Σ_k c_k P[k][i] (δ_{ij} - P[k][j])  (routing split)
    private static func computeCovariance(
        P: [[Double]],
        lambdaExt: [[Double]],
        arrivalSCVs: [Double],
        capacity: [Double],
        effectiveServiceSCVs: [Double],
        d: Int
    ) -> [[Double]] {

        // M = I - P^T
        var M = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                M[i][j] = (i == j ? 1.0 : 0.0) - P[j][i]
            }
        }

        // B[k] = capacity[k] * effectiveServiceSCVs[k]
        var B = [Double](repeating: 0, count: d)
        for k in 0..<d { B[k] = capacity[k] * effectiveServiceSCVs[k] }

        // MB = M * diag(B)
        var MB = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                MB[i][j] = M[i][j] * B[j]
            }
        }

        // term1 = MB * M^T = (I-P^T)*diag(B)*(I-P)
        var term1 = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                var sum = 0.0
                for k in 0..<d { sum += MB[i][k] * M[j][k] }
                term1[i][j] = sum
            }
        }

        // Routing variability: Σ_k c_k P[k][i] (δ_{ij} - P[k][j])
        var routing = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for k in 0..<d {
            for i in 0..<d {
                if P[k][i] == 0 { continue }
                for j in 0..<d {
                    routing[i][j] += capacity[k] * P[k][i] * ((i == j ? 1.0 : 0.0) - P[k][j])
                }
            }
        }

        // A[i][i] = Σ_k lambdaExt[k][i] * arrivalSCVs[k]
        let K = arrivalSCVs.count
        var result = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for k in 0..<K {
                result[i][i] += lambdaExt[k][i] * arrivalSCVs[k]
            }
        }

        // Σ = A + term1 + routing
        for i in 0..<d {
            for j in 0..<d {
                result[i][j] += term1[i][j] + routing[i][j]
            }
        }

        return result
    }

    /// Builds the d × 2d reflection matrix in interleaved column ordering:
    ///   columns = [lower_0, upper_0, lower_1, upper_1, ..., lower_{d-1}, upper_{d-1}]
    ///
    /// **Finite-buffer (manufacturing blocking):**
    ///   Lower face x_k = 0 → e_k (station idle, keep X_k ≥ 0)
    ///   Upper face x_k = a_k → -e_k + Σ_i P_{ik} · e_i (blocked flow stays upstream)
    ///
    /// **Infinite-buffer (Harrison-Reiman orthant SRBM):**
    ///   Lower face x_k = 0 → (I − Pᵀ)_{:,k} = e_k − (P_{k,:})ᵀ
    ///     This is the classical Skorokhod reflection for open Jackson networks
    ///     (Dai 1990 §2.6; Harrison 1988 eq. 4.6). When station k finishes service,
    ///     a fraction P_{k,j} of that work is pushed into station j.
    ///   Upper face x_k = a_k → −e_k (wall truncation; finite buffer a_k is just
    ///     a numerical cap, mass at the wall should be ≈ 0).
    private static func computeReflectionMatrix(
        P: [[Double]],
        d: Int,
        infiniteBuffers: Bool
    ) -> [[Double]] {
        var R = Array(repeating: Array(repeating: 0.0, count: 2 * d), count: d)

        for k in 0..<d {
            let colLo = 2 * k
            let colHi = 2 * k + 1

            if infiniteBuffers {
                // Lower face: (I − Pᵀ)_{:,k}
                for i in 0..<d {
                    R[i][colLo] = (i == k ? 1.0 : 0.0) - P[k][i]
                }
                // Upper face: −e_k (wall truncation)
                R[k][colHi] = -1.0
            } else {
                // Lower face: e_k (identity)
                R[k][colLo] = 1.0
                // Upper face: −e_k + Σ_i P[i][k] · e_i (manufacturing blocking)
                for i in 0..<d {
                    R[i][colHi] = (i == k ? -1.0 : 0.0) + P[i][k]
                }
            }
        }

        return R
    }

    // MARK: - Formatting

    private static func formatValue(_ v: Double) -> String {
        String(format: "%10.5f", v)
    }

    // MARK: - Graph Helpers (shared logic with NetworkExporter)

    private static func stationIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    private static func sourceIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    /// Returns the per-server service rate for a given class at a station.
    /// Falls back to the station's default distribution if no per-class override exists.
    private static func serviceRateForClass(station: NetworkNode, classIdx: Int) -> Double {
        if let config = station.serviceDistributions[classIdx] {
            return extractRate(distribution: config.distribution,
                             parameters: config.distributionParameters)
        }
        return extractRate(distribution: station.distribution,
                         parameters: station.distributionParameters)
    }

    /// Returns the service SCV for a given class at a station.
    private static func serviceSCVForClass(station: NetworkNode, classIdx: Int) -> Double {
        if let config = station.serviceDistributions[classIdx] {
            return extractSCV(distribution: config.distribution,
                            parameters: config.distributionParameters)
        }
        return extractSCV(distribution: station.distribution,
                        parameters: station.distributionParameters)
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
        var visited = Set<UUID>()
        var queue = [startID]
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
