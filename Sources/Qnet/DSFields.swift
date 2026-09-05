import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// DS fields — the ONE numeric field, the one text field, the one range pair,
// the one search field and the one multi-line text area. Every text-entry
// control in Qnet (inspectors, Settings, the Generate / Test-set sheets,
// pane filter rows) is one of these. There is no second implementation
// anywhere — design_lint.sh rejects a TextEditor or a bare
// `.roundedBorder` outside this layer; if a caller needs a behaviour that
// is missing, add it here.
//
// Field chrome is the native `.roundedBorder` NSTextField so a Qnet field
// looks like a System Settings field, with:
//   • monospaced digits, right-aligned numbers
//   • a unit column beside the field (reserved in `.form` rows so every
//     field in a grouped section lines up)
//   • an optional Stepper (`.linear` or `.multiplicative` step)
//   • a 1.5-pt danger border while invalid (`validatedFieldBorder`)
//   • an `InlineFieldMessage` caption under the control (error / warning)
//   • a commit on Return, on focus loss, on a stepper press AND on
//     disappearance, so closing the window mid-edit keeps the value
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Row layout environment

/// How `DSInspectorRow` (and the DS fields built on it) lay out their label.
enum DSRowLayout {
    /// Trailing-aligned label column of `DS.Layout.formLabelWidth`, then the
    /// control. Free-standing inspectors.
    case inspector
    /// `LabeledContent`: label leading, control trailing, spanning the row.
    /// Grouped `Form` sections (sheets, Settings).
    case form
    /// No label; the control with its message caption underneath. For a
    /// field that lives inside someone else's `LabeledContent`.
    case compact
    /// No label and no message caption — the control alone, for table cells
    /// and range pairs. Validation still shows on the field border.
    case bare
}

private struct DSRowLayoutKey: EnvironmentKey {
    static let defaultValue: DSRowLayout = .inspector
}

/// When true every DSInspectorRow reserves a one-line caption slot under
/// its control, so a validation message appearing or disappearing never
/// shifts the rows beneath it (parameter sheets).
private struct DSReservedMessageSlotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dsRowLayout: DSRowLayout {
        get { self[DSRowLayoutKey.self] }
        set { self[DSRowLayoutKey.self] = newValue }
    }
    var dsReservesMessageSlot: Bool {
        get { self[DSReservedMessageSlotKey.self] }
        set { self[DSReservedMessageSlotKey.self] = newValue }
    }
}

extension View {
    /// Choose the label layout for every DS row in this subtree.
    func dsRowLayout(_ layout: DSRowLayout) -> some View {
        environment(\.dsRowLayout, layout)
    }

    /// Reserve a fixed caption line under every DS row in this subtree.
    func dsReservedMessageSlot(_ reserved: Bool = true) -> some View {
        environment(\.dsReservesMessageSlot, reserved)
    }
}

// MARK: - Inline message

/// The one caption shown beneath a field or as an advisory row: a filled
/// circle in `DS.Color.danger` for errors, a filled triangle in
/// `DS.Color.warning` for warnings (legal but unwise values). Error text is
/// danger-coloured; warning text stays primary so a sentence of advice
/// remains readable. Reserves no space when `message` is nil; use
/// `.dsReservedMessageSlot()` for layout stability.
struct InlineFieldMessage: View {
    /// Three severities, three voices:
    ///   `.error`    something is wrong and blocks (red, filled circle)
    ///   `.warning`  something is worth knowing but does not block
    ///               (orange triangle, primary text)
    ///   `.pending`  the value is not finished yet — a half-typed number
    ///               ("0.", "1e-") is not a mistake, so it is deliberately
    ///               calm: secondary text, ellipsis glyph, no colour.
    enum Severity { case error, warning, pending }

    let message: String?
    var severity: Severity = .error
    /// Line cap for a message drawn in a fixed-height slot (a table's
    /// reserved caption row): 1 truncates with an ellipsis and the full
    /// text stays in the tooltip. Nil keeps the default (3 for errors and
    /// warnings, 1 for a pending note).
    var lineLimit: Int? = nil

    init(message: String?, severity: Severity = .error, lineLimit: Int? = nil) {
        self.message = message
        self.severity = severity
        self.lineLimit = lineLimit
    }

    /// Advisory-row spelling: `InlineFieldMessage("…", severity: .warning)`.
    init(_ message: String, severity: Severity = .warning) {
        self.message = message
        self.severity = severity
    }

    private var symbol: String {
        switch severity {
        case .error:   return DS.Symbol.error
        case .warning: return DS.Symbol.warning
        case .pending: return DS.Symbol.pending
        }
    }

    private var iconColor: SwiftUI.Color {
        switch severity {
        case .error:   return DS.Color.dangerText
        case .warning: return DS.Color.warningText
        case .pending: return DS.Color.textSecondary
        }
    }

    private var textColor: SwiftUI.Color {
        switch severity {
        case .error:   return DS.Color.dangerText
        case .warning: return DS.Color.textPrimary
        case .pending: return DS.Color.textSecondary
        }
    }

    private var spokenLabel: String {
        guard let message else { return "" }
        switch severity {
        case .error:   return "Error: \(message)"
        case .warning: return "Warning: \(message)"
        case .pending: return "Not ready: \(message)"
        }
    }

    var body: some View {
        if let message, !message.isEmpty {
            Label {
                Text(message)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(iconColor)
            }
            .font(DS.Font.caption)
            .lineLimit(lineLimit ?? (severity == .pending ? 1 : 3))
            .truncationMode(.tail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenLabel)
            .transition(.opacity)
            .help(severity == .pending ? "Finish entering the value to enable Save" : message)
        }
    }
}

// MARK: - Validated border

