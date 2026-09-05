import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Movable dialog panels
// ─────────────────────────────────────────────────────────────────────────────
//
// A macOS sheet is pinned to the middle of the window it belongs to. That
// is right for "do you want to save?" and wrong for every form in Qnet,
// because every one of them asks the user about something the sheet is
// sitting on top of: which background to export the *diagram* on, which
// service rate to give the *station* behind it, how many replications to
// run against the *network* it hides.
//
// `DSPanelWindow` hosts a form in a real window instead: draggable by its
// title bar, resizable inside the band its `DSSheetSize` already declares,
// remembered where the user left it, and — unlike a sheet — able to stay
// open while the canvas is scrolled and the shell scrollback is read.
//
//     DSPanelWindow.present(id: "canvas-export",
//                           title: format.title,
//                           size: .compact,
//                           escapeCloses: false) { _ in
//         CanvasExportOptionsSheet(…)
//     }
//
// There is ONE of these, not one host per form. The body it presents is
// the same `DSSheet` a sheet presentation would show — the only thing that
// changes is how the body dismisses itself, and `\.qnetDismiss` below hides
// that difference so a form does not have to know which host it is in.
//
// It is built on `AuxiliaryWindow.make`, so a panel inherits the whole
// auxiliary-window contract for free: the `qnet.aux.` identifier ⌘W keys
// off, no window tabbing, a Window-menu entry, a `WindowRef` whose Close
// acts on ITS window, and the frame autosaver.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Dismissal that works in either host

/// How a form closes itself, whichever host it is in.
///
/// A `DSSheet` body has to work in two places: inside a real `.sheet(…)`,
/// where SwiftUI's `\.dismiss` is the correct thing to call, and inside a
/// `DSPanelWindow`, where the correct thing is to close *that* window —
/// `\.dismiss` there either does nothing or, worse, dismisses whatever
/// presentation happens to be above it. The body cannot tell the two
/// apart, so the host declares it: `DSPanelWindow` puts its window's close
/// in the environment, and `DSSheet` fills in SwiftUI's `dismiss` when
/// nobody above it has claimed the slot.
///
/// A form with explicit `onCancel` / `onConfirm` closures (most of them)
/// does not need this; it is for a body that has to dismiss itself from
/// somewhere other than its footer.
struct QnetDismissAction {
    /// False for the inert default — the marker `DSSheet` looks at before
    /// substituting `\.dismiss`.
    let isClaimed: Bool
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.isClaimed = true
        self.perform = perform
    }

    private init() {
        self.isClaimed = false
        self.perform = {}
    }

    /// Nothing above this view has claimed the dismissal yet.
    static let unclaimed = QnetDismissAction()

    @MainActor func callAsFunction() { perform() }
}

private struct QnetDismissKey: EnvironmentKey {
    static let defaultValue = QnetDismissAction.unclaimed
}

extension EnvironmentValues {
    /// Dismiss this form — closing the hosting panel window, or dismissing
    /// the sheet, whichever it turns out to be. See `QnetDismissAction`.
    var qnetDismiss: QnetDismissAction {
        get { self[QnetDismissKey.self] }
        set { self[QnetDismissKey.self] = newValue }
    }
}

/// Substitutes SwiftUI's `dismiss` into `\.qnetDismiss` when no host has
/// claimed it — i.e. when this body really is being shown as a sheet.
/// Applied once, by `DSSheet`, so no form has to remember to do it.
private struct QnetDismissBridge<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qnetDismiss) private var claimed
    let content: Content

    var body: some View {
        if claimed.isClaimed {
            content
        } else {
            content.environment(\.qnetDismiss, QnetDismissAction { dismiss() })
        }
    }
}

extension View {
    /// See `QnetDismissBridge`. `DSSheet` applies this; nothing else needs to.
    func qnetDismissBridge() -> some View {
        QnetDismissBridge(content: self)
    }
}

// MARK: - Modality

