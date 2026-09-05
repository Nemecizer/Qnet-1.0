import Foundation
import CoreGraphics
import SwiftUI

enum NodeKind: String, Codable, CaseIterable {
    case station
    case buffer
    case source
    case sink

    var displayName: String {
        switch self {
        case .station:
            return "Station"
        case .buffer:
            return "Buffer"
        case .source:
            return "Source"
        case .sink:
            return "Sink"
        }
    }

    /// SF Symbol used for this node kind in inspectors, menus and the
    /// palette.  Mirrors the canvas shapes: circle (station), stacked
    /// slots (buffer), diamond (source), square (sink).
    var systemImage: String {
        switch self {
        case .station: return "circle.fill"
        case .buffer:  return "rectangle.split.3x1.fill"
        case .source:  return "diamond.fill"
        case .sink:    return "app.fill"
        }
    }
}

enum EditorTool: String, CaseIterable {
    case select
    case multiSelect
    case pan
    case addStation
    case addBuffer
    case addSource
    case addSink
    case addLink

    var displayName: String {
        switch self {
        case .select:
            return "Pointer"
        case .multiSelect:
            return "Multi-Select"
        case .pan:
            return "Pan"
        case .addStation:
            return "Add Station"
        case .addBuffer:
            return "Add Buffer"
        case .addSource:
            return "Add Source"
        case .addSink:
            return "Add Sink"
        case .addLink:
            return "Add Link"
        }
    }

    /// Short label used in the tool palette.
    var paletteLabel: String {
        switch self {
        case .select:      return "Pointer"
        case .multiSelect: return "Multi-Select"
        case .pan:         return "Pan"
        case .addStation:  return "Station"
        case .addBuffer:   return "Buffer"
        case .addSource:   return "Source"
        case .addSink:     return "Sink"
        case .addLink:     return "Link"
        }
    }

    /// Menu-item title in the Tools menu.
    var menuTitle: String {
        switch self {
        case .select:      return "Pointer Tool"
        case .multiSelect: return "Multi-Select Tool"
        case .pan:         return "Pan Tool"
        case .addStation:  return "Station Tool"
        case .addBuffer:   return "Buffer Tool"
        case .addSource:   return "Source Tool"
        case .addSink:     return "Sink Tool"
        case .addLink:     return "Link Tool"
        }
    }

    /// SF Symbol drawn in the palette and Tools menu.
    var systemImage: String {
        switch self {
        case .select:      return "cursorarrow"
        case .multiSelect: return "rectangle.dashed"
        case .pan:         return "hand.raised.fill"
        case .addStation:  return NodeKind.station.systemImage
        case .addBuffer:   return NodeKind.buffer.systemImage
        case .addSource:   return NodeKind.source.systemImage
        case .addSink:     return NodeKind.sink.systemImage
        case .addLink:     return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// Single-letter canvas hotkey (no modifier), matching the industry-
    /// standard Figma / OmniGraffle set handled by the canvas key handler.
    var shortcutKey: Character {
        switch self {
        case .select:      return "V"
        case .multiSelect: return "M"
        case .pan:         return "H"
        case .addStation:  return "S"
        case .addBuffer:   return "B"
        case .addSource:   return "O"
        case .addSink:     return "X"
        case .addLink:     return "L"
        }
    }

    /// Tooltip text for the palette button (kept to two lines).
    var helpText: String {
        switch self {
        case .select:
            return "Pointer tool (\(shortcutKey)) — click to select, drag to move (guides line the node up with its neighbours and the grid; hold ⌃ while dragging to place it freely; ⌥ duplicates; Escape mid-drag puts the drag back), drag on empty canvas to rubber-band select, double-click empty canvas for the hand and one click anywhere to come back"
        case .multiSelect:
            return "Multi-Select tool (\(shortcutKey)) — drag a rectangle to select several nodes at once; double-click empty canvas for the hand and one click anywhere to come back"
        case .pan:
            return "Pan tool (\(shortcutKey)) — drag the canvas to scroll; press V for the Pointer, hold Space to pan from any tool, or double-click empty canvas in any selection tool to borrow the hand for one click"
        case .addStation:
            return "Station tool (\(shortcutKey)) — click the canvas to place a service station"
        case .addBuffer:
            return "Buffer tool (\(shortcutKey)) — click the canvas to place a finite or infinite buffer"
        case .addSource:
            return "Source tool (\(shortcutKey)) — click the canvas to place an arrival source (one customer class each)"
        case .addSink:
            return "Sink tool (\(shortcutKey)) — click the canvas to place an exit sink"
        case .addLink:
            return "Link tool (\(shortcutKey)) — click a start node, then each next node to chain routing links, or press on a node and drag to a second one; click the same station twice (or drag out and back onto it) for a self-loop"
        }
    }

    /// Visual grouping used by the palette and the Tools menu:
    /// selection tools, node tools, then the link tool. Node tools are in
    /// FLOW order — source · station · buffer · sink — the same order the
    /// status bar counts them in, so the window has one ordering of its
    /// four primitives. Each tool keeps its own letter shortcut.
    static let paletteGroups: [[EditorTool]] = [
        [.select, .multiSelect, .pan],
        [.addSource, .addStation, .addBuffer, .addSink],
        [.addLink],
    ]

    /// Reverse lookup from a typed character (case-insensitive).
    init?(shortcutCharacter: Character) {
        let upper = Character(shortcutCharacter.uppercased())
        guard let match = EditorTool.allCases.first(where: { $0.shortcutKey == upper }) else {
            return nil
        }
        self = match
    }
}

enum QueueDistribution: String, Codable, CaseIterable, Identifiable {
    case exponential
    case gamma
    case uniform
    case constant
    case weibull
    case erlang
    case lognormal
    case pareto
    case poisson

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exponential:
            return "Exponential"
        case .gamma:
            return "Gamma"
        case .uniform:
            return "Uniform"
        case .constant:
            return "Deterministic"
        case .weibull:
            return "Weibull"
        case .erlang:
            return "Erlang"
        case .lognormal:
            return "Lognormal"
        case .pareto:
            return "Pareto"
        case .poisson:
            return "Poisson"
        }
    }

