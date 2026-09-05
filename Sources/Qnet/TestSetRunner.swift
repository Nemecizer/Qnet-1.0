import Foundation
import SwiftUI

/// Test-set runner — generates N random networks per the user's
/// parameters, runs all infinite- or finite-regime algorithms on each,
/// and reports the per-algorithm mean absolute % error vs the simulation
/// reference, averaged over the test set. The orchestration uses
/// Foundation's `Process` API so each binary runs silently with stdout
/// captured to memory (no Interactive Shell noise per test case).

// MARK: - Parameter sheets (SwiftUI)

// Both Test-menu sheets share the DSSheet chrome (44-pt glyph header,
// grouped Form, footer with the first blocking problem and Cancel / Run)
// used by the inspectors and the export sheet, and the DS field
// components — `DSRangeFields` for every min … max input, `DSNumericField`
// for counts — in `.bare` layout (the `LabeledContent` carries the label,
// the footer reports the first blocking problem). Only presentation
// changed: the values handed to `onRun` and everything downstream in
// TestSetRunner are untouched.

/// "min … max" pair of integer fields for one grouped-Form row.
private struct IntRangeFields: View {
    @Binding var lower: Int
    @Binding var upper: Int
    let range: ClosedRange<Int>
    let label: String

    var body: some View {
        DSRangeFields(label: label, lower: $lower, upper: $upper, range: range, help: label)
            .dsRowLayout(.bare)
    }
}

/// "min … max" pair of decimal fields (two fraction digits) for a ρ range.
private struct DoubleRangeFields: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        DSRangeFields(label: label, lower: $lower, upper: $upper, range: range,
                      stepper: 0.05, help: label)
            .dsRowLayout(.bare)
    }
}

/// Integer field with a stepper ("Test cases").
private struct CountField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    var body: some View {
        DSNumericField(label: label, value: $value, range: range, stepper: 1, commit: .onEdit,
                       help: label, width: DS.Layout.compactFieldWidth, accessibilityLabel: label)
            .dsRowLayout(.bare)
    }
}

/// Topology menu shared by both sheets (same names as Generate Random
/// Network so the three dialogs agree).
private struct TopologyPicker: View {
    @Binding var topology: RandomNetworkGenerator.Topology

    var body: some View {
        Picker("Topology", selection: $topology) {
            Text("Feed-forward").tag(RandomNetworkGenerator.Topology.feedForward)
            Text("Jackson feedback (light)").tag(RandomNetworkGenerator.Topology.jacksonFeedback)
            Text("General P-matrix (full feedback)").tag(RandomNetworkGenerator.Topology.generalPMatrix)
            Text("Re-entrant feedback (class-change)").tag(RandomNetworkGenerator.Topology.reentrantFeedback)
        }
        .pickerStyle(.menu)
        .help("Routing structure of every generated network")
    }
}

struct TestSetParameterSheet: View {
    @Binding var params: TestSetParameters
    let infinite: Bool
    let onCancel: () -> Void
    let onRun: (TestSetParameters) -> Void

    @State private var stationsLower = 3
    @State private var stationsUpper = 6
    @State private var classesLower = 1
    @State private var classesUpper = 3
    @State private var rhoLower = 0.5
    @State private var rhoUpper = 0.85
    @State private var numCases = 20
    @State private var topology: RandomNetworkGenerator.Topology = .feedForward
    @State private var fixedSeed = false
    @State private var seed = 12_345

    private static let stationRange = 1...32
    private static let classRange = 1...16
    private static let caseRange = 1...1000
    /// ρ must lie strictly inside (0, 1); the fields accept two decimals.
    private static let rhoRange = 0.01...0.99

    private var regime: String { infinite ? "infinite" : "finite" }

    /// First blocking problem, in row order; nil when the sweep can run.
    private var problem: String? {
        if !Self.stationRange.contains(stationsLower) || !Self.stationRange.contains(stationsUpper) {
            return "Stations must be between 1 and 32."
        }
        if stationsLower > stationsUpper { return "Minimum stations must not exceed the maximum." }
        if !Self.classRange.contains(classesLower) || !Self.classRange.contains(classesUpper) {
            return "Customer classes must be between 1 and 16."
        }
        if classesLower > classesUpper { return "Minimum classes must not exceed the maximum." }
        if !(rhoLower > 0 && rhoUpper < 1) { return "ρ must lie strictly between 0 and 1." }
        if rhoLower > rhoUpper { return "Minimum ρ must not exceed the maximum." }
        if !Self.caseRange.contains(numCases) { return "Test cases must be between 1 and 1000." }
        return nil
    }

