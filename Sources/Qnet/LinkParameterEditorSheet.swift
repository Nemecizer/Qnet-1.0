import SwiftUI

/// The modal link inspector (`DSSheet` chrome around
/// `LinkInspectorSections`, bound to one `LinkParameterDraft`): the
/// routing probability with its sibling table and Balance to 1, and the
/// entry / exit class pickers. Each sibling row switches the inspector
/// to that link in place. Save commits everything as ONE undo step.
///
/// The docked Inspector pane shows the same sections and commits on
/// blur; this sheet is the review-and-save form. One guard for every
/// way out with a dirty draft — a sibling switch, Cancel, Escape and
/// the window-close path all go through `requestClose` /
/// `requestNavigation`, which show the same Save / Don't Save / Cancel
/// prompt and skip it when nothing changed.
struct LinkParameterEditorSheet: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    /// Closes this form whichever host it is in — the sheet, or the
    /// `DSPanelWindow` the panel presenter puts it in. See
    /// `QnetDismissAction`.
    @Environment(\.qnetDismiss) private var qnetDismiss

    /// The link being edited. Starts as the presented target and changes
    /// when the user navigates to a sibling; the sheet itself stays up.
    @State private var linkID: UUID
    @StateObject private var model = LinkParameterDraft()
    @FocusState private var probabilityFocused: Bool

    /// What the DOCUMENT currently points the editor at, when this body is
    /// hosted in a panel: a panel leaves the canvas live underneath it, so
    /// the user can double-click another link while the form is open and
    /// expects the form to follow. `nil` in a sheet host, where nothing can
    /// retarget the presentation. Retargeting goes through the same
    /// unsaved-changes guard a sibling row does.
    private let externalTargetID: UUID?

    /// Set by the panel presenter so the window's own exits — the title-bar
    /// close button, ⌘W, Quit — ask about a dirty draft instead of throwing
    /// it away. Unused in a sheet host, which has no such exits.
    private let closeGuard: DSPanelCloseGuard?

    /// True from the moment a close has been agreed, so the guard installed
    /// above lets that close through instead of re-asking.
    @State private var isClosing = false

    private enum PendingAction: Equatable {
        case navigate(UUID)
        case close
    }
    @State private var pendingAction: PendingAction?
    @State private var showUnsavedPrompt = false

    init(linkID: UUID,
         externalTargetID: UUID? = nil,
         closeGuard: DSPanelCloseGuard? = nil) {
        _linkID = State(initialValue: linkID)
        self.externalTargetID = externalTargetID
        self.closeGuard = closeGuard
    }

    private var link: NetworkLink? {
        editor.link(with: linkID)
    }

    private var isValid: Bool { model.isValid(editor: editor) }
    private var isDirty: Bool { model.isDirty(editor: editor) }

    // MARK: - Body

    var body: some View {
        Group {
            if let link {
                DSSheet {
                    header(link)
                } content: {
                    Form {
                        LinkInspectorSections(
                            model: model,
                            link: link,
                            host: .sheet,
                            probabilityFocus: $probabilityFocused,
                            onOpenSibling: { requestNavigation(to: $0) })
                    }
                    .formStyle(.grouped)
                    .dsRowLayout(.form)
                    .dsReservedMessageSlot()
                } footer: {
                    DSSheetFooter(
                        problem: model.firstProblem(editor: editor),
                        confirmTitle: "Save",
                        canConfirm: isValid,
                        cancelHelp: isDirty ? "Close without saving — asks first (Esc)" : "Close (Esc)",
                        blockedHelp: model.pendingNote ?? "Fix the highlighted fields to save",
                        onCancel: { requestClose() },
                        onConfirm: { saveChanges() }
                    ) {
                        // "Still typing 0." — calm note, Save disabled, no red.
                        InlineFieldMessage(message: model.pendingNote, severity: .pending)
                    }
                }
            } else {
                DSSheetMissingTarget(message: "The selected link no longer exists.") {
                    isClosing = true
                    editor.closeLinkParameterEditor()
                    qnetDismiss()
                }
            }
        }
        // Same band as the node inspector's source / station form, so
        // opening one after the other does not step the window width.
        .dsSheetFrame(.wide)
        // Deterministic initial focus (macOS 14 `.defaultFocus`), no timer.
        .defaultFocus($probabilityFocused, true)
        .onAppear {
            model.load(from: editor, linkID: linkID)
            // In a panel, the window's close button and ⌘W would otherwise
            // bypass the one unsaved-changes guard every other exit uses.
            closeGuard?.allowsClose = { windowMayClose() }
        }
        .onChange(of: linkID) { _, newID in
            model.load(from: editor, linkID: newID)
            probabilityFocused = true
        }
        // The canvas is live under a panel: a double-click on another link
        // retargets the open form rather than editing a stale id.
        .onChange(of: externalTargetID) { _, newID in
            guard let newID, newID != linkID else { return }
            requestNavigation(to: newID)
        }
        .confirmationDialog(
            "Save changes to \(link.map(editor.displayLabel(for:)) ?? "this link") before \(pendingAction == .close ? "closing" : "switching")?",
            isPresented: $showUnsavedPrompt,
            titleVisibility: .visible
        ) {
            Button("Save") {
                if model.commit(to: editor) { performPendingAction() } else { pendingAction = nil }
            }
            .disabled(!isValid)
            Button("Don’t Save", role: .destructive) { performPendingAction() }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(isValid
                 ? "The edits to this link have not been saved. Saving commits them as one undo step."
                 : "The edits to this link have not been saved and cannot be saved as they are (\(model.firstProblem(editor: editor) ?? model.pendingNote ?? "a field is incomplete")).")
        }
    }

    // MARK: - Header

    private func header(_ link: NetworkLink) -> some View {
        DSSheetHeader(editor.displayLabel(for: link), subtitle: headerSubtitle) {
            DSSheetSymbolGlyph(
                fill: DS.Color.tintFill(CustomerClass.color(for: model.selectedClass)),
                systemImage: DS.Symbol.link,
                tint: DS.Color.textPrimary
            )
        }
        .accessibilityLabel("\(editor.displayLabel(for: link)), routing link, \(headerSubtitle)")
    }

    private var headerSubtitle: String {
        var text = "Routing link · \(CustomerClass.label(for: model.selectedClass))"
        if let exit = model.effectiveExitClass, exit != model.selectedClass {
            text += " → \(CustomerClass.label(for: exit))"
        }
        return text
    }

    // MARK: - The one guard: navigate / close

    /// Switch the inspector to `id`, asking to save first when the
    /// current edit differs from the stored link.
    private func requestNavigation(to id: UUID) {
        guard editor.link(with: id) != nil else { return }
        guard isDirty else {
            switchLink(to: id)
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
        guard isDirty else { return true }
        pendingAction = .close
        showUnsavedPrompt = true
        return false
    }

    /// Cancel / Escape: same prompt, skipped when nothing changed.
    private func requestClose() {
        guard isDirty else {
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
        case .navigate(let id): switchLink(to: id)
        case .close: close()
        }
    }

    private func switchLink(to id: UUID) {
        editor.selectedLinkID = id
        editor.selectedNodeID = nil
        withAnimation(DS.Motion.quick) {
            linkID = id
        }
    }

    private func close() {
        // Before the close is issued, so a panel's close guard lets this
        // one through rather than putting the prompt up a second time.
        isClosing = true
        editor.closeLinkParameterEditor()
        qnetDismiss()
    }

    private func saveChanges() {
        guard model.commit(to: editor) else { return }
        close()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The link parameter editor, as a movable panel
// ─────────────────────────────────────────────────────────────────────────────
//
// The same case as the node editor next door, and if anything sharper: the
// form's whole subject is a routing probability shared with its sibling
// links, and the siblings are drawn on the canvas the sheet was covering.
// See the header of `NodeParameterEditorPanel` for the two consequences of
// a panel root being built once.
// ─────────────────────────────────────────────────────────────────────────────

/// Presents the link parameter editor as a movable panel.
@MainActor
enum LinkParameterEditorPanel {
    /// Panel id, and therefore the window identifier suffix and the
    /// frame-autosave key (`QnetPanel.link-parameters`).
    static let panelID = "link-parameters"

    /// Title bar text: the name of the FORM, not of the link, because the
    /// form retargets in place from its sibling table. See
    /// `NodeParameterEditorPanel.windowTitle`.
    static let windowTitle = "Link Parameters"

    /// Lives for as long as the panel does. Filled in by the hosted form
    /// on appear; see `DSPanelCloseGuard`.
    private static var closeGuard = DSPanelCloseGuard()

    /// Mirror `editor.linkParameterEditorTarget` onto the panel. The
    /// published target stays the single switch every opener writes.
    ///
    /// - Parameter targetID: `editor.linkParameterEditorTarget?.id`.
    static func sync(editor: NetworkEditorModel, targetID: UUID?) {
        guard let targetID else {
            DSPanelWindow.close(id: panelID)
            return
        }
        // Already up on another link: raise it, and let the form retarget
        // itself from the published id. Rebuilding the root would discard
        // an unsaved draft instead of offering to save it. The link form is
        // one band (`.wide`) for every link, so there is nothing to reband.
        if DSPanelWindow.bringForward(id: panelID) { return }

        closeGuard = DSPanelCloseGuard()
        DSPanelWindow.present(
            id: panelID,
            title: windowTitle,
            // The band the form's own `dsSheetFrame` declares — the same
            // one the node editor's station form uses, so opening one after
            // the other does not step the window width.
            size: .wide,
            modality: .documentModal,
            escapeCloses: false,
            closeGuard: closeGuard,
            // The ONE teardown path — footer Cancel, Save, title-bar
            // button, ⌘W, Quit — so the published target cannot stick.
            onClose: { editor.closeLinkParameterEditor() }
        ) { _ in
            LinkParameterEditorPanelBody(editor: editor,
                                         initialLinkID: targetID,
                                         closeGuard: closeGuard)
        }
    }
}

/// Link parameter editor as a *panel* body. See
/// `NodeParameterEditorPanelBody`: the panel root is built once, so the
/// target is observed rather than copied.
struct LinkParameterEditorPanelBody: View {
    @ObservedObject var editor: NetworkEditorModel
    let initialLinkID: UUID
    let closeGuard: DSPanelCloseGuard

    var body: some View {
        LinkParameterEditorSheet(
            linkID: initialLinkID,
            externalTargetID: editor.linkParameterEditorTarget?.id,
            closeGuard: closeGuard)
            .environmentObject(editor)
    }
}