    var defaultParameters: String {
        switch self {
        case .exponential:
            return "rate=1.0"
        case .gamma:
            return "shape=2.0,scale=1.0"
        case .uniform:
            return "min=0.5,max=1.5"
        case .constant:
            return "value=1.0"
        case .weibull:
            return "shape=1.5,scale=1.0"
        case .erlang:
            return "k=2,rate=1.0"
        case .lognormal:
            return "mu=0.0,sigma=0.25"
        case .pareto:
            return "shape=2.5,scale=1.0"
        case .poisson:
            return "lambda=1.0"
        }
    }

    // MARK: Inspector metadata (additive — not part of the Codable form)

    /// Honest, self-explanatory name for pickers.  Poisson is a *count*
    /// distribution; as an arrival law it means "Poisson process", whose
    /// inter-arrival times are Exponential — say so.
    var pickerName: String {
        switch self {
        case .poisson: return "Poisson process (Exp. inter-arrivals)"
        default:       return displayName
        }
    }

    /// Density / mass function in plain text, for the distribution card.
    var formulaDescription: String {
        switch self {
        case .exponential:
            return "f(x) = λ e^(−λx),  x ≥ 0"
        case .gamma:
            return "f(x) = x^(k−1) e^(−x/θ) / (Γ(k) θ^k),  x > 0"
        case .uniform:
            return "f(x) = 1 / (b − a),  a ≤ x ≤ b"
        case .constant:
            return "P(X = v) = 1  (no variability)"
        case .weibull:
            return "f(x) = (k/λ)(x/λ)^(k−1) e^(−(x/λ)^k),  x ≥ 0"
        case .erlang:
            return "f(x) = μ^k x^(k−1) e^(−μx) / (k−1)!,  x ≥ 0"
        case .lognormal:
            return "f(x) = e^(−(ln x − μ)² / 2σ²) / (x σ √(2π)),  x > 0"
        case .pareto:
            return "f(x) = α xₘ^α / x^(α+1),  x ≥ xₘ"
        case .poisson:
            return "N(t) ~ Poisson(λt);  inter-arrivals ~ Exp(λ)"
        }
    }

    /// Mean of the service / inter-arrival time in terms of the native
    /// parameters.
    var meanFormula: String {
        switch self {
        case .exponential: return "E[X] = 1/λ"
        case .gamma:       return "E[X] = k·θ"
        case .uniform:     return "E[X] = (a + b)/2"
        case .constant:    return "E[X] = v"
        case .weibull:     return "E[X] = λ·Γ(1 + 1/k)"
        case .erlang:      return "E[X] = k/μ"
        case .lognormal:   return "E[X] = e^(μ + σ²/2)"
        case .pareto:      return "E[X] = α·xₘ/(α − 1),  α > 1"
        case .poisson:     return "E[X] = 1/λ  (inter-arrival)"
        }
    }

