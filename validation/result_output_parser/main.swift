import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

private func requireClose(
    _ actual: Double?,
    _ expected: Double,
    tolerance: Double = 1e-12,
    _ message: String
) throws {
    guard let actual, abs(actual - expected) <= tolerance else {
        throw CheckFailure.failed("\(message): expected \(expected), got \(String(describing: actual))")
    }
}

private func requireCompleted(
    _ disposition: ParsedResultOutput.Disposition,
    _ message: String
) throws {
    guard case .completed = disposition else {
        throw CheckFailure.failed(message)
    }
}

private func requirePartial(
    _ disposition: ParsedResultOutput.Disposition,
    containing fragment: String,
    _ message: String
) throws {
    guard case .partial(let reason) = disposition,
          reason.localizedCaseInsensitiveContains(fragment) else {
        throw CheckFailure.failed(message)
    }
}

private func requireFailed(
    _ disposition: ParsedResultOutput.Disposition,
    containing fragment: String,
    _ message: String
) throws {
    guard case .failed(let reason) = disposition,
          reason.localizedCaseInsensitiveContains(fragment) else {
        throw CheckFailure.failed(message)
    }
}

private let stationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

private func run(_ method: ResultMethodMetadata) -> ResultRunRecord {
    let station = NetworkNode(id: stationID, kind: .station, name: "Checkout")
    let ignored = NetworkNode(id: UUID(), kind: .buffer, name: "Waiting Room")
    return ResultRunRecord(
        method: method,
        provenance: ResultProvenance(
            networkSnapshot: ResultNetworkSnapshot(nodes: [ignored, station]),
            exportStationIDs: [stationID]
        )
    )
}

private func measurement(
    _ metric: String,
    in parsed: ParsedResultOutput
) -> ResultMeasurement? {
    parsed.measurements.first { $0.metric == metric }
}

private func checkEmptyAndMalformedOutput() throws {
    for raw in [nil, ""] as [String?] {
        let parsed = ResultOutputParser.parse(raw, for: run(.openProductForm))
        try require(parsed.measurements.isEmpty, "empty output produced measurements")
        try require(parsed.evidence == nil, "empty output produced evidence")
        try requireFailed(
            parsed.disposition,
            containing: "produced no output",
            "empty output was not a hard failure"
        )
    }

    let malformed = ResultOutputParser.parse(
        "solver says everything is probably fine\n",
        for: run(.openProductForm)
    )
    try require(malformed.measurements.isEmpty, "malformed output produced measurements")
    try requireFailed(
        malformed.disposition,
        containing: "no recognized station performance measures",
        "malformed output was not a hard failure"
    )
    try require(
        malformed.warnings.contains { $0.contains("No recognized station measurements") },
        "malformed output did not retain an inspection warning"
    )
}

private func checkBARWithoutBounds() throws {
    let raw = """
    BAR moment relaxation
    Certified: no
    Relaxation: 12 moments, 4 equalities, 2 PSD blocks
    No compatible SDP backend is installed.
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.barMomentBounds))
    try require(parsed.measurements.isEmpty, "BAR backend-none output produced a bound")
    try requireFailed(
        parsed.disposition,
        containing: "produced no performance bounds",
        "BAR backend-none output was not a hard failure"
    )
    try require(
        parsed.evidence?.discretization == "12 moments, 4 equalities, 2 PSD blocks",
        "BAR relaxation evidence was lost"
    )
    try require(
        parsed.evidence?.convergenceNote == "Uncertified BAR relaxation result",
        "BAR certification evidence was lost"
    )
}

private func checkAdaptivePartial() throws {
    let raw = """
    Adaptive low-rank BAR analysis
    Rank: 8  converged: no
    E[Z_1] = 3.25    Var[Z_1] = 1.5
    Held-out relative BAR RMS = 0.002
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.adaptiveLowRankBAR))
    try requirePartial(
        parsed.disposition,
        containing: "maximum mixture rank",
        "adaptive nonconvergence was not partial"
    )
    try require(parsed.measurements.count == 2, "adaptive output did not retain both moments")
    try requireClose(measurement("Mean workload", in: parsed)?.estimate, 3.25,
                     "adaptive mean was parsed incorrectly")
    try requireClose(parsed.evidence?.residual, 0.002,
                     "adaptive validation residual was lost")
    try require(parsed.evidence?.discretization == "mixture rank 8",
                "adaptive rank evidence was lost")
}

private let regenerativeMetric = "QNET_NODE_METRIC_V1 node_id=s1 metric=mean_number class_id=- estimate=2.5 standard_error=0.1 ci_confidence=0.95 ci_low=2.3 ci_high=2.7 ci_half_width=0.2 effective_cycles=40"

