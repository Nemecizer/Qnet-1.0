import Foundation

// MARK: - Solver-output parsing

struct ParsedResultOutput {
    enum Disposition {
        case completed
        case partial(String)
        case failed(String)
    }

    var measurements: [ResultMeasurement]
    var evidence: ResultNumericalEvidence?
    var warnings: [String]
    var disposition: Disposition
}
/// Converts the stable compact rows emitted by Qnet's existing runners into
/// typed measurements. This parser deliberately recognizes semantic row names
/// (`rho_i`, `Gamma_i`, `sojourn_i`, `E[X_i]`, …), never terminal column
/// positions. The original capture is retained beside these records for audit.
enum ResultOutputParser {
    private static let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
    private static let ansi = try! NSRegularExpression(
        pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#
    )
    private static let percentDelta = try! NSRegularExpression(
        pattern: #"\s*\([+-]?(?:\d+(?:\.\d*)?|\.\d+)%\)"#
    )
    /// The optional uncertainty a Monte Carlo row carries after its estimate.
    /// Two spellings reach this parser and they mean the same thing:
    ///   * `rho_1 = 0.900000\t(0.012300)` — what the two simulators print
    ///     directly. Despite the bare parentheses this is a HALF-WIDTH, not a
    ///     standard error: fBNAsim prints `t_crit(n)·SE` (1.96 above n = 30)
    ///     and jackson_sim prints `2·sqrt(var/n)`.
    ///   * `rho_1   0.900 ± 0.012` — what the comparison formatter prints for
    ///     a column that reported one (QnetGUIApp's `fmtv`).
    /// The parenthesised alternative is kept so raw solver output pasted into
    /// the shell still parses. Exactly one of the two groups can match, so
    /// callers read `groups[safe: 4] ?? groups[safe: 5]`.
    private static let uncertaintySuffix =
        #"(?:\s+(?:\(("# + number + #")\)|±\s*("# + number + #")))?"#
    private static let stationRow = try! NSRegularExpression(
        pattern: #"^\s*(rho|Gamma|sojourn)_([0-9]+)\s*(?:=\s*)?("# + number + #")"#
            + uncertaintySuffix,
        options: [.caseInsensitive]
    )
    private static let expectationRow = try! NSRegularExpression(
        pattern: #"^\s*E\[([XQY])_([0-9]+)\]\s*(?:=\s*)?("# + number + #")"#
            + uncertaintySuffix,
        options: [.caseInsensitive]
    )
    private static let comparisonExpectationRow = try! NSRegularExpression(
        pattern: #"^\s*E\[([XQY])_([0-9]+)\]\s+.*?("# + number + #")(?:\s|$)"#,
        options: [.caseInsensitive]
    )
    private static let convertedQueueRow = try! NSRegularExpression(
        pattern: #"^\s*L_([0-9]+)\s*=\s*("# + number + #")\s*(?:±\s*("# + number + #"))?"#,
        options: [.caseInsensitive]
    )
    private static let ctmcStationRow = try! NSRegularExpression(
        pattern: #"^\s*Station\s+s([0-9]+):\s+E\[N\]=("# + number
            + #")\s+utilization=("# + number + #")\s+P\(full\)=("# + number
            + #")\s+throughput=("# + number + #")\s+E\[T\]=("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let productFormStationRow = try! NSRegularExpression(
        pattern: #"^\s*Station\s+s([0-9]+)\s+\(fcfs\):\s+E\[N\]=("# + number
            + #")\s+throughput=("# + number + #")\s+utilization=("# + number
            + #")\s+margin=("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let decompositionStationRow = try! NSRegularExpression(
        pattern: #"^\s*[sS]([0-9]+)\s+[^:]*:\s+offered=("# + number
            + #")\s+throughput=("# + number + #")\s+P\(full\)=("# + number
            + #")\s+E\[N\]=("# + number + #")\s+E\[Q\]=("# + number
            + #")\s+util=("# + number + #")\s+W=("# + number
            + #")\s+T=("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let truncatedNodeRow = try! NSRegularExpression(
        pattern: #"^\s*Node\s+([0-9]+)\s+[^:]+:\s+E\[N\]=("# + number
            + #")\s+utilization=("# + number + #")\s+departure=("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let adaptiveBARRow = try! NSRegularExpression(
        pattern: #"^\s*E\[Z_([0-9]+)\]\s*=\s*("# + number
            + #")\s+Var\[Z_[0-9]+\]\s*=\s*("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let barExactRow = try! NSRegularExpression(
        pattern: #"^\s*mean_workload_([0-9]+):\s*\[("# + number
            + #"),\s*("# + number + #")\]\s*\(exact\)"#,
        options: [.caseInsensitive]
    )
    private static let barNumericalRow = try! NSRegularExpression(
        pattern: #"^\s*mean_workload_([0-9]+):\s*lower=("# + number
            + #")\s*\([^)]*\),\s*upper=("# + number + #")\s*\([^)]*\)"#,
        options: [.caseInsensitive]
    )
    private static let residualRow = try! NSRegularExpression(
        pattern: #"(?:residual|stationarity error|\|\|pi Q\|\|_1)\s*[:=]\s*("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let refinementRow = try! NSRegularExpression(
        pattern: #"successive refinement relative change\s*=\s*("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let capRow = try! NSRegularExpression(
        pattern: #"Selected total cap:\s*([0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let heuristicRow = try! NSRegularExpression(
        pattern: #"Heuristic converged:\s*(yes|no)"#,
        options: [.caseInsensitive]
    )
    private static let adaptiveResidualRow = try! NSRegularExpression(
        pattern: #"Held-out relative BAR RMS\s*=\s*("# + number + #")"#,
        options: [.caseInsensitive]
    )
    private static let adaptiveRankRow = try! NSRegularExpression(
        pattern: #"Rank:\s*([0-9]+)\s+converged:\s*(yes|no)"#,
        options: [.caseInsensitive]
    )
    private static let barCertifiedRow = try! NSRegularExpression(
        pattern: #"Certified:\s*(yes|no)"#,
        options: [.caseInsensitive]
    )
    private static let barRelaxationRow = try! NSRegularExpression(
        pattern: #"Relaxation:\s*([0-9]+)\s+moments,\s*([0-9]+)\s+equalities,\s*([0-9]+)\s+PSD blocks"#,
        options: [.caseInsensitive]
    )
    private static let regenerativeMetricRow = try! NSRegularExpression(
        pattern: #"^QNET_NODE_METRIC_V1 node_id=(\S+) metric=(\S+) class_id=(\S+) estimate=(\S+) standard_error=(\S+) ci_confidence=(\S+) ci_low=(\S+) ci_high=(\S+) ci_half_width=(\S+) effective_cycles=(\S+)$"#
    )
    private static let regenerativeCyclesRow = try! NSRegularExpression(
        pattern: #"Complete empty-to-empty cycles:\s*([0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let regenerativePrecisionRow = try! NSRegularExpression(
        pattern: #"Precision target met:\s*(yes|no)"#,
        options: [.caseInsensitive]
    )
    private static let mlmcStatusRow = try! NSRegularExpression(
        pattern: #"QNET_MLMC_STATUS_V1\s+adaptive=(yes|no)\s+precision_met=(yes|no|na)\s+cap_hits=([0-9]+)"#,
        options: [.caseInsensitive]
    )
    private static let qbdMetricRow = try! NSRegularExpression(
        pattern: #"^QNET_QBD_METRIC_V1 metric=(\S+)(?: level=([0-9]+))? estimate=("#
            + number + #")$"#
    )
    private static let qbdEvidenceRow = try! NSRegularExpression(
        pattern: #"^QNET_QBD_EVIDENCE_V1 key=(\S+) value=(\S+)$"#
    )

