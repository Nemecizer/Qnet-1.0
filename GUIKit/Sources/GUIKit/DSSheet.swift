import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// The one sheet chrome. Every modal sheet in Qnet is
//
//     DSSheet {
//         DSSheetHeader("S1", subtitle: "Station · 2 servers") { glyph }
//     } content: {
//         Form { … }.formStyle(.grouped)
//     } footer: {
//         DSSheetFooter(problem: firstProblem, confirmTitle: "Save",
//                       canConfirm: isValid, onCancel: …, onConfirm: …)
//     }
//
// Header and footer are padded `DS.Spacing.l` and separated from the
// content by hairlines; the content region fills the remaining height.
// The footer carries the default (Return) and cancel (Esc) key bindings.
//
// Geometry: every sheet opens at one of two widths (`DS.Layout.sheetWidth`
// 560, `sheetWidthWide` 640) and is resizable inside a `DSSheetSize` band —
// pass `size:` to `DSSheet` (or apply `.dsSheetFrame(_:)` to a custom root).
// ─────────────────────────────────────────────────────────────────────────────

/// Sheet geometry presets: min / ideal / max width and height.
enum DSSheetSize {
    /// Short dialogs (Find Node): 560 × 400.
    case compact
    /// Most parameter sheets (Generate, Export, Link editor, Test set): 560 × 540.
    case regular
    /// Longer forms (spectral convergence sweep): 560 × 600.
    case tall
    /// Grids and pickers, and BOTH parameter inspectors: 640 × 620.
    /// The link inspector used to open at 560 and the node inspector at
    /// 640, so opening one after the other stepped the window width for
    /// no reason a user could see; they are one band now.
    case wide
    /// A sheet whose content is a wide data table — today only the node
    /// inspector’s per-class service table: 800 × 620, resizable 760…1000.
    /// Deliberately the widest band; a table that has to wrap its
    /// parameter fields reads worse than a wide sheet does.
    case table

    var minWidth: CGFloat {
        switch self {
        case .compact, .regular, .tall: return DS.Layout.sheetMinWidth
        case .wide: return DS.Layout.sheetWidth
        case .table: return DS.Layout.sheetMinWidthTable
        }
    }
    var idealWidth: CGFloat {
        switch self {
        case .compact, .regular, .tall: return DS.Layout.sheetWidth
        case .wide: return DS.Layout.sheetWidthWide
        case .table: return DS.Layout.sheetWidthTable
        }
    }
    var maxWidth: CGFloat {
        switch self {
        case .compact, .regular, .tall: return DS.Layout.sheetMaxWidth
        case .wide: return DS.Layout.sheetMaxWidthWide
        case .table: return DS.Layout.sheetMaxWidthTable
        }
    }
    var minHeight: CGFloat {
        switch self {
        case .compact: return DS.Layout.sheetMinHeightCompact
        case .regular, .tall: return DS.Layout.sheetMinHeight
        case .wide, .table: return DS.Layout.sheetMinHeightWide
        }
    }
    var idealHeight: CGFloat {
        switch self {
        case .compact: return DS.Layout.sheetHeightCompact
        case .regular: return DS.Layout.sheetHeightRegular
        case .tall: return DS.Layout.sheetHeightTall
        case .wide, .table: return DS.Layout.sheetHeightWide
        }
    }
    var maxHeight: CGFloat {
        switch self {
        case .compact: return DS.Layout.sheetMaxHeightCompact
        case .regular: return DS.Layout.sheetMaxHeightRegular
        case .tall, .wide, .table: return DS.Layout.sheetMaxHeight
        }
    }

    /// Opening height for a sheet whose body is `rows` repeated field rows
    /// on top of fixed chrome — the node inspector’s per-class service
    /// table. The result is clamped into this size’s `minHeight …
    /// maxHeight` band, so a many-class station opens tall but never
    /// off-screen — and the arithmetic lives here instead of as literals
    /// inside a sheet. (A form whose fixed part is shorter — a sink — uses
    /// a smaller *band*, `.compact` / `.regular`, not a height override.)
    func height(forRows rows: Int) -> CGFloat {
        let grown = idealHeight + CGFloat(max(0, rows)) * DS.Layout.tableRowHeight
        return min(max(grown, minHeight), maxHeight)
    }
}

extension View {
    /// Apply a `DSSheetSize` band (min / ideal / max width and height).
    /// `idealHeight:` overrides only the opening height — pass a value
    /// from `DSSheetSize.height(forRows:)` for a sheet whose content
    /// grows with a row count (the node inspector's per-class table);
    /// the min / max band still comes from the size, so no sheet can
    /// invent its own geometry.
    func dsSheetFrame(_ size: DSSheetSize, idealHeight: CGFloat? = nil) -> some View {
        frame(minWidth: size.minWidth, idealWidth: size.idealWidth, maxWidth: size.maxWidth,
              minHeight: size.minHeight, idealHeight: idealHeight ?? size.idealHeight,
              maxHeight: size.maxHeight)
    }
}

struct DSSheet<Header: View, Content: View, Footer: View>: View {
    let size: DSSheetSize?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(
        size: DSSheetSize? = nil,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.size = size
        self.header = header
        self.content = content
        self.footer = footer
    }

    var body: some View {
        // `qnetDismissBridge` fills in `\.qnetDismiss` from SwiftUI's own
        // `dismiss` unless a host — `DSPanelWindow` — has already claimed
        // it, so one sheet body dismisses itself correctly whether it is
        // presented as a sheet or hosted in a movable panel window.
        Group {
            if let size {
                stack.dsSheetFrame(size)
            } else {
                stack
            }
        }
        .qnetDismissBridge()
    }

