import Foundation

/// How the user is currently entering distribution parameters in the
/// editor. Pure UI state — the .bnet file always stores native form.
enum ParameterEntryMode: String, CaseIterable, Identifiable {
    case native = "Native"
    case moments = "Mean & SCV"

    var id: String { rawValue }
}

/// Editable, validated draft of one distribution (a source's arrival
/// law, a station's fallback service law, or one per-class service row).
/// Holds the raw text the user typed so validation can run on every
/// keystroke, and converts between the native parameters and the
/// (mean, SCV) moments form without losing input.
struct DistributionDraft: Equatable {
    var distribution: QueueDistribution
    /// Native parameter text keyed by `DistributionParameterDef.key`.
    var params: [String: String]
    var meanText: String = ""
    var scvText: String = ""

    // MARK: Construction

    init(distribution: QueueDistribution, parameterString: String) {
        self.distribution = distribution
        let stored = QueueDistribution.parseParameterStrings(parameterString)
        var values = [String: String]()
        for def in distribution.parameterDefs {
            if let raw = stored[def.key], let v = DS.Number.parse(raw) {
                values[def.key] = DS.Number.fieldText(v)
            } else {
                values[def.key] = DS.Number.fieldText(def.defaultValue)
            }
        }
        params = values
        seedMomentsFromNative()
    }

    static func defaults(_ distribution: QueueDistribution) -> DistributionDraft {
        DistributionDraft(distribution: distribution, parameterString: distribution.defaultParameters)
    }

    /// Switch family, keeping the current moments when they are feasible
    /// for the new family (so "Exponential mean 2" becomes "Gamma mean 2")
    /// and falling back to the family defaults otherwise.
    mutating func changeDistribution(to newDistribution: QueueDistribution, mode: ParameterEntryMode) {
        guard newDistribution != distribution else { return }
        let (m, s) = moments(for: mode)
        var next = DistributionDraft.defaults(newDistribution)
        if let m, m > 0 {
            let targetSCV = newDistribution.fixedSCV ?? max(s ?? 1.0, 1e-9)
            if let solved = newDistribution.parametersFromMoments(mean: m, scv: targetSCV) {
                var values = [String: String]()
                for def in newDistribution.parameterDefs {
                    values[def.key] = DS.Number.fieldText(solved[def.key] ?? def.defaultValue)
                }
                next.params = values
                next.seedMomentsFromNative()
            }
        }
        self = next
    }

    // MARK: Parsing

    var parsedParams: [String: Double] {
        params.compactMapValues { DS.Number.parse($0) }
    }

    var nativeMean: Double? { distribution.computeMean(params: parsedParams) }
    var nativeSCV: Double? { distribution.computeSCV(params: parsedParams) }

    // MARK: Validation

    /// Per-field messages in native mode, keyed by parameter key.
    var nativeErrors: [String: String] {
        let parsed = parsedParams
        var errors = distribution.validateParameters(parsed)
        for def in distribution.parameterDefs where parsed[def.key] == nil {
            errors[def.key] = "Enter a number for \(def.displayName)."
        }
        return errors
    }

    var meanError: String? {
        guard let m = DS.Number.parse(meanText) else { return "Enter a positive mean." }
        return m > 0 ? nil : "Mean must be > 0."
    }

    var scvError: String? {
        if distribution.hasFixedSCV { return nil }
        guard let s = DS.Number.parse(scvText) else { return "Enter an SCV (c²) ≥ 0." }
        if s < 0 { return "SCV must be ≥ 0." }
        // Messages stay under ~45 characters so they fit the one-line
        // caption slot under a field at the sheet's minimum width.
        if s == 0 {
            return "SCV 0 is Deterministic — pick that family."
        }
        if let m = DS.Number.parse(meanText), m > 0,
           distribution.parametersFromMoments(mean: m, scv: s) == nil {
            return "Mean and SCV infeasible for \(distribution.displayName)."
        }
        return nil
    }

    // MARK: Display (6 significant digits for generated values)

    /// Keys ("shape", "scale", …, plus `meanKey` / `scvKey`) whose text the
    /// user has typed in this session. Their text is shown verbatim;
    /// every other value is machine-generated (`%.10g` from a moments
    /// round-trip, e.g. θ = 0.3333333333) and is *displayed* capped to 6
    /// significant digits while `params` keeps the full precision for
    /// Save. An 84-pt table field can then show the value without the
    /// text scrolling out of view.
    private(set) var userEditedKeys: Set<String> = []

