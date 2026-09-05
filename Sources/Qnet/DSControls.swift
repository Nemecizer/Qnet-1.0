import SwiftUI

// MARK: - Row label

/// The one row label: title in `DS.Font.body` with an optional secondary
/// caption underneath (`DS.Font.caption`). Dims as a whole when the row is
/// disabled or `dimmed` (an override row whose switch is off). Used by
/// `DSInspectorRow`, hence by every DS field, and by Settings toggle rows.
struct DSRowLabel: View {
    let title: String
    let caption: String?
    var dimmed: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, caption: String? = nil, dimmed: Bool = false) {
        self.title = title
        self.caption = caption
        self.dimmed = dimmed
    }

    private var active: Bool { isEnabled && !dimmed }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(active ? DS.Color.textPrimary : DS.Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundStyle(active ? DS.Color.textSecondary : DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsAnimation(DS.Motion.quick, value: active)
    }
}

/// Settings spelling of `DSRowLabel`, kept so Settings rows read naturally.
typealias SettingsLabel = DSRowLabel

// MARK: - Glossary button

/// The "?" that turns a jargon label into an explanation: the one
/// question-mark button in the app. Used by `DSInspectorRow` (hence by
/// every DS field, slider and picker), by `DSTextArea` and by the Settings
/// rows whose control is not a DS field (`SettingsLabel`). `text` is a
/// `DS.Glossary` entry; `label` names the thing being explained, so the
/// tooltip reads "What is ρ?" and the popover is titled with it.
struct DSGlossaryButton: View {
    let label: String
    let text: String

    @State private var showHelp = false
    @State private var hovering = false
    @DSAccessibility private var a11y

