import SwiftUI
import AppKit

// MARK: - Panes in windows of their own
//
// A pane is either docked in the main window's split tree or in a window
// of its own — never both. That mutual exclusion is the whole safety
// argument for the feature, and it is enforced in exactly one place:
// `ContentView.shows(_:)` returns false for a detached pane, so the pane
// leaves the split tree in the same breath as its window opens. Two mounted
// copies of the Shell would put two `SwiftTermView` wrappers in a fight over
// `TerminalModel.hostView` and thrash the terminal; one copy, re-parented,
// is exactly what hiding and showing the pane already does, and it keeps
// the shell's PID and scrollback.
//
// ── Why tearing a pane OUT is never animated ─────────────────────────────
//
// `DS.Motion.standard` is a real 250 ms curve unless Reduce Motion is on,
// and the pane branches in `ContentView` carry `.transition(.opacity)`. So
// a pane removed inside `withAnimation` stays in the view tree, fading, for
// a quarter of a second after its window has already opened — and for the
// Shell that overlap is not cosmetic. `SwiftTermView.updateNSView` calls
// `attachHost`, which re-parents the model's cached terminal view into
// *its* wrapper; the outgoing, still-subscribed docked copy would do that
// the next time `TerminalModel` published anything (which, during a run, is
// many times a second) and steal the terminal back out of the new window,
// leaving it blank.
//
// Detaching therefore writes its settings with no animation: the docked
// pane is gone before the window exists, and the two wrappers are never
// alive together. Re-ATTACHING is animated as usual and is safe for the
// mirror-image reason — the thing being destroyed there is an AppKit
// window, torn down synchronously by `close()`, not a SwiftUI subtree
// lingering through a transition, and a pane being *inserted* runs
// `makeNSView` immediately however long its opacity takes to arrive.
//
// Nothing here re-implements a window. `AuxiliaryWindow.make` already owns
// the app's non-document windows — the `qnet.aux.` identifier that tells
// ⌘W apart from Close Tab, the Window-menu listing, the tabbing refusal,
// the frame autosave, the once-only close observer — and this file only
// says which panes get one and what goes inside.

/// The live inputs a detached pane needs from the main window, in one
/// observable object.
///
/// A detached pane is hosted by AppKit, outside the SwiftUI environment
/// the main window's view tree carries, so the four environment objects
/// have to be re-injected — and one of them, the editor, is *swapped* when
/// the user changes tab. Pushing new values into this object (rather than
/// rebuilding each window's root view) is what lets a detached Results
/// workspace follow the front tab without remounting, and what keeps a
/// detached Shell's terminal view from being torn down on a tab switch.
@MainActor
final class DetachedPaneContext: ObservableObject {
    /// The front tab's editor. Changes on every tab switch.
    @Published fileprivate(set) var editor: NetworkEditorModel
    @Published fileprivate(set) var activeTabID: UUID
    @Published fileprivate(set) var networkTitle: String

    /// App-lifetime singletons: one instance each, so they need no
    /// republishing when the front tab changes.
    let terminal: TerminalModel
    let appSettings: AppSettings
    let ai: AIModel
    let workingDirectory: URL

    fileprivate init(
        editor: NetworkEditorModel,
        activeTabID: UUID,
        networkTitle: String,
        terminal: TerminalModel,
        appSettings: AppSettings,
        ai: AIModel,
        workingDirectory: URL
    ) {
        self.editor = editor
        self.activeTabID = activeTabID
        self.networkTitle = networkTitle
        self.terminal = terminal
        self.appSettings = appSettings
        self.ai = ai
        self.workingDirectory = workingDirectory
    }

    /// Republishes only what actually changed: an unconditional write to a
    /// `@Published` property invalidates every detached window's body on
    /// every main-window update, which for the Shell means a terminal
    /// re-layout per keystroke elsewhere in the app.
    fileprivate func update(editor: NetworkEditorModel, activeTabID: UUID, networkTitle: String) {
        if self.editor !== editor { self.editor = editor }
        if self.activeTabID != activeTabID { self.activeTabID = activeTabID }
        if self.networkTitle != networkTitle { self.networkTitle = networkTitle }
    }
}

