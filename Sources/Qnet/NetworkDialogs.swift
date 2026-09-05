import SwiftUI
import AppKit

// Both dialogs use the DSSheet chrome — 44-pt glyph header with title and
// one-line description, grouped Form, footer with the first blocking
// problem and Cancel / confirm — so they look like the inspectors, the
// SRBM export sheet and the Test-menu sheets.

// MARK: - Generate Random Network

/// Network ▸ Generate Random Network… (⇧⌘R). Steppers on the integer
/// fields, menu pickers for buffers and topology, inline validation, and
/// Cancel/Generate bound to Escape/Return.
struct GenerateRandomNetworkSheet: View {
    let onCancel: () -> Void
    let onGenerate: (RandomNetworkGenerator.Parameters) -> Void

    @State private var stations = 4
    @State private var classes = 3
    @State private var infiniteBuffers = true
    @State private var topology: RandomNetworkGenerator.Topology = .feedForward
    @State private var rhoText = "0.90"
    @State private var seedText = ""

    private static let stationRange = 1...20
    private static let classRange = 1...8
    private static let rhoRange = 0.1...0.99

    private var rhoValue: Double? {
        guard let v = DS.Number.parse(rhoText), Self.rhoRange.contains(v) else { return nil }
        return v
    }

    private var seedValue: UInt64?? {
        let t = seedText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        if let s = UInt64(t) { return .some(s) }
        return nil
    }

