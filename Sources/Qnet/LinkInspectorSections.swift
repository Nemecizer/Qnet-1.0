import SwiftUI

// MARK: - Draft

/// Everything the link inspector edits, shared by the modal
/// `LinkParameterEditorSheet` (commits on Save) and the docked
/// `InspectorPaneView` (commits on blur). See `NodeParameterDraft` for
/// the load / dirty / commit contract; this is the same shape for a link.
@MainActor
final class LinkParameterDraft: ObservableObject {
    @Published private(set) var linkID: UUID?
    @Published var probabilityText: String = "1"
    @Published var selectedClass: Int = 0
    /// `sameAsEntry` = no class transition; otherwise the exit class
    /// index (may equal the class count, meaning "new derived class").
    @Published var exitSelection: Int = LinkParameterDraft.sameAsEntry
    /// See `NodeParameterDraft.fieldFocusCount`.
    @Published var fieldFocusCount: Int = 0

    nonisolated static let sameAsEntry = -1

    private struct Snapshot: Equatable {
        var probability = ""
        var entryClass = 0
        var exit = -1
    }
    private var baseline = Snapshot()

    init() {}

    private var current: Snapshot {
        Snapshot(probability: probabilityText, entryClass: selectedClass, exit: exitSelection)
    }

    func load(from editor: NetworkEditorModel, linkID: UUID) {
        self.linkID = linkID
        fieldFocusCount = 0
        guard let link = editor.link(with: linkID) else { return }
        probabilityText = DS.Number.fieldText(link.routingProbability)
        selectedClass = link.customerClass
        exitSelection = link.toCustomerClass ?? Self.sameAsEntry
        baseline = current
    }

    /// Put the fields back to the loaded (or last committed) values —
    /// Escape in the docked pane. See `NodeParameterDraft.revertToBaseline`.
    func revertToBaseline() {
        guard linkID != nil else { return }
        probabilityText = baseline.probability
        selectedClass = baseline.entryClass
        exitSelection = baseline.exit
    }

    /// True when the draft differs from what is stored on the link.
    func isDirty(editor: NetworkEditorModel) -> Bool {
        guard let linkID, let link = editor.link(with: linkID) else { return false }
        let storedExit = link.toCustomerClass ?? Self.sameAsEntry
        if selectedClass != link.customerClass || exitSelection != storedExit { return true }
        guard let p = DS.Number.parse(probabilityText) else {
            return probabilityText != DS.Number.fieldText(link.routingProbability)
        }
        return abs(p - link.routingProbability) > 1e-12
    }

    /// The single changed field for undo coalescing, or nil.
    var changedFieldKey: String? {
        let a = current, b = baseline
        var keys: [String] = []
        if a.probability != b.probability { keys.append("probability") }
        if a.entryClass != b.entryClass { keys.append("entryClass") }
        if a.exit != b.exit { keys.append("exit") }
        return keys.count == 1 ? keys[0] : nil
    }

    var effectiveExitClass: Int? {
        exitSelection == Self.sameAsEntry ? selectedClass : exitSelection
    }

    // MARK: Validation

    var probabilityError: String? {
        guard let p = DS.Number.parse(probabilityText) else { return "Enter a number between 0 and 1." }
        if p < 0 || p > 1 { return "Probability must be between 0 and 1." }
        return nil
    }

    /// True while "0." / "" / "1e-" is in the probability field: the value
    /// is incomplete, so Save stays disabled, but nothing turns red.
    var probabilityIsPending: Bool {
        DS.Number.parse(probabilityText) == nil && DS.Number.isPartialNumber(probabilityText)
    }

    var pendingNote: String? {
        probabilityIsPending ? "Still typing Probability" : nil
    }

    func firstProblem(editor: NetworkEditorModel) -> String? {
        guard let linkID else { return nil }
        if !probabilityIsPending, let e = probabilityError { return e }
        if editor.entryClassesUsedByOtherLinks(onPairOf: linkID).contains(selectedClass) {
            return "\(CustomerClass.label(for: selectedClass)) is already carried by another link between these nodes."
        }
        return nil
    }

    func isValid(editor: NetworkEditorModel) -> Bool {
        firstProblem(editor: editor) == nil && pendingNote == nil
    }

    // MARK: Commit

