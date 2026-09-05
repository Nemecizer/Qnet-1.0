import SwiftUI

/// Everything the node inspector edits, as ONE observable draft shared by
/// the two hosts that show it: the modal `NodeParameterEditorSheet`
/// (⌘I; commits on Save as one undo step) and the docked
/// `InspectorPaneView` (follows the selection; commits each field on
/// blur, coalescing a run of commits to one field into one undo step).
/// The fields, validation, load and commit logic live here exactly once,
/// so the sheet and the pane cannot drift.
///
/// Load / dirty / commit contract:
///   • `load(from:nodeID:)` fills every field from the node and records
///     the `baseline`; `isDirty` is "current draft ≠ baseline".
///   • `refresh(from:)` re-reads the SAME node after the document changed
///     (undo, the pane's own commit): field text and baseline are
///     rewritten, UI state — the active class row, the entry modes — is
///     kept. `revertToBaseline()` is Escape in the pane.
///   • `commit(to:coalescing:)` writes the draft as one undo step named
///     "Edit S1 Parameters" (or folds into the current field run when
///     `coalescing` is true — the docked pane) and re-baselines.
///   • Nothing is written while `isValid` is false.
@MainActor
final class NodeParameterDraft: ObservableObject {

    /// The node being edited. Nil before the first `load`.
    @Published private(set) var nodeID: UUID?

    // Identity
    @Published var nameText: String = ""
    // Capacity
    @Published var serversText: String = "1"
    @Published var bufferSizeText: String = "1"
    @Published var infiniteBuffersDraft: Bool = false
    // Single distribution (sources, and stations with no served class)
    @Published var draft: DistributionDraft = .defaults(.exponential)
    @Published var entryMode: ParameterEntryMode = .native
    // Per-class service rows (stations)
    @Published var servedClasses: [Int] = []
    @Published var classDrafts: [Int: DistributionDraft] = [:]
    @Published var classEntryMode: ParameterEntryMode = .native
    @Published var activeClassRow: Int? = nil
    // Picture
    @Published var stationPicture: StationPicture = .none
    /// True while the Name field has keyboard focus — set by the host so
    /// `nameIsPending` can tell "cleared to retype" from "left empty".
    @Published var nameIsFocused: Bool = false
    /// Number of text fields currently holding keyboard focus (0 or 1 in
    /// practice; a counter so focus moving from one field to the next in
    /// one event never reads as "nothing focused"). The docked pane
    /// commits when this returns to zero — the blur.
    @Published var fieldFocusCount: Int = 0
    /// One-level revert for a bulk class action; see `BulkUndo`.
    @Published var bulkUndo: BulkUndo?
    /// Live traffic-equation readout for the station being edited, from
    /// a draft copy of the nodes. Refreshed by `scheduleStabilityRefresh`.
    @Published private(set) var stability: StationStabilityReadout?

    /// The values loaded for the current node, for the dirty check.
    private var baseline = Snapshot()
    private var stabilityTask: Task<Void, Never>?

    /// Everything the inspector edits, in one comparable value.
    struct Snapshot: Equatable {
        var name = ""
        var servers = ""
        var bufferSize = ""
        var infiniteBuffers = false
        var picture: StationPicture = .none
        var single: DistributionDraft = .defaults(.exponential)
        var perClass: [Int: DistributionDraft] = [:]
    }

    struct BulkUndo: Equatable {
        /// What the table looked like before the action.
        var before: [Int: DistributionDraft]
        /// What the action produced; the offer stands only while the
        /// table still equals this.
        var result: [Int: DistributionDraft]
        /// "S1 copied to 5 classes" — announced in the footer.
        var announcement: String
        /// "Undo Copy to All Classes" — the button title.
        var actionName: String
    }

    init() {}

    // MARK: - Snapshot / dirty

    var current: Snapshot {
        Snapshot(name: nameText, servers: serversText, bufferSize: bufferSizeText,
                 infiniteBuffers: infiniteBuffersDraft, picture: stationPicture,
                 single: draft, perClass: classDrafts)
    }

    /// True when the fields differ from the values loaded for this node.
    /// Compares the whole draft — name, capacity, picture and every
    /// per-class law — so navigating away can never lose an edit silently.
    var isDirty: Bool { current != baseline }

