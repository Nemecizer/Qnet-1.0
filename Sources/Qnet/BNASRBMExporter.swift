import Foundation

enum BNASRBMExportError: LocalizedError {
    case noStations
    case noSource
    case noSink
    case routingProbabilityExceedsOne(String, Double, Int)
    case sourceNotConnectedToStation1
    case infiniteMean(String)
    case infiniteVariance(String)
    case degenerateCovariance
    case stationOverloaded(String, Double)
    /// The traffic equations alpha = lambda + P-transpose alpha have no finite
    /// solution: some set of stations routes every job it receives back into
    /// itself, so its throughput is unbounded. Carries the station whose alpha
    /// is undetermined and the customer class whose routing does it. The
    /// wording matches `NetworkExportError.trafficEquationsSingular` and
    /// `QNAExportError.trafficEquationsSingular`: one defect, one sentence.
    case trafficEquationsSingular(String, Int)
    case encoding(String)

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
        case .degenerateCovariance:
            return "The covariance matrix is zero (all distributions are constant with deterministic routing). SRBM requires randomness."
        case .stationOverloaded(let name, let rho):
            return "\(name) has traffic intensity rho = \(String(format: "%.4f", rho)) >= 1. The service rate must exceed the arrival rate at every station for the SRBM to have a stationary distribution."
        case .trafficEquationsSingular(let name, let classIdx):
            return "Routing for \(CustomerClass.label(for: classIdx)) returns every job that reaches \(name) to \(name), so its throughput is unbounded and no arrival rate can be computed. Lower a routing probability on that cycle, or send part of it to a sink."
        case .encoding(let message):
            return "The SRBM parameters could not be encoded as JSON: \(message)"
        }
    }
}

@MainActor
enum BNASRBMExporter {

    // MARK: - Internal Data

    /// Computed SRBM parameters shared by all export formats.
    /// Uses BNA's orthant formulation with workload transformation.
    struct BNASRBMData {
        let d: Int
        let drift: [Double]          // workload drift vector
        let gamma: [[Double]]        // workload covariance matrix
        let R: [[Double]]            // d x d orthant reflection matrix (workload-transformed)
        let meanServiceTimes: [Double]  // tau[i] = 1 / (s_i * muEff_i)
        // Customer class data
        let K: Int                    // number of customer classes
        let totalThroughput: [Double] // alpha[i] per station
        let effectiveServiceRates: [Double] // muEff[i] per station
        let classExternalArrivals: [Double] // lambda_k per class
        let classThroughput: [[Double]]     // alphaPerClass[k][i]
        let classServiceRates: [[Double]]   // mu_ki[k][i]
    }

    // MARK: - Compute

