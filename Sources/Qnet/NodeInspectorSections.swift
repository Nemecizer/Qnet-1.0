import SwiftUI

/// Where an inspector's sections are being shown. The two hosts differ
/// only in geometry and commit timing; the fields are the same views
/// bound to the same `NodeParameterDraft`.
enum InspectorHost {
    /// The modal sheet (⌘I): wide, per-class service as a table, commits
    /// on Save.
    case sheet
    /// The docked pane: narrow, per-class service as a class picker over
    /// one stacked editor, commits each field on blur.
    case pane
}

/// The node inspector's sections — Identity / Capacity / Service /
/// Routing — parameterised by host so `NodeParameterEditorSheet` and
/// `InspectorPaneView` render the SAME form. Emit them inside a
/// `Form { … }.formStyle(.grouped)`; the host owns the chrome, the
/// `NodeParameterDraft` and the commit policy.
///
/// Field focus is reported to the draft (`fieldFocusCount`) so the pane
/// can commit when the last field blurs; `onOpenLink` is what a Routing
/// row does when activated (the sheet closes into the link inspector,
/// the pane just selects the link).
struct NodeInspectorSections: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject var model: NodeParameterDraft
    let node: NetworkNode
    let host: InspectorHost
    var nameFocus: FocusState<Bool>.Binding
    var onOpenLink: ((UUID) -> Void)? = nil

    @State private var showPicturePicker = false
    @DSAccessibility private var a11y
    /// Keyboard focus of a per-class table ROW (Full Keyboard Access):
    /// the class whose row is focused drives the distribution card just
    /// as a mouse click on the row does.
    @FocusState private var focusedClassRow: Int?

    var body: some View {
        identitySection
        switch node.kind {
        case .buffer:
            bufferCapacitySection
        case .station:
            stationCapacitySection
            if model.servedClasses.isEmpty {
                singleDistributionSection(
                    title: "Service Time",
                    footer: "No customer class reaches this station yet; this default law is used until links connect a class.",
                    rateLabel: "μ")
            } else if host == .sheet {
                perClassServiceSection
            } else {
                stackedClassServiceSection
            }
            routingSection
        case .source:
            singleDistributionSection(
                title: "Inter-arrival Time",
                footer: "Arrivals from this source form \(CustomerClass.label(for: editor.customerClassIndex(for: node.id))).",
                rateLabel: "λ")
            routingSection
        case .sink:
            Section("Behaviour") {
                Text("Jobs leave the network here. Sinks have no parameters.")
                    .foregroundStyle(DS.Color.textSecondary)
            }
            routingSection
        }
    }

    // MARK: - Geometry per host

    private var wideFieldWidth: CGFloat? { host == .pane ? nil : DS.Layout.wideFieldWidth }
    private var numericFieldWidth: CGFloat? { host == .pane ? DS.Layout.narrowFieldWidth : DS.Layout.fieldWidth }
    private var segmentedWidth: CGFloat? { host == .pane ? nil : DS.Layout.wideFieldWidth }
    private var menuWidth: CGFloat? { host == .pane ? DS.Layout.fieldWidth : DS.Layout.wideMenuWidth }

    /// Blur / focus bookkeeping for the pane's commit-on-blur rule.
    private func noteFocus(_ focused: Bool) {
        model.fieldFocusCount = max(0, model.fieldFocusCount + (focused ? 1 : -1))
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Identity") {
            DSTextField(
                label: "Name",
                text: $model.nameText,
                placeholder: "Name",
                help: "Unique label shown on the canvas and in reports",
                width: wideFieldWidth,
                error: model.nameError(editor: editor),
                // Select-all + Delete before retyping a name is not a
                // mistake yet: no red border, no red caption. Save stays
                // blocked and the footer says "Still typing Name".
                required: true,
                focus: nameFocus
            )
            .onChange(of: nameFocus.wrappedValue) { _, focused in
                model.nameIsFocused = focused
                noteFocus(focused)
            }

            LabeledContent("Kind") {
                Label(node.kind.displayName, systemImage: node.kind.systemImage)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            if node.kind == .station {
                LabeledContent("Picture") {
                    HStack(spacing: DS.Spacing.s) {
                        StationPicturePreview(picture: model.stationPicture, size: DS.Layout.controlHeight + DS.Spacing.xs)
                            .accessibilityHidden(true)
                        if host == .sheet {
                            Text(model.stationPicture.displayName)
                                .foregroundStyle(DS.Color.textSecondary)
                                .lineLimit(1)
                        }
                        if let suggestion = pictureSuggestion {
                            Button("Use \(suggestion.displayName)") {
                                model.stationPicture = suggestion
                            }
                            .controlSize(.small)
                            .help("Suggested from the number of servers")
                        }
                        Button("Choose…") {
                            showPicturePicker = true
                        }
                        .help("Pick a resource icon to draw inside the station circle (\(model.stationPicture.displayName))")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Picture: \(model.stationPicture.displayName)")
                // A movable panel, not a sheet. The icon being chosen is
                // drawn inside the station circle ON the canvas, so the one
                // thing the user needs to see while choosing is the thing a
                // sheet would cover. `showPicturePicker` remains the single
                // switch — the flag is still the state, the panel is only
                // the presentation — so the "Choose…" button above, and
                // anything else that sets the flag, is unchanged.
                .onChange(of: showPicturePicker) { _, presented in
                    guard presented else {
                        DSPanelWindow.close(id: Self.picturePanelID)
                        return
                    }
                    DSPanelWindow.present(
                        id: Self.picturePanelID,
                        title: "Station Picture",
                        size: .wide,
                        modality: picturePanelModality,
                        // `onClose` is the ONE teardown path: the footer's
                        // Cancel, Choose, the title-bar button, ⌘W and Quit
                        // all arrive here, so the flag is cleared exactly
                        // once and cannot get stuck on.
                        onClose: { showPicturePicker = false }
                    ) { _ in
                        PicturePickerSheet(selection: $model.stationPicture)
                    }
                }
                // A panel outlives the row that opened it unless it is taken
                // away. Both of these matter: the inspector is rebuilt when
                // the selection changes, and a panel left standing would be
                // writing the PREVIOUS node's draft; and when the ⌘I sheet
                // host goes away, AppKit orders its window out without
                // closing it, which would leave the panel alive but hidden.
                .onChange(of: node.id) { _, _ in closePicturePicker() }
                .onDisappear { closePicturePicker() }
            }
        }
    }

    /// Operator / Two Operators / Team suggestion when no picture is chosen
    /// (or the current operator picture no longer matches the server count).
    private var pictureSuggestion: StationPicture? {
        guard let servers = DS.Number.parseInt(model.serversText), servers >= 1 else { return nil }
        let suggested = StationPicture.suggested(forServers: servers)
        guard model.stationPicture == .none
                || (model.stationPicture.isOperatorPicture && model.stationPicture != suggested) else {
            return nil
        }
        return suggested
    }

    // MARK: - Picture panel

    /// One panel per app, not one per inspector host: only one inspector can
    /// be driven at a time, and two windows editing one draft is a data race
    /// the user can see. Presenting the same id twice brings the open panel
    /// forward instead of stacking a copy.
    private static let picturePanelID = "station-picture"

    /// The picker belongs to one station's inspector, and while it is up the
    /// bare canvas tool letters must not fire underneath it — both hosts
    /// therefore ask for a modal panel. They differ in what it can safely
    /// hang off:
    ///
    /// * From the docked pane the opener is the canvas window, which is not
    ///   going anywhere, so the panel is a real child window: it travels
    ///   with its parent and stays above it — a sheet's ordering without a
    ///   sheet's immobility.
    /// * From the ⌘I sheet the opener is the *sheet's* window, which AppKit
    ///   orders out when the sheet ends without closing it. A child of that
    ///   window would be dragged out of sight while still registered, which
    ///   is exactly how a "a dialog is up" flag gets stuck. Floating above
    ///   every Qnet window instead keeps the panel's lifetime its own.
    private var picturePanelModality: DSPanelModality {
        host == .pane ? .documentModal : .appModal
    }

    /// Takes the panel away from the outside. `DSPanelWindow.close(id:)`
    /// deliberately does not run `onClose` — the caller is the one removing
    /// the panel, so it already knows — which is why the flag is cleared
    /// here as well.
    private func closePicturePicker() {
        guard showPicturePicker else { return }
        showPicturePicker = false
        DSPanelWindow.close(id: Self.picturePanelID)
    }

    // MARK: - Capacity

    private var stationCapacitySection: some View {
        Section {
            DSNumericField(
                label: "Servers",
                text: $model.serversText,
                range: 1...10_000,
                stepper: 1,
                error: model.serversError,
                help: "Number of identical parallel servers (c ≥ 1)",
                glossary: DS.Glossary.servers,
                placeholder: "1",
                width: DS.Layout.narrowFieldWidth,
                accessibilityLabel: "Number of servers",
                onFocusChange: noteFocus
            )
            stabilityRow
        } header: {
            Text("Capacity")
        } footer: {
            Text(stabilityFooter)
        }
    }

    /// "λ = 1.2 /time · c·μ = 1.5 /time · ρ = 0.8" from a DRAFT copy of
    /// the network: the one number a queueing tool owes the user, shown
    /// where the service rate is typed. Warns (never blocks) at ρ ≥ 0.95;
    /// an unstable station is a legal network, just a bad one.
    private var stabilityRow: some View {
        let s = model.stability
        let rho = s?.utilisation
        let warning: String? = {
            guard let s, let rho else { return nil }
            let r = DS.Number.format(rho, significantDigits: DS.Number.readoutDigits)
            if s.isUnstable {
                return "ρ = \(r) at this rate: \(node.name) is unstable, the queue grows without bound."
            }
            if s.isHeavy {
                return "ρ = \(r): heavy traffic, expect long queues and slow convergence."
            }
            return nil
        }()
        let rhoTint = rho.map { $0 >= 1 ? DS.Color.dangerText : ($0 >= 0.95 ? DS.Color.warningText : DS.Color.textPrimary) }
        return DSInspectorRow(label: "Load",
                              help: s == nil
                                  ? "Utilisation from the traffic equations; add a source and a route to this station to see it"
                                  : "Arrival rate, service capacity and utilisation from the traffic equations, using the values in this inspector",
                              glossary: DS.Glossary.rho,
                              warning: warning) {
            // The sheet has room for the three readouts on one line; the
            // pane (288 pt minimum, minus the label column) does not — a
            // four-digit λ would truncate to "1.2…" or push the row wide.
            // There they stack, one quantity per line, values in a fixed
            // trailing-aligned column so the digits do not jitter as ρ
            // changes.
            if host == .pane {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    readoutStat("λ", s?.arrivalRate, unit: "/time", glossary: DS.Glossary.lambda)
                    readoutStat("c·μ", s?.capacity, unit: "/time", glossary: DS.Glossary.mu)
                    readoutStat("ρ", rho, unit: nil, glossary: DS.Glossary.rho, tint: rhoTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: DS.Spacing.m) {
                    readoutStat("λ", s?.arrivalRate, unit: "/time", glossary: DS.Glossary.lambda)
                    readoutStat("c·μ", s?.capacity, unit: "/time", glossary: DS.Glossary.mu)
                    readoutStat("ρ", rho, unit: nil, glossary: DS.Glossary.rho, tint: rhoTint)
                }
                .frame(height: DS.Layout.controlHeight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stabilityAccessibilityLabel)
    }

    private var stabilityAccessibilityLabel: String {
        guard let s = model.stability, let rho = s.utilisation else {
            return "Load: not available until a source routes jobs to this station"
        }
        let f = { (v: Double) in DS.Number.format(v, significantDigits: DS.Number.readoutDigits) }
        return "Load: arrival rate \(f(s.arrivalRate)) per time, capacity \(f(s.capacity)) per time, utilisation \(f(rho))\(s.isUnstable ? ", unstable" : "")"
    }

    private var stabilityFooter: String {
        if model.stability == nil {
            return "Utilisation ρ = λ / (c·μ) appears once a source routes jobs to this station."
        }
        return "ρ = λ / (c·μ) from the traffic equations, recomputed as you edit. The station is stable while ρ < 1."
    }

    /// One "λ = 1.2345 /time" readout. The value sits in a column of at
    /// least `DS.Layout.readoutWidth`, trailing-aligned, so three stacked
    /// readouts line up and a value growing a digit does not shift its
    /// unit. The unit slot is always present (blank when there is none)
    /// so the three lines share one right edge in the stacked layout.
    private func readoutStat(_ label: String, _ value: Double?, unit: String?, glossary: String,
                             tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xxs) {
            Text("\(label) =")
                .font(DS.Font.numberSmall)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(minWidth: host == .pane ? DS.Layout.compactFieldWidth / 2 : nil, alignment: .leading)
            Text(value.map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "—")
                .font(DS.Font.numberSmallEmphasis)
                .foregroundStyle(value == nil ? DS.Color.textTertiary : (tint ?? DS.Color.textPrimary))
                .lineLimit(1)
                .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
            Text(value != nil ? (unit ?? "") : "")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(minWidth: host == .pane ? DS.Layout.compactFieldWidth / 2 : nil, alignment: .leading)
                .accessibilityHidden(unit == nil || value == nil)
        }
        .help(glossary)
    }

    private var bufferCapacitySection: some View {
        Section {
            DSSegmentedPicker(
                label: "Network buffers",
                selection: $model.infiniteBuffersDraft,
                options: [false, true],
                help: "Applies to every buffer in this network, not only this one",
                width: segmentedWidth
            ) { $0 ? "Infinite" : "Finite" }
            Text("Network-wide setting: Finite enforces each buffer's capacity (blocking / loss); Infinite ignores every capacity limit. Undoable.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            DSNumericField(
                label: "Buffer size",
                text: $model.bufferSizeText,
                unit: "jobs",
                range: 1...1_000_000,
                stepper: 1,
                error: model.infiniteBuffersDraft ? nil : model.bufferSizeError,
                help: model.infiniteBuffersDraft
                    ? "Ignored while network buffers are infinite"
                    : "Maximum number of waiting jobs (≥ 1)",
                glossary: DS.Glossary.bufferSize,
                placeholder: "1",
                width: DS.Layout.narrowFieldWidth,
                accessibilityLabel: "Buffer size",
                onFocusChange: noteFocus
            )
            .disabled(model.infiniteBuffersDraft)
        } header: {
            Text("Capacity")
        }
    }

    // MARK: - Single distribution (source / fallback)

    @ViewBuilder
    private func singleDistributionSection(title: String, footer: String, rateLabel: String) -> some View {
        Section {
            distributionPicker(
                selection: Binding(
                    get: { model.draft.distribution },
                    set: { newValue in
                        model.draft.changeDistribution(to: newValue, mode: model.entryMode)
                    }),
                kind: node.kind,
                showSubtitle: host == .sheet)

            DSSegmentedPicker(
                label: "Enter as",
                selection: Binding(
                    get: { model.entryMode },
                    set: { newMode in
                        guard newMode != model.entryMode else { return }
                        model.draft.syncMode(to: newMode)
                        model.entryMode = newMode
                    }),
                options: ParameterEntryMode.allCases,
                help: "Type the family's native parameters, or a target mean and SCV that are solved into them",
                glossary: DS.Glossary.entryMode,
                width: segmentedWidth
            )

            distributionFields(draft: $model.draft, mode: model.entryMode, rateLabel: rateLabel,
                               classLabel: nil)

            DistributionCard(draft: model.draft, mode: model.entryMode, rateLabel: rateLabel)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    /// Parameter region: always two rows (a hidden filler keeps the height
    /// when the family has one parameter) so switching distributions or
    /// entry modes never changes the form height. Shared by the source /
    /// fallback section and the pane's stacked per-class editor.
    @ViewBuilder
    private func distributionFields(draft: Binding<DistributionDraft>, mode: ParameterEntryMode,
                                    rateLabel: String, classLabel: String?) -> some View {
        let d = draft.wrappedValue
        let prefix = classLabel.map { "\($0) " } ?? ""
        switch mode {
        case .native:
            let errors = d.nativeErrors
            ForEach(d.distribution.parameterDefs, id: \.key) { def in
                DSNumericField(
                    label: def.displayName,
                    text: Binding(get: { draft.wrappedValue.displayParam(def.key) },
                                  set: { draft.wrappedValue.setParam(def.key, $0) }),
                    unit: def.unit,
                    error: errors[def.key],
                    help: def.help,
                    placeholder: DS.Number.fieldText(def.defaultValue),
                    width: numericFieldWidth,
                    accessibilityLabel: prefix + def.displayName,
                    onFocusChange: noteFocus
                )
            }
            if d.distribution.parameterDefs.count < 2 {
                DSInspectorRowPlaceholder()
            }
        case .moments:
            DSNumericField(
                label: "Mean",
                text: draft.displayMeanText,
                unit: "time",
                error: d.meanError,
                help: "Target mean \(rateLabel == "λ" ? "inter-arrival" : "service") time (> 0)",
                glossary: DS.Glossary.mean,
                width: numericFieldWidth,
                accessibilityLabel: prefix + "Mean \(rateLabel == "λ" ? "inter-arrival" : "service") time",
                onFocusChange: noteFocus
            )
            if d.distribution.hasFixedSCV {
                DSInspectorRow(label: "SCV (c²)",
                               help: "Squared coefficient of variation, variance / mean²",
                               glossary: DS.Glossary.scv) {
                    Text("\(DS.Number.format(d.distribution.fixedSCV ?? 0))  (fixed by family)")
                        .font(DS.Font.number)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(height: DS.Layout.controlHeight)
                }
            } else {
                DSNumericField(
                    label: "SCV (c²)",
                    text: draft.displayScvText,
                    unit: d.distribution.hasDiscreteSCV ? "→ 1/k" : nil,
                    error: d.scvError,
                    help: d.distribution.hasDiscreteSCV
                        ? "Erlang snaps the SCV to the nearest 1/k"
                        : "Squared coefficient of variation, variance / mean²",
                    glossary: DS.Glossary.scv,
                    width: numericFieldWidth,
                    accessibilityLabel: prefix + "Squared coefficient of variation",
                    onFocusChange: noteFocus
                )
            }
        }
    }

    // MARK: - Per-class service: stacked editor (pane)

    /// The narrow host's per-class editor: a class picker over ONE set of
    /// distribution fields bound to the active class's draft. Same
    /// drafts, same validation, same bulk actions as the sheet's table —
    /// only the arrangement differs.
    private var stackedClassServiceSection: some View {
        let active = model.activeClassRow ?? model.servedClasses.first ?? 0
        let activeBinding = Binding<DistributionDraft>(
            get: { model.classDrafts[active] ?? .defaults(.exponential) },
            set: { model.classDrafts[active] = $0 })
        return Section {
            DSMenuPicker(
                label: "Class",
                selection: Binding(get: { active }, set: { model.activeClassRow = $0 }),
                options: model.servedClasses,
                help: "Which customer class's service law the fields below edit",
                glossary: DS.Glossary.customerClass,
                width: DS.Layout.fieldWidth
            ) { idx in
                ClassChip(classIndex: idx)
            }

            distributionPicker(
                selection: Binding(
                    get: { activeBinding.wrappedValue.distribution },
                    set: { newValue in
                        activeBinding.wrappedValue.changeDistribution(to: newValue, mode: model.classEntryMode)
                    }),
                kind: .station,
                showSubtitle: false)

            entryModePicker

            distributionFields(draft: activeBinding, mode: model.classEntryMode, rateLabel: "μ",
                               classLabel: CustomerClass.label(for: active))

            DistributionCard(draft: activeBinding.wrappedValue, mode: model.classEntryMode, rateLabel: "μ",
                             title: "\(CustomerClass.label(for: active)) — \(activeBinding.wrappedValue.distribution.pickerName)",
                             arrivalRate: model.stability?.arrivalRatePerClass[active])
        } header: {
            HStack(spacing: DS.Spacing.s) {
                Text("Service Time per Class")
                Spacer()
                bulkActionsMenu
            }
        } footer: {
            Text(classSectionFooter)
        }
    }

    private var classSectionFooter: String {
        let n = model.servedClasses.count
        let settled = model.servedClasses.compactMap { c -> String? in
            guard let d = model.classDrafts[c],
                  let e = model.settledErrors(d, mode: model.classEntryMode).first else { return nil }
            return "\(CustomerClass.label(for: c)): \(e)"
        }
        if let first = settled.first, host == .pane { return first }
        return "\(n) class\(n == 1 ? "" : "es") served here. Mean, SCV and μ = 1/mean update as you type."
    }

    private var entryModePicker: some View {
        DSSegmentedPicker(
            label: "Enter as",
            selection: Binding(
                get: { model.classEntryMode },
                set: { newMode in
                    guard newMode != model.classEntryMode else { return }
                    for key in model.classDrafts.keys { model.classDrafts[key]?.syncMode(to: newMode) }
                    model.classEntryMode = newMode
                }),
            options: ParameterEntryMode.allCases,
            help: "Entry mode for every class: native parameters, or mean and SCV",
            glossary: DS.Glossary.entryMode,
            width: host == .pane ? nil : DS.Layout.fieldWidth + DS.Spacing.xl
        )
    }

    /// The scope is in the title: "5 other classes", not "all classes" —
    /// a bulk action must say how much it is about to overwrite before
    /// it is chosen.
    private var bulkActionsMenu: some View {
        Menu {
            if let first = model.servedClasses.first {
                let n = model.otherClassCount(excluding: first)
                Button("Copy \(CustomerClass.label(for: first)) to \(n) Other Class\(n == 1 ? "" : "es")") {
                    model.copyToAllClasses(from: first)
                }
                .disabled(n == 0)
            }
            Button("Exponential (rate 1) for All \(model.servedClasses.count) Classes") {
                model.applyToAllClasses(.defaults(.exponential), named: "Exponential (rate 1)")
            }
        } label: {
            Label("Apply", systemImage: DS.Symbol.more)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Bulk actions for every class row")
    }

    // MARK: - Per-class service: table (sheet)

    private var perClassServiceSection: some View {
        Section {
            serviceTable
                .dsRowLayout(.bare)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Service time per class table, \(model.servedClasses.count) rows")

            if let classIdx = model.activeClassRow ?? model.servedClasses.first,
               let rowDraft = model.classDrafts[classIdx] {
                DistributionCard(draft: rowDraft, mode: model.classEntryMode, rateLabel: "μ",
                                 title: "\(CustomerClass.label(for: classIdx)) — \(rowDraft.distribution.pickerName)",
                                 arrivalRate: model.stability?.arrivalRatePerClass[classIdx])
            }
        } header: {
            HStack(spacing: DS.Spacing.s) {
                Text("Service Time per Class")
                Spacer()
                // The same control the single-distribution section uses,
                // in `.bare` row layout at the table's control size.
                entryModePicker
                    .dsRowLayout(.bare)
                    .controlSize(.small)
                bulkActionsMenu
            }
        } footer: {
            Text("One row per customer class served here. λ is the class's arrival rate at this station; mean, SCV and μ = 1/mean update as you type. ↑ / ↓ move between rows.")
        }
    }

    // Column widths. Fixed for every column but Parameters, which takes
    // the surplus, so the distribution menu stays beside its heading and
    // the readouts beside their numbers at any sheet width.
    private var classColumnWidth: CGFloat { DS.Layout.narrowFieldWidth - DS.Spacing.l }
    private var distributionColumnWidth: CGFloat { DS.Layout.fieldWidth }
    private var readoutColumnWidth: CGFloat { DS.Layout.readoutWidth }

    /// The per-class table: a header row, then one focusable row per
    /// class with a reserved caption row of EXACT height beneath it
    /// (`DS.Layout.tableMessageHeight`), so a settled error appearing
    /// never shifts the table by a point.
    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                headerCell("Class", width: classColumnWidth)
                headerCell("Distribution", width: distributionColumnWidth)
                headerCell(model.classEntryMode == .native ? "Parameters" : "Mean · SCV", flexible: true)
                headerCell("λ", width: readoutColumnWidth, alignment: .trailing, help: DS.Glossary.lambda)
                headerCell("Mean", width: readoutColumnWidth, alignment: .trailing, help: DS.Glossary.mean)
                headerCell("SCV", width: readoutColumnWidth, alignment: .trailing, help: DS.Glossary.scv)
                headerCell("μ", width: readoutColumnWidth, alignment: .trailing, help: DS.Glossary.mu)
                Color.clear
                    .frame(width: DS.Layout.iconButtonWidth + DS.Spacing.s, height: DS.Spacing.xs)
                    .accessibilityHidden(true)
            }
            DSRule()

            ForEach(Array(model.servedClasses.enumerated()), id: \.element) { index, classIdx in
                serviceTableRow(classIdx: classIdx)
                if index < model.servedClasses.count - 1 {
                    DSRule()
                }
            }
        }
        .onChange(of: focusedClassRow) { _, row in
            if let row { model.activeClassRow = row }
        }
    }

    /// `help` carries the DS.Glossary entry for a jargon-only column
    /// heading (λ, μ, SCV) — the bar's "no jargon-only label without
    /// help" rule applies to table headings too.
    private func headerCell(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading,
                            flexible: Bool = false, help: String? = nil) -> some View {
        Text(title)
            .font(DS.Font.tableHeader)
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: flexible ? .infinity : nil, alignment: alignment)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.s)
            .help(help ?? title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(help.map { "\(title). \($0)" } ?? title)
    }

    /// One class: a focusable row of cells (one accessibility element,
    /// named by its class) plus a caption row of fixed height carrying
    /// the row's settled messages, also named by its class so VoiceOver
    /// hears "Class 1: Rate must be greater than 0" where it belongs.
    ///
    /// Messages are filtered through `pendingKeys`, exactly as
    /// `settledErrors` filters the footer's: a half-typed number is not a
    /// mistake, so nothing turns red while the footer simultaneously
    /// says "Still typing Class 1 Rate".
    @ViewBuilder
    private func serviceTableRow(classIdx: Int) -> some View {
        let rowDraft = model.classDrafts[classIdx] ?? .defaults(.exponential)
        let errors = rowDraft.errors(for: model.classEntryMode)
        let moments = rowDraft.moments(for: model.classEntryMode)
        let settled = model.settledErrors(rowDraft, mode: model.classEntryMode)
        let rowMessage: String? = settled.isEmpty ? nil : settled.joined(separator: "  ")
        let isActive = (model.activeClassRow ?? model.servedClasses.first) == classIdx
        let className = CustomerClass.label(for: classIdx)
        let lambda = model.stability?.arrivalRatePerClass[classIdx]

        HStack(spacing: 0) {
            tableCell(isActive: isActive, activates: classIdx) {
                ClassChip(classIndex: classIdx)
                    .frame(width: classColumnWidth, alignment: .leading)
            }

            tableCell(isActive: isActive) {
                distributionPicker(
                    selection: Binding(
                        get: { model.classDrafts[classIdx]?.distribution ?? .exponential },
                        set: { newValue in
                            model.classDrafts[classIdx, default: .defaults(.exponential)]
                                .changeDistribution(to: newValue, mode: model.classEntryMode)
                            model.activeClassRow = classIdx
                        }),
                    kind: .station,
                    showSubtitle: false)
                .frame(width: distributionColumnWidth)
                .controlSize(.small)
            }

            tableCell(isActive: isActive, activates: classIdx, flexible: true) {
                HStack(spacing: DS.Spacing.s) {
                    switch model.classEntryMode {
                    case .native:
                        ForEach(rowDraft.distribution.parameterDefs, id: \.key) { def in
                            compactField(label: def.shortLabel,
                                         text: classParamBinding(classIdx, def.key),
                                         classIdx: classIdx,
                                         error: errors[def.key],
                                         help: def.help,
                                         accessibility: "\(className) \(def.displayName)")
                        }
                    case .moments:
                        compactField(label: "m",
                                     text: classMomentBinding(classIdx, keyPath: \.displayMeanText),
                                     classIdx: classIdx,
                                     error: errors[DistributionDraft.meanKey],
                                     help: "Mean service time (> 0)",
                                     accessibility: "\(className) mean")
                        if rowDraft.distribution.hasFixedSCV {
                            Text("c² = \(DS.Number.format(rowDraft.distribution.fixedSCV ?? 0))")
                                .font(DS.Font.numberCaption)
                                .foregroundStyle(DS.Color.textSecondary)
                                .frame(minWidth: DS.Layout.compactFieldWidth, alignment: .leading)
                                .help("SCV fixed by the \(rowDraft.distribution.displayName) family")
                        } else {
                            compactField(label: "c²",
                                         text: classMomentBinding(classIdx, keyPath: \.displayScvText),
                                         classIdx: classIdx,
                                         error: errors[DistributionDraft.scvKey],
                                         help: "Squared coefficient of variation (≥ 0)",
                                         accessibility: "\(className) SCV")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            numberCell(lambda, isActive: isActive, activates: classIdx,
                       accessibility: "\(className) arrival rate λ")
            numberCell(moments.mean, isActive: isActive, activates: classIdx,
                       accessibility: "\(className) mean")
            numberCell(moments.scv, isActive: isActive, activates: classIdx,
                       accessibility: "\(className) SCV")
            numberCell(moments.mean.flatMap { $0 > 0 ? 1.0 / $0 : nil }, isActive: isActive, activates: classIdx,
                       accessibility: "\(className) service rate μ")

            tableCell(isActive: isActive) {
                DSIconMenu(systemImage: DS.Symbol.more,
                           label: "\(className) row actions",
                           help: "Actions for the \(className) row") {
                    let others = model.otherClassCount(excluding: classIdx)
                    Button("Copy \(className) to \(others) Other Class\(others == 1 ? "" : "es")") {
                        model.copyToAllClasses(from: classIdx)
                    }
                    .disabled(others == 0)
                    Button("Reset \(className) to Exponential (rate 1)") {
                        model.classDrafts[classIdx] = .defaults(.exponential)
                    }
                }
            }
        }
        // The active-row accent rule IS the focus indication: a focused
        // row is always the active one (`focusedClassRow` → `activeClassRow`
        // in `serviceTable`), so the system ring is off for good rather
        // than drawn on top of the rule.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isActive ? DS.Color.accent : Color.clear)
                .frame(width: DS.Stroke.selection)
                .accessibilityHidden(true)
        }
        // `.activate` only: the row is reachable with ↑ / ↓ and under
        // Full Keyboard Access, but is NOT a stop in the Tab chain — Tab
        // goes field → field → next row's field, one stop per control,
        // not one extra per class.
        .focusable(interactions: .activate)
        .focused($focusedClassRow, equals: classIdx)
        .focusEffectDisabled()
        // ↑ / ↓ switch rows only while no text field is being edited:
        // inside a field the keys belong to the field editor (line ends,
        // and the stepper where there is one).
        .onKeyPress(.upArrow) { moveRowFocus(from: classIdx, offset: -1) }
        .onKeyPress(.downArrow) { moveRowFocus(from: classIdx, offset: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(className) row")
        .accessibilityAddTraits(isActive ? .isSelected : [])

        // Always present, always the same height: the caption slot the
        // `.bare` layout does not give us. Exact height, one line,
        // truncated, with the full text in the tooltip.
        InlineFieldMessage(message: rowMessage, lineLimit: 1)
            .padding(.horizontal, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DS.Layout.tableMessageHeight, alignment: .topLeading)
            .background(isActive ? DS.Color.subtleFill : Color.clear)
            .help(rowMessage ?? "")
            .accessibilityLabel(rowMessage.map { "\(className): \($0)" } ?? "")
            .accessibilityHidden(rowMessage == nil)
    }

    private func moveRowFocus(from classIdx: Int, offset: Int) -> KeyPress.Result {
        guard model.fieldFocusCount == 0 else { return .ignored }
        guard let i = model.servedClasses.firstIndex(of: classIdx) else { return .ignored }
        let j = i + offset
        guard model.servedClasses.indices.contains(j) else { return .ignored }
        focusedClassRow = model.servedClasses[j]
        return .handled
    }

    /// One padded table cell. `activates` makes a click on the cell select
    /// that class row (drives the distribution card below the table).
    private func tableCell<Content: View>(
        isActive: Bool,
        activates classIdx: Int? = nil,
        flexible: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: flexible ? .infinity : nil, maxHeight: .infinity, alignment: .leading)
            .background(isActive ? DS.Color.subtleFill : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if let classIdx { model.activeClassRow = classIdx }
            }
    }

    /// Right-aligned readout cell (λ / mean / SCV / μ) with monospaced
    /// digits and a fixed width so the column never reflows.
    private func numberCell(_ value: Double?, isActive: Bool, activates classIdx: Int, accessibility: String) -> some View {
        tableCell(isActive: isActive, activates: classIdx) {
            Group {
                if let value {
                    if value.isInfinite {
                        Text("∞").foregroundStyle(DS.Color.warningText)
                    } else {
                        Text(DS.Number.format(value, significantDigits: DS.Number.readoutDigits))
                    }
                } else {
                    Text("—").foregroundStyle(DS.Color.textTertiary)
                }
            }
            .font(DS.Font.number)
            .lineLimit(1)
            .frame(width: readoutColumnWidth, alignment: .trailing)
            .accessibilityLabel("\(accessibility): \(value.map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "unknown")")
        }
    }

    /// Caption + compact DSNumericField for one cell of the per-class table.
    /// Focusing the field makes its row the active one (drives the card).
    private func compactField(label: String, text: Binding<String>, classIdx: Int, error: String?, help: String, accessibility: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
            DSNumericField(
                label: accessibility,
                text: text,
                error: error,
                help: help,
                width: DS.Layout.compactFieldWidth,
                accessibilityLabel: accessibility,
                onFocusChange: { focused in
                    if focused { model.activeClassRow = classIdx }
                    noteFocus(focused)
                }
            )
        }
        .help(help)
    }

    private func classParamBinding(_ classIdx: Int, _ key: String) -> Binding<String> {
        Binding(
            get: { model.classDrafts[classIdx]?.displayParam(key) ?? "" },
            set: { model.classDrafts[classIdx, default: .defaults(.exponential)].setParam(key, $0) }
        )
    }

    private func classMomentBinding(_ classIdx: Int, keyPath: WritableKeyPath<DistributionDraft, String>) -> Binding<String> {
        Binding(
            get: { model.classDrafts[classIdx]?[keyPath: keyPath] ?? "" },
            set: { model.classDrafts[classIdx, default: .defaults(.exponential)][keyPath: keyPath] = $0 }
        )
    }

    /// Menu picker whose rows read "Gamma   c² = 1/k" with the family symbol.
    /// Full-width row with subtitles in the sheet's single-distribution
    /// section; a compact label-less menu inside the per-class table and
    /// the pane.
    private func distributionPicker(selection: Binding<QueueDistribution>, kind: NodeKind, showSubtitle: Bool) -> some View {
        DSMenuPicker(
            label: "Distribution",
            selection: selection,
            options: QueueDistribution.cases(for: kind),
            help: "Probability law of the \(kind == .source ? "inter-arrival" : "service") time",
            glossary: DS.Glossary.distribution,
            width: showSubtitle ? menuWidth : (host == .pane ? DS.Layout.fieldWidth : nil)
        ) { option in
            Label {
                if showSubtitle {
                    Text(option.pickerName) + Text("   \(option.menuSubtitle)").foregroundStyle(DS.Color.textSecondary)
                } else {
                    Text(option.displayName)
                }
            } icon: {
                Image(systemName: option.symbol)
            }
        }
    }

    // MARK: - Routing

    /// Every link attached to this node: outgoing first (one row per
    /// link, activatable — the mirror of the link inspector's sibling
    /// table), a per-class total with the same unbalanced wording, then
    /// the incoming links dimmed and read-only.
    private var routingSection: some View {
        let attached = editor.linksAttached(to: node.id)
        let outgoing = attached.filter { $0.fromNodeID == node.id }
        let incoming = attached.filter { $0.fromNodeID != node.id }
        let classes = Array(Set(outgoing.map(\.customerClass))).sorted()
        let totals: [(cls: Int, total: Double)] = classes.map { c in
            (c, outgoing.filter { $0.customerClass == c }.reduce(0.0) { $0 + $1.routingProbability })
        }
        let unbalanced = totals.filter { abs($0.total - 1) > 1e-6 }

        return Section {
            if attached.isEmpty {
                Text("No links yet — draw one with the Link tool (L).")
                    .foregroundStyle(DS.Color.textSecondary)
            } else {
                VStack(spacing: 0) {
                    if !outgoing.isEmpty {
                        routingGroupHeader("Outgoing")
                        ForEach(outgoing) { link in
                            RoutingLinkRow(
                                link: link,
                                otherNodeName: editor.node(with: link.toNodeID)?.name ?? "?",
                                direction: .outgoing,
                                action: onOpenLink.map { open in { open(link.id) } })
                            DSRule()
                        }
                        ForEach(totals, id: \.cls) { entry in
                            HStack(spacing: DS.Spacing.s) {
                                ClassChip(classIndex: entry.cls, compact: true)
                                    .font(DS.Font.caption)
                                Text("total")
                                    .font(DS.Font.chromeEmphasis)
                                Spacer()
                                Text(DS.Number.format(entry.total, significantDigits: DS.Number.readoutDigits))
                                    .font(DS.Font.numberSmallEmphasis)
                                    .foregroundStyle(abs(entry.total - 1) > 1e-6 ? DS.Color.warningText : DS.Color.textPrimary)
                                    .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
                                Image(systemName: DS.Symbol.disclosure)
                                    .font(DS.Font.chevron)
                                    .hidden()
                            }
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.vertical, DS.Spacing.xs)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(CustomerClass.label(for: entry.cls)) total \(DS.Number.format(entry.total, significantDigits: DS.Number.readoutDigits))")
                        }
                    }
                    if !incoming.isEmpty {
                        if !outgoing.isEmpty { DSRule() }
                        routingGroupHeader("Incoming")
                        ForEach(Array(incoming.enumerated()), id: \.element.id) { index, link in
                            RoutingLinkRow(
                                link: link,
                                otherNodeName: editor.node(with: link.fromNodeID)?.name ?? "?",
                                direction: .incoming,
                                action: nil)
                            if index < incoming.count - 1 { DSRule() }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Links at \(node.name): \(outgoing.count) outgoing, \(incoming.count) incoming")

                InlineFieldMessage(message: unbalanced.first.map { entry in
                    let t = DS.Number.format(entry.total, significantDigits: DS.Number.readoutDigits)
                    if entry.total > 1 {
                        return "Routing from \(node.name) for \(CustomerClass.label(for: entry.cls)) sums to \(t), which exceeds 1. Lower one of the links."
                    }
                    let missing = DS.Number.format((1 - entry.total) * 100, significantDigits: DS.Number.readoutDigits)
                    return "Routing from \(node.name) for \(CustomerClass.label(for: entry.cls)) sums to \(t); \(missing)% of jobs have no route."
                }, severity: .warning)
                .frame(minHeight: DS.Spacing.l, alignment: .leading)
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                Text("Routing")
                DSGlossaryButton(label: "Routing", text: DS.Glossary.routingProbability)
            }
        } footer: {
            Text(outgoing.isEmpty
                 ? "Links are edited in the link inspector: click an arrow on the canvas, or ⌥⇥ through this node's links."
                 : "Probabilities of the links leaving a node for one class should sum to 1. Click an outgoing link to edit it.")
        }
    }

    private func routingGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.tableHeader)
            .foregroundStyle(DS.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Routing row

/// One link in the node inspector's Routing table: class chip, arrow,
/// the node at the other end, an exit-class tag when the link changes
/// class, and the probability. Outgoing rows are buttons that open the
/// link; incoming rows are dimmed and read-only.
private struct RoutingLinkRow: View {
    enum Direction { case outgoing, incoming }

    let link: NetworkLink
    let otherNodeName: String
    let direction: Direction
    let action: (() -> Void)?

    @State private var isHovering = false
    @DSAccessibility private var a11y

    private var probabilityText: String {
        DS.Number.format(link.routingProbability, significantDigits: DS.Number.readoutDigits)
    }

    private var spokenLabel: String {
        let dir = direction == .outgoing ? "to \(otherNodeName)" : "from \(otherNodeName)"
        var text = "\(CustomerClass.label(for: link.customerClass)) \(dir), probability \(probabilityText)"
        if link.hasClassTransition { text += ", becomes \(CustomerClass.label(for: link.exitClass))" }
        return text
    }

    var body: some View {
        let row = HStack(spacing: DS.Spacing.s) {
            ClassChip(classIndex: link.customerClass, compact: true)
                .font(DS.Font.caption)
            Image(systemName: DS.Symbol.link)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityHidden(true)
            Text(otherNodeName)
                .font(DS.Font.chrome)
                .lineLimit(1)
            if link.hasClassTransition {
                ExitClassTag(exitClass: link.exitClass)
            }
            Spacer()
            Text(probabilityText)
                .font(DS.Font.numberSmall)
                .foregroundStyle(DS.Color.textPrimary)
                .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
            Image(systemName: DS.Symbol.disclosure)
                .font(DS.Font.chevron)
                .foregroundStyle(DS.Color.textTertiary)
                .opacity(action == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) {
                row.background(isHovering ? DS.Color.hoverFill(a11y.contrast) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
            }
            .help("Edit the link to \(otherNodeName) in the link inspector")
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Opens this link in the link inspector")
        } else {
            row
                .foregroundStyle(DS.Color.textSecondary)
                .help("Incoming from \(otherNodeName); edit it from that node or by clicking the arrow")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenLabel)
        }
    }
}

// MARK: - Distribution card

/// Compact card under a distribution picker: family symbol and name,
/// the density formula, the live mean / SCV / rate in monospaced digits,
/// the class's arrival rate when known, and the closed-form moment
/// formulas.
struct DistributionCard: View {
    let draft: DistributionDraft
    let mode: ParameterEntryMode
    let rateLabel: String
    var title: String? = nil
    /// The class's arrival rate at this station (per-class λ), so the μ
    /// readout has something to be compared against.
    var arrivalRate: Double? = nil

    var body: some View {
        let moments = draft.moments(for: mode)
        let dist = draft.distribution

        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: dist.symbol)
                    .foregroundStyle(DS.Color.infoText)
                    .accessibilityHidden(true)
                Text(title ?? dist.pickerName)
                    .font(DS.Font.chromeEmphasis)
                    .lineLimit(1)
                Spacer()
                if mode == .moments {
                    Text("native: \(draft.compactSummary())")
                        .font(DS.Font.numberCaption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Text(dist.formulaDescription)
                .font(DS.Font.monoCaption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: DS.Spacing.l) {
                stat("mean", moments.mean, unit: "time")
                stat("SCV", moments.scv, unit: nil)
                stat(rateLabel, moments.mean.flatMap { $0 > 0 ? 1.0 / $0 : nil }, unit: "1/time")
                if let arrivalRate, rateLabel == "μ" {
                    stat("λ", arrivalRate, unit: "1/time")
                }
                Spacer()
            }

            Text("\(dist.meanFormula)    \(dist.scvFormula)")
                .font(DS.Font.monoCaption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Color.subtleFill)
        )
        .accessibilityElement(children: .combine)
    }

    /// Plain-language explanation of every stat label. λ and μ are drawn
    /// here with nothing beside them, which is exactly the "jargon-only
    /// label" the design guide requires help for; "mean" and "SCV" get
    /// the same glossary entries the fields above them use.
    private func statGlossary(_ label: String) -> String {
        switch label {
        case "λ":    return DS.Glossary.lambda
        case "μ":    return DS.Glossary.mu
        case "mean": return DS.Glossary.mean
        case "SCV":  return DS.Glossary.scv
        default:     return "\(label) of the \(draft.distribution.displayName) family at these parameters"
        }
    }

    private func stat(_ label: String, _ value: Double?, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text("\(label) =")
                .font(DS.Font.number)
                .foregroundStyle(DS.Color.textSecondary)
                .help(statGlossary(label))
            if let value {
                if value.isInfinite {
                    Text("∞")
                        .font(DS.Font.numberEmphasis)
                        .foregroundStyle(DS.Color.warningText)
                } else {
                    Text(DS.Number.format(value, significantDigits: DS.Number.readoutDigits))
                        .font(DS.Font.numberEmphasis)
                        .foregroundStyle(DS.Color.textPrimary)
                }
            } else {
                Text("—")
                    .font(DS.Font.number)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            if let unit, value != nil {
                Text(unit)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .accessibilityLabel("\(label) \(value.map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "unknown")")
        .accessibilityHint(statGlossary(label))
    }
}