    private var problem: String? {
        if !Self.stationRange.contains(stations) { return "Stations must be between 1 and 20." }
        if !Self.classRange.contains(classes) { return "Customer classes must be between 1 and 8." }
        if rhoValue == nil { return "Target ρ must be a number between 0.10 and 0.99." }
        if seedValue == nil { return "Seed must be a non-negative integer, or blank for a random seed." }
        return nil
    }

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Generate Random Network",
                subtitle: "Creates a random open network in a new tab: random routing per class, a random service law per (station, class) and arrival rates scaled to the target ρ."
            ) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.randomNetwork,
                                   tint: DS.Color.infoText)
            }
        } content: {
            Form {
                Section {
                    LabeledContent("Stations") {
                        countField(value: $stations, range: Self.stationRange, label: "Number of stations")
                    }
                    .help("Number of service stations d (1–20)")

                    LabeledContent("Customer classes") {
                        countField(value: $classes, range: Self.classRange, label: "Number of customer classes")
                    }
                    .help("Number of customer classes c (1–8)")

                    Picker("Buffers", selection: $infiniteBuffers) {
                        Text("Infinite").tag(true)
                        Text("Finite").tag(false)
                    }
                    .pickerStyle(.menu)
                    .help("Infinite buffers give an SRBM on the orthant; finite buffers an SRBM on a hypercube")

                    Picker("Topology", selection: $topology) {
                        Text("Feed-forward").tag(RandomNetworkGenerator.Topology.feedForward)
                        Text("Jackson feedback (light)").tag(RandomNetworkGenerator.Topology.jacksonFeedback)
                        Text("General P-matrix (full feedback)").tag(RandomNetworkGenerator.Topology.generalPMatrix)
                        Text("Re-entrant feedback (class-change)").tag(RandomNetworkGenerator.Topology.reentrantFeedback)
                    }
                    .pickerStyle(.menu)
                    .help("Routing structure of the generated network")
                } header: {
                    Text("Structure")
                }

                Section {
                    LabeledContent("Target ρ") {
                        DSNumericField(
                            label: "Target utilisation rho",
                            text: $rhoText,
                            range: Self.rhoRange,
                            stepper: 0.05,
                            help: DS.Glossary.rho,
                            placeholder: "0.90",
                            width: DS.Layout.compactFieldWidth,
                            accessibilityLabel: "Target utilisation rho"
                        )
                        .dsRowLayout(.bare)
                    }
                    .help("Average utilisation every station is scaled towards (0.10–0.99)")

                    LabeledContent("Seed") {
                        DSNumericField(
                            label: "Random seed",
                            text: $seedText,
                            error: seedValue == nil ? "Enter a non-negative whole number" : nil,
                            help: "Leave blank for a fresh random network; enter an integer to reproduce one",
                            placeholder: "Random",
                            width: DS.Layout.fieldWidth,
                            accessibilityLabel: "Random seed"
                        )
                        .dsRowLayout(.bare)
                    }
                    .help("Leave blank for a fresh random network; enter an integer to reproduce one")
                } header: {
                    Text("Load and reproducibility")
                } footer: {
                    Text("External arrival rates are scaled so every station sits near the target ρ; a fixed seed regenerates the same network.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } footer: {
            DSSheetFooter(
                problem: problem,
                confirmTitle: "Generate",
                canConfirm: problem == nil,
                cancelHelp: "Close without generating a network (Esc)",
                confirmHelp: "Create the random network in a new tab (Return)",
                blockedHelp: "Fix the highlighted values to generate",
                onCancel: onCancel,
                onConfirm: generate
            )
        }
        .dsSheetFrame(.regular)
    }

    /// Integer count with a stepper: the DS numeric field alone (`.bare`);
    /// the enclosing `LabeledContent` carries the label and the sheet
    /// footer reports the first blocking problem.
    private func countField(value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        DSNumericField(
            label: label,
            value: value,
            range: range,
            stepper: 1,
            commit: .onEdit,
            help: label,
            width: DS.Layout.compactFieldWidth,
            accessibilityLabel: label
        )
        .dsRowLayout(.bare)
    }

    private func generate() {
        guard let rho = rhoValue, let seed = seedValue else { return }
        var params = RandomNetworkGenerator.Parameters()
        params.stations = max(1, min(20, stations))
        params.classes  = max(1, min(8, classes))
        params.infiniteBuffers = infiniteBuffers
        params.targetRho = max(0.1, min(0.99, rho))
        params.topology = topology
        params.seed = seed
        onGenerate(params)
    }
}

// MARK: - Find Node

/// Edit ▸ Find Node… (⌘F). A live-filtering search field: the match list
/// updates as you type and Return reveals the first match.
/// Find Node as a *panel* body.
///
/// A panel's root view is built once, when the window opens, so a plain
/// `FindNodeSheet(nodes: editor.nodes, …)` would go on searching the node
/// list as it stood at that moment — and unlike the sheet this replaces, a
/// panel leaves the canvas underneath it live and editable.  Observing the
/// document is the whole of the difference; the form itself is unchanged.
struct FindNodePanelBody: View {
    @ObservedObject var editor: NetworkEditorModel
    let onCancel: () -> Void
    let onFind: (String) -> Void

    var body: some View {
        FindNodeSheet(nodes: editor.nodes, onCancel: onCancel, onFind: onFind)
    }
}

struct FindNodeSheet: View {
    let nodes: [NetworkNode]
    let onCancel: () -> Void
    let onFind: (String) -> Void

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var matches: [NetworkNode] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return nodes.filter { $0.name.lowercased().contains(q) }
    }

    private var matchSummary: String {
        if trimmedQuery.isEmpty {
            return "\(nodes.count) node\(nodes.count == 1 ? "" : "s") on the canvas"
        }
        switch matches.count {
        case 0:  return "No node matches “\(trimmedQuery)”"
        case 1:  return "1 match"
        default: return "\(matches.count) matches"
        }
    }

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Find Node",
                subtitle: "Enter a node name or part of one. The first match is selected and scrolled into view."
            ) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.find,
                                   tint: DS.Color.infoText)
            }
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                DSSearchField(
                    text: $query,
                    placeholder: "Node name (e.g. S3, Src, buffer)",
                    help: "Type part of a node name; the list filters as you type",
                    accessibilityLabel: "Node name",
                    escapeClears: false,   // Escape cancels the sheet
                    focus: $fieldFocused,
                    onSubmit: { submit() }
                )

                Text(matchSummary)
                    .font(DS.Font.chrome)
                    .foregroundStyle(DS.Color.textSecondary)
                    .monospacedDigit()
                    .accessibilityLabel(matchSummary)

                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(matches.prefix(6), id: \.id) { n in
                            HStack(spacing: DS.Spacing.s) {
                                Image(systemName: n.kind.systemImage)
                                    .foregroundStyle(DS.Color.nodeTint(for: n.kind))
                                    .frame(width: DS.Layout.paletteIconWidth)
                                    .accessibilityHidden(true)
                                Text(n.name)
                                    .font(DS.Font.body)
                                Text(n.kind.rawValue.capitalized)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if matches.count > 6 {
                            Text("and \(matches.count - 6) more…")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    .padding(DS.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Color.subtleFill)
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.l)
            .dsAnimation(DS.Motion.quick, value: matches.count)
        } footer: {
            DSSheetFooter(
                confirmTitle: "Find",
                canConfirm: !matches.isEmpty,
                cancelHelp: "Close without changing the selection (Esc)",
                confirmHelp: "Select the first matching node and zoom to it (Return)",
                blockedHelp: "Type part of a node name to find it",
                onCancel: onCancel,
                onConfirm: submit
            )
        }
        .dsSheetFrame(.compact)
        .defaultFocus($fieldFocused, true)
    }

    private func submit() {
        guard !matches.isEmpty else { return }
        onFind(query)
    }
}
