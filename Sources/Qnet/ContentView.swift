import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The key a tooltip in this file cites, read from the one table the
/// debug-build menu audit checks against the menu bar — never typed.
@MainActor
private func shortcut(_ command: KeyboardShortcutReference.Command) -> String {
    KeyboardShortcutReference.key(for: command)
}

struct ContentView: View {
    @Binding var tabs: [NetworkTab]
    @Binding var activeTabID: UUID
    /// Installed by QnetGUIApp: the guarded owner of every tab close (see
    /// TabClosing.swift). The tab bar never edits `tabs` to close one.
    var tabActions: TabActions = .inert
    @EnvironmentObject private var editor: NetworkEditorModel
    @EnvironmentObject private var terminal: TerminalModel
    @EnvironmentObject private var appSettings: AppSettings
    /// Not read by anything in this view. It is held so that
    /// `PaneWindowHost` can re-inject it into a detached AI pane, which is
    /// hosted by AppKit and therefore outside this view's SwiftUI
    /// environment. The four objects QnetGUIApp injects into the scene are
    /// exactly the four a detached pane may need.
    @EnvironmentObject private var ai: AIModel
    /// Which pane owns keyboard focus. The four side panes light their
    /// header rule; the canvas has no header, so its tab bar carries the
    /// same 2-pt accent rule instead (Window ▸ Focus Canvas is visible).
    @ObservedObject private var focusRouter = FocusRouter.shared

    private var workspaceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private var activeTab: NetworkTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    private var windowTitle: String {
        activeTab?.title ?? "Untitled"
    }