    /// Which single field differs from the baseline, for undo coalescing
    /// in the docked pane ("servers", "name", "class2", …). Nil when
    /// nothing or more than one thing changed — those never coalesce.
    var changedFieldKey: String? {
        let a = current, b = baseline
        var keys: [String] = []
        if a.name != b.name { keys.append("name") }
        if a.servers != b.servers { keys.append("servers") }
        if a.bufferSize != b.bufferSize { keys.append("bufferSize") }
        if a.infiniteBuffers != b.infiniteBuffers { keys.append("infiniteBuffers") }
        if a.picture != b.picture { keys.append("picture") }
        if a.single != b.single { keys.append("single") }
        for c in Set(a.perClass.keys).union(b.perClass.keys) where a.perClass[c] != b.perClass[c] {
            keys.append("class\(c)")
        }
        return keys.count == 1 ? keys[0] : nil
    }

    // MARK: - Load / refresh

    /// Fill every field from `nodeID` and re-baseline — the SELECTION
    /// changed. Resets the UI state a previous node may have left behind
    /// (active class row, bulk-undo offer, focus count), so stepping
    /// station → sink → station cannot carry a stale value.
    ///
    /// Not for a document change under the same node: that is `refresh`,
    /// which rewrites the field text but keeps which class the user is
    /// editing and how they are entering it.
    func load(from editor: NetworkEditorModel, nodeID: UUID) {
        self.nodeID = nodeID
        activeClassRow = nil
        bulkUndo = nil
        fieldFocusCount = 0
        guard let node = editor.node(with: nodeID) else { return }
        fill(from: editor, node: node)
        activeClassRow = servedClasses.first
        baseline = current
        refreshStability(editor: editor)
    }

    /// The document changed under the loaded node (undo, a context-menu
    /// command, the sheet's Save, the AI assistant, the pane's own
    /// commit): rewrite the field TEXT from the node and re-baseline,
    /// keeping every piece of UI state — `activeClassRow` (while that
    /// class is still served here), `entryMode` / `classEntryMode`, the
    /// focus bookkeeping and the bulk-undo offer. The docked pane calls
    /// this from its reload path; a reload must never move which class
    /// the pane is editing.
    func refresh(from editor: NetworkEditorModel) {
        guard let nodeID, let node = editor.node(with: nodeID) else { return }
        let keptRow = activeClassRow
        let keptMode = entryMode
        let keptClassMode = classEntryMode
        fill(from: editor, node: node)
        // Keep the entry modes: the drafts were rebuilt in native form,
        // so seed the moments fields the way `syncMode` would.
        if keptMode == .moments { draft.syncMode(to: .moments) }
        if keptClassMode == .moments {
            for c in servedClasses { classDrafts[c]?.syncMode(to: .moments) }
        }
        entryMode = keptMode
        classEntryMode = keptClassMode
        if let keptRow, servedClasses.contains(keptRow) {
            activeClassRow = keptRow
        } else {
            activeClassRow = servedClasses.first
        }
        baseline = current
        refreshStability(editor: editor)
    }

    /// Put every field back to the values loaded (or last committed) for
    /// this node — Escape in the docked pane, the one way to abandon an
    /// invalid edit without retyping it. UI state is kept.
    func revertToBaseline() {
        guard nodeID != nil else { return }
        nameText = baseline.name
        serversText = baseline.servers
        bufferSizeText = baseline.bufferSize
        infiniteBuffersDraft = baseline.infiniteBuffers
        stationPicture = baseline.picture
        draft = baseline.single
        classDrafts = baseline.perClass
        bulkUndo = nil
    }