    static let meanKey = "mean"
    static let scvKey = "scv"

    /// Display form of a generated value: at most 6 significant digits.
    /// Text that does not parse (mid-edit) is returned verbatim.
    static func displayText(_ raw: String) -> String {
        guard raw.count > 8, let v = DS.Number.parse(raw) else { return raw }
        let short = String(format: "%.6g", v)
        return DS.Number.parse(short) == nil ? raw : short
    }

    /// Native parameter text as the field should show it.
    func displayParam(_ key: String) -> String {
        let raw = params[key] ?? ""
        return userEditedKeys.contains(key) ? raw : Self.displayText(raw)
    }

    /// Store user-typed text for a native parameter (shown verbatim from
    /// now on).
    mutating func setParam(_ key: String, _ text: String) {
        params[key] = text
        userEditedKeys.insert(key)
    }

    var displayMeanText: String {
        get { userEditedKeys.contains(Self.meanKey) ? meanText : Self.displayText(meanText) }
        set { meanText = newValue; userEditedKeys.insert(Self.meanKey) }
    }

    var displayScvText: String {
        get { userEditedKeys.contains(Self.scvKey) ? scvText : Self.displayText(scvText) }
        set { scvText = newValue; userEditedKeys.insert(Self.scvKey) }
    }

    /// Messages for the given entry mode.  Keys are parameter keys in
    /// native mode and "mean" / "scv" in moments mode.
    func errors(for mode: ParameterEntryMode) -> [String: String] {
        switch mode {
        case .native:
            return nativeErrors
        case .moments:
            var e = [String: String]()
            if let m = meanError { e["mean"] = m }
            if let s = scvError { e["scv"] = s }
            return e
        }
    }

    func isValid(for mode: ParameterEntryMode) -> Bool {
        errors(for: mode).isEmpty
    }

    /// Keys whose text is a legal *prefix* of a number ("", "-", "0.",
    /// "1e") rather than a number: the user is still typing it. Their
    /// `errors(for:)` message stays real — a half-typed value must never
    /// be written to the document — but the sheet reports them as
    /// "still typing" (a calm footer note, Save disabled) instead of a
    /// red problem line, so `1e-3` can be typed character by character
    /// without the footer and the Save button flickering.
    func pendingKeys(for mode: ParameterEntryMode) -> [String] {
        func isPending(_ text: String) -> Bool {
            DS.Number.parse(text) == nil && DS.Number.isPartialNumber(text)
        }
        switch mode {
        case .native:
            return distribution.parameterDefs
                .map(\.key)
                .filter { isPending(params[$0] ?? "") }
        case .moments:
            var keys = [String]()
            if isPending(meanText) { keys.append(Self.meanKey) }
            if !distribution.hasFixedSCV, isPending(scvText) { keys.append(Self.scvKey) }
            return keys
        }
    }

    /// Human name of a parameter / moment key, for the "still typing" note.
    func fieldName(for key: String) -> String {
        switch key {
        case Self.meanKey: return "Mean"
        case Self.scvKey:  return "SCV (c²)"
        default:
            return distribution.parameterDefs.first { $0.key == key }?.displayName ?? key
        }
    }

    /// Names of the fields the user is part-way through typing.
    func pendingFieldNames(for mode: ParameterEntryMode) -> [String] {
        pendingKeys(for: mode).map { fieldName(for: $0) }
    }

    // MARK: Moments <-> native

    /// Native parameters solved from the moments fields, plus the realised
    /// moments (Erlang snaps SCV to 1/k, so they can differ from the input).
    func derivedFromMoments() -> (params: [String: Double], mean: Double, scv: Double)? {
        guard let mean = DS.Number.parse(meanText), mean > 0 else { return nil }
        let scv: Double = distribution.fixedSCV ?? (DS.Number.parse(scvText) ?? -1)
        guard scv >= 0 else { return nil }
        guard let params = distribution.parametersFromMoments(mean: mean, scv: scv) else { return nil }
        let realizedMean = distribution.computeMean(params: params) ?? mean
        let realizedSCV = distribution.computeSCV(params: params) ?? scv
        return (params, realizedMean, realizedSCV)
    }