    private var windowSubtitle: String {
        guard let url = editor.currentFileURL else { return "Unsaved network" }
        return (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Which panes are on screen
    //
    // Two questions, deliberately separate. `AppSettings.isPaneEnabled`
    // is the user's View ▸ Panes choice, which a maximize must never
    // change — it is what the arrangement goes back to. `shows` is what is
    // actually drawn: while one pane is maximized it is the only one.
    //
    // EVERY derived pane list and every `if` in `body` asks `shows`, and
    // nothing asks the stored flag directly, because `SplitViewConfigurator`
    // saves and restores divider positions only while the pane list it was
    // handed matches the split's arranged subviews. A list that disagreed
    // with the view tree would not error; it would silently stop persisting
    // the window's layout.

    /// Whether the pane is drawn right now. `AppSettings.soloedPane` is
    /// the single sanitized answer to "is anything maximized"; asking it
    /// here rather than re-deriving one is what keeps this view tree, the
    /// pane headers' buttons and the View ▸ Panes item in agreement.
    private func shows(_ pane: FocusRouter.Pane) -> Bool {
        // A detached pane is in a window of its own, and this is the ONE
        // place that keeps it from also being here. Two mounted copies of
        // the Shell would leave two SwiftTermView wrappers fighting over
        // TerminalModel.hostView; one copy, re-parented into the other
        // window, is what hiding and showing the pane already does and is
        // what preserves the shell's PID and scrollback.
        if appSettings.isDetached(pane) { return false }
        if let solo = appSettings.soloedPane { return solo == pane }
        return appSettings.isPaneEnabled(pane)
    }

    /// The panes that should have a window of their own right now: torn
    /// out AND switched on. Hiding a detached pane closes its window
    /// without forgetting where the pane lives, so showing it again brings
    /// the window back rather than docking it.
    private var detachedPaneWindows: Set<FocusRouter.Pane> {
        appSettings.detachedPanes.filter(appSettings.isPaneEnabled)
    }

    /// The top row holds the Tools palette, the canvas and the right
    /// column; it is absent only while a pane in another row is maximized.
    private var topRowVisible: Bool {
        shows(.palette) || shows(.canvas) || rightColumnVisible
    }

    private var bottomRowVisible: Bool {
        shows(.shell) || shows(.ai)
    }

    /// Vertical workspace rows in display order. Results gets its own
    /// full-width row so station tables are not squeezed into a sidebar.
    private var outerPanes: [String] {
        var panes: [String] = []
        if topRowVisible { panes.append("top") }
        if shows(.results) { panes.append("results") }
        if bottomRowVisible { panes.append("bottom") }
        return panes
    }

    /// The right column holds the Inspector and the Status pane; it is
    /// present while either is.
    private var rightColumnVisible: Bool {
        shows(.status) || shows(.inspector)
    }

    /// The top split's panes. The right column is one pane, "right",
    /// whichever of the Inspector and the Status pane it holds — its
    /// saved width is the column's, not the Status pane's (the old key,
    /// `…status`, is migrated once by `SplitKeyMigration`).
    private var topPanes: [String] {
        var p: [String] = []
        if shows(.palette) { p.append("palette") }
        if shows(.canvas) { p.append("canvas") }
        if rightColumnVisible { p.append("right") }
        return p
    }

    private var rightPanes: [String] {
        var p: [String] = []
        if shows(.inspector) { p.append("inspector") }
        if shows(.status) { p.append("status") }
        return p
    }

    private var bottomPanes: [String] {
        var p: [String] = []
        if shows(.shell) { p.append("terminal") }
        if shows(.ai) { p.append("ai") }
        return p
    }

    /// The pane that currently has the whole window, or nil. Read by the
    /// toolbar's Workspace item so a remembered maximize is visible on
    /// screen rather than only in `defaults read`.
    private var maximizedPane: FocusRouter.Pane? { appSettings.soloedPane }

    /// Bit field of the six pane toggles, watched so that showing or
    /// hiding ANY pane leaves the maximized state — whichever entry point
    /// did it (the menu, the toolbar, a preset, an AppleScript-driven
    /// default). Without this a toggle while one pane is maximized would
    /// appear to do nothing at all.
    private var paneVisibilitySignature: Int {
        var bits = 0
        for (i, pane) in FocusRouter.Pane.allCases.enumerated() where appSettings.isPaneEnabled(pane) {
            bits |= 1 << i
        }
        return bits
    }

    /// Ideal height of the bottom row. The Shell on its own, with the
    /// Results row away, IS the workspace's second half rather than a
    /// footer — that is exactly the arrangement the Shell workspace preset
    /// produces — so it asks for `shellRowIdealHeight` and settles at
    /// roughly 45 % of the content area against the canvas row's ideal.
    /// With the AI pane beside it, or the Results row also present, three
    /// rows have to fit and it goes back to the footer ideal.
    private var bottomRowIdealHeight: CGFloat {
        shows(.shell) && !shows(.ai) && !shows(.results)
            ? DS.Layout.shellRowIdealHeight
            : DS.Layout.bottomRowIdealHeight
    }

    /// Minimum height of the window's content, summed over the rows that
    /// are actually on screen.
    ///
    /// A flat minimum sized for all three rows (720 pt) plus the ~52-pt
    /// unified title bar does not fit the ~706-pt visible frame of an
    /// 800-pt display with the Dock showing, so a user working with the
    /// bottom row hidden could not resize the window onto their own
    /// screen. AppKit does not shrink a window when its minimum drops, so
    /// hiding a pane will not pull an already-minimum window in — it only
    /// makes the smaller size reachable by dragging.
    private var contentMinHeight: CGFloat {
        outerPanes.reduce(CGFloat.zero) { total, row in
            total + (row == "top" ? DS.Layout.canvasRowMinHeight : DS.Layout.bottomRowMinHeight)
        }
    }

    // MARK: - The two parameter editors, as movable panels
    //
    // Both were `.sheet(item:)` presentations until round 4, and they are
    // the two forms a user opens most often. A sheet is pinned to the
    // middle of the window and covers what is behind it, and what is
    // behind these two is the station or the link they describe — the
    // exact case `DSPanelWindow`'s file header argues panels exist for.
    //
    // The presenters live beside the forms they present
    // (`NodeParameterEditorPanel`, `LinkParameterEditorPanel`), the same
    // way `ArchetypeGalleryPanel` and `CanvasExportOptionsPresenter` do:
    // they own the band, the close guard and the retarget, all of which
    // depend on the form's own geometry rule. What belongs HERE is only
    // the mirroring — `editor.parameterEditorTarget` /
    // `.linkParameterEditorTarget` remain the single switch every opener
    // writes, and these watchers turn a change in it into a presentation.
    //
    // `isModalSheetPresented` still reads the two targets, so the gate
    // that keeps bare canvas tool letters dead under a form full of
    // number fields is unchanged.

    /// Bring both parameter panels in line with the document. Called from
    /// the two watchers below and once on appear, so a window rebuilt with
    /// a target already set (a reopened scene) still shows its form.
    private func syncParameterPanels() {
        NodeParameterEditorPanel.sync(editor: editor,
                                      targetID: editor.parameterEditorTarget?.id)
        LinkParameterEditorPanel.sync(editor: editor,
                                      targetID: editor.linkParameterEditorTarget?.id)
    }

    /// Take both panels down without clearing the targets. A panel is an
    /// AppKit window, not part of this view tree, so it has to be closed
    /// by hand when the view that owns it goes; `DSPanelWindow.close(id:)`
    /// deliberately does not run the presenter's `onClose`, which is right
    /// on this path — the document is being taken away, not cancelled, and
    /// writing to it during teardown is what we do not want.
    private func closeParameterPanels() {
        DSPanelWindow.close(id: NodeParameterEditorPanel.panelID)
        DSPanelWindow.close(id: LinkParameterEditorPanel.panelID)
    }

    var body: some View {
        // One stable split tree. Panes are conditionally *present*
        // (never re-parented into a different tree), so collapsing the
        // AI pane, the status pane or the whole bottom row keeps the
        // terminal's identity; the shell process is additionally pinned
        // by TerminalModel.hostView caching.
        //
        // Maximizing a pane is the same mechanism, not a second one: every
        // OTHER pane simply stops being present, including — for the first
        // time — the canvas and the whole top row. Nothing moves branch, so
        // maximizing the Shell leaves SwiftTermView mounted exactly where it
        // was, and maximizing anything else unmounts it the way hiding it
        // already did.
        VSplitView {
            if topRowVisible {
                HSplitView {
                    // Every optional pane fades (`.transition(.opacity)`): the
                    // split view re-flows the neighbours, but the pane's chrome
                    // no longer pops in and out.
                    if shows(.palette) {
                        ToolPaletteView()
                            .frame(minWidth: DS.Layout.palettePaneMinWidth,
                                   idealWidth: DS.Layout.palettePaneIdealWidth,
                                   maxWidth: DS.Layout.palettePaneMaxWidth)
                            .transition(.opacity)
                    }

                    if shows(.canvas) {
                        VStack(spacing: 0) {
                            TabBarView(
                                tabs: $tabs,
                                activeTabID: $activeTabID,
                                tabActions: tabActions,
                                isCanvasFocused: focusRouter.focusedPane == .canvas
                            )
                            NetworkCanvasScrollContainer()
                            CanvasStatusBar()
                        }
                        .background(PaneFocusMarker(.canvas))
                        .background(SplitViewConfigurator(
                            autosaveName: "TopHSplit",
                            panes: topPanes,
                            canonical: SplitViewConfigurator.topCanonical,
                            flexible: "canvas"
                        ))
                        .frame(minWidth: DS.Layout.canvasPaneMinWidth)
                        .transition(.opacity)
                    }

                    if rightColumnVisible {
                        // Right column: the docked Inspector above the Status
                        // pane, each optional, in their own vertical split so
                        // the user decides how much of the column each gets.
                        // The Analytical / Re-entrant / Warnings pills sit
                        // under the Status header, inside the pane, so the
                        // column reads header / form / header / pills / log.
                        VSplitView {
                            if shows(.inspector) {
                                InspectorPaneView()
                                    .frame(minHeight: DS.Layout.inspectorPaneMinHeight,
                                           idealHeight: DS.Layout.inspectorPaneIdealHeight)
                                    .transition(.opacity)
                            }
                            if shows(.status) {
                                StatusPanelView(showsFlagBar: true)
                                    .frame(minHeight: DS.Layout.statusPaneMinHeight)
                                    .background(SplitViewConfigurator(
                                        autosaveName: "RightVSplit",
                                        panes: rightPanes,
                                        canonical: ["inspector", "status"],
                                        flexible: "status"
                                    ))
                                    .transition(.opacity)
                            }
                        }
                        // One width for the column whichever pane it holds, so
                        // toggling the Inspector never resizes it (and, through
                        // the coupled-width mirror, the AI pane) under the pointer.
                        .frame(minWidth: DS.Layout.rightColumnMinWidth,
                               idealWidth: DS.Layout.rightColumnIdealWidth)
                        .transition(.opacity)
                    }
                }
                .background(SplitViewConfigurator(
                    autosaveName: "OuterVSplit",
                    panes: outerPanes,
                    canonical: ["top", "results", "bottom"],
                    flexible: "top"
                ))
                .frame(minHeight: DS.Layout.canvasRowMinHeight,
                       idealHeight: DS.Layout.canvasRowIdealHeight)
                .transition(.opacity)
            }

            if shows(.results) {
                ResultsWorkspaceView(tabID: activeTabID, networkTitle: windowTitle)
                    .frame(minHeight: DS.Layout.bottomRowMinHeight,
                           idealHeight: DS.Layout.bottomRowIdealHeight)
                    .transition(.opacity)
            }

            if bottomRowVisible {
                HSplitView {
                    if shows(.shell) {
                        TerminalPaneView(workingDirectory: workspaceURL)
                            .background(SplitViewConfigurator(
                                autosaveName: "BottomHSplit",
                                panes: bottomPanes,
                                canonical: ["terminal", "ai"],
                                flexible: "terminal"
                            ))
                            .frame(minWidth: DS.Layout.canvasPaneMinWidth)
                            .transition(.opacity)
                    }

                    if shows(.ai) {
                        AIPaneView()
                            .background {
                                if !shows(.shell) {
                                    SplitViewConfigurator(
                                        autosaveName: "BottomHSplit",
                                        panes: bottomPanes,
                                        canonical: ["terminal", "ai"],
                                        flexible: "terminal"
                                    )
                                }
                            }
                            .frame(minWidth: DS.Layout.sidePaneMinWidth,
                                   idealWidth: CGFloat(appSettings.aiPaneWidth))
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: DS.Layout.bottomRowMinHeight,
                       idealHeight: bottomRowIdealHeight)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            CornerResizeOverlay(
                aiPaneVisible: shows(.ai) && shows(.shell)
            )
        }
        .frame(minWidth: DS.Layout.Window.mainMinWidth,
               minHeight: contentMinHeight)
        .background(WindowFrameAutosave(name: "BNETMainWindow"))
        // Opens, closes and feeds the windows of any torn-out panes. It
        // has to live here: this is the only place that holds all four
        // scene environment objects, the front tab and the workspace URL
        // at once, and a detached pane is hosted outside the SwiftUI
        // environment and needs every one of them handed to it.
        .background(PaneWindowHost(
            editor: editor,
            terminal: terminal,
            appSettings: appSettings,
            ai: ai,
            activeTabID: activeTabID,
            networkTitle: windowTitle,
            workingDirectory: workspaceURL,
            wanted: detachedPaneWindows
        ))
        .background(WindowDocumentState(
            representedURL: editor.currentFileURL,
            isEdited: editor.hasUnsavedChanges
        ))
        .background(TabSwitchKeyMonitor(
            onNext: { WorkspaceCommands.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: +1) },
            onPrevious: { WorkspaceCommands.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: -1) }
        ))
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar(id: "qnet.main") {
            ToolbarItem(id: "straighten", placement: .primaryAction) {
                Button {
                    editor.straightenNetwork()
                } label: {
                    Label("Straighten Network", systemImage: DS.Symbol.extentHorizontal)
                }
                .help("Straighten Network (Network ▸ Straighten Network)")
                .accessibilityLabel("Straighten Network")
            }
            // Same command, name and tooltip as View ▸ Zoom to Fit: frames
            // the network by changing the view transform only. Re-laying
            // the nodes out is Straighten, the button beside it.
            ToolbarItem(id: "fit", placement: .primaryAction) {
                Button {
                    editor.zoomToFit()
                } label: {
                    Label("Zoom to Fit", systemImage: DS.Symbol.zoomToFit)
                }
                .disabled(editor.nodes.isEmpty)
                .help("Zoom to Fit — frame the whole network without moving any node (View ▸ Zoom to Fit, \(shortcut(.zoomToFit)))")
                .accessibilityLabel("Zoom to Fit")
            }
            ToolbarItem(id: "snap", placement: .primaryAction, showsByDefault: false) {
                Toggle(isOn: $editor.snapToGrid) {
                    Label("Snap to Grid", systemImage: DS.Symbol.snapToGrid)
                }
                .help("Snap to Grid (\(shortcut(.snapToGrid)))")
                .accessibilityLabel("Snap to Grid")
            }
            // The workspace arrangement, one click from the toolbar. The
            // presets used to sit three menu levels deep (View ▸ Panes ▸
            // Workspace Presets) and Maximize is the other half of the same
            // question — "which panes, and how much of the window" — so
            // both live under one glyph.
            //
            // A NEW item id: renaming an existing one silently resets every
            // customized toolbar, so all nine ids that were here keep theirs
            // and a user who has never customized simply gains this one.
            //
            // But a new default item is NOT retroactive either: NSToolbar's
            // autosaved configuration stores the identifiers a customized
            // toolbar shows, and an identifier that was not in that list
            // when it was saved is not added to it. A user who has ever
            // opened Customize Toolbar therefore will not see this button
            // until they add it themselves. That is why the presets and
            // Maximize also live in View ▸ Panes, at the top level of that
            // menu rather than three levels down — the menu is the path that
            // is guaranteed to be there, and this item is the shortcut.
            ToolbarItem(id: "panes.workspace", placement: .primaryAction) {
                Menu {
                    WorkspacePresetItems(appSettings: appSettings)
                    Divider()
                    Button(WorkspaceCommands.maximizeTitle(appSettings)) {
                        withAnimation(DS.Motion.standard) {
                            WorkspaceCommands.toggleMaximizeFocusedPane(appSettings: appSettings)
                        }
                    }
                    .help(WorkspaceCommands.maximizeHelp(appSettings))
                    Divider()
                    // The third question this menu answers — which panes,
                    // how much of the window, and which window — rendered
                    // from the same list View ▸ Panes uses.
                    Menu("Separate Windows") {
                        PaneWindowItems(appSettings: appSettings)
                    }
                    .help("Give a pane a window of its own, or bring one back")
                } label: {
                    // The glyph carries the maximized state. A maximize is
                    // remembered across launches, and the canvas — unlike
                    // every other maximizable pane — has no header to show a
                    // restore button in, so without this a user could meet a
                    // one-pane window at launch with nothing on screen
                    // saying why. The canvas status bar carries the control
                    // itself; this is the same fact in the toolbar, for the
                    // panes whose own header is what got maximized.
                    // The TEXT stays "Workspace" in every state: it is the
                    // item's name in Customize Toolbar and in the "Icon and
                    // Text" display mode, and a name that changed with the
                    // window's arrangement would be a different button every
                    // time the user went looking for it.
                    Label("Workspace",
                          systemImage: maximizedPane == nil ? DS.Symbol.paneSplit : DS.Symbol.paneRestore)
                }
                .help(maximizedPane == nil
                      ? "Apply a pane arrangement, or give one pane the whole window (View ▸ Panes)"
                      : "The \(maximizedPane!.displayName) pane has the whole window — choose Restore Pane Layout to bring the others back (View ▸ Panes)")
                .accessibilityLabel(maximizedPane == nil
                                    ? "Workspace arrangement"
                                    : "Workspace arrangement, \(maximizedPane!.displayName) pane maximized")
            }
            ToolbarItem(id: "panes.palette", placement: .primaryAction) {
                Toggle(isOn: $appSettings.palettePaneVisible.animation(DS.Motion.standard)) {
                    Label("Tools", systemImage: DS.Symbol.paneLeft)
                }
                .help("Show or hide the Tools pane (\(shortcut(.showToolsPane)))")
                .accessibilityLabel("Tools pane")
            }
            ToolbarItem(id: "panes.status", placement: .primaryAction) {
                Toggle(isOn: $appSettings.statusPaneVisible.animation(DS.Motion.standard)) {
                    Label("Status", systemImage: DS.Symbol.paneRight)
                }
                .help("Show or hide the Status pane (\(shortcut(.showStatusPane)))")
                .accessibilityLabel("Status pane")
            }
            ToolbarItem(id: "panes.results", placement: .primaryAction) {
                Toggle(isOn: $appSettings.resultsPaneVisible.animation(DS.Motion.standard)) {
                    Label("Results", systemImage: DS.Symbol.numberFormat)
                }
                .help("Show or hide the structured Results workspace (\(shortcut(.showResultsPane)))")
                .accessibilityLabel("Results workspace")
            }
            ToolbarItem(id: "panes.inspector", placement: .primaryAction) {
                Toggle(isOn: $appSettings.inspectorPaneVisible.animation(DS.Motion.standard)) {
                    Label("Inspector", systemImage: DS.Symbol.inspector)
                }
                .help("Show or hide the Inspector pane (\(shortcut(.showInspectorPane)))")
                .accessibilityLabel("Inspector pane")
            }
            ToolbarItem(id: "panes.shell", placement: .primaryAction) {
                Toggle(isOn: $appSettings.shellPaneVisible.animation(DS.Motion.standard)) {
                    Label("Shell", systemImage: DS.Symbol.terminal)
                }
                .help("Show or hide the Shell pane (\(shortcut(.showShellPane)))")
                .accessibilityLabel("Shell pane")
            }
            ToolbarItem(id: "panes.ai", placement: .primaryAction) {
                Toggle(isOn: $appSettings.aiPaneVisible.animation(DS.Motion.standard)) {
                    Label("AI Assistant", systemImage: DS.Symbol.assistant)
                }
                .help("Show or hide the AI Assistant pane (\(shortcut(.showAIPane)))")
                .accessibilityLabel("AI Assistant pane")
            }
        }
        // The node and the link parameter editors, as movable panels
        // rather than pinned sheets. See "The two parameter editors"
        // above; everything but the mirroring lives with the forms.
        .onChange(of: editor.parameterEditorTarget?.id) { _, _ in
            syncParameterPanels()
        }
        .onChange(of: editor.linkParameterEditorTarget?.id) { _, _ in
            syncParameterPanels()
        }
        .onAppear { syncParameterPanels() }
        .onDisappear { closeParameterPanels() }
        .sheet(isPresented: $editor.showSRBMExportSheet) {
            SRBMExportSheet()
                .environmentObject(editor)
        }
        // Showing or hiding ANY pane leaves the maximized state, whichever
        // entry point did it. Watching the toggles rather than patching
        // each menu item, toolbar button and preset is what makes the rule
        // exceptionless — and it is also how the stored value is cleared
        // when the user hides the very pane that was maximized.
        .onChange(of: paneVisibilitySignature) { _, _ in
            guard appSettings.hasStoredSolo else { return }
            withAnimation(DS.Motion.standard) { appSettings.soloedPane = nil }
        }
        // A pane that closes itself between launches has to say why. The
        // repair runs in `AppSettings.init`, before any view exists; this is
        // the first moment there is a status log to write it into, and the
        // flag is cleared here so a second window does not repeat it.
        .onAppear {
            guard appSettings.didRepairResultsPane else { return }
            appSettings.didRepairResultsPane = false
            editor.addStatus(
                "The Results workspace was closed. An earlier version reopened it on every solver run and then left it open, which reduced the canvas and the Shell to what was left of the window. No run record was touched — View ▸ Panes ▸ Results (⌥⌘6) brings the workspace back.",
                severity: .info
            )
        }
        // The first run reveals the Results workspace — ONCE, and only
        // when the run would otherwise be invisible.
        //
        // It used to fire on every run against a flag that then stayed
        // true forever, so one run permanently added a seventh pane: three
        // rows whose ideal heights sum to ~1016 pt in ~848 pt of content,
        // which letterboxed the canvas to ~330 pt and the Shell to eleven
        // rows. Now: not while the Shell is showing (the run IS visible
        // there), not while a pane is maximized (the user asked for one
        // pane), and never a second time.
        .onReceive(NotificationCenter.default.publisher(for: .qnetResultRunDidBegin)) { note in
            guard let tabID = note.userInfo?["tabID"] as? UUID,
                  tabID == activeTabID,
                  !appSettings.resultsAutoShown,
                  appSettings.soloedPane == nil,
                  !appSettings.resultsPaneVisible,
                  !appSettings.shellPaneVisible else { return }
            appSettings.resultsAutoShown = true
            withAnimation(DS.Motion.standard) { appSettings.resultsPaneVisible = true }
        }
    }
}

// MARK: - Window document state

/// Keeps the hosting NSWindow's proxy icon (`representedURL`) and the
/// title-bar edited dot (`isDocumentEdited`) in sync with the active tab.
private struct WindowDocumentState: NSViewRepresentable {
    let representedURL: URL?
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let url = representedURL
        let edited = isEdited
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.representedURL != url { window.representedURL = url }
            if window.isDocumentEdited != edited { window.isDocumentEdited = edited }
        }
    }
}

