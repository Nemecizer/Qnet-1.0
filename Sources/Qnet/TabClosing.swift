import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// Closing document tabs.
//
// There is ONE owner of "close these tabs": `QnetGUIApp.closeTabs(ids:)`,
// which guards every close with the Save / Don't Save / Cancel question
// (`confirmClose`), remembers what it closed for Window ▸ Reopen Closed
// Tab, and only then edits the `tabs` array. The five entry points — the
// tab's close button, a middle-click on the tab, the tab context menu's
// three items, File ▸ Close Tab (⌘W) and File ▸ Close All Tabs (⌥⌘W) —
// all reach it through `TabActions`, so none of them can drop unsaved work
// on the floor the way the tab bar's private copies once did.
//
// What lives here is the part that does not need the App's private
// members: the closure bundle the tab bar receives, the review loop over
// dirty tabs, the closed-tab stack behind Reopen Closed Tab, and the
// document writer both Save paths share.
// ─────────────────────────────────────────────────────────────────────────────

/// The closure bundle `ContentView` and its tab bar receive. `close`
/// takes a SET so "Close Other Tabs" and "Close Tabs to the Right" are one
/// call each, reviewed dirty tab by dirty tab the way Xcode does.
struct TabActions {
    var close: (Set<UUID>) -> Void

    /// For previews and headless paths where nothing owns the tabs.
    static var inert: TabActions { TabActions(close: { _ in }) }
}

/// The review loop: every dirty tab in `tabs`, in tab-bar order, asks
/// Save / Don't Save / Cancel. Save runs the caller's `save` (Save As…
/// for an untitled network) and a cancelled Save panel cancels the whole
/// close; Cancel anywhere cancels the whole close; Don't Save moves on.
/// Returns true when the close may proceed.
enum TabClosing {
    @MainActor
    static func confirmClose(_ tabs: [NetworkTab], save: (NetworkTab) -> Bool) -> Bool {
        for tab in tabs where tab.editor.hasUnsavedChanges {
            switch ConfirmAlert.saveChanges(documentTitle: tab.title,
                                            hasFile: tab.editor.currentFileURL != nil) {
            case .save:
                if !save(tab) { return false }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }
}

// MARK: - Writing a .bnet

/// The one encoder for a `.bnet` on disk, shared by File ▸ Save, Save As…
/// and the Save button of the close guard, so a tab saved on its way out
/// is byte-for-byte what ⌘S would have written.
enum TabDocumentWriter {
    /// Encodes the editor's document and writes it atomically, then marks
    /// the editor clean and points it at `url`. Throws on either failure;
    /// the caller reports it (the editor is left as it was).
    @MainActor
    static func write(editor: NetworkEditorModel, to url: URL) throws {
        let document = NetworkDocument(
            nodes: editor.nodes, links: editor.links,
            infiniteBuffers: editor.infiniteBuffers, canvasScale: editor.canvasScale
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        editor.currentFileURL = url
        editor.markDocumentClean()
        editor.addStatus("Saved network to \(url.lastPathComponent).", severity: .success)
    }

    /// The Save panel every Save As… path shows: `.bnet` only, a name
    /// derived from the tab, the document's own folder when it has one.
    /// Nil when the user cancelled.
    @MainActor
    static func runSavePanel(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Network As"
        panel.nameFieldStringValue = suggestedName.hasSuffix(".bnet") ? suggestedName : suggestedName + ".bnet"
        panel.allowedContentTypes = [UTType(filenameExtension: "bnet") ?? .json]
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Reopen Closed Tab

/// Everything needed to bring a closed tab back: the document, the file it
/// came from, its status log and whether it matched that file when it
/// closed (a tab closed with Don't Save comes back dirty, as it should).
struct ClosedTab {
    let title: String
    let document: NetworkDocument
    let fileURL: URL?
    let statusLog: [StatusEntry]
    let wasClean: Bool
    let closedAt: Date

    @MainActor
    init(tab: NetworkTab) {
        let editor = tab.editor
        title = tab.title
        document = NetworkDocument(
            nodes: editor.nodes, links: editor.links,
            infiniteBuffers: editor.infiniteBuffers,
            canvasScale: editor.canvasScale, canvasPanOffset: editor.canvasPanOffset
        )
        fileURL = editor.currentFileURL
        statusLog = editor.statusMessages
        wasClean = !editor.hasUnsavedChanges
        closedAt = Date()
    }

    /// A blank untitled tab is not worth a slot on the stack.
    var isWorthKeeping: Bool {
        fileURL != nil || !document.nodes.isEmpty || !document.links.isEmpty
    }

    /// Rebuilds the tab, log and all, and notes the reopen in its log.
    @MainActor
    func makeTab() -> NetworkTab {
        let tab = NetworkTab(title: title)
        tab.editor.loadNetwork(document: document)
        tab.editor.currentFileURL = fileURL
        if !statusLog.isEmpty { tab.editor.statusMessages = statusLog }
        if wasClean { tab.editor.markDocumentClean() }
        tab.editor.addStatus("Reopened \(title)\(wasClean ? "" : " with its unsaved changes").")
        return tab
    }
}

/// The stack behind Window ▸ Reopen Closed Tab (⇧⌘T): the last few closed
/// tabs, newest on top, kept for the session only — a tab reopened after a
/// relaunch is what Restore Tabs and File ▸ Open Recent are for.
@MainActor
final class ClosedTabHistory: ObservableObject {
    static let capacity = 10

    @Published private(set) var stack: [ClosedTab] = []

    var canReopen: Bool { !stack.isEmpty }

    /// Title of the tab ⇧⌘T would bring back, for the menu item's tooltip.
    var mostRecentTitle: String? { stack.last?.title }

    /// Pushes the tab if there is anything to bring back.
    func remember(_ tab: NetworkTab) {
        let closed = ClosedTab(tab: tab)
        guard closed.isWorthKeeping else { return }
        stack.append(closed)
        if stack.count > Self.capacity { stack.removeFirst(stack.count - Self.capacity) }
    }

    /// Pops the most recently closed tab.
    func pop() -> ClosedTab? {
        stack.popLast()
    }
}
