import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// One sheet for every "configure this run, then go" dialog in the Run, File ▸
// Export and Network menus. Before this, each solver built an `NSAlert` with an
// `NSGridView` accessory (AlertFormBuilder): a modal alert with AppKit fields,
// no inline validation, no glossary popovers and Return/Esc semantics that
// differed from the DSSheet inspectors. The Run menu is the most-used path in
// the app, so it now uses the same chrome as Generate Random Network, Find
// Node, Export SRBM and the two inspectors.
//
// A caller describes the form (`RunParameterSpec`) and gets the collected
// values back in a closure; nothing about solver launching, shell-script
// generation or output parsing goes through here.
//
//     presentRunParameters(
//         RunParameterSpec(title: "Run Spectral Method", …),
//         onSetDefault: { v in appSettings.smDegree = v.int("degree") },
//         onCancel:     { editor.addStatus("Spectral run cancelled.", severity: .warning) }
//     ) { v in
//         let degree = v.int("degree")   // …unchanged run logic…
//     }
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Values

/// Type-tagged bag of collected values, keyed by the field's `key`.
/// Integers cover both counts and popup selections (the selected index),
/// which keeps the call sites reading exactly like the old
/// `popup.indexOfSelectedItem` / `Int(field.stringValue)` code.
struct RunParameterValues: Equatable {
    enum Value: Equatable {
        case int(Int)
        case double(Double)
        case flag(Bool)
    }

    private(set) var storage: [String: Value] = [:]

    init(_ storage: [String: Value] = [:]) { self.storage = storage }

    func int(_ key: String, default fallback: Int = 0) -> Int {
        if case .int(let v)? = storage[key] { return v }
        return fallback
    }

    func double(_ key: String, default fallback: Double = 0) -> Double {
        if case .double(let v)? = storage[key] { return v }
        return fallback
    }

    func flag(_ key: String, default fallback: Bool = false) -> Bool {
        if case .flag(let v)? = storage[key] { return v }
        return fallback
    }

    mutating func set(_ key: String, _ value: Value) { storage[key] = value }
}

// MARK: - Spec

/// One row of a run-parameter sheet.
struct RunParameterField: Identifiable {
    enum Kind {
        /// Integer entry with a stepper. `emptyFor` shows a blank field for
        /// a sentinel value (0 = "auto") and writes it back when cleared.
        case integer(range: ClosedRange<Int>, step: Int = 1, emptyFor: Int? = nil)
        /// Decimal entry with a stepper.
        case decimal(range: ClosedRange<Double>, step: Double)
        /// Menu picker; the value is the selected index.
        case choice([String])
        /// Switch.
        case flag
    }

    var id: String { key }
    let key: String
    let title: String
    let kind: Kind
    /// Tooltip on the row (every control carries one).
    var help: String?
    /// Adds the "?" glossary popover to a numeric field (`DS.Glossary`).
    var glossary: String?
    /// Trailing unit column ("events", "time units").
    var unit: String?

    init(_ key: String, _ title: String, _ kind: Kind,
         help: String? = nil, glossary: String? = nil, unit: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.help = help
        self.glossary = glossary
        self.unit = unit
    }
}

/// A titled group of fields, matching the grouped `Form` sections used by
/// the inspectors and the Generate Random Network sheet.
struct RunParameterSection: Identifiable {
    var id: String { title + (footer ?? "") }
    let title: String
    var footer: String?
    var fields: [RunParameterField]

    init(_ title: String, footer: String? = nil, fields: [RunParameterField]) {
        self.title = title
        self.footer = footer
        self.fields = fields
    }
}

/// Everything the sheet needs to render itself.
struct RunParameterSpec {
    let title: String
    /// One- or two-line description under the title (what the run does).
    let subtitle: String
    /// Qnet Help topic for the method this dialog configures. Rendered as
    /// the footer's "Help" button, so a reader stuck on "Polynomial
    /// degree" can reach the page that explains the method without
    /// cancelling the run.
    var helpTopic: HelpTopic?
    var systemImage: String = DS.Symbol.runCircle
    var tint: Color = DS.Color.info
    var confirmTitle: String = "Run"
    var confirmHelp: String = "Start the run with these parameters (Return)"
    var cancelHelp: String = "Close without running (Esc)"
    var size: DSSheetSize = .regular
    var sections: [RunParameterSection]
    /// Starting values, keyed like the fields.
    var values: RunParameterValues

    /// Convenience: build `values` from a key → value dictionary.
    init(title: String,
         subtitle: String,
         helpTopic: HelpTopic? = nil,
         systemImage: String = DS.Symbol.runCircle,
         tint: Color = DS.Color.info,
         confirmTitle: String = "Run",
         confirmHelp: String = "Start the run with these parameters (Return)",
         cancelHelp: String = "Close without running (Esc)",
         size: DSSheetSize = .regular,
         sections: [RunParameterSection],
         values: [String: RunParameterValues.Value]) {
        self.title = title
        self.subtitle = subtitle
        self.helpTopic = helpTopic
        self.systemImage = systemImage
        self.tint = tint
        self.confirmTitle = confirmTitle
        self.confirmHelp = confirmHelp
        self.cancelHelp = cancelHelp
        self.size = size
        self.sections = sections
        self.values = RunParameterValues(values)
    }
}