// MARK: - ⌃Tab / ⌃⇧Tab tab switching

/// Local key monitor for the two shortcuts SwiftUI menu items cannot
/// carry alongside ⇧⌘] / ⇧⌘[. Only fires when the window that hosts
/// this view is key.
private struct TabSwitchKeyMonitor: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(host: view, onNext: onNext, onPrevious: onPrevious)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNext = onNext
        context.coordinator.onPrevious = onPrevious
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        private var monitor: Any?
        private weak var host: NSView?

        func install(host: NSView, onNext: @escaping () -> Void, onPrevious: @escaping () -> Void) {
            self.host = host
            self.onNext = onNext
            self.onPrevious = onPrevious
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Extract the plain values first; NSEvent itself is not
                // Sendable so it must not cross into the isolated closure.
                let keyCode = event.keyCode
                let flags = event.modifierFlags
                let eventWindow = event.windowNumber
                let handled: Bool = MainActor.assumeIsolated {
                    guard let self,
                          keyCode == 48,   // Tab
                          flags.intersection([.control, .command, .option]) == [.control],
                          let window = self.host?.window,
                          window.isKeyWindow,
                          window.windowNumber == eventWindow
                    else { return false }
                    if flags.contains(.shift) { self.onPrevious?() } else { self.onNext?() }
                    return true
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Tab bar

/// Private drag type for a document tab. Declaring one means the tab
/// strip accepts Qnet tabs and nothing else — a filename from the Finder
/// or a line of shell output no longer lights the insertion bar and then
/// does nothing — and dragging a tab into Mail or TextEdit no longer
/// pastes a bare UUID.
///
/// `importedAs`, not `exportedAs`: the payload never leaves this process
/// (both ends of the drag are the same window's `tabs` array), and
/// `exportedAs` is a promise to LaunchServices that the bundle's
/// Info.plist declares the identifier under `UTExportedTypeDeclarations`
/// — a promise `build_app.sh` does not keep, so UTType logged "expected
/// to be declared and exported" on the first drag. `importedAs` makes no
/// such promise: LaunchServices resolves a declared type when one exists
/// and mints a dynamic identifier otherwise. Should the tab payload ever
/// need to cross processes, add the declaration to the Info.plist heredoc
/// and switch back to `exportedAs`.
extension UTType {
    static let qnetTab = UTType(importedAs: "com.bnetgui.tab", conformingTo: .data)
}

/// The payload itself: just the tab's identity, since both ends of the
/// drag are the same window's `tabs` array.
private struct TabDragItem: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .qnetTab)
    }
}

private struct TabBarView: View {
    @Binding var tabs: [NetworkTab]
    @Binding var activeTabID: UUID
    /// Every close — the ✕ button, a middle-click, the three context-menu
    /// items — is one call on the app's guarded owner, which asks Save /
    /// Don't Save / Cancel for each dirty tab and remembers the closed tab
    /// for Window ▸ Reopen Closed Tab. This view only decides WHICH tabs.
    var tabActions: TabActions
    /// True while the canvas owns keyboard focus — the tab bar then shows
    /// the same top accent rule the four pane headers use.
    var isCanvasFocused: Bool = false

    /// Total width of all tabs concatenated (measured by GeometryReader
    /// inside the ScrollView's content). When this exceeds `viewportWidth`
    /// the tab row overflows and the arrow buttons become active.
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// Tab the pointer is currently over while dragging another tab; the
    /// dragged tab lands at this tab's position.
    @State private var dropTargetID: UUID?
    /// True while a dragged tab hovers the strip's trailing drop zone.
    @State private var isEndTargeted = false