    static func parse(_ raw: String?, for run: ResultRunRecord) -> ParsedResultOutput {
        guard let raw, !raw.isEmpty else {
            return ParsedResultOutput(
                measurements: [], evidence: nil,
                warnings: ["The solver completed without capturable standard output."],
                disposition: .failed("The solver exited successfully but produced no output. No performance measures can be trusted from this run.")
            )
        }

        let clean = normalized(raw)
        var measurements: [ResultMeasurement] = []
        var seen = Set<String>()
        var qbdResiduals: [Double] = []
        var qbdIterations: String?
        var qbdStability: String?

        for line in clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let groups = captures(stationRow, in: line), groups.count >= 4,
               let index = Int(groups[2]), let estimate = Double(groups[3]) {
                let semantic = groups[1].lowercased()
                let (metric, unit): (String, String)
                switch semantic {
                case "rho": (metric, unit) = ("Utilization", "ratio")
                case "gamma": (metric, unit) = ("Throughput", "customers / time")
                default: (metric, unit) = ("Mean sojourn time", "time")
                }
                append(
                    measurement(index: index, metric: metric, estimate: estimate,
                                unit: unit,
                                halfWidthText: groups[safe: 4] ?? groups[safe: 5],
                                run: run),
                    key: "\(index)|\(metric)", to: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(expectationRow, in: line), groups.count >= 4,
               let index = Int(groups[2]), let estimate = Double(groups[3]) {
                let symbol = groups[1].uppercased()
                let metric: String
                let unit: String
                switch symbol {
                case "Y": metric = "Mean workload"; unit = "work"
                case "Q": metric = "Mean number in system"; unit = "customers"
                default: metric = "Mean reported occupancy"; unit = "customers"
                }
                append(
                    measurement(index: index, metric: metric, estimate: estimate,
                                unit: unit,
                                halfWidthText: groups[safe: 4] ?? groups[safe: 5],
                                run: run),
                    key: "\(index)|\(metric)", to: &measurements, seen: &seen
                )
                continue
            }

            // A comparison can legitimately have an unavailable first
            // column (rendered as an em dash) followed by successful method
            // columns. Preserve the first actual estimate instead of
            // treating the whole comparison as empty.
            if run.method.identifier == ResultMethodMetadata.comparison.identifier,
               let groups = captures(comparisonExpectationRow, in: line),
               groups.count >= 4,
               let index = Int(groups[2]), let estimate = Double(groups[3]) {
                let symbol = groups[1].uppercased()
                let metric = symbol == "Y" ? "Mean workload" : "Mean reported occupancy"
                let unit = symbol == "Y" ? "work" : "customers"
                append(
                    measurement(index: index, metric: metric, estimate: estimate,
                                unit: unit, halfWidthText: nil, run: run),
                    key: "\(index)|\(metric)", to: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(convertedQueueRow, in: line), groups.count >= 3,
               let index = Int(groups[1]), let estimate = Double(groups[2]) {
                var value = measurement(
                    index: index, metric: "Mean queue length", estimate: estimate,
                    unit: "customers", halfWidthText: nil, run: run
                )
                if let halfWidthText = groups[safe: 3], let halfWidth = Double(halfWidthText) {
                    value.uncertainty = ResultUncertainty(
                        lowerBound: estimate - halfWidth,
                        upperBound: estimate + halfWidth,
                        confidenceLevel: 0.95
                    )
                }
                append(value, key: "\(index)|Mean queue length",
                       to: &measurements, seen: &seen)
                continue
            }

            if let groups = captures(ctmcStationRow, in: line), groups.count >= 7,
               let index = Int(groups[1]) {
                let values: [(String, String, String)] = [
                    ("Mean number in system", "customers", groups[2]),
                    ("Server utilization", "ratio", groups[3]),
                    ("Full probability", "probability", groups[4]),
                    ("Throughput", "customers / time", groups[5]),
                    ("Mean sojourn time", "time", groups[6])
                ]
                appendStationValues(
                    values, index: index, run: run,
                    measurements: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(productFormStationRow, in: line),
               groups.count >= 6, let index = Int(groups[1]) {
                let values: [(String, String, String)] = [
                    ("Mean number in system", "customers", groups[2]),
                    ("Throughput", "customers / time", groups[3]),
                    ("Server utilization", "ratio", groups[4]),
                    ("Stability margin", "ratio", groups[5])
                ]
                appendStationValues(
                    values, index: index, run: run,
                    measurements: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(decompositionStationRow, in: line),
               groups.count >= 10, let index = Int(groups[1]) {
                let values: [(String, String, String)] = [
                    ("Offered arrival rate", "customers / time", groups[2]),
                    ("Throughput", "customers / time", groups[3]),
                    ("Full probability", "probability", groups[4]),
                    ("Mean number in system", "customers", groups[5]),
                    ("Mean queue length", "customers", groups[6]),
                    ("Server utilization", "ratio", groups[7]),
                    ("Mean waiting time", "time", groups[8]),
                    ("Mean sojourn time", "time", groups[9])
                ]
                appendStationValues(
                    values, index: index, run: run,
                    measurements: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(truncatedNodeRow, in: line),
               groups.count >= 5, let index = Int(groups[1]) {
                let values: [(String, String, String)] = [
                    ("Mean number in system", "customers", groups[2]),
                    ("Server utilization", "ratio", groups[3]),
                    ("External departure rate", "customers / time", groups[4])
                ]
                appendStationValues(
                    values, index: index, run: run,
                    measurements: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(adaptiveBARRow, in: line),
               groups.count >= 4, let index = Int(groups[1]) {
                let values: [(String, String, String)] = [
                    ("Mean workload", "work", groups[2]),
                    ("Workload variance", "work²", groups[3])
                ]
                appendStationValues(
                    values, index: index, run: run,
                    measurements: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(barExactRow, in: line),
               groups.count >= 4, let index = Int(groups[1]),
               let lower = Double(groups[2]), let upper = Double(groups[3]) {
                let station = station(atOneBased: index, in: run)
                let estimate = (lower + upper) / 2
                append(
                    ResultMeasurement(
                        stationID: station?.id,
                        stationName: station?.name ?? "S\(index)",
                        metric: "Mean workload",
                        estimate: estimate,
                        unit: "work",
                        uncertainty: ResultUncertainty(
                            lowerBound: lower, upperBound: upper
                        ),
                        note: "Certified exact SRBM point bound"
                    ),
                    key: "\(index)|Mean workload", to: &measurements, seen: &seen
                )
                continue
            }

            if let groups = captures(barNumericalRow, in: line),
               groups.count >= 4, let index = Int(groups[1]),
               let lower = Double(groups[2]), let upper = Double(groups[3]) {
                let station = station(atOneBased: index, in: run)
                for (metric, value) in [("Mean workload lower bound", lower),
                                        ("Mean workload upper bound", upper)] {
                    append(
                        ResultMeasurement(
                            stationID: station?.id,
                            stationName: station?.name ?? "S\(index)",
                            metric: metric, estimate: value, unit: "work",
                            note: "Floating SDP value; not a certified numerical bound"
                        ),
                        key: "\(index)|\(metric)", to: &measurements, seen: &seen
                    )
                }
                continue
            }

            if let groups = captures(regenerativeMetricRow, in: line),
               groups.count >= 11,
               let estimate = finiteNumber(groups[4]) {
                let nodeID = groups[1].removingPercentEncoding ?? groups[1]
                let metricID = groups[2]
                let classID = groups[3] == "-"
                    ? nil : (groups[3].removingPercentEncoding ?? groups[3])
                guard let index = numericIdentifier(nodeID, prefix: "s") else { continue }
                let station = station(atOneBased: index, in: run)
                let (metric, unit): (String, String)
                switch metricID {
                case "mean_number":
                    (metric, unit) = ("Mean number in system", "customers")
                case "mean_queue":
                    (metric, unit) = ("Mean queue length", "customers")
                case "utilization":
                    (metric, unit) = ("Server utilization", "ratio")
                case "service_completion_rate":
                    (metric, unit) = ("Service completion rate", "customers / time")
                case "mean_number_class":
                    (metric, unit) = ("Mean number in system", "customers")
                default:
                    continue
                }
                let classIndex = classID.flatMap { numericIdentifier($0, prefix: "c") }
                    .map { $0 - 1 }
                let standardError = finiteNumber(groups[5])
                let confidence = finiteNumber(groups[6])
                let low = finiteNumber(groups[7])
                let high = finiteNumber(groups[8])
                let effectiveCycles = finiteNumber(groups[10])
                let result = ResultMeasurement(
                    stationID: station?.id,
                    stationName: station?.name ?? nodeID,
                    customerClass: classIndex,
                    metric: metric,
                    estimate: estimate,
                    unit: unit,
                    uncertainty: ResultUncertainty(
                        standardError: standardError,
                        lowerBound: low,
                        upperBound: high,
                        confidenceLevel: confidence
                    ),
                    note: effectiveCycles.map {
                        "Effective complete cycles: \(DS.Number.format($0, significantDigits: 6))"
                    }
                )
                append(
                    result,
                    key: "\(index)|\(classIndex.map(String.init) ?? "all")|\(metric)",
                    to: &measurements, seen: &seen
                )
                continue
            }

            if run.method.identifier == ResultMethodMetadata.qbd.identifier,
               let groups = captures(qbdMetricRow, in: line),
               groups.count >= 4,
               let estimate = finiteNumber(groups[3]) {
                let metricID = groups[1]
                let level = Int(groups[2])
                let station = station(atOneBased: 1, in: run)
                let metric: String
                let unit: String
                let note: String?
                switch metricID {
                case "mean_level":
                    metric = "Mean number in system"
                    unit = "customers"
                    note = "QBD level equals customer count for the strict one-phase adapter"
                case "second_moment_level":
                    metric = "Second moment of number in system"
                    unit = "customers²"
                    note = nil
                case "variance_level":
                    metric = "Variance of number in system"
                    unit = "customers²"
                    note = nil
                case "standard_deviation_level":
                    metric = "Standard deviation of number in system"
                    unit = "customers"
                    note = nil
                case "probability_empty":
                    metric = "Empty-system probability"
                    unit = "probability"
                    note = nil
                case "tail_probability":
                    guard let level else { continue }
                    metric = "Tail probability P(N ≥ \(level))"
                    unit = "probability"
                    note = "Exact matrix-geometric tail probability"
                default:
                    continue
                }
                append(
                    ResultMeasurement(
                        stationID: station?.id,
                        stationName: station?.name ?? "S1",
                        metric: metric,
                        estimate: estimate,
                        unit: unit,
                        note: note
                    ),
                    key: "1|\(metric)", to: &measurements, seen: &seen
                )
                continue
            }

            if run.method.identifier == ResultMethodMetadata.qbd.identifier,
               let groups = captures(qbdEvidenceRow, in: line),
               groups.count >= 3 {
                let key = groups[1].removingPercentEncoding ?? groups[1]
                let value = groups[2].removingPercentEncoding ?? groups[2]
                switch key {
                case "rate_equation_residual_inf",
                     "boundary_balance_residual_scaled",
                     "normalization_residual":
                    if let residual = Double(value), residual.isFinite {
                        qbdResiduals.append(abs(residual))
                    }
                case "iterations":
                    qbdIterations = value
                case "stability_classification":
                    qbdStability = value.replacingOccurrences(of: "_", with: " ")
                default:
                    break
                }
            }
        }

        var evidence = ResultNumericalEvidence()
        if let groups = firstCaptures(residualRow, in: clean),
           let value = groups[safe: 1].flatMap(Double.init) {
            evidence.residual = value
        }
        if let groups = firstCaptures(refinementRow, in: clean),
           let value = groups[safe: 1].flatMap(Double.init) {
            evidence.refinementDelta = value
        }
        if let groups = firstCaptures(capRow, in: clean),
           let cap = groups[safe: 1] {
            evidence.discretization = "total-population cap \(cap)"
        }
        if let groups = firstCaptures(heuristicRow, in: clean),
           let state = groups[safe: 1] {
            evidence.convergenceNote = "Truncation criteria met: \(state.lowercased()) (heuristic)"
        }
        if let groups = firstCaptures(adaptiveResidualRow, in: clean),
           let value = groups[safe: 1].flatMap(Double.init) {
            evidence.residual = value
        }
        if let groups = firstCaptures(adaptiveRankRow, in: clean),
           let rank = groups[safe: 1], let converged = groups[safe: 2] {
            evidence.discretization = "mixture rank \(rank)"
            evidence.convergenceNote = "Adaptive BAR criteria met: \(converged.lowercased())"
        }
        if let groups = firstCaptures(barCertifiedRow, in: clean),
           let certified = groups[safe: 1] {
            evidence.convergenceNote = certified.lowercased() == "yes"
                ? "Certified exact SRBM special case"
                : "Uncertified BAR relaxation result"
        }
        if let groups = firstCaptures(barRelaxationRow, in: clean),
           groups.count >= 4 {
            evidence.discretization = "\(groups[1]) moments, \(groups[2]) equalities, \(groups[3]) PSD blocks"
        }
        if let groups = firstCaptures(regenerativeCyclesRow, in: clean),
           let cycles = groups[safe: 1] {
            evidence.discretization = "\(cycles) complete regenerative cycles"
        }
        if let groups = firstCaptures(regenerativePrecisionRow, in: clean),
           let met = groups[safe: 1] {
            evidence.convergenceNote = "Sequential fixed-width target met: \(met.lowercased())"
        }
        if run.method.identifier == ResultMethodMetadata.srbmMLMC.identifier,
           let groups = firstCaptures(mlmcStatusRow, in: clean),
           let adaptive = groups[safe: 1], let met = groups[safe: 2],
           let capHits = groups[safe: 3] {
            evidence.convergenceNote = adaptive.lowercased() == "yes"
                ? "Adaptive MLMC precision target met: \(met.lowercased()) (cap hits: \(capHits))"
                : "Fixed-sample MLMC plan"
        }
        if run.method.identifier == ResultMethodMetadata.qbd.identifier {
            evidence.residual = qbdResiduals.max()
            if let qbdIterations {
                evidence.discretization = "matrix-geometric rate solve, \(qbdIterations) iterations"
            }
            if let qbdStability {
                evidence.convergenceNote = "QBD stability classification: \(qbdStability)"
            }
        }

        var warnings: [String] = []
        var disposition: ParsedResultOutput.Disposition = .completed
        if measurements.isEmpty {
            if run.method.identifier == ResultMethodMetadata.barMomentBounds.identifier {
                warnings.append("No numerical bounds were produced. The conic relaxation was built, but a general model needs an installed SDP backend; inspect the retained relaxation summary.")
                disposition = .failed("The BAR relaxation produced no performance bounds. Install a supported CVXPY SDP backend or use an exact special case.")
            } else {
                warnings.append("No recognized station measurements were found; inspect the retained raw output.")
                disposition = .failed("The solver produced no recognized station performance measures.")
            }
        }
        if run.method.identifier == ResultMethodMetadata.comparison.identifier {
            warnings.append("The structured table records the first value in each comparison row; the retained raw output contains every method column.")
        }
        if run.method.identifier == ResultMethodMetadata.barMomentBounds.identifier,
           clean.localizedCaseInsensitiveContains("Certified: no") {
            warnings.append("General floating-point SDP values are feasibility-checked but are not certified numerical bounds.")
        }
        if run.method.identifier == ResultMethodMetadata.adaptiveLowRankBAR.identifier,
           clean.localizedCaseInsensitiveContains("converged: no") {
            warnings.append("The maximum mixture rank was reached before both adaptive criteria passed.")
            disposition = .partial("The maximum mixture rank was reached before the adaptive BAR validation criteria passed.")
        }
        if run.method.identifier == ResultMethodMetadata.regenerativeMonteCarlo.identifier,
           clean.localizedCaseInsensitiveContains("Precision target met: no") {
            warnings.append("The run stopped at a safeguard before every requested precision target was met.")
            disposition = .partial("The regenerative simulation returned estimates, but its requested precision target was not met.")
        }
        if run.method.identifier == ResultMethodMetadata.srbmMLMC.identifier,
           !measurements.isEmpty,
           clean.localizedCaseInsensitiveContains("QNET_MLMC_STATUS_V1"),
           clean.localizedCaseInsensitiveContains("adaptive=yes"),
           clean.localizedCaseInsensitiveContains("precision_met=no") {
            warnings.append("At least one adaptive MLMC replication reached its maximum-sample safeguard before meeting the requested standard-error target.")
            disposition = .partial("SRBM MLMC returned estimates, but at least one adaptive replication hit its sample cap before meeting the requested precision target.")
        }
        if run.method.identifier == ResultMethodMetadata.regenerativeMonteCarlo.identifier,
           let groups = firstCaptures(regenerativeCyclesRow, in: clean),
           groups[safe: 1] == "0" {
            disposition = .failed("No complete empty-to-empty regenerative cycle was observed, so the reported values are not steady-state regenerative estimates.")
        }
        if run.method.identifier == ResultMethodMetadata.truncatedCTMC.identifier,
           clean.localizedCaseInsensitiveContains("Heuristic converged: no") {
            warnings.append("The state-space cap was reached before the truncation checks passed.")
            disposition = .partial("The truncated CTMC returned estimates, but its boundary-mass and refinement checks did not converge.")
        }
        if run.method.identifier == ResultMethodMetadata.sbd.identifier,
           clean.localizedCaseInsensitiveContains("QNET_SBD_STATUS_V1"),
           clean.localizedCaseInsensitiveContains("fallback_used=yes") {
            warnings.append("SBD used a one-dimensional fallback because an internal spectral subproblem failed.")
            disposition = .partial("SBD completed with a fallback approximation after an internal spectral solve failed.")
        }
        if run.method.identifier == ResultMethodMetadata.comparison.identifier,
           clean.localizedCaseInsensitiveContains("QNET_COMPARISON_STATUS_V1"),
           clean.localizedCaseInsensitiveContains("partial=yes") {
            warnings.append("One or more comparison methods failed or were skipped; successful columns remain available.")
            disposition = measurements.isEmpty
                ? .failed("Every method in the comparison failed or was skipped.")
                : .partial("The comparison contains successful results, but one or more methods failed or were skipped.")
        }
        return ParsedResultOutput(
            measurements: measurements,
            evidence: evidence.isEmpty ? nil : evidence,
            warnings: warnings,
            disposition: disposition
        )
    }

    private static func measurement(
        index: Int,
        metric: String,
        estimate: Double,
        unit: String,
        halfWidthText: String?,
        run: ResultRunRecord
    ) -> ResultMeasurement {
        let station = station(atOneBased: index, in: run)
        // A half-width becomes the interval it describes, not a standard
        // error. It used to be stored as `standardError`, so the Results pane
        // labelled a 95 % interval "SE 0.0123" — the same number under the
        // wrong name, and the narrower claim of the two. Both producers are
        // 95 %: fBNAsim's Student-t half-width exactly, jackson_sim's 2σ to
        // within half a percent of coverage (2 rather than 1.96, so the stated
        // 95 % is the conservative reading of a slightly wider interval).
        let halfWidth = halfWidthText.flatMap(Double.init)
        return ResultMeasurement(
            stationID: station?.id,
            stationName: station?.name ?? "S\(index)",
            metric: metric,
            estimate: estimate,
            unit: unit,
            uncertainty: halfWidth.map {
                ResultUncertainty(
                    lowerBound: estimate - $0,
                    upperBound: estimate + $0,
                    confidenceLevel: 0.95
                )
            }
        )
    }

    private static func station(atOneBased index: Int, in run: ResultRunRecord) -> NetworkNode? {
        guard index > 0 else { return nil }
        let snapshot = run.provenance.networkSnapshot
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        if let ids = run.provenance.exportStationIDs,
           ids.indices.contains(index - 1) {
            return byID[ids[index - 1]]
        }
        return snapshot.nodes.filter { $0.kind == .station }.indices.contains(index - 1)
            ? snapshot.nodes.filter { $0.kind == .station }[index - 1]
            : nil
    }

    private static func append(
        _ value: ResultMeasurement,
        key: String,
        to output: inout [ResultMeasurement],
        seen: inout Set<String>
    ) {
        // A formatted table may be preceded by the raw compact rows. Keep the
        // first complete semantic value rather than duplicating it.
        guard seen.insert(key).inserted else { return }
        output.append(value)
    }

    private static func appendStationValues(
        _ values: [(metric: String, unit: String, text: String)],
        index: Int,
        run: ResultRunRecord,
        measurements: inout [ResultMeasurement],
        seen: inout Set<String>
    ) {
        for value in values {
            guard let estimate = Double(value.text) else { continue }
            append(
                measurement(
                    index: index, metric: value.metric,
                    estimate: estimate, unit: value.unit,
                    halfWidthText: nil, run: run
                ),
                key: "\(index)|\(value.metric)",
                to: &measurements,
                seen: &seen
            )
        }
    }

    private static func finiteNumber(_ text: String) -> Double? {
        guard text.uppercased() != "NA", let value = Double(text), value.isFinite else {
            return nil
        }
        return value
    }

    private static func numericIdentifier(_ text: String, prefix: Character) -> Int? {
        guard text.first?.lowercased() == String(prefix).lowercased(),
              let value = Int(text.dropFirst()), value > 0 else { return nil }
        return value
    }

    private static func normalized(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let withoutANSI = ansi.stringByReplacingMatches(
            in: raw, range: range, withTemplate: ""
        )
        let deltaRange = NSRange(withoutANSI.startIndex..<withoutANSI.endIndex, in: withoutANSI)
        return percentDelta.stringByReplacingMatches(
            in: withoutANSI, range: deltaRange, withTemplate: ""
        ).replacingOccurrences(of: "\r", with: "\n")
    }

    private static func firstCaptures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        guard let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) else { return nil }
        return strings(for: match, in: text)
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        firstCaptures(regex, in: text)
    }

    private static func strings(for match: NSTextCheckingResult, in text: String) -> [String] {
        (0..<match.numberOfRanges).map { position in
            let range = match.range(at: position)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) && !self[index].isEmpty ? self[index] : nil
    }
}