    /// The document values, written into the fields. Shared by `load`
    /// (selection change) and `refresh` (document change); neither the
    /// baseline nor any UI state is touched here.
    private func fill(from editor: NetworkEditorModel, node: NetworkNode) {
        nameText = node.name
        infiniteBuffersDraft = editor.infiniteBuffers
        bufferSizeText = String(node.bufferSize)
        serversText = String(node.numberOfServers)
        stationPicture = node.picture
        servedClasses = []
        classDrafts = [:]

        switch node.kind {
        case .buffer:
            break
        case .station:
            servedClasses = editor.classesServedAtStation(nodeID: node.id)
            let fallback = Self.stationServiceLaw(node)
            var drafts = [Int: DistributionDraft]()
            for classIdx in servedClasses {
                if let config = node.serviceDistributions[classIdx] {
                    drafts[classIdx] = DistributionDraft(
                        distribution: config.distribution,
                        parameterString: config.distributionParameters)
                } else {
                    // Fallback: the node's top-level distribution seeds this class.
                    drafts[classIdx] = DistributionDraft(
                        distribution: fallback.distribution,
                        parameterString: fallback.parameters)
                }
            }
            classDrafts = drafts
            // Fallback single distribution for stations no class reaches yet.
            draft = DistributionDraft(distribution: fallback.distribution,
                                      parameterString: fallback.parameters)
        case .source:
            draft = DistributionDraft(distribution: node.distribution,
                                      parameterString: node.distributionParameters)
        case .sink:
            break
        }
    }

    /// Re-baseline without touching the fields — after a commit, so a
    /// Save followed by Previous / Next does not ask again.
    private func rebaseline() {
        baseline = current
        bulkUndo = nil
    }

    // MARK: - Validation