    /// The measured content includes the trailing drop zone, which is
    /// slack rather than content — subtract it so the scroll arrows do not
    /// light up 32 pt before the tabs actually overflow.
    private var hasOverflow: Bool {
        viewportWidth > 0 && (contentWidth - DS.Spacing.xxl) > viewportWidth + 0.5
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            // Overflow arrows keep their width when inactive so the tab
            // strip never shifts when a tab is added or removed.
            arrowButton(systemName: DS.Symbol.previous, label: "Previous Tab", help: "Previous Tab (\(shortcut(.showPreviousTab)))") {
                WorkspaceCommands.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: -1)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: DS.Spacing.xxs) {
                        ForEach(tabs) { tab in
                            TabItemView(
                                editor: tab.editor,
                                title: tab.title,
                                isActive: tab.id == activeTabID,
                                onSelect: { activeTabID = tab.id },
                                onClose: { closeTab(id: tab.id) },
                                onCloseOthers: { closeOtherTabs(keeping: tab.id) },
                                onCloseRight: { closeTabs(toTheRightOf: tab.id) }
                            )
                            .id(tab.id)
                            // Safari / Xcode behaviour: drag a tab to
                            // re-order it. The insertion point is shown as
                            // an accent bar on the tab the drop will
                            // displace; the active tab stays active.
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(DS.Color.accent)
                                    .frame(width: DS.Stroke.selection)
                                    .padding(.vertical, DS.Spacing.xxs)
                                    .opacity(dropTargetID == tab.id ? 1 : 0)
                                    .dsAnimation(DS.Motion.quick, value: dropTargetID)
                                    .accessibilityHidden(true)
                            }
                            .draggable(TabDragItem(id: tab.id)) {
                                Text(tab.title)
                                    .font(DS.Font.label)
                                    .lineLimit(1)
                                    .padding(.horizontal, DS.Spacing.s)
                                    .padding(.vertical, DS.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                            .fill(DS.Color.surfaceRaised)
                                    )
                            }
                            .dropDestination(for: TabDragItem.self) { items, _ in
                                dropTargetID = nil
                                return moveTab(items.first?.id, to: tab.id)
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTargetID = tab.id
                                } else if dropTargetID == tab.id {
                                    dropTargetID = nil
                                }
                            }
                        }
                        // Drop zone past the last tab: dragging a tab into
                        // the empty strip appends it, instead of silently
                        // doing nothing (the insertion bar shows on the
                        // trailing edge of the last tab).
                        Color.clear
                            .frame(width: DS.Spacing.xxl, height: DS.Layout.tabBarHeight)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(DS.Color.accent)
                                    .frame(width: DS.Stroke.selection)
                                    .padding(.vertical, DS.Spacing.xs)
                                    .opacity(isEndTargeted ? 1 : 0)
                                    .dsAnimation(DS.Motion.quick, value: isEndTargeted)
                                    .accessibilityHidden(true)
                            }
                            .dropDestination(for: TabDragItem.self) { items, _ in
                                isEndTargeted = false
                                return moveTabToEnd(items.first?.id)
                            } isTargeted: { isEndTargeted = $0 }
                    }
                    .padding(.top, DS.Spacing.xs)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: TabContentWidthKey.self, value: g.size.width)
                        }
                    )
                }
                .onPreferenceChange(TabContentWidthKey.self) { contentWidth = $0 }
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { viewportWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in viewportWidth = w }
                    }
                )
                .onChange(of: activeTabID) { _, id in
                    withAnimation(DS.Motion.quick) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(activeTabID, anchor: nil) }
                }
            }

            arrowButton(systemName: DS.Symbol.next, label: "Next Tab", help: "Next Tab (\(shortcut(.showNextTab)))") {
                WorkspaceCommands.showAdjacentTab(tabs: tabs, activeTabID: $activeTabID, offset: +1)
            }

            DSIconButton(systemImage: DS.Symbol.add, label: "New Network", help: "New Network in a new tab (File ▸ New Network, \(shortcut(.newNetwork)))") {
                addNewTab()
            }
        }
        .padding(.horizontal, DS.Spacing.xs)
        .frame(height: DS.Layout.tabBarHeight)
        .background(DS.Color.surface)
        // Rule sits *under* the tabs so the active tab's fill joins the
        // canvas below it.
        .background(alignment: .bottom) { DSRule() }
        // The canvas has no pane header, so its focus rule lives here —
        // the same one DSSectionHeader draws for every other pane.
        .dsFocusRule(isCanvasFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open networks")
    }

    /// Moves the dragged tab to the position the insertion bar promised:
    /// immediately BEFORE the tab it was dropped on. Removing first
    /// shifts every later index down by one, so a forward drag has to
    /// insert at `to - 1` — without that correction the tab landed one
    /// position past the bar (dragging A onto C gave [B, C, A], not
    /// [B, A, C]). `activeTabID` is an identity, not an index, so the
    /// active tab is unaffected by the re-order.
    private func moveTab(_ draggedID: UUID?, to targetID: UUID) -> Bool {
        guard let draggedID, draggedID != targetID,
              let from = tabs.firstIndex(where: { $0.id == draggedID }),
              let to = tabs.firstIndex(where: { $0.id == targetID })
        else { return false }
        let target = from < to ? to - 1 : to
        withAnimation(DS.Motion.quick) {
            let moved = tabs.remove(at: from)
            tabs.insert(moved, at: target)
        }
        return true
    }

    /// Drop past the last tab: move the dragged tab to the end.
    private func moveTabToEnd(_ draggedID: UUID?) -> Bool {
        guard let draggedID,
              let from = tabs.firstIndex(where: { $0.id == draggedID }),
              from != tabs.count - 1
        else { return false }
        withAnimation(DS.Motion.quick) {
            let moved = tabs.remove(at: from)
            tabs.append(moved)
        }
        return true
    }

    private func arrowButton(
        systemName: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        DSIconButton(systemImage: systemName, label: label, help: help, action: action)
            .opacity(hasOverflow ? 1 : 0)
            .disabled(!hasOverflow || tabs.count < 2)
            .dsAnimation(DS.Motion.quick, value: hasOverflow)
    }

    private func addNewTab() {
        let tab = NetworkTab()
        tabs.append(tab)
        activeTabID = tab.id
    }

    // The three close shapes only compute WHICH tabs; the owner installed
    // in `tabActions` asks about unsaved changes and edits the array.

    private func closeTab(id: UUID) {
        tabActions.close([id])
    }

    private func closeOtherTabs(keeping id: UUID) {
        let others = Set(tabs.map(\.id)).subtracting([id])
        guard !others.isEmpty else { return }
        tabActions.close(others)
    }

    private func closeTabs(toTheRightOf id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), idx < tabs.count - 1 else { return }
        tabActions.close(Set(tabs[(idx + 1)...].map(\.id)))
    }
}

/// Preference key used to propagate the tab-row's intrinsic content width
/// from the inner HStack up to `TabBarView` so it can decide whether the
/// left/right scroll arrows should be active.
private struct TabContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Outline of a document tab: left, top and right edges only, so the
/// active tab reads as attached to the canvas beneath it.
private struct TabOutline: Shape {
    var radius: CGFloat = DS.Radius.control

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                 radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                 radius: radius, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

private struct TabItemView: View {
    @DSAccessibility private var a11y

    @ObservedObject var editor: NetworkEditorModel
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseRight: () -> Void

    @State private var isHovering = false

    private var isDirty: Bool { editor.hasUnsavedChanges }

    private var fullPath: String {
        editor.currentFileURL?.path ?? "Unsaved network"
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: DS.Radius.control, topTrailingRadius: DS.Radius.control)
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(title)
                .font(isActive ? DS.Font.label.weight(.medium) : DS.Font.label)
                .foregroundStyle(isActive ? DS.Color.textPrimary : DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: DS.Layout.tabMaxTitleWidth)

            // Safari/Xcode pattern: the unsaved dot occupies the close
            // button's slot until the pointer is over the tab.
            ZStack {
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: DS.Symbol.remove)
                            .font(DS.Font.glyphSmall)
                            .foregroundStyle(DS.Color.textSecondary)
                            .frame(width: DS.Spacing.l, height: DS.Spacing.l)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isDirty
                          ? "Close tab — asks to save its unsaved changes first (\(shortcut(.closeTab)))"
                          : "Close tab (\(shortcut(.closeTab))); \(shortcut(.reopenClosedTab)) brings it back")
                    .accessibilityLabel("Close \(title)")
                } else if isDirty {
                    Circle()
                        .fill(DS.Color.dimmed(DS.Color.textPrimary, DS.Opacity.muted))
                        .frame(width: DS.Layout.indicatorDotSize, height: DS.Layout.indicatorDotSize)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .frame(width: DS.Spacing.l, height: DS.Spacing.l)
        }
        .padding(.leading, DS.Spacing.m)
        .padding(.trailing, DS.Spacing.s)
        .frame(height: DS.Layout.tabBarHeight - DS.Spacing.xs)
        .background(
            shape.fill(
                isActive ? DS.Color.surfaceRaised
                         : (isHovering ? DS.Color.hoverFill(a11y.contrast) : Color.clear)
            )
        )
        .overlay {
            if isActive {
                TabOutline().stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
            }
        }
        // Cover the bar's bottom rule so the active tab joins the canvas.
        .padding(.bottom, isActive ? -1 : 0)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
        .overlay(MiddleClickCatcher(onMiddleClick: onClose))
        .help(fullPath)
        .contextMenu {
            // All three go through the app's guarded close: every dirty
            // tab in the set asks Save / Don't Save / Cancel in turn.
            Button("Close Tab") { onClose() }
            Button("Close Other Tabs") { onCloseOthers() }
            Button("Close Tabs to the Right") { onCloseRight() }
            Divider()
            Button("Reveal in Finder") {
                if let url = editor.currentFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(editor.currentFileURL == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)\(isDirty ? ", edited" : "")")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onSelect() }
    }
}

/// Transparent overlay that only intercepts middle-button clicks
/// (button 2) — every other event passes through to SwiftUI.
private struct MiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onMiddleClick = onMiddleClick
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {
        var onMiddleClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2 else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
            onMiddleClick?()
        }
    }
}

// MARK: - Palette

// PalettePanelView moved to ToolPaletteView.swift (tooltips, shortcut
// badges, hover / pressed / selected states, keyboard focus, pane header).

// MARK: - Status bar