/// A presented sheet: the form plus what to do with the answer. Identifiable
/// so it can drive `.sheet(item:)` from the App scene.
struct RunParameterRequest: Identifiable {
    let id = UUID()
    let spec: RunParameterSpec
    /// Shown as the footer's leading "Set as Default" button when non-nil;
    /// writes the current values into `AppSettings`.
    let onSetDefault: ((RunParameterValues) -> Void)?
    let onCancel: () -> Void
    let onRun: (RunParameterValues) -> Void
}

// MARK: - Sheet

/// The DSSheet rendering of a `RunParameterSpec`: 44-pt glyph header,
/// grouped Form of DS controls, footer with the first blocking problem,
/// an optional "Set as Default" button, Cancel (Esc) and Run (Return).
struct RunParameterSheet: View {
    let request: RunParameterRequest

    @State private var values: RunParameterValues
    /// Flashes on the "Set as Default" button for a moment after a save,
    /// the same confirmation the old AppKit push button gave.
    @State private var savedDefaults = false

    init(request: RunParameterRequest) {
        self.request = request
        _values = State(initialValue: request.spec.values)
    }

    private var spec: RunParameterSpec { request.spec }

    private var allFields: [RunParameterField] { spec.sections.flatMap(\.fields) }

    /// First out-of-range value, named in the footer. DSNumericField clamps
    /// on commit, so this normally stays nil — it is the backstop for a
    /// field left mid-edit.
    private var problem: String? {
        for field in allFields {
            switch field.kind {
            case .integer(let range, _, let emptyFor):
                let v = values.int(field.key)
                if v == emptyFor { continue }
                if !range.contains(v) {
                    return "\(field.title) must be between \(range.lowerBound) and \(range.upperBound)."
                }
            case .decimal(let range, _):
                let v = values.double(field.key)
                if !range.contains(v) {
                    return "\(field.title) must be between "
                        + DS.Number.format(range.lowerBound) + " and "
                        + DS.Number.format(range.upperBound) + "."
                }
            case .choice, .flag:
                continue
            }
        }
        return nil
    }

    var body: some View {
        DSSheet {
            DSSheetHeader(spec.title, subtitle: spec.subtitle) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(spec.tint),
                                   systemImage: spec.systemImage,
                                   tint: DS.Color.legibleTint(spec.tint))
            }
        } content: {
            Form {
                ForEach(spec.sections) { section in
                    Section {
                        ForEach(section.fields) { field in
                            row(field)
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if let footer = section.footer {
                            Text(footer)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            // The footer's `helpTopic:` slot renders the Mac help control
            // (the round "?" in the bottom-left corner) that opens Qnet
            // Help at this method's page. A scientific dialog should never
            // be a dead end — the fields name quantities (polynomial
            // degree, grid size n, basis size m) that are only defined
            // in the method's page.
            DSSheetFooter(
                problem: problem,
                helpTopic: spec.helpTopic,
                confirmTitle: spec.confirmTitle,
                canConfirm: problem == nil,
                cancelHelp: spec.cancelHelp,
                confirmHelp: spec.confirmHelp,
                blockedHelp: "Fix the highlighted values to run",
                onCancel: request.onCancel,
                onConfirm: { request.onRun(values) }
            ) {
                setAsDefaultButton
            }
        }
        .dsSheetFrame(spec.size)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ field: RunParameterField) -> some View {
        switch field.kind {
        case .integer(let range, let step, let emptyFor):
            LabeledContent(field.title) {
                DSNumericField(
                    label: field.title,
                    value: intBinding(field.key),
                    unit: field.unit,
                    range: range,
                    stepper: .linear(Double(step)),
                    emptyFor: emptyFor,
                    help: field.help,
                    glossary: field.glossary,
                    width: DS.Layout.fieldWidth,
                    accessibilityLabel: field.title
                )
                .dsRowLayout(.bare)
            }
            .help(field.help ?? field.title)

        case .decimal(let range, let step):
            LabeledContent(field.title) {
                DSNumericField(
                    label: field.title,
                    value: doubleBinding(field.key),
                    unit: field.unit,
                    range: range,
                    stepper: .linear(step),
                    help: field.help,
                    glossary: field.glossary,
                    width: DS.Layout.fieldWidth,
                    accessibilityLabel: field.title
                )
                .dsRowLayout(.bare)
            }
            .help(field.help ?? field.title)

        case .choice(let titles):
            Picker(field.title, selection: intBinding(field.key)) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            .pickerStyle(.menu)
            .help(field.help ?? field.title)
            .accessibilityLabel(field.title)

        case .flag:
            Toggle(field.title, isOn: flagBinding(field.key))
                .toggleStyle(.switch)
                .help(field.help ?? field.title)
                .accessibilityLabel(field.title)
        }
    }

    @ViewBuilder
    private var setAsDefaultButton: some View {
        if let onSetDefault = request.onSetDefault {
            Button(savedDefaults ? "Saved as Default" : "Set as Default") {
                onSetDefault(values)
                withAnimation(DS.Motion.quick) { savedDefaults = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(DS.Motion.quick) { savedDefaults = false }
                }
            }
            .disabled(savedDefaults || problem != nil)
            .help("Remember these values as the defaults for this dialog and Settings")
            .accessibilityLabel("Set as default")
        }
    }

    // MARK: Bindings

    private func intBinding(_ key: String) -> Binding<Int> {
        Binding(get: { values.int(key) }, set: { values.set(key, .int($0)) })
    }

    private func doubleBinding(_ key: String) -> Binding<Double> {
        Binding(get: { values.double(key) }, set: { values.set(key, .double($0)) })
    }

    private func flagBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { values.flag(key) }, set: { values.set(key, .flag($0)) })
    }
}
