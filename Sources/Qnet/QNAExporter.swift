import Foundation

enum QNAExportError: LocalizedError {
    case noStations
    case noSource
    case noSink
    case routingProbabilityExceedsOne(String, Double, Int)
    case sourceNotConnectedToStation1
    case infiniteMean(String)
    case infiniteVariance(String)
    case stationOverloaded(String, Double)
    /// The traffic equations alpha = lambda + P-transpose alpha have no finite
    /// solution: some set of stations routes every job it receives back into
    /// itself, so its throughput is unbounded. Carries the station whose alpha
    /// is undetermined and the customer class whose routing does it.
    ///
    /// The sentence is spelled out here rather than delegated to
    /// `NetworkExportError.trafficEquationsSingular`, whose wording it must
    /// match: `validation/rqna_integration_check.sh` compiles this file alone
    /// against `validation/rqna_exporter/stubs.swift`, which does not declare
    /// `NetworkExportError`, and validation/ is not editable from here.
    case trafficEquationsSingular(String, Int)

    var errorDescription: String? {
        switch self {
        case .noStations:
            return "The network has no stations."
        case .noSource:
            return "The network has no source node."
        case .noSink:
            return "The network has no sink node."
        case .routingProbabilityExceedsOne(let name, let sum, let classIdx):
            return "Routing probabilities from \(name) for \(CustomerClass.label(for: classIdx)) sum to \(String(format: "%.4f", sum)), which exceeds 1.0."
        case .sourceNotConnectedToStation1:
            return "The source must connect (possibly via a buffer) to station S1."
        case .infiniteMean(let name):
            return "\(name) has a distribution with infinite mean (e.g. Pareto with shape <= 1)."
        case .infiniteVariance(let name):
            return "\(name) has a distribution with infinite variance (e.g. Pareto with shape <= 2)."
        case .stationOverloaded(let name, let rho):
            return "\(name) has traffic intensity rho = \(String(format: "%.4f", rho)) >= 1. The arrival rate must not exceed the service capacity."
        case .trafficEquationsSingular(let name, let classIdx):
            return "Routing for \(CustomerClass.label(for: classIdx)) returns every job that reaches \(name) to \(name), so its throughput is unbounded and no arrival rate can be computed. Lower a routing probability on that cycle, or send part of it to a sink."
        }
    }
}

/// Exports a GUI network to the QNA standard input format.
///
/// Multi-class networks are aggregated to a single-class representation
/// using throughput-weighted averaging, the same approach as SRBMExporter.
@MainActor
enum QNAExporter {

