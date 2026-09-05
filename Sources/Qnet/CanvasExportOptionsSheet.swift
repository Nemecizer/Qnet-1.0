import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Diagram export options
// ─────────────────────────────────────────────────────────────────────────────
//
// The choices behind File ▸ Export ▸ Diagram as PDF… / PNG…: how big, on
// what ground, with or without the grid and the class legend.  Remembered
// in UserDefaults under `CanvasExportOptions.Keys`, so the second export
// of a session opens with the first one's answers.  Print and Copy as
// Image read the same options without asking (⌘P and ⌥⌘C must stay one
// keystroke); the dialog is shown only by the two Export commands, and it
// is a movable panel (`DSPanelWindow`) rather than a sheet — see
// `CanvasExportOptionsPresenter` at the bottom of this file for why.
// ─────────────────────────────────────────────────────────────────────────────

/// Everything the renderer needs to know beyond the network itself.
struct CanvasExportOptions: Equatable {
    enum Background: String, CaseIterable, Identifiable {
        /// The canvas ground (`DS.Color.surfaceRaised`, light appearance).
        case canvas
        /// Paper white.
        case white
        /// No ground at all — PDF only; a PNG is written on white instead.
        case transparent

        var id: String { rawValue }
        var title: String {
            switch self {
            case .canvas: return "Canvas"
            case .white: return "White"
            case .transparent: return "Transparent"
            }
        }
    }

    /// Pixels per point for a PNG (1×, 2×, 4×); a PDF is vector and
    /// ignores it.
    var pixelScale: Int = 2
    var background: Background = .canvas
    var includesGrid = false
    /// Class-colour key, composed into the figure when the network has
    /// more than one customer class.
    var includesLegend = true

    static let pixelScales = [1, 2, 4]

    enum Keys {
        static let pixelScale = "canvas.export.pixelScale"
        static let background = "canvas.export.background"
        static let includesGrid = "canvas.export.includesGrid"
        static let includesLegend = "canvas.export.includesLegend"
    }

    /// The remembered options (defaults on first use).
    static func load() -> CanvasExportOptions {
        let d = UserDefaults.standard
        var o = CanvasExportOptions()
        if let s = d.object(forKey: Keys.pixelScale) as? Int, pixelScales.contains(s) { o.pixelScale = s }
        if let b = d.string(forKey: Keys.background).flatMap(Background.init(rawValue:)) { o.background = b }
        if d.object(forKey: Keys.includesGrid) != nil { o.includesGrid = d.bool(forKey: Keys.includesGrid) }
        if d.object(forKey: Keys.includesLegend) != nil { o.includesLegend = d.bool(forKey: Keys.includesLegend) }
        return o
    }
}

/// Which command opened the sheet — it changes the rows that apply.
enum CanvasExportFormat {
    case pdf
    case png

    var title: String { self == .pdf ? "Export Diagram as PDF" : "Export Diagram as PNG" }
    var subtitle: String {
        switch self {
        case .pdf: return "Vector output — resolution-independent at any size, for a paper figure or a slide."
        case .png: return "Raster output on an opaque ground, for an email, a wiki or a chat."
        }
    }
}

/// The form.  `@AppStorage` on the same keys `CanvasExportOptions.load`
/// reads, so what the user picks here is what Print and Copy use next.
/// It is an ordinary `DSSheet` body: the panel host presents exactly the
/// view a `.sheet(` would have.
struct CanvasExportOptionsSheet: View {
    let format: CanvasExportFormat
    let classCount: Int
    let onCancel: () -> Void
    let onConfirm: (CanvasExportOptions) -> Void

    @AppStorage(CanvasExportOptions.Keys.pixelScale) private var pixelScale = 2
    @AppStorage(CanvasExportOptions.Keys.background) private var backgroundRaw =
        CanvasExportOptions.Background.canvas.rawValue
    @AppStorage(CanvasExportOptions.Keys.includesGrid) private var includesGrid = false
    @AppStorage(CanvasExportOptions.Keys.includesLegend) private var includesLegend = true

    private var background: Binding<CanvasExportOptions.Background> {
        Binding(
            get: { CanvasExportOptions.Background(rawValue: backgroundRaw) ?? .canvas },
            set: { backgroundRaw = $0.rawValue })
    }

    private var options: CanvasExportOptions {
        CanvasExportOptions(
            pixelScale: CanvasExportOptions.pixelScales.contains(pixelScale) ? pixelScale : 2,
            background: background.wrappedValue,
            includesGrid: includesGrid,
            includesLegend: includesLegend)
    }