    /// Squared coefficient of variation in terms of the native parameters.
    var scvFormula: String {
        switch self {
        case .exponential: return "c² = 1"
        case .gamma:       return "c² = 1/k"
        case .uniform:     return "c² = (b − a)² / 3(a + b)²"
        case .constant:    return "c² = 0"
        case .weibull:     return "c² = Γ(1 + 2/k)/Γ(1 + 1/k)² − 1"
        case .erlang:      return "c² = 1/k"
        case .lognormal:   return "c² = e^(σ²) − 1"
        case .pareto:      return "c² = 1/(α(α − 2)),  α > 2"
        case .poisson:     return "c² = 1"
        }
    }

    /// One-line SCV hint shown next to the name in picker menus.
    var menuSubtitle: String {
        switch self {
        case .exponential: return "c² = 1"
        case .gamma:       return "c² = 1/k"
        case .uniform:     return "c² from (a, b)"
        case .constant:    return "c² = 0"
        case .weibull:     return "c² from k"
        case .erlang:      return "c² = 1/k"
        case .lognormal:   return "c² = e^σ² − 1"
        case .pareto:      return "c² = 1/α(α−2)"
        case .poisson:     return "c² = 1"
        }
    }

    /// SF Symbol for picker menus and the distribution card.
    var symbol: String {
        switch self {
        case .exponential: return "chart.line.downtrend.xyaxis"
        case .gamma:       return "waveform.path"
        case .uniform:     return "rectangle.fill"
        case .constant:    return "minus"
        case .weibull:     return "waveform.path.ecg"
        case .erlang:      return "chart.bar.fill"
        case .lognormal:   return "chart.line.uptrend.xyaxis"
        case .pareto:      return "chart.line.flattrend.xyaxis"
        case .poisson:     return "circle.grid.cross"
        }
    }

    /// True when the law describes a service time.  The Poisson *count*
    /// process only makes sense for arrival sources.
    var isAvailableForStations: Bool {
        self != .poisson
    }

    /// Distributions offered by the inspector for a node kind.
    static func cases(for kind: NodeKind) -> [QueueDistribution] {
        kind == .station ? allCases.filter(\.isAvailableForStations) : allCases
    }
}

// MARK: - Customer Class

enum CustomerClass {
    /// Palette for the first eight customer classes — stable hues for
    /// backward compatibility with existing networks and screenshots.
    static let palette: [Color] = [
        .red, .blue, .green, .orange, .purple, .cyan, .pink, .yellow,
    ]

    /// Color for any class index. Classes 0–7 use the fixed palette;
    /// classes 8+ get procedurally generated hues from an HSV wheel
    /// (odd-numbered offsets into the circle keep adjacent class colors
    /// visually distinct). This lets reentrant / multi-stage networks
    /// use arbitrarily many derived classes without running out of
    /// colors.
    static func color(for classIndex: Int) -> Color {
        if classIndex < palette.count {
            return palette[classIndex]
        }
        // Golden-angle spacing gives well-distributed hues.
        let overflow = classIndex - palette.count
        let hue = Double(overflow) * 0.61803398875
        let h = hue - floor(hue)
        // Alternate saturation/value slightly so the wheel doesn't look
        // like a flat palette.
        let sat = overflow % 2 == 0 ? 0.72 : 0.88
        let val = overflow % 3 == 0 ? 0.82 : 0.95
        return Color(hue: h, saturation: sat, brightness: val)
    }

    static func label(for classIndex: Int) -> String {
        "Class \(classIndex + 1)"
    }
}

// MARK: - Per-Class Service Distribution

struct ServiceDistributionConfig: Codable, Hashable {
    var distribution: QueueDistribution
    var distributionParameters: String

    init(
        distribution: QueueDistribution = .exponential,
        distributionParameters: String = QueueDistribution.exponential.defaultParameters
    ) {
        self.distribution = distribution
        self.distributionParameters = distributionParameters
    }
}

// MARK: - Distribution Parameter Definitions & SCV

struct DistributionParameterDef {
    let key: String
    let displayName: String
    let defaultValue: Double
    /// Unit shown after the field ("time", "1/time", or nil for a pure
    /// number such as a shape parameter).
    let unit: String?
    let minValue: Double?
    let maxValue: Double?
    /// When true the lower bound is strict (value must be > minValue).
    let exclusiveMin: Bool
    /// Short help text for the field's tooltip / inline caption.
    let help: String
    /// True when the parameter must be a whole number (Erlang stages).
    let isInteger: Bool

    init(
        key: String,
        displayName: String,
        defaultValue: Double,
        unit: String? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        exclusiveMin: Bool = false,
        help: String = "",
        isInteger: Bool = false
    ) {
        self.key = key
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.exclusiveMin = exclusiveMin
        self.help = help
        self.isInteger = isInteger
    }