/// Border treatment for a text field that is currently invalid.
struct ValidatedFieldBorder: ViewModifier {
    let isInvalid: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control - 1, style: .continuous)
                    .stroke(DS.Color.danger, lineWidth: isInvalid ? DS.Stroke.hairlineBold : 0)
                    .padding(-DS.Stroke.hairline)
            )
            .dsAnimation(DS.Motion.quick, value: isInvalid)
    }
}

extension View {
    func validatedFieldBorder(isInvalid: Bool) -> some View {
        modifier(ValidatedFieldBorder(isInvalid: isInvalid))
    }
}

// MARK: - Unit column

/// Unit label beside a field. In `.form` rows the column is always
/// reserved (`DS.Layout.unitColumnWidth`) so fields align across rows;
/// elsewhere it is drawn only when there is a unit.
private struct DSUnitColumn: View {
    let unit: String?
    let dimmed: Bool
    @Environment(\.dsRowLayout) private var layout

    var body: some View {
        if layout == .form {
            Text(unit ?? "")
                .font(DS.Font.numberSmall)
                .foregroundStyle(dimmed ? DS.Color.textTertiary : DS.Color.textSecondary)
                .lineLimit(1)
                .frame(minWidth: DS.Layout.unitColumnWidth, alignment: .leading)
                .accessibilityHidden(true)
        } else if let unit, !unit.isEmpty {
            Text(unit)
                .font(DS.Font.numberSmall)
                .foregroundStyle(dimmed ? DS.Color.textTertiary : DS.Color.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Text field

/// Labelled single-line text field with the DS row layout. Pass
/// `focus:` to drive focus from the caller's `@FocusState` (initial focus
/// on the Name field of a sheet). `width: nil` lets the field fill the
/// row (URLs, model names); `monospaced` sets SF Mono for identifiers;
/// `isSecure` swaps in a `SecureField` (API keys) while keeping focus and
/// submit behaviour; `accessory` places controls after the field (a
/// presets menu, a reveal button).
///
/// `required:` is the text counterpart of `DSNumericField`'s mid-number
/// tolerance: while the field has focus and is empty, the caller's
/// `error` is *not* drawn, because select-all + Delete before retyping a
/// name is not a mistake the user has made yet. The caller's Save stays
/// blocked (its own `error` is still non-nil) and should say so calmly —
/// "Still typing Name" — instead of painting a red border, a red caption
/// and a red footer line on an empty field. Leaving the field empty shows
/// the error normally.
struct DSTextField<Accessory: View>: View {
    let label: String
    let caption: String?
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let monospaced: Bool
    let help: String?
    let glossary: String?
    let width: CGFloat?
    /// Optional validation message; non-nil shows the danger state.
    let error: String?
    /// See the type doc: suppress `error` while focused and empty.
    let required: Bool
    let externalFocus: FocusState<Bool>.Binding?
    let onSubmit: (() -> Void)?
    /// Fired when the row is torn down mid-edit (the window closed, the
    /// pane switched) — the commit hook. Defaults to `onSubmit`, which is
    /// right for a field whose Return action IS its commit (the Settings
    /// API key writes the Keychain there); a caller whose Return only
    /// advances focus passes its own `onCommit` (or `{}`) so that focus
    /// move never fires at teardown.
    let onCommit: (() -> Void)?
    @ViewBuilder let accessory: () -> Accessory

    @FocusState private var focused: Bool

    private var isFocused: Bool { externalFocus?.wrappedValue ?? focused }

    /// The message actually drawn. Nil while the user has cleared a
    /// required field to retype it.
    private var shownError: String? {
        if required, isFocused, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return error
    }

    init(
        label: String,
        caption: String? = nil,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        monospaced: Bool = false,
        help: String? = nil,
        glossary: String? = nil,
        width: CGFloat? = DS.Layout.fieldWidth,
        error: String? = nil,
        required: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.caption = caption
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.monospaced = monospaced
        self.help = help
        self.glossary = glossary
        self.width = width
        self.error = error
        self.required = required
        self.externalFocus = focus
        self.onSubmit = onSubmit
        self.onCommit = onCommit
        self.accessory = accessory
    }

    var body: some View {
        DSInspectorRow(label: label, caption: caption, help: help, glossary: glossary, error: shownError) {
            HStack(spacing: DS.Spacing.xs) {
                Group {
                    if isSecure {
                        SecureField("", text: $text, prompt: Text(placeholder))
                    } else {
                        TextField("", text: $text, prompt: Text(placeholder))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? DS.Font.mono : DS.Font.body)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .focused(externalFocus ?? $focused)
                .onSubmit { onSubmit?() }
                .validatedFieldBorder(isInvalid: shownError != nil)
                .help(help ?? label)
                .accessibilityLabel(label)

                accessory()
            }
        }
        // The row going away (⌘W on the Settings window mid-edit fires no
        // focus change) commits through `onCommit`, which defaults to
        // `onSubmit` — see the property doc for when to pass one.
        .onDisappear { (onCommit ?? onSubmit)?() }
    }
}

extension DSTextField where Accessory == EmptyView {
    init(
        label: String,
        caption: String? = nil,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        monospaced: Bool = false,
        help: String? = nil,
        glossary: String? = nil,
        width: CGFloat? = DS.Layout.fieldWidth,
        error: String? = nil,
        required: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil
    ) {
        self.init(label: label, caption: caption, text: text, placeholder: placeholder,
                  isSecure: isSecure, monospaced: monospaced, help: help, glossary: glossary,
                  width: width, error: error, required: required,
                  focus: focus, onSubmit: onSubmit, onCommit: onCommit) { EmptyView() }
    }
}

// MARK: - Numeric field

/// How a numeric field reports validity while the user types.
enum DSValidationMode {
    /// Validate on every keystroke, but tolerate incomplete input ("-",
    /// "1e", ".") so the danger border never flashes mid-number.
    case live
    /// Validate only on Return or focus loss.
    case onCommit
}

/// When a value-backed numeric field writes its binding.
enum DSCommitMode {
    /// Write on every keystroke that parses and lies in range (a canvas
    /// preview that should follow the field).
    case onEdit
    /// Write once, on Return / focus loss / a stepper press, clamped into
    /// range. Half-typed values never reach `@AppStorage` or model
    /// observers. The default.
    case onCommit
}

/// Right-aligned numeric entry with monospaced digits, a unit column, the
/// DS row layout, an optional stepper and inline validation (danger border
/// + caption) instead of a silent parse failure. `help` is the tooltip;
/// `glossary` adds the "?" popover (`DS.Glossary`).
///
/// Three backing stores:
///   • `value: Binding<Double>` — parsed with `format`; written according
///     to `commit:` (see `DSCommitMode`), clamped into `range` on commit.
///   • `value: Binding<Int>`    — same for integers.
///   • `text: Binding<String>`  — the caller keeps the raw text (editors that
///     store parameters as strings); the field only reports validity, and
///     the caller may supply its own `error:` message (domain rules such as
///     "Mean must be > 0").
///
/// `stepper:` adds a Stepper: `.linear(d)` adds / subtracts `d` (an integer
/// or float literal is a linear step), `.multiplicative(f)` multiplies /
/// divides by `f` for log-scale quantities (a tolerance ε).
/// `emptyFor:` shows an empty field for a sentinel value (0 = "auto") and
/// writes that sentinel back when the field is committed empty.
/// `overrideToggle:` puts an enable switch before the field ("let the
/// solver choose" vs "set by hand"); the field, unit and label dim while
/// it is off. `onFocusChange` fires when keyboard focus enters or leaves.
struct DSNumericField: View {
    /// Stepper policy.
    enum Step: Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
        /// Add / subtract a fixed amount.
        case linear(Double)
        /// Multiply / divide by a factor — for quantities on a log scale.
        case multiplicative(Double)

        init(integerLiteral value: Int) { self = .linear(Double(value)) }
        init(floatLiteral value: Double) { self = .linear(value) }
    }

    private enum Store {
        case double(Binding<Double>, FloatingPointFormatStyle<Double>, ClosedRange<Double>?, Double?)
        case int(Binding<Int>, IntegerFormatStyle<Int>, ClosedRange<Int>?, Int?)
        case text(Binding<String>, ClosedRange<Double>?)
    }

    private let label: String
    private let caption: String?
    private let unit: String?
    private let help: String?
    private let placeholder: String
    private let width: CGFloat?
    private let store: Store
    private let glossary: String?
    private let validation: DSValidationMode
    private let commit: DSCommitMode
    private let stepper: Step?
    private let externalError: String?
    private let accessibilityLabel: String?
    private let onFocusChange: ((Bool) -> Void)?
    private let externalFocus: FocusState<Bool>.Binding?
    private let overrideToggle: Binding<Bool>?
    /// Mirror of the internal validation message for composite controls
    /// (`DSRangeFields`) that report one message for several fields.
    private let errorReport: Binding<String?>?

    /// Editing buffer for the value-backed stores.
    @State private var text: String = ""
    @State private var error: String?
    /// Transient advisory shown after the field itself changed the value
    /// (a commit outside `range` is clamped, not rejected).
    @State private var notice: String?
    @State private var noticeToken = 0
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    // Double -----------------------------------------------------------
    init(
        label: String,
        caption: String? = nil,
        value: Binding<Double>,
        unit: String? = nil,
        format: FloatingPointFormatStyle<Double> = .number,
        range: ClosedRange<Double>? = nil,
        stepper: Step? = nil,
        emptyFor: Double? = nil,
        validation: DSValidationMode = .live,
        commit: DSCommitMode = .onCommit,
        error: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        placeholder: String = "",
        width: CGFloat? = DS.Layout.fieldWidth,
        accessibilityLabel: String? = nil,
        overrideToggle: Binding<Bool>? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        errorReport: Binding<String?>? = nil
    ) {
        self.label = label
        self.caption = caption
        self.unit = unit
        self.help = help
        self.placeholder = placeholder
        self.width = width
        self.store = .double(value, format, range, emptyFor)
        self.validation = validation
        self.commit = commit
        self.stepper = stepper
        self.externalError = error
        self.accessibilityLabel = accessibilityLabel
        self.onFocusChange = onFocusChange
        self.glossary = glossary
        self.externalFocus = focus
        self.overrideToggle = overrideToggle
        self.errorReport = errorReport
    }

    // Int --------------------------------------------------------------
    init(
        label: String,
        caption: String? = nil,
        value: Binding<Int>,
        unit: String? = nil,
        format: IntegerFormatStyle<Int> = .number,
        range: ClosedRange<Int>? = nil,
        stepper: Step? = nil,
        emptyFor: Int? = nil,
        validation: DSValidationMode = .live,
        commit: DSCommitMode = .onCommit,
        error: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        placeholder: String = "",
        width: CGFloat? = DS.Layout.fieldWidth,
        accessibilityLabel: String? = nil,
        overrideToggle: Binding<Bool>? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        errorReport: Binding<String?>? = nil
    ) {
        self.label = label
        self.caption = caption
        self.unit = unit
        self.help = help
        self.placeholder = placeholder
        self.width = width
        self.store = .int(value, format, range, emptyFor)
        self.validation = validation
        self.commit = commit
        self.stepper = stepper
        self.externalError = error
        self.accessibilityLabel = accessibilityLabel
        self.onFocusChange = onFocusChange
        self.glossary = glossary
        self.externalFocus = focus
        self.overrideToggle = overrideToggle
        self.errorReport = errorReport
    }

    // String -----------------------------------------------------------
    init(
        label: String,
        caption: String? = nil,
        text: Binding<String>,
        unit: String? = nil,
        range: ClosedRange<Double>? = nil,
        stepper: Step? = nil,
        validation: DSValidationMode = .live,
        error: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        placeholder: String = "",
        width: CGFloat? = DS.Layout.fieldWidth,
        accessibilityLabel: String? = nil,
        overrideToggle: Binding<Bool>? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        errorReport: Binding<String?>? = nil
    ) {
        self.label = label
        self.caption = caption
        self.unit = unit
        self.help = help
        self.placeholder = placeholder
        self.width = width
        self.store = .text(text, range)
        self.validation = validation
        self.commit = .onCommit
        self.stepper = stepper
        self.externalError = error
        self.accessibilityLabel = accessibilityLabel
        self.onFocusChange = onFocusChange
        self.glossary = glossary
        self.externalFocus = focus
        self.overrideToggle = overrideToggle
        self.errorReport = errorReport
    }

    private var fieldEnabled: Bool { isEnabled && (overrideToggle?.wrappedValue ?? true) }


    /// True while the field has focus and its text is a legal *prefix* of
    /// a number ("", "-", "0.", "1e", "1e-"): the user is mid-number.
    private var isMidNumber: Bool {
        isFocused && DS.Number.isPartialNumber(textBinding.wrappedValue)
    }

    /// The message actually drawn (danger border + caption). Suppressed
    /// mid-number so typing `1e-3` never flashes red on the `e` and `-`
    /// keystrokes, and clearing a field to retype does not turn it red.
    /// This covers the caller-supplied `error:` too — sheets recompute
    /// theirs on every keystroke, so without this the internal tolerance
    /// (`validate(tolerant:)`) would be defeated by the external message.
    /// Leaving the field (or a stepper press) commits, focus drops, and a
    /// still-incomplete value shows its error normally.
    private var shownError: String? {
        guard fieldEnabled, !isMidNumber else { return nil }
        return externalError ?? error
    }

    /// The clamp notice (warning caption). Like `shownError` it stays quiet
    /// while the number is still being typed.
    private var shownNotice: String? {
        guard fieldEnabled, !isMidNumber else { return nil }
        return notice
    }
    private var isFocused: Bool { externalFocus?.wrappedValue ?? focused }
    private var a11yName: String { accessibilityLabel ?? label }

    var body: some View {
        DSInspectorRow(label: label, caption: caption, help: help, glossary: glossary,
                       error: shownError, warning: shownNotice, labelDimmed: !fieldEnabled) {
            HStack(spacing: DS.Spacing.xs) {
                if let overrideToggle {
                    Toggle(isOn: overrideToggle) { Text(label) }
                        .labelsHidden()
                        .controlSize(.small)
                        .help(overrideToggle.wrappedValue
                              ? "Override on — turn off to let the solver choose \(label)"
                              : "Override off — turn on to set \(label) by hand")
                        .accessibilityLabel("Override \(label)")
                        .padding(.trailing, DS.Spacing.xs)
                }

                TextField("", text: textBinding, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .focused(externalFocus ?? $focused)
                    .onSubmit { commitEditing() }
                    .validatedFieldBorder(isInvalid: shownError != nil)
                    .help(help ?? label)
                    .accessibilityLabel(a11yName)
                    .accessibilityValue(unit.map { "\(textBinding.wrappedValue) \($0)" } ?? textBinding.wrappedValue)
                    .accessibilityHint(help ?? "")
                    .disabled(!fieldEnabled)

                if let stepper {
                    stepperControl(stepper)
                }

                DSUnitColumn(unit: unit, dimmed: !fieldEnabled)
            }
        }
        .onAppear { syncFromValue(force: true) }
        // The window closing (⌘W) or the pane switching tears the row down
        // without a guaranteed focus-change event, so a value typed and not
        // tabbed out of would never reach its binding. `commitEditing` is
        // idempotent: it clamps, writes once and rewrites canonical text.
        // No clamp advisory on this path — a caption on a view being torn
        // down is invisible.
        .onDisappear { commitEditing(announceClamp: false) }
        .onChange(of: externalValueKey) { _, _ in syncFromValue(force: false) }
        .onChange(of: isFocused) { _, nowFocused in
            onFocusChange?(nowFocused)
            if !nowFocused { commitEditing() }
        }
        .onChange(of: textBinding.wrappedValue) { _, _ in
            // A new keystroke supersedes the "clamped to …" advisory.
            if notice != nil { notice = nil }
            if validation == .live { validate(tolerant: true) }
            if commit == .onEdit { writeIfValid() }
        }
    }

    // MARK: Binding plumbing

    /// The text the field edits: the caller's string for `.text`, our own
    /// buffer for the value-backed stores.
    private var textBinding: Binding<String> {
        switch store {
        case .text(let binding, _): return binding
        case .double, .int: return $text
        }
    }

    /// A string key that changes whenever the bound value changes outside
    /// the field (e.g. Restore Defaults), so the buffer can follow.
    private var externalValueKey: String {
        switch store {
        case .double(let b, let f, _, _): return f.format(b.wrappedValue)
        case .int(let b, let f, _, _):    return f.format(b.wrappedValue)
        case .text(let b, _):             return b.wrappedValue
        }
    }

    /// Canonical text for the stored value ("" for the `emptyFor` sentinel).
    private func formatted() -> String {
        switch store {
        case .double(let b, let f, _, let sentinel):
            if let sentinel, b.wrappedValue == sentinel { return "" }
            return f.format(b.wrappedValue)
        case .int(let b, let f, _, let sentinel):
            if let sentinel, b.wrappedValue == sentinel { return "" }
            return f.format(b.wrappedValue)
        case .text(let b, _):
            return b.wrappedValue
        }
    }

    /// Say what the field did when a committed value was outside `range`:
    /// clamping is not a silent correction, and the advisory fades on its
    /// own (or on the next keystroke) so it never becomes chrome.
    private func showClampNotice(_ value: String) {
        noticeToken += 1
        let token = noticeToken
        notice = "Clamped to \(value)\(unitSuffix)"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard noticeToken == token else { return }
            withAnimation(DS.Motion.quick) { notice = nil }
        }
    }

    private func setError(_ message: String?) {
        if error != message { error = message }
        if let errorReport, errorReport.wrappedValue != message { errorReport.wrappedValue = message }
    }

    private func syncFromValue(force: Bool) {
        switch store {
        case .double(let b, _, _, _):
            if force || parseDouble(text) != b.wrappedValue { text = formatted() }
        case .int(let b, _, _, _):
            if force || parseInt(text) != b.wrappedValue { text = formatted() }
        case .text:
            break
        }
        validate(tolerant: true)
    }

    /// Return / focus loss. Value stores: clamp into range, write once,
    /// rewrite the field in canonical form; unparsable text reverts;
    /// empty text writes the `emptyFor` sentinel when there is one. Text
    /// stores: strict validation only — the caller owns the text.
    ///
    /// A disabled field (its override switch off, or `.disabled` from the
    /// environment) never writes: the user has switched it off, so merely
    /// opening and closing the window must not parse the displayed text
    /// and write back a clamped value they never asked for.
    private func commitEditing(announceClamp: Bool = true) {
        guard fieldEnabled else { return }
        switch store {
        case .text:
            validate(tolerant: false)
        case .double(let b, let f, let range, let sentinel):
            let raw = text.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty, let sentinel {
                if b.wrappedValue != sentinel { b.wrappedValue = sentinel }
            } else if let v = parseDouble(raw) {
                let clamped = clamp(v, range)
                if clamped != b.wrappedValue { b.wrappedValue = clamped }
                if clamped != v, announceClamp { showClampNotice(f.format(clamped)) }
            }
            text = formatted()
            setError(nil)
        case .int(let b, let f, let range, let sentinel):
            let raw = text.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty, let sentinel {
                if b.wrappedValue != sentinel { b.wrappedValue = sentinel }
            } else if let v = parseInt(raw) {
                let clamped = clamp(v, range)
                if clamped != b.wrappedValue { b.wrappedValue = clamped }
                if clamped != v, announceClamp { showClampNotice(f.format(clamped)) }
            }
            text = formatted()
            setError(nil)
        }
    }

    /// `.onEdit` commit: write the binding when the text parses and lies in
    /// range; otherwise leave the stored value and the caption alone.
    private func writeIfValid() {
        guard error == nil else { return }
        switch store {
        case .double(let b, _, let range, _):
            if let v = parseDouble(text), range?.contains(v) ?? true, v != b.wrappedValue { b.wrappedValue = v }
        case .int(let b, _, let range, _):
            if let v = parseInt(text), range?.contains(v) ?? true, v != b.wrappedValue { b.wrappedValue = v }
        case .text:
            break
        }
    }

    /// Stepper: start from the typed value when it parses, otherwise from
    /// the stored one, then commit immediately.
    private func step(_ direction: Double) {
        guard let stepper else { return }
        func advance(_ base: Double) -> Double {
            switch stepper {
            case .linear(let d):              return base + d * direction
            case .multiplicative(let factor): return direction > 0 ? base * factor : base / factor
            }
        }
        switch store {
        case .double(let b, _, let range, _):
            let v = clamp(tidied(advance(parseDouble(text) ?? b.wrappedValue)), range)
            b.wrappedValue = v
            syncFromValue(force: true)
        case .int(let b, _, let range, _):
            let base = Double(parseInt(text) ?? b.wrappedValue)
            let v = clamp(Int(advance(base).rounded()), range)
            b.wrappedValue = v
            syncFromValue(force: true)
        case .text(let b, let range):
            let v = clamp(tidied(advance(parseDouble(b.wrappedValue) ?? 0)), range)
            b.wrappedValue = DS.Number.fieldText(v)
            validate(tolerant: false)
        }
    }

    // MARK: Stepper

    /// The stepper beside the field. A linear step over a bounded range is
    /// the native `Stepper(value:in:step:)`, so the arrow greys out at the
    /// bound instead of clicking silently; the proxy binding starts from
    /// the typed text (not just the stored value) and routes the write
    /// through the same clamp-and-canonicalise path as Return. A
    /// multiplicative step has no native form, so it keeps the increment /
    /// decrement closures and disables itself when neither direction can
    /// move the value.
    @ViewBuilder
    private func stepperControl(_ policy: Step) -> some View {
        switch (policy, store) {
        case (.linear(let d), .double(_, _, .some(let range), _)):
            Stepper(label, value: doubleStepProxy(range), in: range, step: d)
                .labelsHidden()
                .accessibilityLabel("\(a11yName) stepper")
                .disabled(!fieldEnabled)
        case (.linear(let d), .int(_, _, .some(let range), _)):
            Stepper(label, value: intStepProxy(range), in: range, step: max(1, Int(d.rounded())))
                .labelsHidden()
                .accessibilityLabel("\(a11yName) stepper")
                .disabled(!fieldEnabled)
        default:
            Stepper(label, onIncrement: { step(+1) }, onDecrement: { step(-1) })
                .labelsHidden()
                .accessibilityLabel("\(a11yName) stepper")
                .disabled(!fieldEnabled || !canStep(policy))
        }
    }

    private func doubleStepProxy(_ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: {
                guard case .double(let b, _, _, _) = store else { return range.lowerBound }
                return clamp(parseDouble(text) ?? b.wrappedValue, range)
            },
            set: { newValue in
                guard case .double(let b, _, _, _) = store else { return }
                b.wrappedValue = clamp(tidied(newValue), range)
                syncFromValue(force: true)
            }
        )
    }

    private func intStepProxy(_ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: {
                guard case .int(let b, _, _, _) = store else { return range.lowerBound }
                return clamp(parseInt(text) ?? b.wrappedValue, range)
            },
            set: { newValue in
                guard case .int(let b, _, _, _) = store else { return }
                b.wrappedValue = clamp(newValue, range)
                syncFromValue(force: true)
            }
        )
    }

    /// True while at least one direction of a closure-driven stepper would
    /// change the value (a multiplicative step at both ends of its range
    /// cannot, so the control greys out).
    private func canStep(_ policy: Step) -> Bool {
        func moves(_ base: Double, _ range: ClosedRange<Double>?) -> Bool {
            switch policy {
            case .linear(let d):
                return clamp(base + d, range) != base || clamp(base - d, range) != base
            case .multiplicative(let f):
                guard f > 0, f != 1 else { return false }
                return clamp(base * f, range) != base || clamp(base / f, range) != base
            }
        }
        switch store {
        case .double(let b, _, let range, _):
            return moves(parseDouble(text) ?? b.wrappedValue, range)
        case .int(let b, _, let range, _):
            let r = range.map { Double($0.lowerBound)...Double($0.upperBound) }
            return moves(Double(parseInt(text) ?? b.wrappedValue), r)
        case .text(let b, let range):
            return moves(parseDouble(b.wrappedValue) ?? 0, range)
        }
    }

    /// Round away the floating-point noise repeated steps accumulate.
    private func tidied(_ v: Double) -> Double {
        let scale = 1_000_000_000.0
        return (v * scale).rounded() / scale
    }

    private func validate(tolerant: Bool) {
        let raw = textBinding.wrappedValue.trimmingCharacters(in: .whitespaces)
        if tolerant && DS.Number.isPartialNumber(raw) { setError(nil); return }
        switch store {
        case .double(_, let f, let range, let sentinel):
            if raw.isEmpty { setError(sentinel != nil || tolerant ? nil : "Enter a number"); return }
            guard let v = parseDouble(raw) else { setError("Enter a number"); return }
            setError(rangeError(v, range, format: f))
        case .int(_, _, let range, let sentinel):
            if raw.isEmpty { setError(sentinel != nil || tolerant ? nil : "Enter a whole number"); return }
            guard let v = parseInt(raw) else { setError("Enter a whole number"); return }
            setError(rangeError(v, range))
        case .text(_, let range):
            if raw.isEmpty { setError(nil); return }
            guard let v = parseDouble(raw) else { setError("Enter a number"); return }
            setError(rangeError(v, range, format: nil))
        }
    }

    private func rangeError(_ v: Double, _ range: ClosedRange<Double>?, format: FloatingPointFormatStyle<Double>?) -> String? {
        guard let range, !range.contains(v) else { return nil }
        let lo = format.map { $0.format(range.lowerBound) } ?? DS.Number.format(range.lowerBound)
        let hi = format.map { $0.format(range.upperBound) } ?? DS.Number.format(range.upperBound)
        return "Must be between \(lo) and \(hi)\(unitSuffix)"
    }

    private func rangeError(_ v: Int, _ range: ClosedRange<Int>?) -> String? {
        guard let range, !range.contains(v) else { return nil }
        return "Must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted())\(unitSuffix)"
    }

    private var unitSuffix: String {
        guard let unit, !unit.isEmpty else { return "" }
        return " \(unit)"
    }

    private func clamp(_ v: Double, _ range: ClosedRange<Double>?) -> Double {
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func clamp(_ v: Int, _ range: ClosedRange<Int>?) -> Int {
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let v = DS.Number.parse(t) { return v }
        if case .double(_, let f, _, _) = store, let v = try? f.parseStrategy.parse(t) { return v }
        return nil
    }

    private func parseInt(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let v = DS.Number.parseInt(t) { return v }
        if case .int(_, let f, _, _) = store, let v = try? f.parseStrategy.parse(t) { return v }
        // "1e3" typed into an integer field.
        if let d = DS.Number.parse(t), d == d.rounded(), abs(d) < 9e15 { return Int(d) }
        return nil
    }
}

// MARK: - Range pair

/// "min … max" pair of numeric fields for one row — the only way a closed
/// range is edited in Qnet (Settings ▸ Test Sets, the Test-menu sheets).
/// Each field is a `DSNumericField` in `.bare` layout at
/// `DS.Layout.compactFieldWidth`; the row shows one message: a field's own
/// range error first (it concerns what is being typed), then the ordering
/// rule (`lo ≤ hi`, or `lo < hi` when `strict`). In `.bare` layout only
/// the pair is drawn and the caller reports problems (sheet footer).
struct DSRangeFields: View {
    private enum Store {
        case int(Binding<Int>, Binding<Int>, ClosedRange<Int>)
        case double(Binding<Double>, Binding<Double>, ClosedRange<Double>, FloatingPointFormatStyle<Double>, DSNumericField.Step?)
    }

    private let label: String
    private let caption: String?
    private let store: Store
    private let unit: String?
    private let help: String?
    private let glossary: String?
    private let separator: String
    private let strict: Bool
    private let orderMessage: String
    private let accessibilityLabel: String?

    @State private var loError: String?
    @State private var hiError: String?
    @Environment(\.dsRowLayout) private var layout

    init(
        label: String,
        caption: String? = nil,
        lower: Binding<Int>,
        upper: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String? = nil,
        separator: String = "…",
        strict: Bool = false,
        orderMessage: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.label = label
        self.caption = caption
        self.store = .int(lower, upper, range)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.separator = separator
        self.strict = strict
        self.orderMessage = orderMessage ?? (strict ? "End must be greater than start" : "Minimum must not exceed maximum")
        self.accessibilityLabel = accessibilityLabel
    }

    init(
        label: String,
        caption: String? = nil,
        lower: Binding<Double>,
        upper: Binding<Double>,
        range: ClosedRange<Double>,
        format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(2)),
        stepper: DSNumericField.Step? = nil,
        unit: String? = nil,
        separator: String = "…",
        strict: Bool = false,
        orderMessage: String? = nil,
        help: String? = nil,
        glossary: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.label = label
        self.caption = caption
        self.store = .double(lower, upper, range, format, stepper)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.separator = separator
        self.strict = strict
        self.orderMessage = orderMessage ?? (strict ? "End must be greater than start" : "Minimum must not exceed maximum")
        self.accessibilityLabel = accessibilityLabel
    }

    private var orderError: String? {
        switch store {
        case .int(let lo, let hi, _):
            return (strict ? lo.wrappedValue >= hi.wrappedValue : lo.wrappedValue > hi.wrappedValue) ? orderMessage : nil
        case .double(let lo, let hi, _, _, _):
            return (strict ? lo.wrappedValue >= hi.wrappedValue : lo.wrappedValue > hi.wrappedValue) ? orderMessage : nil
        }
    }

    private var shownError: String? { loError ?? hiError ?? orderError }
    private var name: String { accessibilityLabel ?? label }

    var body: some View {
        DSInspectorRow(label: label, caption: caption, help: help, glossary: glossary, error: shownError) {
            HStack(spacing: DS.Spacing.xs) {
                field(isLower: true)
                Text(separator)
                    .foregroundStyle(DS.Color.textSecondary)
                    .accessibilityHidden(true)
                field(isLower: false)
                DSUnitColumn(unit: unit, dimmed: false)
            }
            .help(help ?? label)
            .dsAnimation(DS.Motion.quick, value: shownError)
        }
    }

    @ViewBuilder
    private func field(isLower: Bool) -> some View {
        let a11y = "\(name) \(isLower ? "minimum" : "maximum")"
        switch store {
        case .int(let lo, let hi, let range):
            DSNumericField(
                label: a11y, value: isLower ? lo : hi, range: range,
                help: help, width: DS.Layout.compactFieldWidth,
                accessibilityLabel: a11y,
                errorReport: isLower ? $loError : $hiError
            )
            .dsRowLayout(.bare)
        case .double(let lo, let hi, let range, let format, let stepper):
            DSNumericField(
                label: a11y, value: isLower ? lo : hi, format: format, range: range,
                stepper: stepper, help: help, width: DS.Layout.compactFieldWidth,
                accessibilityLabel: a11y,
                errorReport: isLower ? $loError : $hiError
            )
            .dsRowLayout(.bare)
        }
    }
}

// MARK: - Search field

/// The one search / filter field (Status pane filter, Settings sidebar,
/// Qnet Help, Find Node). Magnifier, plain text field, clear button once
/// there is text, accent border while focused. `shortcutHint` ("⌘F") is
/// spoken in the tooltip, never typed into the placeholder.
///
/// Escape: with `escapeClears` (default) Escape clears the text while the
/// field has focus; pass `false` inside a sheet whose Escape must cancel
/// the sheet. `clearsOnWindowEscape` binds the clear button to the
/// window-wide Escape as well — only for windows whose Escape has no other
/// meaning (Help), never the main window.
struct DSSearchField: View {
    @Binding var text: String
    let placeholder: String
    let shortcutHint: String?
    let help: String?
    /// Match position, drawn inside the bezel before the clear button and
    /// spoken as the field's accessibility value ("3 of 5"). Settings and
    /// the Status pane both cycle matches, so both show one.
    let status: String?
    let accessibilityLabel: String?
    let escapeClears: Bool
    let clearsOnWindowEscape: Bool
    let onSubmit: (() -> Void)?
    /// Shift-Return. A field that cycles matches steps backward here,
    /// mirroring Return, as every macOS find field does (Safari, Xcode,
    /// Finder). When nil, Shift-Return is left to the text field.
    let onShiftSubmit: (() -> Void)?
    let externalFocus: FocusState<Bool>.Binding?

    @FocusState private var focused: Bool
    @State private var isHovering = false
    @State private var clearHovering = false

    init(
        text: Binding<String>,
        placeholder: String = "Search",
        shortcutHint: String? = nil,
        help: String? = nil,
        status: String? = nil,
        accessibilityLabel: String? = nil,
        escapeClears: Bool = true,
        clearsOnWindowEscape: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil,
        onShiftSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.shortcutHint = shortcutHint
        self.help = help
        self.status = status
        self.accessibilityLabel = accessibilityLabel
        self.escapeClears = escapeClears
        self.clearsOnWindowEscape = clearsOnWindowEscape
        self.externalFocus = focus
        self.onSubmit = onSubmit
        self.onShiftSubmit = onShiftSubmit
    }

    private var isFocused: Bool { externalFocus?.wrappedValue ?? focused }

    private var tooltip: String {
        var s = help ?? placeholder
        if let shortcutHint, !shortcutHint.isEmpty { s += " (\(shortcutHint))" }
        if escapeClears { s += ". Escape clears." }
        return s
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .focused(externalFocus ?? $focused)
            .onSubmit { onSubmit?() }
            // Consumed before the text field sees it, so a Shift-Return
            // never also fires `onSubmit` and steps forward.
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift), let onShiftSubmit else { return .ignored }
                onShiftSubmit()
                return .handled
            }
            .accessibilityLabel(accessibilityLabel ?? placeholder)
            .accessibilityValue(status ?? "")
        if escapeClears {
            base.onExitCommand { text = "" }
        } else {
            base
        }
    }

