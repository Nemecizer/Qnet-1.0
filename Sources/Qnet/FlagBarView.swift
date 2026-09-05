import SwiftUI

/// Three equal-width status pills (`DSPill`) in a fixed-height bar under
/// the Status pane's header (`StatusPanelView(showsFlagBar: true)`), each
/// with a leading SF Symbol:
///   • Analytical (green)              — `editor.isAnalyticallyTractable`
///   • Re-entrant (green/orange/red)   — `editor.hasFeedback` + diffusion quality
///   • Warnings (orange, count badge)  — `editor.networkHasWarnings`
/// Orange is `DS.Color.warning`, the same colour the status log and inline
/// field advice use for the word "warning"; red is reserved for errors and
/// pathological (red-quality) re-entrant routing.
///
/// Every pill is a button: a lit pill opens a popover explaining why the
/// flag fired; an unlit pill opens a short "why not" popover so the state
/// is always explainable (and VoiceOver-reachable).
///
/// The bar reflects whichever editor is currently active; SwiftUI re-renders
/// it automatically when the active tab's flags change because the editor
/// is injected via `@EnvironmentObject`.  Parameter edits post
/// `.bnetNetworkParametersDidChange`, which re-runs the silent analysis so
/// the pills never show stale state after Save.
struct FlagBarView: View {
    @EnvironmentObject private var editor: NetworkEditorModel

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            DSPill(
                title: "Analytical",
                systemImage: DS.Symbol.verified,
                isOn: editor.isAnalyticallyTractable,
                tint: DS.Color.success,
                help: editor.tractabilityTitle.isEmpty
                    ? "Closed-form stationary distribution available."
                    : editor.tractabilityTitle,
                inactiveHelp: "Not analytically tractable. Click to see why.",
                accessibilityHint: "Opens the tractability explanation",
                detail: { AnalyticalDetail(editor: editor) }
            )
            DSPill(
                title: "Re-entrant",
                systemImage: DS.Symbol.reentrant,
                isOn: editor.hasFeedback,
                tint: reentrantTint(editor.feedbackQuality),
                help: reentrantTooltip(editor.feedbackQuality),
                inactiveHelp: "Routing is feed-forward (no cycles). Click for details.",
                accessibilityHint: "Opens the routing-cycle and diffusion-friendliness report",
                detail: { ReentrantDetail(editor: editor) }
            )
            DSPill(
                title: "Warnings",
                systemImage: DS.Symbol.warning,
                isOn: editor.networkHasWarnings,
                tint: DS.Color.warning,
                badge: editor.networkHasWarnings ? max(editor.networkWarningList.count, 1) : nil,
                help: "The latest analysis produced \(editor.networkWarningList.count) warning\(editor.networkWarningList.count == 1 ? "" : "s"). Click to list them.",
                inactiveHelp: "No warnings from the latest analysis.",
                accessibilityHint: "Opens the list of analysis warnings",
                detail: { WarningDetail(editor: editor) }
            )
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity)
        .background(DS.Color.surface)
        // The header above draws its own bottom rule; only the edge that
        // faces the filter row needs one.
        .dsHairline(.bottom)
    }

    /// Diffusion-friendliness → pill tint. The "partial" quality is the
    /// one warning colour; the tint is unused while the pill is off.
    private func reentrantTint(_ q: NetworkEditorModel.FeedbackQuality) -> Color {
        switch q {
        case .green:  return DS.Color.success
        case .yellow: return DS.Color.warning
        case .red:    return DS.Color.danger
        case .notReentrant: return DS.Color.textSecondary
        }
    }

    private func reentrantTooltip(_ q: NetworkEditorModel.FeedbackQuality) -> String {
        switch q {
        case .green:  return "Re-entrant routing; all diffusion-friendliness criteria pass. Diffusion methods should match simulation within ~10%."
        case .yellow: return "Re-entrant routing; some criteria failed. Expect 10–30% under-prediction versus simulation. Click for details."
        case .red:    return "Re-entrant routing with a Kumar–Seidman / Bramson-style pathology. Diffusion methods will under-predict; trust the simulator."
        case .notReentrant: return ""
        }
    }
}

