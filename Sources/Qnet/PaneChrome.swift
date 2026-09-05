import SwiftUI
import AppKit

/// Process start, used to tell "pane shown at launch" from "pane shown by
/// the user" (the AI composer only grabs focus in the latter case).
enum AppLaunch {
    static let date = Date()
}

extension Notification.Name {
    /// Posted (userInfo["tab"] = SettingsView.Tab rawValue) to ask the
    /// Settings window to open on a specific pane.
    static let bnetOpenSettingsTab = Notification.Name("bnet.settings.openTab")
}

/// Opens the Settings window on the given pane (by `SettingsView.Tab`
/// raw value). Uses the standard `showSettingsWindow:` responder action
/// SwiftUI installs for the `Settings` scene on macOS 13+.
@MainActor
func openSettingsPane(_ tabRawValue: String) {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    // Give the window a runloop turn to appear before selecting the pane.
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .bnetOpenSettingsTab,
            object: nil,
            userInfo: ["tab": tabRawValue]
        )
    }
}

// MARK: - Keyboard focus routing

/// Which main-window pane currently owns keyboard focus, and how to
/// move focus between panes without the mouse. Pane views register
/// their root NSView (via `PaneFocusMarker`) plus optional handlers for
/// Zoom In/Out and Find so the global menu shortcuts act on the pane
/// the user is looking at.
@MainActor
final class FocusRouter: ObservableObject {
    static let shared = FocusRouter()

    enum Pane: String, CaseIterable {
        case palette, canvas, status, results, shell, ai
        /// The docked parameter inspector (right column, above Status).
        case inspector

        /// Whether "give this pane the whole window" means anything for
        /// it. The Tools palette is width-capped by
        /// `DS.Layout.palettePaneMaxWidth` — maximizing it would draw a
        /// narrow column beside an empty window — so it is the one pane
        /// that offers no maximize control and is skipped by the menu item.
        var canBeMaximized: Bool { self != .palette }

        /// Whether the pane can be torn out into a window of its own.
        ///
        /// The canvas cannot: it *is* the document, and the main window
        /// would be left with a tab bar and nothing under it.
        ///
        /// The Tools palette cannot either, and its reason is its own, not
        /// the canvas's: it is a width-capped strip whose whole value is
        /// being next to the canvas, a window of one column of glyphs is a
        /// worse palette than a hidden one, and — mechanically — its
        /// header is the one built with the no-trailing `DSSectionHeader`
        /// overload, so a detached palette window would carry none of the
        /// controls every other detached pane reattaches itself with. So
        /// "6 of 6 panes detachable" is deliberately 5 of 6 plus two
        /// stated exclusions, not an unfinished feature.
        var canBeDetached: Bool { self != .canvas && self != .palette }

        /// The pane's name as the menus, headers and tooltips print it.
        /// One table, so "AI Assistant" cannot be "AI" in one place and
        /// "Assistant" in another.
        var displayName: String {
            switch self {
            case .palette:   return "Tools"
            case .canvas:    return "Canvas"
            case .status:    return "Status"
            case .results:   return "Results"
            case .shell:     return "Shell"
            case .ai:        return "AI Assistant"
            case .inspector: return "Inspector"
            }
        }
    }

    @Published private(set) var focusedPane: Pane?

    private final class RootBox { weak var view: NSView? }
    private var roots: [Pane: RootBox] = [:]

    /// Who registered the handler currently in each table.
    ///
    /// SwiftUI does not promise that a disappearing view's `onDisappear`
    /// runs before the replacing view's `onAppear`: toggle a pane off and
    /// on quickly and the OLD instance's teardown can arrive last, nilling
    /// the handler the NEW instance has already installed — after which
    /// ⌘F and ⌥⌘= silently do nothing for that pane until it is toggled
    /// again. Every table therefore records its registrant, and a clearing
    /// call is honoured only when it is clearing its own registration.
    ///
    /// `owner` is optional and defaults to nil so a registrant that has
    /// not opted in behaves exactly as before (nil claims and nil releases
    /// match each other); a pane that passes a token is protected.
    private var focusOwners = HandlerOwners()
    private var zoomOwners = HandlerOwners()
    private var findOwners = HandlerOwners()
    private var findStepOwners = HandlerOwners()