    /// Exports the network as a QNA input file string.
    static func export(
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Result<String, QNAExportError> {

        // ── Gather and validate network structure ──
        let sources = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        let sinks = nodes.filter { $0.kind == .sink }
        let stations = nodes.filter { $0.kind == .station }
            .sorted { stationIndex($0.name) < stationIndex($1.name) }

        guard !stations.isEmpty else { return .failure(.noStations) }
        guard !sources.isEmpty  else { return .failure(.noSource) }
        guard !sinks.isEmpty    else { return .failure(.noSink) }

        // Customer-class count — includes derived classes introduced by
        // Phase-1 class-transition links (toCustomerClass on a link).
        let maxLinkClass = links.reduce(-1) { acc, link in
            max(acc, link.customerClass, link.toCustomerClass ?? -1)
        }
        let K = max(sources.count, maxLinkClass + 1)
        let d = stations.count

        // ── Verify first source reaches station 1 ──
        if !pathExists(from: sources[0].id, to: stations[0].id, nodes: nodes, links: links) {
            return .failure(.sourceNotConnectedToStation1)
        }

        // ── Build station index map ──
        var stationIDToIndex = [UUID: Int]()
        for (i, s) in stations.enumerated() {
            stationIDToIndex[s.id] = i
        }

        // ── Per-class external arrival rate and SCV vectors ──
        // lambdaExt[k][i]   = external arrival rate of class k at station i (sum over sources)
        // ca0_pc[k][i]      = SCV of the superposed thinned external streams of class k at i
        // arrivalSCVs[k]    = legacy class-aggregate SCV (kept for the basic per-class block)
        //
        // Per-(k,i) thinning + superposition (Whitt/QNA approximation):
        //   For each source of class k routing to station i with prob p:
        //     thinnedRate = rate · p
        //     thinnedSCV  = p · sourceSCV + (1 − p)        (renewal thinning)
        //   When multiple sources route to the same (k, i), the
        //   superposed SCV is the rate-weighted average of component
        //   thinned SCVs.
        var lambdaExt = Array(repeating: Array(repeating: 0.0, count: d), count: K)
        var arrivalSCVs = [Double](repeating: 1.0, count: K)
        var ca0_pc_weightedSum = Array(repeating: Array(repeating: 0.0, count: d), count: K)

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
                    let p = link.routingProbability
                    let thinnedRate = rate * p
                    let thinnedScv = p * scv + (1.0 - p)
                    lambdaExt[k][stationIdx] += thinnedRate
                    ca0_pc_weightedSum[k][stationIdx] += thinnedRate * thinnedScv
                }
            }
        }
        // Derived classes (no source) keep arrivalSCVs[k] = 1.0 nominal.

        var ca0_pc = Array(repeating: Array(repeating: 1.0, count: d), count: K)
        for k in 0..<K {
            for i in 0..<d {
                if lambdaExt[k][i] > 1e-15 {
                    ca0_pc[k][i] = ca0_pc_weightedSum[k][i] / lambdaExt[k][i]
                }
            }
        }

        // ── Per-class routing matrices ──
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
                    return .failure(.routingProbabilityExceedsOne(station.name, rowSum, classIdx))
                }
            }
            P_class.append(matrix)
        }

        // ── Solve per-class traffic equations ──
        // Class-transition path builds an expanded (K·d)×(K·d) routing
        // matrix when any link carries a class change; unchanged
        // per-class path otherwise.
        var alphaPerClass = Array(repeating: Array(repeating: 0.0, count: d), count: K)
        let hasClassTransitions = links.contains { link in
            guard let to = link.toCustomerClass else { return false }
            return to != link.customerClass
        }

        // Build the K·d × K·d expanded routing matrix unconditionally so
        // it can be exported below (BNAqna's per-class variability needs
        // it to wire upstream-class variance into downstream-class
        // arrivals — see Bitran-Tirupati 1988 / Whitt 1988).
        let N = K * d
        var P_ex = Array(repeating: [Double](repeating: 0, count: N), count: N)
        for (i, _) in stations.enumerated() {
            let outgoing = links.filter { $0.fromNodeID == stations[i].id }
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
        if !hasClassTransitions {
            for k in 0..<K {
                let solved = solveTrafficEquations(
                    P: P_class[k], externalRates: lambdaExt[k], d: d)
                if let bad = solved.singularIndex {
                    return .failure(.trafficEquationsSingular(stations[bad].name, k))
                }
                alphaPerClass[k] = solved.alpha
            }
        } else {
            var lambda_ex = [Double](repeating: 0, count: N)
            for k in 0..<K {
                for i in 0..<d { lambda_ex[k * d + i] = lambdaExt[k][i] }
            }
            let solved = solveTrafficEquations(
                P: P_ex, externalRates: lambda_ex, d: N)
            if let bad = solved.singularIndex {
                // The expanded system is indexed by (class, station) pairs.
                return .failure(.trafficEquationsSingular(stations[bad % d].name, bad / d))
            }
            let alpha_ex = solved.alpha
            for k in 0..<K {
                for i in 0..<d { alphaPerClass[k][i] = alpha_ex[k * d + i] }
            }
        }

        // ── Total throughput per station ──
        var alpha = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            for k in 0..<K {
                alpha[i] += alphaPerClass[k][i]
            }
        }

        // ── Effective service rate and SCV (mixture moment-matching) ──
        // For FCFS class-blind service, each customer draws from the mixture
        // distribution.  We compute the first two moments and derive muEff, scvEff:
        //   m1 = E[S_i]   = Sum_k w_k / mu_{i,k}
        //   m2 = E[S_i^2] = Sum_k w_k (1 + c²_{s,i,k}) / mu_{i,k}^2
        //   muEff_i  = 1 / m1
        //   c²_eff_i = (m2 - m1^2) / m1^2
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

        // ── Aggregated routing matrix ──
        var P_agg = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            if alpha[i] > 1e-15 {
                for j in 0..<d {
                    for k in 0..<K {
                        P_agg[i][j] += (alphaPerClass[k][i] / alpha[i]) * P_class[k][i][j]
                    }
                }
            }
        }

        // ── Aggregate external arrival rate per station ──
        var lambda0 = Array(repeating: 0.0, count: d)
        for j in 0..<d {
            for k in 0..<K {
                lambda0[j] += lambdaExt[k][j]
            }
        }

        // ── Aggregate external arrival SCV (weighted by arrival rates) ──
        var ca0_sq = Array(repeating: 1.0, count: d)
        for j in 0..<d {
            if lambda0[j] > 1e-15 {
                var weightedSum = 0.0
                for k in 0..<K {
                    weightedSum += lambdaExt[k][j] * arrivalSCVs[k]
                }
                ca0_sq[j] = weightedSum / lambda0[j]
            }
        }

        // ── Check traffic intensities ──
        for (j, station) in stations.enumerated() {
            let tau_j = 1.0 / muEff[j]
            let rho_j = alpha[j] * tau_j / Double(station.numberOfServers)
            if rho_j >= 1.0 {
                return .failure(.stationOverloaded(station.name, rho_j))
            }
        }

        // ── Format QNA input ──
        var lines = [String]()

        lines.append("# QNA input generated by BNAGUI")
        lines.append("# \(d) stations, \(K) customer class\(K > 1 ? "es" : "")")
        lines.append("")

        // n
        lines.append("\(d)")
        lines.append("")

        // servers
        lines.append("# Servers per node")
        lines.append(stations.map { String($0.numberOfServers) }.joined(separator: " "))
        lines.append("")

        // External arrival rates
        lines.append("# External arrival rates (lambda_0j)")
        lines.append(lambda0.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // External arrival SCVs
        lines.append("# External arrival SCVs (c^2_{a0,j})")
        lines.append(ca0_sq.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Mean service times
        lines.append("# Mean service times (tau_j = 1/mu_j)")
        let taus = (0..<d).map { 1.0 / muEff[$0] }
        lines.append(taus.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Service SCVs
        lines.append("# Service SCVs (c^2_{s,j})")
        lines.append(scvEff.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Routing matrix
        lines.append("# Routing matrix Q")
        for i in 0..<d {
            lines.append(P_agg[i].map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        // ── Customer class data (for per-class output) ──
        lines.append("customer_classes \(K)")
        lines.append("")

        // tau (workload-to-queue conversion factor: 1/(s_i * muEff_i))
        lines.append("# tau (workload conversion factor)")
        let tau_wl = (0..<d).map { 1.0 / (Double(stations[$0].numberOfServers) * muEff[$0]) }
        lines.append(tau_wl.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Total throughput per station
        lines.append("# Total throughput per station")
        lines.append(alpha.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Effective service rate per station
        lines.append("# Effective service rate per station")
        lines.append(muEff.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // External arrival rate per class
        lines.append("# External arrival rate per class (lambda_k)")
        let lambda_k = (0..<K).map { k in lambdaExt[k].reduce(0, +) }
        lines.append(lambda_k.map { String(format: "%g", $0) }.joined(separator: " "))
        lines.append("")

        // Per-class throughput (K rows x d cols)
        lines.append("# Per-class throughput alpha[k][i] (K rows x d cols)")
        for k in 0..<K {
            lines.append(alphaPerClass[k].map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        // Per-class service rate (K rows x d cols)
        lines.append("# Per-class service rate mu[k][i] (K rows x d cols)")
        for k in 0..<K {
            let row = (0..<d).map { i in serviceRateForClass(station: stations[i], classIdx: k) }
            lines.append(row.map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        // ── Bitran-Tirupati 1988 / Whitt 1988 per-class variability data ──
        // BNAqna's per-class variability solver needs (a) per-class
        // service SCVs (the existing service-SCV column is the FCFS
        // mixture variance, not the per-class), (b) per-class external
        // arrival rates per station (not just per class), and (c) the
        // K·d × K·d expanded routing matrix that captures class
        // relabels on links. Without (c) the per-class fixed-point
        // can't propagate upstream-class variance to downstream-class
        // arrivals, which is the documented root cause of the 20-25%
        // sojourn-estimate gap on Lu-Kumar / Kumar-Seidman networks.

        lines.append("# Per-class service SCV cs[k][i] (K rows x d cols)")
        for k in 0..<K {
            let row = (0..<d).map { i in serviceSCVForClass(station: stations[i], classIdx: k) }
            lines.append(row.map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        lines.append("# Per-class external arrival rate at station lambda_ext[k][i] (K rows x d cols)")
        for k in 0..<K {
            lines.append(lambdaExt[k].map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        lines.append("# Per-(class, station) routing P_ex[k*d+i][k'*d+j] ((K*d) x (K*d))")
        for row in 0..<N {
            lines.append(P_ex[row].map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        // Per-(class, station) external arrival SCV — appended AFTER P_ex
        // so older bna_rqna parsers (which stopped at P_ex) ignore it
        // gracefully. New parsers read it as an optional trailing block;
        // when absent the per-class solves default ca0_pc[k][i] to 1
        // (Poisson). With this block, RQNA's per-class limiting and
        // per-timescale solves use the actual external variability.
        lines.append("# Per-class external SCV ca0_pc[k][i] (K rows x d cols)")
        for k in 0..<K {
            lines.append(ca0_pc[k].map { String(format: "%g", $0) }.joined(separator: " "))
        }
        lines.append("")

        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - Traffic Equation Solver

    /// Solves alpha = lambda + P-transpose alpha by Gaussian elimination with
    /// partial pivoting.
    ///
    /// `singularIndex` is the smallest variable the system does not determine,
    /// or nil when it determines all of them. A closed routing cycle — every
    /// job leaving a set of stations comes straight back to it, which one
    /// self-loop at p = 1.0 is enough to build — makes I - P-transpose
    /// singular, and alpha = lambda + alpha has no finite solution. This
    /// function used to skip the division and hand back the right-hand side,
    /// i.e. the *external* arrival rate, which the caller wrote into the .qna
    /// file as a solved throughput; `bna_qna` then printed rho, E[W], E[N],
    /// E[T] and P(W>0) as `nan` for every node while the flag bar was already
    /// refusing the same document with a precise sentence. Reporting the index
    /// lets the caller name the station and refuse instead.
    ///
    /// The test is exactly where the old code skipped a division, so it calls
    /// nothing singular that used to be solved. This mirrors the identical
    /// function in SRBMExporter.
    private static func solveTrafficEquations(
        P: [[Double]], externalRates rhs_in: [Double], d: Int
    ) -> (alpha: [Double], singularIndex: Int?) {
        var A = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                A[i][j] = (i == j ? 1.0 : 0.0) - P[j][i]
            }
        }
        var rhs = rhs_in

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
                // Row swaps permute rows, never columns, so column i is still
                // variable alpha_i and the index names a station.
                singular = i
            }
        }
        return (x, singular)
    }

    // MARK: - Distribution Parameter Extraction

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
            let lambda = p["lambda"] ?? 1.0
            return lambda
        }
    }

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
            return 1.0
        }
    }

    // MARK: - Service Rate/SCV Per Class

    private static func serviceRateForClass(station: NetworkNode, classIdx: Int) -> Double {
        if let config = station.serviceDistributions[classIdx] {
            return extractRate(distribution: config.distribution,
                             parameters: config.distributionParameters)
        }
        return extractRate(distribution: station.distribution,
                         parameters: station.distributionParameters)
    }

    private static func serviceSCVForClass(station: NetworkNode, classIdx: Int) -> Double {
        if let config = station.serviceDistributions[classIdx] {
            return extractSCV(distribution: config.distribution,
                            parameters: config.distributionParameters)
        }
        return extractSCV(distribution: station.distribution,
                        parameters: station.distributionParameters)
    }

    // MARK: - Graph Helpers

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
                if let idx = resolveTargetStation(
                    from: link.toNodeID, nodes: nodes, links: links,
                    stationIDToIndex: stationIDToIndex
                ) {
                    return idx
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