    /// Commit the draft as one undo step ("Edit Link S1 → S2"). Returns
    /// false when the draft is invalid (nothing is written).
    @discardableResult
    func commit(to editor: NetworkEditorModel, coalescing: Bool = false) -> Bool {
        guard let linkID, let link = editor.link(with: linkID), isValid(editor: editor),
              let probability = DS.Number.parse(probabilityText) else { return false }
        let label = editor.displayLabel(for: link)
        guard isDirty(editor: editor) else {
            if !coalescing { editor.addStatus("No changes to link \(label).") }
            return true
        }

        var changes: [String] = []
        if abs(probability - link.routingProbability) > 1e-12 {
            changes.append("probability \(DS.Number.format(link.routingProbability, significantDigits: DS.Number.readoutDigits)) → \(DS.Number.format(probability, significantDigits: DS.Number.readoutDigits))")
        }
        if selectedClass != link.customerClass {
            changes.append("entry class → \(CustomerClass.label(for: selectedClass))")
        }
        let newExit: Int? = exitSelection == Self.sameAsEntry ? nil : exitSelection
        if newExit != link.toCustomerClass {
            changes.append(newExit.map { "exit class → \(CustomerClass.label(for: $0))" } ?? "exit class cleared")
        }
        let summary = changes.isEmpty ? nil : "Edited link \(label): " + changes.joined(separator: "; ") + "."

        let mutation: () -> Void = { [self] in
            editor.updateLinkProbability(linkID: linkID, probability: probability)
            editor.updateLinkCustomerClass(linkID: linkID, customerClass: selectedClass)
            editor.updateLinkExitClass(linkID: linkID, exitClass: newExit)
        }
        let name = "Edit Link \(label)"
        let changed: Bool
        if coalescing, let key = changedFieldKey {
            changed = editor.performCoalescedParameterEdit(key: "\(linkID.uuidString).\(key)",
                                                           name: name, summary: summary, mutation)
        } else {
            editor.endParameterRun()
            changed = editor.performParameterEdit(name, summary: summary, mutation)
        }
        if !changed, !coalescing {
            editor.addStatus("No changes to link \(label).")
        }
        baseline = current
        return true
    }
}

// MARK: - Sections