    var body: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: DS.Symbol.help)
                .font(DS.Font.subheadline)
                // Hover state, like every other DS control: a "?" the
                // pointer is over must look clickable.
                .foregroundStyle(hovering ? DS.Color.accent : DS.Color.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(a11y.animation(DS.Motion.quick)) { self.hovering = hovering }
        }
        .dsTooltip("What is \(label)?")
        .accessibilityLabel("What is \(label)?")
        .accessibilityHint(text)
        .popover(isPresented: $showHelp, arrowEdge: .trailing) {
            DSPopover(title: label, systemImage: DS.Symbol.help, size: .compact) {
                Text(text)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Glossary slot (the "?" column)

/// The trailing column every `.form` / `.inspector` row ends with: exactly
/// `DS.Layout.glossaryColumnWidth` wide, holding a `DSGlossaryButton` when
/// the row has a glossary entry and nothing otherwise. Reserving the slot
/// on rows WITHOUT an entry is the point — before it existed the "?" was
/// the rightmost element of only the rows that had one, so their field,
/// stepper and unit column sat one button-width left of the identical
/// rows above them. Rows whose control is not a DS field (a Settings
/// toggle, a read-only value) place this after their control so they end
/// at the same x as a field row.
struct DSGlossarySlot: View {
    let label: String
    let text: String?

    init(label: String, text: String?) {
        self.label = label
        self.text = text
    }

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                DSGlossaryButton(label: label, text: text)
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(width: DS.Layout.glossaryColumnWidth, height: DS.Layout.controlHeight)
    }
}

// MARK: - Inspector row

/// One labelled row of an inspector or sheet. The label sits in a fixed
/// trailing-aligned column (`DS.Layout.formLabelWidth`) so every row in a
/// pane lines up; inside a grouped `Form` (`.dsRowLayout(.form)`) it becomes
/// a `LabeledContent` row instead; `.compact` drops the label but keeps the
/// message caption; `.bare` renders the control alone (table cells).
/// `help` is the tooltip; an optional `caption` is a secondary line under
/// the label; an optional `glossary` string adds a question-mark button
/// whose popover explains jargon (use `DS.Glossary.*` for SCV, ρ, Γ …); an
/// optional `error` renders an `InlineFieldMessage` under the control, and
/// an optional `warning` renders the same caption in the advisory style
/// when there is no error (a value the field itself changed, e.g. "Clamped
/// to 1,000"). With `.dsReservedMessageSlot()` the caption line is always
/// reserved so messages never shift the layout.
struct DSInspectorRow<Content: View>: View {
    let label: String
    let caption: String?
    let help: String?
    let glossary: String?
    let error: String?
    let warning: String?
    let labelDimmed: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.dsRowLayout) private var layout
    @Environment(\.dsReservesMessageSlot) private var reservesSlot

    init(
        label: String,
        caption: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        error: String? = nil,
        warning: String? = nil,
        labelDimmed: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.caption = caption
        self.help = help
        self.glossary = glossary
        self.error = error
        self.warning = warning
        self.labelDimmed = labelDimmed
        self.content = content
    }

    var body: some View {
        switch layout {
        case .inspector:
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(alignment: .center, spacing: DS.Spacing.s) {
                    if !label.isEmpty {
                        labelView
                            .frame(width: DS.Layout.formLabelWidth, alignment: .trailing)
                    }
                    content()
                    // Always reserved (see DSGlossarySlot): rows with and
                    // without a "?" share one trailing edge.
                    glossarySlot
                }
                .frame(minHeight: DS.Layout.controlHeight)
                messageSlot(alignment: .leading)
                    .padding(.leading, label.isEmpty ? 0 : DS.Layout.formLabelWidth + DS.Spacing.s)
            }
        case .form:
            LabeledContent {
                VStack(alignment: .trailing, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.s) {
                        content()
                        glossarySlot
                    }
                    // The caption ends under the control, not under the
                    // reserved "?" column.
                    messageSlot(alignment: .trailing)
                        .padding(.trailing, DS.Layout.glossaryColumnWidth + DS.Spacing.s)
                }
            } label: {
                if !label.isEmpty { labelView }
            }
        case .compact:
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.s) {
                    content()
                    helpButton
                }
                messageSlot(alignment: .leading)
            }
        case .bare:
            content()
        }
    }

    private var labelView: some View {
        DSRowLabel(label, caption: caption, dimmed: labelDimmed)
            .help(help ?? label)
    }

    /// `.compact` keeps the old behaviour (the button only when there is
    /// an entry): those rows live in table cells, where a reserved column
    /// would widen every cell.
    @ViewBuilder
    private var helpButton: some View {
        if let glossary, !glossary.isEmpty {
            DSGlossaryButton(label: label, text: glossary)
        }
    }

    private var glossarySlot: some View {
        DSGlossarySlot(label: label, text: glossary)
    }

    /// The error wins the one caption line; an advisory shows only when
    /// there is nothing wrong to report.
    private var message: (text: String?, severity: InlineFieldMessage.Severity) {
        if let error, !error.isEmpty { return (error, .error) }
        if let warning, !warning.isEmpty { return (warning, .warning) }
        return (nil, .error)
    }

    @ViewBuilder
    private func messageSlot(alignment: Alignment) -> some View {
        let message = message
        if reservesSlot {
            InlineFieldMessage(message: message.text, severity: message.severity)
                .frame(minHeight: DS.Spacing.l, alignment: alignment)
        } else if let text = message.text {
            InlineFieldMessage(message: text, severity: message.severity)
        }
    }
}

/// Reserves the height of one DS field row (plus the message slot when
/// `.dsReservedMessageSlot()` is on) without drawing anything, so a
/// one-parameter distribution family occupies the same space as a
/// two-parameter one and the sheet never changes height.
struct DSInspectorRowPlaceholder: View {
    @Environment(\.dsReservesMessageSlot) private var reservesSlot

    var body: some View {
        Color.clear
            .frame(height: DS.Layout.fieldRowHeight + (reservesSlot ? DS.Spacing.l + DS.Spacing.xxs : 0))
            .accessibilityHidden(true)
    }
}

// MARK: - Labelled slider

/// Slider with a live readout of fixed width (`DS.Layout.readoutWidth`) in
/// monospaced digits, so the row never reflows while dragging. The track
/// is `DS.Layout.sliderMinWidth … sliderIdealWidth` wide in every row.
struct DSLabelledSlider: View {
    let label: String
    let caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let unit: String?
    let format: FloatingPointFormatStyle<Double>
    let help: String?
    let glossary: String?