    @DSAccessibility private var a11y

    private var bezel: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: DS.Symbol.find)
                .font(DS.Font.chrome)
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityHidden(true)
            field
            if let status, !status.isEmpty {
                Text(status)
                    .font(DS.Font.numberSmall)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if !text.isEmpty {
                if clearsOnWindowEscape {
                    clearButton.keyboardShortcut(.cancelAction)
                } else {
                    clearButton
                }
            }
        }
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: DS.Layout.controlHeight)
        // Recessed NSSearchField bezel: the field ground sits inside a
        // hairline, and a hovered but unfocused field lifts very slightly
        // so the target is discoverable without a border change.
        .background(bezel.fill(DS.Color.fieldBackground))
        .background(bezel.fill(isHovering && !isFocused ? DS.Color.hoverFill(a11y.contrast) : .clear))
        // `strokeBorder`, not `stroke`: a stroke is centred on the path, so
        // half of the bezel line used to be painted over the field ground
        // the text sits on.
        .overlay(
            bezel.strokeBorder(isFocused ? DS.Color.accentStroke : DS.Color.controlBorder(a11y.contrast),
                               lineWidth: DS.Stroke.hairline(a11y.contrast))
        )
        .dsFocusRing(isFocused, radius: DS.Radius.control)
        .onHover { hovering in
            withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
        }
        .dsAnimation(DS.Motion.quick, value: isFocused)
        .dsAnimation(DS.Motion.quick, value: text.isEmpty)
        .dsAnimation(DS.Motion.quick, value: status)
        .help(tooltip)
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            Image(systemName: DS.Symbol.clearField)
                .font(DS.Font.chrome)
                .foregroundStyle(clearHovering ? DS.Color.textPrimary : DS.Color.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(a11y.animation(DS.Motion.quick)) { clearHovering = hovering }
        }
        .dsTooltip("Clear search")
    }
}

