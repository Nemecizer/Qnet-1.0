import SwiftUI
import Foundation

/// Writes a snapshot of every open tab's editor state (node positions,
/// links, canvas zoom, infinite-buffer toggle, associated user file URL)
/// into UserDefaults, debounced, so that the next launch can recreate
/// exactly what the user was last looking at.
///
/// Two entry points:
///   * `scheduleSave(tabs:activeID:)`  — debounced; call from `.onChange`
///                                      handlers in the view layer.
///   * `saveImmediately(tabs:activeID:)` — synchronous; call right before
///                                      the app quits so no pending
///                                      debounced write is lost.
///
/// Static helpers `restore()` / `clearPersistence()` read / delete the
/// snapshot blob from UserDefaults.
@MainActor
final class TabPersistence: ObservableObject {
    static let storageKey = "tabs.persistedState"
    static let debounceMS: UInt64 = 400

    private var saveTask: Task<Void, Never>?

    /// Debounce saves during rapid activity (e.g. dragging a node) so we
    /// only touch UserDefaults once every few hundred milliseconds.
    func scheduleSave(tabs: [NetworkTab], activeID: UUID?) {
        let snapshot = Self.snapshot(tabs: tabs, activeID: activeID)
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceMS * 1_000_000)
            guard !Task.isCancelled else { return }
            Self.writeSnapshot(snapshot)
        }
    }

    /// Flush the current tab state to UserDefaults without waiting for the
    /// debounce window to elapse.  Used at app termination.
    func saveImmediately(tabs: [NetworkTab], activeID: UUID?) {
        saveTask?.cancel()
        Self.writeSnapshot(Self.snapshot(tabs: tabs, activeID: activeID))
    }

    /// Cancel any pending debounced save so it can't fire after a
    /// `clearPersistence()` and resurrect the state.
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// Remove the saved state entirely.  Called when the user answered
    /// "don't restore" to the quit-time dialog.
    static func clearPersistence() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Read and decode the saved state, or nil if there is none / it is
    /// corrupt.  Silent on failure — the app simply falls back to a fresh
    /// empty tab.
    static func restore() -> PersistedTabState? {
        guard
            let str  = UserDefaults.standard.string(forKey: storageKey),
            let data = str.data(using: .utf8),
            let state = try? JSONDecoder().decode(PersistedTabState.self, from: data)
        else {
            return nil
        }
        return state
    }

    // MARK: - Internals

    private static func snapshot(tabs: [NetworkTab], activeID: UUID?) -> PersistedTabState {
        let entries = tabs.map { tab -> PersistedTabState.Entry in
            PersistedTabState.Entry(
                id: tab.id,
                title: tab.title,
                document: NetworkDocument(
                    nodes: tab.editor.nodes,
                    links: tab.editor.links,
                    infiniteBuffers: tab.editor.infiniteBuffers,
                    canvasScale: tab.editor.canvasScale,
                    canvasPanOffset: tab.editor.canvasPanOffset
                ),
                userFileURL: tab.editor.currentFileURL?.absoluteString,
                // Persist Status pane scrollback so each tab reopens
                // with the activity log it had before quit.
                statusLog: tab.editor.statusMessages
            )
        }
        return PersistedTabState(entries: entries, activeTabID: activeID)
    }

    private static func writeSnapshot(_ snapshot: PersistedTabState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // .prettyPrinted is too verbose in UserDefaults
        guard
            let data = try? encoder.encode(snapshot),
            let str  = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(str, forKey: storageKey)
    }
}

/// Invisible SwiftUI view that fires `onChange` whenever an editor's
/// observable state changes.  One of these is placed in the App body per
/// tab so that every tab's edits trigger a debounced save, not just the
/// currently active one.
struct TabPersistenceObserver: View {
    @ObservedObject var editor: NetworkEditorModel
    let onChange: () -> Void

    var body: some View {
        // SwiftUI uses Equatable conformance to decide whether onChange
        // should fire — NetworkNode and NetworkLink are Hashable (hence
        // Equatable) so array mutations (including per-element position
        // updates during a drag) reliably produce change events.
        // We also watch statusMessages.count so a session that prints
        // status without touching nodes (e.g. running an algorithm)
        // still produces persisted writes — important if the app
        // crashes before the user gets to the quit-time save.
        Color.clear
            .frame(width: DS.Layout.hiddenProbeSize, height: DS.Layout.hiddenProbeSize)
            .onChange(of: editor.nodes)                 { _, _ in onChange() }
            .onChange(of: editor.links)                 { _, _ in onChange() }
            .onChange(of: editor.canvasScale)           { _, _ in onChange() }
            .onChange(of: editor.canvasPanOffset)       { _, _ in onChange() }
            .onChange(of: editor.infiniteBuffers)       { _, _ in onChange() }
            .onChange(of: editor.currentFileURL)        { _, _ in onChange() }
            .onChange(of: editor.statusMessages.count)  { _, _ in onChange() }
    }
}
