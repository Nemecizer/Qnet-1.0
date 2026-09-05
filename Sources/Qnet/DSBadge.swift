import SwiftUI

// MARK: - Pill

/// Status pill with an on/off state (the flag bar). Always a button: a lit
/// pill opens a popover explaining why the flag fired; an unlit pill opens
/// a short "why not" popover so the state is always explainable (and
/// VoiceOver-reachable). The popover content should be a `DSPopover`.
///
/// Off: neutral fill, secondary label. On: tinted fill (`tint` at 18 %),
/// hairline tint stroke, tinted symbol and a label in a contrast-corrected
/// tint colour (`DS.Color.legibleTint`), so an orange pill stays readable
/// in light mode. Hover deepens the fill, pressing deepens it further
/// (`DSPillButtonStyle`), disabled dims to `DS.Opacity.disabled`; nothing
/// scales or bounces. An optional `badge` count sits after the title.
struct DSPill<Detail: View>: View {
    let title: String
    let systemImage: String?
    let isOn: Bool
    let tint: Color
    let badge: Int?
    /// Tooltip while lit.
    let help: String
    /// Tooltip while off.
    let inactiveHelp: String
    /// VoiceOver hint for the popover action.
    let accessibilityHint: String?
    @ViewBuilder let detail: () -> Detail

    @State private var showPopover = false

    init(
        title: String,
        systemImage: String? = nil,
        isOn: Bool,
        tint: Color,
        badge: Int? = nil,
        help: String,
        inactiveHelp: String,
        accessibilityHint: String? = nil,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.tint = tint
        self.badge = badge
        self.help = help
        self.inactiveHelp = inactiveHelp
        self.accessibilityHint = accessibilityHint
        self.detail = detail
    }

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            label
        }
        .buttonStyle(DSPillButtonStyle(isOn: isOn, tint: tint))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            detail()
        }
        .help(isOn ? help : inactiveHelp)
        .accessibilityLabel("\(title): \(isOn ? "on" : "off")\(badge.map { ", \($0)" } ?? "")")
        .accessibilityHint(accessibilityHint ?? (isOn ? help : inactiveHelp))
        .dsAnimation(DS.Motion.quick, value: isOn)
    }

    private var label: some View {
        // One `legibleTint` lookup per render, not three: it is memoised,
        // but the label, the symbol and the count capsule all want the
        // same value and reading it once is clearer as well as cheaper.
        let inkOn = DS.Color.legibleTint(tint)
        return HStack(spacing: DS.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DS.Font.chromeEmphasis)
                    .foregroundStyle(isOn ? inkOn : DS.Color.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(isOn ? DS.Font.labelEmphasis : DS.Font.label)
                .foregroundStyle(isOn ? inkOn : DS.Color.textSecondary)
                .lineLimit(1)
            if let badge {
                Text("\(badge)")
                    .font(DS.Font.numberCaption.weight(.bold))
                    .foregroundStyle(DS.Color.textOnTint)
                    .padding(.horizontal, DS.Spacing.xs)
                    .frame(minWidth: DS.Layout.chipHeight - DS.Spacing.xs)
                    .frame(height: DS.Layout.chipHeight - DS.Spacing.xs)
                    .background(Capsule().fill(inkOn))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.s)
    }
}

/// Interaction states of a `DSPill`:
///   • off   — `inactiveFill`; hover `hoverFill`; pressed `selectionFill`
///   • on    — `tintFill`; hover / pressed `tintFillStrong`
///   • disabled — `DS.Opacity.disabled`, hover suppressed
private struct DSPillButtonStyle: ButtonStyle {
    let isOn: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        DSPillButtonBody(configuration: configuration, isOn: isOn, tint: tint)
    }
}