// MARK: - Text area

/// The one multi-line text control (Settings ▸ AI Assistant ▸ System
/// prompt). Before it existed the app's only `TextEditor` drew its own
/// background, border and height literals — the single field chrome not
/// produced by this file.
///
/// The label sits above the well rather than beside it: a control that is
/// five lines tall does not belong in the trailing slot of a
/// `LabeledContent`, and the well then spans the full row like the text
/// areas in System Settings. Chrome matches `.roundedBorder`
/// (`DS.Color.fieldBackground` inside a `DS.Color.controlBorder` hairline)
/// and the focus treatment is the same soft ring as `DSSearchField`, so a
/// Full Keyboard Access user sees the ring they see everywhere else.
///
/// In the `.form` row layout the reserved "?" column applies here as it
/// does to every `DSInspectorRow`: the glossary slot sits at the
/// top-trailing corner, level with the "?" of the field rows above and
/// below, and the well stops `DS.Layout.glossaryColumnWidth` short of the
/// row's trailing edge so it ends at the same x as those fields. In the
/// other layouts the "?" sits beside the label and the well spans the row.
///
/// Height is given in lines (`DS.Layout.textAreaLineHeight` each): the
/// well opens at `minLines` and grows with its content to `maxLines`,
/// after which it scrolls.
struct DSTextArea: View {
    let label: String
    let caption: String?
    @Binding var text: String
    let minLines: Int
    let maxLines: Int
    let monospaced: Bool
    let help: String?
    let glossary: String?
    let error: String?