    init(
        label: String,
        caption: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        unit: String? = nil,
        format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(2)),
        help: String? = nil,
        glossary: String? = nil
    ) {
        self.label = label
        self.caption = caption
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.format = format
        self.help = help
        self.glossary = glossary
    }

    private var readout: String {
        let number = format.format(value)
        if let unit, !unit.isEmpty { return "\(number) \(unit)" }
        return number
    }

    var body: some View {
        DSInspectorRow(label: label, caption: caption, help: help, glossary: glossary) {
            HStack(spacing: DS.Spacing.s) {
                Group {
                    if let step {
                        Slider(value: $value, in: range, step: step)
                    } else {
                        Slider(value: $value, in: range)
                    }
                }
                .labelsHidden()
                .frame(minWidth: DS.Layout.sliderMinWidth, idealWidth: DS.Layout.sliderIdealWidth)
                .accessibilityLabel(label)
                .accessibilityValue(readout)

                Text(readout)
                    .font(DS.Font.number)
                    .foregroundStyle(DS.Color.textPrimary)
                    .frame(minWidth: DS.Layout.readoutWidth, alignment: .trailing)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .help(help ?? label)
        }
    }
}

// MARK: - Segmented picker

/// Segmented control whose label is carried by the row (`labelsHidden()`),
/// with `help` applied to the control and an optional fixed `width`.
struct DSSegmentedPicker<Option: Hashable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    let help: String?
    /// Longer explanation behind a "?" button, like every other DS row.
    /// A picker whose label is jargon ("Enter as") must carry one.
    let glossary: String?
    let width: CGFloat?

    init(
        label: String,
        selection: Binding<Option>,
        options: [Option],
        help: String? = nil,
        glossary: String? = nil,
        width: CGFloat? = nil,
        title: @escaping (Option) -> String
    ) {
        self.label = label
        self._selection = selection
        self.options = options
        self.help = help
        self.glossary = glossary
        self.width = width
        self.title = title
    }

    var body: some View {
        DSInspectorRow(label: label, help: help, glossary: glossary) {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: width)
            .help(help ?? label)
            .accessibilityLabel(label)
        }
    }
}

extension DSSegmentedPicker where Option: RawRepresentable, Option.RawValue == String {
    init(label: String, selection: Binding<Option>, options: [Option],
         help: String? = nil, glossary: String? = nil, width: CGFloat? = nil) {
        self.init(label: label, selection: selection, options: options,
                  help: help, glossary: glossary, width: width) { $0.rawValue }
    }
}

// MARK: - Menu picker

/// Pop-up menu picker in the same row layout, with a custom row renderer
/// so callers can show symbols or colour swatches next to the option title.
struct DSMenuPicker<Option: Hashable, Row: View>: View {
    let label: String
    let caption: String?
    @Binding var selection: Option
    let options: [Option]
    let help: String?
    let glossary: String?
    let width: CGFloat?
    @ViewBuilder let row: (Option) -> Row

    init(
        label: String,
        caption: String? = nil,
        selection: Binding<Option>,
        options: [Option],
        help: String? = nil,
        glossary: String? = nil,
        width: CGFloat? = DS.Layout.fieldWidth,
        @ViewBuilder row: @escaping (Option) -> Row
    ) {
        self.label = label
        self.caption = caption
        self._selection = selection
        self.options = options
        self.help = help
        self.glossary = glossary
        self.width = width
        self.row = row
    }

    var body: some View {
        DSInspectorRow(label: label, caption: caption, help: help, glossary: glossary) {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    row(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: width)
            .help(help ?? label)
            .accessibilityLabel(label)
        }
    }
}

extension DSMenuPicker where Row == Text {
    init(
        label: String,
        caption: String? = nil,
        selection: Binding<Option>,
        options: [Option],
        help: String? = nil,
        glossary: String? = nil,
        width: CGFloat? = DS.Layout.fieldWidth,
        title: @escaping (Option) -> String
    ) {
        self.init(label: label, caption: caption, selection: selection, options: options,
                  help: help, glossary: glossary, width: width) {
            Text(title($0))
        }
    }
}