    /// Validates a parsed value against the bounds.  Returns a short,
    /// user-facing message or nil when the value is acceptable.
    func validate(_ value: Double) -> String? {
        guard value.isFinite else { return "\(displayName) must be a finite number." }
        if isInteger, value != value.rounded() {
            return "\(displayName) must be a whole number."
        }
        if let minValue {
            if exclusiveMin, value <= minValue {
                return "\(displayName) must be > \(DS.Number.format(minValue))."
            }
            if !exclusiveMin, value < minValue {
                return "\(displayName) must be ≥ \(DS.Number.format(minValue))."
            }
        }
        if let maxValue, value > maxValue {
            return "\(displayName) must be ≤ \(DS.Number.format(maxValue))."
        }
        return nil
    }
}

extension QueueDistribution {

    var parameterDefs: [DistributionParameterDef] {
        switch self {
        case .exponential:
            return [.init(key: "rate", displayName: "Rate (λ)", defaultValue: 1.0,
                          unit: "1/time", minValue: 0, exclusiveMin: true,
                          help: "Events per unit time; mean = 1/λ.")]
        case .gamma:
            return [
                .init(key: "shape", displayName: "Shape (k)", defaultValue: 2.0,
                      minValue: 0, exclusiveMin: true,
                      help: "k > 0. Larger k means less variability (c² = 1/k)."),
                .init(key: "scale", displayName: "Scale (θ)", defaultValue: 1.0,
                      unit: "time", minValue: 0, exclusiveMin: true,
                      help: "θ > 0. Mean = k·θ."),
            ]
        case .uniform:
            return [
                .init(key: "min", displayName: "Min (a)", defaultValue: 0.5,
                      unit: "time", minValue: 0,
                      help: "Lower bound, a ≥ 0 and a < b."),
                .init(key: "max", displayName: "Max (b)", defaultValue: 1.5,
                      unit: "time", minValue: 0, exclusiveMin: true,
                      help: "Upper bound, b > a."),
            ]
        case .constant:
            return [.init(key: "value", displayName: "Value (v)", defaultValue: 1.0,
                          unit: "time", minValue: 0, exclusiveMin: true,
                          help: "Deterministic duration, v > 0.")]
        case .weibull:
            return [
                .init(key: "shape", displayName: "Shape (k)", defaultValue: 1.5,
                      minValue: 0, exclusiveMin: true,
                      help: "k > 0. k = 1 is Exponential; k > 1 is less variable."),
                .init(key: "scale", displayName: "Scale (λ)", defaultValue: 1.0,
                      unit: "time", minValue: 0, exclusiveMin: true,
                      help: "λ > 0. Mean = λ·Γ(1 + 1/k)."),
            ]
        case .erlang:
            return [
                .init(key: "k", displayName: "Stages (k)", defaultValue: 2.0,
                      minValue: 1, help: "Whole number k ≥ 1; c² = 1/k.", isInteger: true),
                .init(key: "rate", displayName: "Rate (μ)", defaultValue: 1.0,
                      unit: "1/time", minValue: 0, exclusiveMin: true,
                      help: "Per-stage rate μ > 0; mean = k/μ."),
            ]
        case .lognormal:
            return [
                .init(key: "mu", displayName: "μ (log-mean)", defaultValue: 0.0,
                      help: "Mean of ln X (any real number)."),
                .init(key: "sigma", displayName: "σ (log-sd)", defaultValue: 0.25,
                      minValue: 0, exclusiveMin: true,
                      help: "σ > 0. c² = e^σ² − 1."),
            ]
        case .pareto:
            return [
                .init(key: "shape", displayName: "Shape (α)", defaultValue: 2.5,
                      minValue: 1, exclusiveMin: true,
                      help: "α > 1 for a finite mean; α > 2 required for a finite variance (SCV)."),
                .init(key: "scale", displayName: "Scale (xₘ)", defaultValue: 1.0,
                      unit: "time", minValue: 0, exclusiveMin: true,
                      help: "Minimum value xₘ > 0."),
            ]
        case .poisson:
            return [.init(key: "lambda", displayName: "Rate (λ)", defaultValue: 1.0,
                          unit: "1/time", minValue: 0, exclusiveMin: true,
                          help: "Arrival rate; inter-arrivals are Exp(λ) with mean 1/λ.")]
        }
    }

    /// Cross-field validation on top of the per-parameter bounds.  Keys
    /// are parameter keys; values are the message to show under that
    /// field.  Empty when everything is consistent.
    func validateParameters(_ params: [String: Double]) -> [String: String] {
        var errors = [String: String]()
        for def in parameterDefs {
            if let v = params[def.key], let msg = def.validate(v) {
                errors[def.key] = msg
            }
        }
        switch self {
        case .uniform:
            if errors.isEmpty, let a = params["min"], let b = params["max"], b <= a {
                errors["max"] = "Max must be greater than Min."
            }
        case .pareto:
            if errors["shape"] == nil, let alpha = params["shape"], alpha <= 2 {
                errors["shape"] = "Pareto SCV is finite only for α > 2."
            }
        default:
            break
        }
        return errors
    }