/// What a detached pane's window actually hosts: the same pane view the
/// split tree builds, with the environment re-injected around it.
///
/// The pane views are used unchanged and unwrapped — no wrapper, no extra
/// chrome of this file's own. Each one already draws its own
/// `DSSectionHeader`, already carries a `PaneFocusMarker` (which is what
/// makes Window ▸ Focus, ⌘F and ⌥⌘= keep working out here, through
/// `FocusRouter.paneRoot`'s no-split-view fallback), and already ends its
/// header with the control that puts it back.
///
/// The pane's own header therefore stays, deliberately: it is the only
/// place the working directory, the run count and the reattach control
/// live, and it is what draws the focus rule. What that leaves is a window
/// whose title bar and whose first line would otherwise both read "Shell",
/// which is why the window is titled `<network> — <pane>` (see
/// `PaneWindowController.windowTitle`) rather than by the pane alone: the
/// two lines say different things, and the Window menu's entry for this
/// window can no longer be confused with the "Shell" actions submenu next
/// to it.
private struct DetachedPaneRoot: View {
    let pane: FocusRouter.Pane
    @ObservedObject var context: DetachedPaneContext

    var body: some View {
        paneBody
            .environmentObject(context.editor)
            .environmentObject(context.terminal)
            .environmentObject(context.appSettings)
            .environmentObject(context.ai)
    }

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .status:
            StatusPanelView(showsFlagBar: true)
        case .inspector:
            InspectorPaneView()
        case .results:
            ResultsWorkspaceView(tabID: context.activeTabID, networkTitle: context.networkTitle)
        case .shell:
            TerminalPaneView(workingDirectory: context.workingDirectory)
        case .ai:
            AIPaneView()
        case .canvas, .palette:
            // Unreachable: `FocusRouter.Pane.canBeDetached` is false for
            // both, and every path into this file filters on it. Drawing
            // nothing is the right failure — an empty window the user can
            // close beats a crash.
            EmptyView()
        }
    }
}

/// Opens, closes and updates the pane windows so that the set on screen
/// always equals the set `AppSettings` says should be there.
///
/// Static state rather than an instance because there is exactly one such
/// set per process: the app has a single `WindowGroup` whose New-Window
/// item is replaced (`QnetCommands`, `CommandGroup(replacing: .newItem)`),
/// but even if a second main window did appear, both would drive this one
/// table and one shared context instead of racing to open two Shell
/// windows.
@MainActor
enum PaneWindowController {
    private static var windows: [FocusRouter.Pane: NSWindow] = [:]
    private static var context: DetachedPaneContext?

    /// Title bar text for a detached pane's window, the way Xcode titles a
    /// separate editor window: the document, then the thing this window
    /// shows of it.
    ///
    /// Not `pane.displayName` alone. The pane's own `DSSectionHeader` is
    /// the first line inside the window and already says the pane's name,
    /// so a window titled "Shell" printed it twice; and the Window menu
    /// lists that title one separator away from the "Shell" *actions*
    /// submenu (`WorkspaceCommands`), which put two different items called
    /// "Shell" in one menu. `FocusRouter.Pane.displayName` stays the single
    /// table the header, the toggles and the tooltips all read.
    static func windowTitle(_ pane: FocusRouter.Pane, networkTitle: String) -> String {
        let document = networkTitle.trimmingCharacters(in: .whitespaces)
        guard !document.isEmpty else { return pane.displayName }
        return "\(document) — \(pane.displayName)"
    }

    /// Panes whose window we are closing *because it is already docked
    /// again*. The close observer's job is to reattach a pane the user
    /// closed; without this it would also "reattach" — and so throw away
    /// the placement — every window we close on the way to hiding a pane.
    private static var closingProgrammatically: Set<FocusRouter.Pane> = []

