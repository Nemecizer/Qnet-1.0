import SwiftUI
import AppKit

// Extracted from the host app's ContentView.swift — window frame persistence
// that survives relaunch AND clamps a restored frame to the screens that
// actually exist now, so a window saved on a disconnected display cannot come
// back somewhere unreachable.

private final class ObserverTokens {
    private var tokens: [NSObjectProtocol] = []

    func keep(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

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
