import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// DS gallery — the design system rendered as a system, side by side in light
// and dark, so a token change can be *seen* before it ships.
// ─────────────────────────────────────────────────────────────────────────────
//
// Open it with:
//
//     swift run Qnet --ds-gallery          (dev tree)
//     Qnet.app/Contents/MacOS/Qnet --ds-gallery
//
// The flag does not suppress the main window; the gallery opens beside it as
// an auxiliary window, so you can compare a real pane with the reference.
//
// What it shows, in three columns:
//   • light appearance
//   • dark appearance
//   • light at `.dynamicTypeSize(.accessibility1)`, which is where clipped
//     labels and fixed-height rows fail first
//
// and, per section: the type scale with its real macOS point sizes, every
// DS.Color swatch with its measured contrast against `surface`, the icon
// button / toggle / menu in idle · hover · pressed · disabled · selected,
// DSPill on and off with a count badge, DSBadge in all three emphases plus
// swatch and dot, DSNumericField in all four DSRowLayouts with a live error
// and a warning, DSRangeFields, DSSearchField, DSSegmentedPicker,
// DSLabelledSlider, DSEmptyState (including `.search`), the three DSPopover
// sizes and a DSSheet header + footer.
//
// The contrast numbers beside the swatches are the same WCAG 2.x formula
// `validation/ds_contrast.swift` gates in CI — the gallery is the eye test,
// the script is the gate.
//
// The toolbar across the top forces the three accessibility switches for
// the whole window (Reduce Motion, Increase Contrast, Differentiate
// Without Colour) through `DSA11yOverride`, and the a11y section renders
// the two branch-carrying specimens — DSBadge's `dotSymbol` and
// SeriesChip's silhouettes — with the switch off and on side by side. Both
// branches used to be invisible without changing System Settings and
// relaunching, which is the round trip this window exists to remove.
//
// The three columns share ONE vertical ScrollView, so row N of Light and
// row N of Dark are always on screen together — comparing a light swatch
// with its dark counterpart is the whole point, and three independent
// scrollers drifted apart on the first gesture.
//
// This file is a design reference rather than a shipping surface — nothing
// here is reachable from the menus and it holds no app state — but it IS
// compiled into the release binary and reachable with `--ds-gallery`, on
// purpose: the gallery is how a designer checks a shipped build, and a
// reference that only exists in debug is a reference nobody trusts.

// MARK: - Contrast helper (mirrors validation/ds_contrast.swift)

private enum GalleryContrast {
    static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? NSColor.black
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent)
             + 0.7152 * lin(s.greenComponent)
             + 0.0722 * lin(s.blueComponent)
    }

    /// Contrast of `ink` on `ground`, both resolved in `appearance`.
    static func ratio(_ ink: SwiftUI.Color, on ground: SwiftUI.Color,
                      appearance: NSAppearance) -> CGFloat {
        var a = NSColor(ink), b = NSColor(ground)
        appearance.performAsCurrentDrawingAppearance {
            a = (NSColor(ink).usingColorSpace(.sRGB)) ?? a
            b = (NSColor(ground).usingColorSpace(.sRGB)) ?? b
        }
        // Composite a translucent ink over its ground before measuring.
        if a.alphaComponent < 1 {
            let f = a.alphaComponent
            a = NSColor(srgbRed: a.redComponent * f + b.redComponent * (1 - f),
                        green: a.greenComponent * f + b.greenComponent * (1 - f),
                        blue: a.blueComponent * f + b.blueComponent * (1 - f),
                        alpha: 1)
        }
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func text(_ ink: SwiftUI.Color, on ground: SwiftUI.Color,
                     dark: Bool) -> String {
        let app = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        return String(format: "%.2f:1", Double(ratio(ink, on: ground, appearance: app)))
    }
}

// MARK: - Small building blocks

/// A labelled specimen row: what the thing is called, then the thing.
private struct Specimen<Content: View>: View {
    let name: String
    var detail: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.Font.monoCaption)
                    .foregroundStyle(DS.Color.textSecondary)
                if let detail {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .frame(width: DS.Layout.formLabelWidth + DS.Spacing.xl, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            DSSectionHeader(title)
            if let note {
                Text(note)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Spacing.m)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                content()
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.m)
        }
    }
}

// MARK: - The gallery body