    /// Parse "key1=val1,key2=val2" into string values.
    static func parseParameterStrings(_ s: String) -> [String: String] {
        var result = [String: String]()
        for pair in s.split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                result[key] = val
            }
        }
        return result
    }

    /// Compute SCV from a dictionary of numeric parameter values.
    func computeSCV(params: [String: Double]) -> Double? {
        switch self {
        case .exponential:
            return 1.0
        case .gamma:
            guard let shape = params["shape"], shape > 0 else { return nil }
            return 1.0 / shape
        case .uniform:
            guard let a = params["min"], let b = params["max"],
                  (a + b) != 0 else { return nil }
            let diff = b - a
            let sum = a + b
            return (diff * diff) / (3.0 * sum * sum)
        case .constant:
            return 0.0
        case .weibull:
            guard let k = params["shape"], k > 0 else { return nil }
            let g1 = tgamma(1.0 + 1.0 / k)
            let g2 = tgamma(1.0 + 2.0 / k)
            guard g1 > 0 else { return nil }
            return (g2 - g1 * g1) / (g1 * g1)
        case .erlang:
            guard let k = params["k"], k > 0 else { return nil }
            return 1.0 / k
        case .lognormal:
            guard let sigma = params["sigma"] else { return nil }
            return exp(sigma * sigma) - 1.0
        case .pareto:
            guard let alpha = params["shape"], alpha > 2.0 else { return nil }
            return 1.0 / (alpha * (alpha - 2.0))
        case .poisson:
            // A Poisson source produces a Poisson process whose
            // inter-arrival distribution is Exp(λ) — SCV = 1, independent
            // of λ. (Earlier this returned 1/λ, the count-distribution
            // SCV, which is the wrong interpretation for an arrival
            // process and made the form/canvas show inconsistent values
            // vs. the solver pipeline.)
            guard let lambda = params["lambda"], lambda > 0 else { return nil }
            return 1.0
        }
    }

    /// Compute SCV from the stored parameter string (e.g. "rate=1.0").
    func scvFromParameterString(_ paramString: String) -> Double? {
        let strings = Self.parseParameterStrings(paramString)
        let doubles = strings.compactMapValues { Double($0) }
        return computeSCV(params: doubles)
    }

    /// Compute the mean (expected value) from a dictionary of numeric parameter values.
    func computeMean(params: [String: Double]) -> Double? {
        switch self {
        case .exponential:
            guard let rate = params["rate"], rate > 0 else { return nil }
            return 1.0 / rate
        case .gamma:
            guard let shape = params["shape"], let scale = params["scale"],
                  shape > 0, scale > 0 else { return nil }
            return shape * scale
        case .uniform:
            guard let a = params["min"], let b = params["max"] else { return nil }
            return (a + b) / 2.0
        case .constant:
            guard let value = params["value"] else { return nil }
            return value
        case .weibull:
            guard let k = params["shape"], let lam = params["scale"],
                  k > 0, lam > 0 else { return nil }
            return lam * tgamma(1.0 + 1.0 / k)
        case .erlang:
            guard let k = params["k"], let rate = params["rate"],
                  k > 0, rate > 0 else { return nil }
            return k / rate
        case .lognormal:
            guard let mu = params["mu"], let sigma = params["sigma"] else { return nil }
            return exp(mu + sigma * sigma / 2.0)
        case .pareto:
            guard let alpha = params["shape"], let xm = params["scale"],
                  alpha > 1.0, xm > 0 else { return nil }
            return alpha * xm / (alpha - 1.0)
        case .poisson:
            // Inter-arrival mean for a Poisson process at rate λ is 1/λ.
            // (Earlier this returned λ, the count-distribution mean,
            // which made the form/canvas display 1/λ as λ — the
            // inversion users were observing.)
            guard let lambda = params["lambda"], lambda > 0 else { return nil }
            return 1.0 / lambda
        }
    }

    /// Compute mean from the stored parameter string (e.g. "rate=1.0").
    func meanFromParameterString(_ paramString: String) -> Double? {
        let strings = Self.parseParameterStrings(paramString)
        let doubles = strings.compactMapValues { Double($0) }
        return computeMean(params: doubles)
    }

    /// True if SCV is locked by the distribution choice (user can't pick it).
    var hasFixedSCV: Bool {
        switch self {
        case .exponential, .constant, .poisson: return true
        default: return false
        }
    }

    /// The locked SCV when `hasFixedSCV` is true; nil otherwise.
    var fixedSCV: Double? {
        switch self {
        case .exponential, .poisson: return 1.0
        case .constant: return 0.0
        default: return nil
        }
    }

    /// SCV is constrained to a discrete grid (Erlang: 1/k for integer k≥1).
    var hasDiscreteSCV: Bool {
        if case .erlang = self { return true }
        return false
    }

    /// Solve the distribution's native parameters from a target
    /// (mean, SCV). Returns nil if the moments are infeasible for this
    /// family (e.g. Pareto with SCV that pushes α≤2, Uniform whose
    /// implied lower bound is negative).
    ///
    /// SCV-locked distributions ignore the requested SCV and use the
    /// fixed value:
    ///   - Exponential, Poisson:  SCV = 1
    ///   - Constant:              SCV = 0
    /// Erlang snaps SCV to the nearest 1/k (k integer ≥ 1).
    func parametersFromMoments(mean: Double, scv: Double) -> [String: Double]? {
        guard mean > 0, scv >= 0 else { return nil }
        switch self {
        case .exponential:
            return ["rate": 1.0 / mean]
        case .gamma:
            guard scv > 0 else { return nil }
            return ["shape": 1.0 / scv, "scale": mean * scv]
        case .uniform:
            // mean m, SCV s ⇒ half-width h = m·√(3s)
            let h = mean * sqrt(3.0 * scv)
            let lo = mean - h
            let hi = mean + h
            guard lo >= 0 else { return nil }
            return ["min": lo, "max": hi]
        case .constant:
            return ["value": mean]
        case .weibull:
            // Solve Γ(1+2/k)/Γ(1+1/k)² = 1+SCV for k via bisection.
            // The LHS is monotone decreasing in k>0; LHS=2 at k=1 (SCV=1),
            // →∞ as k→0, →1 as k→∞. So feasible SCV ∈ (0, ∞).
            guard scv > 0 else { return nil }
            let target = 1.0 + scv
            func f(_ k: Double) -> Double {
                let g1 = tgamma(1.0 + 1.0 / k)
                let g2 = tgamma(1.0 + 2.0 / k)
                return g2 / (g1 * g1) - target
            }
            // Bracket: f(0.05) is large positive; f(50) is small positive
            // approaching 0. Need f(lo)>0, f(hi)<0 for bisection. Walk
            // hi upward until f(hi) ≤ 0; if SCV<≈0 (target<1) we'd never
            // bracket — guarded by scv>0 above.
            var lo = 0.05
            var hi = 50.0
            while f(hi) > 0 && hi < 1e4 { hi *= 2 }
            guard f(lo) > 0, f(hi) <= 0 else { return nil }
            for _ in 0..<80 {
                let mid = 0.5 * (lo + hi)
                if f(mid) > 0 { lo = mid } else { hi = mid }
            }
            let k = 0.5 * (lo + hi)
            let scale = mean / tgamma(1.0 + 1.0 / k)
            return ["shape": k, "scale": scale]
        case .erlang:
            guard scv > 0 else { return nil }
            let k = max(1.0, (1.0 / scv).rounded())
            return ["k": k, "rate": k / mean]
        case .lognormal:
            let s2 = log(1.0 + scv)
            let mu = log(mean) - s2 / 2.0
            return ["mu": mu, "sigma": sqrt(s2)]
        case .pareto:
            // SCV = 1 / (α(α−2)) with α>2. Solve α² − 2α − 1/SCV = 0
            // ⇒ α = 1 + √(1 + 1/SCV).
            guard scv > 0 else { return nil }
            let alpha = 1.0 + sqrt(1.0 + 1.0 / scv)
            guard alpha > 2.0 else { return nil }
            let xm = mean * (alpha - 1.0) / alpha
            return ["shape": alpha, "scale": xm]
        case .poisson:
            // Poisson process: λ = 1 / mean (inter-arrival), SCV = 1.
            return ["lambda": 1.0 / mean]
        }
    }
}