    /// Set once, at quit. `NSWindow.willCloseNotification` is not promised
    /// at termination, but if AppKit does send it we must not read it as
    /// "the user put this pane back": that would dock every detached pane
    /// on quit and lose the arrangement the next launch is meant to
    /// restore.
    private static var appIsTerminating = false
    private static var terminationObserver: NSObjectProtocol?

    /// Top-left of the last pane window opened without a remembered frame,
    /// so a second one does not land exactly on top of the first.
    /// `AuxiliaryWindow.make` centres a window it has no saved frame for,
    /// which is right for a single dialog and wrong for a set.
    private static var cascadeOrigin = NSPoint.zero

    /// Brings the set of open pane windows in line with `wanted`.
    ///
    /// - Parameter activating: `false` for the first reconcile of a launch,
    ///   which restores windows remembered from last time — those must
    ///   appear without stealing key from the main window the user is
    ///   looking at. `true` when the user has just asked for one.
    static func reconcile(
        wanted: Set<FocusRouter.Pane>,
        editor: NetworkEditorModel,
        terminal: TerminalModel,
        appSettings: AppSettings,
        ai: AIModel,
        activeTabID: UUID,
        networkTitle: String,
        workingDirectory: URL,
        activating: Bool
    ) {
        observeTermination()

        // The overwhelmingly common case, and the one that must cost
        // nothing: no pane has ever been torn out. Holding no context also
        // means holding no reference to the front tab's editor, so closing
        // that tab really releases it.
        guard !wanted.isEmpty || !windows.isEmpty else {
            context = nil
            return
        }

        let ctx: DetachedPaneContext
        if let existing = context {
            existing.update(editor: editor, activeTabID: activeTabID, networkTitle: networkTitle)
            ctx = existing
            // The window title carries the document name, so it has to
            // follow a rename, a save-as or a tab switch. Written only when
            // it differs: setting `NSWindow.title` unconditionally on every
            // reconcile re-lays-out the title bar for nothing.
            for (pane, window) in windows {
                let title = windowTitle(pane, networkTitle: networkTitle)
                if window.title != title { window.title = title }
            }
        } else {
            ctx = DetachedPaneContext(
                editor: editor,
                activeTabID: activeTabID,
                networkTitle: networkTitle,
                terminal: terminal,
                appSettings: appSettings,
                ai: ai,
                workingDirectory: workingDirectory
            )
            context = ctx
        }

        // Over a snapshot: `close(_:)` mutates the table it is iterating.
        for pane in Array(windows.keys) where !wanted.contains(pane) {
            close(pane)
        }
        // Deterministic order, so restoring several windows at launch
        // cascades them the same way every time.
        for pane in FocusRouter.Pane.allCases where wanted.contains(pane) && windows[pane] == nil {
            open(pane, context: ctx, appSettings: appSettings, activating: activating)
        }

        if windows.isEmpty { context = nil }
    }

    /// Bring a detached pane's window to the front. A no-op for a docked
    /// pane, so callers do not have to ask first.
    static func present(_ pane: FocusRouter.Pane) {
        guard let window = windows[pane] else { return }
        AuxiliaryWindow.present(window)
    }