    private var sweepSummary: String {
        let n = numCases
        return "\(n) random \(regime)-buffer network\(n == 1 ? "" : "s"), each solved by every \(regime)-buffer method and scored against the simulator."
    }

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Run \(infinite ? "Infinite" : "Finite") Test Set",
                subtitle: "Generates random \(regime)-buffer networks, runs every \(regime)-regime method on each and reports the per-method accuracy averaged over the sweep."
            ) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.testSet,
                                   tint: DS.Color.infoText)
            }
        } content: {
            Form {
                Section {
                    LabeledContent("Stations") {
                        IntRangeFields(lower: $stationsLower, upper: $stationsUpper,
                                       range: Self.stationRange, label: "Stations")
                    }
                    .help("Number of service stations d drawn for each network (1–32)")

                    LabeledContent("Customer classes") {
                        IntRangeFields(lower: $classesLower, upper: $classesUpper,
                                       range: Self.classRange, label: "Customer classes")
                    }
                    .help("Number of customer classes c drawn for each network (1–16)")

                    LabeledContent("Target ρ") {
                        DoubleRangeFields(lower: $rhoLower, upper: $rhoUpper,
                                          range: Self.rhoRange, label: "Target utilisation")
                    }
                    .help(DS.Glossary.rho)

                    TopologyPicker(topology: $topology)
                } header: {
                    Text("Networks")
                } footer: {
                    Text("Each case draws d, c and ρ uniformly from these ranges.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    LabeledContent("Test cases") {
                        CountField(value: $numCases, range: Self.caseRange, label: "Test cases")
                    }
                    .help("Number of random networks in the sweep (1–1000)")

                    Toggle("Fixed random seed", isOn: $fixedSeed)
                        .help("Use the same generated networks when these parameters are run again")

                    if fixedSeed {
                        LabeledContent("Seed") {
                            DSNumericField(
                                label: "Seed",
                                value: $seed,
                                range: 0...Int(Int32.max),
                                stepper: 1,
                                commit: .onEdit,
                                help: "Base seed used to generate the complete test set",
                                width: DS.Layout.fieldWidth,
                                accessibilityLabel: "Test-set seed"
                            )
                            .dsRowLayout(.bare)
                        }
                    }
                } header: {
                    Text("Sweep")
                } footer: {
                    Text(sweepSummary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } footer: {
            DSSheetFooter(
                problem: problem,
                helpTopic: .testSets,
                confirmTitle: "Run",
                canConfirm: problem == nil,
                cancelHelp: "Close without running (Esc)",
                confirmHelp: "Generate the networks and start the sweep (Return)",
                blockedHelp: "Fix the highlighted values to run the sweep",
                onCancel: onCancel,
                onConfirm: runTapped
            )
        }
        .dsSheetFrame(.regular)
        .onAppear {
            stationsLower = params.stationsLower
            stationsUpper = params.stationsUpper
            classesLower = params.classesLower
            classesUpper = params.classesUpper
            rhoLower = params.rhoLower
            rhoUpper = params.rhoUpper
            numCases = params.numTestCases
            topology = params.topology
            fixedSeed = params.seed != nil
            seed = Int(params.seed ?? 12_345)
        }
    }

    private func runTapped() {
        guard problem == nil else { return }
        var p = params
        p.stationsLower = stationsLower; p.stationsUpper = stationsUpper
        p.classesLower = classesLower;   p.classesUpper = classesUpper
        p.rhoLower = rhoLower;           p.rhoUpper = rhoUpper
        p.numTestCases = numCases
        p.topology = topology
        p.seed = fixedSeed ? UInt64(seed) : nil
        onRun(p)
    }
}

// MARK: - Parameters

struct TestSetParameters {
    var stationsLower: Int = 3
    var stationsUpper: Int = 6
    var classesLower: Int = 1
    var classesUpper: Int = 3
    var rhoLower: Double = 0.5
    var rhoUpper: Double = 0.85
    var numTestCases: Int = 20
    var topology: RandomNetworkGenerator.Topology = .feedForward
    var seed: UInt64? = nil
}

// MARK: - Per-algo output

/// Parsed output of one algorithm on one test case (the `-c` format).
struct TestSetAlgoOutput {
    var rho: [Int: Double] = [:]
    var gamma: [Int: Double] = [:]
    var sojourn: [Int: Double] = [:]
    var meanInSystem: [Int: Double] = [:]
    var elapsed: TimeInterval = 0
}

// MARK: - Output parser

enum TestSetParser {
    /// Parses the compact `-c` output emitted by every algorithm:
    ///   rho_<k> = <value>
    ///   Gamma_<k> = <value>
    ///   sojourn_<k> = <value>
    ///   E[<var>_<k>] = <value>      (var = "Q" infinite, "X" finite)
    /// Tolerates header / blank lines around the blocks.
    static func parse(_ text: String, varName: String) -> TestSetAlgoOutput {
        var out = TestSetAlgoOutput()
        let prefixEQ = "E[\(varName)_"
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let rhs = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let value = Double(rhs) else { continue }
            // rho_k, Gamma_k, sojourn_k, E[<var>_k]
            if lhs.hasPrefix("rho_"),
               let k = Int(lhs.dropFirst("rho_".count)) {
                out.rho[k] = value
            } else if lhs.hasPrefix("Gamma_"),
                      let k = Int(lhs.dropFirst("Gamma_".count)) {
                out.gamma[k] = value
            } else if lhs.hasPrefix("sojourn_"),
                      let k = Int(lhs.dropFirst("sojourn_".count)) {
                out.sojourn[k] = value
            } else if lhs.hasPrefix(prefixEQ), lhs.hasSuffix("]"),
                      let k = Int(lhs.dropFirst(prefixEQ.count).dropLast()) {
                out.meanInSystem[k] = value
            }
        }
        return out
    }
}

