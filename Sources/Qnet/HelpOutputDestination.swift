import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Where a Help-menu topic goes. This file used to also carry `HelpTextView`
// and `HelpTextWindow` — a second, free-text help window with its own chrome
// (760 × 620 against the Help window's 1040 × 704), its own reading frame and
// no search. It was unreachable: `QnetGUIApp.showHelp(topic:)` sent every
// `.popup` topic to `QnetHelpWindow` before the free-text path could see it,
// so its `.popup` branch never executed. One typeset viewer for one document
// is the rule, and `QnetHelpWindow` is that viewer, so the window and its view
// are gone and only the destination enum — which the Settings picker binds to —
// remains.
// ─────────────────────────────────────────────────────────────────────────────

/// Where the Help → * menu sends the text of a selected help topic.
/// Controlled by the user via Settings ▸ Help menu.
enum HelpOutputDestination: Int, CaseIterable, Identifiable {
    case statusWindow     = 0
    case interactiveShell = 1
    case popup            = 2

    var id: Int { rawValue }

    /// Names match the pane titles ("Status", "Shell"); the two plain-text
    /// destinations say so, since they print the topic as ASCII rather
    /// than typesetting it.
    var displayName: String {
        switch self {
        case .statusWindow:     return "Status pane (plain text)"
        case .interactiveShell: return "Shell pane (plain text)"
        case .popup:            return "Qnet Help window"
        }
    }
}
