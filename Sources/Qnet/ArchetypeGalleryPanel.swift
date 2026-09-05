import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The archetype gallery, as a movable panel
// ─────────────────────────────────────────────────────────────────────────────
//
// `ArchetypeGallerySheet` is a browse-and-tune form: the user picks one of
// five starting networks on the left, sets its size and load on the right,
// and reads a one-line preview of what Insert will produce — all of it
// about the canvas the dialog is sitting on top of. On an occupied canvas
// the form's own footer promises the archetype lands "clear to the right of
// what is already there", which is a promise the user cannot check while a
// sheet covers the canvas.
//
// So it is presented in a `DSPanelWindow` instead: draggable, resizable
// inside the `.wide` band the form already declares, and remembered where
// it was left. This file is the presenter — the same shape as
// `CanvasExportOptionsPresenter`, and the same reason for existing: the
// commands that open the gallery live in the menu bar, outside any SwiftUI
// presentation context, and a window needs no presentation context.
//
// The insert itself is deliberately NOT here. It is one closure — build the
// archetype, hand it to `NetworkEditorModel.insertSubnetwork` — and it stays
// with the scene that owns the active editor (`QnetGUIApp`), so this file
// cannot drift away from it.
// ─────────────────────────────────────────────────────────────────────────────

/// Presents the archetype gallery as a movable panel. See the file header.
@MainActor
enum ArchetypeGalleryPanel {
    /// Panel id, and therefore the window identifier suffix and the
    /// frame-autosave key (`QnetPanel.archetype-gallery`).
    static let panelID = "archetype-gallery"

    /// Title bar text. Kept verbatim equal to the form's own
    /// `DSSheetHeader` title in `ArchetypeGallerySheet`, so the window is
    /// not named one thing and headed another; change the two together.
    static let windowTitle = "Insert Archetype"

    /// Take the panel away from the outside. `DSPanelWindow.close(id:)`
    /// does not run the `onClose` handed to `present` — the caller is the
    /// one removing the panel, so it already knows — which is why a caller
    /// mirroring the panel into a `@State` flag clears the flag itself on
    /// this path.
    static func close() { DSPanelWindow.close(id: panelID) }

    /// Mirror a `@State` Bool onto the panel: the flag stays the single
    /// switch every menu item and shortcut writes, and this is only the
    /// presentation. Call it from `.onChange(of: theFlag)`.
    ///
    /// - Parameter onDismiss: clears the caller's flag. It runs when the
    ///   panel goes away on its own — Cancel, Insert, the title-bar button,
    ///   ⌘W, Escape, Quit — because that is the one path all of those take.
    static func sync(presented: Bool,
                     canvasNodeCount: @autoclosure () -> Int,
                     canvasSourceCount: @autoclosure () -> Int,
                     initialInfiniteBuffers: @autoclosure () -> Bool,
                     onInsert: @escaping (NetworkArchetype, ArchetypeParameters) -> Void,
                     onDismiss: @escaping () -> Void) {
        guard presented else {
            close()
            return
        }
        present(canvasNodeCount: canvasNodeCount(),
                canvasSourceCount: canvasSourceCount(),
                initialInfiniteBuffers: initialInfiniteBuffers(),
                onInsert: onInsert,
                onClose: onDismiss)
    }

    /// - Parameter initialInfiniteBuffers: the regime the DOCUMENT is in. The
    ///   form's Buffers control opens on it, because an insert never
    ///   re-interprets the stations already on the canvas — only an empty
    ///   canvas adopts the choice made here. Read once, when the panel opens:
    ///   a panel left standing across a Network ▸ Buffer Model change would
    ///   otherwise be showing a stale regime, and the model, not the form,
    ///   is what decides.
    static func present(canvasNodeCount: Int,
                        canvasSourceCount: Int,
                        initialInfiniteBuffers: Bool,
                        onInsert: @escaping (NetworkArchetype, ArchetypeParameters) -> Void,
                        onClose: @escaping () -> Void) {
        DSPanelWindow.present(
            id: panelID,
            title: windowTitle,
            size: .wide,
            // Document-modal, which is what the sheet this replaces already
            // was: the gallery belongs to the canvas window it will insert
            // into, travels with it, and stays above it — a sheet's
            // ordering without a sheet's immobility. It also keeps the bare
            // canvas tool letters from firing underneath a form full of
            // Steppers and number fields.
            modality: .documentModal,
            // `DSSheetFooter` already binds Cancel to Escape; a second
            // cancel action in the same window is one too many.
            escapeCloses: false,
            onClose: onClose
        ) { ref in
            ArchetypeGallerySheet(
                canvasNodeCount: canvasNodeCount,
                canvasSourceCount: canvasSourceCount,
                initialInfiniteBuffers: initialInfiniteBuffers,
                onCancel: { ref.close() },
                onInsert: { archetype, parameters in
                    // Order the panel out before the insert runs: the
                    // insert moves the canvas selection and posts an undo
                    // entry, and the user should be looking at the network
                    // when that happens, not at the form that asked for it.
                    ref.close()
                    onInsert(archetype, parameters)
                })
        }
    }
}
