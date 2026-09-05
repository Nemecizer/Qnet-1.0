import SwiftUI
import AppKit

// MARK: - Build stamp formatting

/// Parses and formats `AppVersion.buildTimestamp` ("MM.dd.yyyy.HHmm").
/// The raw dotted stamp is never the only thing a user sees; every
/// window that shows it also shows a human-readable date.
enum BuildStamp {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM.dd.yyyy.HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func date(from stamp: String) -> Date? {
        parser.date(from: stamp)
    }

    /// "12 May 2026" for the date half of a stamp.
    static func dateText(_ stamp: String) -> String? {
        guard let d = date(from: stamp) else { return nil }
        return d.formatted(.dateTime.day().month(.wide).year())
    }

    /// "06:06" for the time half of a stamp.
    static func timeText(_ stamp: String) -> String? {
        guard let d = date(from: stamp) else { return nil }
        return d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// "12 May 2026, 06:06" — or the raw stamp if it does not parse.
    static func humanReadable(_ stamp: String) -> String {
        if let dt = dateText(stamp), let tm = timeText(stamp) {
            return "\(dt), \(tm)"
        }
        return stamp
    }
}

// MARK: - Escape closes window

/// Attaches an invisible button bound to the cancel action (Escape) so a
/// hosted auxiliary window can be dismissed from the keyboard, matching
/// every panel-style window on the Mac.
private struct EscapeClosesWindow: ViewModifier {
    let close: () -> Void

    func body(content: Content) -> some View {
        content.background {
            Button("") { close() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: DS.Layout.hiddenProbeSize, height: DS.Layout.hiddenProbeSize)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func escapeClosesWindow(_ close: @escaping () -> Void) -> some View {
        modifier(EscapeClosesWindow(close: close))
    }
}

// MARK: - Auxiliary windows

/// Weak reference handed to a hosted view so its Close button and Escape
/// key act on the window that hosts *it*, never on `NSApp.keyWindow`.
@MainActor
final class WindowRef {
    weak var window: NSWindow?
    func close() { window?.performClose(nil) }
}

/// Root actually handed to the hosting controller: the caller's view plus
/// the two things every auxiliary window may want wrapped around it — the
/// Escape binding and the frame autosaver. Both are opt-in through
/// `AuxiliaryWindow.make`, and both have to be *inside* the SwiftUI
/// hierarchy (the autosaver is an `NSViewRepresentable` that waits for
/// `view.window`), which is why they live here and not on the NSWindow.
private struct AuxiliaryWindowRoot<Root: View>: View {
    let root: Root
    let escapeCloses: Bool
    let close: () -> Void
    let frameKey: String?

    var body: some View {
        Group {
            if escapeCloses {
                root.escapeClosesWindow(close)
            } else {
                root
            }
        }
        .background {
            if let frameKey {
                WindowFrameAutosave(name: frameKey)
            }
        }
    }
}

/// Fires `action` once, when `window` closes, then unregisters itself.
///
/// `SettingsWindowTagger` hangs the same kind of observer off its own
/// coordinator, but a window built by `AuxiliaryWindow.make` has no
/// coordinator to hang one on — so the observer owns itself and the table
/// below keeps it alive for exactly as long as its window is open.
@MainActor
private final class WindowCloseObserver {
    private static var live: [ObjectIdentifier: WindowCloseObserver] = [:]

    private let key: ObjectIdentifier
    private let action: () -> Void
    private var token: NSObjectProtocol?

    private init(key: ObjectIdentifier, action: @escaping () -> Void) {
        self.key = key
        self.action = action
    }

    static func attach(to window: NSWindow, action: @escaping () -> Void) {
        let key = ObjectIdentifier(window)
        // A window is made once and reused; a second attach would fire the
        // handler twice.
        guard live[key] == nil else { return }
        let observer = WindowCloseObserver(key: key, action: action)
        observer.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { observer.fire() }
        }
        live[key] = observer
    }

    private func fire() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        Self.live[key] = nil
        action()
    }
}

/// Factory for the app's non-document windows (About, Qnet Help, Release
/// Notes, SRBM MLMC Guide) and, through `DSPanelWindow`, for every movable
/// dialog panel. Every window it makes:
///   • carries an identifier prefixed `<app>.aux.` so File ▸ Close Tab can
///     tell it apart from the main canvas window,
///   • is listed in the Window menu,
///   • refuses window tabbing so ⌘T / "Merge All Windows" can't capture it,
///   • closes on Escape and is retained (`isReleasedWhenClosed = false`).
@MainActor
enum AuxiliaryWindow {
    static var identifierPrefix: String { "\(GUIKitConfig.identifierNamespace).aux." }