    @Environment(\.dsRowLayout) private var layout
    @FocusState private var focused: Bool
    @DSAccessibility private var a11y

    init(
        label: String,
        caption: String? = nil,
        text: Binding<String>,
        minLines: Int = 5,
        maxLines: Int = 10,
        monospaced: Bool = false,
        help: String? = nil,
        glossary: String? = nil,
        error: String? = nil
    ) {
        self.label = label
        self.caption = caption
        self._text = text
        self.minLines = minLines
        self.maxLines = max(minLines, maxLines)
        self.monospaced = monospaced
        self.help = help
        self.glossary = glossary
        self.error = error
    }

    private var bezel: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
    }

    /// Trailing inset of the well and its message in `.form`: the reserved
    /// "?" column plus the gap every field row leaves before it.
    private var trailingInset: CGFloat {
        layout == .form ? DS.Layout.glossaryColumnWidth + DS.Spacing.s : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if layout == .form {
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    DSRowLabel(label, caption: caption)
                    Spacer(minLength: 0)
                    // Reserved whether or not there is an entry, like the
                    // slot on every other `.form` row.
                    DSGlossarySlot(label: label, text: glossary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    DSRowLabel(label, caption: caption)
                    if let glossary, !glossary.isEmpty {
                        DSGlossaryButton(label: label, text: glossary)
                    }
                    Spacer(minLength: 0)
                }
            }

            TextEditor(text: $text)
                .font(monospaced ? DS.Font.mono : DS.Font.body)
                .scrollContentBackground(.hidden)
                .padding(DS.Spacing.xs)
                .frame(minHeight: CGFloat(minLines) * DS.Layout.textAreaLineHeight,
                       maxHeight: CGFloat(maxLines) * DS.Layout.textAreaLineHeight)
                .focused($focused)
                .background(bezel.fill(DS.Color.fieldBackground))
                .overlay(
                    bezel.strokeBorder(
                        error != nil ? DS.Color.danger
                                     : (focused ? DS.Color.accentStroke : DS.Color.controlBorder(a11y.contrast)),
                        lineWidth: error != nil ? DS.Stroke.hairlineBold : DS.Stroke.hairline(a11y.contrast))
                )
                .dsFocusRing(focused, radius: DS.Radius.control)
                .dsAnimation(DS.Motion.quick, value: focused)
                .help(help ?? label)
                .accessibilityLabel(label)
                .accessibilityHint(help ?? "")
                .padding(.trailing, trailingInset)

            InlineFieldMessage(message: error, severity: .error)
                .padding(.trailing, trailingInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