private func checkRegenerativeOutcomes() throws {
    let partialRaw = """
    Complete empty-to-empty cycles: 40
    Precision target met: no
    \(regenerativeMetric)
    """
    let partial = ResultOutputParser.parse(partialRaw, for: run(.regenerativeMonteCarlo))
    try requirePartial(
        partial.disposition,
        containing: "precision target was not met",
        "regenerative safeguard stop was not partial"
    )
    try require(partial.measurements.count == 1, "regenerative estimate was discarded")
    try requireClose(partial.measurements.first?.uncertainty?.standardError, 0.1,
                     "regenerative standard error was lost")
    try require(partial.evidence?.discretization == "40 complete regenerative cycles",
                "regenerative cycle evidence was lost")
    try require(partial.evidence?.convergenceNote?.contains("no") == true,
                "regenerative precision evidence was lost")

    let zeroRaw = """
    Complete empty-to-empty cycles: 0
    Precision target met: no
    \(regenerativeMetric)
    """
    let zero = ResultOutputParser.parse(zeroRaw, for: run(.regenerativeMonteCarlo))
    try requireFailed(
        zero.disposition,
        containing: "No complete empty-to-empty regenerative cycle",
        "zero-cycle regenerative output was not a hard failure"
    )
}

private func checkMLMCOutcomes() throws {
    let cappedRaw = """
    L_1 = 2.5000 ± 0.4000 (95%)
    QNET_MLMC_STATUS_V1 adaptive=yes precision_met=no cap_hits=1
    """
    let capped = ResultOutputParser.parse(cappedRaw, for: run(.srbmMLMC))
    try requirePartial(
        capped.disposition,
        containing: "sample cap",
        "adaptive MLMC cap exhaustion was not partial"
    )
    try require(capped.measurements.count == 1, "capped MLMC estimate was discarded")
    try requireClose(
        capped.measurements.first?.uncertainty?.upperBound,
        2.9,
        "MLMC 95% half-width was not retained"
    )
    try require(
        capped.evidence?.convergenceNote?.contains("cap hits: 1") == true,
        "MLMC cap evidence was lost"
    )

    let metRaw = """
    L_1 = 2.5000 ± 0.4000 (95%)
    QNET_MLMC_STATUS_V1 adaptive=yes precision_met=yes cap_hits=0
    """
    let met = ResultOutputParser.parse(metRaw, for: run(.srbmMLMC))
    try requireCompleted(met.disposition, "precision-qualified MLMC output did not complete")
}

private func checkTruncatedPartial() throws {
    let raw = """
    Selected total cap: 40
    Node 1 Checkout: E[N]=8.5 utilization=0.9 departure=1.0
    successive refinement relative change = 0.05
    Heuristic converged: no
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.truncatedCTMC))
    try requirePartial(
        parsed.disposition,
        containing: "did not converge",
        "truncated-cap nonconvergence was not partial"
    )
    try require(parsed.measurements.count == 3, "truncated CTMC metrics were lost")
    try require(parsed.evidence?.discretization == "total-population cap 40",
                "truncation cap evidence was lost")
    try requireClose(parsed.evidence?.refinementDelta, 0.05,
                     "truncation refinement evidence was lost")
}

private func checkSBDFallbackPartial() throws {
    let raw = """
    rho_1 = 0.9
    Gamma_1 = 1.0
    sojourn_1 = 10.0
    QNET_SBD_STATUS_V1 fallback_used=yes
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.sbd))
    try requirePartial(
        parsed.disposition,
        containing: "fallback approximation",
        "SBD fallback was not partial"
    )
    try require(parsed.measurements.count == 3, "SBD fallback metrics were discarded")
    try require(parsed.measurements.allSatisfy { $0.stationID == stationID },
                "export-order station identity was not preserved")
}

private func checkComparisonOutcomes() throws {
    let partialRaw = """
    E[X_1]      —       2.5       2.7
    QNET_COMPARISON_STATUS_V1 partial=yes successful=qna failed=spectral
    """
    let partial = ResultOutputParser.parse(partialRaw, for: run(.comparison))
    try requirePartial(
        partial.disposition,
        containing: "one or more methods failed",
        "mixed comparison was not partial"
    )
    try require(partial.measurements.count == 1, "successful comparison value was lost")
    try requireClose(partial.measurements.first?.estimate, 2.5,
                     "comparison did not retain its first available value")

    let allFailed = ResultOutputParser.parse(
        "QNET_COMPARISON_STATUS_V1 partial=yes successful=0 failed=all\n",
        for: run(.comparison)
    )
    try requireFailed(
        allFailed.disposition,
        containing: "Every method in the comparison failed",
        "all-failed comparison was not a hard failure"
    )
}

