import SwiftUI
import AppKit

/// Menu commands for the main-window workspace: View ▸ Panes (⌥⌘1–6) and
/// Window ▸ tab switching, pane focus and the Shell submenu.
///
/// View keeps only presentation (show / hide, text size); actions on the
/// shell process live in Window ▸ Shell, under Focus Shell.
///
/// Installed from `QnetGUIApp.commands`. Shortcut map (checked against
/// the existing bindings in QnetGUIApp — no collisions):
///   ⌥⌘1 Tools  ⌥⌘2 Status  ⌥⌘3 Shell  ⌥⌘4 AI Assistant  ⌥⌘5 Inspector
///   ⌥⌘6 Results
///   ⌥⌘= / ⌥⌘− Increase / Decrease Pane Text Size (focused pane, via FocusRouter)
///   ⇧⌘] Next Tab  ⇧⌘[ Previous Tab  (⌃⇥ / ⌃⇧⇥ via ContentView's key monitor)
///   ⌘1–⌘9 Show tab N (Window menu lists the first nine tabs by title)
///   ⇧⌘T Reopen Closed Tab (the last tab closed this session)
///   ⌃⌘0 Focus Canvas · ⌃⌘1 Focus Tools  ⌃⌘2 Focus Status  ⌃⌘3 Focus Shell
///   (⌃` alias)  ⌃⌘4 Focus AI Input  ⌃⌘5 Focus Inspector · ⌃⌘6 Focus Results
///   — the ⌃⌘ digit
///   is the pane's ⌥⌘ digit, so "3 is the Shell" is one fact; the canvas,
///   which has no pane toggle, takes 0
///   ⌘K Clear Shell (Window ▸ Shell)
///   ⌃⌘↩ Maximize Pane / Restore Pane Layout (the focused pane fills the
///   window; nothing else in the menu bar carries ↩ with modifiers)
///
/// Pane visibility writes are animated (`DS.Motion.standard`) so a pane
/// fades in and out instead of popping.
struct WorkspaceCommands: Commands {
    @Binding var tabs: [NetworkTab]
    @Binding var activeTabID: UUID
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var terminal: TerminalModel
    /// Tab switching and pane focus are disabled while any sheet is up:
    /// a run sheet writes its status into the editor it was opened from,
    /// so letting ⇧⌘] change tabs underneath it would log the result into
    /// a different tab's network.
    @ObservedObject var menuContext: MenuContext
    /// The tabs closed this session, for Window ▸ Reopen Closed Tab.
    @ObservedObject var closedTabs: ClosedTabHistory
    /// Which pane owns keyboard focus — the text-size items enable and
    /// disable with it (and with the pane's own size limits, which live on
    /// `appSettings` / `terminal`, both observed here so the menu redraws).
    @ObservedObject private var focusRouter = FocusRouter.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Menu("Panes") {
                // Every item carries the same tooltip its toolbar twin
                // shows, so the menu explains itself the way the pane
                // headers do.
                Toggle("Tools", isOn: $appSettings.palettePaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("1", modifiers: [.option, .command])
                    .help(paneToggleHelp("Tools", visible: appSettings.palettePaneVisible))
                Toggle("Status", isOn: $appSettings.statusPaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("2", modifiers: [.option, .command])
                    .help(paneToggleHelp("Status", visible: appSettings.statusPaneVisible))
                Toggle("Shell", isOn: $appSettings.shellPaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("3", modifiers: [.option, .command])
                    .help(paneToggleHelp("Shell", visible: appSettings.shellPaneVisible))
                Toggle("AI Assistant", isOn: $appSettings.aiPaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("4", modifiers: [.option, .command])
                    .help(paneToggleHelp("AI Assistant", visible: appSettings.aiPaneVisible))
                Toggle("Inspector", isOn: $appSettings.inspectorPaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("5", modifiers: [.option, .command])
                    .help(paneToggleHelp("Inspector", visible: appSettings.inspectorPaneVisible))
                Toggle("Results", isOn: $appSettings.resultsPaneVisible.animation(DS.Motion.standard))
                    .keyboardShortcut("6", modifiers: [.option, .command])
                    .help(paneToggleHelp("Results", visible: appSettings.resultsPaneVisible))
                Divider()
                // One preset list, rendered here and in the toolbar's
                // Workspace menu — the feature was three levels deep and
                // effectively undiscoverable.
                Menu("Workspace Presets") {
                    WorkspacePresetItems(appSettings: appSettings)
                }
                .help("Apply a saved pane arrangement for a common workflow")
                // Which WINDOW a pane lives in, beside which panes and how
                // much of the window. Same list as the toolbar's Workspace
                // menu renders, so the two cannot drift.
                Menu("Separate Windows") {
                    PaneWindowItems(appSettings: appSettings)
                }
                .help("Give a pane a window of its own — it leaves the main window's layout and keeps its own size and position")
                Divider()
                // Maximize acts on the pane with keyboard focus, the way
                // ⌥⌘= does, and reads as its own inverse once something is
                // maximized. It changes no pane toggle: restoring puts
                // every divider back where it was.
                Button(maximizeTitle) {
                    withAnimation(DS.Motion.standard) {
                        Self.toggleMaximizeFocusedPane(appSettings: appSettings)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.control, .command])
                .disabled(menuContext.anySheetPresented)
                .help(maximizeHelp)
                Divider()
                // The one command that undoes any arrangement, however it
                // was reached: nothing hidden, nothing maximized, nothing
                // in a window of its own. A user who has lost a pane should
                // need to find only this.
                Button("Show All Panes") {
                    withAnimation(DS.Motion.standard) {
                        appSettings.soloedPane = nil
                        appSettings.reattachAllPanes()
                        appSettings.palettePaneVisible = true
                        appSettings.statusPaneVisible = true
                        appSettings.shellPaneVisible = true
                        appSettings.aiPaneVisible = true
                        appSettings.inspectorPaneVisible = true
                        appSettings.resultsPaneVisible = true
                    }
                }
                .disabled(everyPaneIsHome)
                .help(everyPaneIsHome
                      ? "Every pane is already showing in this window"
                      : "Show the Tools, Status, Shell, AI Assistant, Inspector and Results panes, and bring any pane that has a window of its own back into this one")
                Divider()
                // Real bindings behind the A+ / A− tooltips. Routed to the
                // pane that has keyboard focus (Status, Shell, AI) and
                // disabled — like that pane's own A+ / A− buttons — when
                // the focused pane cannot act: the canvas or the Tools
                // pane has focus (canvas zoom is ⌘= / ⌘−), or the pane is
                // already at the end of its text-size range.
                Button("Increase Pane Text Size") {
                    FocusRouter.shared.zoom(+1) { }
                }
                .keyboardShortcut("=", modifiers: [.option, .command])
                .disabled(!focusRouter.canZoom(+1))
                .help(paneTextSizeHelp(+1))

                Button("Decrease Pane Text Size") {
                    FocusRouter.shared.zoom(-1) { }
                }
                .keyboardShortcut("-", modifiers: [.option, .command])
                .disabled(!focusRouter.canZoom(-1))
                .help(paneTextSizeHelp(-1))
            }
        }

        CommandGroup(before: .windowArrangement) {
            Button("Show Next Tab") {
                Self.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: +1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(tabs.count < 2 || menuContext.anySheetPresented)
            .help("Bring the next document tab forward")

            Button("Show Previous Tab") {
                Self.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(tabs.count < 2 || menuContext.anySheetPresented)
            .help("Bring the previous document tab forward")

            // ⌘1–⌘9 show the first nine tabs, in tab-bar order, the way
            // Safari, Terminal and Xcode number theirs. The list is live:
            // it follows tab order, titles and the active tab (check mark).
            // Zoom to Fit / Zoom to Selection, which used to hold ⌘1 / ⌘2,
            // moved to Keynote's ⇧⌘0 / ⌥⇧⌘0 beside ⌘0 Actual Size.
            Divider()
            ForEach(Array(tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                Toggle(isOn: Binding(
                    get: { activeTabID == tab.id },
                    set: { if $0 { activeTabID = tab.id } }
                )) {
                    Text(tab.title)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(menuContext.anySheetPresented)
                .help(activeTabID == tab.id
                      ? "\u{201C}\(tab.title)\u{201D} is the front tab"
                      : "Bring \u{201C}\(tab.title)\u{201D} to the front (tab \(index + 1))")
            }

            // Safari's key. The stack is per session; a tab closed with
            // Don't Save comes back with its unsaved changes intact.
            Button("Reopen Closed Tab") {
                guard let closed = closedTabs.pop() else { return }
                let tab = closed.makeTab()
                tabs.append(tab)
                activeTabID = tab.id
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!closedTabs.canReopen || menuContext.anySheetPresented)
            .help(closedTabs.mostRecentTitle.map { "Bring back “\($0)”, the last tab closed" }
                  ?? "No tab has been closed in this session")

            Divider()

            // The ⌃⌘ digit is the pane's ⌥⌘ digit (View ▸ Panes), so "3 is
            // the Shell" is one fact, not two; the canvas has no pane
            // toggle and takes 0. ⌃` also focuses the Shell (see
            // MenuKeyAliases) — a menu item can print only one key.
            //
            // Every one of these goes through `reveal(_:appSettings:then:)`
            // rather than flipping the pane's toggle itself, because
            // "hidden" is only one of the three ways a pane can be off
            // screen — see that function. Each used to answer just the one,
            // and so did nothing at all whenever another pane was
            // maximized.
            Button("Focus Canvas") {
                Self.reveal(.canvas, appSettings: appSettings) { FocusRouter.shared.focus(.canvas) }
            }
            .keyboardShortcut("0", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Move keyboard focus to the drawing canvas, restoring the pane layout first if another pane has the whole window")

            // The Tools pane has no text size, so ⌥⌘= / ⌥⌘− stay dimmed
            // while it holds focus (their tooltip says why); the letter
            // shortcuts select tools without focusing it.
            Button("Focus Tools") {
                Self.reveal(.palette, appSettings: appSettings) { FocusRouter.shared.focus(.palette) }
            }
            .keyboardShortcut("1", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the Tools pane if hidden and move keyboard focus to it (arrow keys and Space then pick a tool)")

            Button("Focus Status") {
                Self.reveal(.status, appSettings: appSettings) { FocusRouter.shared.focus(.status) }
            }
            .keyboardShortcut("2", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the Status pane if hidden and move keyboard focus to it")

            Button("Focus Shell") {
                Self.focusShell(appSettings: appSettings)
            }
            .keyboardShortcut("3", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the Shell pane if hidden and move keyboard focus to it (⌃` does the same)")

            Button("Focus AI Input") {
                Self.reveal(.ai, appSettings: appSettings) { FocusRouter.shared.focus(.ai) }
            }
            .keyboardShortcut("4", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the AI Assistant pane if hidden and put the caret in its composer")

            Button("Focus Inspector") {
                Self.reveal(.inspector, appSettings: appSettings) { FocusRouter.shared.focus(.inspector) }
            }
            .keyboardShortcut("5", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the Inspector pane if hidden and put the caret in the selected node's first field")

            Button("Focus Results") {
                Self.reveal(.results, appSettings: appSettings) { FocusRouter.shared.focus(.results) }
            }
            .keyboardShortcut("6", modifiers: [.control, .command])
            .disabled(menuContext.anySheetPresented)
            .help("Show the Results workspace if hidden and move keyboard focus to its filter")

            // Actions on the shell process. These are not presentation, so
            // they do not belong in View; they sit under Focus Shell in the
            // Window menu, next to the pane they act on.
            Menu("Shell") {
                Button("Clear Shell") {
                    terminal.clearTerminal()
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("Empty the Shell pane without restarting the shell process")

                // No shortcut: ⌘F already routes to the Shell's find bar
                // when the Shell has keyboard focus (Edit ▸ Find in Shell…).
                Button("Find in Shell…") {
                    revealShellThen { terminal.showFind() }
                }
                .help("Search the Shell scrollback")

                Divider()

                Button("Restart Shell…") {
                    WorkspaceCommands.confirmRestartShell(terminal)
                }
                .help("Terminate and relaunch the shell process (confirms first)")
            }

            Divider()
        }
    }

    /// Every pane showing, in this window. A detached pane is showing but
    /// is not here, so "Show All Panes" still has something to do.
    private var everyPaneIsHome: Bool {
        appSettings.palettePaneVisible && appSettings.statusPaneVisible
            && appSettings.inspectorPaneVisible
            && appSettings.shellPaneVisible && appSettings.aiPaneVisible
            && appSettings.resultsPaneVisible
            && !appSettings.hasDetachedPane
    }

    private var maximizeTitle: String { Self.maximizeTitle(appSettings) }
    private var maximizeHelp: String { Self.maximizeHelp(appSettings) }

    private func paneToggleHelp(_ pane: String, visible: Bool) -> String {
        visible ? "Hide the \(pane) pane" : "Show the \(pane) pane"
    }

    /// Says which pane the command would act on, or why it is dimmed.
    private func paneTextSizeHelp(_ direction: Int) -> String {
        let verb = direction > 0 ? "Increase" : "Decrease"
        guard let pane = focusRouter.zoomTargetName else {
            return "\(verb) the text size of the focused pane — click in the Status, Shell or AI Assistant pane first (the canvas uses ⌘= / ⌘−)"
        }
        guard focusRouter.canZoom(direction) else {
            return "The \(pane) pane is already at its \(direction > 0 ? "largest" : "smallest") text size"
        }
        return "\(verb) the \(pane) pane's text size"
    }

    private func revealShellThen(_ action: @escaping @MainActor () -> Void) {
        Self.revealShell(appSettings: appSettings, then: action)
    }

    /// Window ▸ Focus Shell, shared with the ⌃` alias in `MenuKeyAliases`
    /// so both entry points reveal the pane the same way.
    @MainActor
    static func focusShell(appSettings: AppSettings) {
        revealShell(appSettings: appSettings) { FocusRouter.shared.focus(.shell) }
    }

    @MainActor
    static func revealShell(appSettings: AppSettings,
                            then action: @escaping @MainActor () -> Void) {
        reveal(.shell, appSettings: appSettings, then: action)
    }

    /// Put `pane` genuinely on screen, then run `action` — on the settled
    /// layout when something had to move, and on the next run-loop turn
    /// when nothing did.
    ///
    /// "Visible" is three conditions, not one, and every caller that only
    /// answered the first has been a silent no-op:
    ///
    ///  1. the pane's own View ▸ Panes toggle is on;
    ///  2. no OTHER pane has the whole window (`ContentView.shows(_:)` draws
    ///     nothing else while one is maximized) — so with the Results pane
    ///     maximized, flipping the Status toggle sets a flag nobody reads
    ///     and focus lands nowhere;
    ///  3. if the pane lives in a window of its own, that window is in
    ///     front — making a view the first responder of a window that is
    ///     not key moves no visible focus at all.
    ///
    /// Case 3 deliberately does NOT clear someone else's maximize: the main
    /// window's arrangement is not in the way of a pane that is not in it,
    /// and rearranging a window the user did not ask about is a worse
    /// surprise than the one it would fix. Nor is a pane's own maximize
    /// disturbed in case 2 — that already shows it.
    @MainActor
    static func reveal(_ pane: FocusRouter.Pane,
                       appSettings: AppSettings,
                       then action: @escaping @MainActor () -> Void = {}) {
        if appSettings.isDetached(pane) {
            guard !appSettings.isPaneEnabled(pane) else {
                // The window is already open; only the app's attention has
                // to move. Nothing is being laid out, so nothing is worth
                // waiting for.
                soon { PaneWindowController.present(pane); action() }
                return
            }
            withAnimation(DS.Motion.standard) { appSettings.setPaneEnabled(pane, true) }
            afterLayout {
                PaneWindowController.present(pane)
                action()
            }
            return
        }
        // Is anything actually in the way? Its own toggle off, or another
        // pane holding the whole window. If neither, the pane is drawn and
        // drawn here, and the action must not sit out a settle delay for a
        // layout that is not going to change — ⌃⌘0 on a window that needs
        // nothing done to it should feel instant.
        let blocked = !appSettings.isPaneEnabled(pane)
            || (appSettings.soloedPane.map { $0 != pane } ?? false)
        guard blocked else {
            soon(action)
            return
        }
        withAnimation(DS.Motion.standard) {
            if let solo = appSettings.soloedPane, solo != pane {
                appSettings.soloedPane = nil
            }
            if !appSettings.isPaneEnabled(pane) {
                appSettings.setPaneEnabled(pane, true)
            }
        }
        afterLayout(action)
    }

    /// Next turn of the run loop, not next frame. The pane is already on
    /// screen; all this buys is that focus moves after the event that asked
    /// for it has finished being dispatched — which is what `afterLayout`
    /// gave these call sites before, minus a settle delay there is now
    /// nothing to settle.
    private static func soon(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { action() }
    }

    /// Runs after SwiftUI has had a chance to insert a newly-shown pane
    /// (and its show animation to finish, so focus lands on a laid-out view).
    static func afterLayout(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.standardSettleDelay + 0.05) {
            action()
        }
    }

    static func showAdjacentTab(tabs: [NetworkTab], activeTabID: Binding<UUID>, offset: Int) {
        guard tabs.count > 1,
              let idx = tabs.firstIndex(where: { $0.id == activeTabID.wrappedValue }) else { return }
        let next = (idx + offset + tabs.count) % tabs.count
        activeTabID.wrappedValue = tabs[next].id
    }

    /// The pane Maximize would act on: whatever is already maximized (so
    /// the command is its own inverse), else the pane with keyboard focus,
    /// else the canvas.
    ///
    /// The canvas fallback is why this is not optional. `focusedPane` is nil
    /// until a click resolves through `pane(containing:)`, which is the
    /// state at every launch — so the command and ⌃⌘↩ used to be dimmed
    /// exactly when a user first reaches for them. Xcode's pane commands act
    /// on the editor in that situation; ours acts on the document, which is
    /// the canvas. The Tools palette is width-capped and is never a target,
    /// so focus sitting there also falls through to the canvas, and so is
    /// a pane the user has torn out into a window of its own.
    ///
    /// The three helpers below are static because the menu item and the
    /// toolbar's Workspace menu are two renderings of one command, and a
    /// title that read "Maximize Pane" in one and "Restore Pane Layout" in
    /// the other would be worse than having no toolbar entry at all.
    @MainActor
    static func maximizeTarget(_ appSettings: AppSettings) -> FocusRouter.Pane {
        if let solo = appSettings.soloedPane { return solo }
        guard let focused = FocusRouter.shared.focusedPane,
              focused.canBeMaximized,
              // A pane in a window of its own already has one, and it has
              // no claim on the main window's other panes. Focus sitting
              // there falls through to the canvas rather than leaving the
              // command enabled and inert — the very failure the canvas
              // fallback was added to fix.
              !appSettings.isDetached(focused) else { return .canvas }
        return focused
    }

    @MainActor
    static func maximizeTitle(_ appSettings: AppSettings) -> String {
        appSettings.soloedPane == nil ? "Maximize Pane" : "Restore Pane Layout"
    }

    @MainActor
    static func maximizeHelp(_ appSettings: AppSettings) -> String {
        if let solo = appSettings.soloedPane {
            return "Put every pane back exactly where it was before the \(solo.displayName) pane was maximized"
        }
        return "Give the \(maximizeTarget(appSettings).displayName) pane the whole window; nothing is hidden and every divider comes back where it is now"
    }

    /// Maximize the focused pane, or restore the saved arrangement when
    /// one is already maximized. The single rule behind View ▸ Panes, the
    /// toolbar's Workspace menu and every pane header's maximize button.
    @MainActor
    static func toggleMaximizeFocusedPane(appSettings: AppSettings) {
        if appSettings.soloedPane != nil {
            appSettings.soloedPane = nil
            return
        }
        // Through `maximizeTarget`, not `focusedPane`, so the command does
        // what its own tooltip says it will when nothing has been clicked
        // yet.
        appSettings.toggleSolo(maximizeTarget(appSettings))
    }

    /// Applies one workspace preset. Leaving the maximized state is part
    /// of applying a preset: a preset the user cannot see land is not a
    /// preset.
    ///
    /// `outerRowFractions` is that same argument applied to the dividers.
    /// A preset whose name promises a proportion ("Shell": the shell as the
    /// second half of the window) has to move one, because the saved
    /// `SplitPane.OuterVSplit.*` heights are otherwise re-applied over the
    /// top of it and the command looks broken. Each entry maps a row of the
    /// outer split ("results", "bottom") to its share of the split's height;
    /// an empty dictionary — the default, and what the arrangement-only
    /// presets pass — leaves every divider exactly where the user put it.
    ///
    /// The heights are written BEFORE the visibility flags because
    /// `SplitViewConfigurator.restore()` runs off the pane-set change and
    /// reads the keys as they stand at that moment.
    @MainActor
    static func applyWorkspacePreset(
        _ appSettings: AppSettings,
        palette: Bool,
        status: Bool,
        inspector: Bool,
        results: Bool,
        shell: Bool,
        ai: Bool,
        outerRowFractions: [String: Double] = [:]
    ) {
        if !outerRowFractions.isEmpty {
            // Stand the divider autosave down for the length of the
            // transition first: AppKit lays the rows out, and saves what it
            // sees, before the restore that reads these keys back can run.
            WorkspaceLayout.beginPresetTransition()
            for (row, fraction) in outerRowFractions {
                WorkspaceLayout.setOuterRowHeight(row, fraction: fraction)
            }
        }
        withAnimation(DS.Motion.standard) {
            appSettings.soloedPane = nil
            // A preset is a claim about THIS window's arrangement, so it
            // has to be about every pane it names — one still floating in a
            // window of its own would leave the claim half true, and the
            // preset would look as though it had skipped a pane.
            appSettings.reattachAllPanes()
            appSettings.palettePaneVisible = palette
            appSettings.statusPaneVisible = status
            appSettings.inspectorPaneVisible = inspector
            appSettings.resultsPaneVisible = results
            appSettings.shellPaneVisible = shell
            appSettings.aiPaneVisible = ai
        }
        // Applying a preset while its panes are already the ones showing
        // changes no pane set, so nothing else would re-read the keys —
        // and that is exactly when the user is asking for the proportion
        // rather than the arrangement.
        guard !outerRowFractions.isEmpty else { return }
        afterLayout { WorkspaceLayout.reapplySavedSizes() }
    }

    /// Restart is destructive (kills the shell, forgets the saved
    /// transcript), so it always confirms. Clear (⌘K) is the
    /// non-destructive alternative and is named in the dialog.
    @MainActor
    static func confirmRestartShell(_ terminal: TerminalModel) {
        guard ConfirmAlert.destructive(
            title: "Restart the shell?",
            message: "The running shell process will be terminated and the saved transcript will not be restored on the next launch. To only empty the screen, use Clear Shell (⌘K) instead.",
            confirmTitle: "Restart Shell"
        ) else { return }
        TerminalModel.clearSavedTranscript()
        terminal.restart()
    }
}

/// Nests a `@CommandsBuilder` block so a `.commands { }` body can hold
/// more than the builder's ten-child limit.
struct CommandsGroup<Content: Commands>: Commands {
    private let content: Content

    init(@CommandsBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some Commands {
        content
    }
}

// MARK: - Workspace presets

/// The workspace-preset buttons, in one place because they are rendered
/// twice: View ▸ Panes ▸ Workspace Presets and the toolbar's Workspace
/// menu. The list is ordered by how much of the window each arrangement
/// gives to the canvas, from "everything around it" down to "canvas only".
///
/// A preset is a *pane arrangement*, never a document change. It leaves
/// every divider where the user last dragged it — the split-view autosave
/// keeps each pane's width and height — with one exception, spelled out in
/// `applyWorkspacePreset`: a preset whose NAME is a claim about proportion
/// sets that proportion, because a saved divider would otherwise override
/// it and the command would appear to do nothing. Two of the five make such
/// a claim, and both quote the fraction below in their own tooltip.
struct WorkspacePresetItems: View {
    @ObservedObject var appSettings: AppSettings

    /// The Shell preset's promise: the shell row's share of the window's
    /// height, measured the way the user would measure it — see
    /// `WorkspaceLayout.setOuterRowHeight`, which is careful not to quietly
    /// take the share out of the smaller workspace area instead. Named
    /// because the button's tooltip prints it, so the number the user reads
    /// and the number the preset writes cannot drift.
    static let shellRowFraction = 0.45
    /// The Analyze Results preset's promise, same rule.
    static let resultsRowFraction = 0.5

    var body: some View { presetMenuItems }

    @ViewBuilder private var presetMenuItems: some View {
        Button("Build Network") {
            apply(palette: true, status: true, inspector: true,
                  results: false, shell: false, ai: false)
        }
        .help("Show the drawing tools, inspector and status log")

        Button("Analyze Results") {
            apply(palette: false, status: true, inspector: true,
                  results: true, shell: false, ai: false,
                  outerRowFractions: ["results": Self.resultsRowFraction])
        }
        .help("Give the structured Results workspace \(Self.percent(Self.resultsRowFraction)) of the window, with the inspector and status log for context")

        Button("Run and Diagnose") {
            apply(palette: false, status: true, inspector: false,
                  results: true, shell: true, ai: false)
        }
        .help("Show results, solver output and the status log together")

        // The shell-forward arrangement: the network above, the
        // interactive shell below at 45 % of the window's height, and the
        // status log for the run's provenance. Nothing else competes for
        // height, which is what makes the Shell readable rather than an
        // eleven-row strip. This one MOVES the divider — see
        // `applyWorkspacePreset` — because a saved 243-pt bottom row is
        // otherwise restored straight over the arrangement.
        Button("Shell") {
            apply(palette: false, status: true, inspector: false,
                  results: false, shell: true, ai: false,
                  outerRowFractions: ["bottom": Self.shellRowFraction])
        }
        .help("Make the interactive shell the second half of the window — it takes \(Self.percent(Self.shellRowFraction)) of the window's height, with the network above and the status log for context")

        Button("Canvas Only") {
            apply(palette: false, status: false, inspector: false,
                  results: false, shell: false, ai: false)
        }
        .help("Hide every pane without changing the network")
    }

    private func apply(
        palette: Bool, status: Bool, inspector: Bool,
        results: Bool, shell: Bool, ai: Bool,
        outerRowFractions: [String: Double] = [:]
    ) {
        WorkspaceCommands.applyWorkspacePreset(
            appSettings,
            palette: palette, status: status, inspector: inspector,
            results: results, shell: shell, ai: ai,
            outerRowFractions: outerRowFractions
        )
    }

    /// "45 %" — a fraction as the tooltips print it, with the thin space
    /// the rest of the app's percentages use.
    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))\u{202F}%"
    }
}

// MARK: - Pane windows

/// The pane-window toggles, in one place because they are rendered twice:
/// View ▸ Panes ▸ Separate Windows and the toolbar's Workspace menu.
///
/// Tearing a pane out is a deliberate act and lives only here and in the
/// toolbar — not as a seventh glyph in every pane header, which already
/// carries up to eight controls. Putting one BACK is the opposite: it is
/// offered from the detached window's own header (`PaneSoloButton`), from
/// that window's close button, and from "Return All Panes" below, because
/// a user who has lost track of a pane must not have to remember which
/// menu took it away.
///
/// Two panes are missing from the list on purpose — see
/// `FocusRouter.Pane.canBeDetached`.
struct PaneWindowItems: View {
    @ObservedObject var appSettings: AppSettings

    private static let detachable = FocusRouter.Pane.allCases.filter(\.canBeDetached)

    var body: some View { paneWindowMenuItems }

    /// Named for the lint as much as for the reader: `design_lint.sh`
    /// decides "is this `Divider()` a real menu separator" from the name of
    /// the declaration that builds it, the same way `presetMenuItems`
    /// above is named.
    @ViewBuilder private var paneWindowMenuItems: some View {
        ForEach(Self.detachable, id: \.self) { pane in
            Toggle(pane.displayName, isOn: binding(for: pane))
                .help(help(for: pane))
        }

        Divider()

        Button("Return All Panes to the Main Window") {
            withAnimation(DS.Motion.standard) { appSettings.reattachAllPanes() }
        }
        .disabled(!appSettings.hasDetachedPane)
        .help(appSettings.hasDetachedPane
              ? "Close every pane window and put its pane back into the main window's layout"
              : "Every pane is already in the main window")
    }

    /// Switching a pane out also switches it ON. A pane torn into a window
    /// the user cannot see would be a menu item that appears to do nothing,
    /// and the toggle in View ▸ Panes above stays the record of whether the
    /// pane is wanted at all — hiding it later closes the window without
    /// forgetting that this pane lives outside.
    private func binding(for pane: FocusRouter.Pane) -> Binding<Bool> {
        Binding(
            get: { appSettings.isDetached(pane) },
            set: { detached in
                if detached {
                    // Unanimated on the way out, and that is load-bearing
                    // rather than a style choice — see "Why tearing a pane
                    // OUT is never animated" at the top of
                    // PaneDetachment.swift. Coming back is animated like
                    // any other pane appearing.
                    appSettings.setPaneEnabled(pane, true)
                    appSettings.setDetached(pane, true)
                } else {
                    withAnimation(DS.Motion.standard) {
                        appSettings.setDetached(pane, false)
                    }
                }
            }
        )
    }

    private func help(for pane: FocusRouter.Pane) -> String {
        appSettings.isDetached(pane)
            ? "Put the \(pane.displayName) pane back into the main window, where it was before"
            : "Show the \(pane.displayName) pane in a window of its own, with its own size and position — it leaves the main window's layout, and the layout closes over it"
    }
}