    /// Ownership bookkeeping for one handler table. An absent entry is the
    /// nil owner, so an un-opted-in registrant's clear still matches.
    private struct HandlerOwners {
        private var owners: [Pane: ObjectIdentifier] = [:]

        mutating func claim(_ pane: Pane, _ owner: ObjectIdentifier?) {
            owners[pane] = owner
        }

        /// True when `owner` is the pane's current registrant — i.e. this
        /// is the clearing call that should win.
        func mayRelease(_ pane: Pane, _ owner: ObjectIdentifier?) -> Bool {
            owners[pane] == owner
        }

        mutating func release(_ pane: Pane) {
            owners[pane] = nil
        }
    }

    private var focusHandlers: [Pane: () -> Void] = [:]
    private var zoomHandlers: [Pane: (Int) -> Void] = [:]
    /// Whether a pane's text size can still move in a given direction, so
    /// the View ▸ Panes menu items dim at the pane's min / max exactly as
    /// its own A+ / A− buttons do.
    private var zoomBounds: [Pane: (Int) -> Bool] = [:]
    private var findHandlers: [Pane: () -> Void] = [:]
    /// Find Next / Find Previous (⌘G / ⇧⌘G) for panes that keep a walkable
    /// match list; `findStepBounds` says whether there is anything to
    /// step through right now.
    private var findStepHandlers: [Pane: (Int) -> Void] = [:]
    private var findStepBounds: [Pane: () -> Bool] = [:]
    private var observer: NSObjectProtocol?
    private weak var lastResponder: AnyObject?

    private init() {
        // NSApplication posts didUpdate after every event is dispatched;
        // comparing the first responder identity is cheap, so this is
        // an inexpensive way to track pane focus without KVO on
        // NSWindow.firstResponder.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func register(root: NSView, for pane: Pane) {
        let box = roots[pane] ?? RootBox()
        box.view = root
        roots[pane] = box
    }

    /// Registers (or, with a nil handler, clears) the pane's Window ▸ Focus
    /// action. Pass `owner: token.id` — a `PaneHandlerOwner` held in the
    /// view's `@State` — to make the clear ignore a stale teardown.
    func setFocusHandler(_ pane: Pane, owner: ObjectIdentifier? = nil, _ handler: (() -> Void)?) {
        if handler == nil {
            guard focusOwners.mayRelease(pane, owner) else { return }
            focusOwners.release(pane)
        } else {
            focusOwners.claim(pane, owner)
        }
        focusHandlers[pane] = handler
    }

    func setZoomHandler(
        _ pane: Pane,
        owner: ObjectIdentifier? = nil,
        _ handler: ((Int) -> Void)?,
        canZoom: ((Int) -> Bool)? = nil
    ) {
        if handler == nil {
            guard zoomOwners.mayRelease(pane, owner) else { return }
            zoomOwners.release(pane)
        } else {
            zoomOwners.claim(pane, owner)
        }
        zoomHandlers[pane] = handler
        zoomBounds[pane] = handler == nil ? nil : canZoom
    }

    func setFindHandler(_ pane: Pane, owner: ObjectIdentifier? = nil, _ handler: (() -> Void)?) {
        if handler == nil {
            guard findOwners.mayRelease(pane, owner) else { return }
            findOwners.release(pane)
        } else {
            findOwners.claim(pane, owner)
        }
        findHandlers[pane] = handler
    }

    /// Registers ⌘G / ⇧⌘G for a pane. `canStep` is consulted for the menu
    /// items' enablement; call `noteFindStateChanged()` whenever its
    /// answer changes so the menu re-evaluates.
    func setFindStepHandler(
        _ pane: Pane,
        owner: ObjectIdentifier? = nil,
        _ handler: ((Int) -> Void)?,
        canStep: (() -> Bool)? = nil
    ) {
        if handler == nil {
            guard findStepOwners.mayRelease(pane, owner) else { return }
            findStepOwners.release(pane)
        } else {
            findStepOwners.claim(pane, owner)
        }
        findStepHandlers[pane] = handler
        findStepBounds[pane] = handler == nil ? nil : canStep
        objectWillChange.send()
    }

    /// Panes call this when their match count changes, so Edit ▸ Find
    /// Next / Find Previous enable and disable with it.
    func noteFindStateChanged() {
        objectWillChange.send()
    }