    var body: some View {
        DSSheet(size: .compact) {
            DSSheetHeader(format.title, subtitle: format.subtitle) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.export,
                                   tint: DS.Color.infoText)
            }
        } content: {
            Form {
                Section {
                    if format == .png {
                        DSSegmentedPicker(
                            label: "Scale",
                            selection: $pixelScale,
                            options: CanvasExportOptions.pixelScales,
                            help: "Pixels per point. 2× matches a Retina screen; 4× for print-quality raster."
                        ) { "\($0)×" }
                    }
                    DSSegmentedPicker(
                        label: "Background",
                        selection: background,
                        options: format == .pdf
                            ? CanvasExportOptions.Background.allCases
                            : [.canvas, .white],
                        help: format == .pdf
                            ? "The ground behind the diagram. Transparent lets the figure sit on the page's own colour."
                            : "The ground behind the diagram. A PNG is always opaque."
                    ) { $0.title }
                    Toggle("Include grid", isOn: $includesGrid)
                        .help("Draw the canvas dot grid behind the network")
                    Toggle("Include class legend", isOn: $includesLegend)
                        .disabled(classCount <= 1)
                        .help(classCount > 1
                              ? "Compose the customer-class colour key into the bottom-left of the figure"
                              : "This network has one customer class, so there is no colour key to include")
                } header: {
                    Text("Figure")
                } footer: {
                    Text(footerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } footer: {
            DSSheetFooter(
                confirmTitle: "Export…",
                cancelHelp: "Close without exporting (Esc)",
                confirmHelp: "Choose a destination and write the file (Return)",
                onCancel: onCancel,
                onConfirm: { onConfirm(options) }
            )
        }
    }

    private var footerText: String {
        var parts = ["Every export is drawn in the light appearance, so a figure made at midnight matches one made at noon."]
        if classCount > 1 {
            parts.append("This network has \(classCount) customer classes; a figure without its colour key is hard to read in print.")
        }
        return parts.joined(separator: " ")
    }
}

/// Presents `CanvasExportOptionsSheet` in a movable panel window.
///
/// It is a *panel* and not a sheet for the reason the form exists: the
/// user is choosing a background and a scale for a picture of the network
/// the dialog is sitting on top of, and a sheet pins itself over exactly
/// the thing they need to look at. In a panel they can drag it aside,
/// toggle "Include grid", and see what they are about to export.
///
/// This also retires the app's only hand-rolled `NSWindow` + `beginSheet`
/// presentation. The Export commands live in the menu bar, outside any
/// SwiftUI presentation context, which is what pushed this form into
/// AppKit in the first place — a window needs no presentation context, so
/// `DSPanelWindow` solves that problem outright, and the old
/// no-key-window fallback (export silently, with whatever options were
/// remembered) is gone with it.
@MainActor
enum CanvasExportOptionsPresenter {
    /// Panel id, and therefore the window identifier and the frame-autosave
    /// key. One id for both formats: the PDF and PNG dialogs are the same
    /// form with one row swapped, so re-opening either restores the frame
    /// the user last dragged it to.
    private static let panelID = "canvas-export"

    static func present(format: CanvasExportFormat,
                        classCount: Int,
                        onConfirm: @escaping (CanvasExportOptions) -> Void) {
        // Asking again while the panel is up must bring it forward, not
        // stack a second copy writing the same @AppStorage keys. Presenting
        // the id again does exactly that, but the *format* may differ
        // (⌘-export PNG on top of an open PDF panel), and a panel cannot
        // change its rows under the user — so close and rebuild.
        if DSPanelWindow.isOpen(id: panelID) {
            DSPanelWindow.close(id: panelID)
        }
        DSPanelWindow.present(
            id: panelID,
            title: format.title,
            size: .compact,
            // The footer's Cancel already binds Escape; a second cancel
            // action in the same window is one too many.
            escapeCloses: false
        ) { ref in
            CanvasExportOptionsSheet(
                format: format,
                classCount: classCount,
                onCancel: { ref.close() },
                onConfirm: { options in
                    // Order the panel out BEFORE the save panel opens.
                    // `NSSavePanel.runModal` is app-modal, and two windows
                    // fighting for key status leaves the sheet's fields
                    // half-alive behind the save panel; the async hop lets
                    // the close land before the modal run loop starts.
                    ref.close()
                    DispatchQueue.main.async { onConfirm(options) }
                })
        }
    }
}