    /// True while the Name field has focus and is empty: the user has
    /// cleared it to retype, which blocks Save but is not yet an error.
    var nameIsPending: Bool {
        nameIsFocused && nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func nameError(editor: NetworkEditorModel) -> String? {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name cannot be empty." }
        if editor.nodes.contains(where: { $0.id != nodeID && $0.name == trimmed }) {
            return "Another node is already named \(trimmed)."
        }
        return nil
    }

    var serversError: String? {
        guard let v = DS.Number.parseInt(serversText) else { return "Enter a whole number of servers." }
        return v >= 1 ? nil : "Servers must be ≥ 1."
    }

    var bufferSizeError: String? {
        guard let v = DS.Number.parseInt(bufferSizeText) else { return "Enter a whole number of jobs." }
        return v >= 1 ? nil : "Buffer size must be ≥ 1."
    }

    /// A numeric field the user is part-way through typing ("", "-", "1e"):
    /// its error is real (Save stays blocked) but the host says
    /// "Still typing …" instead of showing a red problem line.
    static func isPending(_ text: String) -> Bool {
        DS.Number.parse(text) == nil && DS.Number.isPartialNumber(text)
    }

    /// Messages of a draft, excluding the fields still being typed.
    func settledErrors(_ d: DistributionDraft, mode: ParameterEntryMode) -> [String] {
        let pending = Set(d.pendingKeys(for: mode))
        return d.errors(for: mode)
            .filter { !pending.contains($0.key) }
            .values.sorted()
    }

    /// Save is blocked by a real problem *or* by a half-typed number.
    func isValid(editor: NetworkEditorModel) -> Bool {
        firstProblem(editor: editor) == nil && pendingNote(editor: editor) == nil
    }

    /// The first blocking problem, in visual order. Fields the user is
    /// mid-way through typing are reported by `pendingNote` instead.
    func firstProblem(editor: NetworkEditorModel) -> String? {
        guard let nodeID, let node = editor.node(with: nodeID) else { return nil }
        if !nameIsPending, let e = nameError(editor: editor) { return e }
        switch node.kind {
        case .buffer:
            if !infiniteBuffersDraft, !Self.isPending(bufferSizeText), let e = bufferSizeError { return e }
        case .station:
            if !Self.isPending(serversText), let e = serversError { return e }
            if servedClasses.isEmpty {
                if let e = settledErrors(draft, mode: entryMode).first { return e }
            } else {
                for c in servedClasses {
                    guard let d = classDrafts[c] else { continue }
                    if let e = settledErrors(d, mode: classEntryMode).first {
                        return "\(CustomerClass.label(for: c)): \(e)"
                    }
                }
            }
        case .source:
            if let e = settledErrors(draft, mode: entryMode).first { return e }
        case .sink:
            break
        }
        return nil
    }

    /// "Still typing Rate (λ)" — the calm note shown while a number is
    /// incomplete. Save stays disabled, but nothing turns red.
    func pendingNote(editor: NetworkEditorModel) -> String? {
        guard let nodeID, let node = editor.node(with: nodeID),
              firstProblem(editor: editor) == nil else { return nil }
        var names: [String] = []
        if nameIsPending { names.append("Name") }
        switch node.kind {
        case .buffer:
            if !infiniteBuffersDraft, Self.isPending(bufferSizeText) { names.append("Buffer size") }
        case .station:
            if Self.isPending(serversText) { names.append("Servers") }
            if servedClasses.isEmpty {
                names += draft.pendingFieldNames(for: entryMode)
            } else {
                for c in servedClasses {
                    names += (classDrafts[c]?.pendingFieldNames(for: classEntryMode) ?? [])
                        .map { "\(CustomerClass.label(for: c)) \($0)" }
                }
            }
        case .source:
            names += draft.pendingFieldNames(for: entryMode)
        case .sink:
            break
        }
        guard !names.isEmpty else { return nil }
        return "Still typing \(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? "…" : "")"
    }

    /// What a silent discard would throw away, for the status log:
    /// `Servers ("abc")`, `Class 2 Rate (λ) ("")`, … — the fields whose
    /// text does not pass validation right now. Empty while the draft is
    /// valid.
    func invalidFieldSummaries(editor: NetworkEditorModel) -> [String] {
        guard let nodeID, let node = editor.node(with: nodeID) else { return [] }
        func quoted(_ text: String) -> String { "(\"\(text)\")" }
        var out: [String] = []
        if nameError(editor: editor) != nil { out.append("Name \(quoted(nameText))") }
        func distributionFields(_ d: DistributionDraft, mode: ParameterEntryMode, prefix: String) {
            for key in d.errors(for: mode).keys.sorted() {
                let text: String
                switch key {
                case DistributionDraft.meanKey: text = d.displayMeanText
                case DistributionDraft.scvKey:  text = d.displayScvText
                default:                        text = d.displayParam(key)
                }
                out.append("\(prefix)\(d.fieldName(for: key)) \(quoted(text))")
            }
        }
        switch node.kind {
        case .buffer:
            if !infiniteBuffersDraft, bufferSizeError != nil { out.append("Buffer size \(quoted(bufferSizeText))") }
        case .station:
            if serversError != nil { out.append("Servers \(quoted(serversText))") }
            if servedClasses.isEmpty {
                distributionFields(draft, mode: entryMode, prefix: "")
            } else {
                for c in servedClasses {
                    if let d = classDrafts[c] {
                        distributionFields(d, mode: classEntryMode, prefix: "\(CustomerClass.label(for: c)) ")
                    }
                }
            }
        case .source:
            distributionFields(draft, mode: entryMode, prefix: "")
        case .sink:
            break
        }
        return out
    }

    // MARK: - Bulk class actions (one-level revert)

    /// Number of rows a "… to all classes" action would overwrite,
    /// excluding the source row. Named in the menu titles so the scope is
    /// visible *before* the click rather than after it.
    func otherClassCount(excluding source: Int?) -> Int {
        servedClasses.filter { $0 != source }.count
    }

    func copyToAllClasses(from source: Int) {
        guard let src = classDrafts[source] else { return }
        let targets = servedClasses.filter { $0 != source }
        guard !targets.isEmpty else { return }
        applyBulk(actionName: "Copy to All Classes",
                  announcement: "\(CustomerClass.label(for: source)) copied to \(targets.count) class\(targets.count == 1 ? "" : "es")") {
            for c in targets { classDrafts[c] = src }
        }
    }

    func applyToAllClasses(_ template: DistributionDraft, named: String) {
        let count = servedClasses.count
        guard count > 0 else { return }
        applyBulk(actionName: "Apply \(named)",
                  announcement: "\(named) applied to \(count) class\(count == 1 ? "" : "es")") {
            for c in servedClasses { classDrafts[c] = template }
        }
    }

    /// Runs a bulk edit and records one level of revert. ⌘Z does nothing
    /// inside a modal sheet (the sheet's state is not on the undo
    /// manager), so a misclick on "Exponential (rate 1) for all classes"
    /// used to destroy hand-entered Gamma parameters for every class with
    /// no way back short of Cancel.
    private func applyBulk(actionName: String, announcement: String, _ change: () -> Void) {
        let before = classDrafts
        change()
        bulkUndo = BulkUndo(before: before, result: classDrafts,
                            announcement: announcement, actionName: actionName)
    }

    /// The revert offer stands only while the table is exactly what the
    /// bulk action produced: any further edit withdraws it.
    var bulkUndoIsLive: Bool {
        guard let bulkUndo else { return false }
        return classDrafts == bulkUndo.result
    }

    func revertBulk() {
        guard let bulkUndo else { return }
        classDrafts = bulkUndo.before
        self.bulkUndo = nil
    }

    // MARK: - Stability readout

    /// Recompute the λ / c·μ / ρ row after the draft settles — debounced
    /// so the traffic equations are not solved on every keystroke of
    /// `1e-3`, but fast enough that the number is there by the time the
    /// eye moves from the field to the readout.
    func scheduleStabilityRefresh(editor: NetworkEditorModel) {
        stabilityTask?.cancel()
        stabilityTask = Task { @MainActor [weak self, weak editor] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let editor else { return }
            self.refreshStability(editor: editor)
        }
    }

    func refreshStability(editor: NetworkEditorModel) {
        guard let nodeID, let node = editor.node(with: nodeID), node.kind == .station else {
            if stability != nil { stability = nil }
            return
        }
        let readout = NetworkEditorModel.stabilityReadout(
            for: nodeID,
            draftNodes: draftNodes(editor: editor, node: node),
            links: editor.links,
            infiniteBuffers: infiniteBuffersDraft)
        if readout != stability { stability = readout }
    }

    /// `editor.nodes` with this station replaced by the draft's values —
    /// only the parts that currently parse; a half-typed field leaves the
    /// stored value in place so the readout never goes blank mid-edit.
    private func draftNodes(editor: NetworkEditorModel, node: NetworkNode) -> [NetworkNode] {
        var copy = node
        if let servers = DS.Number.parseInt(serversText), servers >= 1 {
            copy.numberOfServers = servers
        }
        if servedClasses.isEmpty {
            if let params = draft.effectiveParams(for: entryMode) {
                copy.distribution = draft.distribution
                copy.distributionParameters = Self.parameterString(draft.distribution, params)
            }
        } else {
            for c in servedClasses {
                guard let d = classDrafts[c], let params = d.effectiveParams(for: classEntryMode) else { continue }
                copy.serviceDistributions[c] = ServiceDistributionConfig(
                    distribution: d.distribution,
                    distributionParameters: Self.parameterString(d.distribution, params))
            }
            if let first = servedClasses.first, let d = classDrafts[first],
               let params = d.effectiveParams(for: classEntryMode) {
                copy.distribution = d.distribution
                copy.distributionParameters = Self.parameterString(d.distribution, params)
            }
        }
        return editor.nodes.map { $0.id == node.id ? copy : $0 }
    }

    private static func parameterString(_ distribution: QueueDistribution, _ params: [String: Double]) -> String {
        distribution.parameterDefs.map { def in
            "\(def.key)=\(DS.Number.fieldText(params[def.key] ?? def.defaultValue))"
        }.joined(separator: ",")
    }

    // MARK: - Law comparison helpers

    /// A station's stored service law as the inspector edits it. Old
    /// `.bnet` files may carry a station whose law is the source-only
    /// `.poisson` (`lambda=…`); it means the same thing as
    /// Exponential(`rate=…`), so it is shown as Exponential with the rate
    /// carried over — and Save treats that mapping as "unchanged"
    /// (`stationLawIsUnchanged`) so an untouched Save is a no-op rather
    /// than a silent rewrite.
    static func stationServiceLaw(_ node: NetworkNode) -> (distribution: QueueDistribution, parameters: String) {
        guard node.distribution == .poisson else {
            return (node.distribution, node.distributionParameters)
        }
        let stored = QueueDistribution.parseParameterStrings(node.distributionParameters)
        let rate = stored["lambda"].flatMap(DS.Number.parse)
            ?? stored["rate"].flatMap(DS.Number.parse)
            ?? 1.0
        return (.exponential, "rate=\(DS.Number.fieldText(rate))")
    }

    /// True when `draft` is the same law as the stored (family, parameter
    /// string) pair. Parameters are compared *numerically*: a file that
    /// stores "rate=2.0" and the canonical "rate=2" are one law.
    static func lawIsUnchanged(_ draft: DistributionDraft,
                               distribution: QueueDistribution,
                               parameters: String) -> Bool {
        guard draft.distribution == distribution else { return false }
        return DistributionDraft(distribution: distribution, parameterString: parameters)
            .parameterString() == draft.parameterString()
    }

    static func lawIsUnchanged(_ draft: DistributionDraft, config: ServiceDistributionConfig?) -> Bool {
        guard let config else { return false }
        return lawIsUnchanged(draft, distribution: config.distribution,
                              parameters: config.distributionParameters)
    }

    static func stationLawIsUnchanged(_ resolved: DistributionDraft, node: NetworkNode) -> Bool {
        let baseline = stationServiceLaw(node)
        return lawIsUnchanged(resolved, distribution: baseline.distribution, parameters: baseline.parameters)
    }

    private func topLevelSyncDraft(drafts: [Int: DistributionDraft]) -> DistributionDraft? {
        servedClasses.first.flatMap { drafts[$0] }
    }

    private func firstClassEdited(node: NetworkNode, drafts: [Int: DistributionDraft]) -> Bool {
        guard let first = servedClasses.first, let d = drafts[first] else { return false }
        return !Self.lawIsUnchanged(d, config: node.serviceDistributions[first])
    }

    /// Whether Save should refresh the station's top-level distribution
    /// from class 1. That mirror exists only for single-class readers of a
    /// `.bnet` file, so it is rewritten when — and only when — class 1 was
    /// edited *and* the stored law really differs.
    private func topLevelSyncChanged(node: NetworkNode, drafts: [Int: DistributionDraft]) -> Bool {
        guard let d = topLevelSyncDraft(drafts: drafts),
              firstClassEdited(node: node, drafts: drafts) else { return false }
        return !Self.stationLawIsUnchanged(d, node: node)
    }

    // MARK: - Commit

    /// Commit the draft as ONE undo step ("Edit S1 Parameters") and emit
    /// one status line. Returns false when the draft is invalid (nothing
    /// is written). With `coalescing` true — the docked pane — a run of
    /// commits to the same field folds into the previous undo entry via
    /// `NetworkEditorModel.performCoalescedParameterEdit`.
    @discardableResult
    func commit(to editor: NetworkEditorModel, coalescing: Bool = false) -> Bool {
        guard let nodeID, let node = editor.node(with: nodeID), isValid(editor: editor) else { return false }
        guard isDirty else {
            // Nothing to write: a Save on an untouched sheet still says so.
            if !coalescing { editor.addStatus("No changes to \(node.name).") }
            return true
        }

        var notes: [String] = []
        var changes: [String] = []

        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != node.name { changes.append("renamed to \(trimmedName)") }

        // Resolve moments → native before entering the mutation so the
        // notes can ride along in the single summary line.
        var resolvedDraft = draft
        var resolvedClassDrafts = classDrafts
        if node.kind != .buffer, node.kind != .sink {
            if entryMode == .moments, node.kind == .source || servedClasses.isEmpty,
               let note = resolvedDraft.commitMomentsToNative(label: "") {
                notes.append(note)
            }
            if node.kind == .station, classEntryMode == .moments {
                for c in servedClasses {
                    if let note = resolvedClassDrafts[c]?.commitMomentsToNative(label: "\(CustomerClass.label(for: c)): ") {
                        notes.append(note)
                    }
                }
            }
        }

        switch node.kind {
        case .buffer:
            if infiniteBuffersDraft != editor.infiniteBuffers {
                changes.append(infiniteBuffersDraft ? "network buffers → infinite" : "network buffers → finite")
            }
            if !infiniteBuffersDraft, let size = DS.Number.parseInt(bufferSizeText), size != node.bufferSize {
                changes.append("size \(node.bufferSize) → \(size)")
            }
        case .station:
            if let servers = DS.Number.parseInt(serversText), servers != node.numberOfServers {
                changes.append("servers \(node.numberOfServers) → \(servers)")
            }
            if stationPicture != node.picture {
                changes.append("picture → \(stationPicture.displayName)")
            }
            if servedClasses.isEmpty {
                if !Self.stationLawIsUnchanged(resolvedDraft, node: node) {
                    changes.append("service → \(resolvedDraft.distribution.displayName)(\(resolvedDraft.compactSummary()))")
                }
            } else {
                for c in servedClasses {
                    guard let d = resolvedClassDrafts[c] else { continue }
                    if !Self.lawIsUnchanged(d, config: node.serviceDistributions[c]) {
                        changes.append("\(CustomerClass.label(for: c)) → \(d.distribution.displayName)(\(d.compactSummary()))")
                    }
                }
                if topLevelSyncChanged(node: node, drafts: resolvedClassDrafts),
                   let first = servedClasses.first {
                    changes.append("default service law follows \(CustomerClass.label(for: first))")
                }
            }
        case .source:
            if !Self.lawIsUnchanged(resolvedDraft, distribution: node.distribution,
                                    parameters: node.distributionParameters) {
                changes.append("arrivals → \(resolvedDraft.distribution.pickerName)(\(resolvedDraft.compactSummary()))")
            }
        case .sink:
            break
        }

        let summary: String? = changes.isEmpty
            ? nil
            : "Edited \(node.name): " + changes.joined(separator: "; ") + "."
                + (notes.isEmpty ? "" : " Note: " + notes.joined(separator: " "))

        let mutation: () -> Void = { [self] in
            editor.renameNode(nodeID: node.id, name: trimmedName)

            switch node.kind {
            case .buffer:
                editor.setInfiniteBuffers(infiniteBuffersDraft)
                if !infiniteBuffersDraft, let size = DS.Number.parseInt(bufferSizeText) {
                    editor.updateBufferSize(nodeID: node.id, size: size)
                }

            case .station:
                if let servers = DS.Number.parseInt(serversText) {
                    editor.updateNumberOfServers(nodeID: node.id, count: servers)
                }
                editor.updateStationPicture(nodeID: node.id, picture: stationPicture)

                if servedClasses.isEmpty {
                    if !Self.stationLawIsUnchanged(resolvedDraft, node: node) {
                        editor.updateNodeDistribution(
                            nodeID: node.id,
                            distribution: resolvedDraft.distribution,
                            parameters: resolvedDraft.parameterString())
                    }
                } else {
                    for c in servedClasses {
                        guard let d = resolvedClassDrafts[c],
                              !Self.lawIsUnchanged(d, config: node.serviceDistributions[c]) else { continue }
                        editor.updateServiceDistribution(
                            nodeID: node.id,
                            customerClass: c,
                            distribution: d.distribution,
                            parameters: d.parameterString())
                    }
                    if topLevelSyncChanged(node: node, drafts: resolvedClassDrafts),
                       let d = topLevelSyncDraft(drafts: resolvedClassDrafts) {
                        editor.updateNodeDistribution(
                            nodeID: node.id,
                            distribution: d.distribution,
                            parameters: d.parameterString())
                    }
                }

            case .source:
                if !Self.lawIsUnchanged(resolvedDraft, distribution: node.distribution,
                                        parameters: node.distributionParameters) {
                    editor.updateNodeDistribution(
                        nodeID: node.id,
                        distribution: resolvedDraft.distribution,
                        parameters: resolvedDraft.parameterString())
                }

            case .sink:
                break
            }
        }

        let name = "Edit \(node.name) Parameters"
        let changed: Bool
        if coalescing, let key = changedFieldKey {
            changed = editor.performCoalescedParameterEdit(key: "\(node.id.uuidString).\(key)",
                                                           name: name, summary: summary, mutation)
        } else {
            editor.endParameterRun()
            changed = editor.performParameterEdit(name, summary: summary, mutation)
        }

        if !changed, !coalescing {
            editor.addStatus("No changes to \(node.name).")
        }

        // The committed values are the new "unchanged" state. Reload the
        // moments-resolved parameters so the fields show what was written.
        if entryMode == .moments { draft = resolvedDraft; draft.syncMode(to: .moments) }
        if classEntryMode == .moments {
            for c in servedClasses {
                if var d = resolvedClassDrafts[c] { d.syncMode(to: .moments); classDrafts[c] = d }
            }
        }
        rebaseline()
        return true
    }
}
