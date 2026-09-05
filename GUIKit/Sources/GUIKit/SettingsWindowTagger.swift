import SwiftUI
import AppKit

// Extracted from the host app's SettingsComponents.swift.
//
// SwiftUI hands you no reference to the NSWindow it builds for the Settings
// scene, so anything window-scoped there — routing a find command, persisting
// a frame, knowing whether Settings is the key window — has nothing to hold.
// These two types recover that handle by identity, once, when the pane appears.

struct SettingsWindowTagger: NSViewRepresentable {
    @MainActor private static weak var taggedWindow: NSWindow?

    /// True when `window` is the Settings window (by tag, or by the
    /// identifier SwiftUI gives the Settings scene as a fallback before the
    /// tagger has attached).
    @MainActor static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if let tagged = taggedWindow, tagged === window { return true }
        return window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
    }

    func makeNSView(context: Context) -> NSView {
        // The coordinator, not the whole `Context`: a `Context` carries the
        // environment and the current transaction, and an escaping closure
        // has no business holding either past this call.
        let coordinator = context.coordinator
        let v = WindowAttachView { window in
            Self.taggedWindow = window
            Self.restoreFrameOnce(window)
            coordinator.observe(window)
        }
        // `viewDidMoveToWindow` covers the normal path, but a view can also
        // be built with its window already set, and SwiftUI has been known
        // to install the hierarchy after the representable is made — so the
        // deferred attempt stays as the belt to that brace.
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            Self.taggedWindow = window
            Self.restoreFrameOnce(window)
            coordinator.observe(window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window {
            Self.taggedWindow = w
            Self.restoreFrameOnce(w)
            context.coordinator.observe(w)
        }
    }

    /// Windows this launch have already been put back where the user left
    /// them. Keyed by identity and weak, so that if SwiftUI ever does build
    /// a fresh Settings window (measured on this OS it re-shows the same
    /// one, but that is an implementation detail of the Settings scene) the
    /// old one cannot keep the new one out.
    @MainActor private static let restored = NSHashTable<NSWindow>.weakObjects()

    /// Puts the Settings window back at its saved frame as early as the view
    /// hierarchy allows.
    ///
    /// `SettingsView` also carries `WindowFrameAutosave(name:)`, which is the
    /// authority for *saving* and would restore too — but only from a
    /// `DispatchQueue.main.async` after the first layout pass, by which point
    /// the window has been ordered front at its centred ideal size and the
    /// user has seen it jump. `AuxiliaryWindow.make` avoids that for the
    /// other seven windows by reading the frame before it orders the window
    /// front; a `Settings` scene gives us no such hook, because SwiftUI owns
    /// the window's creation. `viewDidMoveToWindow` is the earliest moment
    /// this app can observe — it fires synchronously as the hosting view is
    /// installed, i.e. before SwiftUI orders the window front — so the
    /// restore happens there instead. The later autosaver restore then sets
    /// the same rect and is invisible.
    @MainActor private static func restoreFrameOnce(_ window: NSWindow) {
        makeResizable(window)
        keepResizable(window)
        guard !restored.contains(window) else { return }
        restored.add(window)
        guard let saved = WindowFrameAutosave.savedFrame(named: settingsFrameKey) else { return }
        window.setFrame(saved, display: false, animate: false)
    }

    /// Gives the Settings window the resize control every other window in
    /// the app has.
    ///
    /// SwiftUI builds a `Settings` scene's window WITHOUT `.resizable` in
    /// its style mask, and nothing declared in Swift moves it: measured on
    /// this OS, the scene's `.windowResizability(.contentMinSize)` already
    /// leaves `contentMaxSize` unbounded (1.8e308 in both axes) and the
    /// window is still `resizable == false`, and adding `maxWidth: .infinity,
    /// maxHeight: .infinity` to the view's own `.frame(…)` — the obvious fix
    /// — changes neither flag. The mask is the only thing left, so it is set
    /// here, on the one hook this app has into that window.
    ///
    /// It is safe precisely BECAUSE the limits are already right: the drag
    /// is bounded below by `contentMinSize`, which SwiftUI took from
    /// `SettingsView`'s `minWidth` / `minHeight`, and above by nothing —
    /// which is what a form of long scrolling panes wants. `SettingsView`'s
    /// `.frame(…)` carries the matching `maxWidth` / `maxHeight` so the
    /// panes actually grow into the extra room instead of leaving it blank.
    ///
    /// Idempotent: inserting a flag already present is a no-op. It is not
    /// sufficient on its own, though — see `keepResizable`, which re-asserts
    /// it after SwiftUI clears it.
    @MainActor private static func makeResizable(_ window: NSWindow) {
        guard !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
    }

    /// Windows whose `.resizable` flag is already being kept alive by an
    /// observer. Weak, and keyed by identity, for the same reason `restored`
    /// is.
    @MainActor private static let resizeWatched = NSHashTable<NSWindow>.weakObjects()

    /// Keeps `.resizable` set for as long as the Settings window exists.
    ///
    /// `makeResizable` at attach time is enough for the FIRST Settings
    /// window of a launch and no other. Measured on this OS, by logging the
    /// style mask from every `NSWindow` notification: SwiftUI clears the flag
    /// again one run-loop pass after the window is first ordered front (the
    /// existing `updateNSView` call happens to put it back, which is why the
    /// first open looks fixed), and clears it a second time as the window
    /// closes. ⌘, then does NOT build a new window — it re-shows the SAME
    /// `NSWindow`, identical `windowNumber` — so the view never left it,
    /// neither `viewDidMoveToWindow` nor `updateNSView` runs again, and
    /// nothing puts the flag back. Every Settings window after the first in a
    /// session was fixed-size until relaunch.
    ///
    /// The window's own notifications are the only hook that survives that
    /// re-show. `didUpdate` is the one that fires after SwiftUI's clear;
    /// `didBecomeKey` is observed too so the resize control is never briefly
    /// dead while the window is already on screen. `makeResizable` returns
    /// immediately when the flag is present, so the steady-state cost is one
    /// bit test per event-loop pass, and setting a flag SwiftUI is not
    /// clearing cannot ping-pong with it.
    ///
    /// Registered once per window and never removed: the observers must
    /// outlive both the SwiftUI view and each close, they hold the window
    /// weakly, and `resizeWatched` bounds them to one registration per
    /// window.
    @MainActor private static func keepResizable(_ window: NSWindow) {
        guard !resizeWatched.contains(window) else { return }
        resizeWatched.add(window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    makeResizable(window)
                }
            }
        }
    }

    /// Shared with the `WindowFrameAutosave` attached in `SettingsView`;
    /// the two must name the same key or the restore reads what nothing wrote.
    static let settingsFrameKey = GUIKitConfig.frameKey(for: "Settings")

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Resigns first responder as the window starts to close, so a field
    /// still being edited fires its focus-loss commit before SwiftUI tears
    /// the view down. Without this, typing a value and pressing ⌘W
    /// immediately discarded it — the same rule System Settings follows.
    @MainActor
    final class Coordinator: NSObject {
        private weak var observed: NSWindow?

        func observe(_ window: NSWindow?) {
            guard let window, observed !== window else { return }
            if let old = observed {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            }
            observed = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }

        @objc private func windowWillClose(_ note: Notification) {
            (note.object as? NSWindow)?.makeFirstResponder(nil)
        }

        // No deinit teardown: NotificationCenter keeps a zeroing weak
        // reference to a selector-based observer, and the coordinator
        // outlives the window it watches only until the view goes away.
    }
}

private final class WindowAttachView: NSView {
    private let onAttach: @MainActor (NSWindow) -> Void

    init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
        self.onAttach = onAttach
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach(window) }
    }
}