    /// Whether Find Next / Previous would do anything in the focused pane.
    var canStepFind: Bool {
        guard let pane = focusedPane, findStepHandlers[pane] != nil else { return false }
        return findStepBounds[pane]?() ?? true
    }

    /// Route Find Next (+1) / Find Previous (−1) to the focused pane.
    func stepFind(_ delta: Int) {
        refresh()
        guard let pane = focusedPane, let handler = findStepHandlers[pane] else { return }
        handler(delta)
    }

    /// Root NSView of a pane: the arranged subview of the enclosing
    /// NSSplitView that contains the registered marker.
    ///
    /// The split-view walk stays FIRST and unchanged, so every docked pane
    /// resolves to exactly the view it resolved to before — which is what
    /// keeps `firstFocusable(in:)` picking the same first responder. Only
    /// when there is no NSSplitView anywhere above the marker (a pane
    /// hosted in a window of its own, where the hosting controller's view
    /// is the whole content) do we fall back to that window's content
    /// view. Without the fallback `pane(containing:)` never matches such a
    /// pane, `focusedPane` stays nil, and Window ▸ Focus <pane>, ⌘F and
    /// ⌥⌘= / ⌥⌘− all silently do nothing there.
    private func paneRoot(_ pane: Pane) -> NSView? {
        guard let marker = roots[pane]?.view else { return nil }
        var current: NSView? = marker
        while let v = current, let parent = v.superview {
            if parent is NSSplitView { return v }
            current = parent
        }
        return marker.window?.contentView
    }

    private func pane(containing view: NSView) -> Pane? {
        for pane in Pane.allCases {
            if let root = paneRoot(pane), view === root || view.isDescendant(of: root) {
                return pane
            }
        }
        return nil
    }

    private func refresh() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let responder = window.firstResponder
        if responder === lastResponder { return }
        lastResponder = responder
        var view: NSView? = responder as? NSView
        if view == nil, let tv = responder as? NSText { view = tv }
        let newPane = view.flatMap { pane(containing: $0) }
        if newPane != focusedPane { focusedPane = newPane }
    }

    /// Move keyboard focus to a pane. Prefers a registered handler
    /// (the AI composer, the status table); otherwise makes the first
    /// focusable descendant of the pane root the first responder.
    func focus(_ pane: Pane) {
        orderPaneWindowFront(pane)
        if let handler = focusHandlers[pane] {
            handler()
            return
        }
        guard let root = paneRoot(pane), let window = root.window else { return }
        if let target = Self.firstFocusable(in: root) {
            window.makeFirstResponder(target)
        }
    }

    /// Bring the window that hosts `pane` forward before focusing it.
    ///
    /// A no-op for a docked pane invoked from the menu bar: the main
    /// window is already key. It matters when the pane lives in a window
    /// of its own, or when a reference window is key and Window ▸ Focus
    /// Shell is chosen — making a view the first responder of a window
    /// that is not key moves no visible focus at all.
    private func orderPaneWindowFront(_ pane: Pane) {
        guard let window = roots[pane]?.view?.window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    private static func firstFocusable(in view: NSView) -> NSView? {
        // Skip split views and SwiftUI hosting containers, which accept
        // first responder only to relay events.
        if view.acceptsFirstResponder,
           !(view is NSSplitView),
           !view.className.contains("Hosting") {
            return view
        }
        for sub in view.subviews {
            if let found = firstFocusable(in: sub) { return found }
        }
        return nil
    }

    /// Route Zoom In (+1) / Zoom Out (−1) to the focused pane's handler
    /// when it has one; otherwise run the canvas default.
    func zoom(_ direction: Int, default canvasAction: () -> Void) {
        refresh()
        if let pane = focusedPane, let handler = zoomHandlers[pane] {
            handler(direction)
        } else {
            canvasAction()
        }
    }

    /// Whether "Increase / Decrease Pane Text Size" would do anything
    /// right now: false when no focused pane has a zoom handler (the
    /// canvas, the Tools pane, or nothing has focus) and false when the
    /// focused pane is already at that end of its size range.
    func canZoom(_ direction: Int) -> Bool {
        guard let pane = focusedPane, zoomHandlers[pane] != nil else { return false }
        guard let bounds = zoomBounds[pane] else { return true }
        return bounds(direction)
    }

    /// Name of the pane the text-size commands would act on, for the menu
    /// item's tooltip ("Status", "Shell", "AI Assistant").
    var zoomTargetName: String? {
        guard let pane = focusedPane, zoomHandlers[pane] != nil else { return nil }
        return pane.displayName
    }

    /// Route ⌘F to the focused pane when it has a find UI.
    func find(default canvasAction: () -> Void) {
        refresh()
        if let pane = focusedPane, let handler = findHandlers[pane] {
            handler()
        } else {
            canvasAction()
        }
    }
}