// MARK: - Process invocation

enum TestSetProcess {
    /// Runs `binary` with `args`, captures stdout to memory, discards
    /// stderr. Returns nil on launch failure or non-zero exit.
    /// Synchronous — caller should hop off the main thread.
    static func runCapturing(_ binary: URL, args: [String], timeout: TimeInterval = 600) -> String? {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        do { try proc.run() } catch { return nil }

        // Drain stderr off-thread to avoid deadlock when the binary fills
        // the pipe buffer; stdout is read to EOF on this (already
        // off-main) thread, so no captured var is mutated concurrently.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()

        proc.waitUntilExit()
        _ = group.wait(timeout: .now() + timeout)
        if proc.terminationStatus != 0 { return nil }
        return String(data: outData, encoding: .utf8)
    }
}

// MARK: - Per-test-case run + aggregate stats

/// One test case's outcome: the random network parameters, the
/// per-algorithm parsed outputs, and which algorithm is the reference
/// (typically "Sim" / "MC").
struct TestSetCaseResult {
    let caseIndex: Int
    let stations: Int
    let classes: Int
    let targetRho: Double
    var algoOutputs: [String: TestSetAlgoOutput] = [:]
    let referenceKey: String
}

/// Mean absolute % error of `algo` E[N] vs `ref` E[N], averaged over
/// stations whose reference value is meaningfully large (avoid
/// blowing up on stations with E[N] ≈ 0). Returns nil if there are no
/// usable stations.
func meanAbsPctError(algo: TestSetAlgoOutput, ref: TestSetAlgoOutput) -> Double? {
    var errs: [Double] = []
    for (k, refVal) in ref.meanInSystem where abs(refVal) > 1e-6 {
        if let v = algo.meanInSystem[k] {
            errs.append(abs(v - refVal) / abs(refVal) * 100.0)
        }
    }
    return errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count)
}