struct NodeParameterEditorTarget: Identifiable {
    let id: UUID
}

struct LinkParameterEditorTarget: Identifiable {
    let id: UUID
}

struct NetworkTab: Identifiable {
    let id: UUID
    var editor: NetworkEditorModel
    var title: String

    @MainActor init(id: UUID = UUID(), editor: NetworkEditorModel = NetworkEditorModel(), title: String = "Untitled") {
        self.id = id
        self.editor = editor
        self.title = title
    }
}

/// Picture / resource icon drawn inside a station circle.
///
/// Entries are SF Symbol names, so the icon is vector-based, monochrome,
/// and scales cleanly with the station's size and zoom.  The catalogue is
/// modelled after the resource-pool types that commercial discrete-event
/// simulators (Arena, FlexSim, Simio) ship out of the box: human
/// operators, manufacturing equipment, automated / robotic resources,
/// service-industry resources, and logistics.
enum StationPicture: String, CaseIterable, Codable, Hashable {
    case none          = ""                           // empty circle

    // People / operators
    case singleOperator = "person.fill"               // c = 1 server
    case twoOperators   = "person.2.fill"             // c = 2
    case team           = "person.3.fill"             // c ≥ 3

    // Manufacturing
    case machine        = "gearshape.2.fill"
    case workbench      = "hammer.fill"
    case repairStation  = "wrench.and.screwdriver.fill"
    case printer        = "printer.fill"
    case automated      = "cpu.fill"                  // robot / CNC