private struct DSPillButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isOn: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @DSAccessibility private var a11y
    @State private var isHovering = false

    private var fill: Color {
        if isOn {
            if configuration.isPressed || (isHovering && isEnabled) { return DS.Color.tintFillStrong(tint) }
            return DS.Color.tintFill(tint)
        }
        if configuration.isPressed { return DS.Color.selectionFill(a11y.contrast) }
        if isHovering && isEnabled { return DS.Color.hoverFill(a11y.contrast) }
        return DS.Color.inactiveFill
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(isOn ? DS.Color.dimmed(tint, DS.Opacity.borderTint)
                                 : DS.Color.controlBorder(a11y.contrast),
                            lineWidth: DS.Stroke.hairline(a11y.contrast))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .onHover { hovering in
                withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
            }
            .dsAnimation(DS.Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Badge / chip

/// Compact badge for counts ("3 issues", "128"), class chips and status
/// chips, always `DS.Layout.chipHeight` tall. Neutral by default; pass a
/// `tint` for a tinted fill + legible tint label. `swatch` draws a short
/// coloured bar before the text instead of tinting the whole chip — the
/// canvas class legend uses that form so the chip mirrors the link colour
/// without shouting. `dot` draws a status dot before the text (AI backend
/// chip); `dotRing` adds a translucent ring around it (busy).
struct DSBadge: View {
    enum Emphasis {
        /// Grey fill, secondary text.
        case neutral
        /// `tint` fill and legible-tint text.
        case tinted
        /// Selection wash (accent) — used for the active class filter.
        case selected
    }

    let text: String
    let tint: Color
    let emphasis: Emphasis
    let swatch: Bool
    let dimmed: Bool
    let dot: Color?
    let dotRing: Bool
    /// Shape fallback for the status dot. With "Differentiate Without
    /// Colour" on, a coloured dot carries no meaning at all, so the dot is
    /// replaced by this glyph (still tinted, but now distinguishable by
    /// silhouette). Any caller whose dot colour *is* the message must
    /// supply one; a decorative dot may leave it nil.
    let dotSymbol: String?

    init(
        text: String,
        tint: Color = DS.Color.textSecondary,
        emphasis: Emphasis = .neutral,
        swatch: Bool = false,
        dimmed: Bool = false,
        dot: Color? = nil,
        dotRing: Bool = false,
        dotSymbol: String? = nil
    ) {
        self.text = text
        self.tint = tint
        self.emphasis = emphasis
        self.swatch = swatch
        self.dimmed = dimmed
        self.dot = dot
        self.dotRing = dotRing
        self.dotSymbol = dotSymbol
    }

    @DSAccessibility private var a11y

    private var fill: Color {
        switch emphasis {
        case .neutral:  return DS.Color.inactiveFill
        case .tinted:   return DS.Color.tintFill(tint)
        case .selected: return DS.Color.selectionFill(a11y.contrast)
        }
    }

    private var border: Color {
        switch emphasis {
        case .neutral:  return .clear
        case .tinted:   return DS.Color.dimmed(tint, DS.Opacity.borderTint)
        case .selected: return DS.Color.controlBorder(a11y.contrast)
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .neutral:  return dimmed ? DS.Color.textTertiary(a11y.contrast) : DS.Color.textSecondary
        case .tinted:   return DS.Color.legibleTint(tint)
        case .selected: return DS.Color.textPrimary
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if swatch {
                RoundedRectangle(cornerRadius: DS.Radius.swatch)
                    .fill(dimmed ? DS.Color.dimmed(tint, DS.Opacity.selectionFillStrong) : tint)
                    .frame(width: DS.Layout.swatchBarWidth, height: DS.Layout.swatchBarHeight)
            }
            if let dot {
                if let dotSymbol, a11y.differentiate {
                    Image(systemName: dotSymbol)
                        .font(DS.Font.caption)
                        .foregroundStyle(dot)
                        .frame(width: DS.Layout.indicatorDotSize + DS.Spacing.xs,
                               height: DS.Layout.indicatorDotSize + DS.Spacing.xs)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(dot)
                        .frame(width: DS.Layout.indicatorDotSize, height: DS.Layout.indicatorDotSize)
                        .overlay {
                            if dotRing {
                                Circle()
                                    .stroke(DS.Color.dimmed(dot, DS.Opacity.selectionFillStrong),
                                            lineWidth: DS.Stroke.hairlineBold)
                                    .frame(width: DS.Layout.indicatorDotSize + DS.Spacing.xs,
                                           height: DS.Layout.indicatorDotSize + DS.Spacing.xs)
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            Text(text)
                .font(emphasis == .selected ? DS.Font.numberCaption.weight(.bold) : DS.Font.numberCaption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: DS.Layout.chipHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .stroke(border, lineWidth: DS.Stroke.hairline(a11y.contrast))
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .dsAnimation(DS.Motion.quick, value: emphasis == .selected)
        .dsAnimation(DS.Motion.quick, value: dimmed)
    }
}

// MARK: - Class chip

/// Colour swatch + label used wherever a customer class is named (menus,
/// tables, sheet rows). The label is always shown as text so colour alone
/// never carries meaning.
struct ClassChip: View {
    let classIndex: Int
    var compact: Bool = false

    /// With "Differentiate Without Colour" on, the swatch takes a
    /// per-class silhouette as well as a per-class colour, so two classes
    /// are told apart without relying on hue. Six shapes cycle; the label
    /// beside it is always the authoritative answer.
    private static let swatchShapes = [
        "circle.fill", "square.fill", "triangle.fill",
        "diamond.fill", "hexagon.fill", "pentagon.fill",
    ]

    @DSAccessibility private var a11y

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if a11y.differentiate {
                Image(systemName: Self.swatchShapes[classIndex % Self.swatchShapes.count])
                    .font(DS.Font.caption)
                    .foregroundStyle(CustomerClass.color(for: classIndex))
                    .frame(width: DS.Layout.classDotSize, height: DS.Layout.classDotSize)
            } else {
                Circle()
                    .fill(CustomerClass.color(for: classIndex))
                    .frame(width: DS.Layout.classDotSize, height: DS.Layout.classDotSize)
                    .overlay(Circle().stroke(DS.Color.controlBorder(a11y.contrast),
                                             lineWidth: DS.Stroke.hairlineFaint(a11y.contrast)))
            }
            Text(compact ? "C\(classIndex + 1)" : CustomerClass.label(for: classIndex))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CustomerClass.label(for: classIndex))
    }
}

// MARK: - Shortcut keycap

/// Keycap-shaped badge for a single-letter shortcut (Tools pane).
struct ShortcutBadge: View {
    let key: String

    @DSAccessibility private var a11y

    var body: some View {
        Text(key)
            .font(DS.Font.keycap)
            .monospacedDigit()
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs / 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous)
                    .fill(DS.Color.inactiveFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous)
                    .stroke(DS.Color.separator(a11y.contrast),
                            lineWidth: DS.Stroke.hairlineFaint(a11y.contrast))
            )
            .accessibilityHidden(true)
    }
}