    /// Computes SRBM data from the network model using the GJN workload formulation.
    ///
    /// Supports multiple customer classes (K sources = K classes) and multiple
    /// servers per station.  Uses station-aggregated SRBM with:
    ///   1. Per-class traffic equations: alpha_k = (I - (P^(k))^T)^{-1} lambda^{ext}_k
    ///   2. Throughput-weighted aggregation of routing and service rates
    ///   3. Queue-length covariance using total throughput rates
    ///   4. Orthant reflection: R = I - P_agg^T (d x d)
    ///   5. Workload transformation: Gamma[i][j] *= tau[i]*tau[j], R[i][j] *= tau[i]/tau[j]
    ///   6. Workload drift: theta[i] = sum_j R[i][j] * (rho[j] - 1)
    static func computeData(
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Result<BNASRBMData, BNASRBMExportError> {

        // -- Gather and validate network structure --
        let sources  = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        let sinks    = nodes.filter { $0.kind == .sink }
        let stations = nodes.filter { $0.kind == .station }
            .sorted { stationIndex($0.name) < stationIndex($1.name) }

        guard !stations.isEmpty else {
            return .failure(.noStations)
        }
        guard !sources.isEmpty else {
            return .failure(.noSource)
        }
        guard !sinks.isEmpty else {
            return .failure(.noSink)
        }

        // Customer-class count — includes derived classes introduced by
        // Phase-1 class-transition links (toCustomerClass on a link).
        let maxLinkClass = links.reduce(-1) { acc, link in
            max(acc, link.customerClass, link.toCustomerClass ?? -1)
        }
        let K = max(sources.count, maxLinkClass + 1)
        let d = stations.count

        // -- Verify first source reaches station 1 --
        let firstStation = stations[0]
        if !pathExists(from: sources[0].id, to: firstStation.id, nodes: nodes, links: links) {
            return .failure(.sourceNotConnectedToStation1)
        }

        // -- Build station index map --
        var stationIDToIndex = [UUID: Int]()
        for (i, s) in stations.enumerated() {
            stationIDToIndex[s.id] = i
        }

        // -- Per-class external arrival rate vectors --
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
        // Derived classes (no source, created by class transitions) keep
        // arrivalSCVs[k] = 1.0 default — they have no external arrival
        // process, so the SCV is nominal.

        // -- Per-class routing matrices --
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

        // -- Solve per-class traffic equations --
        // Default path (no class transitions): alpha_k = (I - (P^(k))^T)^{-1} lambda^{ext}_k
        // Class-transition path: build (K·d)×(K·d) expanded routing
        // matrix and solve once (matches SRBMExporter's logic).
        var alphaPerClass = Array(repeating: Array(repeating: 0.0, count: d), count: K)
        let hasClassTransitions = links.contains { link in
            guard let to = link.toCustomerClass else { return false }
            return to != link.customerClass
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
                return .failure(.trafficEquationsSingular(stations[bad % d].name, bad / d))
            }
            let alpha_ex = solved.alpha
            for k in 0..<K {
                for i in 0..<d { alphaPerClass[k][i] = alpha_ex[k * d + i] }
            }
        }

        // -- Total throughput per station --
        var alpha = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            for k in 0..<K {
                alpha[i] += alphaPerClass[k][i]
            }
        }

        // -- Server counts --
        var serverCounts = [Int]()
        for station in stations {
            serverCounts.append(station.numberOfServers)
        }

        // -- Effective service rate and SCV (mixture moment-matching) --
        // For FCFS class-blind service, each customer draws from the mixture
        // distribution.  We compute the first two moments of the mixture and
        // derive the effective rate and SCV:
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

        // -- Aggregated routing matrix --
        // P_ij = Sum_k (alpha_k_i / alpha_i) * P^(k)_{ij}
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