    // Service
    case healthcare     = "stethoscope"
    case cashier        = "cart.fill"
    case teller         = "creditcard.fill"
    case callCenter     = "phone.fill"

    // Logistics / inspection / compute
    case packageBox     = "shippingbox.fill"
    case inspection     = "magnifyingglass"
    case serverRack     = "server.rack"
    case gear           = "gear"

    /// Human-readable label used in the picker grid.
    var displayName: String {
        switch self {
        case .none:           return "No Picture"
        case .singleOperator: return "Operator"
        case .twoOperators:   return "Two Operators"
        case .team:           return "Team"
        case .machine:        return "Machine"
        case .workbench:      return "Workbench"
        case .repairStation:  return "Repair / Maintenance"
        case .printer:        return "Printer / 3D Print"
        case .automated:      return "Automated / Robot"
        case .healthcare:     return "Healthcare"
        case .cashier:        return "Cashier"
        case .teller:         return "Teller / ATM"
        case .callCenter:     return "Call Center"
        case .packageBox:     return "Package Box"
        case .inspection:     return "Inspection"
        case .serverRack:     return "Server Rack"
        case .gear:           return "Gear"
        }
    }

    /// SF Symbol name to draw, or nil for "no picture" (plain circle).
    var systemImageName: String? {
        self == .none ? nil : rawValue
    }

    /// Picture suggested for a station with `servers` parallel servers:
    /// one operator, two operators, or a team for three or more.
    static func suggested(forServers servers: Int) -> StationPicture {
        switch servers {
        case ...1: return .singleOperator
        case 2:    return .twoOperators
        default:   return .team
        }
    }

    /// True for the operator pictures that `suggested(forServers:)` can
    /// return — used to decide whether a picture was auto-suggested or
    /// deliberately chosen.
    var isOperatorPicture: Bool {
        self == .singleOperator || self == .twoOperators || self == .team
    }
}

struct NetworkNode: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: NodeKind
    var name: String
    var position: CGPoint
    var bufferSize: Int
    var distribution: QueueDistribution
    var distributionParameters: String
    var numberOfServers: Int
    var serviceDistributions: [Int: ServiceDistributionConfig]
    /// Optional resource icon drawn inside the station circle.  Only
    /// meaningful for `.station` nodes; other node kinds ignore it.
    /// Default `.none` keeps the pre-feature look (plain circle).
    var picture: StationPicture

    init(
        id: UUID = UUID(),
        kind: NodeKind,
        name: String,
        position: CGPoint,
        bufferSize: Int = 1,
        numberOfServers: Int = 1,
        distribution: QueueDistribution = .exponential,
        distributionParameters: String = QueueDistribution.exponential.defaultParameters,
        serviceDistributions: [Int: ServiceDistributionConfig] = [:],
        picture: StationPicture = .none
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.position = position
        self.bufferSize = bufferSize
        self.numberOfServers = numberOfServers
        self.distribution = distribution
        self.distributionParameters = distributionParameters
        self.serviceDistributions = serviceDistributions
        self.picture = picture
    }

    // Custom Decodable for backward compatibility with old .bnet files
    enum CodingKeys: String, CodingKey {
        case id, kind, name, position, bufferSize, distribution, distributionParameters
        case numberOfServers, serviceDistributions, picture
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        position = try container.decode(CGPoint.self, forKey: .position)
        bufferSize = try container.decode(Int.self, forKey: .bufferSize)
        distribution = try container.decode(QueueDistribution.self, forKey: .distribution)
        distributionParameters = try container.decode(String.self, forKey: .distributionParameters)
        numberOfServers = try container.decodeIfPresent(Int.self, forKey: .numberOfServers) ?? 1
        serviceDistributions = try container.decodeIfPresent(
            [Int: ServiceDistributionConfig].self, forKey: .serviceDistributions
        ) ?? [:]
        picture = try container.decodeIfPresent(StationPicture.self, forKey: .picture) ?? .none
    }
}