/// How much of the app a panel leaves live behind it.
///
/// None of these runs an `NSApp.runModal` session. A modal run loop
/// started from inside a SwiftUI action nests a second event loop under
/// the terminal's PTY reads, which is a deadlock waiting for a slow
/// solver; "modal" here means ordering plus explicitly disabled commands,
/// which is what the user actually perceives.
enum DSPanelModality {
    /// Free-floating. Every menu command stays live, and the panel can be
    /// left open while the user works. The right answer for a form the
    /// user opened *in order to* look at the thing behind it.
    case modeless
    /// Ordered above — and moved with — the window that opened it, as an
    /// AppKit child window, and marks `MenuContext.modalPanelPresented` so
    /// commands that would present a second dialog disable themselves.
    /// Movable and resizable, which a `beginSheet` sheet is not.
    case documentModal
    /// Floats above every Qnet window, and marks
    /// `MenuContext.modalPanelPresented`. For a panel that must not be
    /// lost behind the canvas — not for one the user wants to set aside.
    case appModal

    /// Whether the menu bar should treat this panel as a modal dialog.
    var blocksCommands: Bool { self != .modeless }
}

// MARK: - Refusing a close

/// Lets a form take over its panel's own close paths.
///
/// A sheet has exactly two ways out and the form owns both of them: its
/// footer's Cancel and Escape. A window has three more that the form does
/// not — the title-bar close button, ⌘W, and Quit — and for the node and
/// link parameter editors those are the paths that would throw away a
/// half-typed draft without asking. Every other exit from those forms
/// routes through one three-way Save / Don't Save / Cancel prompt; this is
/// how the window's own exits join it.
///
/// The caller makes one of these, hands it to `present(closeGuard:)` and to
/// the body it presents; the body fills in `allowsClose` once it is on
/// screen. Returning `false` refuses THIS close and makes the form
/// responsible for finishing the job (typically: put the prompt up, and
/// close the panel from its answer).
///
/// `DSPanelWindow.close(id:)` is not refusable and never consults this —
/// there the caller is taking the panel away deliberately, and a form
/// cannot veto its own document being closed.
@MainActor
final class DSPanelCloseGuard {
    /// Return `false` to refuse the close. `nil` (the default) allows it.
    var allowsClose: (() -> Bool)?
    init() {}
}

/// `NSWindowDelegate` that asks a `DSPanelCloseGuard`. One per panel, kept
/// alive by the panel registry because `NSWindow.delegate` is weak.
@MainActor
private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
    let guardBox: DSPanelCloseGuard
    init(guardBox: DSPanelCloseGuard) { self.guardBox = guardBox }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { guardBox.allowsClose?() ?? true }
    }
}

// MARK: - The host

/// The one movable-dialog host. See the file header.
@MainActor
enum DSPanelWindow {
    private struct Panel {
        let window: NSWindow
        let modality: DSPanelModality
        /// Retained here because `NSWindow.delegate` is weak. Nil for a
        /// panel presented without a `closeGuard`.
        let delegate: PanelWindowDelegate?
        /// Distinguishes one *presentation* of a panel from the next one
        /// under the same id. `NSWindow.willCloseNotification` is delivered
        /// on the main queue, i.e. a run-loop tick after the window has
        /// actually gone, so a close-and-re-present in a single turn (the
        /// Export panel changing from PDF rows to PNG rows) would otherwise
        /// have the *old* window's late teardown evict the *new* window
        /// from the registry.
        let token: UUID
    }

    /// Open panels by id, so asking for a panel that is already up brings
    /// it forward instead of stacking a second copy of the same form —
    /// two windows editing one set of `@AppStorage` keys is a data race the
    /// user can see.
    private static var panels: [String: Panel] = [:]

    /// `WindowFrameAutosave` name for a panel. Namespaced so a panel id can
    /// never collide with the main window's or an auxiliary window's key.
    static func frameKey(for id: String) -> String { "QnetPanel.\(id)" }

    static func isOpen(id: String) -> Bool { panels[id] != nil }

    /// Bring an already-open panel forward WITHOUT rebuilding its root, and
    /// report whether there was one. For a caller that re-presents the same
    /// form as its target changes: the root is built once and observes the
    /// document, so a second request is a raise, not a rebuild — rebuilding
    /// would throw away a half-typed draft.
    @discardableResult
    static func bringForward(id: String) -> Bool {
        guard let panel = panels[id] else { return false }
        AuxiliaryWindow.present(panel.window)
        return true
    }

