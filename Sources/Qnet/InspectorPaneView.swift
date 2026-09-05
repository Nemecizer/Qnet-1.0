import SwiftUI
import AppKit

/// The docked Inspector pane (View ▸ Panes ▸ Inspector, ⌥⌘5; focus with
/// ⌃⌘5): a selection-driven inspector in the right column, above the
/// Status pane. It follows `editor.selectedNodeID` / `selectedLinkID`
/// and renders the SAME `NodeInspectorSections` / `LinkInspectorSections`
/// the modal sheets do, bound to the same draft models — so while S3 is
/// being edited the canvas still shows S3, S2 is one click away, and the
/// numbers change under the user's eyes.
///
/// Commit policy (MATLAB's property inspector, Igor Pro, OmniGraffle):
/// every field commits on blur or Return, pickers and steppers commit as
/// soon as the draft settles (a short debounce), and consecutive commits
/// to the same field fold into one undo step through
/// `NetworkEditorModel.performCoalescedParameterEdit` — exactly as
/// `nudgeSelection` coalesces a run of arrow presses.
///
/// Invalid-draft rule: an invalid draft is never written. It stays on
/// screen with its inline message until the user fixes it, presses
/// Escape (which reverts the whole draft to the last committed values —
/// `revertToBaseline`), or moves the selection. Moving on DISCARDS the
/// invalid edit, and says so: one warning line in the Status log names
/// the node, the field and the rejected text ("Discarded invalid edit to
/// S1: Servers ("abc")"), so nothing vanishes without a trace.
///
/// Reload rule: when the document changes under the loaded node (undo,
/// a context-menu command, the sheet's Save, the AI assistant, this
/// pane's own commit) the pane calls `NodeParameterDraft.refresh`, which
/// rewrites the field text and re-baselines but keeps every piece of UI
/// state. A reload must never move which class the pane is editing or
/// flip the entry mode — picking Class 2 and choosing Gamma must leave
/// the pane on Class 2, showing Gamma, after the commit lands. Undo /
/// redo keep the selection (`NetworkEditorModel.restore`), so ⌘Z after
/// a pane commit shows the restored value in the same field.
///
/// The sheets stay available (Edit ▸ Edit Parameters…, ⌘I, the header
/// button) for a review-and-save pass with Previous / Next.
struct InspectorPaneView: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject private var focusRouter = FocusRouter.shared

    @StateObject private var nodeModel = NodeParameterDraft()
    @StateObject private var linkModel = LinkParameterDraft()

    @FocusState private var nameFocused: Bool
    @FocusState private var probabilityFocused: Bool

    /// Debounced commit for changes made without a text field focused
    /// (a picker, a stepper press, a picture choice).
    @State private var commitTask: Task<Void, Never>?
    /// Which node or link the models are loaded for.
    @State private var loadedNodeID: UUID?
    @State private var loadedLinkID: UUID?
    /// This instance's identity for its `FocusRouter` registration, so a
    /// late `onDisappear` cannot clear a newer instance's handler.
    @State private var handlerOwner = PaneHandlerOwner()

    private static let settleDelay: UInt64 = 400_000_000

    /// The node the pane follows: the selected node, or the one node of a
    /// one-node marquee selection (the same rule ⌘I uses).
    private var targetNodeID: UUID? {
        if let id = editor.selectedNodeID { return id }
        if editor.selectedLinkID == nil, editor.selectedNodeIDs.count == 1 { return editor.selectedNodeIDs.first }
        return nil
    }

    private var targetLinkID: UUID? {
        targetNodeID == nil ? editor.selectedLinkID : nil
    }

    private var node: NetworkNode? { targetNodeID.flatMap { editor.node(with: $0) } }
    private var link: NetworkLink? { targetLinkID.flatMap { editor.link(with: $0) } }

    private var isFocused: Bool { focusRouter.focusedPane == .inspector }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            DSSectionHeader("Inspector", subtitle: headerSubtitle, isFocused: isFocused) {
                if let node {
                    Image(systemName: node.kind.systemImage)
                        .font(DS.Font.glyphSmall)
                        .foregroundStyle(DS.Color.nodeTint(for: node.kind))
                        .help(node.kind.displayName)
                        .accessibilityHidden(true)
                } else if link != nil {
                    Image(systemName: DS.Symbol.link)
                        .font(DS.Font.glyphSmall)
                        .foregroundStyle(DS.Color.textSecondary)
                        .help("Routing link")
                        .accessibilityHidden(true)
                }
            } trailing: {
                DSIconButton(
                    systemImage: DS.Symbol.inspector,
                    label: "Edit in Sheet",
                    help: "Open the same parameters in a sheet with Previous / Next and a Save button (⌘I)"
                ) {
                    commitNow()
                    editor.openParameterEditorForSelection()
                }
                .disabled(!editor.canOpenParameterEditor || editor.isModalSheetPresented)
                PaneSoloButton(.inspector)
            }

            ZStack {
                content
                    .dsContentWell()
                if node == nil && link == nil {
                    DSEmptyState(
                        systemImage: DS.Symbol.inspector,
                        title: "No Selection",
                        message: "Select a node or a link on the canvas to edit its parameters here. Changes apply as you leave each field and are undoable; Escape reverts a field you have not left yet."
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .background(PaneFocusMarker(.inspector))
        .onAppear {
            FocusRouter.shared.setFocusHandler(.inspector, owner: handlerOwner.id) {
                if node != nil { nameFocused = true } else if link != nil { probabilityFocused = true }
            }
            syncSelection()
        }
        // The clear is owner-checked: toggle the Inspector off and on
        // quickly and SwiftUI can run this teardown AFTER the replacing
        // instance's `onAppear`, which used to leave Window ▸ Focus
        // Inspector doing nothing until the pane was toggled again.
        .onDisappear {
            commitNow()
            FocusRouter.shared.setFocusHandler(.inspector, owner: handlerOwner.id, nil)
        }
        // Selection follows the canvas: commit whatever is pending for the
        // old target, then load the new one.
        .onChange(of: targetNodeID) { _, _ in syncSelection() }
        .onChange(of: targetLinkID) { _, _ in syncSelection() }
        // The document changed under the pane (undo, a context menu, the
        // sheet's Save, the AI assistant, our own commit): refresh — unless
        // the user is mid-edit here, in which case their blur commit wins.
        .onChange(of: editor.nodes) { _, _ in reloadIfIdle() }
        .onChange(of: editor.links) { _, _ in reloadIfIdle() }
        .onChange(of: editor.infiniteBuffers) { _, _ in reloadIfIdle() }
        // Draft changes: refresh the live ρ readout, and commit once the
        // draft settles if no text field is being typed into.
        .onChange(of: nodeModel.current) { _, _ in
            nodeModel.scheduleStabilityRefresh(editor: editor)
            scheduleCommit()
        }
        .onChange(of: linkModel.probabilityText) { _, _ in scheduleCommit() }
        .onChange(of: linkModel.selectedClass) { _, _ in scheduleCommit() }
        .onChange(of: linkModel.exitSelection) { _, _ in scheduleCommit() }
        // Blur: the last text field lost focus.
        .onChange(of: nodeModel.fieldFocusCount) { old, new in if old > 0, new == 0 { commitNow() } }
        .onChange(of: linkModel.fieldFocusCount) { old, new in if old > 0, new == 0 { commitNow() } }
        // Return inside any field commits at once.
        .onSubmit { commitNow() }
    }

    /// "S2 · Station" / "S1 → S2 · Class 1". Problems and "still typing"
    /// notes are NOT repeated here: the caption slot is single-line and
    /// would truncate them, and the field already shows the message where
    /// the eye is.
    private var headerSubtitle: String? {
        if let node {
            return "\(node.name) · \(node.kind.displayName)"
        }
        if let link {
            return "\(editor.displayLabel(for: link)) · \(CustomerClass.label(for: linkModel.selectedClass))"
        }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if let node, loadedNodeID == node.id {
            Form {
                NodeInspectorSections(
                    model: nodeModel,
                    node: node,
                    host: .pane,
                    nameFocus: $nameFocused,
                    onOpenLink: { linkID in
                        commitNow()
                        editor.selectedLinkID = linkID
                        editor.selectedNodeID = nil
                        editor.selectedNodeIDs = []
                    })
            }
            .formStyle(.grouped)
            .dsRowLayout(.form)
            .dsReservedMessageSlot()
            .dsAnimation(DS.Motion.standard, value: nodeModel.draft.distribution)
            .dsAnimation(DS.Motion.standard, value: nodeModel.entryMode)
            .dsAnimation(DS.Motion.standard, value: nodeModel.classEntryMode)
            .dsAnimation(DS.Motion.standard, value: nodeModel.activeClassRow)
            // Escape (AppKit's cancelOperation, so it reaches us from
            // inside a text field): put every field back to the last
            // committed values. Without this the only way out of an
            // invalid field was retyping it.
            .onExitCommand { revertDraft() }
        } else if let link, loadedLinkID == link.id {
            Form {
                LinkInspectorSections(
                    model: linkModel,
                    link: link,
                    host: .pane,
                    probabilityFocus: $probabilityFocused,
                    onOpenSibling: { siblingID in
                        commitNow()
                        editor.selectedLinkID = siblingID
                        editor.selectedNodeID = nil
                    })
            }
            .formStyle(.grouped)
            .dsRowLayout(.form)
            .dsReservedMessageSlot()
            .onExitCommand { revertDraft() }
        } else {
            // Empty ground under the empty-state overlay (and for the one
            // frame between a selection change and the reload).
            Color.clear
        }
    }

    // MARK: - Load / commit

    /// Commit for the previous target, then load the new one. Called on
    /// every selection change; a no-op when nothing changed. An invalid
    /// draft cannot be committed; it is discarded and logged.
    private func syncSelection() {
        commitTask?.cancel()
        if let previous = loadedNodeID, previous != targetNodeID {
            if nodeModel.isDirty, !nodeModel.commit(to: editor, coalescing: true) {
                logDiscardedNodeEdit(previous)
            }
            editor.endParameterRun()
        }
        if let previous = loadedLinkID, previous != targetLinkID {
            if linkModel.isDirty(editor: editor), !linkModel.commit(to: editor, coalescing: true) {
                logDiscardedLinkEdit(previous)
            }
            editor.endParameterRun()
        }
        if let id = targetNodeID, editor.node(with: id) != nil {
            if loadedNodeID != id {
                editor.applyParameterCacheOverlay(to: id)
                nodeModel.load(from: editor, nodeID: id)
                loadedNodeID = id
            }
            loadedLinkID = nil
        } else if let id = targetLinkID, editor.link(with: id) != nil {
            if loadedLinkID != id {
                linkModel.load(from: editor, linkID: id)
                loadedLinkID = id
            }
            loadedNodeID = nil
        } else {
            loadedNodeID = nil
            loadedLinkID = nil
        }
    }

    /// "Discarded invalid edit to S1: Servers ("abc")." — the trace an
    /// edit leaves when the selection moves off a draft that cannot be
    /// written.
    private func logDiscardedNodeEdit(_ nodeID: UUID) {
        let name = editor.node(with: nodeID)?.name ?? "node"
        let fields = nodeModel.invalidFieldSummaries(editor: editor)
        let what = fields.isEmpty
            ? (nodeModel.pendingNote(editor: editor) ?? "an incomplete field")
            : fields.joined(separator: ", ")
        editor.addStatus("Discarded invalid edit to \(name): \(what).", severity: .warning)
    }

    private func logDiscardedLinkEdit(_ linkID: UUID) {
        let label = editor.link(with: linkID).map { editor.displayLabel(for: $0) } ?? "link"
        let what: String
        if linkModel.probabilityError != nil || linkModel.probabilityIsPending {
            what = "Probability (\"\(linkModel.probabilityText)\")"
        } else {
            what = linkModel.firstProblem(editor: editor) ?? "an invalid field"
        }
        editor.addStatus("Discarded invalid edit to link \(label): \(what).", severity: .warning)
    }

    /// The document changed elsewhere: refresh the draft so the pane shows
    /// the truth — unless a field here is being typed into or the draft
    /// holds an uncommitted (invalid) edit, which the user still owns.
    /// `refresh` keeps the active class row and the entry modes; only the
    /// field text and the baseline move.
    private func reloadIfIdle() {
        if let id = loadedNodeID {
            guard editor.node(with: id) != nil else { syncSelection(); return }
            if nodeModel.fieldFocusCount == 0, !nodeModel.isDirty {
                nodeModel.refresh(from: editor)
            } else {
                nodeModel.scheduleStabilityRefresh(editor: editor)
            }
        }
        if let id = loadedLinkID {
            guard editor.link(with: id) != nil else { syncSelection(); return }
            if linkModel.fieldFocusCount == 0, !linkModel.isDirty(editor: editor) {
                linkModel.load(from: editor, linkID: id)
            }
        }
    }

    /// Escape: abandon whatever has not been committed. A clean draft is
    /// left alone (the key then means nothing here, which is right).
    private func revertDraft() {
        commitTask?.cancel()
        if loadedNodeID != nil, nodeModel.isDirty {
            withAnimation(DS.Motion.quick) { nodeModel.revertToBaseline() }
            nodeModel.scheduleStabilityRefresh(editor: editor)
        }
        if loadedLinkID != nil, linkModel.isDirty(editor: editor) {
            withAnimation(DS.Motion.quick) { linkModel.revertToBaseline() }
        }
    }

    /// Commit after the draft settles, but never while a text field has
    /// focus — typing `1e-3` must not write `1` and then `1e`.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.settleDelay)
            guard !Task.isCancelled else { return }
            commitIfIdle()
        }
    }

    private func commitIfIdle() {
        if loadedNodeID != nil, nodeModel.fieldFocusCount == 0 {
            nodeModel.commit(to: editor, coalescing: true)
        }
        if loadedLinkID != nil, linkModel.fieldFocusCount == 0 {
            linkModel.commit(to: editor, coalescing: true)
        }
    }

    /// Blur / Return / leaving: write a valid dirty draft now.
    private func commitNow() {
        commitTask?.cancel()
        if loadedNodeID != nil { nodeModel.commit(to: editor, coalescing: true) }
        if loadedLinkID != nil { linkModel.commit(to: editor, coalescing: true) }
    }
}