struct NetworkDocument: Codable {
    let nodes: [NetworkNode]
    let links: [NetworkLink]
    var infiniteBuffers: Bool
    var canvasScale: CGFloat
    var canvasPanOffset: CGSize

    init(nodes: [NetworkNode],
         links: [NetworkLink],
         infiniteBuffers: Bool = false,
         canvasScale: CGFloat = 1.0,
         canvasPanOffset: CGSize = .zero) {
        self.nodes = nodes
        self.links = links
        self.infiniteBuffers = infiniteBuffers
        self.canvasScale = canvasScale
        self.canvasPanOffset = canvasPanOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([NetworkNode].self, forKey: .nodes)
        links = try container.decode([NetworkLink].self, forKey: .links)
        infiniteBuffers = try container.decodeIfPresent(Bool.self, forKey: .infiniteBuffers) ?? false
        canvasScale = try container.decodeIfPresent(CGFloat.self, forKey: .canvasScale) ?? 1.0
        canvasPanOffset = try container.decodeIfPresent(CGSize.self, forKey: .canvasPanOffset) ?? .zero
    }
}

/// Whole-application snapshot written to UserDefaults by `TabPersistence` so
/// that the user's editing session (every tab, its positions, zoom level,
/// and the "buffers are infinite" flag) survives application quits and
/// unclean terminations.  Includes the UUID of the active tab so the same
/// tab is selected again on relaunch.
struct PersistedTabState: Codable {
    struct Entry: Codable {
        let id: UUID
        var title: String
        var document: NetworkDocument
        /// Absolute URL (as a string) of any user-chosen `.bnet` file this
        /// tab was loaded from or saved to.  Auto-save does NOT overwrite
        /// that file — it only updates this snapshot.  Stored here so
        /// ⌘S continues to target the same file after relaunch.
        var userFileURL: String?
        /// Per-tab Status pane scrollback. Restored verbatim on next
        /// launch so the user sees the same activity log they had
        /// before quitting. Optional + decode-default-empty so older
        /// saved blobs (pre-statusMessages) still load.
        var statusMessages: [String]? = nil
        /// Structured replacement for `statusMessages` (timestamp +
        /// severity per entry). Older blobs carry only the string form,
        /// which is migrated on restore.
        var statusLog: [StatusEntry]? = nil
    }

    var entries: [Entry]
    var activeTabID: UUID?
}

struct NetworkLink: Identifiable, Hashable, Codable {
    let id: UUID
    let fromNodeID: UUID
    let toNodeID: UUID
    var routingProbability: Double
    var customerClass: Int

    /// Optional class-transition. When non-nil AND different from
    /// `customerClass`, a job enters the link as `customerClass` and exits
    /// as `toCustomerClass` — the standard way to model reentrant lines
    /// (Dai-Harrison 1992; Bramson-Dai 2001). Nil means "same class on
    /// both ends" (identical behavior to pre-Phase-1 links).
    ///
    /// This field is additive and backward-compatible: old .bnet files
    /// (pre-Phase-1) load with `toCustomerClass == nil` and behave
    /// exactly as before.
    var toCustomerClass: Int?

    init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        toNodeID: UUID,
        routingProbability: Double = 1.0,
        customerClass: Int = 0,
        toCustomerClass: Int? = nil
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.routingProbability = routingProbability
        self.customerClass = customerClass
        self.toCustomerClass = toCustomerClass
    }

    // Custom Decodable for backward compatibility with old .bnet files
    enum CodingKeys: String, CodingKey {
        case id, fromNodeID, toNodeID, routingProbability, customerClass
        case toCustomerClass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fromNodeID = try container.decode(UUID.self, forKey: .fromNodeID)
        toNodeID = try container.decode(UUID.self, forKey: .toNodeID)
        routingProbability = try container.decode(Double.self, forKey: .routingProbability)
        customerClass = try container.decodeIfPresent(Int.self, forKey: .customerClass) ?? 0
        toCustomerClass = try container.decodeIfPresent(Int.self, forKey: .toCustomerClass)
    }

    /// The class a job exits this link with. Defaults to `customerClass`
    /// (no transition). Call sites that need to know "which class does
    /// this link deliver jobs as?" should use this helper.
    var exitClass: Int { toCustomerClass ?? customerClass }

    /// True when the link changes the customer class on traversal.
    var hasClassTransition: Bool {
        guard let to = toCustomerClass else { return false }
        return to != customerClass
    }
}