/// Application status bar beneath the canvas: tool, zoom, selection,
/// primitive counts, snap state, buffer regime and the trailing
/// solver-run indicator. Proportional 11-pt text with monospaced
/// digits so numbers don't jitter.
private struct CanvasStatusBar: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @EnvironmentObject private var terminal: TerminalModel

    var body: some View {
        HStack(spacing: 0) {
            segment(help: "Active tool. Switch in the Tools pane or with its letter shortcut. Hold Space, or drag with the middle mouse button, to pan in any tool.") {
                Image(systemName: editor.selectedTool.systemImage)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
                Text(editor.selectedTool.displayName)
                    .fontWeight(.medium)
            }
            segmentDivider
            segment(help: "Canvas zoom (\(shortcut(.zoomIn)) / \(shortcut(.zoomOut)); \(shortcut(.actualSize)) actual size, \(shortcut(.zoomToFit)) zoom to fit, \(shortcut(.zoomToSelection)) zoom to selection; ⌥-scroll or pinch to zoom about the pointer)") {
                Text("\(Int((editor.canvasScale * 100).rounded()))%")
                    .frame(minWidth: DS.Layout.zoomReadoutWidth, alignment: .trailing)
            }
            segmentDivider
            if let marquee = editor.marqueeNodeCount {
                segment(help: "Nodes inside the selection rectangle") {
                    Text("Selecting \(marquee) node\(marquee == 1 ? "" : "s")")
                        .foregroundStyle(DS.Color.accent)
                }
            } else {
                segment(help: "What is selected on the canvas — nodes, a link, or both (⌘A selects all nodes, Escape or ⌥⌘A deselects everything)") {
                    Text(selectionSummary)
                        .foregroundStyle(editor.hasAnySelection ? DS.Color.textPrimary : DS.Color.textSecondary)
                }
                .accessibilityLabel(selectionSummary)
            }
            segmentDivider
            segment(help: "Network primitives: sources, stations, buffers, sinks, links") {
                // Full words when the bar is wide enough; the palette's SF
                // symbols otherwise. Never three-letter abbreviations.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.m) {
                        ForEach(primitiveCounts) { countLabel($0, style: .words) }
                    }
                    HStack(spacing: DS.Spacing.s) {
                        ForEach(primitiveCounts) { countLabel($0, style: .symbols) }
                    }
                }
            }
            segmentDivider
            segment(help: editor.snapSuspended
                    ? "Free placement: ⌃ is held, so Snap to Grid and the alignment guides stand down for this drag"
                    : "Snap to Grid (\(shortcut(.snapToGrid))). Hold ⌃ while dragging to place a node freely.") {
                Image(systemName: DS.Symbol.snapToGrid)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundStyle(editor.snapToGrid && !editor.snapSuspended
                                     ? DS.Color.accent : DS.Color.textTertiary)
                    .accessibilityLabel(editor.snapSuspended ? "Snap to grid suspended"
                                        : (editor.snapToGrid ? "Snap to grid on" : "Snap to grid off"))
                if editor.snapSuspended {
                    Text("Free placement")
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            .dsAnimation(DS.Motion.quick, value: editor.snapSuspended)
            segmentDivider
            segment(help: editor.infiniteBuffers
                    ? "Infinite buffers: unbounded queues (BNA / QNA / spectral orthant methods)"
                    : "Finite buffers: bounded queues with blocking (fBNA methods)") {
                Text(editor.infiniteBuffers ? "Infinite buffers" : "Finite buffers")
            }
            if editor.canvasPanOffset != .zero {
                let px = Int(editor.canvasPanOffset.width.rounded())
                let py = Int(editor.canvasPanOffset.height.rounded())
                segmentDivider
                segment(help: "Canvas pan offset in points (\(shortcut(.actualSize)) returns to actual size at the origin)") {
                    Image(systemName: DS.Symbol.pan)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundStyle(DS.Color.textSecondary)
                    Text("Pan \(px), \(py) pt")
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .accessibilityLabel("Canvas panned by \(px) and \(py) points")
            }

            Spacer(minLength: DS.Spacing.s)

            runSegment
            segmentDivider
            // The maximize control every other pane carries in its header's
            // trailing slot. The canvas has no header — the tab bar above it
            // belongs to the document, not to the pane — so this bar is
            // where it belongs, and it is also the ONLY thing on screen that
            // says a maximize is in force once the canvas has the window:
            // the state is remembered across launches, so a user can meet a
            // one-pane window at login with no other explanation for it.
            HStack(spacing: DS.Spacing.xs) {
                PaneSoloButton(.canvas)
            }
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.statusBarHeight)
        }
        .font(DS.Font.numberSmall)
        .foregroundStyle(DS.Color.textPrimary)
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: DS.Layout.statusBarHeight)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { DSRule() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
    }

    @ViewBuilder
    private var runSegment: some View {
        if let run = terminal.activeRun {
            segment(help: runHelp(run)) {
                // Determinate whenever the solver reports a total through
                // its -P progress file (the same bytes the Shell's ASCII
                // bar reads); an indeterminate spinner otherwise, rather
                // than a bar that never moves.
                if let fraction = terminal.runProgress {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: DS.Layout.runProgressWidth)
                    // "47%" — the macOS form, the same one the zoom segment
                    // two dividers away uses.
                    Text("\(Int((fraction * 100).rounded()))% · \(TerminalRunSummary.clock(terminal.runElapsed))")
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(minWidth: DS.Layout.runReadoutWidth, alignment: .leading)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: DS.Spacing.m, height: DS.Spacing.m)
                    Text("Running \(run) for \(terminal.activeRunOwnerTitle ?? "another tab")… \(TerminalRunSummary.clock(terminal.runElapsed))")
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                }
                // Live from the first millisecond of the run: the model
                // waits for the wrapper's pid itself, so Stop is never a
                // dimmed button beside a bar that says "running".
                DSIconButton(
                    systemImage: DS.Symbol.stop,
                    label: "Stop Run",
                    help: terminal.canCancelRun
                        ? "Stop \(run) (Run ▸ Stop \(run), \(shortcut(.stop))) — sends the same interrupt ⌃C would in the Shell"
                        : "Stop \(run) (Run ▸ Stop \(run), \(shortcut(.stop))) — interrupts it as soon as it reports its process id",
                    isDestructive: true
                ) { stopRun() }
            }
            .accessibilityLabel(runAccessibilityLabel(run))
        } else if let last = terminal.lastRunSummary {
            segment(help: "Last run: \(last.text)") {
                Image(systemName: last.succeeded ? DS.Symbol.success
                                  : (last.cancelled ? DS.Symbol.warning : DS.Symbol.failure))
                    .font(DS.Font.caption)
                    .foregroundStyle(last.succeeded ? DS.Color.successText
                                     : (last.cancelled ? DS.Color.warningText : DS.Color.dangerText))
                Text("\(last.text) · \(last.ownerTitle)")
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityLabel("Last run: \(last.text)")
        } else {
            segment(help: "No solver run yet — use the Run menu") {
                Text("Idle")
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    /// Tooltip for the live-run segment: names the run, its progress and
    /// how to stop it.
    private func runHelp(_ run: String) -> String {
        let clock = TerminalRunSummary.clock(terminal.runElapsed)
        if let fraction = terminal.runProgress {
            return "\(run) for \(terminal.activeRunOwnerTitle ?? "another tab"): \(Int((fraction * 100).rounded()))% done after \(clock) — Stop with \(shortcut(.stop))"
        }
        return "\(run) for \(terminal.activeRunOwnerTitle ?? "another tab") is running in the Shell (\(clock)) — Stop with \(shortcut(.stop))"
    }

    private func runAccessibilityLabel(_ run: String) -> String {
        if let fraction = terminal.runProgress {
            return "Running \(run) for \(terminal.activeRunOwnerTitle ?? "another tab"), \(Int((fraction * 100).rounded())) percent, \(TerminalRunSummary.clock(terminal.runElapsed)) elapsed"
        }
        return "Running \(run) for \(terminal.activeRunOwnerTitle ?? "another tab"), \(TerminalRunSummary.clock(terminal.runElapsed)) elapsed"
    }

    /// Interrupts the run and says so in the status log, so a cancelled
    /// run leaves the same trail a finished one does. The model writes
    /// the line (it may arrive a moment later, once the wrapper has
    /// reported its pid), so the menu bar and this button log one text.
    private func stopRun() {
        terminal.cancelActiveRun { text, severity in
            editor.addStatus(text, severity: severity)
        }
    }

    private func segment<Content: View>(help: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            content()
        }
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: DS.Layout.statusBarHeight)
        .help(help)
    }

    private var segmentDivider: some View {
        DSRule(.vertical, length: DS.Spacing.m)
    }

    /// One primitive kind's count for the status bar.
    private struct PrimitiveCount: Identifiable {
        let id: String
        let singular: String
        let plural: String
        let systemImage: String
        let value: Int

        /// "3 stations" / "1 link" — tooltip and accessibility label.
        var spoken: String { "\(value) \(value == 1 ? singular : plural)" }
    }

    private enum CountStyle { case words, symbols }

    private var primitiveCounts: [PrimitiveCount] {
        func count(_ kind: NodeKind) -> Int { editor.nodes.filter { $0.kind == kind }.count }
        return [
            PrimitiveCount(id: "source", singular: "source", plural: "sources",
                           systemImage: NodeKind.source.systemImage, value: count(.source)),
            PrimitiveCount(id: "station", singular: "station", plural: "stations",
                           systemImage: NodeKind.station.systemImage, value: count(.station)),
            PrimitiveCount(id: "buffer", singular: "buffer", plural: "buffers",
                           systemImage: NodeKind.buffer.systemImage, value: count(.buffer)),
            PrimitiveCount(id: "sink", singular: "sink", plural: "sinks",
                           systemImage: NodeKind.sink.systemImage, value: count(.sink)),
            PrimitiveCount(id: "link", singular: "link", plural: "links",
                           systemImage: DS.Symbol.link, value: editor.links.count),
        ]
    }

    /// Fixed-width count (3 digits) so the bar never reflows between 9
    /// and 10 links. Words style: "3 stations"; symbols style: glyph + 3.
    private func countLabel(_ item: PrimitiveCount, style: CountStyle) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            switch style {
            case .words:
                Text("\(item.value)")
                    .frame(minWidth: DS.Layout.counterWidth, alignment: .trailing)
                Text(item.value == 1 ? item.singular : item.plural)
                    .foregroundStyle(DS.Color.textSecondary)
            case .symbols:
                Image(systemName: item.systemImage)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: DS.Spacing.m)
                Text("\(item.value)")
                    .frame(minWidth: DS.Layout.counterWidth, alignment: .leading)
            }
        }
        .help(item.spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spoken)
    }

    private var selectionCount: Int {
        var ids = editor.selectedNodeIDs
        if let s = editor.selectedNodeID { ids.insert(s) }
        return ids.count
    }

    /// Reads the whole canvas selection, links included, so the segment
    /// is exactly the inverse of Edit ▸ Deselect All's enablement:
    /// "No selection" appears if and only if that command is dimmed.
    /// Links are selectable, editable objects and are drawn with the
    /// accent stroke when chosen — the bar has to say so.
    private var selectionSummary: String {
        let nodes = selectionCount
        let hasLink = editor.selectedLinkID != nil
        switch (nodes, hasLink) {
        case (0, false): return "No selection"
        case (0, true):  return "Selected 1 link"
        case (let n, false): return "Selected \(n) node\(n == 1 ? "" : "s")"
        case (let n, true):  return "Selected \(n) node\(n == 1 ? "" : "s"), 1 link"
        }
    }
}