/// Invisible marker that registers its host pane with `FocusRouter`.
/// Place it as `.background(PaneFocusMarker(.status))` on a pane's root.
struct PaneFocusMarker: NSViewRepresentable {
    let pane: FocusRouter.Pane

    init(_ pane: FocusRouter.Pane) { self.pane = pane }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        FocusRouter.shared.register(root: v, for: pane)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        FocusRouter.shared.register(root: nsView, for: pane)
    }
}

// MARK: - Handler registration ownership

/// Identity token for one view instance's `FocusRouter` handler
/// registrations. Hold it in `@State`, which gives one instance per view
/// *identity* and keeps it alive across body re-evaluations, and pass
/// `owner: token.id` to every `set…Handler` call the view makes — both
/// the install in `onAppear` and the clear in `onDisappear`. A teardown
/// that arrives after a newer instance has already registered then
/// recognises that it does not own the entry and leaves it alone.
final class PaneHandlerOwner {
    init() {}
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

// MARK: - Pane window control

/// The one control a pane header carries at the trailing edge of its
/// trailing slot, and the one place that decides what its words mean.
///
/// It answers whichever question the pane is currently in a position to
/// ask, so a header never grows a second window-management glyph:
///
///   • Docked — **Maximize** / **Restore Pane Layout**. Maximizing is a
///     *view* state, not a pane toggle: it hides nothing, it only stops
///     drawing the other panes, and restoring puts every divider back
///     where it was because the split-view autosave was never asked to
///     save the maximized arrangement (each split is down to a single
///     pane while one is maximized, and `SplitViewConfigurator` only
///     saves a split with two or more). That is why the button says
///     "Restore Pane Layout" rather than "Show Panes".
///   • In a window of its own — **Return to the Main Window**. Maximize is
///     meaningless there: the pane already has that window, and the main
///     window's other panes are not its to blank. Tearing a pane OUT is a
///     deliberate act and lives in the menus — View ▸ Panes ▸ Separate
///     Windows, and the toolbar's Workspace menu — but putting it back has
///     to be reachable from the window the user is looking at, which is
///     the detached one.
struct PaneSoloButton: View {
    @EnvironmentObject private var appSettings: AppSettings
    let pane: FocusRouter.Pane

    init(_ pane: FocusRouter.Pane) { self.pane = pane }

    private var isMaximized: Bool { appSettings.soloedPane == pane }
    private var isDetached: Bool { appSettings.isDetached(pane) }

    var body: some View {
        DSIconButton(systemImage: symbol, label: label, help: help) {
            withAnimation(DS.Motion.standard) {
                if isDetached {
                    appSettings.setDetached(pane, false)
                } else {
                    appSettings.toggleSolo(pane)
                }
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }

    private var symbol: String {
        if isDetached { return DS.Symbol.reattach }
        return isMaximized ? DS.Symbol.paneRestore : DS.Symbol.paneMaximize
    }

    private var label: String {
        if isDetached { return "Return \(pane.displayName) to the Main Window" }
        return isMaximized ? "Restore Pane Layout" : "Maximize \(pane.displayName) Pane"
    }

    /// The key equivalent is quoted from the one table rather than typed
    /// here, so a rebind cannot leave this tooltip behind.
    private var help: String {
        if isDetached {
            return "Put the \(pane.displayName) pane back into the main window, where it was before (closing this window does the same)"
        }
        return isMaximized
            ? "Put the other panes back exactly where they were (View ▸ Panes ▸ Restore Pane Layout, \(KeyboardShortcutReference.key(for: .maximizePane)))"
            : "Give the \(pane.displayName) pane the whole window; the other panes come back exactly as they are now (View ▸ Panes ▸ Maximize Pane, \(KeyboardShortcutReference.key(for: .maximizePane)))"
    }
}