/// Aggregate report block — per-algorithm summary statistics over all
/// test cases. `referenceKey` names the column treated as truth.
func formatAggregateReport(
    cases: [TestSetCaseResult],
    params: TestSetParameters,
    infinite: Bool,
    referenceKey: String,
    algoOrder: [String]
) -> String {
    var lines: [String] = []
    let modeLabel = infinite ? "Infinite" : "Finite"
    lines.append("")
    lines.append("══════════════════════════════════════════════════════════════════")
    lines.append("\(modeLabel) Test Set — \(cases.count) cases")
    lines.append("  Stations:  \(params.stationsLower)…\(params.stationsUpper)")
    lines.append("  Classes:   \(params.classesLower)…\(params.classesUpper)")
    lines.append("  ρ range:   \(String(format: "%.2f", params.rhoLower))…\(String(format: "%.2f", params.rhoUpper))")
    lines.append("  Topology:  \(params.topology)")
    lines.append("  Reference: \(referenceKey)")
    lines.append("──────────────────────────────────────────────────────────────────")
    lines.append("")

    // Per-algo collection of per-case mean abs % errors.
    var perAlgoErrs: [String: [Double]] = [:]
    var perAlgoTimes: [String: [TimeInterval]] = [:]
    for c in cases {
        guard let ref = c.algoOutputs[referenceKey] else { continue }
        for algo in algoOrder where algo != referenceKey {
            guard let out = c.algoOutputs[algo] else { continue }
            if let e = meanAbsPctError(algo: out, ref: ref) {
                perAlgoErrs[algo, default: []].append(e)
            }
            perAlgoTimes[algo, default: []].append(out.elapsed)
        }
    }

    // Header.
    let colName = "Algorithm"
    let colMean = "Mean %err"
    let colP50  = "P50"
    let colP90  = "P90"
    let colMax  = "Max"
    let colN    = "N"
    let colTime = "Avg time"
    let widths  = [12, 10, 8, 8, 8, 5, 10]
    func pad(_ s: String, _ w: Int, right: Bool = true) -> String {
        if s.count >= w { return s }
        let space = String(repeating: " ", count: w - s.count)
        return right ? s + space : space + s
    }
    var header = pad(colName, widths[0])
    header += pad(colMean, widths[1], right: false)
    header += pad(colP50,  widths[2], right: false)
    header += pad(colP90,  widths[3], right: false)
    header += pad(colMax,  widths[4], right: false)
    header += pad(colN,    widths[5], right: false)
    header += pad(colTime, widths[6], right: false)
    lines.append(header)
    lines.append(String(repeating: "─", count: header.count))

    for algo in algoOrder where algo != referenceKey {
        let errs = perAlgoErrs[algo] ?? []
        let times = perAlgoTimes[algo] ?? []
        guard !errs.isEmpty else {
            var row = pad(algo, widths[0])
            row += pad("—", widths[1], right: false)
            row += pad("—", widths[2], right: false)
            row += pad("—", widths[3], right: false)
            row += pad("—", widths[4], right: false)
            row += pad("0", widths[5], right: false)
            row += pad("—", widths[6], right: false)
            lines.append(row)
            continue
        }
        let sorted = errs.sorted()
        let mean = errs.reduce(0, +) / Double(errs.count)
        func pct(_ p: Double) -> Double {
            let idx = max(0, min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded())))
            return sorted[idx]
        }
        let p50 = pct(0.50)
        let p90 = pct(0.90)
        let mx  = sorted.last ?? 0
        let avgT = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        var row = pad(algo, widths[0])
        row += pad(String(format: "%.2f%%", mean), widths[1], right: false)
        row += pad(String(format: "%.2f", p50),    widths[2], right: false)
        row += pad(String(format: "%.2f", p90),    widths[3], right: false)
        row += pad(String(format: "%.2f", mx),     widths[4], right: false)
        row += pad("\(errs.count)",                widths[5], right: false)
        row += pad(String(format: "%.2fs", avgT),  widths[6], right: false)
        lines.append(row)
    }
    // Reference row (no error vs itself).
    if let _ = perAlgoTimes[referenceKey] ?? cases.first?.algoOutputs[referenceKey].map({ _ in [TimeInterval]() }) {
        let times = cases.compactMap { $0.algoOutputs[referenceKey]?.elapsed }
        let avgT = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        var row = pad(referenceKey + " (ref)", widths[0])
        row += pad("—", widths[1], right: false)
        row += pad("—", widths[2], right: false)
        row += pad("—", widths[3], right: false)
        row += pad("—", widths[4], right: false)
        row += pad("\(times.count)", widths[5], right: false)
        row += pad(String(format: "%.2fs", avgT), widths[6], right: false)
        lines.append(row)
    }

    lines.append("")
    lines.append("Mean %err is the per-case mean absolute % error of E[\(infinite ? "Q" : "X")_k]")
    lines.append("across stations (relative to \(referenceKey)), averaged over the test set.")
    lines.append("══════════════════════════════════════════════════════════════════")
    lines.append("")
    return lines.joined(separator: "\n")
}

// MARK: - Spectral Convergence — parameters & sheet