/// The link inspector's sections — Routing (probability, sibling table,
/// Balance to 1) and Customer class (entry / exit) — rendered identically
/// by the sheet and the docked pane. `onOpenSibling` is what a sibling
/// row does when activated.
struct LinkInspectorSections: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject var model: LinkParameterDraft
    let link: NetworkLink
    let host: InspectorHost
    var probabilityFocus: FocusState<Bool>.Binding
    var onOpenSibling: ((UUID) -> Void)? = nil

    @DSAccessibility private var a11y

    var body: some View {
        routingSection
        classSection
    }

    private func noteFocus(_ focused: Bool) {
        model.fieldFocusCount = max(0, model.fieldFocusCount + (focused ? 1 : -1))
    }

    // MARK: Routing

    private var routingSection: some View {
        let fromName = editor.node(with: link.fromNodeID)?.name ?? "?"
        let siblings = siblingLinks
        let thisProbability = DS.Number.parse(model.probabilityText)
        let siblingSum = siblings.reduce(0.0) { $0 + $1.routingProbability }
        let total = siblingSum + (thisProbability ?? 0)

        return Section {
            DSNumericField(
                label: "Probability",
                text: $model.probabilityText,
                range: 0...1,
                stepper: 0.05,
                error: model.probabilityError,
                help: "Fraction of \(CustomerClass.label(for: model.selectedClass)) jobs leaving \(fromName) that follow this link (0 – 1)",
                glossary: DS.Glossary.routingProbability,
                placeholder: "1",
                width: DS.Layout.narrowFieldWidth,
                accessibilityLabel: "Routing probability",
                focus: probabilityFocus,
                onFocusChange: noteFocus
            )

            // Sibling context: every other link that shares this link's
            // origin and entry class, plus the running total. Sibling rows
            // are buttons that switch the inspector to that link.
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Routing from \(fromName) for \(CustomerClass.label(for: model.selectedClass))")
                    .font(DS.Font.tableHeader)
                    .foregroundStyle(DS.Color.textSecondary)
                VStack(spacing: 0) {
                    ForEach(siblings) { sibling in
                        SiblingLinkRow(
                            label: editor.displayLabel(for: sibling),
                            value: sibling.routingProbability,
                            exitClass: sibling.hasClassTransition ? sibling.exitClass : nil,
                            action: onOpenSibling.map { open in { open(sibling.id) } }
                        )
                        DSRule()
                    }
                    currentLinkRow(
                        label: "\(editor.displayLabel(for: link))  (this link)",
                        value: thisProbability,
                        exitClass: model.effectiveExitClass != model.selectedClass ? model.effectiveExitClass : nil)
                    DSRule()
                    HStack(spacing: DS.Spacing.s) {
                        Text("Total")
                            .font(DS.Font.chromeEmphasis)
                        Spacer()
                        balanceButton(siblingSum: siblingSum, total: total, fromName: fromName)
                        Text(DS.Number.format(total, significantDigits: DS.Number.readoutDigits))
                            .font(DS.Font.numberSmallEmphasis)
                            .foregroundStyle(totalIsUnbalanced(total) ? DS.Color.warningText : DS.Color.textPrimary)
                            .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
                    }
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.vertical, DS.Spacing.xs)
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sibling links table, total \(DS.Number.format(total, significantDigits: DS.Number.readoutDigits))")

                InlineFieldMessage(message: totalMessage(total: total, fromName: fromName, siblingCount: siblings.count),
                                   severity: .warning)
                    .frame(minHeight: DS.Spacing.l, alignment: .leading)
            }
        } header: {
            Text("Routing")
        } footer: {
            Text(siblings.isEmpty
                 ? "Probabilities of all links leaving a node for the same class should sum to 1."
                 : "Probabilities of all links leaving a node for the same class should sum to 1. Click a sibling link to edit it here.")
        }
    }

    /// The emphasised, non-interactive row for the link being edited.
    private func currentLinkRow(label: String, value: Double?, exitClass: Int?) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(label)
                .font(DS.Font.chromeEmphasis)
                .lineLimit(1)
            if let exitClass {
                ExitClassTag(exitClass: exitClass)
            }
            Spacer()
            Text(value.map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "—")
                .font(DS.Font.numberSmallEmphasis)
                .foregroundStyle(value == nil ? DS.Color.textTertiary : DS.Color.textPrimary)
                .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
            // Keeps the number column aligned with the sibling rows' chevron.
            Image(systemName: DS.Symbol.disclosure)
                .font(DS.Font.chevron)
                .hidden()
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Color.selectionFill(a11y.contrast))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), probability \(value.map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "not a number")")
    }

    private func totalIsUnbalanced(_ total: Double) -> Bool {
        abs(total - 1.0) > 1e-6
    }

    /// "Balance to 1": set *this* link's probability to whatever the
    /// siblings leave over. Deliberately touches nothing but this field
    /// — the sibling values are the user's. Disabled (with a tooltip that
    /// says why) when the siblings already sum to more than 1. Always
    /// drawn, never inserted or removed, so the Total row does not jump.
    private func balanceButton(siblingSum: Double, total: Double, fromName: String) -> some View {
        let remainder = 1.0 - siblingSum
        let canBalance = remainder >= 0 && totalIsUnbalanced(total)
        let target = DS.Number.format(max(remainder, 0), significantDigits: DS.Number.readoutDigits)
        let cls = CustomerClass.label(for: model.selectedClass)
        let why: String
        if !totalIsUnbalanced(total) {
            why = "The routing from \(fromName) for \(cls) already sums to 1."
        } else if remainder < 0 {
            why = "The sibling links already sum to more than 1 on their own; lower one of them first. This button only ever changes this link's probability."
        } else {
            why = "Set this link's probability to \(target) so the routing from \(fromName) for \(cls) sums to 1. The sibling links are not changed."
        }
        return Button("Balance to 1") {
            withAnimation(a11y.animation(DS.Motion.quick)) {
                model.probabilityText = DS.Number.fieldText(min(max(remainder, 0), 1))
            }
        }
        .controlSize(.small)
        .disabled(!canBalance)
        .help(why)
        .accessibilityLabel("Balance to 1")
        .accessibilityHint("Sets this link's probability to \(target)")
    }

    private func totalMessage(total: Double, fromName: String, siblingCount: Int) -> String? {
        guard model.probabilityError == nil, totalIsUnbalanced(total) else { return nil }
        let t = DS.Number.format(total, significantDigits: DS.Number.readoutDigits)
        let cls = CustomerClass.label(for: model.selectedClass)
        if total > 1 {
            return "Routing from \(fromName) for \(cls) sums to \(t), which exceeds 1. Lower this or a sibling link."
        }
        let missing = DS.Number.format((1 - total) * 100, significantDigits: DS.Number.readoutDigits)
        return "Routing from \(fromName) for \(cls) sums to \(t); \(missing)% of jobs have no route\(siblingCount == 0 ? " (this is the only outgoing link)" : "")."
    }

    /// Other links leaving the same node with the *currently selected*
    /// entry class (so the table follows the picker, not just the saved
    /// class).
    private var siblingLinks: [NetworkLink] {
        editor.links.filter {
            $0.id != link.id
            && $0.fromNodeID == link.fromNodeID
            && $0.customerClass == model.selectedClass
        }
        .sorted { editor.displayLabel(for: $0) < editor.displayLabel(for: $1) }
    }

    // MARK: Classes

    private var classSection: some View {
        let classCount = max(editor.numberOfCustomerClasses, 1)
        let used = editor.entryClassesUsedByOtherLinks(onPairOf: link.id)

        return Section {
            LabeledContent("Entry class") {
                Menu {
                    ForEach(0..<classCount, id: \.self) { idx in
                        Button {
                            model.selectedClass = idx
                        } label: {
                            HStack {
                                ClassChip(classIndex: idx)
                                if idx == model.selectedClass {
                                    Image(systemName: DS.Symbol.checkmark)
                                }
                            }
                        }
                        .disabled(used.contains(idx))
                    }
                } label: {
                    ClassChip(classIndex: model.selectedClass)
                }
                .fixedSize()
                .help("Class of the jobs that take this link. Classes already carried by another \(editor.displayLabel(for: link)) link are unavailable.")
                .accessibilityLabel("Entry class, \(CustomerClass.label(for: model.selectedClass))")
            }
            if !used.isEmpty {
                Text("Unavailable: \(used.sorted().map { CustomerClass.label(for: $0) }.joined(separator: ", ")) — already carried by another link between these nodes.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Exit class") {
                Menu {
                    Button {
                        model.exitSelection = LinkParameterDraft.sameAsEntry
                    } label: {
                        HStack {
                            Text("Same as entry (\(CustomerClass.label(for: model.selectedClass)))")
                            if model.exitSelection == LinkParameterDraft.sameAsEntry { Image(systemName: DS.Symbol.checkmark) }
                        }
                    }
                    Divider()
                    ForEach(0..<classCount, id: \.self) { idx in
                        Button {
                            model.exitSelection = idx
                        } label: {
                            HStack {
                                ClassChip(classIndex: idx)
                                if model.exitSelection == idx { Image(systemName: DS.Symbol.checkmark) }
                            }
                        }
                    }
                    Divider()
                    Button {
                        model.exitSelection = classCount
                    } label: {
                        HStack {
                            ClassChip(classIndex: classCount)
                            Text("(new class)")
                            if model.exitSelection == classCount { Image(systemName: DS.Symbol.checkmark) }
                        }
                    }
                } label: {
                    if model.exitSelection == LinkParameterDraft.sameAsEntry {
                        Text("Same as entry")
                    } else {
                        HStack(spacing: DS.Spacing.xs) {
                            ClassChip(classIndex: model.exitSelection)
                            if model.exitSelection >= classCount {
                                Text("(new)").foregroundStyle(DS.Color.textSecondary)
                            }
                        }
                    }
                }
                .fixedSize()
                .help("Class the job becomes after traversing this link. Pick a different class to model a re-entrant line.")
                .accessibilityLabel("Exit class, \(model.exitSelection == LinkParameterDraft.sameAsEntry ? "same as entry" : CustomerClass.label(for: model.exitSelection))")
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                Text("Customer class")
                DSGlossaryButton(label: "Customer class", text: DS.Glossary.customerClass)
            }
        } footer: {
            Text(model.effectiveExitClass != model.selectedClass
                 ? "Jobs enter as \(CustomerClass.label(for: model.selectedClass)) and leave as \(CustomerClass.label(for: model.effectiveExitClass ?? model.selectedClass)) — a class transition (Dai–Harrison re-entrant line)."
                 : "Jobs keep their class on this link. Choose a different exit class to create a class transition.")
        }
    }
}

