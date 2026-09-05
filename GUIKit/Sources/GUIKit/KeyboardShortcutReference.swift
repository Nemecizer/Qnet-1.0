import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Help ▸ Keyboard Shortcuts
//
// The one help topic that is not static text. It is generated from the live
// menu bar — `MenuShortcutAudit.run()` walks every NSMenuItem and reports its
// key equivalent — so the page can never disagree with what the menus print,
// the way a hand-written table eventually would. The output is plain ASCII in
// the same shape as the other `AlgorithmHelp` blobs (title, underlined
// headings, four-space-indented aligned tables), so `HelpMarkup` typesets it
// like every other topic and the Status / Shell destinations print it verbatim.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum KeyboardShortcutReference {

    // MARK: The keys tooltips cite

    /// The commands whose shortcut a tooltip, a status-bar segment or a
    /// help string mentions. A view never spells a key out: it asks
    /// `key(for:)`, so the menus can be rebound without leaving a tooltip
    /// behind (the toolbar's Zoom to Fit taught ⌘1 for a round after ⌘1
    /// had become "show tab 1"). The table is CHECKED, not trusted:
    /// `auditTable(against:)` compares every entry that names a menu path
    /// with the live menu bar and the debug-build audit reports drift.
    enum Command: CaseIterable {
        case newNetwork, closeTab, closeAllTabs, reopenClosedTab, save
        case zoomIn, zoomOut, actualSize, zoomToFit, zoomToSelection, snapToGrid
        case showToolsPane, showStatusPane, showShellPane, showAIPane, showInspectorPane, showResultsPane
        case showNextTab, showPreviousTab
        case focusCanvas, focusTools, focusStatus, focusShell, focusAIInput, focusInspector, focusResults
        case clearShell
        /// ⌃⌘↩ — View ▸ Panes ▸ Maximize Pane. The item's title flips to
        /// "Restore Pane Layout" while a pane is maximized, so like `.stop`
        /// and `.find` it carries no path to audit.
        case maximizePane
        /// ⌘. — Run ▸ Stop <run> while a solver runs, else the AI pane's
        /// Stop. The title is dynamic, so it carries no path to audit.
        case stop
        /// ⌘F — Find Node / Find in Shell / Search … (title follows focus).
        case find

        /// Modifier glyphs in the Mac order ⌃ ⌥ ⇧ ⌘, then the key.
        var key: String {
            switch self {
            case .newNetwork: return "⌘N"
            case .closeTab: return "⌘W"
            case .closeAllTabs: return "⌥⌘W"
            case .reopenClosedTab: return "⇧⌘T"
            case .save: return "⌘S"
            case .zoomIn: return "⌘="
            case .zoomOut: return "⌘−"
            case .actualSize: return "⌘0"
            case .zoomToFit: return "⇧⌘0"
            case .zoomToSelection: return "⌥⇧⌘0"
            case .snapToGrid: return "⌥⌘G"
            case .showToolsPane: return "⌥⌘1"
            case .showStatusPane: return "⌥⌘2"
            case .showShellPane: return "⌥⌘3"
            case .showAIPane: return "⌥⌘4"
            case .showInspectorPane: return "⌥⌘5"
            case .showResultsPane: return "⌥⌘6"
            case .showNextTab: return "⇧⌘]"
            case .showPreviousTab: return "⇧⌘["
            case .focusCanvas: return "⌃⌘0"
            case .focusTools: return "⌃⌘1"
            case .focusStatus: return "⌃⌘2"
            case .focusShell: return "⌃⌘3"
            case .focusAIInput: return "⌃⌘4"
            case .focusInspector: return "⌃⌘5"
            case .focusResults: return "⌃⌘6"
            case .clearShell: return "⌘K"
            case .maximizePane: return "⌃⌘↩"
            case .stop: return "⌘."
            case .find: return "⌘F"
            }
        }

        /// Where the menu bar prints this key, in `MenuShortcutAudit`'s
        /// path form; nil for the two commands whose title is dynamic.
        var menuPath: String? {
            switch self {
            case .newNetwork: return "File › New Network"
            case .closeTab: return "File › Close Tab"
            case .closeAllTabs: return "File › Close All Tabs"
            case .reopenClosedTab: return "Window › Reopen Closed Tab"
            case .save: return "File › Save"
            case .zoomIn: return "View › Zoom In"
            case .zoomOut: return "View › Zoom Out"
            case .actualSize: return "View › Actual Size"
            case .zoomToFit: return "View › Zoom to Fit"
            case .zoomToSelection: return "View › Zoom to Selection"
            case .snapToGrid: return "View › Snap to Grid"
            case .showToolsPane: return "View › Panes › Tools"
            case .showStatusPane: return "View › Panes › Status"
            case .showShellPane: return "View › Panes › Shell"
            case .showAIPane: return "View › Panes › AI Assistant"
            case .showInspectorPane: return "View › Panes › Inspector"
            case .showResultsPane: return "View › Panes › Results"
            case .showNextTab: return "Window › Show Next Tab"
            case .showPreviousTab: return "Window › Show Previous Tab"
            case .focusCanvas: return "Window › Focus Canvas"
            case .focusTools: return "Window › Focus Tools"
            case .focusStatus: return "Window › Focus Status"
            case .focusShell: return "Window › Focus Shell"
            case .focusAIInput: return "Window › Focus AI Input"
            case .focusInspector: return "Window › Focus Inspector"
            case .focusResults: return "Window › Focus Results"
            case .clearShell: return "Window › Shell › Clear Shell"
            case .stop, .find, .maximizePane: return nil
            }
        }
    }

    /// The key a tooltip should print for `command` — "⇧⌘0" for
    /// `.zoomToFit` — in the same glyph order the menu bar uses.
    static func key(for command: Command) -> String { command.key }

    /// Compares the table with the live menu bar: one line per entry whose
    /// menu item prints a different key (or is missing). Empty means the
    /// tooltips agree with the menus.
    static func auditTable(against entries: [MenuShortcutAudit.Entry]) -> [String] {
        var byPath: [String: String] = [:]
        for e in entries { byPath[e.path] = keyText(e) }
        var drift: [String] = []
        for command in Command.allCases {
            guard let path = command.menuPath else { continue }
            guard let live = byPath[path] else {
                drift.append("\(path): not in the menu bar (table says \(command.key))")
                continue
            }
            if live != command.key {
                drift.append("\(path): menu prints \(live), table says \(command.key)")
            }
        }
        return drift
    }

    /// Keys that exist but are not printed beside a menu item: the second
    /// key equivalents `MenuKeyAliases` and the tab key monitor install,
    /// and the canvas's own keyboard vocabulary. Hand-maintained because
    /// nothing in the menu bar knows about them.
    private static let unprintedKeys: [(String, String)] = [
        ("⌃`",        "Focus Shell (second key for Window ▸ Focus Shell)"),
        ("⌃⇥ / ⌃⇧⇥",  "Show Next / Previous Tab (second keys for Window ▸ Show Next / Previous Tab)"),
        ("Esc",       "Deselect all on the canvas; close a sheet, a popover or an auxiliary window"),
        ("Esc (mid-drag)",
                      "Put the drag back: the nodes return to where they started and no undo step is left behind"),
        ("⇥ / ⇧⇥",    "Walk the nodes in reading order, scrolling the target into view"),
        ("⌥⇥ / ⌥⇧⇥",  "Walk the links attached to the selected node"),
        ("← ↑ → ↓",   "Nudge the selection one grid cell (1 pt with Snap to Grid off); ⇧ = four cells (10 pt)"),
        ("← ↑ → ↓ (nothing selected)",
                      "Scroll the canvas one wheel line; ⇧ = four lines"),
        ("⇧- or ⌘-click", "Add a node to the selection or remove it"),
        ("⌥-drag",    "Duplicate the selection and move the copies, as one undo step"),
        ("⌃-drag",    "Place freely: suspends Snap to Grid and the alignment guides"),
        ("Space (held)", "Pan the canvas with any tool; the middle mouse button does the same"),
        ("Double-click", "Edit Parameters… for the node or link under the pointer"),
        ("Double-click (empty canvas)",
                      "Sticky pan: the hand takes the canvas over; one click anywhere restores the previous tool"),
        ("Drag node → node", "Link tool: draws the link, with a dashed preview following the pointer"),
        ("Drag out and back", "Link tool: a self-loop on the station the drag started from"),
    ]

    /// Modifier order on the Mac is ⌃ ⌥ ⇧ ⌘; the audit already emits it
    /// that way. Only the readability substitutions live here.
    private static func keyText(_ entry: MenuShortcutAudit.Entry) -> String {
        var key = MenuShortcutAudit.Entry.keyName(entry.key)
        switch key {
        case "-": key = "−"
        case "=": key = "="
        default: break
        }
        return MenuShortcutAudit.Entry.glyphs(entry.modifiers) + key
    }

    /// "File › Export › All Solver Inputs to Folder…" → "Export ▸ All
    /// Solver Inputs to Folder…": the top-level menu becomes the section
    /// heading, submenus keep a ▸ between their levels.
    private static func commandText(_ path: String) -> String {
        let parts = path.components(separatedBy: " › ")
        return parts.dropFirst().joined(separator: " ▸ ")
    }

    private static func topLevel(_ path: String) -> String {
        path.components(separatedBy: " › ").first ?? path
    }

    /// The whole page. Cheap — a walk of about a hundred menu items — so
    /// it is rebuilt on every read rather than cached, which is what lets
    /// the Run pairs (whose shortcut follows the buffer mode) and "Stop
    /// <run>" print what the menu bar prints right now.
    static func text() -> String {
        let entries = MenuShortcutAudit.run().entries

        // Group by top-level menu, preserving the bar's own order.
        var order: [String] = []
        var groups: [String: [MenuShortcutAudit.Entry]] = [:]
        for e in entries {
            let menu = topLevel(e.path)
            if groups[menu] == nil { order.append(menu) }
            groups[menu, default: []].append(e)
        }

        var out: [String] = []
        out.append("KEYBOARD SHORTCUTS")
        out.append("==================")
        out.append("")
        out.append("Every key equivalent in the menu bar, read from the live menus as")
        out.append("this page is opened — so it always matches what the menus show.")
        out.append("A key that appears here only once belongs to the item that is")
        out.append("enabled for the current network: the Run pairs share their key")
        out.append("between the infinite- and finite-buffer variants.")
        out.append("")
        out.append("CONVENTIONS")
        out.append("-----------")
        out.append("  • ⌥⌘ + letter runs a method (Run menu): ⌥⌘M Monte Carlo, ⌥⌘S")
        out.append("    Spectral Method, ⌥⌘Q QNA, ⌥⌘B SBD, ⌥⌘E SRBM MLMC, ⌥⌘F")
        out.append("    Finite Element, ⌥⌘L Linear Program. ⌘R runs the comparison and")
        out.append("    ⌘. stops whatever is running.")
        out.append("  • ⌘ + digit shows that document tab (⌘1–⌘9, in tab-bar order);")
        out.append("    ⌥⌘ + digit shows or hides a pane; ⌃⌘ + digit moves keyboard")
        out.append("    focus into that pane. The digits agree — 1 Tools, 2 Status,")
        out.append("    3 Shell, 4 AI Assistant, 5 Inspector, 6 Results — and ⌃⌘0 focuses the")
        out.append("    canvas, which has no pane to show or hide.")
        out.append("  • ⌘W closes the front tab (asking to save first) and ⇧⌘T reopens")
        out.append("    the last tab closed this session.")
        out.append("  • Bare letters (V M H · S B O X · L) pick a canvas tool, matching")
        out.append("    the badges in the Tools pane. They never fire inside a text")
        out.append("    field, the Shell, a sheet or an auxiliary window.")
        out.append("  • ⌘= / ⌘− zoom whatever has focus — the canvas, or the text of the")
        out.append("    Status, Shell or AI Assistant pane. ⌘0 is actual size, ⇧⌘0 fits")
        out.append("    the network and ⌥⇧⌘0 fits the selection (the Keynote keys).")
        out.append("  • ⌘F finds in whatever is in front: a node, the Shell scrollback,")
        out.append("    the Status log, the AI transcript, Help or Settings.")
        out.append("")

        let keyWidth = max(10, (entries.map { keyText($0).count }.max() ?? 8) + 2)

        if entries.isEmpty {
            // Headless (`Qnet --dump-help keyboardShortcuts`): there is no
            // menu bar to read. Say so rather than print an empty page.
            out.append("MENU BAR")
            out.append("--------")
            out.append("The menu bar is not available in this context, so the per-menu")
            out.append("tables are omitted. Open Help ▸ Keyboard Shortcuts in the app.")
            out.append("")
        }

        for menu in order {
            guard let items = groups[menu] else { continue }
            let heading = menu.uppercased()
            out.append(heading)
            out.append(String(repeating: "-", count: heading.count))
            for e in items {
                let key = keyText(e).padding(toLength: keyWidth, withPad: " ", startingAt: 0)
                out.append("    " + key + commandText(e.path))
            }
            out.append("")
        }

        out.append("KEYS NOT PRINTED IN A MENU")
        out.append("--------------------------")
        let aliasWidth = max(keyWidth, (unprintedKeys.map { $0.0.count }.max() ?? 8) + 2)
        for (key, what) in unprintedKeys {
            out.append("    " + key.padding(toLength: aliasWidth, withPad: " ", startingAt: 0) + what)
        }
        out.append("")
        out.append("CHECKING THE MAP")
        out.append("----------------")
        out.append("Launch with \(GUIKitConfig.menuAuditEnvironmentKey)=1 in the environment to print this")
        out.append("map to standard error and exit non-zero if two items share a key.")
        out.append("A debug build runs the same check shortly after launch.")
        out.append("")
        return out.joined(separator: "\n")
    }
}