/// Same shape as TestSetParameters except the ρ field is start / finish /
/// step instead of min / max. The sweep generates one random network per
/// case (stations / classes / topology drawn from the bounds, same seed
/// reused across the ρ sweep) and runs Spectral / QNA / Sim at every ρ
/// in [start, finish] step.
struct SpectralConvergenceParameters {
    var stationsLower: Int = 3
    var stationsUpper: Int = 6
    var classesLower:  Int = 1
    var classesUpper:  Int = 3
    var rhoStart:      Double = 0.50
    var rhoEnd:        Double = 0.95
    var rhoStep:       Double = 0.05
    var numTestCases:  Int = 10
    var topology: RandomNetworkGenerator.Topology = .feedForward
    var seed: UInt64? = nil
}

/// Returns the discrete ρ grid [start, start+step, …] capped at end+ε.
extension SpectralConvergenceParameters {
    var rhoValues: [Double] {
        guard rhoStep > 1e-9 else { return [rhoStart] }
        var out: [Double] = []
        var v = rhoStart
        // Use a tolerance so 0.50 + 0.05*9 == 0.95 includes the endpoint.
        while v <= rhoEnd + 1e-9 {
            out.append(min(v, rhoEnd))
            v += rhoStep
        }
        if out.last.map({ abs($0 - rhoEnd) > 1e-9 }) == true && out.last! < rhoEnd {
            out.append(rhoEnd)
        }
        return out
    }
}

struct SpectralConvergenceParameterSheet: View {
    @Binding var params: SpectralConvergenceParameters
    let onCancel: () -> Void
    let onRun: (SpectralConvergenceParameters) -> Void

    @State private var stationsLower = 3
    @State private var stationsUpper = 6
    @State private var classesLower = 1
    @State private var classesUpper = 3
    @State private var rhoStart = 0.50
    @State private var rhoEnd = 0.95
    @State private var rhoStep = 0.05
    @State private var numCases = 10
    @State private var topology: RandomNetworkGenerator.Topology = .feedForward
    @State private var fixedSeed = false
    @State private var seed = 12_345

    private static let stationRange = 1...32
    private static let classRange = 1...16
    private static let caseRange = 1...200
    private static let rhoRange = 0.01...0.99

    /// ρ grid implied by the current start / end / step (same rule as
    /// `SpectralConvergenceParameters.rhoValues`).
    private var rhoCount: Int {
        var p = SpectralConvergenceParameters()
        p.rhoStart = rhoStart; p.rhoEnd = rhoEnd; p.rhoStep = rhoStep
        return p.rhoValues.count
    }

    private var sweepValid: Bool {
        rhoStart > 0 && rhoEnd > rhoStart && rhoEnd < 1.0
            && rhoStep > 0 && rhoStep <= (rhoEnd - rhoStart) + 1e-9
    }

    /// First blocking problem, in row order; nil when the sweep can run.
    private var problem: String? {
        if !Self.stationRange.contains(stationsLower) || !Self.stationRange.contains(stationsUpper) {
            return "Stations must be between 1 and 32."
        }
        if stationsLower > stationsUpper { return "Minimum stations must not exceed the maximum." }
        if !Self.classRange.contains(classesLower) || !Self.classRange.contains(classesUpper) {
            return "Customer classes must be between 1 and 16."
        }
        if classesLower > classesUpper { return "Minimum classes must not exceed the maximum." }
        if !sweepValid { return "ρ sweep needs 0 < start < end < 1 and 0 < step ≤ end − start." }
        if !Self.caseRange.contains(numCases) { return "Test cases must be between 1 and 200." }
        return nil
    }