    /// Close a panel from outside it (the command that opened it going
    /// away, a document closing, the same form being re-presented with a
    /// different shape). No-op when it is not open.
    ///
    /// The registry entry is dropped synchronously, so `close(id:)` may be
    /// followed immediately by `present(id:)` for the same id — the closing
    /// panel's `willClose` arrives a tick later, by which time the id
    /// belongs to the new presentation, and the token check in `finish`
    /// discards it. That is also why the closed panel's `onClose` does not
    /// run: the caller is the one taking the panel away, so it already
    /// knows, and firing it would clear the very state the replacement
    /// presentation depends on. The window has no delegate, so
    /// `performClose` cannot be refused.
    static func close(id: String) {
        guard let panel = panels[id] else { return }
        panels[id] = nil
        syncMenuFlag()
        // Not refusable, in both the ways a close can be refused. Dropping
        // the delegate disposes of the form's own close guard — the caller
        // is taking the panel away, so the form has no say — and `close()`
        // rather than `performClose(nil)` disposes of AppKit's: a window
        // with a sheet attached IGNORES `performClose`, and the moment this
        // is most often called is exactly such a moment. The node editor's
        // "Save changes before closing?" prompt is a SwiftUI
        // `confirmationDialog`, i.e. an alert sheet on this window, and
        // answering it clears the document target, which brings us here
        // while that sheet is still dismissing. `performClose` there is a
        // silent no-op and leaves a panel on screen that the registry has
        // already forgotten. `close()` is not conditional on any of that.
        panel.window.delegate = nil
        panel.window.parent?.removeChildWindow(panel.window)
        panel.window.close()
    }

    /// Move an open panel onto a different `DSSheetSize` band, because the
    /// form inside it changed shape — the node parameter panel retargeted
    /// from a sink to a station, whose per-class table needs a wider window
    /// than a sink's two fields do.
    ///
    /// The hosted root is deliberately left alone: rebuilding it would be a
    /// half-typed draft thrown away, and the root already follows the new
    /// band on its own through `dsSheetFrame`. Only the window's own limits
    /// move, and its frame only when the new band no longer contains it, so
    /// a size the user chose is kept wherever it still fits.
    ///
    /// No-op when no panel is open under `id`.
    static func reband(id: String, to size: DSSheetSize) {
        guard let panel = panels[id] else { return }
        let window = panel.window
        window.contentMinSize = NSSize(width: size.minWidth, height: size.minHeight)
        window.contentMaxSize = NSSize(width: size.maxWidth, height: size.maxHeight)
        let current = window.contentRect(forFrameRect: window.frame).size
        let clamped = NSSize(
            width: min(max(current.width, size.minWidth), size.maxWidth),
            height: min(max(current.height, size.minHeight), size.maxHeight))
        if clamped != current { window.setContentSize(clamped) }
    }