    private static func open(
        _ pane: FocusRouter.Pane,
        context: DetachedPaneContext,
        appSettings: AppSettings,
        activating: Bool
    ) {
        let window = AuxiliaryWindow.make(
            id: "pane.\(pane.rawValue)",
            title: windowTitle(pane, networkTitle: context.networkTitle),
            contentSize: DS.Layout.Window.detachedPaneDefault,
            minSize: DS.Layout.Window.detachedPaneMin,
            // Escape belongs to the pane, not to the window. In the Shell
            // it is a key the program on the other end of the pty reads; in
            // the Inspector it reverts the field being edited. Throwing the
            // window away on it would be a data loss, not a dismissal.
            escapeCloses: false,
            // Open into the full-screen space the user is already in
            // rather than yanking them back to the desktop — a pane window
            // is something you reach for mid-task.
            fullScreenAuxiliary: true,
            // Per pane, so the Shell's window comes back where the Shell's
            // window was, even after the Results window has been moved.
            frameKey: "DetachedPane.\(pane.rawValue)",
            onClose: {
                // The window is gone either way, so the table must let go
                // of it whoever closed it; only the *meaning* differs.
                windows[pane] = nil
                // Closing the window is how you put the pane back: it is
                // the only meaning a close button can have here that does
                // not lose the pane. (Hiding it is still ⌥⌘n, and the
                // toggle in View ▸ Panes is untouched.)
                guard !appIsTerminating,
                      !closingProgrammatically.contains(pane) else { return }
                appSettings.setDetached(pane, false)
            }
        ) { _ in
            DetachedPaneRoot(pane: pane, context: context)
        }
        windows[pane] = window
        // Cascade only the windows AppKit would otherwise centre. A pane
        // the user has already placed comes back exactly where they left
        // it, and is not nudged for having been opened second.
        if AuxiliaryWindow.savedFrame(named: "DetachedPane.\(pane.rawValue)") == nil {
            cascadeOrigin = window.cascadeTopLeft(from: cascadeOrigin)
        }
        if activating {
            AuxiliaryWindow.present(window)
        } else {
            // Launch restore: on screen, in front of nothing. The main
            // window keeps key focus, so the first keystroke of the session
            // still goes where the user is looking.
            window.orderFront(nil)
        }
    }

    private static func close(_ pane: FocusRouter.Pane) {
        // Hold the window across `close()`: `AuxiliaryWindow.make` sets
        // `isReleasedWhenClosed = false`, so this table is its only owner
        // and removing the entry first would deallocate it mid-close.
        guard let window = windows.removeValue(forKey: pane) else { return }
        closingProgrammatically.insert(pane)
        window.close()
        closingProgrammatically.remove(pane)
    }

    private static func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { appIsTerminating = true }
        }
    }
}

/// Invisible view that keeps `PaneWindowController` in step with the
/// settings and the front tab. Lives in `ContentView`'s background, which
/// is the only place that has all four environment objects, the active tab
/// and the workspace URL at once.
///
/// Reconciling is driven off a single key string rather than off `body`,
/// because `ContentView` re-renders on every node drag and pushing the
/// same values into the context that often would invalidate a detached
/// Shell's terminal view for nothing.
struct PaneWindowHost: View {
    let editor: NetworkEditorModel
    let terminal: TerminalModel
    let appSettings: AppSettings
    let ai: AIModel
    let activeTabID: UUID
    let networkTitle: String
    let workingDirectory: URL
    /// The panes that should have a window right now: detached AND shown.
    /// A pane hidden with ⌥⌘n keeps its detached placement for the next
    /// time it is shown, but must not leave a window behind meanwhile.
    let wanted: Set<FocusRouter.Pane>

    /// Everything a window's content depends on, flattened. The pane set
    /// is spelled in `allCases` order rather than the set's own, which has
    /// no order, so an unchanged set always produces the same key.
    private var reconcileKey: String {
        let panes = FocusRouter.Pane.allCases.filter(wanted.contains).map(\.rawValue)
        return ([activeTabID.uuidString,
                 networkTitle,
                 String(UInt(bitPattern: ObjectIdentifier(editor)))] + panes)
            .joined(separator: "|")
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { reconcile(activating: false) }
            .onChange(of: reconcileKey) { _, _ in reconcile(activating: true) }
    }

    private func reconcile(activating: Bool) {
        PaneWindowController.reconcile(
            wanted: wanted,
            editor: editor,
            terminal: terminal,
            appSettings: appSettings,
            ai: ai,
            activeTabID: activeTabID,
            networkTitle: networkTitle,
            workingDirectory: workingDirectory,
            activating: activating
        )
    }
}