    private var solveSummary: String {
        guard sweepValid else { return "Choose a valid ρ sweep to see the number of solves." }
        let solves = numCases * rhoCount
        return "\(numCases) case\(numCases == 1 ? "" : "s") × \(rhoCount) ρ value\(rhoCount == 1 ? "" : "s") = \(solves) spectral solve\(solves == 1 ? "" : "s"), each checked against simulation (QNA is the flat-line baseline)."
    }

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Run Infinite Spectral Convergence",
                subtitle: "For each case, generates one random network and sweeps the target ρ from start to end in equal steps, reporting how the spectral method's error shrinks as ρ → 1."
            ) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.decreasing,
                                   tint: DS.Color.infoText)
            }
        } content: {
            Form {
                Section {
                    LabeledContent("Stations") {
                        IntRangeFields(lower: $stationsLower, upper: $stationsUpper,
                                       range: Self.stationRange, label: "Stations")
                    }
                    .help("Number of service stations d drawn for each network (1–32)")

                    LabeledContent("Customer classes") {
                        IntRangeFields(lower: $classesLower, upper: $classesUpper,
                                       range: Self.classRange, label: "Customer classes")
                    }
                    .help("Number of customer classes c drawn for each network (1–16)")

                    TopologyPicker(topology: $topology)
                } header: {
                    Text("Networks")
                }

                Section {
                    LabeledContent("ρ sweep") {
                        HStack(spacing: DS.Spacing.xs) {
                            rhoField($rhoStart, "Sweep start")
                            Text("→")
                                .foregroundStyle(DS.Color.textSecondary)
                                .accessibilityHidden(true)
                            rhoField($rhoEnd, "Sweep end")
                        }
                    }
                    .help("Target utilisation ρ is swept from start to end; both strictly between 0 and 1")

                    LabeledContent("Step") {
                        rhoField($rhoStep, "Sweep step", invalid: !(rhoStep > 0 && rhoStep <= (rhoEnd - rhoStart) + 1e-9))
                    }
                    .help("Increment between consecutive ρ values (0 < step ≤ end − start)")

                    LabeledContent("Test cases") {
                        CountField(value: $numCases, range: Self.caseRange, label: "Test cases")
                    }
                    .help("Number of random networks, each swept over every ρ value (1–200)")

                    Toggle("Fixed random seed", isOn: $fixedSeed)
                        .help("Reuse the same network shapes and simulation streams when this sweep is run again")

                    if fixedSeed {
                        LabeledContent("Seed") {
                            DSNumericField(
                                label: "Seed",
                                value: $seed,
                                range: 0...Int(Int32.max),
                                stepper: 1,
                                commit: .onEdit,
                                help: "Base seed for the complete convergence sweep",
                                width: DS.Layout.fieldWidth,
                                accessibilityLabel: "Convergence-sweep seed"
                            )
                            .dsRowLayout(.bare)
                        }
                    }
                } header: {
                    Text("Sweep")
                } footer: {
                    Text(solveSummary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } footer: {
            DSSheetFooter(
                problem: problem,
                helpTopic: .testSets,
                confirmTitle: "Run",
                canConfirm: problem == nil,
                cancelHelp: "Close without running (Esc)",
                confirmHelp: "Generate the networks and start the convergence sweep (Return)",
                blockedHelp: "Fix the highlighted values to run the sweep",
                onCancel: onCancel,
                onConfirm: runTapped
            )
        }
        .dsSheetFrame(.tall)
        .onAppear {
            stationsLower = params.stationsLower
            stationsUpper = params.stationsUpper
            classesLower = params.classesLower
            classesUpper = params.classesUpper
            rhoStart = params.rhoStart
            rhoEnd = params.rhoEnd
            rhoStep = params.rhoStep
            numCases = params.numTestCases
            topology = params.topology
            fixedSeed = params.seed != nil
            seed = Int(params.seed ?? 12_345)
        }
    }

    /// One ρ value (two decimals). `invalid` overrides the range check for
    /// the step field, whose rule depends on the other two values.
    private func rhoField(_ value: Binding<Double>, _ accessibility: String, invalid: Bool? = nil) -> some View {
        DSNumericField(
            label: accessibility,
            value: value,
            format: .number.precision(.fractionLength(2)),
            range: invalid == nil ? Self.rhoRange : nil,
            stepper: invalid == nil ? 0.05 : 0.01,
            error: invalid == true ? "Step must be positive and at most end − start" : nil,
            help: accessibility,
            width: DS.Layout.compactFieldWidth,
            accessibilityLabel: accessibility
        )
        .dsRowLayout(.bare)
    }

    private func runTapped() {
        guard problem == nil else { return }
        var p = params
        p.stationsLower = stationsLower; p.stationsUpper = stationsUpper
        p.classesLower  = classesLower;  p.classesUpper  = classesUpper
        p.rhoStart = rhoStart; p.rhoEnd = rhoEnd; p.rhoStep = rhoStep
        p.numTestCases = numCases
        p.topology = topology
        p.seed = fixedSeed ? UInt64(seed) : nil
        onRun(p)
    }
}
