import SwiftUI
import AppKit

/// Closures the menu bar invokes on `QnetGUIApp`. Keeping them in one
/// value type lets `QnetCommands` observe the editor (for enabled state)
/// without needing access to the App's private members.
struct QnetCommandActions {
    // File
    var newNetwork: () -> Void
    var openNetwork: () -> Void
    var openExample: () -> Void
    var openRecent: (URL) -> Void
    var closeTab: () -> Void
    var closeAllTabs: () -> Void
    var closeWindow: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var exportFiniteSimulatorInput: () -> Void
    var exportSRBMSolverInput: () -> Void
    var exportQNAInput: () -> Void
    var exportAllSolverInputs: () -> Void
    // Edit
    var findNode: () -> Void
    var clearCanvas: () -> Void
    var clearStatusLog: () -> Void
    // Network
    var analyzeNetwork: () -> Void
    var showNetworkPrimitives: () -> Void
    var generateRandomNetwork: () -> Void
    /// Help ▸ Check Dependencies… — re-runs the startup checklist on demand.
    /// A packaged build no longer runs it at launch, so this is the route to it.
    var checkDependencies: () -> Void
    var insertArchetype: () -> Void
    // Run
    var runComparison: () -> Void
    var runMonteCarloInfinite: () -> Void
    var runOpenProductForm: () -> Void
    var runQBD: () -> Void
    var runSpectralInfinite: () -> Void
    var runQNA: () -> Void
    var runRQNA: () -> Void
    var runSBD: () -> Void
    var runExactSimulation: () -> Void
    var runLinearProgram: () -> Void
    var runMonteCarloFinite: () -> Void
    var runSpectralFinite: () -> Void
    var runFiniteElement: () -> Void
    var runFiniteLP: () -> Void
    var runGenericCTMC: () -> Void
    var runFiniteDecomposition: () -> Void
    var runTruncatedCTMC: () -> Void
    var runAdaptiveLowRankBAR: () -> Void
    var runBARMomentBounds: () -> Void
    var runRegenerativeMonteCarlo: () -> Void
    var runMultiClassSRBM: () -> Void
    // Test
    var runInfiniteTestSet: () -> Void
    var runFiniteTestSet: () -> Void
    var runSpectralConvergence: () -> Void
    // Help
    var showHelpTopic: (HelpTopic) -> Void
}

/// The whole menu bar. Because this struct observes the active editor,
/// every `.disabled(...)` below is re-evaluated on each @Published change,
/// so items grey out and light up as the canvas, selection and buffer
/// mode change.
///
/// Sheet rule, stated once: no command that MUTATES the document or OPENS
/// a panel is enabled while a sheet is up. A sheet edits one node, link or
/// run; a mutation underneath it (Cut, Paste, Duplicate, Delete Selected
/// Link, Clear Canvas) would make the sheet save onto a dead id, and an
/// app-modal panel (a Save panel, Page Setup, Print, the Clear Canvas
/// alert) on top of a sheet leaves two modal surfaces fighting for the
/// keyboard. Commands that present a second sheet are gated for a third
/// reason: SwiftUI shows one sheet per scene and silently drops the next.
/// The gate is `sheetPresented`; the clipboard trio stays live for a
/// focused text field inside the sheet, which is the responder chain's
/// case and never reaches the canvas.
///
/// Shortcut map (no collisions; verified by `MenuShortcutAudit`, and
/// printed for users by Help ▸ Keyboard Shortcuts, which is GENERATED from
/// the live menu bar — so this comment is a summary, not the source of
/// truth). The workspace items (View ▸ Panes ⌥⌘1–5, Window ▸ tabs
/// ⇧⌘] / ⇧⌘[ and ⌘1–⌘9, ⇧⌘T Reopen Closed Tab, pane focus ⌃⌘1–5 —
/// the same digits as the Panes toggles — and ⌃⌘0 Focus Canvas, plus ⌃`
/// as the Shell alias and Window ▸ Shell with ⌘K Clear Shell) live in
/// `WorkspaceCommands`. Tooltips that cite a key read it from
/// `KeyboardShortcutReference.key(for:)`, a table the debug-build menu
/// audit checks against these bindings.
///   File     ⌘N New · ⌘O Open · ⇧⌘O Open Example · ⌥⌘N New from Archetype
///            · ⌘W Close Tab
///            ⌥⌘W Close All Tabs · ⇧⌘W Close Window · ⌘S Save · ⇧⌘S Save As
///            ⌘E Export ▸ All Solver Inputs to Folder · Page Setup (no key:
///            ⇧⌘P is Show Network Primitives) · ⌘P Print Diagram
///   Edit     ⌘Z/⇧⌘Z (the responder chain only while a text field has
///            keyboard focus — NSApp.sendAction's return value is not a
///            usable test, see the note on the group — otherwise the
///            canvas undo stack; the item names the step it will
///            reverse: "Undo Insert Tandem Line") · ⌘X/⌘C/⌘V
///            (⌘C also copies the Shell's selection, which no responder-chain
///            test can see: SwiftTerm's view is an NSView, not an NSText)
///            ⌘D Duplicate · ⌫ Delete (canvas only: disabled in text entry
///            and while the Shell has focus) · ⌘A · ⌘F Find Node / Find in
///            Shell / Search Help (title follows the focused pane / window,
///            and every pane but the canvas answers through FocusRouter)
///            ⌘G / ⇧⌘G Find Next / Previous (the focused pane's match list,
///            or the Qnet Help window's while it is key)
///            ⌘I Edit Parameters… · ⌥⌘C Copy as Image
///   View     ⌘= / ⌘- Zoom (routed to the focused pane) · ⌘0 Actual Size
///            ⇧⌘0 Zoom to Fit · ⌥⇧⌘0 Zoom to Selection (Keynote's keys;
///            ⌘1–⌘9 belong to the document tabs, as in every tabbed Mac
///            app) · ⌥⌘G Snap to Grid
///   Network  ⇧⌘A Analyze · ⇧⌘P Primitives · ⇧⌘R Generate Random
///   Tools    V M H · S B O X L (bare letters, matching the palette badges and
///            canvas hotkeys; `ToolShortcutGuard` keeps them out of text entry
///            and the items are disabled while an auxiliary window is key or
///            a sheet is open, so typing in Help / Settings / an inspector
///            never switches the canvas tool)
///   Run      ⌘R Comparison · ⌥⌘M Monte Carlo… · ⌥⌘S Spectral Method…
///            ⌥⌘Q QNA · ⌥⌘B SBD · ⌥⌘E SRBM MLMC · ⌥⌘F Finite Element…
///            ⌥⌘L Linear Program / Finite-Buffer LP
///            (buffer-mode pairs share a key: only the enabled variant carries it;
///            every item is dimmed while a sheet is up so its shortcut cannot
///            queue a second sheet SwiftUI would silently drop)
///            ⌘. Stop Run (the AI pane's Stop claims ⌘. only while no
///            solver run is active, so exactly one owner is live)
///   Help     ⌘? Qnet Help
struct QnetCommands: Commands {
    @ObservedObject var editor: NetworkEditorModel
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var menuContext: MenuContext
    /// Observed for Run ▸ Stop Run: the item's title and enablement
    /// follow `terminal.activeRun`.
    @ObservedObject var terminal: TerminalModel
    let testSetRunning: Bool
    let actions: QnetCommandActions
    /// Which pane is first responder; Find / Zoom route to it.
    @ObservedObject private var focusRouter = FocusRouter.shared
    /// The Qnet Help window's search state; Edit ▸ Find Next / Find
    /// Previous enable and disable with its match count.
    @ObservedObject private var helpModel = HelpWindowModel.shared
    /// The Settings window's search state, for the same two items while
    /// that window is key.
    @ObservedObject private var settingsSearch = SettingsSearchModel.shared