        // -- tau[i] = 1 / (s_i * muEff_i) = 1 / capacity_i --
        var tau = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            tau[i] = 1.0 / (Double(serverCounts[i]) * muEff[i])
        }

        // -- Check traffic intensities --
        // rho[j] = tau[j] * alpha[j] = alpha[j] / capacity[j] must be < 1
        for (j, station) in stations.enumerated() {
            let rho_j = tau[j] * alpha[j]
            if rho_j >= 1.0 {
                return .failure(.stationOverloaded(station.name, rho_j))
            }
        }

        // -- Queue-length covariance --
        var gamma = computeCovariance(
            P: P,
            lambdaExt: lambdaExt, arrivalSCVs: arrivalSCVs,
            totalThroughput: alpha, effectiveServiceSCVs: scvEff,
            d: d
        )

        // -- Orthant reflection matrix: R = I - P^T (d x d) --
        var R = computeReflectionMatrix(P: P, d: d)

        // -- Workload transformation (gjn.c lines 105-111) --
        // Gamma[i][j] *= tau[i] * tau[j]
        // R[i][j] *= tau[i] / tau[j]
        for i in 0..<d {
            for j in 0..<d {
                gamma[i][j] *= tau[i] * tau[j]
                R[i][j] *= tau[i] / tau[j]
            }
        }

        // -- Workload drift (gjn.c lines 129-135) --
        // rho[j] = tau[j] * alpha[j]
        // theta[i] = sum_j R[i][j] * (rho[j] - 1)
        var drift = [Double](repeating: 0, count: d)
        for i in 0..<d {
            for j in 0..<d {
                let rho_j = tau[j] * alpha[j]
                drift[i] += R[i][j] * (rho_j - 1)
            }
        }

        // -- Customer class data for per-class reporting --
        let lambda_k = (0..<K).map { k in lambdaExt[k].reduce(0, +) }
        let classServiceRates: [[Double]] = (0..<K).map { k in
            (0..<d).map { i in serviceRateForClass(station: stations[i], classIdx: k) }
        }

        return .success(BNASRBMData(
            d: d, drift: drift, gamma: gamma, R: R, meanServiceTimes: tau,
            K: K, totalThroughput: alpha, effectiveServiceRates: muEff,
            classExternalArrivals: lambda_k, classThroughput: alphaPerClass,
            classServiceRates: classServiceRates
        ))
    }

    // MARK: - Export Methods

    /// Generic SRBM format: d, theta, Gamma, R (d x d).
    static func export(
        nodes: [NetworkNode],
        links: [NetworkLink]
    ) -> Result<String, BNASRBMExportError> {
        let result = computeData(nodes: nodes, links: links)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return .success(formatStandard(data: data))
        }
    }

    /// Versioned JSON shared by the adaptive low-rank BAR approximation and
    /// the BAR moment-relaxation solver. Both consume the same orthant SRBM
    /// parameters as the established spectral, LP and MLMC implementations.
    /// Keeping the construction here prevents the GUI from maintaining a
    /// second, subtly different drift/covariance/reflection calculation.
    static func exportForAdaptiveBAR(
        nodes: [NetworkNode],
        links: [NetworkLink],
        name: String,
        maxRank: Int = 12
    ) -> Result<String, BNASRBMExportError> {
        switch computeData(nodes: nodes, links: links) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            let covariance = symmetrized(data.gamma)
            return encodeJSON([
                "schema_version": 1,
                "name": name,
                "drift": data.drift,
                "covariance": covariance,
                "reflection": data.R,
                "options": [
                    "max_rank": max(1, maxRank),
                    "training_points": max(64, 6 * data.d),
                    "validation_points": max(32, 6 * data.d),
                    "bar_tolerance": 2e-5,
                    "moment_tolerance": 2e-3,
                    "log_rate_span": 1.6,
                    "max_iterations": 6000
                ] as [String: Any]
            ])
        }
    }

    /// Versioned input for the polynomial BAR/Stieltjes moment relaxation.
    /// Unit first moments are the default targets because they line up with
    /// the workload coordinates displayed by the other SRBM methods.
    static func exportForBARBounds(
        nodes: [NetworkNode],
        links: [NetworkLink],
        name: String,
        order: Int = 2
    ) -> Result<String, BNASRBMExportError> {
        switch computeData(nodes: nodes, links: links) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            let covariance = symmetrized(data.gamma)
            let targets: [[String: Any]] = (0..<data.d).map { index in
                var moment = [Int](repeating: 0, count: data.d)
                moment[index] = 1
                return [
                    "name": "mean_workload_\(index + 1)",
                    "moment": moment
                ]
            }
            return encodeJSON([
                "schema_version": 1,
                "model_type": "orthant_srbm_bar_bounds",
                "name": name,
                "drift": data.drift,
                "covariance": covariance,
                "reflection": data.R,
                "relaxation": [
                    "order": max(1, order),
                    "max_variables": 100_000,
                    "max_psd_entries": 5_000_000,
                    "targets": targets
                ] as [String: Any]
            ])
        }
    }

    /// Export for BNAfm (finite element): d, theta, Gamma, R (d x d), meshSize.
    static func exportForFEM(
        nodes: [NetworkNode],
        links: [NetworkLink],
        meshSize: Int = 10
    ) -> Result<String, BNASRBMExportError> {
        let result = computeData(nodes: nodes, links: links)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            var text = formatStandard(data: data)
            text += "\(meshSize)\n"
            return .success(text)
        }
    }

    /// Export for BNAsm (spectral method / bnet): d, mu, Gamma, R, degree, [customer class data].
    static func exportForSpectral(
        nodes: [NetworkNode],
        links: [NetworkLink],
        degree: Int = 8
    ) -> Result<String, BNASRBMExportError> {
        let result = computeData(nodes: nodes, links: links)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            var lines = [String]()
            // Dimension
            lines.append("\(data.d)")
            lines.append("")
            // Drift vector mu
            lines.append(data.drift.map { String(format: "%10.5f", $0) }.joined(separator: " "))
            lines.append("")
            // Covariance matrix Gamma
            for row in data.gamma {
                lines.append(row.map { String(format: "%10.5f", $0) }.joined(separator: " "))
            }
            lines.append("")
            // Reflection matrix R
            for row in data.R {
                lines.append(row.map { String(format: "%10.5f", $0) }.joined(separator: " "))
            }
            lines.append("")
            // Polynomial degree
            lines.append("\(degree)")
            lines.append("")

            // Customer class data
            lines.append("customer_classes \(data.K)")
            lines.append("")

            // tau (workload-to-queue conversion)
            lines.append(data.meanServiceTimes.map { String(format: "%g", $0) }.joined(separator: " "))
            lines.append("")

            // Total throughput per station
            lines.append(data.totalThroughput.map { String(format: "%g", $0) }.joined(separator: " "))
            lines.append("")

            // Effective service rate per station
            lines.append(data.effectiveServiceRates.map { String(format: "%g", $0) }.joined(separator: " "))
            lines.append("")

            // lambda_k (external arrival rate per class)
            lines.append(data.classExternalArrivals.map { String(format: "%g", $0) }.joined(separator: " "))
            lines.append("")

            // alpha_ki (K rows x d cols)
            for k in 0..<data.K {
                lines.append(data.classThroughput[k].map { String(format: "%g", $0) }.joined(separator: " "))
            }
            lines.append("")

            // mu_ki (K rows x d cols)
            for k in 0..<data.K {
                lines.append(data.classServiceRates[k].map { String(format: "%g", $0) }.joined(separator: " "))
            }
            lines.append("")

            return .success(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Formatting

    /// Standard numeric format: d, theta, Gamma, R (d x d).
    private static func formatStandard(data: BNASRBMData) -> String {
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
        return lines.joined(separator: "\n")
    }

    private static func encodeJSON(
        _ document: [String: Any]
    ) -> Result<String, BNASRBMExportError> {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.encoding("UTF-8 conversion failed."))
            }
            return .success(text + "\n")
        } catch {
            // Every value above is a JSON primitive. Reaching this branch
            // therefore indicates a non-finite computed SRBM parameter,
            // which is unsafe to pass to either numerical method.
            return .failure(.encoding(error.localizedDescription))
        }
    }

    private static func symmetrized(_ matrix: [[Double]]) -> [[Double]] {
        matrix.indices.map { row in
            matrix.indices.map { column in
                0.5 * (matrix[row][column] + matrix[column][row])
            }
        }
    }

    /// Input format for BNAmc / rbm_mlmc (Blanchet-Chen-Glynn-Si 2021 MLMC).
    /// Format required by rbm_mlmc.c parse_input: one-line dimension, then drift
    /// vector, then d rows of Sigma, then d rows of R.  Blank lines and '#'
    /// comment lines are skipped by the parser, so we reuse formatStandard and
    /// prepend a short header describing the source network.
    static func formatBNAmcInput(data: BNASRBMData) -> String {
        var header = [String]()
        header.append("# BNET -> BNAmc SRBM input (workload scaling)")
        header.append("# Produced by BNASRBMExporter")
        header.append("# d = \(data.d)")
        header.append("# mu_eff per station (1/tau) = " +
                      data.meanServiceTimes.map { tau in
                          String(format: "%.4f", tau > 0 ? 1.0 / tau : 0.0)
                      }.joined(separator: ", "))
        header.append("# mean queue length L_i = mu_eff_i * E[Y_i]")
        header.append("")
        return header.joined(separator: "\n") + formatStandard(data: data)
    }

    /// Recommended grid size and basis degree for BNAlp / srbm_lp given the
    /// dimensionality `d` of the SRBM.  The LP that srbm_lp builds has
    /// roughly n^d interior variables, so naively keeping n = 100 explodes
    /// past d = 2 (at d = 3 you already have a million-variable LP that
    /// CPLEX won't finish in a reasonable time).  These defaults follow
    /// what the paper's Section 4 experiments actually use: they trade a
    /// small amount of approximation error for multiple orders of magnitude
    /// in solve time.
    ///
    /// Returned tuple: `(gridN, basisM)`.
    static func recommendedBNAlpGrid(forDimension d: Int) -> (Int, Int) {
        switch d {
        case ...1:  return (100, 6)
        case 2:     return (100, 6)   // classic 2D setting, ~0.5 s
        case 3:     return ( 25, 5)   // 15 625 cells, ~1–5 s
        case 4:     return ( 12, 4)   // 20 736 cells
        case 5:     return ( 10, 3)   // 100 000 cells
        case 6:     return (  6, 3)   // 46,656 interior points
        case 7:     return (  5, 3)   // 78,125 interior points
        case 8:     return (  4, 3)   // 65,536 interior points
        case 9...10:return (  3, 3)   // at most 59,049 interior points
        default:    return (  2, 2)   // tensor minimum; preflight still guards total columns
        }
    }

    /// Input format for BNAlp / srbm_lp (Saure-Glynn-Zeevi 2008 LP solver).
    ///
    /// The binary's parser (src/srbm_params.c in OLD/BNA/BNAlp) is keyword-
    /// driven and ignores blank lines plus `#` comments.  Required keys:
    ///   dimension <d>
    ///   grid_n    <n>
    ///   basis_m   <m>
    ///   grid_type exponential | dyadic | exprandom
    ///   drift           \n   mu_1 ... mu_d
    ///   covariance      \n   Sigma row 1 \n ... \n Sigma row d
    ///   reflection      \n   R row 1 \n ... \n R row d
    ///   grid_spacing    \n   spacing_1 ... spacing_d   (0 0 0 → auto)
    ///   tightness_bounds\n   K_1 ... K_{2d+1}
    ///
    /// Pass any overrides explicitly; leave as nil / empty for auto-scaled
    /// defaults.  `gridType` is the string the binary's parser recognises
    /// (`exponential`, `dyadic`, or `exprandom`).
    static func formatBNAlpInput(data: BNASRBMData,
                                  gridN: Int? = nil,
                                  basisM: Int? = nil,
                                  gridType: String = "exponential",
                                  smoothnessWeight: Double = 0.0,
                                  basisNormalize: Bool = false) -> String {
        let rec = recommendedBNAlpGrid(forDimension: data.d)
        let gridN = gridN ?? rec.0
        let basisM = basisM ?? rec.1
        let d = data.d
        var lines = [String]()

        // Header comment (skipped by parser; useful for the user)
        lines.append("# BNET -> BNAlp SRBM input (LP solver)")
        lines.append("# Produced by BNASRBMExporter")
        lines.append("# d = \(d)")
        lines.append("# mu_eff per station (1/tau) = " +
                     data.meanServiceTimes.map { tau in
                         String(format: "%.4f", tau > 0 ? 1.0 / tau : 0.0)
                     }.joined(separator: ", "))
        lines.append("# mean queue length L_i = mu_eff_i * E[Y_i]")
        lines.append("")

        // Algorithm hyperparameters
        lines.append("dimension  \(d)")
        lines.append("grid_n     \(gridN)")
        lines.append("basis_m    \(basisM)")
        lines.append("grid_type  \(gridType)")
        if smoothnessWeight > 0 {
            lines.append("smoothness_weight \(smoothnessWeight)")
        }
        if basisNormalize {
            lines.append("basis_normalize 1")
        }
        lines.append("")

        // Drift vector (one row, d values)
        lines.append("drift")
        lines.append("  " + data.drift.map { formatValue($0) }.joined(separator: "  "))
        lines.append("")

        // Covariance (d rows)
        lines.append("covariance")
        for row in data.gamma {
            lines.append("  " + row.map { formatValue($0) }.joined(separator: "  "))
        }
        lines.append("")

        // Reflection (d rows)
        lines.append("reflection")
        for row in data.R {
            lines.append("  " + row.map { formatValue($0) }.joined(separator: "  "))
        }
        lines.append("")

        // Grid spacing — leave as zeros so the binary auto-computes ρ/2.
        lines.append("grid_spacing")
        lines.append("  " + Array(repeating: "0.0", count: d).joined(separator: "  "))
        lines.append("")

        // Tightness bounds: 2d+1 values, loose enough to be effectively
        // disabled (they're sanity limits not active constraints here).
        lines.append("tightness_bounds")
        let tightness = Array(repeating: "100000", count: 2 * d + 1)
        lines.append("  " + tightness.joined(separator: " "))
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
            let lambda = p["lambda"] ?? 1.0
            return lambda
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
            return 1.0
        }
    }

    // MARK: - SRBM Parameter Computation

    /// Solves (I - P^T) * x = rhs for x (per-class throughput rates).
    ///
    /// `singularIndex` is the smallest variable the system does not determine,
    /// or nil when it determines all of them. A closed routing cycle — every
    /// job leaving a set of stations comes straight back to it, which one
    /// self-loop at p = 1.0 is enough to build — makes I - P^T singular, and
    /// alpha = lambda + alpha has no finite solution: the station is unbounded,
    /// not merely busy. This function used to skip the division in that case
    /// and hand back the right-hand side, i.e. the *external* arrival rate,
    /// which every caller then read as a solved throughput. Reporting the index
    /// lets `computeData` name the station and refuse instead, exactly as
    /// SRBMExporter already does.
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
                // Row swaps permute rows, never columns, so column i is still
                // variable alpha_i and the index names a station.
                singular = i
            }
        }
        return (x, singular)
    }

    /// Queue-length covariance (before workload transformation):
    ///   Gamma = A + (I-P^T)*diag(B)*(I-P) + Gamma_routing
    ///
    /// where A_{ii} = Sum_k lambdaExt[k][i] * arrivalSCVs[k]  (external arrival variance rate),
    ///       B_i  = Lambda_i * c^2_{s,i,eff}                   (service variance rate),
    ///       Gamma_routing[j][l] = Sum_i Lambda_i * (delta_{jl} * Pbar_{ij} - Pbar_{ij} * Pbar_{il})
    ///
    /// The (I-P^T)*diag(B)*(I-P) term correctly propagates service variability
    /// through the routing topology (cf. Chen & Yao, QNET/gjn.c).
    private static func computeCovariance(
        P: [[Double]],
        lambdaExt: [[Double]],
        arrivalSCVs: [Double],
        totalThroughput alpha: [Double],
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

        // B[k] = alpha[k] * effectiveServiceSCVs[k]
        var B = [Double](repeating: 0, count: d)
        for k in 0..<d { B[k] = alpha[k] * effectiveServiceSCVs[k] }

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

        // Routing variability: Sum_k alpha[k] * P[k][i] * (delta_{ij} - P[k][j])
        var routing = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for k in 0..<d {
            for i in 0..<d {
                if P[k][i] == 0 { continue }
                for j in 0..<d {
                    routing[i][j] += alpha[k] * P[k][i] * ((i == j ? 1.0 : 0.0) - P[k][j])
                }
            }
        }

        // A[i][i] = Sum_k lambdaExt[k][i] * arrivalSCVs[k]
        let K = arrivalSCVs.count
        var result = Array(repeating: Array(repeating: 0.0, count: d), count: d)
        for i in 0..<d {
            for k in 0..<K {
                result[i][i] += lambdaExt[k][i] * arrivalSCVs[k]
            }
        }

        // Gamma = A + term1 + routing
        for i in 0..<d {
            for j in 0..<d {
                result[i][j] += term1[i][j] + routing[i][j]
            }
        }

        return result
    }

    /// Builds the d x d orthant reflection matrix.
    ///   R[k][k] = 1      (station k is idle)
    ///   R[j][k] = -P[k][j]  (no departures flow downstream)
    private static func computeReflectionMatrix(P: [[Double]], d: Int) -> [[Double]] {
        var R = Array(repeating: Array(repeating: 0.0, count: d), count: d)

        for k in 0..<d {
            R[k][k] = 1.0
            for j in 0..<d {
                if P[k][j] > 0 {
                    R[j][k] -= P[k][j]
                }
            }
        }

        return R
    }

    // MARK: - Formatting

    private static func formatValue(_ v: Double) -> String {
        String(format: "%10.5f", v)
    }

    // MARK: - Graph Helpers

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