// MARK: - Shell pane

/// The Shell pane. Not private: `PaneDetachment.swift` builds the same
/// view when the Shell is in a window of its own, and building the SAME
/// view is the point — the terminal's NSView is cached on `TerminalModel`
/// and simply re-parented, so the shell process and its scrollback survive
/// the move.
struct TerminalPaneView: View {
    @EnvironmentObject private var terminal: TerminalModel
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject private var focusRouter = FocusRouter.shared

    let workingDirectory: URL

    /// True for ~1 s after a successful Copy so the button shows a
    /// checkmark — the same confirmation the AI pane gives.
    @State private var copiedFlash = false
    /// Measured pane width. Below `DS.Layout.headerCondenseWidthWide` the
    /// header's least-used controls fold into one overflow menu rather
    /// than squeezing the title and the directory to nothing — the same
    /// rule the AI pane header follows at its own, narrower, token.
    @State private var paneWidth: CGFloat = 0

    private var currentPath: String {
        terminal.sessionDirectoryDisplay.isEmpty ? workingDirectory.path : terminal.sessionDirectoryDisplay
    }

    private var abbreviatedPath: String {
        (currentPath as NSString).abbreviatingWithTildeInPath
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(get: { terminal.fontName }, set: { terminal.setFontName($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSectionHeader("Shell", isFocused: focusRouter.focusedPane == .shell) {
                HStack(spacing: DS.Spacing.s) {
                    Circle()
                        .fill(terminal.isShellRunning ? DS.Color.success : DS.Color.danger)
                        .frame(width: DS.Layout.indicatorDotSize, height: DS.Layout.indicatorDotSize)
                        .dsTooltip(terminal.isShellRunning ? "Shell running" : "Shell exited")
                    Text(abbreviatedPath)
                        .font(DS.Font.chrome)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Current directory: \(currentPath)")
                        .accessibilityLabel("Current directory \(currentPath)")
                    // Only present when the shell has exited (rare), and
                    // it fades in rather than snapping the path label
                    // sideways.
                    if !terminal.isShellRunning {
                        Button("Restart") {
                            terminal.restart()
                        }
                        .controlSize(.small)
                        .help("Start a new shell session")
                        .accessibilityLabel("Restart shell")
                        .transition(.opacity)
                    }
                }
                .dsAnimation(DS.Motion.quick, value: terminal.isShellRunning)
                .frame(maxWidth: DS.Layout.paneHeaderInfoMaxWidth, alignment: .leading)
            } trailing: {
                // Header control order, shared by the Status, Shell and AI
                // panes: [pane-specific] … Find · Copy/Export · font family
                // · text size · destructive · the pane-window control.
                // Scroll to Bottom is the Shell's pane-specific control;
                // Clear and Restart are its two destructive ones. Maximize
                // sits past them, at the header's edge, because it is the
                // one control here that acts on the WINDOW rather than on
                // the session — and it means an edge-of-header click is no
                // longer a destructive one.
                DSIconButton(systemImage: DS.Symbol.download, label: "Scroll to Bottom", help: "Scroll to the prompt") {
                    terminal.scrollToBottom()
                }
                DSIconButton(systemImage: DS.Symbol.find, label: "Find in Shell", help: "Find in the scrollback (\(shortcut(.find)) while the shell has focus)") {
                    terminal.showFind()
                }
                DSIconButton(
                    systemImage: copiedFlash ? DS.Symbol.checkmark : DS.Symbol.copy,
                    label: copiedFlash ? "Copied" : "Copy",
                    help: "Copy the selection, or the whole scrollback when nothing is selected"
                ) {
                    copyFromShell()
                }
                .contentTransition(.symbolEffect(.replace))
                if paneWidth >= DS.Layout.headerCondenseWidthWide {
                    MonospaceFontMenu(family: fontFamilyBinding, help: "Shell font")
                    FontSizeStepper(
                        canDecrease: terminal.fontSize > TerminalModel.minFontSize,
                        canIncrease: terminal.fontSize < TerminalModel.maxFontSize,
                        onDecrease: { terminal.decreaseFontSize() },
                        onIncrease: { terminal.increaseFontSize() }
                    )
                } else {
                    shellOverflowMenu
                }
                DSIconButton(systemImage: DS.Symbol.clearPane, label: "Clear Shell", help: "Clear the screen and scrollback (\(shortcut(.clearShell))). The shell keeps running.", isDestructive: true) {
                    terminal.clearTerminal()
                }
                DSIconButton(systemImage: DS.Symbol.refresh, label: "Restart Shell", help: "Restart the shell and forget the saved transcript…", isDestructive: true) {
                    WorkspaceCommands.confirmRestartShell(terminal)
                }
                PaneSoloButton(.shell)
            }

            SwiftTermView(
                workingDirectory: workingDirectory,
                classicTheme: appSettings.shellClassicTheme
            )
            .dsContentWell()
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { paneWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in paneWidth = w }
            }
        )
        .background(PaneFocusMarker(.shell))
        .onAppear {
            FocusRouter.shared.setFocusHandler(.shell) { terminal.focusTerminal() }
            FocusRouter.shared.setZoomHandler(.shell) { step in
                if step > 0 { terminal.increaseFontSize() } else { terminal.decreaseFontSize() }
            } canZoom: { step in
                step > 0
                    ? terminal.fontSize < TerminalModel.maxFontSize
                    : terminal.fontSize > TerminalModel.minFontSize
            }
            FocusRouter.shared.setFindHandler(.shell) { terminal.showFind() }
            // ⌘G / ⇧⌘G in the Shell. SwiftTerm searches for whatever is on the
            // system find pasteboard — its own find bar writes there on every
            // keystroke — so the step handler is registered without a `canStep`
            // predicate: the find bar is private, there is no event to
            // re-evaluate the menu on while the user types into it, and an
            // enabled item that finds nothing is a far smaller failure than a
            // dead ⌘G. Edit ▸ Find Next's tooltip does read the pasteboard
            // (`terminal.hasFindTerm`) and says which of the two states it is in.
            FocusRouter.shared.setFindStepHandler(.shell) { delta in
                terminal.findNext(delta)
            }
        }
    }

    /// The header's least-used controls, folded into one menu when the
    /// pane is too narrow to show them all.
    private var shellOverflowMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.more,
            label: "More Shell controls",
            help: "Shell font and text size"
        ) {
            Button("Increase Text Size") { terminal.increaseFontSize() }
                .disabled(terminal.fontSize >= TerminalModel.maxFontSize)
            Button("Decrease Text Size") { terminal.decreaseFontSize() }
                .disabled(terminal.fontSize <= TerminalModel.minFontSize)
            Divider()
            Picker("Shell Font", selection: fontFamilyBinding) {
                Text("System Monospaced").tag("")
                ForEach(MonospaceFontMenu.monospaceFamilies(), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
        }
    }

    /// Copy is never silent: the status log says how much was copied
    /// (the whole scrollback when nothing was selected) and the button
    /// glyph confirms for a second.
    private func copyFromShell() {
        guard let text = terminal.copySelectionOrAll() else {
            editor.addStatus("Nothing to copy from the shell.", severity: .warning)
            return
        }
        let hadSelection = terminal.hasSelection
        let count = text.count.formatted()
        editor.addStatus(
            hadSelection
                ? "Copied \(count) characters from the shell selection."
                : "Copied \(count) characters — the whole shell scrollback (nothing was selected).",
            severity: .success
        )
        withAnimation(DS.Motion.quick) { copiedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            withAnimation(DS.Motion.quick) { copiedFlash = false }
        }
    }
}

// MARK: - Notification-token lifetime

/// Holds `NotificationCenter` observer tokens and unregisters them when it
/// is released.
///
/// The two coordinators below live as long as the SwiftUI view that made
/// them, which is not forever: SwiftUI rebuilds the Settings scene on every
/// ⌘, and hands it a fresh `WindowFrameAutosave.Coordinator`, and every
/// pane toggle can retire a `SplitViewConfigurator.Coordinator`. Each one
/// registered block-based observers and never removed them, so the blocks
/// (and the closed-over coordinators) accumulated for the life of the
/// process and kept answering notifications for windows that were gone.
///
/// A `deinit` on the coordinators themselves cannot do this: they are
/// `@MainActor`, and a non-isolated `deinit` may not touch their isolated
/// stored properties. A plain object parked in a `let` can — its own
/// `deinit` is unrestricted, and it is released exactly when its owner is.
private final class ObserverTokens {
    private var tokens: [NSObjectProtocol] = []