    static func isAuxiliary(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(identifierPrefix) ?? false
    }

    /// - Parameters:
    ///   - escapeCloses: Bind Escape to closing the window. Pass `false`
    ///     when the hosted root already owns the cancel action — a
    ///     `DSSheetFooter` binds Cancel to `.cancelAction`, and a detached
    ///     Inspector needs Escape to revert the field being edited rather
    ///     than to throw the window away.
    ///   - fullScreenAuxiliary: Let the window open *into* the full-screen
    ///     space the user is already in instead of yanking them back to the
    ///     desktop. True for anything a user opens while working: a help
    ///     window, a reference window, a dialog panel.
    ///   - frameKey: `WindowFrameAutosave` name. When set, the window is
    ///     restored to the frame the user last left it at — this launch or
    ///     any previous one — and is NOT centred. Do not pass one for a
    ///     fixed-size window (About): its size is a deliberate lock, and a
    ///     remembered frame would fight it.
    ///   - onClose: Run when the window closes, however it was closed
    ///     (button, ⌘W, Escape, Quit). Fires once.
    static func make<Root: View>(
        id: String,
        title: String,
        contentSize: NSSize,
        minSize: NSSize? = nil,
        resizable: Bool = true,
        transparentTitlebar: Bool = false,
        escapeCloses: Bool = true,
        fullScreenAuxiliary: Bool = false,
        frameKey: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder root: (WindowRef) -> Root
    ) -> NSWindow {
        let ref = WindowRef()
        let rootView = AuxiliaryWindowRoot(
            root: root(ref),
            escapeCloses: escapeCloses,
            close: { ref.close() },
            frameKey: frameKey)
        let hosting = NSHostingController(rootView: rootView)
        if !resizable {
            // Lock the hosting controller to the SwiftUI view's preferred
            // size so AppKit doesn't renegotiate during the first display
            // cycle (avoids the macOS 26 NSHostingView constraint recursion).
            hosting.sizingOptions = [.preferredContentSize]
            hosting.preferredContentSize = contentSize
        }
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifierPrefix + id)
        var mask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { mask.insert([.miniaturizable, .resizable]) }
        window.styleMask = mask
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = false
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = transparentTitlebar
        window.setContentSize(contentSize)
        if let minSize { window.contentMinSize = minSize }
        if fullScreenAuxiliary { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        // Restore before the window is ordered front, so the user never
        // sees it land centred and then jump to where they left it.
        if let frameKey, let saved = savedFrame(named: frameKey) {
            window.setFrame(saved, display: false, animate: false)
        } else {
            window.center()
        }
        if let onClose { WindowCloseObserver.attach(to: window, action: onClose) }
        ref.window = window
        return window
    }

    /// The frame `WindowFrameAutosave` saved under `name`, clamped onto the
    /// screens attached *now*. One implementation, in the autosaver that
    /// writes the key: `make` needs the frame *before* the window is
    /// ordered front, which is the only reason the read is separable from
    /// the autosaver's own restore at all.
    static func savedFrame(named name: String) -> NSRect? {
        WindowFrameAutosave.savedFrame(named: name)
    }

    /// Bring an existing window forward and activate the app.
    static func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main window registry

/// Remembers which NSWindows host the main canvas `ContentView`, so
/// File ▸ Close Tab (⌘W) can close *the key window* when that window is
/// an auxiliary panel (About, Help, Release Notes, Settings) and close a
/// canvas tab only when the canvas window is in front.
@MainActor
enum MainWindowRegistry {
    private static let table = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) { table.add(window) }
    static func contains(_ window: NSWindow) -> Bool { table.contains(window) }
    static var isEmpty: Bool { table.count == 0 }

    /// The canvas window a `.documentModal` panel should hang off.
    ///
    /// NOT `NSApp.keyWindow`: ⌥⌘N (File ▸ New from Archetype…) stays live
    /// while Settings or Qnet Help is in front, and parenting the gallery
    /// to one of those makes it travel with that window, order above it,
    /// and vanish when it closes — while its Insert acts on a canvas the
    /// user cannot see. Only a registered canvas window is ever a parent.
    ///
    /// `nil` means "no suitable parent": the caller should leave the panel
    /// unparented rather than attach it to something arbitrary.
    static func documentWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, contains(key) { return key }
        if let main = NSApp.mainWindow, contains(main) { return main }
        // Front-to-back, so this is the canvas window the user looked at
        // most recently rather than whichever one was made first.
        if let front = NSApp.orderedWindows.first(where: { contains($0) }) { return front }
        // Registry still empty — the tagger attaches a run-loop tick after
        // the window exists — so keep the historical fallback, minus the
        // one case it got wrong.
        guard isEmpty, let candidate = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return AuxiliaryWindow.isAuxiliary(candidate) ? nil : candidate
    }