struct DSGalleryView: View {
    /// Whether this column is rendering the dark appearance, so the
    /// contrast readouts resolve the same colours the eye is seeing.
    let dark: Bool
    @DSAccessibility private var a11y

    // Live state so the interactive specimens actually interact.
    @State private var text = "S1"
    @State private var emptyText = ""
    @State private var number: Double = 1.25
    @State private var badNumber: Double = -3
    @State private var count = 4
    @State private var lo = 2
    @State private var hi = 16
    @State private var slider: Double = 0.62
    @State private var query = "buffer"
    @State private var prompt = "A multi-line text area, shown here at its resting height.\nIt grows to maxLines, then scrolls."
    @State private var snap = true
    @State private var flag = true
    @State private var mode = "Native"

    /// Body of the `.wide` popover specimen: preformatted reference text
    /// with a fixed measure, which is the only content that case is for.
    private static let widePopoverSpecimen = """
        R = I - PᵀΔ

          station    R[i][i]    R[i][j]
          S1          1.000     -0.400
          S2         -0.250      1.000

        A column of R sums to the fraction of departures
        that leave the network at that station.
        """

    var body: some View {
        // No ScrollView here: `DSGalleryWindowView` wraps all three
        // columns in one, so the appearances stay row-aligned.
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            typeScale
            colours
            controls
            pillsAndBadges
            accessibility
            fields
            states
        }
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surface)
    }

    // MARK: Accessibility branches

    /// The two specimens whose appearance depends on a system switch,
    /// drawn in both states at once. Everything else in the window follows
    /// the toolbar; these two are pinned so the difference is visible even
    /// with the toolbar off.
    private var accessibility: some View {
        GallerySection("Accessibility branches",
                       note: "Left column: the switch off. Right column: the same specimen with the switch forced on. The window's toolbar forces all three switches for every other specimen — including the stroke widths and hover washes that Increase Contrast steps up, which is otherwise invisible until you flip it in System Settings and relaunch.") {
            Specimen(name: "Differentiate", detail: "DSBadge(dotSymbol:) · SeriesChip silhouettes") {
                HStack(alignment: .top, spacing: DS.Spacing.xl) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("off").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        DSBadge(text: "Ready", dot: DS.Color.success, dotSymbol: DS.Symbol.success)
                        DSBadge(text: "No key", dot: DS.Color.warning, dotSymbol: DS.Symbol.warning)
                        HStack(spacing: DS.Spacing.s) {
                            ForEach(0..<3, id: \.self) { SeriesChip(classIndex: $0, compact: true) }
                        }
                    }
                    .dsA11yOverride(DSA11yOverride(differentiateWithoutColor: false))
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("on").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        DSBadge(text: "Ready", dot: DS.Color.success, dotSymbol: DS.Symbol.success)
                        DSBadge(text: "No key", dot: DS.Color.warning, dotSymbol: DS.Symbol.warning)
                        HStack(spacing: DS.Spacing.s) {
                            ForEach(0..<3, id: \.self) { SeriesChip(classIndex: $0, compact: true) }
                        }
                    }
                    .dsA11yOverride(DSA11yOverride(differentiateWithoutColor: true))
                }
            }
            Specimen(name: "Increase Contrast", detail: "hairline widths and hover / selection washes") {
                HStack(alignment: .top, spacing: DS.Spacing.xl) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("standard").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        contrastSpecimens
                    }
                    .dsA11yOverride(DSA11yOverride(contrast: .standard))
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("increased").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        contrastSpecimens
                    }
                    .dsA11yOverride(DSA11yOverride(contrast: .increased))
                }
            }
        }
    }

    private var contrastSpecimens: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            DSBadge(text: "128")
            DSBadge(text: "3 warnings", tint: DS.Color.warning, emphasis: .tinted)
            HStack(spacing: DS.Spacing.xs) {
                DSIconButton(systemImage: DS.Symbol.copy, help: "Copy") {}
                DSIconToggle(systemImage: DS.Symbol.snapToGrid, isOn: $snap,
                             label: "Snap to Grid", help: "Snap to Grid")
            }
            ShortcutBadge(key: "L")
            DSRule().frame(width: DS.Layout.gallerySpecimenWideWidth)
        }
    }

    // MARK: Type

    private var typeScale: some View {
        GallerySection("Typography",
                       note: "SF Pro text styles at their real macOS point sizes. footnote = caption = caption2 = 10 pt, which is why there is one 10-pt token. Numbers use monospaced digits so a changing value never shifts.") {
            Specimen(name: "pageTitle", detail: "22 pt semibold") {
                Text(GUIKitConfig.applicationName).font(DS.Font.pageTitle)
            }
            Specimen(name: "sheetTitle", detail: "17 pt semibold") {
                Text("Station parameters").font(DS.Font.sheetTitle)
            }
            Specimen(name: "sectionTitle", detail: "13 pt semibold") {
                Text("Service Time").font(DS.Font.sectionTitle)
            }
            Specimen(name: "body", detail: "13 pt") {
                Text("Interarrival distribution").font(DS.Font.body)
            }
            Specimen(name: "label / callout", detail: "12 pt") {
                Text("Tractable").font(DS.Font.label)
            }
            Specimen(name: "chrome / subheadline", detail: "11 pt") {
                Text("3 nodes · 2 links").font(DS.Font.chrome)
            }
            Specimen(name: "caption", detail: "10 pt") {
                Text("Must be greater than zero").font(DS.Font.caption)
            }
            Specimen(name: "number", detail: "13 pt monospaced digits") {
                Text("0.837500").font(DS.Font.number)
            }
            Specimen(name: "numberCaption", detail: "10 pt monospaced digits") {
                Text("1.0000e-03").font(DS.Font.numberCaption)
            }
            Specimen(name: "mono", detail: "SF Mono 13 pt") {
                Text("rho_1 = 0.8375").font(DS.Font.mono)
            }
        }
    }

    // MARK: Colour

    private var colours: some View {
        GallerySection("Colour",
                       note: "Every swatch with its measured WCAG contrast against the surface it is drawn on. The four signal colours are shown twice: the solid colour (icons, fills) and the legible tint (text on that colour's own wash). validation/ds_contrast.swift gates exactly these pairs.") {
            swatchRow("surface", DS.Color.surface, ink: DS.Color.textPrimary)
            swatchRow("surfaceRaised", DS.Color.surfaceRaised, ink: DS.Color.textPrimary)
            swatchRow("fieldBackground", DS.Color.fieldBackground, ink: DS.Color.textPrimary)
            swatchRow("subtleFill", DS.Color.subtleFill, ink: DS.Color.textPrimary)
            swatchRow("separator", DS.Color.separator, ink: DS.Color.textPrimary)
            swatchRow("controlBorder", DS.Color.controlBorder, ink: DS.Color.textPrimary)
            swatchRow("inactiveFill", DS.Color.inactiveFill, ink: DS.Color.textPrimary)

            textRow("textPrimary", DS.Color.textPrimary)
            textRow("textSecondary", DS.Color.textSecondary)
            textRow("textTertiary", DS.Color.textTertiary(a11y.contrast))

            signalRow("success", DS.Color.success, DS.Color.successText)
            signalRow("warning", DS.Color.warning, DS.Color.warningText)
            signalRow("danger", DS.Color.danger, DS.Color.dangerText)
            signalRow("info", DS.Color.info, DS.Color.infoText)

            swatchRow("accent", DS.Color.accent, ink: DS.Color.textOnTint)
            swatchRow("hoverFill (10 %)", DS.Color.hoverFill, ink: DS.Color.textPrimary)
            swatchRow("selectionFill (15 %)", DS.Color.selectionFill, ink: DS.Color.textPrimary)
            swatchRow("marqueeFill (8 %)", DS.Color.marqueeFill, ink: DS.Color.textPrimary)
            swatchRow("focusRing (35 %)", DS.Color.focusRing, ink: DS.Color.textPrimary)

            swatchRow("stationFill", DS.Color.stationFill, ink: DS.Color.nodeStroke)
            swatchRow("bufferFill", DS.Color.bufferFill, ink: DS.Color.nodeStroke)
            swatchRow("sourceFill", DS.Color.sourceFill, ink: DS.Color.nodeStroke)
            swatchRow("sinkFill", DS.Color.sinkFill, ink: DS.Color.nodeStroke)
            swatchRow("gridDot", DS.Color.gridDot, ink: DS.Color.textPrimary)
            swatchRow("gridLine", DS.Color.gridLine, ink: DS.Color.textPrimary)
        }
    }

    private func chip(_ fill: SwiftUI.Color, _ ink: SwiftUI.Color, _ label: String) -> some View {
        Text(label)
            .font(DS.Font.numberCaption)
            .foregroundStyle(ink)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.chipHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairlineFaint(a11y.contrast)))
    }

    private func swatchRow(_ name: String, _ colour: SwiftUI.Color,
                           ink: SwiftUI.Color) -> some View {
        Specimen(name: name) {
            HStack(spacing: DS.Spacing.s) {
                chip(colour, ink, "Aa")
                Text(GalleryContrast.text(ink, on: colour, dark: dark))
                    .font(DS.Font.numberCaption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private func textRow(_ name: String, _ ink: SwiftUI.Color) -> some View {
        Specimen(name: name) {
            HStack(spacing: DS.Spacing.s) {
                Text("The quick brown fox")
                    .font(DS.Font.label)
                    .foregroundStyle(ink)
                Text(GalleryContrast.text(ink, on: DS.Color.surface, dark: dark))
                    .font(DS.Font.numberCaption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private func signalRow(_ name: String, _ solid: SwiftUI.Color,
                           _ legible: SwiftUI.Color) -> some View {
        Specimen(name: name) {
            HStack(spacing: DS.Spacing.s) {
                chip(solid, DS.Color.textOnTint, "solid")
                chip(DS.Color.tintFill(solid), legible, "wash + text")
                Text(GalleryContrast.text(legible, on: DS.Color.tintFill(solid), dark: dark))
                    .font(DS.Font.numberCaption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        GallerySection("Buttons and toolbar controls",
                       note: "Hover and pressed states are live — move the pointer over these. Every icon-only control carries a tooltip that doubles as its accessibility label; a control without one will not compile through DSIconButton.") {
            Specimen(name: "DSIconButton", detail: "idle · destructive · disabled") {
                HStack(spacing: DS.Spacing.s) {
                    DSIconButton(systemImage: DS.Symbol.copy, help: "Copy") {}
                    DSIconButton(systemImage: DS.Symbol.clearPane, help: "Clear", isDestructive: true) {}
                    DSIconButton(systemImage: DS.Symbol.export, help: "Export") {}
                        .disabled(true)
                }
            }
            Specimen(name: "DSIconToggle", detail: "on / off") {
                HStack(spacing: DS.Spacing.s) {
                    DSIconToggle(systemImage: DS.Symbol.snapToGrid, isOn: $snap,
                                 label: "Snap to Grid", help: "Snap to Grid")
                    DSIconToggle(systemImage: DS.Symbol.grid, isOn: .constant(false),
                                 label: "Grid", help: "Show grid")
                }
            }
            Specimen(name: "DSIconMenu") {
                DSIconMenu(systemImage: DS.Symbol.export, label: "Export", help: "Export…") {
                    Button("As PDF…") {}
                    Button("As PNG…") {}
                }
            }
            Specimen(name: "DSToolbarButtonStyle", detail: "idle / selected / disabled") {
                HStack(spacing: DS.Spacing.s) {
                    Button("Run") {}.buttonStyle(DSToolbarButtonStyle())
                    Button("Selected") {}.buttonStyle(DSToolbarButtonStyle(isSelected: true))
                    Button("Disabled") {}.buttonStyle(DSToolbarButtonStyle()).disabled(true)
                }
            }
            Specimen(name: "DSSegmentedPicker") {
                DSSegmentedPicker(label: "Enter as", selection: $mode,
                                  options: ["Native", "Mean & SCV"],
                                  help: "Entry mode",
                                  glossary: DS.Glossary.entryMode,
                                  width: DS.Layout.wideFieldWidth) { $0 }
                    .dsRowLayout(.compact)
            }
            Specimen(name: "DSLabelledSlider") {
                DSLabelledSlider(label: "Utilisation", value: $slider, range: 0...1,
                                 step: 0.01, help: "Target ρ")
                    .dsRowLayout(.compact)
            }
            Specimen(name: "ShortcutBadge") {
                HStack(spacing: DS.Spacing.xs) {
                    ShortcutBadge(key: "V")
                    ShortcutBadge(key: "S")
                    ShortcutBadge(key: "L")
                }
            }
        }
    }

    // MARK: Pills and badges

    private var pillsAndBadges: some View {
        GallerySection("Pills, badges and chips",
                       note: "A lit pill's label is legibleTint(tint) on tintFill(tint) — the pair the contrast gate measures. Under Differentiate Without Colour the status dot becomes a glyph and the class swatch takes a per-class silhouette.") {
            Specimen(name: "DSPill", detail: "on · off · with count") {
                HStack(spacing: DS.Spacing.s) {
                    DSPill(title: "Tractable", systemImage: DS.Symbol.success, isOn: true,
                           tint: DS.Color.success, help: "Tractable", inactiveHelp: "Not tractable") {
                        Text("detail")
                    }
                    .frame(width: DS.Layout.gallerySpecimenWidth)
                    DSPill(title: "Warnings", systemImage: DS.Symbol.warning, isOn: true,
                           tint: DS.Color.warning, badge: 3,
                           help: "3 warnings", inactiveHelp: "No warnings") { Text("detail") }
                        .frame(width: DS.Layout.gallerySpecimenWideWidth)
                    DSPill(title: "Errors", systemImage: DS.Symbol.error, isOn: false,
                           tint: DS.Color.danger, help: "Errors", inactiveHelp: "No errors") {
                        Text("detail")
                    }
                    .frame(width: DS.Layout.gallerySpecimenWidth)
                }
            }
            Specimen(name: "DSBadge", detail: "neutral · tinted · selected") {
                HStack(spacing: DS.Spacing.s) {
                    DSBadge(text: "128")
                    DSBadge(text: "Partial", tint: DS.Color.warning, emphasis: .tinted)
                    DSBadge(text: "Failed", tint: DS.Color.danger, emphasis: .tinted)
                    DSBadge(text: "Class 1", emphasis: .selected)
                }
            }
            Specimen(name: "DSBadge", detail: "swatch · dot · dot + ring") {
                HStack(spacing: DS.Spacing.s) {
                    DSBadge(text: "Class 1", tint: SeriesPalette.color(for: 0), swatch: true)
                    DSBadge(text: "Ready", dot: DS.Color.success, dotSymbol: DS.Symbol.success)
                    DSBadge(text: "Working", dot: DS.Color.accent, dotRing: true,
                            dotSymbol: DS.Symbol.pending)
                }
            }
            Specimen(name: "SeriesChip") {
                HStack(spacing: DS.Spacing.m) {
                    ForEach(0..<4, id: \.self) { SeriesChip(classIndex: $0) }
                }
                .font(DS.Font.label)
            }
        }
    }

    // MARK: Fields

    private var fields: some View {
        GallerySection("Fields",
                       note: "The same DSNumericField in all four row layouts. The error and warning captions live in a reserved slot under .dsReservedMessageSlot(), so a message appearing never shifts the rows beneath it.") {
            Specimen(name: ".inspector") {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    DSNumericField(label: "Service rate", value: $number, unit: "jobs / s",
                                   range: 0.0001...1_000, help: "μ", glossary: DS.Glossary.seed)
                    DSNumericField(label: "Utilisation", value: $badNumber, unit: nil,
                                   range: 0...1, error: "Must be between 0 and 1",
                                   help: "ρ", glossary: DS.Glossary.tolerance)
                    DSTextField(label: "Name", text: $text, help: "Station name")
                    DSRangeFields(label: "Classes", lower: $lo, upper: $hi, range: 1...64,
                                  help: "Class index range")
                }
                .dsRowLayout(.inspector)
                .dsReservedMessageSlot()
            }
            Specimen(name: ".form", detail: "the ? column is reserved on every row: with and without a glossary, fields end at one x") {
                Form {
                    DSNumericField(label: "Buffer size", value: $count, unit: "jobs",
                                   range: 1...10_000, help: "Capacity",
                                   glossary: DS.Glossary.sampleRate)
                    DSNumericField(label: "Servers", value: $count, unit: "servers",
                                   range: 1...64, help: "Parallel servers — no glossary, same trailing edge")
                    DSNumericField(label: "SCV", value: $number, range: 0...100,
                                   help: "c²", glossary: DS.Glossary.tolerance)
                    DSTextArea(label: "System prompt",
                               caption: "A text area in .form — the well ends where the fields end, the ? in the same column",
                               text: $prompt, minLines: 3, maxLines: 4, monospaced: true,
                               help: "Multi-line text with the reserved ? column",
                               glossary: DS.Glossary.entryMode)
                    DSNumericField(label: "Max tokens", value: $count, unit: "tokens",
                                   range: 1...200_000, help: "The row under the text area — one trailing edge")
                }
                .formStyle(.grouped)
                .dsRowLayout(.form)
                .frame(width: DS.Layout.sheetWidth - DS.Spacing.xxl)
            }
            Specimen(name: ".compact / .bare") {
                HStack(spacing: DS.Spacing.m) {
                    DSNumericField(label: "Mean", value: $number,
                                   width: DS.Layout.compactFieldWidth)
                        .dsRowLayout(.compact)
                    DSNumericField(label: "SCV", value: $number,
                                   width: DS.Layout.compactFieldWidth)
                        .dsRowLayout(.bare)
                }
            }
            Specimen(name: "DSSearchField", detail: "hover · focus ring · clear · match count") {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    DSSearchField(text: $query, placeholder: "Search",
                                  shortcutHint: "⌘F", help: "Filter the list")
                        .frame(width: DS.Layout.wideFieldWidth)
                    DSSearchField(text: $query, placeholder: "Search",
                                  shortcutHint: "⌘F", help: "Return steps through the matches",
                                  status: "3 of 5")
                        .frame(width: DS.Layout.wideFieldWidth)
                    DSSearchField(text: $emptyText, placeholder: "Empty",
                                  help: "Nothing typed yet")
                        .frame(width: DS.Layout.wideFieldWidth)
                }
            }
            Specimen(name: "DSTextArea", detail: "label above · focus ring · sized in lines") {
                DSTextArea(label: "System prompt",
                           caption: "Sent before every conversation.",
                           text: $prompt,
                           minLines: 4,
                           maxLines: 8,
                           monospaced: true,
                           help: "Instructions the assistant receives before every conversation.")
                    .frame(width: DS.Layout.sheetWidth - DS.Spacing.xxl)
            }
            Specimen(name: "InlineFieldMessage", detail: "error · warning · pending") {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    InlineFieldMessage(message: "Must be greater than zero")
                    InlineFieldMessage("ρ above 0.95 — the approximation degrades",
                                       severity: .warning)
                    InlineFieldMessage(message: "Still typing Service rate", severity: .pending)
                }
            }
        }
    }

    // MARK: Empty states, popovers, sheet chrome

    private var states: some View {
        GallerySection("Empty states, popovers and sheet chrome",
                       note: "One empty state, one popover chrome and one sheet chrome for the whole app. The popover sizes are the three DSPopoverSize cases; the sheet header and footer are what every one of the app's sheets is built from.") {
            Specimen(name: "DSEmptyState") {
                DSEmptyState(systemImage: DS.Symbol.network,
                             title: "No Network Yet",
                             message: "Add a source, a station and a sink, then draw links between them.",
                             actionTitle: "Add a Station") {}
                    .frame(height: DS.Layout.gallerySpecimenHeight)
            }
            Specimen(name: "DSEmptyState.search") {
                DSEmptyState.search(query: query)
                    .frame(height: DS.Layout.gallerySpecimenShortHeight)
            }
            Specimen(name: "DSPopover", detail: ".compact / .regular / .wide") {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    DSPopover(title: "Utilisation", systemImage: DS.Symbol.help, size: .compact) {
                        Text(DS.Glossary.tolerance)
                            .font(DS.Font.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize()
                    DSPopover(title: "Warnings", systemImage: DS.Symbol.warning,
                              trailing: "3 stations", size: .regular) {
                        Text("S2 is above 0.95 utilisation; the QNA approximation degrades sharply beyond that point.")
                            .font(DS.Font.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize()
                    // The specimen the detail label promised but never drew.
                    // It is the one with a long title and a scrolling body,
                    // which is exactly the pair that used to collide: in the
                    // Accessibility column the title now wraps instead of
                    // truncating, and the body scrolls instead of clipping.
                    DSPopover(title: "Reflection Matrix Reference",
                              systemImage: DS.Symbol.help,
                              trailing: "R", size: .wide) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(Self.widePopoverSpecimen)
                                .font(DS.Font.monoCallout)
                                .textSelection(.enabled)
                                .padding(.horizontal, DS.Spacing.l)
                                .padding(.bottom, DS.Spacing.l)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                    .fixedSize()
                }
            }
            Specimen(name: "DSSheetHeader") {
                DSSheetHeader("Station parameters", subtitle: "S1 · 2 classes served") {
                    DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                       systemImage: DS.Symbol.inspector,
                                       tint: DS.Color.infoText)
                }
                .frame(width: DS.Layout.sheetWidth)
            }
            Specimen(name: "DSSheetFooter", detail: "clean · blocked") {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    DSSheetFooter(confirmTitle: "Save", canConfirm: true,
                                  onCancel: {}, onConfirm: {})
                        .frame(width: DS.Layout.sheetWidth)
                    DSSheetFooter(problem: "Service rate must be greater than zero",
                                  confirmTitle: "Save", canConfirm: false,
                                  blockedHelp: "Fix the highlighted fields to save",
                                  onCancel: {}, onConfirm: {})
                        .frame(width: DS.Layout.sheetWidth)
                }
            }
        }
    }
}

// MARK: - Three-column shell

struct DSGalleryWindowView: View {
    @State private var reduceMotion = false
    @State private var increaseContrast = false
    @State private var differentiate = false

    /// What every specimen in the window is rendered with. `nil` for a
    /// switch that is off means "follow the system", so the window opens
    /// showing what the reviewer's own Mac shows.
    private var override: DSA11yOverride {
        DSA11yOverride(reduceMotion: reduceMotion ? true : nil,
                       contrast: increaseContrast ? .increased : nil,
                       differentiateWithoutColor: differentiate ? true : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            columnTitles
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    column(dark: false, accessibilityText: false)
                    DSRule(.vertical)
                    column(dark: true, accessibilityText: false)
                    DSRule(.vertical)
                    column(dark: false, accessibilityText: true)
                }
            }
            .background(DS.Color.surface)
        }
        .frame(minWidth: DS.Layout.Window.auxWideMinWidth,
               minHeight: DS.Layout.Window.auxWideMinHeight)
    }

    /// Forces the three accessibility switches for the whole window.
    private var toolbar: some View {
        HStack(spacing: DS.Spacing.l) {
            Text("Force accessibility switches")
                .font(DS.Font.chrome)
                .foregroundStyle(DS.Color.textSecondary)
            Toggle("Reduce Motion", isOn: $reduceMotion)
                .help("Drop every DS animation, as System Settings ▸ Accessibility ▸ Display ▸ Reduce motion does")
            Toggle("Increase Contrast", isOn: $increaseContrast)
                .help("Step every hairline and hover / selection wash up, as System Settings ▸ Accessibility ▸ Display ▸ Increase contrast does")
            Toggle("Differentiate Without Colour", isOn: $differentiate)
                .help("Give every colour-coded chip a shape as well, as System Settings ▸ Accessibility ▸ Display ▸ Differentiate without colour does")
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .font(DS.Font.chrome)
        .dsChromeBar(.bottom, horizontal: DS.Spacing.m, vertical: DS.Spacing.s)
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            title("Light", dark: false)
            DSRule(.vertical, length: DS.Layout.headerHeight)
            title("Dark", dark: true)
            DSRule(.vertical, length: DS.Layout.headerHeight)
            title("Light · Accessibility 1", dark: false)
        }
    }

    private func title(_ text: String, dark: Bool) -> some View {
        DSSectionHeader(text)
            .frame(maxWidth: .infinity)
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func column(dark: Bool, accessibilityText: Bool) -> some View {
        DSGalleryView(dark: dark)
            .dynamicTypeSize(accessibilityText ? .accessibility1 : .large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surface)
            .environment(\.colorScheme, dark ? .dark : .light)
            .dsA11yOverride(override)
    }
}

// MARK: - Window

@MainActor
enum DSGalleryWindow {
    private static var retained: NSWindow?

    /// Set by `--ds-gallery` on the command line; `applicationDidFinishLaunching`
    /// opens the window once the app is up.
    static var requestedAtLaunch = false

    static func show() {
        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }
        let window = AuxiliaryWindow.make(
            id: "ds-gallery",
            title: "Design System Gallery",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: GUIKitConfig.frameKey(for: "DSGallery")
        ) { _ in
            DSGalleryWindowView()
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
}
