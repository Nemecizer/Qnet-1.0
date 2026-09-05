import SwiftUI

/// The modal node inspector (Edit ▸ Edit Parameters…, ⌘I): `DSSheet`
/// chrome around `NodeInspectorSections`, the same grouped form the
/// docked Inspector pane shows, bound to one `NodeParameterDraft`. Save
/// commits every change as ONE undo step ("Edit S1 Parameters") and
/// emits one status line.
///
/// Canonical host: the docked pane (`InspectorPaneView`) is the
/// selection-driven inspector and commits on blur; this sheet is the
/// keyboard-first review-and-save form for the same fields. Neither has
/// fields of its own — both render `NodeInspectorSections`.
///
/// One guard for every way out with a dirty draft. Previous / Next
/// (⌥↑ / ⌥↓), Cancel, Escape and the window-close path
/// (`ContentView`'s `onDismiss` only clears the presented target; the
/// sheet itself is the only thing that can dismiss it) all go through
/// `requestClose` / `navigate`, which show the SAME three-way prompt —
/// Save / Don't Save / Cancel, Save disabled while the draft is invalid —
/// and skip it entirely when nothing changed, so the common case still
/// closes on one key.
///
/// Geometry is decided ONCE per presentation over the whole sibling
/// order: the `.table` band if any station in the order shows a class
/// table, and the opening height from the largest class count in the
/// order. Stepping between siblings therefore never resizes the sheet.
struct NodeParameterEditorSheet: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    /// Closes this form whichever host it is in — the sheet, or the
    /// `DSPanelWindow` the panel presenter puts it in. See
    /// `QnetDismissAction`.
    @Environment(\.qnetDismiss) private var qnetDismiss

    /// The node being edited. Starts as the presented target and changes
    /// when the user steps to a sibling; the sheet itself stays up.
    @State private var nodeID: UUID
    @StateObject private var model = NodeParameterDraft()

    /// What the DOCUMENT currently points the editor at, when this body is
    /// hosted in a panel: a panel leaves the canvas live underneath it, so
    /// the user can double-click another station while the form is open and
    /// expects the form to follow. `nil` in a sheet host, where nothing can
    /// retarget the presentation. Retargeting goes through the same
    /// unsaved-changes guard as ⌥↑ / ⌥↓ do.
    private let externalTargetID: UUID?

    /// Set by the panel presenter so the window's own exits — the title-bar
    /// close button, ⌘W, Quit — ask about a dirty draft instead of throwing
    /// it away. Unused in a sheet host, which has no such exits.
    private let closeGuard: DSPanelCloseGuard?

    /// True from the moment a close has been agreed, so the guard installed
    /// above lets that close through instead of re-asking.
    @State private var isClosing = false

    init(nodeID: UUID,
         externalTargetID: UUID? = nil,
         closeGuard: DSPanelCloseGuard? = nil) {
        _nodeID = State(initialValue: nodeID)
        self.externalTargetID = externalTargetID
        self.closeGuard = closeGuard
    }

    /// What the unsaved-changes prompt will do after Save / Don't Save.
    private enum PendingAction: Equatable {
        case navigate(UUID)
        case close
    }
    @State private var pendingAction: PendingAction?
    @State private var showUnsavedPrompt = false

    @FocusState private var nameFocused: Bool

    private var node: NetworkNode? {
        editor.node(with: nodeID)
    }

    private var isValid: Bool { model.isValid(editor: editor) }

    // MARK: - Body

    var body: some View {
        Group {
            if let node {
                DSSheet {
                    header(node)
                } content: {
                    Form {
                        NodeInspectorSections(
                            model: model,
                            node: node,
                            host: .sheet,
                            nameFocus: $nameFocused,
                            onOpenLink: { linkID in openLink(linkID) })
                    }
                    .formStyle(.grouped)
                    .dsRowLayout(.form)
                    .dsReservedMessageSlot()
                    .dsAnimation(DS.Motion.standard, value: model.draft.distribution)
                    .dsAnimation(DS.Motion.standard, value: model.entryMode)
                    .dsAnimation(DS.Motion.standard, value: model.classEntryMode)
                    .onChange(of: model.current) { _, _ in
                        model.scheduleStabilityRefresh(editor: editor)
                    }
                } footer: {
                    DSSheetFooter(
                        problem: model.firstProblem(editor: editor),
                        confirmTitle: "Save",
                        canConfirm: isValid,
                        cancelHelp: model.isDirty ? "Close without saving — asks first (Esc)" : "Close (Esc)",
                        blockedHelp: model.pendingNote(editor: editor) ?? "Fix the highlighted fields to save",
                        onCancel: { requestClose() },
                        onConfirm: { saveChanges() }
                    ) {
                        // One slot, two calm messages: the "still typing"
                        // note while a number is half-entered (1e-), or
                        // the one-level revert offered after a bulk class
                        // action. Neither is red; neither shifts layout.
                        if let bulkUndo = model.bulkUndo, model.bulkUndoIsLive {
                            bulkUndoBar(bulkUndo)
                        } else {
                            InlineFieldMessage(message: model.pendingNote(editor: editor), severity: .pending)
                        }
                    }
                }
            } else {
                DSSheetMissingTarget(message: "The selected node no longer exists.") {
                    isClosing = true
                    editor.closeParameterEditor()
                    qnetDismiss()
                }
            }
        }
        .dsSheetFrame(sheetSize, idealHeight: idealHeight)
        // Deterministic initial focus on the Name field (macOS 14
        // `.defaultFocus`), instead of a timer that races a slow first
        // presentation.
        .defaultFocus($nameFocused, true)
        .onAppear {
            model.load(from: editor, nodeID: nodeID)
            // In a panel, the window's close button and ⌘W would otherwise
            // bypass the one unsaved-changes guard every other exit uses.
            closeGuard?.allowsClose = { windowMayClose() }
        }
        .onChange(of: nodeID) { _, newID in
            model.load(from: editor, nodeID: newID)
            nameFocused = true
        }
        // The canvas is live under a panel: a double-click on another
        // station retargets the open form rather than editing a stale id.
        .onChange(of: externalTargetID) { _, newID in
            guard let newID, newID != nodeID else { return }
            retarget(to: newID)
        }
        .background(navigationShortcuts)
        .confirmationDialog(
            "Save changes to \(node?.name ?? "this node") before \(pendingAction == .close ? "closing" : "switching")?",
            isPresented: $showUnsavedPrompt,
            titleVisibility: .visible
        ) {
            Button("Save") {
                if model.commit(to: editor) { performPendingAction() } else { pendingAction = nil }
            }
            .disabled(!isValid)
            Button("Don’t Save", role: .destructive) { performPendingAction() }
            Button("Cancel", role: .cancel) { pendingAction = nil; pendingLinkToOpen = nil }
        } message: {
            Text(isValid
                 ? "The edits to this node have not been saved. Saving commits them as one undo step."
                 : "The edits to this node have not been saved and cannot be saved as they are (\(model.firstProblem(editor: editor) ?? model.pendingNote(editor: editor) ?? "a field is incomplete")).")
        }
    }

    /// ⌥↑ / ⌥↓ for Previous / Next, as zero-size buttons so the keys work
    /// wherever focus is inside the sheet. Titled, so VoiceOver and the
    /// keyboard-shortcut inspector can still name them.
    private var navigationShortcuts: some View {
        ZStack {
            Button("Previous Node") { navigate(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(neighbour(offset: -1) == nil)
            Button("Next Node") { navigate(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(neighbour(offset: 1) == nil)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry (fixed for the whole presentation)

    /// Geometry band of the sheet, from `DSSheetSize` like every other
    /// sheet in the app, chosen for the WHOLE sibling order so Previous /
    /// Next never changes it: a sink gets the compact band, a buffer the
    /// regular one, a source the wide one, and a station the `.table`
    /// band when any station in the order shows a per-class table (the
    /// table needs about 700 pt of form content).
    private var sheetSize: DSSheetSize { Self.size(for: nodeID, in: editor) }

    /// The band for a given node, as a free function so the panel presenter
    /// can size the WINDOW from the same rule the body sizes its content
    /// with — one definition, not two that can drift apart.
    static func size(for nodeID: UUID, in editor: NetworkEditorModel) -> DSSheetSize {
        guard let node = editor.node(with: nodeID) else { return .wide }
        switch node.kind {
        case .sink:   return .compact
        case .buffer: return .regular
        case .source: return .wide
        case .station:
            let anyTable = editor.inspectorNavigationOrder(forKind: .station)
                .contains { !editor.classesServedAtStation(nodeID: $0.id).isEmpty }
            return anyTable ? .table : .wide
        }
    }

    /// Opening height: the band's own ideal height, grown by one
    /// `DS.Layout.tableRowHeight` per row the form will show — for a
    /// station the classes of the LARGEST station in the order, and for
    /// every kind the Routing rows of the node in the order with the most
    /// links (capped at four) — clamped into the band, so the sheet opens
    /// tall enough for every sibling and never grows mid-navigation.
    private var idealHeight: CGFloat { Self.idealHeight(for: nodeID, in: editor) }

    /// Companion to `size(for:in:)`: the opening height, shared with the
    /// panel presenter for the same reason.
    static func idealHeight(for nodeID: UUID, in editor: NetworkEditorModel) -> CGFloat {
        let sheetSize = size(for: nodeID, in: editor)
        guard let node = editor.node(with: nodeID) else { return sheetSize.idealHeight }
        let order = editor.inspectorNavigationOrder(forKind: node.kind)
        let mostLinks = order.map { editor.linksAttached(to: $0.id).count }.max() ?? 0
        let linkRows = min(mostLinks, 4)
        guard node.kind == .station else {
            return linkRows == 0 ? sheetSize.idealHeight : sheetSize.height(forRows: linkRows)
        }
        let largest = order
            .map { editor.classesServedAtStation(nodeID: $0.id).count }
            .max() ?? 0
        let classRows = largest == 0 ? 2 : min(largest, 6)
        return sheetSize.height(forRows: classRows + linkRows)
    }

    // MARK: - Header

    private func header(_ node: NetworkNode) -> some View {
        let shownName = model.nameText.trimmingCharacters(in: .whitespaces).isEmpty ? node.name : model.nameText
        return HStack(spacing: DS.Spacing.s) {
            DSSheetHeader(shownName, subtitle: subtitle(for: node)) {
                DSSheetGlyph(fill: DS.Color.nodeFill(for: node.kind)) {
                    if node.kind == .station, let sys = model.stationPicture.systemImageName {
                        Image(systemName: sys)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(DS.Spacing.s)
                            .foregroundStyle(DS.Color.nodeGlyph)
                    } else {
                        Image(systemName: node.kind.systemImage)
                            .font(DS.Font.sheetGlyph)
                            .foregroundStyle(DS.Color.nodeTint(for: node.kind))
                    }
                }
            }
            .accessibilityLabel("\(node.name), \(node.kind.displayName)")

            navigationButtons(node)
        }
    }

    /// Previous / Next in the header's trailing slot — the same in-place
    /// sibling walk the link inspector has. Disabled (never wrapping) at
    /// the ends, with the destination named in the tooltip so the user
    /// knows where the button goes before pressing it.
    @ViewBuilder
    private func navigationButtons(_ node: NetworkNode) -> some View {
        let kindName = node.kind.displayName.lowercased()
        let order = editor.inspectorNavigationOrder(forKind: node.kind)
        let position = (order.firstIndex { $0.id == nodeID }).map { $0 + 1 }
        let prev = neighbour(offset: -1)
        let next = neighbour(offset: 1)
        if prev != nil || next != nil {
            HStack(spacing: DS.Spacing.xs) {
                // "2 of 5" — the standard inspector position readout, in
                // monospaced digits so it does not twitch as it changes.
                if let position {
                    Text("\(position) of \(order.count)")
                        .font(DS.Font.numberCaption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("This is \(kindName) \(position) of \(order.count), in the order the solvers number them")
                        .accessibilityLabel("\(kindName.capitalized) \(position) of \(order.count)")
                }
                HStack(spacing: DS.Spacing.xxs) {
                    DSIconButton(
                        systemImage: DS.Symbol.stepPrevious,
                        label: "Previous \(kindName)",
                        help: prev.map { "Edit \($0.name) (⌥↑)" } ?? "No previous \(kindName)"
                    ) { navigate(offset: -1) }
                    .disabled(prev == nil)

                    DSIconButton(
                        systemImage: DS.Symbol.stepNext,
                        label: "Next \(kindName)",
                        help: next.map { "Edit \($0.name) (⌥↓)" } ?? "No next \(kindName)"
                    ) { navigate(offset: 1) }
                    .disabled(next == nil)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Step through \(kindName)s")
        }
    }

    private func subtitle(for node: NetworkNode) -> String {
        switch node.kind {
        case .station:
            let servers = DS.Number.parseInt(model.serversText) ?? node.numberOfServers
            let classes = model.servedClasses.count
            var parts = ["Station", "\(servers) server\(servers == 1 ? "" : "s")"]
            if classes > 0 { parts.append("\(classes) class\(classes == 1 ? "" : "es")") }
            if let rho = model.stability?.utilisation {
                parts.append("ρ \(DS.Number.format(rho, significantDigits: 3))")
            }
            return parts.joined(separator: " · ")
        case .buffer:
            if model.infiniteBuffersDraft { return "Buffer · infinite capacity" }
            let size = DS.Number.parseInt(model.bufferSizeText) ?? node.bufferSize
            return "Buffer · capacity \(size)"
        case .source:
            return "Source · \(CustomerClass.label(for: editor.customerClassIndex(for: node.id))) arrivals"
        case .sink:
            return "Sink"
        }
    }

    // MARK: - The one guard: navigate / close

    private func neighbour(offset: Int) -> NetworkNode? {
        editor.nodeAdjacentInInspectorOrder(to: nodeID, offset: offset)
    }

    /// Step to the neighbour, asking to save first when the draft differs
    /// from what is stored.
    private func navigate(offset: Int) {
        guard let target = neighbour(offset: offset) else {
            NSSound.beep()
            return
        }
        guard model.isDirty else {
            switchNode(to: target.id)
            return
        }
        pendingAction = .navigate(target.id)
        showUnsavedPrompt = true
    }

    /// The document pointed the editor at a different node while the panel
    /// was open. Same three-way guard as a sibling step: nothing is thrown
    /// away without being offered a Save first.
    private func retarget(to id: UUID) {
        guard editor.node(with: id) != nil else { return }
        guard model.isDirty else {
            switchNode(to: id)
            return
        }
        pendingAction = .navigate(id)
        showUnsavedPrompt = true
    }

    /// The hosting panel window is trying to close itself (title-bar
    /// button, ⌘W, Quit). Answer `false` to hold it open while the same
    /// Save / Don't Save / Cancel prompt every other exit uses is
    /// answered; that answer then closes the panel through `close()`.
    private func windowMayClose() -> Bool {
        if isClosing { return true }
        guard model.isDirty else { return true }
        pendingAction = .close
        showUnsavedPrompt = true
        return false
    }

    /// Cancel / Escape. The same prompt as navigation; skipped when
    /// nothing changed so a stray Escape on an untouched sheet still
    /// closes it in one key — and a stray Escape on six hand-typed
    /// Gamma rows does not throw them away.
    private func requestClose() {
        guard model.isDirty else {
            close()
            return
        }
        pendingAction = .close
        showUnsavedPrompt = true
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .navigate(let id): switchNode(to: id)
        case .close: close()
        }
    }

    /// Switch in place — the presented `parameterEditorTarget` is left
    /// alone (replacing it would tear the sheet down and put it back up),
    /// exactly as the link inspector does. The canvas selection follows
    /// so the node under discussion is the highlighted one.
    private func switchNode(to id: UUID) {
        editor.applyParameterCacheOverlay(to: id)
        editor.selectedNodeID = id
        editor.selectedLinkID = nil
        withAnimation(DS.Motion.quick) { nodeID = id }
    }

    /// Close the sheet; when a Routing row asked for a link, present the
    /// link inspector once this sheet has gone (SwiftUI shows one sheet
    /// per scene at a time).
    private func close() {
        let editor = editor
        let linkToOpen = pendingLinkToOpen
        pendingLinkToOpen = nil
        // Before the close is issued, so a panel's close guard lets this
        // one through rather than putting the prompt up a second time.
        isClosing = true
        editor.closeParameterEditor()
        qnetDismiss()
        if let linkToOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.standardSettleDelay + 0.05) {
                editor.openLinkParameterEditor(for: linkToOpen)
            }
        }
    }

    /// A Routing row: close this sheet and open the link's inspector —
    /// asking about a dirty draft first, like every other way out.
    private func openLink(_ linkID: UUID) {
        pendingLinkToOpen = linkID
        requestClose()
    }

    /// Link the Routing row asked for; consumed by `close()`.
    @State private var pendingLinkToOpen: UUID?

    private func saveChanges() {
        guard model.commit(to: editor) else { return }
        close()
    }

    // MARK: - Bulk undo bar

    /// Footer accessory: what happened, and one button to take it back.
    private func bulkUndoBar(_ undo: NodeParameterDraft.BulkUndo) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Label(undo.announcement, systemImage: DS.Symbol.pending)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
            Button("Undo \(undo.actionName)") {
                withAnimation(DS.Motion.quick) { model.revertBulk() }
            }
            .controlSize(.small)
            .help("Put every class row back the way it was before this bulk action")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(undo.announcement). Undo available.")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The node parameter editor, as a movable panel
// ─────────────────────────────────────────────────────────────────────────────
//
// This is the most-used form in the product, and the one the sheet
// presentation hurt most: a user tuning ρ across a five-station line opens
// it dozens of times a session, and every time, the station it is asking
// about — its ρ badge, its neighbours, the queue it feeds — was underneath
// the sheet. Its header even carries a "3 of 5" stepper for walking the
// selection, which is precisely the interaction that wants the canvas
// visible.
//
// So it is hosted in a `DSPanelWindow` instead, the same way the archetype
// gallery and the station picture picker are. Two things follow from a
// panel's root being built once, and both are handled here:
//
//   * the form must OBSERVE the document rather than copy a node id out of
//     it, or double-clicking a second station would leave the panel editing
//     the first one (`NodeParameterEditorPanelBody`);
//   * the window has exits the form does not own — the title-bar button,
//     ⌘W, Quit — which without a `DSPanelCloseGuard` would throw away a
//     half-typed draft that every other exit stops to ask about.
// ─────────────────────────────────────────────────────────────────────────────

/// Presents the node parameter editor as a movable panel.
@MainActor
enum NodeParameterEditorPanel {
    /// Panel id, and therefore the window identifier suffix and the
    /// frame-autosave key (`QnetPanel.node-parameters`).
    static let panelID = "node-parameters"

    /// Title bar text. Deliberately the name of the FORM, not of the node:
    /// the form retargets in place — ⌥↑ / ⌥↓, a Routing row, a double-click
    /// on the canvas — and a title that renamed itself under the user would
    /// make the Window menu entry impossible to follow.
    static let windowTitle = "Node Parameters"

    /// Lives for as long as the panel does. Filled in by the hosted form
    /// on appear; see `DSPanelCloseGuard`.
    private static var closeGuard = DSPanelCloseGuard()

    /// Mirror `editor.parameterEditorTarget` onto the panel. The published
    /// target stays the single switch every opener writes — this is only
    /// the presentation — so `openParameterEditor(for:)` is unchanged.
    ///
    /// - Parameter targetID: `editor.parameterEditorTarget?.id`.
    static func sync(editor: NetworkEditorModel, targetID: UUID?) {
        guard let targetID else {
            DSPanelWindow.close(id: panelID)
            return
        }
        // The band depends on the node: a sink's two fields and a station's
        // per-class table are not the same window. Computed from the same
        // rule the body sizes its content with.
        let size = NodeParameterEditorSheet.size(for: targetID, in: editor)

        // Already up on another node: raise it and move its limits onto the
        // new band. The form retargets itself from the published id — this
        // must NOT rebuild the root, which would discard an unsaved draft
        // instead of offering to save it.
        if DSPanelWindow.bringForward(id: panelID) {
            DSPanelWindow.reband(id: panelID, to: size)
            return
        }

        closeGuard = DSPanelCloseGuard()
        DSPanelWindow.present(
            id: panelID,
            title: windowTitle,
            size: size,
            idealHeight: NodeParameterEditorSheet.idealHeight(for: targetID, in: editor),
            // Document-modal, matching the sheet this replaces: the form
            // belongs to the canvas window it edits, travels with it, stays
            // above it — and the bare canvas tool letters stay dead under a
            // window full of number fields, because `parameterEditorTarget`
            // is still non-nil and `isModalSheetPresented` still reads it.
            modality: .documentModal,
            // `DSSheetFooter` already binds Cancel to Escape.
            escapeCloses: false,
            closeGuard: closeGuard,
            // The ONE teardown path: the footer's Cancel, Save, the
            // title-bar button, ⌘W and Quit all arrive here, so the
            // published target is cleared exactly once and cannot stick.
            onClose: { editor.closeParameterEditor() }
        ) { _ in
            NodeParameterEditorPanelBody(editor: editor,
                                         initialNodeID: targetID,
                                         closeGuard: closeGuard)
        }
    }
}

/// Node parameter editor as a *panel* body.
///
/// A panel's root view is built once, when the window opens, so the node id
/// has to be read from the document on every update rather than captured:
/// unlike the sheet this replaces, a panel leaves the canvas underneath it
/// live, and double-clicking a second station must retarget the open form
/// instead of editing a stale id. The form itself is unchanged.
struct NodeParameterEditorPanelBody: View {
    @ObservedObject var editor: NetworkEditorModel
    /// The node the panel opened on — the initial value of the form's own
    /// `nodeID` state, which then walks with ⌥↑ / ⌥↓ on its own.
    let initialNodeID: UUID
    let closeGuard: DSPanelCloseGuard

    var body: some View {
        NodeParameterEditorSheet(
            nodeID: initialNodeID,
            externalTargetID: editor.parameterEditorTarget?.id,
            closeGuard: closeGuard)
            .environmentObject(editor)
    }
}