    /// True when the key window is (or is presumed to be) the canvas
    /// window. When the registry is empty (attachment still pending) we
    /// fall back to "not auxiliary", preserving the historical behaviour.
    static func keyWindowIsMainContent() -> Bool {
        guard let key = NSApp.keyWindow else { return true }
        if contains(key) { return true }
        if isEmpty { return !AuxiliaryWindow.isAuxiliary(key) }
        return false
    }
}

/// Invisible helper placed in the main window's view hierarchy; registers
/// the hosting NSWindow once it exists.
struct MainWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.schedule(view, attempts: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window { MainWindowRegistry.register(w) }
    }

    private static func schedule(_ view: NSView, attempts: Int) {
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if let w = view.window {
                MainWindowRegistry.register(w)
            } else if attempts < 50 {
                schedule(view, attempts: attempts + 1)
            }
        }
    }
}

// MARK: - Menu context

/// Observable state the command menus need that does not live on the
/// editor: whether a text control has keyboard focus (so Cut/Copy stay
/// enabled for text fields even when the canvas selection is empty),
/// whether the key window is the canvas window (so canvas-only key
/// equivalents such as the bare-letter tool hotkeys stay out of Help,
/// Settings and Release Notes) and the Open Recent list.
@MainActor
final class MenuContext: ObservableObject {
    @Published private(set) var textInputHasFocus = false
    /// True while the key window hosts the canvas `ContentView` (or no
    /// window is key). False while an auxiliary window — Qnet Help,
    /// Settings, Release Notes, About, SRBM MLMC Guide — is in front.
    @Published private(set) var keyWindowIsMain = true
    /// True while a sheet presented by the App scene (Generate Random, Find
    /// Node, Run Test Set, Spectral Convergence, any run-parameter sheet) is
    /// up. The editor-owned sheets are read from the editor directly; these
    /// live in `QnetGUIApp`'s @State, so it mirrors them here for
    /// `QnetCommands.sheetPresented` — canvas key equivalents (tool letters,
    /// ⌫) must not fire underneath any of them.
    @Published var appSheetPresented = false
    /// True while the active editor has one of ITS sheets up (node or link
    /// inspector, SRBM export). Mirrored here so command groups that do
    /// not observe the editor — `WorkspaceCommands` — can still refuse to
    /// switch tabs or move focus out from under a sheet.
    @Published var editorSheetPresented = false
    /// True while a `DSPanelWindow` opened in `.documentModal` or
    /// `.appModal` is up. Deliberately NOT `appSheetPresented`: that flag
    /// says "SwiftUI is showing the scene's one sheet", and the ~50
    /// `.disabled(sheetPresented)` menu items in `QnetCommands` would stay
    /// disabled forever if a window-hosted panel ever set it and closed by
    /// a path SwiftUI does not see. A panel is a real window, so it clears
    /// itself from `NSWindow.willCloseNotification`.
    @Published var modalPanelPresented = false
    /// Any modal sheet at all. Commands that present a second sheet, or
    /// that would change which editor a presented sheet is writing into,
    /// disable themselves on this.
    var anySheetPresented: Bool { appSheetPresented || editorSheetPresented || modalPanelPresented }
    @Published private(set) var recentDocumentURLs: [URL] = []