    /// The (mean, SCV) the user should currently see for the given mode.
    func moments(for mode: ParameterEntryMode) -> (mean: Double?, scv: Double?) {
        switch mode {
        case .native:
            return (nativeMean, nativeSCV)
        case .moments:
            if let d = derivedFromMoments() { return (d.mean, d.scv) }
            return (DS.Number.parse(meanText), distribution.fixedSCV ?? DS.Number.parse(scvText))
        }
    }

    /// Native parameters that will be saved for the given mode.
    func effectiveParams(for mode: ParameterEntryMode) -> [String: Double]? {
        switch mode {
        case .native:
            let parsed = parsedParams
            return distribution.parameterDefs.allSatisfy { parsed[$0.key] != nil } ? parsed : nil
        case .moments:
            return derivedFromMoments()?.params
        }
    }

    mutating func seedMomentsFromNative() {
        if let m = nativeMean, m > 0 { meanText = DS.Number.fieldText(m) }
        if let s = nativeSCV, s.isFinite { scvText = DS.Number.fieldText(s) }
        // Generated values: display them capped to 6 significant digits.
        userEditedKeys.subtract([Self.meanKey, Self.scvKey])
    }

    /// Populate the destination representation from the source one when
    /// the user toggles Native <-> Mean & SCV, so the same distribution is
    /// shown two ways without losing input.
    mutating func syncMode(to newMode: ParameterEntryMode) {
        switch newMode {
        case .moments:
            seedMomentsFromNative()
        case .native:
            if let d = derivedFromMoments() {
                var values = [String: String]()
                for def in distribution.parameterDefs {
                    values[def.key] = DS.Number.fieldText(d.params[def.key] ?? def.defaultValue)
                }
                params = values
                userEditedKeys.subtract(distribution.parameterDefs.map(\.key))
            }
        }
    }

    /// Solve native parameters from the moments fields and overwrite
    /// `params`.  Returns a human-readable note when the realised SCV had
    /// to be snapped (Erlang, Uniform bounds), nil otherwise.  Requires
    /// `isValid(for: .moments)`.
    @discardableResult
    mutating func commitMomentsToNative(label: String) -> String? {
        guard let d = derivedFromMoments() else { return nil }
        var values = [String: String]()
        for def in distribution.parameterDefs {
            values[def.key] = DS.Number.fieldText(d.params[def.key] ?? def.defaultValue)
        }
        params = values
        userEditedKeys.subtract(distribution.parameterDefs.map(\.key))
        guard !distribution.hasFixedSCV,
              let requested = DS.Number.parse(scvText),
              abs(d.scv - requested) > max(1e-6, 0.001 * abs(requested)) else {
            return nil
        }
        return "\(label)\(distribution.displayName) snapped SCV to \(DS.Number.format(d.scv, significantDigits: DS.Number.readoutDigits)) (you entered \(DS.Number.format(requested, significantDigits: DS.Number.readoutDigits)))."
    }

    /// "key=value,key=value" in the on-disk format.
    func parameterString() -> String {
        distribution.parameterDefs.map { def in
            let text = params[def.key] ?? DS.Number.fieldText(def.defaultValue)
            let value = DS.Number.parse(text).map(DS.Number.fieldText) ?? text
            return "\(def.key)=\(value)"
        }.joined(separator: ",")
    }

    /// Compact "k=2, θ=0.5" summary for tables and status lines. The
    /// same `DS.Number.readoutDigits` as every other derived readout —
    /// "native: rate=0.6667" two lines under a five-digit mean was the
    /// one place the one-rule-per-quantity precision was still broken.
    func compactSummary() -> String {
        distribution.parameterDefs.map { def in
            let v = DS.Number.parse(params[def.key] ?? "").map { DS.Number.format($0, significantDigits: DS.Number.readoutDigits) } ?? "?"
            return "\(def.shortLabel)=\(v)"
        }.joined(separator: ", ")
    }
}

extension DistributionParameterDef {
    /// Short symbol for compact table cells: "Shape (k)" → "k",
    /// "μ (log-mean)" → "μ", "Rate (λ)" → "λ".
    var shortLabel: String {
        if let open = displayName.firstIndex(of: "("),
           let close = displayName.firstIndex(of: ")"), open < close {
            let inner = displayName[displayName.index(after: open)..<close]
            if inner.count <= 2 { return String(inner) }
        }
        return String(displayName.split(separator: " ").first ?? Substring(displayName))
    }
}