    /// Present `root` in a movable, resizable panel window.
    ///
    /// - Parameters:
    ///   - id: Identity of the *form*, not of this presentation. Presenting
    ///     the same id twice brings the open panel forward; it is also the
    ///     window identifier suffix and the frame-autosave key.
    ///   - size: The `DSSheetSize` band the form is already written
    ///     against. The panel opens at its ideal size and resizes between
    ///     its min and max — no panel invents its own geometry.
    ///   - idealHeight: Opening height, when the form's body overrides the
    ///     band's own — a `DSSheetSize.height(forRows:)` value, the same
    ///     one the body hands `dsSheetFrame`, so a panel opens as tall as
    ///     the sheet it replaces did. Still inside the band; ignored once
    ///     the user has a remembered frame.
    ///   - escapeCloses: Leave `false` for a `DSSheet` body: its
    ///     `DSSheetFooter` already binds Cancel to Escape, and two cancel
    ///     actions in one window is one too many. `true` for a body with no
    ///     footer of its own.
    ///   - closeGuard: Lets the hosted form refuse the window's OWN close
    ///     paths — the title-bar button, ⌘W, Quit — so a form with an
    ///     unsaved draft can ask first. See `DSPanelCloseGuard`.
    ///   - onClose: Runs when the panel goes away on its own — the footer's
    ///     Cancel, the title-bar close button, ⌘W, Escape, Quit. A form
    ///     whose caller is waiting on an answer must treat this as
    ///     "cancelled", and a caller mirroring the panel into a `@State`
    ///     flag clears the flag here, because this is the ONE path every
    ///     one of those closes goes through. It does NOT run when the
    ///     caller itself takes the panel away with `close(id:)` — see there.
    @discardableResult
    static func present<Root: View>(
        id: String,
        title: String,
        size: DSSheetSize,
        idealHeight: CGFloat? = nil,
        modality: DSPanelModality = .modeless,
        escapeCloses: Bool = false,
        remembersFrame: Bool = true,
        closeGuard: DSPanelCloseGuard? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder root: (WindowRef) -> Root
    ) -> NSWindow {
        if let existing = panels[id] {
            AuxiliaryWindow.present(existing.window)
            return existing.window
        }

        let token = UUID()
        // Captured before the window exists: a document-modal panel hangs
        // off the CANVAS window, never off whichever window happens to be
        // key. A panel-opening command can be reached with Settings or Qnet
        // Help in front, and a dialog parented to one of those travels with
        // it, orders above it and vanishes when it closes, while its
        // confirm button acts on a canvas the user cannot see. `nil` here
        // leaves the panel unparented, which is the right failure: it is
        // still a movable window the user can answer.
        let parent: NSWindow? = modality == .documentModal
            ? MainWindowRegistry.documentWindow()
            : nil

        let window = AuxiliaryWindow.make(
            id: id,
            title: title,
            contentSize: NSSize(width: size.idealWidth,
                                height: min(max(idealHeight ?? size.idealHeight, size.minHeight),
                                            size.maxHeight)),
            minSize: NSSize(width: size.minWidth, height: size.minHeight),
            escapeCloses: escapeCloses,
            // A dialog raised over a full-screened canvas must open in the
            // user's space, not throw them back to the desktop.
            fullScreenAuxiliary: true,
            frameKey: remembersFrame ? frameKey(for: id) : nil,
            onClose: { finish(id: id, token: token, onClose: onClose) }
        ) { ref in
            root(ref)
                // The panel's own close, so a body written against
                // `\.qnetDismiss` closes THIS window (see QnetDismissAction).
                .environment(\.qnetDismiss, QnetDismissAction { ref.close() })
        }

        // The band's upper end. `dsSheetFrame` gives the SwiftUI view a
        // maxWidth/maxHeight, but only the window can stop the resize
        // handle, so the same numbers are handed to AppKit.
        window.contentMaxSize = NSSize(width: size.maxWidth, height: size.maxHeight)

        switch modality {
        case .modeless:
            break
        case .documentModal:
            // A child window travels with its parent and stays above it —
            // a sheet's ordering without a sheet's immobility.
            parent?.addChildWindow(window, ordered: .above)
        case .appModal:
            window.level = .floating
        }

        let delegate = closeGuard.map { PanelWindowDelegate(guardBox: $0) }
        window.delegate = delegate

        panels[id] = Panel(window: window, modality: modality, delegate: delegate, token: token)
        syncMenuFlag()
        AuxiliaryWindow.present(window)
        return window
    }

    /// Single teardown path, run from `NSWindow.willCloseNotification`, so
    /// the registry and the menu flag are cleared no matter how the window
    /// was closed. Getting this wrong is the bug the comment in
    /// `QnetGUIApp.presentRunParameters` records: a stuck "a dialog is up"
    /// flag disables the canvas tool letters and ⌫ until relaunch.
    private static func finish(id: String, token: UUID, onClose: (() -> Void)?) {
        // Only if this id still belongs to THIS presentation. When it does
        // not, `close(id:)` already tore the registry entry down and a
        // replacement may be on screen — see `Panel.token` and `close(id:)`.
        guard let panel = panels[id], panel.token == token else { return }
        panel.window.delegate = nil
        panel.window.parent?.removeChildWindow(panel.window)
        panels[id] = nil
        syncMenuFlag()
        onClose?()
    }

    /// The menu flag is recomputed from the open panels rather than
    /// incremented and decremented, so no close path can leave it stuck on
    /// while another modal panel is still up — or stuck on with none.
    private static func syncMenuFlag() {
        let blocked = panels.values.contains { $0.modality.blocksCommands }
        guard let context = MenuContextRegistry.shared else { return }
        if context.modalPanelPresented != blocked { context.modalPanelPresented = blocked }
    }
}