    /// Fingerprint of the focused text control's own undo stack —
    /// "can it undo, and under what name", plus the same for redo.
    ///
    /// Nothing reads the string; publishing it is the entire point, and it
    /// must not be deleted as dead state. `QnetCommands.undoRouting(redo:)`
    /// decides Edit ▸ Undo's title, its enablement AND its action from live
    /// AppKit state (`NSApp.keyWindow?.firstResponder`, and that field
    /// editor's `UndoManager`), none of which is observable. A `Commands`
    /// body is re-evaluated only when something it observes publishes, so
    /// the menu item was only ever as fresh as the last change to the
    /// editor, `AppSettings`, `SettingsSearchModel` or `textInputHasFocus`.
    ///
    /// That held everywhere a text field writes straight through to an
    /// observed model (a node name, the status search box, the Settings
    /// search field) and failed everywhere one keeps a local `@State`
    /// draft and commits on Return or focus loss — which is every
    /// `DSNumericField`, hence every numeric row in Settings, and the AI
    /// pane's API-key field. MEASURED before this property existed, in the
    /// Settings window with the canvas stack holding one step: typing "9"
    /// into Discrete-Event Simulation ▸ Replications left Edit ▸ Undo
    /// reading "Undo Change Buffer Mode" while invoking it undid the
    /// typing; with the canvas stack empty the item stayed *disabled* and
    /// the first ⌘Z after typing was swallowed entirely.
    ///
    /// `refreshFocus()` already runs after every keystroke (the deferred
    /// event monitor below), so re-publishing on a genuine change of the
    /// field editor's undo state is enough to keep the item honest. It
    /// changes on the first character typed and on each undo/redo, and not
    /// on the second, third or hundredth character — so this costs one
    /// string compare per key event and no extra menu rebuilds.
    @Published private(set) var textUndoState = ""

    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    init() {
        refreshRecents()
        let nc = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,
                     NSControl.textDidBeginEditingNotification,
                     NSControl.textDidEndEditingNotification,
                     NSText.didBeginEditingNotification,
                     NSText.didEndEditingNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: refresh))
        }
        // Clicks and Tab presses move keyboard focus without posting any
        // notification; re-check after the event has been dispatched.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            Task { @MainActor in
                MenuContextRegistry.shared?.refreshFocus()
            }
            return event
        }
        MenuContextRegistry.shared = self
        refreshFocus()
    }

    func refreshFocus() {
        let focused = NSApp.keyWindow?.firstResponder is NSText
        if focused != textInputHasFocus { textInputHasFocus = focused }
        let mainIsKey = MainWindowRegistry.keyWindowIsMainContent()
        if mainIsKey != keyWindowIsMain { keyWindowIsMain = mainIsKey }
        let undoState = Self.focusedTextUndoState()
        if undoState != textUndoState { textUndoState = undoState }
    }

    /// The focused field editor's undo/redo availability and action names,
    /// or "" when no text control holds keyboard focus.
    ///
    /// Deliberately the SAME predicate and the SAME undo manager
    /// `QnetCommands` routes ⌘Z through (`firstResponder as? NSText`, then
    /// `NSResponder.undoManager`), so a change this notices is exactly a
    /// change that would alter what the menu item says or does.
    private static func focusedTextUndoState() -> String {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText,
              let manager = text.undoManager
        else { return "" }
        return [
            manager.canUndo ? "u" : "-",
            manager.undoActionName,
            manager.canRedo ? "r" : "-",
            manager.redoActionName
        ].joined(separator: "\u{1f}")
    }

    /// Identifier AppKit gives the SwiftUI `Settings` scene window.
    static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// True while the Settings window is key. Asks `SettingsWindowTagger`,
    /// which knows the window SwiftUI actually built by identity once the
    /// pane has appeared, and falls back to the identifier above before the
    /// tagger has attached.
    static func settingsWindowIsKey() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return SettingsWindowTagger.isSettingsWindow(window)
    }

    func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshRecents()
    }

    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecents()
    }

    func refreshRecents() {
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls != recentDocumentURLs { recentDocumentURLs = urls }
    }
}

/// Lets the (non-isolated) NSEvent monitor reach the main-actor context
/// without capturing it in a non-Sendable closure.
@MainActor
enum MenuContextRegistry {
    static weak var shared: MenuContext?
}

// MARK: - Menu shortcut audit

/// Walks the built `NSApp.mainMenu` and reports every pair of items that
/// share a key equivalent + modifier mask. Runs automatically in DEBUG
/// builds shortly after launch; set `<APP>_MENU_AUDIT=1` in the environment
/// to print the full shortcut map to stderr and exit with status 1 on any
/// collision (used by the smoke test so a regression fails the build).
@MainActor
enum MenuShortcutAudit {
    struct Entry: CustomStringConvertible {
        let path: String
        let key: String
        let modifiers: NSEvent.ModifierFlags

        var description: String { "\(Self.glyphs(modifiers))\(Self.keyName(key))  \(path)" }

