import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// The two places a view reaches the menu bar directly: a second key
// equivalent for a command that must answer to two keystrokes, and the
// small dispatcher a placeholder button uses to fire a menu command it has
// no closure for.
//
// Second key equivalents
// ----------------------
//
// An NSMenuItem holds exactly one key equivalent and SwiftUI exposes no
// alternate-item API, so a command that must answer to two keystrokes needs a
// local event monitor. Exactly one alias lives here, and new ones should be
// resisted: a shortcut that is not printed next to its menu item is a shortcut
// nobody discovers.
//
//   Window ▸ Focus Shell — ⌃⌘3 (printed in the menu, the Shell's digit in
//   the ⌃⌘1–5 focus family and matching View ▸ Panes ▸ Shell at ⌥⌘3),
//   with ⌃` — the key the item used to carry — kept working here.
// ─────────────────────────────────────────────────────────────────────────────

/// ANSI grave/tilde key. Checked alongside the character so the alias works
/// on layouts where ⌃` produces a control character rather than a backtick.
private let graveKeyCode: UInt16 = 50

@MainActor
enum MenuKeyAliases {
    private static var monitor: Any?
    private static var focusShellAction: (() -> Void)?

    /// Installs the monitor once. Safe to call repeatedly.
    static func install(focusShell: @escaping () -> Void) {
        focusShellAction = focusShell
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let isGrave = event.keyCode == graveKeyCode
                || event.charactersIgnoringModifiers == "`"
            guard mods == .control, isGrave else { return event }
            // Local monitors are delivered on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Only in the canvas window: the Shell is a pane of the
                // main window, and ⌃` means nothing in Help or Settings —
                // so the keystroke is passed on there rather than eaten.
                guard MainWindowRegistry.keyWindowIsMainContent() else { return false }
                focusShellAction?()
                return true
            }
            return handled ? nil : event
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Firing a menu command from a view
//
// The canvas's empty state offers "Open an Example…" and "Start from an
// Archetype…", and the one implementation of each is a method on
// `QnetGUIApp` wired into File ▸ Open Example… and File ▸ New from
// Archetype…. The canvas is several containers below the scene and holds
// no closure to either, so the buttons perform the menu items themselves
// — the same NSMenuItem, the same target and action a click on the menu
// would send. One implementation, no second copy of the command, and no
// notification round-trip that would leave a button dead until the app
// happens to be listening.
//
// Titles are the address, so a renamed menu item makes the button a no-op
// rather than firing the wrong command. The buttons themselves are offered
// unconditionally — both items are permanently present in the File menu,
// and deciding a control's existence from AppKit menu state inside a
// SwiftUI `body` made the most prominent control on an empty canvas blink
// with unrelated re-renders. `canPerform` is a plain, side-effect-free
// read for anything that wants to ask; `perform` is what a button calls.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum MenuBarCommand {
    /// File ▸ Open Example… — titles exactly as `QnetCommands` spells them.
    static let openExample = ["File", "Open Example…"]

    /// File ▸ New from Archetype… — the archetype gallery, and the shortest
    /// route from a blank page to a network that runs. Same rule as
    /// `openExample`: the title is the address, so a rename here and in
    /// `QnetCommands` must happen in one edit.
    static let newFromArchetype = ["File", "New from Archetype…"]

    /// Is this command in the menu bar and enabled right now? Nil `NSApp`
    /// (the headless CLI modes) answers false, as does a renamed item.
    ///
    /// A plain read, with no side effect: it must never provoke AppKit's
    /// menu-validation pass, because a SwiftUI `body` is one of the
    /// callers and `NSMenu.update()` re-evaluates SwiftUI command state —
    /// a re-entrancy hazard, and a `body` that runs on every editor
    /// publish is the last place to pay for one. `isEnabled` is therefore
    /// only as fresh as AppKit's last validation; `perform` runs that pass
    /// itself, at the one moment a stale answer would matter.
    static func canPerform(_ path: [String]) -> Bool {
        guard let (menu, index) = locate(path) else { return false }
        return menu.items[index].isEnabled
    }

    /// Sends the item's action exactly as a click on it would, including
    /// the brief menu flash AppKit draws. Returns false — and does
    /// nothing — when the item is missing or disabled.
    ///
    /// `isEnabled` is only trustworthy after AppKit has run its validation
    /// pass over the owning menu, which normally happens when the user
    /// opens it. A button pressed before the user has ever opened the File
    /// menu — which is exactly what the empty canvas offers — would
    /// otherwise be refused on the state the item was *built* with, so a
    /// `false` is re-checked after `update()`, the documented way to force
    /// that pass. This is a click, not a render: the cost is paid once,
    /// off any `body`.
    @discardableResult
    static func perform(_ path: [String]) -> Bool {
        guard let (menu, index) = locate(path) else { return false }
        if !menu.items[index].isEnabled { menu.update() }
        guard menu.items[index].isEnabled else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// Walks `NSApp.mainMenu` by title, one level per path component:
    /// ["File", "Open Example…"] is the item titled "Open Example…" in the
    /// File menu. Returns the owning menu and the index in it, which is
    /// what `performActionForItem(at:)` takes.
    private static func locate(_ path: [String]) -> (menu: NSMenu, index: Int)? {
        guard !path.isEmpty, let app = NSApp, var menu = app.mainMenu else { return nil }
        for (depth, title) in path.enumerated() {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                return nil
            }
            if depth == path.count - 1 { return (menu, index) }
            guard let submenu = menu.items[index].submenu else { return nil }
            menu = submenu
        }
        return nil
    }
}