/// Both spellings of a simulator's half-width must reach the same place.
/// `(h)` is what jackson_sim and fBNAsim print directly; `± h` is what the
/// comparison formatter prints for the column that reported one. Neither is a
/// standard error, and a row without either must not acquire an interval.
private func checkSimulationHalfWidths() throws {
    let legacyRaw = """
    rho_1 = 0.900000\t(0.012000)
    E[X_1] = 9.000000\t(0.400000)
    Gamma_1 = 1.000000
    """
    let legacy = ResultOutputParser.parse(legacyRaw, for: run(.monteCarlo))
    let rho = measurement("Utilization", in: legacy)
    try requireClose(rho?.uncertainty?.lowerBound, 0.888, tolerance: 1e-9,
                     "parenthesised half-width did not become an interval")
    try requireClose(rho?.uncertainty?.upperBound, 0.912, tolerance: 1e-9,
                     "parenthesised half-width did not become an interval")
    try requireClose(rho?.uncertainty?.confidenceLevel, 0.95,
                     "parenthesised half-width lost its confidence level")
    try require(rho?.uncertainty?.standardError == nil,
                "a half-width was recorded as a standard error")
    try requireClose(measurement("Mean reported occupancy", in: legacy)?.uncertainty?.lowerBound,
                     8.6, tolerance: 1e-9,
                     "E[X] parenthesised half-width was lost")
    try require(measurement("Throughput", in: legacy)?.uncertainty == nil,
                "a row with no reported half-width acquired an interval")

    // The comparison-table spelling, complete with the %-delta that
    // `normalized` strips before the row regexes ever see it.
    let plusMinusRaw = """
    rho_1      0.900 ± 0.012 (+0.1%)  0.899
    E[X_1]     9.000 ± 0.400 (+0.0%)  9.000
    """
    let plusMinus = ResultOutputParser.parse(plusMinusRaw, for: run(.monteCarlo))
    try requireClose(measurement("Utilization", in: plusMinus)?.estimate, 0.9,
                     "± row lost its estimate")
    try requireClose(measurement("Utilization", in: plusMinus)?.uncertainty?.upperBound,
                     0.912, tolerance: 1e-9,
                     "± half-width did not become an interval")
    try requireClose(measurement("Mean reported occupancy", in: plusMinus)?.uncertainty?.lowerBound,
                     8.6, tolerance: 1e-9,
                     "E[X] ± half-width was lost")
}

private func checkProductFormSuccess() throws {
    let raw = """
    Exact open BCMP product-form analysis
    Station s1 (fcfs): E[N]=9 throughput=1 utilization=0.9 margin=0.1
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.openProductForm))
    try requireCompleted(parsed.disposition, "valid product-form output did not complete")
    try require(parsed.measurements.count == 4, "product-form station row was incomplete")
    try requireClose(measurement("Mean number in system", in: parsed)?.estimate, 9,
                     "product-form mean was parsed incorrectly")
    try require(measurement("Mean number in system", in: parsed)?.stationName == "Checkout",
                "product-form station mapping was lost")
    try require(parsed.warnings.isEmpty, "valid product-form output produced warnings")
}

private func checkQBDSuccess() throws {
    let raw = """
    QNET_QBD_METRIC_V1 metric=mean_level estimate=1
    QNET_QBD_METRIC_V1 metric=probability_empty estimate=0.5
    QNET_QBD_METRIC_V1 metric=tail_probability level=5 estimate=0.03125
    QNET_QBD_EVIDENCE_V1 key=stability_classification value=positive_recurrent
    QNET_QBD_EVIDENCE_V1 key=iterations value=12
    QNET_QBD_EVIDENCE_V1 key=rate_equation_residual_inf value=1e-14
    QNET_QBD_EVIDENCE_V1 key=boundary_balance_residual_scaled value=-2e-13
    QNET_QBD_EVIDENCE_V1 key=normalization_residual value=3e-15
    """
    let parsed = ResultOutputParser.parse(raw, for: run(.qbd))
    try requireCompleted(parsed.disposition, "valid QBD output did not complete")
    try require(parsed.measurements.count == 3, "QBD metrics were not fully parsed")
    try requireClose(measurement("Mean number in system", in: parsed)?.estimate, 1,
                     "QBD mean level was parsed incorrectly")
    try requireClose(measurement("Tail probability P(N ≥ 5)", in: parsed)?.estimate, 0.03125,
                     "QBD tail probability was parsed incorrectly")
    try requireClose(parsed.evidence?.residual, 2e-13,
                     "QBD worst residual was not retained")
    try require(parsed.evidence?.discretization == "matrix-geometric rate solve, 12 iterations",
                "QBD iteration evidence was lost")
    try require(parsed.evidence?.convergenceNote == "QBD stability classification: positive recurrent",
                "QBD stability evidence was lost")
}

@main
struct ResultOutputParserCheck {
    static func main() throws {
        try checkEmptyAndMalformedOutput()
        try checkBARWithoutBounds()
        try checkAdaptivePartial()
        try checkRegenerativeOutcomes()
        try checkMLMCOutcomes()
        try checkTruncatedPartial()
        try checkSBDFallbackPartial()
        try checkComparisonOutcomes()
        try checkSimulationHalfWidths()
        try checkProductFormSuccess()
        try checkQBDSuccess()
        print("ResultOutputParser classification and semantic-row checks passed.")
    }
}