    func keep(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

// MARK: - Split View Persistence

/// Saves every pane's size under `SplitPane.<key>.<pane>` (and the
/// legacy `SplitSizes.<key>` array while the full pane set is visible)
/// and restores them when the split is attached or a pane is re-shown.
private struct SplitViewConfigurator: NSViewRepresentable {
    let autosaveName: String
    /// Names of the panes currently present, in order.
    let panes: [String]
    /// The full pane set for this split (used for the legacy array and
    /// for the coupled-width mirror).
    let canonical: [String]
    /// The pane that absorbs leftover space; every other pane is
    /// restored to its saved size.
    let flexible: String

    /// The top split's full pane set. The right column is one pane
    /// ("right") whichever of the Inspector and Status it shows.
    static let topCanonical = ["palette", "canvas", "right"]

    func makeCoordinator() -> Coordinator {
        Coordinator(key: autosaveName, panes: panes, canonical: canonical, flexible: flexible)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coord = context.coordinator
        DispatchQueue.main.async {
            if let splitView = view.findParent(ofType: NSSplitView.self) {
                coord.attach(to: splitView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        if coord.panes != panes {
            coord.panes = panes
            Coordinator.panesByKey[autosaveName] = panes
            // Restore the re-shown pane's last size once SwiftUI has
            // inserted its arranged subview — and once more after the
            // show animation has settled. The first call is a no-op if
            // AppKit has not finished inserting the arranged subview yet
            // (`restore()` bails when the counts disagree), and the pane
            // would then be left at its ideal size with the saved one
            // never applied. Restoring is idempotent, so asking twice is
            // cheaper than guessing which turn of the runloop is right.
            DispatchQueue.main.async { coord.restore() }
            WorkspaceCommands.afterLayout { coord.restore() }
        }
        if coord.splitView == nil {
            DispatchQueue.main.async {
                if let splitView = nsView.findParent(ofType: NSSplitView.self) {
                    coord.attach(to: splitView)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let key: String
        var panes: [String]
        let canonical: [String]
        let flexible: String
        weak var splitView: NSSplitView?
        /// Both observers registered by `attach`, removed when this
        /// coordinator is released. The terminate observer used to be
        /// registered with its token discarded, which made it permanent.
        private let observers = ObserverTokens()

        /// Instant after which `save()` trusts the split's own geometry
        /// again. Set by every `restore()`; see the guard in `save()`.
        private var restoreSettledAt: Date = .distantPast

        /// Pane lists per split key, so the coupled-width mirror only
        /// runs while both splits show their full pane set.
        @MainActor static var panesByKey: [String: [String]] = [:]

        /// Two splits whose RIGHT-most pane should always render at the
        /// same width: TopHSplit's Status pane (palette/canvas/status)
        /// and BottomHSplit's AI Assistant pane (terminal/ai). Dragging
        /// either right divider mirrors to the other.
        static let coupledKeys: Set<String> = ["TopHSplit", "BottomHSplit"]

        /// Guard against synchronous re-entry. AppKit may emit
        /// `didResizeSubviews` synchronously from inside `setPosition`,
        /// which would otherwise let mirror→setPosition→mirror pile up
        /// on the runloop.
        @MainActor static var mirrorInProgress: Bool = false

        /// Time before which any mirror call is a no-op. Set by every
        /// mirror that actually issues a `setPosition`, so the cascade
        /// of resize notifications it kicks off can't re-trigger another
        /// mirror until AppKit has settled.
        @MainActor static var mirrorSuppressedUntil: Date = .distantPast

        init(key: String, panes: [String], canonical: [String], flexible: String) {
            SplitKeyMigration.runOnce()
            self.key = key
            self.panes = panes
            self.canonical = canonical
            self.flexible = flexible
            Self.panesByKey[key] = panes
        }

        func attach(to sv: NSSplitView) {
            guard splitView !== sv else { return }
            splitView = sv
            sv.autosaveName = key
            SplitRegistry.shared.register(sv, name: key)
            restore()
            let nc = NotificationCenter.default
            observers.keep(nc.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: sv,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                    self?.mirrorCoupledWidthToOther()
                    SplitRegistry.shared.bump()
                }
            })
            // Also flush on terminate so the final split position is
            // guaranteed to be on disk before the app exits.
            observers.keep(nc.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                    UserDefaults.standard.synchronize()
                }
            })
            // A workspace preset writes a row's height straight into the
            // `SplitPane.*` keys and then asks every attached split to read
            // them back; see `WorkspaceLayout`.
            WorkspaceLayout.registerRestorer(key: key) { [weak self] in self?.restore() }
        }

        private func legacyKey() -> String { "SplitSizes.\(key)" }
        private func paneKey(_ pane: String) -> String { "SplitPane.\(key).\(pane)" }

        private func size(of view: NSView, in sv: NSSplitView) -> Double {
            Double(sv.isVertical ? view.frame.width : view.frame.height)
        }

        private func save() {
            // A restore in flight moves the dividers itself, and AppKit
            // reports each intermediate position. Writing those back would
            // overwrite the very sizes being restored with a half-applied
            // arrangement — which is how a pane toggle, or a maximize and
            // restore, could quietly lose the user's layout.
            guard Date() >= restoreSettledAt,
                  Date() >= WorkspaceLayout.savesSuppressedUntil else { return }
            guard let sv = splitView,
                  sv.arrangedSubviews.count == panes.count,
                  panes.count >= 2 else { return }
            let sizes = sv.arrangedSubviews.map { size(of: $0, in: sv) }
            // Skip transient zero-width states during initial layout.
            if sizes.contains(where: { $0 <= 1 }) { return }
            let defaults = UserDefaults.standard
            for (pane, s) in zip(panes, sizes) where pane != flexible {
                defaults.set(s, forKey: paneKey(pane))
            }
            if panes == canonical {
                defaults.set(sizes, forKey: legacyKey())
            }
        }

        /// Restores each non-flexible pane to its saved size: panes
        /// before the flexible one are positioned from the leading edge,
        /// panes after it from the trailing edge.
        func restore() {
            restoreSettledAt = Date(timeIntervalSinceNow: DS.Motion.standardSettleDelay + 0.05)
            guard let sv = splitView,
                  sv.arrangedSubviews.count == panes.count,
                  panes.count >= 2,
                  let flexIndex = panes.firstIndex(of: flexible) else { return }
            let defaults = UserDefaults.standard

            // Legacy migration: seed per-pane sizes from the old array
            // the first time we see the full pane set.
            if let legacy = defaults.array(forKey: legacyKey()) as? [Double],
               legacy.count == canonical.count {
                for (pane, s) in zip(canonical, legacy) where pane != flexible {
                    if defaults.object(forKey: paneKey(pane)) == nil {
                        defaults.set(s, forKey: paneKey(pane))
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self, let sv = self.splitView,
                      sv.arrangedSubviews.count == self.panes.count else { return }
                let total = Double(sv.isVertical ? sv.frame.width : sv.frame.height)
                guard total > 1 else { return }
                let thickness = Double(sv.dividerThickness)

                // Leading panes.
                var accum: Double = 0
                for i in 0..<flexIndex {
                    guard let s = defaults.object(forKey: self.paneKey(self.panes[i])) as? Double, s > 1 else {
                        accum += self.size(of: sv.arrangedSubviews[i], in: sv) + thickness
                        continue
                    }
                    accum += s
                    sv.setPosition(accum, ofDividerAt: i)
                    accum += thickness
                }
                // Trailing panes, from the far edge back.
                var trailing: Double = 0
                for i in stride(from: self.panes.count - 1, to: flexIndex, by: -1) {
                    guard let s = defaults.object(forKey: self.paneKey(self.panes[i])) as? Double, s > 1 else {
                        trailing += self.size(of: sv.arrangedSubviews[i], in: sv) + thickness
                        continue
                    }
                    trailing += s
                    sv.setPosition(total - trailing, ofDividerAt: i - 1)
                    trailing += thickness
                }
            }
        }

        /// Push the rightmost pane width from this split to its coupled
        /// partner (Status ⇄ AI Assistant). Only while both splits show
        /// their full pane set, so a collapsed pane never mirrors a
        /// canvas or terminal width into the other row.
        fileprivate func mirrorCoupledWidthToOther() {
            if Self.mirrorInProgress { return }
            if Date() < Self.mirrorSuppressedUntil { return }

            guard Self.coupledKeys.contains(key),
                  panes == canonical,
                  let src = splitView,
                  src.arrangedSubviews.count >= 2 else { return }

            let otherKey: String
            switch key {
            case "TopHSplit":    otherKey = "BottomHSplit"
            case "BottomHSplit": otherKey = "TopHSplit"
            default: return
            }
            let otherCanonical = otherKey == "TopHSplit" ? SplitViewConfigurator.topCanonical : ["terminal", "ai"]
            guard Self.panesByKey[otherKey] == otherCanonical,
                  let dst = SplitRegistry.shared.split(otherKey),
                  dst.arrangedSubviews.count == otherCanonical.count else { return }

            let srcRight = src.arrangedSubviews.last!.frame.width
            let dstRight = dst.arrangedSubviews.last!.frame.width
            // Bail when widths already agree, when either split hasn't
            // been laid out yet, or when the source's right pane is
            // degenerate. Sub-pixel epsilon avoids chasing rounding noise.
            guard srcRight > 1, dst.frame.width > 1,
                  abs(srcRight - dstRight) > 0.5 else { return }

            Self.mirrorInProgress = true
            Self.mirrorSuppressedUntil = Date(timeIntervalSinceNow: 0.1)
            defer { Self.mirrorInProgress = false }

            let lastDividerIndex = dst.arrangedSubviews.count - 2
            let pos = dst.frame.width - srcRight - dst.dividerThickness
            dst.setPosition(pos, ofDividerAt: lastDividerIndex)
        }
    }
}

/// One-shot rename of the top split's right pane key. The column used to
/// be saved as `SplitPane.TopHSplit.status` even when only the Inspector
/// was showing, so an Inspector-only width came back as the Status
/// width. The pane is "right" now; the old value seeds the new key once
/// and is then left alone.
@MainActor
private enum SplitKeyMigration {
    private static var done = false

    static func runOnce() {
        guard !done else { return }
        done = true
        let defaults = UserDefaults.standard
        let old = "SplitPane.TopHSplit.status"
        let new = "SplitPane.TopHSplit.right"
        if defaults.object(forKey: new) == nil, let width = defaults.object(forKey: old) {
            defaults.set(width, forKey: new)
        }
    }
}

// MARK: - Preset-driven row proportions

/// The one place that writes a divider position on the user's behalf.
///
/// Divider positions live in `SplitPane.<split>.<pane>` and are the
/// authority: `SplitViewConfigurator.restore()` re-applies them on attach
/// and on every pane-set change, and `save()` writes them back on the first
/// `didResizeSubviews`. That is exactly right for a divider the user has
/// dragged, and exactly wrong for a *preset*, which is a claim about
/// proportion — "the interactive shell as the second half of the window" —
/// that a saved 243-pt bottom row silently overrides.
///
/// So a preset that promises a proportion writes it into the key before it
/// flips the visibility flags, and then asks every attached split to read
/// the keys back. Presets that promise only an arrangement ("Build
/// Network", "Canvas Only") write nothing and keep every divider where the
/// user left it.
@MainActor
enum WorkspaceLayout {
    /// The outer vertical split, whose rows are "top" (canvas), "results"
    /// and "bottom" (Shell / AI). "top" is the flexible row, so it is the
    /// only one that has no key of its own.
    static let outerSplitKey = "OuterVSplit"

    /// Re-apply calls, one per attached split, weakly held by their
    /// coordinator so a retired split simply does nothing.
    private static var restorers: [String: () -> Void] = [:]

    /// Instant until which `SplitViewConfigurator.save()` stands down.
    ///
    /// Applying a preset adds and removes whole rows, and AppKit reports
    /// every intermediate geometry as a `didResizeSubviews` — during its
    /// layout pass, which runs BEFORE the main-queue block that the pane-set
    /// change schedules the restore in. Without this window the split would
    /// write those transient heights straight over the proportion the preset
    /// has just asked for, and the preset would be undone before it landed.
    /// It is the same hazard `restore()` guards with `restoreSettledAt`, one
    /// runloop turn earlier than `restore()` is able to set it.
    private(set) static var savesSuppressedUntil: Date = .distantPast

    /// Opens that window. Called by `applyWorkspacePreset` before it writes
    /// anything, and only for a preset that actually sets a proportion.
    static func beginPresetTransition() {
        savesSuppressedUntil = Date(timeIntervalSinceNow: DS.Motion.standardSettleDelay + 0.05)
    }

    /// Called by each `SplitViewConfigurator.Coordinator` as it attaches.
    /// One entry per split key; a coordinator that has been released leaves
    /// a closure whose `weak self` is nil, which is exactly the right
    /// behaviour and costs one dictionary slot.
    static func registerRestorer(key: String, _ restore: @escaping () -> Void) {
        restorers[key] = restore
    }

    /// Gives one row of the outer split `fraction` of the WINDOW's height.
    ///
    /// The window, not the split, is the denominator: "45 % of the window"
    /// is what the preset's tooltip says, and the ~52 pt of unified title
    /// bar and toolbar above the panes is the whole difference between the
    /// two readings. Measuring against the smaller of the two and calling
    /// the answer a share of the window is the kind of quiet shortfall a
    /// user notices and cannot name. The split's height is the fallback
    /// only when the view is not in a window yet.
    ///
    /// Written as points, not as a fraction, because the key is a point
    /// height and the split may be resized afterwards — a preset is a
    /// one-time act, not a constraint. Clamped between the row's own
    /// minimum and whatever leaves the canvas row its minimum, so the
    /// arithmetic can never ask AppKit for a position it will refuse and
    /// silently round somewhere else; on a window too short for both
    /// minimums it writes nothing and the arrangement alone applies.
    ///
    /// A no-op before the split exists (a preset applied from a menu always
    /// has one): with no key written, `ContentView`'s ideal heights already
    /// produce this shape on the first layout pass.
    static func setOuterRowHeight(_ row: String, fraction: Double) {
        guard let split = SplitRegistry.shared.split(outerSplitKey),
              split.frame.height > 1 else { return }
        let workspace = Double(split.frame.height)
        let window = Double(split.window?.frame.height ?? split.frame.height)
        let smallest = Double(DS.Layout.bottomRowMinHeight)
        let largest = workspace - Double(DS.Layout.canvasRowMinHeight) - Double(split.dividerThickness)
        guard largest >= smallest else { return }
        let height = min(max(window * fraction, smallest), largest)
        UserDefaults.standard.set(height, forKey: "SplitPane.\(outerSplitKey).\(row)")
    }

    /// Asks every attached split to re-read its saved sizes.
    ///
    /// A pane-set change already triggers this through
    /// `SplitViewConfigurator.updateNSView`; this call is what makes a
    /// preset land when the pane set does NOT change — applying the Shell
    /// preset while its panes are already the ones showing, which is
    /// precisely when a user is asking for the proportion rather than the
    /// arrangement.
    static func reapplySavedSizes() {
        for restore in restorers.values { restore() }
    }
}

private extension NSView {
    func findParent<T: NSView>(ofType type: T.Type) -> T? {
        var current: NSView? = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }
}

// MARK: - Window frame persistence

/// Manually saves and restores the enclosing `NSWindow`'s frame to
/// `UserDefaults` under the key `WindowFrame.<name>`. SwiftUI's
/// `WindowGroup` doesn't honour `setFrameAutosaveName` reliably, so we
/// encode the frame as a string, observe move/resize/close/terminate, and
/// restore it explicitly on first layout. Ensures the last-known window
/// size + position is exactly what the user sees on next launch.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator(name: name) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.schedule(attachTo: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if !context.coordinator.attached {
            context.coordinator.schedule(attachTo: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let name: String
        private(set) var attached = false
        private weak var window: NSWindow?
        /// Every observer this coordinator registered, removed when it is
        /// released. SwiftUI builds a NEW Settings scene — and so a new
        /// coordinator — on every ⌘,, so a coordinator that never
        /// unregistered left four live blocks behind each time.
        private let observers = ObserverTokens()
        private var attachAttempts = 0

        init(name: String) { self.name = name }

        /// Attaches to the window if possible, else retries on the next run
        /// loop tick. Needed because `view.window` is often `nil` during the
        /// first layout pass under SwiftUI's `WindowGroup`.
        func schedule(attachTo view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if self.attached { return }
                if let window = view.window {
                    self.attach(to: window)
                    return
                }
                self.attachAttempts += 1
                if self.attachAttempts < 50 {
                    self.schedule(attachTo: view)
                }
            }
        }

        private func attach(to window: NSWindow) {
            guard !attached else { return }
            attached = true
            self.window = window
            restore()

            let nc = NotificationCenter.default
            let onChange: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
            observers.keep(nc.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window, queue: .main, using: onChange))
            observers.keep(nc.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window, queue: .main, using: onChange))
            observers.keep(nc.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window, queue: .main, using: onChange))
            observers.keep(nc.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                    UserDefaults.standard.synchronize()
                }
            })
        }