        static func glyphs(_ m: NSEvent.ModifierFlags) -> String {
            var s = ""
            if m.contains(.control) { s += "⌃" }
            if m.contains(.option)  { s += "⌥" }
            if m.contains(.shift)   { s += "⇧" }
            if m.contains(.command) { s += "⌘" }
            return s
        }

        static func keyName(_ k: String) -> String {
            switch k {
            case "\u{08}", "\u{7f}": return "⌫"
            case "\t": return "⇥"
            case "\u{19}": return "⇤"
            case "\r": return "↩"
            case " ": return "Space"
            case "\u{1b}": return "Esc"
            // AppKit's function-key code points, as SwiftUI writes them
            // into `keyEquivalent` for the arrow keys.
            case "\u{F700}": return "↑"
            case "\u{F701}": return "↓"
            case "\u{F702}": return "←"
            case "\u{F703}": return "→"
            default: return k.uppercased()
            }
        }
    }

    /// Returns (all shortcuts, collisions).
    static func run() -> (entries: [Entry], collisions: [[Entry]]) {
        var entries: [Entry] = []
        // `NSApp` is nil in the headless CLI modes (`--dump-help`), where
        // the Keyboard Shortcuts topic still has to render its prose.
        guard let app = NSApp, let menu = app.mainMenu else { return ([], []) }
        walk(menu, path: "", into: &entries)
        var buckets: [String: [Entry]] = [:]
        for e in entries {
            let mask = e.modifiers.intersection([.command, .option, .shift, .control])
            // ⇧ is implied for shifted characters like "?"; normalise so
            // "?"+⌘ and "/"+⇧⌘ are not double-counted as distinct.
            buckets["\(e.key)|\(mask.rawValue)", default: []].append(e)
        }
        let collisions = buckets.values.filter { $0.count > 1 }.map { $0 }
        return (entries, collisions)
    }

    private static func walk(_ menu: NSMenu, path: String, into entries: inout [Entry]) {
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden { continue }
            let title = item.title.isEmpty ? "(untitled)" : item.title
            let itemPath = path.isEmpty ? title : "\(path) › \(title)"
            if !item.keyEquivalent.isEmpty, !item.isAlternate {
                let mask = item.keyEquivalentModifierMask
                // Shifted key equivalents are reported as the shifted glyph
                // with the shift flag; store them normalised so an uppercase
                // letter + ⌘ and the lowercase letter + ⇧⌘ compare equal.
                let key = item.keyEquivalent
                let isUpper = key.count == 1 && key.uppercased() == key && key.lowercased() != key
                let normalisedKey = key.lowercased()
                var normalisedMask = mask
                if isUpper { normalisedMask.insert(.shift) }
                entries.append(Entry(path: itemPath, key: normalisedKey, modifiers: normalisedMask))
            }
            if let sub = item.submenu {
                walk(sub, path: itemPath, into: &entries)
            }
        }
    }

    /// Logs the map (or only the collisions) and asserts in DEBUG builds.
    static func runAndReport(verbose: Bool) {
        let (entries, collisions) = run()
        var err = StandardErrorStream()
        if verbose {
            print("[MenuAudit] \(entries.count) menu items carry a shortcut:", to: &err)
            for e in entries.sorted(by: { $0.path < $1.path }) {
                print("  \(e)", to: &err)
            }
        }
        // The tooltip table (KeyboardShortcutReference.Command) must say
        // what the menus print; a rebinding that leaves a tooltip behind
        // is reported here the same way a collision is.
        let drift = KeyboardShortcutReference.auditTable(against: entries)
        if !drift.isEmpty {
            print("[MenuAudit] \(drift.count) tooltip-table entr\(drift.count == 1 ? "y" : "ies") disagree with the menu bar:", to: &err)
            for line in drift { print("  ✗ \(line)", to: &err) }
            assertionFailure("Shortcut table drift: \(drift)")
        }
        if collisions.isEmpty {
            print("[MenuAudit] OK — no duplicate key equivalents.", to: &err)
        } else {
            print("[MenuAudit] \(collisions.count) shortcut collision(s):", to: &err)
            for group in collisions {
                for e in group { print("  ✗ \(e)", to: &err) }
            }
            assertionFailure("Menu shortcut collision(s): \(collisions)")
        }
        if ProcessInfo.processInfo.environment[GUIKitConfig.menuAuditEnvironmentKey] == "1" {
            exit(collisions.isEmpty && drift.isEmpty ? 0 : 1)
        }
    }
}

/// Minimal stderr sink for the audit report.
struct StandardErrorStream: TextOutputStream {
    mutating func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