// MARK: - Rows

/// "→ C2" tag shown after a link label when the link changes the class.
struct ExitClassTag: View {
    let exitClass: Int

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: DS.Symbol.link).font(DS.Font.caption)
            ClassChip(classIndex: exitClass, compact: true)
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.textSecondary)
    }
}

/// One sibling link in the routing table: a hover-highlighted button with
/// the link label, optional exit-class tag, its probability and a
/// trailing chevron. Activating it switches the inspector to that link.
/// With no `action` (a host that cannot switch) it is a plain row.
struct SiblingLinkRow: View {
    let label: String
    let value: Double
    let exitClass: Int?
    let action: (() -> Void)?

    @State private var isHovering = false
    @DSAccessibility private var a11y

    private var spoken: String {
        "\(label), probability \(DS.Number.format(value, significantDigits: DS.Number.readoutDigits))"
    }

    var body: some View {
        let row = HStack(spacing: DS.Spacing.s) {
            Text(label)
                .font(DS.Font.chrome)
                .lineLimit(1)
            if let exitClass {
                ExitClassTag(exitClass: exitClass)
            }
            Spacer()
            Text(DS.Number.format(value, significantDigits: DS.Number.readoutDigits))
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
            .help("Edit \(label) in this inspector")
            .accessibilityLabel(spoken)
            .accessibilityHint("Opens this link in the inspector")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken)
        }
    }
}