    // MARK: Derived state

    private var hasNetwork: Bool { !editor.nodes.isEmpty }
    private var infinite: Bool { editor.infiniteBuffers }
    private var multiClassSolverLookup: SolverRuntimeLookup {
        SolverRuntimeResolver.shared.resolveExecutable(
            name: "mc_solver", subdirectory: "multiclass_diffusion"
        )
    }
    private var textFocused: Bool { menuContext.textInputHasFocus }
    /// True when the Shell owns the keyboard AND holds a selection — the
    /// third way Edit ▸ Copy can be live. `focusedPane` is tested first so
    /// the selection flag is read only when it can matter; both are
    /// @Published, so the item lights up as the user drags out a selection
    /// and dims again when the click clears it.
    private var shellSelectionFocused: Bool {
        focusRouter.focusedPane == .shell && terminal.hasShellSelection
    }
    private var hasNodeSelection: Bool {
        editor.selectedNodeID != nil || !editor.selectedNodeIDs.isEmpty
    }
    private var hasSelection: Bool { hasNodeSelection || editor.selectedLinkID != nil }
    /// The model aligns from two nodes and distributes from three; the menu
    /// says the same thing rather than offering a command that silently
    /// does nothing.
    private var alignEnabled: Bool {
        editor.selectedNodeIDs.count >= 2 && !sheetPresented
    }
    private var distributeEnabled: Bool {
        editor.selectedNodeIDs.count >= 3 && !sheetPresented
    }
    /// File ▸ Save. An untitled document with content is always savable;
    /// one that came from (or has been written to) a file is savable only
    /// while it differs from what is on disk.
    private var canSave: Bool {
        if editor.currentFileURL == nil { return hasNetwork || !editor.links.isEmpty }
        return editor.hasUnsavedChanges
    }
    /// True while a modal sheet (inspector, SRBM export) is presented over
    /// the canvas; canvas-only key equivalents must not fire underneath it.
    /// Beyond the canvas key equivalents this originally guarded, every
    /// command that PRESENTS a sheet is disabled on it too: SwiftUI shows
    /// one sheet per scene, so a second request raised from a shortcut
    /// underneath the first is silently dropped and leaves the sheet-state
    /// mirror stuck true.
    private var sheetPresented: Bool {
        editor.isModalSheetPresented
            // Sheets presented from the App scene (Generate Random, Find
            // Node, Run Test Set, Spectral Convergence, run parameters):
            // a Stepper or Picker inside them is not NSText, so without
            // this the bare tool letters would switch the canvas tool
            // underneath the sheet.
            || menuContext.appSheetPresented
            // A DSPanelWindow opened .documentModal or .appModal: a real,
            // movable window rather than a sheet, but one the user is
            // expected to answer. It is a SEPARATE flag on purpose —
            // appSheetPresented means "SwiftUI is showing the scene's one
            // sheet", and a panel clears itself from
            // NSWindow.willCloseNotification, so it cannot get stuck.
            || menuContext.modalPanelPresented
    }
    /// Canvas key equivalents (tool letters, ⌫) are valid only when the
    /// canvas window is key and nothing modal sits above it.
    private var canvasCommandsActive: Bool { menuContext.keyWindowIsMain && !sheetPresented }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, when enabled: Bool) -> KeyboardShortcut? {
        enabled ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    // MARK: Body

    var body: some Commands {
        appMenu
        fileMenu
        editMenu
        viewMenu
        networkMenu
        toolsMenu
        runMenu
        testMenu
        helpMenu
    }

    // MARK: Qnet

    private var appMenu: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Qnet") { AboutQnetWindow.show() }
                .help("Version and build information")
        }
    }

    // MARK: File

    @CommandsBuilder
    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Network") { actions.newNetwork() }
                .keyboardShortcut("n")
                .help("Open an empty canvas in a new tab")

            Button("Open…") { actions.openNetwork() }
                .keyboardShortcut("o")
                .help("Open a .bnet network file")

            Menu("Open Recent") {
                ForEach(menuContext.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { actions.openRecent(url) }
                        .help(url.path)
                }
                if !menuContext.recentDocumentURLs.isEmpty {
                    Divider()
                }
                Button("Clear Menu") { menuContext.clearRecentDocuments() }
                    .disabled(menuContext.recentDocumentURLs.isEmpty)
            }

            Button("Open Example…") { actions.openExample() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Open one of the bundled literature networks")

            // No `.disabled(sheetPresented)`: the gallery is a DSPanelWindow
            // keyed by id, so a second request raises the open panel instead
            // of stacking a second copy — the "one sheet per scene" hazard
            // `sheetPresented` guards does not apply to a panel. Gating it
            // also made the empty canvas's primary button dead exactly when
            // the panel it opens is up (round-4 blocker R6), and the
            // neighbouring Open Example… carries no such gate either.
            Button("New from Archetype…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")

            Divider()

            Button("Close Tab") { actions.closeTab() }
                .keyboardShortcut("w")
                .help("Close the front tab (asks to save unsaved changes first), or the front auxiliary window")

            Button("Close All Tabs") { actions.closeAllTabs() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .help("Close every document tab in this window, asking to save each one with unsaved changes")

            Button("Close Window") { actions.closeWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help("Close the whole window, tabs and all")

            Divider()

            // Dimmed once the document on screen matches the file on
            // disk, like every other Mac document app — reading the same
            // `hasUnsavedChanges` the tab's edited dot uses. An untitled
            // network with content stays enabled: it has nowhere to have
            // been saved to yet.
            Button("Save") { actions.save() }
                .keyboardShortcut("s")
                .disabled(!canSave)
                .help(canSave
                      ? "Save the network to its .bnet file"
                      : (editor.currentFileURL != nil
                         ? "No unsaved changes"
                         : "Draw or open a network first"))

            Button("Save As…") { actions.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!hasNetwork && editor.currentFileURL == nil)
                .help("Write the network to a new .bnet file")

            Divider()

            Menu("Export") {
                // The picture first: this is a research tool whose users
                // publish these networks, and the diagram is the one
                // thing the app draws.  PDF is vector on a transparent
                // ground for a paper figure; PNG is a 2x raster on the
                // canvas ground for a slide or an email.
                // Gated on `sheetPresented` for the Save panel's sake: an
                // app-modal panel must not open on top of a sheet.
                Button("Diagram as PDF…") { CanvasImageExport.exportPDF(editor: editor) }
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Render the canvas as a vector PDF — background, grid and class legend are asked for first")

                Button("Diagram as PNG…") { CanvasImageExport.exportPNG(editor: editor) }
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Render the canvas as a PNG — scale, background, grid and class legend are asked for first")

                Divider()

                Button("Finite Simulator Input (fBNAsim)…") { actions.exportFiniteSimulatorInput() }
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Write the fBNAsim network description")

                Button("SRBM Solver Input (.in)…") { actions.exportSRBMSolverInput() }
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Write the drift, covariance and reflection data read by srbm_solver and bnet")

                Button("QNA Input (.qna)…") { actions.exportQNAInput() }
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Write the bna_qna / bna_rqna / bna_sbd input file")

                Divider()

                Button("All Solver Inputs to Folder…") { actions.exportAllSolverInputs() }
                    .keyboardShortcut("e")
                    .disabled(!hasNetwork || sheetPresented)
                    .help("Write every solver's input file into one folder (same files as Qnet --export-cmp); finite-buffer networks can pick the blocking convention")

                Divider()

                // The Status pane holds the solver output a user actually
                // keeps (ρ, Γ, sojourn lines, warnings); the same Save the
                // pane's export menu offers, reachable from the menu bar.
                Button("Status Log…") { StatusLogExport.save(editor: editor) }
                    .disabled(editor.statusMessages.isEmpty)
                    .help("Write the Status pane's entries, with timestamps and severities, to a text file")
            }
        }

        // Remove SwiftUI's default Close/Save items so File shows exactly
        // the commands above.  The print group is replaced with BOTH of
        // its standard members: Page Setup… (paper size and orientation,
        // edited into NSPrintInfo.shared, which Print Diagram reads) and
        // Print Diagram…, which prints the vector render and brings the
        // standard macOS Print ▸ Save as PDF escape hatch with it. Page
        // Setup has no key: ⇧⌘P is Network ▸ Show Network Primitives.
        CommandGroup(replacing: .saveItem) { }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { NSApp.runPageLayout(nil) }
                .disabled(sheetPresented)
                .help("Choose the paper size, orientation and scale that Print Diagram uses")

            Button("Print Diagram…") { CanvasImageExport.print(editor: editor) }
                .keyboardShortcut("p")
                .disabled(!hasNetwork || sheetPresented)
                .help("Print the diagram as vector art, scaled down to the page when it does not fit")
        }
    }

    // MARK: Edit

    /// Does a text control own ⌘Z right now?
    ///
    /// `menuContext.textInputHasFocus` is the published answer and drives
    /// menu *enablement*, but it is refreshed from notifications and a
    /// deferred event monitor, so it can lag by one event — notably when
    /// the app is re-activated (⌘Tab) and the window restores its field
    /// editor after `didBecomeKeyNotification` has already been read. The
    /// undo *action* must not be wrong in that window, so it asks AppKit
    /// directly as well. `is NSText` is the same predicate `MenuContext`
    /// uses (a field editor is an `NSTextView`), and it is deliberately
    /// false for SwiftTerm's terminal view, which is a plain `NSView`.
    private static func textEntryOwnsUndo(published: Bool) -> Bool {
        published || NSApp.keyWindow?.firstResponder is NSText
    }

    /// The undo manager the focused text control would actually use, or
    /// nil when no text control holds keyboard focus.
    ///
    /// A field editor is an `NSTextView`, and `NSResponder.undoManager`
    /// is what `undo:` reaches when the responder chain claims the
    /// selector — so this is the *same* stack `NSApp.sendAction` would
    /// operate on, which is exactly why the menu is allowed to describe
    /// itself from it.
    private static func focusedTextUndoManager() -> UndoManager? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText else { return nil }
        return text.undoManager
    }

    /// Force a stale field editor to let go of the key window.
    ///
    /// Clicking the canvas does not resign the field editor (a SwiftUI
    /// `Canvas` is not a focusable responder), so after any visit to a
    /// text field the window keeps handing `undo:` to an invisible search
    /// box for the rest of the session. Whenever a keystroke is routed to
    /// the document stack instead, the editor is ended first: without
    /// that the *next* ⌘Z is swallowed again and the state is sticky.
    private static func endStaleFieldEditing() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
        // `endEditing(for:)` commits the value but SwiftUI hands the field
        // editor straight back, so the responder is checked again and the
        // window itself is made first responder — the state a click on a
        // non-focusable view *should* have produced.
        window.endEditing(for: nil)
        if window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
    }

    /// Where one ⌘Z / ⇧⌘Z will actually go, resolved once so the menu
    /// item's title, its enablement and its action can never disagree.
    ///
    /// The contract this enforces is the one R5 broke: an item that reads
    /// "Undo Add Station" must undo the station, and an item that hands
    /// the keystroke to a text field must not be wearing the document's
    /// action name. The routing therefore asks the focused text control
    /// whether it has anything to undo *before* claiming the keystroke —
    /// a focused control with an empty stack swallows `undo:` silently,
    /// which is precisely how Delete Selection and Clear Canvas became
    /// unrecoverable.
    private struct UndoRouting {
        /// True when the keystroke is offered to the AppKit responder
        /// chain (a text field's own edit); false when it drives the
        /// document's stack.
        var usesTextEditor: Bool
        var available: Bool
        var actionName: String
    }

    private func undoRouting(redo: Bool) -> UndoRouting {
        if Self.textEntryOwnsUndo(published: textFocused) {
            guard let text = Self.focusedTextUndoManager() else {
                // A text control has focus but exposes no undo manager to
                // interrogate. Behave exactly as before — offer the
                // keystroke to the responder chain — rather than guessing.
                return UndoRouting(usesTextEditor: true, available: true, actionName: "")
            }
            if redo ? text.canRedo : text.canUndo {
                return UndoRouting(
                    usesTextEditor: true,
                    available: true,
                    actionName: redo ? text.redoActionName : text.undoActionName
                )
            }
            // Falls through: the focused field has nothing left to undo,
            // so the document stack is both the honest label and the
            // right destination.
        }
        return UndoRouting(
            usesTextEditor: false,
            available: redo ? editor.undoManager.canRedo : editor.undoManager.canUndo,
            actionName: redo ? editor.undoManager.redoActionName : editor.undoManager.undoActionName
        )
    }

    /// Performs one ⌘Z / ⇧⌘Z, re-resolving the route at click time.
    private func performUndoRedo(redo: Bool) {
        let routing = undoRouting(redo: redo)
        if routing.usesTextEditor,
           NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil) {
            return
        }
        // Reaching the document stack means the field editor (if any) is
        // stale; end it so the menu's next answer, and the next ⌘Z, are
        // not routed back into an invisible text control.
        Self.endStaleFieldEditing()
        menuContext.refreshFocus()
        if redo { editor.undoManager.redo() } else { editor.undoManager.undo() }
    }

    /// "Undo Insert Tandem Line", not a bare "Undo". Every mutation calls
    /// `undoManager.setActionName(_:)`, and the menu item is the only place
    /// the user ever reads it — it is what tells them what one ⌘Z will
    /// cost. Falls back to the bare verb when the stack is empty or the
    /// entry carries no name (a focused text field's own edit).
    private func undoRedoTitle(_ verb: String, _ name: String, available: Bool) -> String {
        guard available else { return verb }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? verb : "\(verb) \(trimmed)"
    }

    @CommandsBuilder
    private var editMenu: some Commands {
        // Undo/Redo are resolved through `undoRouting(redo:)`, and the
        // title, the enablement and the action all read the SAME answer.
        // That single rule is what the item has to obey: whatever the menu
        // says one ⌘Z costs is what one ⌘Z does.
        //
        // Two failure modes are being held off at once.
        //
        // (1) `NSApp.sendAction`'s return value is not a usable test.
        // sendAction reports "somebody handled it" as soon as ANY responder
        // in the chain claims `undo:`, and with a live text input context
        // (which the canvas window has whenever AppKit has built a field
        // editor, i.e. essentially always) something always does. The old
        // `if !sendAction { editor.undoManager.undo() }` therefore never
        // reached the canvas stack at all.
        //
        // (2) Focus alone is not a usable test either. Clicking the canvas
        // does not resign a field editor, so after one visit to the status
        // search box, a node name or the AI composer the window keeps
        // handing `undo:` to a text control the user cannot even see: the
        // item read "Undo Delete Selection", was enabled, and silently did
        // nothing — Delete Selection and Clear Canvas unrecoverable. So the
        // routing asks the focused control whether it has anything to undo,
        // takes the document stack when it does not, and ends the stale
        // field editor on the way through so the state cannot stick.
        CommandGroup(replacing: .undoRedo) {
            let undo = undoRouting(redo: false)
            let redo = undoRouting(redo: true)

            Button(undoRedoTitle("Undo", undo.actionName, available: undo.available)) {
                performUndoRedo(redo: false)
            }
            .keyboardShortcut("z")
            .disabled(!undo.available)

            Button(undoRedoTitle("Redo", redo.actionName, available: redo.available)) {
                performUndoRedo(redo: true)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!redo.available)
        }

        // Each clipboard action first tries the AppKit responder chain so a
        // focused text field handles ⌘X/⌘C/⌘V/⌘A natively; NSApp.sendAction
        // returns false when nothing claimed the selector, and we fall
        // through to the canvas-level node operation.
        //
        // Under a sheet (see the sheet rule in the header) the canvas
        // fallbacks are off: Cut and Paste stay enabled only while a text
        // field inside the sheet has focus, where the responder chain
        // claims them and the canvas branch cannot run. Copy is read-only
        // and stays live.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if !NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) {
                    editor.cutSelection()
                }
            }
            .keyboardShortcut("x")
            .disabled(!(hasNodeSelection || textFocused) || (sheetPresented && !textFocused))

            // Three responders can own ⌘C and only one of them is an
            // NSText. The Shell is checked FIRST and by pane, not by
            // responder chain: SwiftTerm's view is a plain NSView, so
            // `textFocused` is false there, and with canvas nodes also
            // selected the same keystroke would otherwise copy the nodes
            // while the user is looking at a selected result table.
            //
            // But that branch is taken only when the Shell actually HAS a
            // selection. Clicking into the Shell to read solver output while
            // three stations are still selected on the canvas is an ordinary
            // state, and there the shell has nothing to copy: falling
            // through hands ⌘C back to the responder chain (SwiftTerm
            // validates `copy:` on `selection.active`, so it declines) and
            // then to the nodes, which is what the user meant. The
            // "copy the whole scrollback" fallback belongs only to the two
            // surfaces that say they are doing it — the pane header button
            // and the context menu — never to a bare ⌘C.
            Button("Copy") {
                if focusRouter.focusedPane == .shell, terminal.hasShellSelection {
                    if terminal.copySelection() == nil { NSSound.beep() }
                } else if !NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                    editor.copySelection()
                }
            }
            .keyboardShortcut("c")
            .disabled(!(hasNodeSelection || textFocused || shellSelectionFocused))

            // Copies the whole diagram, not the selection: PDF and TIFF
            // both go on the pasteboard, so it lands as vector art in
            // Keynote and Pages and as a bitmap everywhere else. Gated on
            // the sheet like the other whole-diagram commands so ⌥⌘C in an
            // inspector cannot render the canvas underneath it.
            Button("Copy as Image") { CanvasImageExport.copyToPasteboard(editor: editor) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasNetwork || sheetPresented)
                .help("Copy the selected nodes and the links between them — or the whole diagram when nothing is selected — to the clipboard as PDF and TIFF")

            Button("Paste") {
                if !NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                    editor.pasteSelection()
                }
            }
            .keyboardShortcut("v")
            .disabled(sheetPresented && !textFocused)

            Button("Duplicate") { editor.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(!hasNodeSelection || textFocused || sheetPresented)

            // Bare ⌫: SwiftTerm's view is not NSText, so the item is also
            // disabled while the Shell has focus — otherwise Backspace typed
            // at the prompt would delete the selected node.
            Button("Delete") { editor.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!hasSelection || textFocused
                          || focusRouter.focusedPane == .shell || !canvasCommandsActive)

            // Also off under a sheet: the link inspector edits exactly the
            // selected link, and deleting it underneath the sheet would
            // make Save write onto a dead id.
            Button("Delete Selected Link") {
                if let id = editor.selectedLinkID { editor.deleteLink(id: id) }
            }
            .disabled(editor.selectedLinkID == nil || sheetPresented)
            .help("Remove the highlighted link (Delete removes whatever is selected, nodes included)")

            Divider()

            Button("Select All") {
                if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
                    editor.selectAll()
                }
            }
            .keyboardShortcut("a")

            // ⇧⌘A (the macOS standard) is Network ▸ Analyze Network here,
            // so Deselect All takes ⌥⌘A.  Offered to a focused text view
            // first, exactly as Select All is.
            Button("Deselect All") {
                // Not a selector any imported header declares (table and
                // outline views implement it), so it is built by name.
                if !NSApp.sendAction(NSSelectorFromString("deselectAll:"), to: nil, from: nil) {
                    editor.deselectAll()
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(!editor.hasAnySelection)
            .help("Clear the canvas selection (Escape does the same on the canvas)")

            Divider()

            // Routed: the title says what ⌘F will do — search the Help
            // window or Settings when one of those is key, search the Shell
            // scrollback when the shell is first responder, else find a node.
            Button(findTitle) { performFind() }
                .keyboardShortcut("f")
                .disabled(!findEnabled)
                .help(findHelp)

            // Standard macOS Find Next / Find Previous. Routed like ⌘F:
            // the Qnet Help window's match list when that window is key,
            // the Settings window's while that is key (enabled exactly
            // while its search field holds a query that matched
            // something), otherwise the focused pane's own match list
            // (the Status pane and the AI transcript both register one
            // with FocusRouter).
            Button("Find Next") { stepFind(+1) }
                .keyboardShortcut("g")
                .disabled(!findStepEnabled)
                .help(findStepHelp)

            Button("Find Previous") { stepFind(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!findStepEnabled)
                .help(findStepHelp)

            Divider()

            // One name for this command everywhere it appears: the Edit
            // menu, the node context menu and the link context menu all
            // say "Edit Parameters…" and all show ⌘I.
            Button("Edit Parameters…") { editor.openParameterEditorForSelection() }
                .keyboardShortcut("i")
                .disabled(!editor.canOpenParameterEditor || textFocused || sheetPresented)
                .help("Edit the parameters of the selected node or link")

            Divider()

            Button("Clear Canvas…") { actions.clearCanvas() }
                .disabled((!hasNetwork && editor.links.isEmpty) || sheetPresented)
                .help("Remove every node and link from the active tab (asks first; undoable)")

            Button("Clear Status Log") { actions.clearStatusLog() }
                .disabled(editor.statusMessages.isEmpty)
                .help("Empty the Status pane (asks first once the log is long; Undo Clear in the empty pane brings it back)")
        }
    }

    // MARK: Find routing

    private enum FindTarget { case help, settings, shell, status, results, ai, canvas }

    private var findTarget: FindTarget {
        if !menuContext.keyWindowIsMain {
            if QnetHelpWindow.isKeyWindow { return .help }
            if MenuContext.settingsWindowIsKey() { return .settings }
        }
        if focusRouter.focusedPane == .shell { return .shell }
        if focusRouter.focusedPane == .status { return .status }
        if focusRouter.focusedPane == .results { return .results }
        if focusRouter.focusedPane == .ai { return .ai }
        return .canvas
    }

    private var findTitle: String {
        switch findTarget {
        case .help:     return "Search Help…"
        case .settings: return "Search Settings…"
        case .shell:    return "Find in Shell…"
        case .status:   return "Search Status Log…"
        case .results:  return "Filter Results…"
        case .ai:       return "Search Conversation…"
        case .canvas:   return "Find Node…"
        }
    }

    private var findHelp: String {
        switch findTarget {
        case .help:     return "Move the keyboard focus to the Help window's search field"
        case .settings: return "Move the keyboard focus to the Settings search field"
        case .shell:    return "Search the Shell scrollback (the Shell has keyboard focus)"
        case .status:   return "Move the keyboard focus to the Status pane's search field"
        case .results:  return "Move the keyboard focus to the Results workspace filter"
        case .ai:       return "Search the AI Assistant transcript"
        case .canvas:   return "Select a node by name and scroll it into view"
        }
    }

    /// Find Next / Find Previous act on the Qnet Help window's match list
    /// while it is key, and on the Settings window's while that is key.
    private var helpFindEnabled: Bool {
        QnetHelpWindow.isKeyWindow && helpModel.matchCount > 0
    }

    private var settingsFindEnabled: Bool {
        MenuContext.settingsWindowIsKey() && settingsSearch.matchCount > 0
    }

    private var settingsFindHelp: String {
        guard settingsSearch.matchCount > 0 else {
            return "No settings match the search (type in the Settings search field first)"
        }
        return "Step through the settings matching \u{201C}\(settingsSearch.query)\u{201D}, in pane order"
    }

    private var helpFindHelp: String {
        guard QnetHelpWindow.isKeyWindow else {
            return "Walk the search matches in the Qnet Help window (open it and search first)"
        }
        guard helpModel.matchCount > 0 else {
            return "No matches in this help topic"
        }
        return "Scroll to the next match of \u{201C}\(helpModel.searchText)\u{201D} in this topic"
    }

    private var findEnabled: Bool {
        switch findTarget {
        case .help, .settings, .shell, .status, .results, .ai: return true
        case .canvas: return hasNetwork
        }
    }

    /// Find Next / Previous: the Help window's matches when it is key,
    /// the Settings window's when that is key, else the focused pane's
    /// (Status log, AI transcript).
    private var findStepEnabled: Bool {
        if QnetHelpWindow.isKeyWindow { return helpFindEnabled }
        if MenuContext.settingsWindowIsKey() { return settingsFindEnabled }
        return focusRouter.canStepFind
    }

    private var findStepHelp: String {
        if QnetHelpWindow.isKeyWindow { return helpFindHelp }
        if MenuContext.settingsWindowIsKey() { return settingsFindHelp }
        switch findTarget {
        case .shell:
            // SwiftTerm searches for whatever is on the system find
            // pasteboard, which its find bar writes on every keystroke, so
            // that — not the router's generic predicate — is what says
            // whether ⌘G has anything to walk.
            return terminal.hasFindTerm
                ? "Scroll to the next match in the Shell scrollback"
                : "Search the Shell first (⌘F); Find Next then steps through the matches"
        case .status:
            return focusRouter.canStepFind
                ? "Select the next entry that matches the Status pane's search"
                : "Search the Status log first (⌘F); Find Next then steps through the matching entries"
        case .ai:
            return focusRouter.canStepFind
                ? "Scroll to the next message that matches the conversation search"
                : "Search the conversation first (⌘F); Find Next then steps through the matching messages"
        default:
            return "Walk the matches of the focused pane's search, or of the Qnet Help window when it is in front"
        }
    }

    /// ⌘G / ⇧⌘G: the Help window when it is key, Settings when it is
    /// key (SettingsView observes `.bnetSettingsStepMatch`), else the
    /// focused pane's handler.
    private func stepFind(_ delta: Int) {
        if QnetHelpWindow.isKeyWindow {
            helpModel.stepMatch(delta)
        } else if MenuContext.settingsWindowIsKey() {
            NotificationCenter.default.post(name: .bnetSettingsStepMatch, object: nil,
                                            userInfo: ["delta": delta])
        } else {
            FocusRouter.shared.stepFind(delta)
        }
    }

    private func performFind() {
        switch findTarget {
        case .help:
            QnetHelpWindow.focusSearch()
        case .settings:
            // SettingsView observes this and focuses its search field.
            // Use the typed constant — a hand-spelt raw string here silently
            // missed the observer (SettingsComponents.bnetSettingsFocusSearch).
            NotificationCenter.default.post(name: .bnetSettingsFocusSearch, object: nil)
        case .status, .results, .ai, .shell:
            // The Status, Results, AI and Shell panes all register find
            // handlers with FocusRouter (the Shell's opens SwiftTerm's own
            // find bar over the scrollback); the canvas prompt is the
            // fallback for a pane that registered none.
            FocusRouter.shared.find { actions.findNode() }
        case .canvas:
            actions.findNode()
        }
    }

    // MARK: View

    private var viewMenu: some Commands {
        CommandGroup(before: .toolbar) {
            // Routed: bumps the focused pane's text size when the shell /
            // status / AI pane has focus, else zooms the canvas.
            Button("Zoom In") { FocusRouter.shared.zoom(+1) { editor.zoomIn() } }
                .keyboardShortcut("=")

            Button("Zoom Out") { FocusRouter.shared.zoom(-1) { editor.zoomOut() } }
                .keyboardShortcut("-")

            // Standard diagramming trio (animated; zoom range from
            // NetworkEditorModel.zoomRange).
            Button("Actual Size") { editor.resetZoom() }
                .keyboardShortcut("0")
                .help("Zoom to 100 % with the origin in the top-left corner")

            // ⇧⌘0 and ⌥⇧⌘0 are Keynote's keys for exactly these two
            // commands, and they sit beside ⌘0 Actual Size. ⌘1–⌘9 were
            // given back to the document tabs (Window menu), which is what
            // those keys mean in every tabbed Mac app.
            Button("Zoom to Fit") { editor.zoomToFit() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(!hasNetwork)
                .help("Frame the whole network")

            Button("Zoom to Selection") { editor.zoomToFitSelection() }
                .keyboardShortcut("0", modifiers: [.command, .option, .shift])
                .disabled(!editor.canZoomToSelection)
                .help("Frame the selected nodes")

            Divider()

            // ⌥⌘G, not ⇧⌘G: the latter is the system's Find Previous,
            // which sits beside ⌘G Find Next in the Edit menu. AppKit
            // registers one item per key equivalent and silently drops the
            // loser, so the pair had to be separated — ⌥⌘ is Qnet's "do
            // something" modifier (the Run methods use it), ⌃⌘ is reserved
            // for moving focus between panes.
            Toggle("Snap to Grid", isOn: Binding(
                get: { editor.snapToGrid },
                set: { editor.snapToGrid = $0 }
            ))
            .keyboardShortcut("g", modifiers: [.command, .option])
            .help("Snap node positions to the canvas grid while dragging and nudging")

            Divider()
            // View ▸ Panes (Palette / Status / Shell / AI Assistant / Inspector, ⌥⌘1–5)
            // is contributed by WorkspaceCommands.
        }
    }

    // MARK: Network

    private var networkMenu: some Commands {
        CommandMenu("Network") {
            Picker("Buffer Model", selection: Binding(
                get: { editor.infiniteBuffers },
                set: { editor.setInfiniteBuffers($0) }
            )) {
                Text("Finite buffers — capacity and blocking apply").tag(false)
                Text("Infinite buffers — queues are unbounded").tag(true)
            }
            .disabled(sheetPresented)
            .help("Network-wide queue-capacity model; changing it is undoable")

            Divider()

            Button("Network Model…") {
                NetworkModelGuideWindow.show(editor: editor, settings: appSettings)
            }
            .disabled(!hasNetwork || sheetPresented)
            .help("Inspect a non-spatial node and route outline, or compare finite-buffer blocking rules")

            Button("Analyze Network") { actions.analyzeNetwork() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!hasNetwork || sheetPresented)
                .help("Check the network for stability, tractability and structural problems")

            Button("Show Network Primitives") { actions.showNetworkPrimitives() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!hasNetwork || sheetPresented)
                .help("Print the SRBM primitives (drift, covariance, reflection) to the shell")

            Divider()

            Button("Straighten Network") { editor.straightenNetwork() }
                .disabled(!hasNetwork)
                .help("Align nodes to a tidy left-to-right layout")

            Button("Straighten and Fit to Window") { editor.fitNetworkToWindow() }
                .disabled(!hasNetwork)
                .help("Straighten the network and re-space the nodes to fill the window at 100 % (moves nodes; undoable)")

            Divider()

            // Align and Distribute, the set every diagramming tool ships.
            // Until now the only route to any of them was the node context
            // menu, which is a route a user has to already know about.
            // `alignEnabled` / `distributeEnabled` mirror the model's own
            // thresholds (2 nodes to align, 3 to distribute) so a greyed
            // item and a no-op method never disagree.
            Menu("Arrange") {
                Button("Align Left") { editor.alignSelectedNodesLeft() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the x of the leftmost one")
                Button("Align Horizontal Centres") { editor.alignSelectedNodesHorizontalCentres() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node onto the vertical line halfway between the leftmost and rightmost of them")
                Button("Align Right") { editor.alignSelectedNodesRight() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the x of the rightmost one")

                Divider()

                Button("Align Top") { editor.alignSelectedNodesTop() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the y of the topmost one")
                Button("Align Vertical Centres") { editor.alignSelectedNodesVerticalCentres() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node onto the horizontal line halfway between the topmost and bottommost of them")
                Button("Align Bottom") { editor.alignSelectedNodesBottom() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the y of the bottommost one")

                Divider()

                Button("Distribute Horizontally") { editor.distributeSelectedNodesHorizontally() }
                    .disabled(!distributeEnabled)
                    .help("Keep the leftmost and rightmost selected nodes and space the rest evenly along x (needs three or more)")
                Button("Distribute Vertically") { editor.distributeSelectedNodesVertically() }
                    .disabled(!distributeEnabled)
                    .help("Keep the topmost and bottommost selected nodes and space the rest evenly along y (needs three or more)")
            }

            Divider()

            Button("Generate Random Network…") { actions.generateRandomNetwork() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(sheetPresented)
                .help("Build a random network of a chosen size, topology and utilisation in a new tab")

            Button("Insert Archetype…") { actions.insertArchetype() }
                .disabled(sheetPresented)
                .help("Insert a ready-made network into this canvas at a chosen size and utilisation, as one undoable step")
        }
    }

    // MARK: Tools

    /// Single-letter shortcuts with no modifier, matching the palette
    /// badges and the canvas hotkeys (V M H · S B O X · L).
    /// `ToolShortcutGuard` keeps these letters out of text fields and the
    /// shell. The active tool shows a check mark.
    private var toolsMenu: some Commands {
        CommandMenu("Tools") {
            ForEach(Array(EditorTool.paletteGroups.enumerated()), id: \.offset) { groupIndex, group in
                ForEach(group, id: \.self) { tool in
                    toolItem(tool)
                }
                if groupIndex < EditorTool.paletteGroups.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// Disabled whenever the canvas is not the key window (type-select in a
    /// Help / Settings / Release Notes list is not NSText, so the event
    /// monitor alone cannot tell) or a sheet is presented over it.
    private func toolItem(_ tool: EditorTool) -> some View {
        Toggle(isOn: Binding(
            get: { editor.selectedTool == tool },
            set: { if $0 { editor.setTool(tool) } }
        )) {
            Label(tool.menuTitle, systemImage: tool.systemImage)
        }
        .keyboardShortcut(KeyEquivalent(Character(tool.shortcutKey.lowercased())), modifiers: [])
        // Bare-letter equivalents must not fire while a sheet is up: a
        // Slider / Stepper / segmented Picker in an inspector is not text
        // entry for `ToolShortcutGuard`, so S / B / O / X typed there
        // would otherwise switch the tool underneath the sheet.
        // `canvasCommandsActive` folds that sheet check in with the
        // key-window check.
        .disabled(!canvasCommandsActive)
        .help(tool.helpText + " — Help ▸ Keyboard Shortcuts lists every key")
    }

    // MARK: Run

    /// Every Run item carries a one-line `.help` in the same voice as the
    /// Test menu: what the method computes, which solver binary runs it,
    /// and what it costs. When an item is dimmed the tooltip says why —
    /// an empty canvas, or a network in the other buffer mode — because
    /// the section headings alone do not explain a greyed-out row.
    private func runHelp(_ text: String, infiniteOnly: Bool? = nil) -> String {
        if !hasNetwork { return text + " (open or draw a network first)" }
        if let infiniteOnly {
            if infiniteOnly && !infinite {
                return text + " (this network has finite buffers)"
            }
            if !infiniteOnly && infinite {
                return text + " (this network has infinite buffers)"
            }
        }
        return text
    }

    /// Every enabled Run item has a Method Reference entry, and its run
    /// sheet's help control opens it: Monte Carlo → .simulationInfinite /
    /// .simulationFinite, Spectral → .spectralInfinite / .spectralFinite,
    /// QNA → .qna, RQNA → .rqna, SBD → .sbd, SRBM MLMC →
    /// .exactSimulation, Linear Program → .linearProgramInfinite, Finite
    /// Element → .finiteElement, Finite-Buffer LP → .finiteLP, Multi-Class
    /// SRBM → .multiClassSRBM. `RunParameterSpecs` names the same topics.
    private var runMenu: some Commands {
        CommandMenu("Run") {
            Button("Choose a Method…") {
                MethodChooserWindow.show(editor: editor) { methodID in
                    runAdvisedMethod(methodID)
                }
            }
            .disabled(!hasNetwork || sheetPresented)
            .help("Compare applicability, assumptions, model layer, outputs and expected cost for this network")

            Divider()

            Button("Run Comparison") { actions.runComparison() }
                .keyboardShortcut("r")
                .disabled(!hasNetwork || sheetPresented)
                .help(runHelp("Run every method for the current buffer mode and tabulate the results side by side") + " — ⌥⌘ + letter runs one method; Help ▸ Keyboard Shortcuts lists them")

            Section("Infinite-Buffer Methods") {
                // The four items that always present a run-parameter sheet
                // take the HIG ellipsis; the ones that launch straight away
                // (QNA, RQNA, SBD, SRBM MLMC, and Linear Program,
                // whose sheet is conditional on a preference) do not.
                Button("Run Monte Carlo…") { actions.runMonteCarloInfinite() }
                    .keyboardShortcut(shortcut("m", [.command, .option], when: infinite))
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Discrete-event simulation of the unbounded-buffer queueing process (BNAsim · jackson_sim) — reference estimates include Monte Carlo uncertainty", infiniteOnly: true))
                Button("Run Exact Open Product Form") { actions.runOpenProductForm() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Exact Jackson/open-BCMP stationary measures for class-preserving Poisson/exponential FCFS M/M/c networks; no state-space truncation", infiniteOnly: true))
                Button("Run Exact Matrix-Analytic QBD") { actions.runQBD() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Exact scalar matrix-geometric solution for the strict one-station M/M/1 subclass, including probabilistic feedback", infiniteOnly: true))
                Button("Run Adaptive Truncated CTMC") { actions.runTruncatedCTMC() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Sparse queue-process CTMC on successively larger total-population caps; truncation agreement is heuristic and any Foster bounds are labeled separately", infiniteOnly: true))
                Button("Run Regenerative Monte Carlo…") { actions.runRegenerativeMonteCarlo() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Sequential fixed-width queue simulation using complete empty-to-empty cycles as IID observations", infiniteOnly: true))
                Button("Run Spectral Method…") { actions.runSpectralInfinite() }
                    .keyboardShortcut(shortcut("s", [.command, .option], when: infinite))
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Polynomial Galerkin solution of the SRBM in the orthant (BNAsm · bnet) — accurate in heavy traffic; cost grows quickly with the polynomial degree", infiniteOnly: true))
                Button("Run Whitt QNA") { actions.runQNA() }
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Whitt's parametric decomposition (BNAqna · bna_qna) — propagates two-moment traffic variability station by station; instant, approximate", infiniteOnly: true))
                Button("Run Whitt–You RQNA") { actions.runRQNA() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Robust QNA, Whitt–You 2022 (BNArqna · bna_rqna) — replaces QNA's variability equations with a robust bound; instant, approximate", infiniteOnly: true))
                Button("Run SBD") { actions.runSBD() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Sequential Bottleneck Decomposition (BNAsbd · bna_sbd) — splits the network into single-station subproblems and solves each one spectrally", infiniteOnly: true))
                Button("Run SRBM MLMC") { actions.runExactSimulation() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Multilevel Monte Carlo for the reflected Brownian motion (BNAmc · rbm_mlmc) — SRBM estimates with explicit finite-T and finite-L bias; no queue-simulation warm-up", infiniteOnly: true))
                Button("Run Linear Program") { actions.runLinearProgram() }
                    .keyboardShortcut(shortcut("l", [.command, .option], when: infinite))
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("LP relaxation of the SRBM stationary distribution (BNAlp · srbm_lp, Saure–Glynn–Zeevi) — moment estimates whose cost grows with the constraint grid", infiniteOnly: true))
                Button("Run Adaptive Low-Rank BAR") { actions.runAdaptiveLowRankBAR() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("Adaptive separable-exponential SRBM approximation with held-out BAR and moment-refinement diagnostics", infiniteOnly: true))
                Button("Run BAR Moment Bounds") { actions.runBARMomentBounds() }
                    .disabled(!hasNetwork || !infinite || sheetPresented)
                    .help(runHelp("SRBM moment outer relaxation; exact special cases are certified and general floating SDP values remain explicitly uncertified", infiniteOnly: true))
            }

            Section("Finite-Buffer Methods") {
                Button("Run Monte Carlo…") { actions.runMonteCarloFinite() }
                    .keyboardShortcut(shortcut("m", [.command, .option], when: !infinite))
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Discrete-event simulation of the finite-buffer queueing process (fBNAsim) — reference estimates include Monte Carlo uncertainty; the dialog picks the blocking regime", infiniteOnly: false))
                Button("Run Regenerative Monte Carlo…") { actions.runRegenerativeMonteCarlo() }
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Sequential fixed-width simulation for finite loss-on-full Markovian networks using complete regeneration cycles", infiniteOnly: false))
                Button("Run Exact Sparse CTMC") { actions.runGenericCTMC() }
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Exact finite-state Markov-chain solution for loss-on-full networks with Poisson arrivals and exponential FCFS service; stops before an unsafe state-space expansion", infiniteOnly: false))
                Button("Run Finite-Buffer Decomposition") { actions.runFiniteDecomposition() }
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Fast M/M/c/K fixed-point decomposition with explicit Loss or approximate BAS semantics and convergence diagnostics", infiniteOnly: false))
                Button("Run Spectral Method…") { actions.runSpectralFinite() }
                    .keyboardShortcut(shortcut("s", [.command, .option], when: !infinite))
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Polynomial Galerkin solution of the SRBM on the hypercube (fBNAsm · srbm_solver) — accurate at moderate degrees; memory grows quickly with degree and stations", infiniteOnly: false))
                Button("Run Finite Element…") { actions.runFiniteElement() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("Hermite finite-element solution of the SRBM density on a hypercube (fBNAfm · bna_fm_gauss) — cost grows as n^2d in the mesh size n and the number of stations d", infiniteOnly: false))
                // Named as Settings names it ("Finite-Buffer LP"), not the
                // abbreviated "Finite LP" the menu used to show.
                Button("Run Finite-Buffer LP") { actions.runFiniteLP() }
                    .keyboardShortcut(shortcut("l", [.command, .option], when: !infinite))
                    .disabled(!hasNetwork || infinite || sheetPresented)
                    .help(runHelp("LP method for the SRBM on a rectangle (fBNAlp · fBNAlp_solver) — moment estimates for bounded buffers", infiniteOnly: false))
            }

            Section("Experimental") {
                // No "(Experimental)" suffix: the item already sits in a
                // section with that name.
                Button(multiClassSolverLookup.url == nil
                       ? "Multi-Class SRBM — Unavailable"
                       : "Run Multi-Class SRBM…") {
                    actions.runMultiClassSRBM()
                }
                    .disabled(!hasNetwork || !infinite || sheetPresented
                              || multiClassSolverLookup.url == nil)
                    .help(multiClassSolverLookup.url == nil
                          ? multiClassSolverLookup.actionableDiagnostic
                          : runHelp("Class-aware workload diffusion with per-class traffic, compound service moments and routing covariance", infiniteOnly: true))
            }

            Divider()

            // The one Stop for a solver run: same SIGINT the Shell's ⌃C
            // sends, from the menu bar and from the status bar's Stop
            // button. ⌘. is free here — the AI pane's own Stop only
            // claims it while no solver run is in flight.
            // Enabled the moment a run exists: `cancelActiveRun` waits for
            // the wrapper's pid itself, so ⌘. is live from the first
            // millisecond instead of after the first status poll.
            Button(stopRunTitle) {
                terminal.cancelActiveRun { text, severity in
                    editor.addStatus(text, severity: severity)
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(terminal.activeRun == nil)
            .help(terminal.activeRun == nil
                  ? "Nothing is running"
                  : (terminal.canCancelRun
                     ? "Interrupt the running solver, as ⌃C would in the Shell"
                     : "Interrupt the running solver as soon as it reports its process id (within a second)"))
        }
    }

    /// Names the run that ⌘. would stop, so the menu says what it acts on.
    private var stopRunTitle: String {
        guard let run = terminal.activeRun else { return "Stop Run" }
        return "Stop \(run)"
    }

    private func runAdvisedMethod(_ methodID: String) {
        switch methodID {
        case "analytical": actions.analyzeNetwork()
        case "simulation-infinite": actions.runMonteCarloInfinite()
        case "open-product-form": actions.runOpenProductForm()
        case "qbd": actions.runQBD()
        case "spectral-infinite": actions.runSpectralInfinite()
        case "qna": actions.runQNA()
        case "rqna": actions.runRQNA()
        case "sbd": actions.runSBD()
        case "mlmc": actions.runExactSimulation()
        case "lp-infinite": actions.runLinearProgram()
        case "truncated-ctmc": actions.runTruncatedCTMC()
        case "regenerative-mc": actions.runRegenerativeMonteCarlo()
        case "adaptive-low-rank-bar": actions.runAdaptiveLowRankBAR()
        case "bar-moment-bounds": actions.runBARMomentBounds()
        case "multiclass-srbm": actions.runMultiClassSRBM()
        case "simulation-finite": actions.runMonteCarloFinite()
        case "ctmc": actions.runGenericCTMC()
        case "finite-decomposition": actions.runFiniteDecomposition()
        case "spectral-finite": actions.runSpectralFinite()
        case "fem-finite": actions.runFiniteElement()
        case "lp-finite": actions.runFiniteLP()
        default: NSSound.beep()
        }
    }

    // MARK: Test

    private var testMenu: some Commands {
        CommandMenu("Test") {
            Button("Run Infinite Test Set…") { actions.runInfiniteTestSet() }
                .disabled(testSetRunning || sheetPresented)
                .help("Sweep random infinite-buffer networks and score every method against simulation")

            Button("Run Finite Test Set…") { actions.runFiniteTestSet() }
                .disabled(testSetRunning || sheetPresented)
                .help("Sweep random finite-buffer networks and score every method against simulation")

            Divider()

            Button("Run Infinite Spectral Convergence…") { actions.runSpectralConvergence() }
                .disabled(testSetRunning || sheetPresented)
                .help("Sweep ρ towards 1 and report how the spectral method's error shrinks")
        }
    }

    // MARK: Window
    // Window ▸ Show Next / Previous Tab (⇧⌘] / ⇧⌘[, plus ⌃⇥ / ⌃⇧⇥ via
    // ContentView's key monitor) and the Focus items are contributed by
    // WorkspaceCommands.

    // MARK: Help

    private var helpMenu: some Commands {
        CommandGroup(replacing: .help) {
            Button("Qnet Help") { QnetHelpWindow.show() }
                .keyboardShortcut("?", modifiers: .command)
                .help("Open the searchable Qnet Help window")

            Divider()

            // Generated from the live menu bar, so it cannot drift from
            // what the menus print.
            Button("Keyboard Shortcuts") { actions.showHelpTopic(.keyboardShortcuts) }
                .help("Every key equivalent in the menu bar, plus the canvas keys that are not printed beside a menu item")

            // One route per document: this is the same topic the Method
            // Reference lists, so it goes through the same dispatch and
            // honours the Settings ▸ Help destination instead of always
            // forcing the Help window open.
            Button("SRBM MLMC Guide") { actions.showHelpTopic(.exactSimulation) }
                .help("Open the SRBM MLMC topic (Settings ▸ Help chooses the window, Status pane or Shell)")
            Button("Release Notes") { ReleaseNotesWindow.show() }
                .help("What changed in this build and in every earlier release")

            // A packaged application does not run this at launch: its native
            // libraries ship inside the bundle, so the only rows that can
            // still fail are the external Python ones. This is the way to
            // ask, rather than being asked every time the app opens.
            Button("Check Dependencies…") { actions.checkDependencies() }
                .help("Re-run the startup checklist: Python, optional modules, and the bundled solvers")

            Divider()

            // Every item explains itself in the Run menu's voice: the full
            // topic title and the solver binary — "SBD — Sequential
            // Bottleneck Decomposition (BNAsbd · bna_sbd)" — so the reader
            // never has to open "SBD" to learn what it is. The two
            // "Spectral Method" and two "Simulation" items are told apart
            // the same way ("… (Infinite Buffers)" / "… (Finite Buffers)").
            Menu("Method Reference") {
                ForEach(HelpTopicGroup.allCases.filter { $0 != .aiProviders }) { group in
                    Section(group.rawValue) {
                        ForEach(HelpTopic.topics(in: group)) { topic in
                            Button(topic.title) { actions.showHelpTopic(topic) }
                                .help(topic.menuHelp)
                        }
                    }
                }
            }

            Menu("Connect an AI Provider") {
                ForEach(HelpTopic.topics(in: .aiProviders)) { topic in
                    Button(topic.title) { actions.showHelpTopic(topic) }
                        .help(topic.menuHelp)
                }
            }
        }
    }
}