        func save() {
            guard let window else { return }
            // Skip degenerate frames that can appear during teardown.
            let frame = window.frame
            guard frame.width > WindowFrameAutosave.degenerateFrameSide,
                  frame.height > WindowFrameAutosave.degenerateFrameSide else { return }
            UserDefaults.standard.set(NSStringFromRect(frame),
                                      forKey: WindowFrameAutosave.defaultsKey(for: name))
        }

        private func restore() {
            guard let window,
                  let target = WindowFrameAutosave.savedFrame(named: name)
            else { return }
            window.setFrame(target, display: true, animate: false)
        }
    }
}

extension WindowFrameAutosave {
    /// A frame narrower or shorter than this is teardown noise (a window
    /// being torn down reports a near-zero frame), not something the user
    /// chose; it is neither saved nor restored.
    static let degenerateFrameSide: CGFloat = 200

    /// The `UserDefaults` key a window's frame is stored under.
    static func defaultsKey(for name: String) -> String { "WindowFrame.\(name)" }

    /// The frame saved under `name`, clamped onto the screen attached
    /// *now* that it overlaps most — `NSScreen.main` when it overlaps none
    /// — so a frame remembered on a since-disconnected display still opens
    /// on-screen. `nil` when nothing usable is stored.
    ///
    /// It is a type method rather than coordinator state because
    /// `AuxiliaryWindow.make` has to know the remembered frame *before* the
    /// window is ordered front — the autosaver only restores one run-loop
    /// tick after the first layout pass, by which point the user has
    /// already seen the window land centred and jump. The autosaver
    /// remains the authority for *saving*; this is only the early read.
    @MainActor
    static func savedFrame(named name: String) -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: defaultsKey(for: name))
        else { return nil }
        let rect = NSRectFromString(saved)
        guard rect.width > degenerateFrameSide,
              rect.height > degenerateFrameSide else { return nil }

        // Clamp onto ONE screen — the one the saved frame overlaps most,
        // and `NSScreen.main` when it overlaps none (the display it was
        // saved on is gone).
        //
        // Not the union of every screen: a union is a rectangle, and two
        // displays of different heights side by side make one whose corners
        // belong to neither. A frame clamped into that union can be moved
        // into the dead space between them, which is exactly the case this
        // function exists to prevent.
        //
        // The one thing this gives up is a window deliberately straddling
        // two displays: it is pulled onto the display it mostly covers.
        // That is the trade the union was making in reverse, and landing a
        // window entirely on a screen is the failure mode a user can fix.
        let screens = NSScreen.screens.map(\.visibleFrame).filter { !$0.isEmpty }
        let best = screens.max { a, b in
            let ia = a.intersection(rect), ib = b.intersection(rect)
            let areaA = ia.isNull ? 0 : ia.width * ia.height
            let areaB = ib.isNull ? 0 : ib.width * ib.height
            return areaA < areaB
        }
        let overlapping = best.flatMap { screen -> NSRect? in
            let hit = screen.intersection(rect)
            return (hit.isNull || hit.isEmpty) ? nil : screen
        }
        guard let screenFrame = overlapping
                ?? NSScreen.main?.visibleFrame
                ?? screens.first,
              !screenFrame.isEmpty
        else { return rect }
        var target = rect
        target.size.width  = min(target.width,  screenFrame.width)
        target.size.height = min(target.height, screenFrame.height)
        target.origin.x = max(screenFrame.minX,
                              min(target.origin.x, screenFrame.maxX - target.width))
        target.origin.y = max(screenFrame.minY,
                              min(target.origin.y, screenFrame.maxY - target.height))
        return target
    }
}
