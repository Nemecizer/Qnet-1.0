import AppKit
import UniformTypeIdentifiers

/// Save Status Log… — the one implementation behind the Status pane's
/// export menu and File ▸ Export ▸ Status Log…. Writes the entries in
/// their `formattedLine` form (`[hh:mm:ss] [WARNING] text`, the same text
/// Copy puts on the clipboard and the AI `read_status` tool sees) to a
/// `.txt` named after the network, and reports the destination in the log
/// itself the way the Shell's Copy reports what it copied.
@MainActor
enum StatusLogExport {
    /// Default file name: `<network>-status.txt`, from the document's
    /// file name without its `.bnet` extension, or `Untitled-status.txt`.
    static func defaultFileName(for editor: NetworkEditorModel) -> String {
        let base = editor.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(base)-status.txt"
    }

    /// Presents the save panel and writes `entries` (the visible entries
    /// when called from the pane, the whole log from the menu bar).
    static func save(editor: NetworkEditorModel, entries: [StatusEntry]? = nil) {
        let items = entries ?? editor.statusMessages
        guard !items.isEmpty else {
            editor.addStatus("Nothing to save — the status log is empty.", severity: .warning)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Status Log"
        panel.nameFieldLabel = "Save As:"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName(for: editor)
        if let dir = editor.currentFileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = items.map(\.formattedLine).joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let shown = (url.path as NSString).abbreviatingWithTildeInPath
            editor.addStatus(
                "Saved \(items.count) status entr\(items.count == 1 ? "y" : "ies") to \(shown).",
                severity: .success
            )
        } catch {
            editor.addStatus(
                "Could not save the status log: \(error.localizedDescription)",
                severity: .error
            )
        }
    }
}