// MARK: - Popover detail views (each is a DSPopover)

private struct AnalyticalDetail: View {
    @ObservedObject var editor: NetworkEditorModel

    var body: some View {
        DSPopover(
            title: "Analytical",
            systemImage: editor.isAnalyticallyTractable ? DS.Symbol.verified : DS.Symbol.unverified,
            tint: editor.isAnalyticallyTractable ? DS.Color.success : DS.Color.textSecondary,
            trailing: editor.isAnalyticallyTractable
                ? (editor.tractabilityIsExact ? "Exact" : "Asymptotic")
                : "Not tractable"
        ) {
            if editor.isAnalyticallyTractable {
                if !editor.tractabilityTitle.isEmpty {
                    Text(editor.tractabilityTitle)
                        .font(DS.Font.subheadline.bold())
                }
                if !editor.tractabilityDetail.isEmpty {
                    Text(editor.tractabilityDetail)
                        .font(DS.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !editor.tractabilityExplanation.isEmpty {
                    DSRule()
                    Text(editor.tractabilityExplanation)
                        .font(DS.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !editor.tractabilityMeans.isEmpty {
                    DSRule()
                    let label = editor.tractabilityMeansLabel.isEmpty
                        ? "Predicted mean per station"
                        : editor.tractabilityMeansLabel
                    let throughputs = analyticalThroughputs
                    Text(throughputs == nil ? label : "\(label) and throughput Γ")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    // Columns: the station's own name (the means vector is
                    // index-aligned with the exporter's station order), the
                    // mean right-aligned in monospaced digits — the same
                    // convention as the node sheet's readouts — and the
                    // throughput Γ the analytical column of Run Comparison
                    // prints as Gamma_N for the same station.
                    Grid(alignment: .leading, horizontalSpacing: DS.Spacing.l,
                         verticalSpacing: DS.Spacing.xxs) {
                        if throughputs != nil {
                            GridRow {
                                Text("Station")
                                    .font(DS.Font.tableHeader)
                                    .foregroundStyle(DS.Color.textSecondary)
                                Text("Mean")
                                    .font(DS.Font.tableHeader)
                                    .foregroundStyle(DS.Color.textSecondary)
                                    .gridColumnAlignment(.trailing)
                                HStack(spacing: DS.Spacing.xxs) {
                                    Text("Γ")
                                        .font(DS.Font.tableHeader)
                                        .foregroundStyle(DS.Color.textSecondary)
                                    DSGlossaryButton(label: "Throughput Γ", text: DS.Glossary.gamma)
                                }
                                .gridColumnAlignment(.trailing)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Station, predicted mean, throughput Γ")
                        }
                        ForEach(Array(editor.tractabilityMeans.enumerated()), id: \.offset) { i, v in
                            let gamma = throughputs.flatMap { i < $0.count ? $0[i] : nil }
                            GridRow {
                                Text(editor.stationName(atExportIndex: i))
                                    .font(DS.Font.numberCaption)
                                    .lineLimit(1)
                                Text(DS.Number.format(v, significantDigits: DS.Number.readoutDigits))
                                    .font(DS.Font.numberCaption)
                                    .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                                if let gamma {
                                    Text(DS.Number.format(gamma, significantDigits: DS.Number.readoutDigits))
                                        .font(DS.Font.numberCaption)
                                        .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
                                        .gridColumnAlignment(.trailing)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(editor.stationName(atExportIndex: i)): mean \(DS.Number.format(v, significantDigits: DS.Number.readoutDigits))"
                                + (gamma.map { ", throughput \(DS.Number.format($0, significantDigits: DS.Number.readoutDigits))" } ?? ""))
                        }
                    }
                    .help(editor.tractabilityTitle.isEmpty
                          ? "Predicted stationary means from the matched closed-form solution"
                          : "\(label) — \(editor.tractabilityTitle)")

                    // The vector is index-aligned with the exporters'
                    // station order, which is the numeric suffix of the
                    // name. When the names do not pin that order down,
                    // `stationName(atExportIndex:)` prints S1 … Sn rather
                    // than confidently labelling a number with the wrong
                    // station — say so instead of leaving it a mystery.
                    if editor.stationOrderIsAmbiguous {
                        InlineFieldMessage(
                            "Station names have no distinct numeric suffix, so rows are labelled by solver index (S1 … Sn) rather than by name.",
                            severity: .warning)
                    }
                }
                if editor.tractabilityTitle.isEmpty
                    && editor.tractabilityDetail.isEmpty
                    && editor.tractabilityExplanation.isEmpty
                    && editor.tractabilityMeans.isEmpty {
                    Text("Network has a known closed-form stationary distribution.")
                        .font(DS.Font.callout)
                }
            } else {
                Text(whyNot)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                let nonExp = nonExponentialStations
                if !nonExp.isEmpty {
                    DSRule()
                    Text("Stations with non-exponential service")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    ForEach(nonExp, id: \.self) { line in
                        Text(line)
                            .font(DS.Font.numberCaption)
                    }
                }
                DSRule()
                Text("Tractable cases: Jackson (exponential service, Markovian routing), skew-symmetric SRBM, and the GCDG 2025 asymptotic regimes.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Per-station throughput Γ for the analytical readout: the effective
    /// arrival rate α from the traffic equations, which is exactly what
    /// `writeAnalyticalFile` prints as `Gamma_N` in the analytical column
    /// of Run Comparison (in steady state what enters a station leaves
    /// it). Nil when the primitives cannot be computed or the station
    /// count does not match the means vector.
    private var analyticalThroughputs: [Double]? {
        guard case .success(let data) = SRBMExporter.computeData(
            nodes: editor.nodes, links: editor.links, infiniteBuffers: editor.infiniteBuffers),
              data.d == editor.tractabilityMeans.count,
              data.alpha.allSatisfy(\.isFinite) else { return nil }
        return data.alpha
    }

    private var whyNot: String {
        if editor.nodes.isEmpty {
            return "The canvas is empty — add a source, a station and a sink to analyse the network."
        }
        if !editor.hasBeenAnalyzed {
            return "The network has not been analysed yet. Analysis runs automatically after edits; run Network ▸ Show Network Primitives for the full report."
        }
        if !editor.tractabilityExplanation.isEmpty {
            return editor.tractabilityExplanation
        }
        return "No known closed-form or asymptotic product-form stationary distribution matches this network."
    }

    /// "S2 (Gamma)" lines for stations whose service law is not exponential.
    private var nonExponentialStations: [String] {
        editor.nodes.filter { $0.kind == .station }.compactMap { node in
            let classes = editor.classesServedAtStation(nodeID: node.id)
            var families = Set<String>()
            if classes.isEmpty {
                if node.distribution != .exponential { families.insert(node.distribution.displayName) }
            } else {
                for c in classes {
                    let d = node.serviceDistributions[c]?.distribution ?? node.distribution
                    if d != .exponential { families.insert(d.displayName) }
                }
            }
            guard !families.isEmpty else { return nil }
            return "\(node.name)  (\(families.sorted().joined(separator: ", ")))"
        }
    }
}

private struct ReentrantDetail: View {
    @ObservedObject var editor: NetworkEditorModel

    private var statusColor: Color {
        switch editor.feedbackQuality {
        case .green: return DS.Color.success
        case .yellow: return DS.Color.warning
        case .red: return DS.Color.danger
        case .notReentrant: return DS.Color.textSecondary
        }
    }

    private var statusHeadline: String {
        switch editor.feedbackQuality {
        case .green:  return "Diffusion-friendly"
        case .yellow: return "Partial — accuracy degraded"
        case .red:    return "Pathological — under-prediction likely"
        case .notReentrant: return "Feed-forward"
        }
    }

    private var implicationText: String {
        switch editor.feedbackQuality {
        case .green:
            return "All criteria pass. Spectral / QNA / RQNA / SBD point estimates should agree with simulation within ~10%."
        case .yellow:
            return "One or two criteria failed. Expect approximations to under-predict E[Q] by 10–30% versus simulation. Cross-check with the simulator on critical stations."
        case .red:
            return "Multiple criteria fail, or a high-ρ station has heavy class-transition amplification (Kumar–Seidman / Bramson signature). Diffusion-based methods may systematically under-predict. Use queue-process simulation with confidence intervals as the reference; the LP relaxation (BNAlp / fBNAlp) supplies a complementary bound or approximation."
        case .notReentrant:
            return "Routing is feed-forward; no diffusion-friendliness concern."
        }
    }

    var body: some View {
        DSPopover(title: "Re-entrant",
                  systemImage: DS.Symbol.reentrant,
                  tint: statusColor,
                  trailing: statusHeadline) {
            if editor.hasFeedback {
                Text("The routing graph contains at least one directed cycle, so jobs may revisit a station.")
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if editor.nodes.isEmpty {
                Text("The canvas is empty — nothing to analyse yet.")
                    .font(DS.Font.callout)
            } else if !editor.hasBeenAnalyzed {
                Text("The network has not been analysed yet; the flag updates automatically after edits.")
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No directed cycle was found: no self-loop, immediate feedback (A → B → A) or longer rework loop. Every job visits each station at most once.")
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.feedbackDescription.isEmpty {
                DSRule()
                Text(editor.feedbackDescription)
                    .font(DS.Font.monoCallout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.feedbackCriteria.isEmpty {
                DSRule()
                Text("Diffusion-friendliness criteria")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                ForEach(Array(editor.feedbackCriteria.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top, spacing: DS.Spacing.s) {
                        Image(systemName: c.ok ? DS.Symbol.success : DS.Symbol.failure)
                            .foregroundStyle(c.ok ? DS.Color.successText : DS.Color.dangerText)
                            .font(DS.Font.callout)
                            .accessibilityLabel(c.ok ? "passed" : "failed")
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(c.label).font(DS.Font.callout)
                            Text(c.detail).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            DSRule()
            Text(implicationText)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WarningDetail: View {
    @ObservedObject var editor: NetworkEditorModel

    var body: some View {
        let count = editor.networkWarningList.count
        DSPopover(title: "Warnings",
                  systemImage: editor.networkHasWarnings ? DS.Symbol.warning : DS.Symbol.noIssues,
                  tint: editor.networkHasWarnings ? DS.Color.warning : DS.Color.success,
                  trailing: editor.networkHasWarnings
                      ? "\(count) issue\(count == 1 ? "" : "s")"
                      : "None") {
            if !editor.networkHasWarnings {
                if editor.nodes.isEmpty {
                    Text("The canvas is empty — nothing to analyse yet.")
                        .font(DS.Font.callout)
                } else if !editor.hasBeenAnalyzed {
                    Text("The network has not been analysed yet; warnings appear here automatically after edits.")
                        .font(DS.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The latest analysis found no problems: every station is stable (ρ < 1) and the routing structure is consistent.")
                        .font(DS.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if editor.networkWarningList.isEmpty {
                Text("The analysis flagged a problem, but the warning list is unavailable. Re-run Network ▸ Show Network Primitives to refresh.")
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ForEach(Array(editor.networkWarningList.enumerated()), id: \.offset) { _, w in
                            HStack(alignment: .top, spacing: DS.Spacing.s) {
                                Image(systemName: DS.Symbol.warning)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.warningText)
                                    .padding(.top, DS.Spacing.xxs)
                                    .accessibilityHidden(true)
                                Text(w)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(DS.Font.callout)
                        }
                    }
                }
                .frame(maxHeight: DS.Layout.popoverListMaxHeight)
            }
            DSRule()
            Text("Run Network ▸ Show Network Primitives for the full primitives report.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }
}