    private var stack: some View {
        VStack(spacing: 0) {
            header()
                .padding(DS.Spacing.l)
            DSRule()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            DSRule()
            footer()
                .padding(DS.Spacing.l)
        }
    }
}

// MARK: - Header

/// Sheet title row: optional 44-pt glyph disc, title (`DS.Font.sheetTitle`)
/// and a one-line secondary subtitle. Pass `.accessibilityLabel` on the
/// whole header if the subtitle needs a different spoken form.
struct DSSheetHeader<Glyph: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let glyph: () -> Glyph

    init(_ title: String, subtitle: String? = nil, @ViewBuilder glyph: @escaping () -> Glyph) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
    }

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            glyph()
                .frame(width: DS.Layout.sheetGlyphSize, height: DS.Layout.sheetGlyphSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(DS.Font.sheetTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DSSheetHeader where Glyph == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// 44-pt disc for a sheet header: a tinted fill with a hairline ring and
/// a symbol (or any content) inside.
struct DSSheetGlyph<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: () -> Content
    @DSAccessibility private var a11y

    init(fill: Color, @ViewBuilder content: @escaping () -> Content) {
        self.fill = fill
        self.content = content
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(DS.Color.controlBorder(a11y.contrast),
                                         lineWidth: DS.Stroke.hairline(a11y.contrast)))
            content()
        }
    }
}

/// Convenience: a symbol glyph disc.
struct DSSheetSymbolGlyph: View {
    let fill: Color
    let systemImage: String
    let tint: Color

    var body: some View {
        DSSheetGlyph(fill: fill) {
            Image(systemName: systemImage)
                .font(DS.Font.sheetGlyph)
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Footer

/// Sheet footer: the Mac help control in the bottom-left corner when the
/// sheet has a `helpTopic`, a leading status slot (the first blocking
/// problem in `DS.Color.danger`, or custom `leading` content), then
/// Cancel (Esc) and the confirm button (Return), which is disabled while
/// `canConfirm` is false. No key-binding hint text: the default-button
/// ring already communicates Return, and no macOS sheet prints its key
/// bindings.
///
/// `helpTopic:` is the one way a sheet links to documentation. It calls
/// Qnet Help at that topic without dismissing the sheet, so a reader
/// stuck on "basis size m" can look it up and come back.
struct DSSheetFooter<Leading: View>: View {
    let problem: String?
    let helpTopic: HelpTopic?
    let cancelTitle: String
    let confirmTitle: String
    let canConfirm: Bool
    let cancelHelp: String
    let confirmHelp: String
    let blockedHelp: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let leading: () -> Leading

    init(
        problem: String? = nil,
        helpTopic: HelpTopic? = nil,
        cancelTitle: String = "Cancel",
        confirmTitle: String = "Save",
        canConfirm: Bool = true,
        cancelHelp: String = "Discard changes (Esc)",
        confirmHelp: String = "Apply changes as one undoable step (Return)",
        blockedHelp: String = "Fix the highlighted fields to continue",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.problem = problem
        self.helpTopic = helpTopic
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.canConfirm = canConfirm
        self.cancelHelp = cancelHelp
        self.confirmHelp = confirmHelp
        self.blockedHelp = blockedHelp
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            if let helpTopic, HelpPresenter.isAvailable {
                DSHelpButton(
                    label: "Help about \(helpTopic.windowTitle)",
                    help: "Open Help at \u{201C}\(helpTopic.windowTitle)\u{201D}"
                ) {
                    HelpPresenter.show?(helpTopic)
                }
                .fixedSize()
            }
            if let problem, !problem.isEmpty {
                // The same caption a field draws under itself — one
                // rendering of "something is wrong", not a third.
                InlineFieldMessage(message: problem, severity: .error, lineLimit: 2)
                    .accessibilityLabel("Cannot continue: \(problem)")
            } else {
                leading()
            }
            Spacer(minLength: DS.Spacing.s)
            Button(cancelTitle, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .help(cancelHelp)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
                .help(canConfirm ? confirmHelp : blockedHelp)
        }
        .dsAnimation(DS.Motion.quick, value: problem)
    }
}

extension DSSheetFooter where Leading == EmptyView {
    init(
        problem: String? = nil,
        helpTopic: HelpTopic? = nil,
        cancelTitle: String = "Cancel",
        confirmTitle: String = "Save",
        canConfirm: Bool = true,
        cancelHelp: String = "Discard changes (Esc)",
        confirmHelp: String = "Apply changes as one undoable step (Return)",
        blockedHelp: String = "Fix the highlighted fields to continue",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.init(problem: problem, helpTopic: helpTopic, cancelTitle: cancelTitle,
                  confirmTitle: confirmTitle, canConfirm: canConfirm, cancelHelp: cancelHelp,
                  confirmHelp: confirmHelp, blockedHelp: blockedHelp,
                  onCancel: onCancel, onConfirm: onConfirm) { EmptyView() }
    }
}

// MARK: - Missing-target placeholder

/// Shown inside a sheet when the node / link it was opened for has been
/// deleted underneath it.
struct DSSheetMissingTarget: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: DS.Symbol.help)
                .font(DS.Font.largeTitle)
                .foregroundStyle(DS.Color.textSecondary)
            Text(message)
                .font(DS.Font.headline)
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
