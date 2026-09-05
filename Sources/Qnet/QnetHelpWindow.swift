import SwiftUI
import AppKit

// MARK: - Topics

enum HelpTopicGroup: String, CaseIterable, Identifiable {
    case concepts        = "Concepts"
    case infiniteMethods = "Infinite-Buffer Methods"
    case finiteMethods   = "Finite-Buffer Methods"
    case workflows       = "Workflows"
    case aiProviders     = "AI Providers"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .concepts:        return DS.Symbol.concepts
        case .infiniteMethods: return DS.Symbol.infiniteBuffers
        case .finiteMethods:   return DS.Symbol.grid
        case .workflows:       return DS.Symbol.workflows
        case .aiProviders:     return DS.Symbol.assistant
        }
    }
}

/// One page of the Qnet Help window. Raw values are stable so the last
/// topic can be persisted in `@AppStorage("help.lastTopic")`.
enum HelpTopic: String, CaseIterable, Identifiable {
    // Concepts
    case srbmOrthant, srbmHypercube, analyticalTractability, feedbackNetworks
    // Infinite-buffer methods — one topic per enabled Run item, so no
    // run sheet's Help button has to borrow a concepts page.
    case spectralInfinite, qna, rqna, sbd, simulationInfinite, regenerativeSimulation, exactSimulation
    case linearProgramInfinite, adaptiveTruncatedCTMC, adaptiveLowRankBAR
    case barMomentBounds, multiClassSRBM
    // Finite-buffer methods
    case spectralFinite, finiteElement, finiteLP, ctmc, finiteDecomposition, simulationFinite
    // Workflows
    case keyboardShortcuts, inspector, solverInputs, testSets, general, interactiveShell
    // AI providers
    case connectAnthropic, connectLMStudio, connectOllama

    var id: String { rawValue }

    var group: HelpTopicGroup {
        switch self {
        case .srbmOrthant, .srbmHypercube, .analyticalTractability, .feedbackNetworks:
            return .concepts
        case .spectralInfinite, .qna, .rqna, .sbd, .simulationInfinite, .regenerativeSimulation, .exactSimulation,
             .linearProgramInfinite, .adaptiveTruncatedCTMC, .adaptiveLowRankBAR,
             .barMomentBounds, .multiClassSRBM:
            return .infiniteMethods
        case .spectralFinite, .finiteElement, .finiteLP, .ctmc, .finiteDecomposition, .simulationFinite:
            return .finiteMethods
        case .keyboardShortcuts, .inspector, .solverInputs, .testSets, .general, .interactiveShell:
            return .workflows
        case .connectAnthropic, .connectLMStudio, .connectOllama:
            return .aiProviders
        }
    }

    /// Sidebar / menu title.
    var title: String {
        switch self {
        case .srbmOrthant:            return "SRBM in an Orthant"
        case .srbmHypercube:          return "SRBM in a Hypercube"
        case .analyticalTractability: return "Analytical Tractability"
        case .feedbackNetworks:       return "Feedback Networks"
        case .spectralInfinite:       return "Spectral Method"
        case .qna:                    return "QNA"
        case .rqna:                   return "RQNA"
        case .sbd:                    return "SBD"
        case .simulationInfinite:     return "Simulation"
        case .regenerativeSimulation: return "Regenerative Monte Carlo"
        case .exactSimulation:        return "SRBM MLMC"
        case .linearProgramInfinite:  return "Linear Program"
        case .adaptiveTruncatedCTMC:  return "Adaptive Truncated CTMC"
        case .adaptiveLowRankBAR:     return "Adaptive Low-Rank BAR"
        case .barMomentBounds:        return "BAR Moment Bounds"
        case .multiClassSRBM:         return "Multi-Class SRBM"
        case .spectralFinite:         return "Spectral Method"
        case .finiteElement:          return "Finite Element"
        // The Run menu says "Run Finite-Buffer LP" and Settings has a
        // "Finite-Buffer LP" pane; the help topic uses the same words.
        case .finiteLP:               return "Finite-Buffer LP"
        case .ctmc:                   return "CTMC"
        case .finiteDecomposition:    return "Finite-Buffer Decomposition"
        case .simulationFinite:       return "Simulation"
        case .keyboardShortcuts:      return "Keyboard Shortcuts"
        case .inspector:              return "Editing Parameters"
        case .solverInputs:           return "Solver Input Files"
        case .testSets:               return "Test Sets"
        case .general:                return "General"
        case .interactiveShell:       return "Shell"
        case .connectAnthropic:       return "Anthropic"
        case .connectLMStudio:        return "LM Studio"
        case .connectOllama:          return "Ollama"
        }
    }

    /// Solver binary shown as a secondary caption where one exists.
    var subtitle: String? {
        switch self {
        case .spectralInfinite:      return "BNAsm · bnet"
        case .qna:                   return "BNAqna · bna_qna"
        case .rqna:                  return "BNArqna · bna_rqna"
        case .sbd:                   return "BNAsbd · bna_sbd"
        case .simulationInfinite:    return "BNAsim · jackson_sim"
        case .regenerativeSimulation:return "regenerative_mc · regenerative_mc.py"
        case .exactSimulation:       return "BNAmc · rbm_mlmc"
        case .linearProgramInfinite: return "BNAlp · srbm_lp"
        case .adaptiveTruncatedCTMC: return "truncated_ctmc · truncated_ctmc.py"
        case .adaptiveLowRankBAR:    return "adaptive_srbm · low_rank_bar.py"
        case .barMomentBounds:       return "bar_bounds · solver.py"
        case .multiClassSRBM:        return "BNAmc-adjacent research solver"
        case .spectralFinite:        return "fBNAsm · srbm_solver"
        case .finiteElement:         return "fBNAfm · bna_fm_gauss"
        case .finiteLP:              return "fBNAlp · fBNAlp_solver"
        case .ctmc:                  return "generic_ctmc · solver.py"
        case .finiteDecomposition:   return "fBNAdecomp · fbna_decomp.py"
        case .simulationFinite:      return "fBNAsim · fBNAsim"
        case .inspector:             return "View ▸ Panes ▸ Inspector · Edit ▸ Edit Parameters…"
        case .solverInputs:          return "File ▸ Export · Qnet --export-cmp"
        default:                     return nil
        }
    }

    /// Full title used for stand-alone windows and the Status-pane
    /// divider. Plain topic names — no "Help:" / "About" prefixes — so the
    /// same words appear in the sidebar, the window title and the divider.
    var windowTitle: String {
        switch self {
        case .srbmOrthant:            return "SRBM in an Orthant"
        case .srbmHypercube:          return "SRBM in a Hypercube"
        case .analyticalTractability: return "Analytical Tractability"
        case .feedbackNetworks:       return "Feedback Networks"
        case .spectralInfinite:       return "Spectral Method (Infinite Buffers)"
        case .qna:                    return "QNA — Queueing Network Analyzer"
        case .rqna:                   return "RQNA — Robust QNA"
        case .sbd:                    return "SBD — Sequential Bottleneck Decomposition"
        case .simulationInfinite:     return "Simulation (Infinite Buffers)"
        case .regenerativeSimulation: return "Regenerative Monte Carlo"
        case .exactSimulation:        return "SRBM MLMC"
        case .linearProgramInfinite:  return "Linear Program (Infinite Buffers)"
        case .adaptiveTruncatedCTMC:  return "Adaptive Truncated CTMC"
        case .adaptiveLowRankBAR:     return "Adaptive Low-Rank BAR"
        case .barMomentBounds:        return "BAR Steady-State Moment Bounds"
        case .multiClassSRBM:         return "Multi-Class SRBM (Experimental)"
        case .spectralFinite:         return "Spectral Method (Finite Buffers)"
        case .finiteElement:          return "Finite Element Method"
        case .finiteLP:               return "Finite-Buffer LP"
        case .ctmc:                   return "CTMC — Exact Markov Chain"
        case .finiteDecomposition:    return "Finite-Buffer Decomposition"
        case .simulationFinite:       return "Simulation (Finite Buffers)"
        case .keyboardShortcuts:      return "Keyboard Shortcuts"
        case .inspector:              return "Inspector Pane and Parameter Sheets"
        case .solverInputs:           return "Solver Input Files"
        case .testSets:               return "Test Sets"
        case .general:                return "General Preferences"
        case .interactiveShell:       return "Shell"
        case .connectAnthropic:       return "Connecting to Anthropic"
        case .connectLMStudio:        return "Connecting to LM Studio"
        case .connectOllama:          return "Connecting to Ollama"
        }
    }

    /// One line for a menu tooltip: the full title, then the solver
    /// binary in parentheses where there is one. This is what makes
    /// Help ▸ Method Reference explain "SBD" without opening it.
    var menuHelp: String {
        if let subtitle { return "\(windowTitle) (\(subtitle))" }
        return windowTitle
    }

    /// Label used for the temp-file name when printed to the shell.
    var label: String {
        switch self {
        case .srbmOrthant:            return "help_srbm_orthant"
        case .srbmHypercube:          return "help_srbm_hypercube"
        case .analyticalTractability: return "help_tract"
        case .feedbackNetworks:       return "help_feedback"
        case .spectralInfinite:       return "help_alg_sm_inf"
        case .qna:                    return "help_alg_qna"
        case .rqna:                   return "help_alg_rqna"
        case .sbd:                    return "help_alg_sbd"
        case .simulationInfinite:     return "help_alg_sim_inf"
        case .regenerativeSimulation: return "help_alg_regenerative_mc"
        case .exactSimulation:        return "help_alg_exact_sim"
        case .linearProgramInfinite:  return "help_alg_lp_inf"
        case .adaptiveTruncatedCTMC:  return "help_alg_truncated_ctmc"
        case .adaptiveLowRankBAR:     return "help_alg_adaptive_bar"
        case .barMomentBounds:        return "help_alg_bar_bounds"
        case .multiClassSRBM:         return "help_alg_mc_srbm"
        case .spectralFinite:         return "help_alg_sm_fin"
        case .finiteElement:          return "help_alg_fe"
        case .finiteLP:               return "help_alg_lp"
        case .ctmc:                   return "help_alg_ctmc"
        case .finiteDecomposition:    return "help_alg_fb_decomp"
        case .simulationFinite:       return "help_alg_sim_fin"
        case .keyboardShortcuts:      return "help_shortcuts"
        case .inspector:              return "help_inspector"
        case .solverInputs:           return "help_solver_inputs"
        case .testSets:               return "help_testsets"
        case .general:                return "help_general"
        case .interactiveShell:       return "help_shell"
        case .connectAnthropic:       return "help_anthropic"
        case .connectLMStudio:        return "help_lmstudio"
        case .connectOllama:          return "help_ollama"
        }
    }

    /// Plain-text body (the existing `AlgorithmHelp` blobs, unedited).
    ///
    /// Main-actor because one topic is not static text: Keyboard
    /// Shortcuts is generated from the live menu bar by
    /// `KeyboardShortcutReference`, so it can never drift from what the
    /// menus print. Every reader (the Help window, the Status / Shell
    /// destinations, `--dump-help`) already runs on the main actor.
    @MainActor
    var text: String {
        switch self {
        case .srbmOrthant:            return AlgorithmHelp.srbmOrthant
        case .srbmHypercube:          return AlgorithmHelp.srbmHypercube
        case .analyticalTractability: return AlgorithmHelp.analyticalTractability
        case .feedbackNetworks:       return AlgorithmHelp.feedbackNetworks
        case .spectralInfinite:       return AlgorithmHelp.algSpectralInfinite
        case .qna:                    return AlgorithmHelp.algQNA
        case .rqna:                   return AlgorithmHelp.algRQNA
        case .sbd:                    return AlgorithmHelp.algSBD
        case .simulationInfinite:     return AlgorithmHelp.algSimulationInfinite
        case .regenerativeSimulation: return AlgorithmHelp.algRegenerativeSimulation
        case .exactSimulation:        return ExactSimulationGuide.text
        case .linearProgramInfinite:  return AlgorithmHelp.algLinearProgramInfinite
        case .adaptiveTruncatedCTMC:  return AlgorithmHelp.algAdaptiveTruncatedCTMC
        case .adaptiveLowRankBAR:     return AlgorithmHelp.algAdaptiveLowRankBAR
        case .barMomentBounds:        return AlgorithmHelp.algBARMomentBounds
        case .multiClassSRBM:         return AlgorithmHelp.algMultiClassSRBM
        case .spectralFinite:         return AlgorithmHelp.algSpectralFinite
        case .finiteElement:          return AlgorithmHelp.algFiniteElement
        case .finiteLP:               return AlgorithmHelp.algFiniteLP
        case .ctmc:                   return AlgorithmHelp.algCTMC
        case .finiteDecomposition:    return AlgorithmHelp.algFiniteDecomposition
        case .simulationFinite:       return AlgorithmHelp.algSimulationFinite
        case .keyboardShortcuts:      return KeyboardShortcutReference.text()
        case .inspector:              return AlgorithmHelp.inspector
        case .solverInputs:           return AlgorithmHelp.solverInputs
        case .testSets:               return AlgorithmHelp.testSets
        case .general:                return AlgorithmHelp.general
        case .interactiveShell:       return AlgorithmHelp.interactiveShell
        case .connectAnthropic:       return AlgorithmHelp.connectAnthropic
        case .connectLMStudio:        return AlgorithmHelp.connectLMStudio
        case .connectOllama:          return AlgorithmHelp.connectOllama
        }
    }

    static func topics(in group: HelpTopicGroup) -> [HelpTopic] {
        allCases.filter { $0.group == group }
    }
}

// MARK: - Plain-text → typeset blocks

/// Converts the ASCII help blobs in `AlgorithmHelp` into semantic blocks
/// without editing the source text.
///
/// Rules:
///   • a line followed by `====` → title; followed by `----` → headline;
///     a `====` banner line, a text line, then another `====` → title
///   • `N.`, `-`, `•` prefixed lines → hanging-indent bullets; lines that
///     continue at the bullet's text column are folded into the bullet
///   • runs indented ≥ 4 spaces (or aligned tables) → monospaced code block
///   • everything else → proportional body text
enum HelpMarkup {
    enum Block: Identifiable {
        case title(String)
        case headline(String)
        case bullet(marker: String, text: String, level: Int)
        case code([String])
        case paragraph(String)

        var id: String {
            switch self {
            case .title(let s):                 return "t:" + s
            case .headline(let s):              return "h:" + s
            case .bullet(let m, let t, let l):  return "b:\(l):\(m):" + t
            case .code(let lines):              return "c:" + lines.joined(separator: "\n")
            case .paragraph(let s):             return "p:" + s
            }
        }

        /// Text used by search; markup-free.
        var searchText: String {
            switch self {
            case .title(let s), .headline(let s), .paragraph(let s): return s
            case .bullet(_, let t, _): return t
            case .code(let lines): return lines.joined(separator: " ")
            }
        }
    }

    /// Parsed blocks of a topic, cached.
    ///
    /// Topics are static text, so a parse never goes stale — but
    /// `HelpTopicDetail` used to re-parse a 10–20 KB document four or
    /// five times per body evaluation, on every keystroke in the search
    /// field. The cache is keyed by topic and checked against the text it
    /// was built from, which costs one string comparison (identical
    /// literals compare by identity) and lets the one generated topic —
    /// Keyboard Shortcuts, rebuilt from the live menu bar — re-parse only
    /// when its text actually changed.
    @MainActor private static var cache: [HelpTopic: (text: String, blocks: [Block])] = [:]

    @MainActor
    static func blocks(for topic: HelpTopic) -> [Block] {
        let text = topic.text
        if let hit = cache[topic], hit.text == text { return hit.blocks }
        let parsed = parse(text)
        cache[topic] = (text, parsed)
        return parsed
    }

    static func parse(_ text: String) -> [Block] {
        // Split into runs separated by blank lines; ids are made unique by
        // suffixing an index so repeated headings don't collide in ForEach.
        let rawLines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var run: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            blocks.append(contentsOf: parseRun(run))
            run.removeAll()
        }

        for line in rawLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushRun()
            } else {
                run.append(line)
            }
        }
        flushRun()

        // Consecutive preformatted runs (separated only by blank lines)
        // belong to one table; merge them so the background is continuous.
        var merged: [Block] = []
        for block in blocks {
            if case .code(let lines) = block, case .code(let prev)? = merged.last {
                merged[merged.count - 1] = .code(prev + [""] + lines)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    private static func isRule(_ s: String, _ ch: Character) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == ch }
    }

    private static func indent(_ s: String) -> Int {
        s.prefix(while: { $0 == " " }).count
    }

    /// Matches "• text", "- text", "1. text", "12) text".
    private static func bulletMatch(_ s: String) -> (marker: String, text: String, contIndent: Int)? {
        let ind = indent(s)
        let body = s.dropFirst(ind)
        let markers = ["•", "-", "*", "→"]
        for m in markers where body.hasPrefix(m + " ") {
            let rest = body.dropFirst(m.count + 1)
            return (m, String(rest).trimmingCharacters(in: .whitespaces), ind + m.count + 1)
        }
        // Numbered: digits followed by "." or ")" and a space.
        var digits = ""
        var idx = body.startIndex
        while idx < body.endIndex, body[idx].isNumber { digits.append(body[idx]); idx = body.index(after: idx) }
        if !digits.isEmpty, idx < body.endIndex, body[idx] == "." || body[idx] == ")" {
            let after = body.index(after: idx)
            if after < body.endIndex, body[after] == " " {
                let rest = body[body.index(after: after)...]
                let marker = digits + String(body[idx])
                return (marker, String(rest).trimmingCharacters(in: .whitespaces), ind + marker.count + 1)
            }
        }
        return nil
    }

    /// True for lines whose internal alignment matters (three or more
    /// consecutive spaces after the first non-space character).
    private static func hasWideGap(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).contains("   ")
    }

    private static func parseRun(_ lines: [String]) -> [Block] {
        var out: [Block] = []

        // Banner: "====" / TITLE / "====".
        if lines.count >= 3, isRule(lines[0], "="), isRule(lines[2], "=") {
            out.append(.title(lines[1].trimmingCharacters(in: .whitespaces)))
            let rest = Array(lines.dropFirst(3))
            if !rest.isEmpty { out.append(contentsOf: parseRun(rest)) }
            return out
        }
        // Underlined heading: TEXT / "====" or "----".
        if lines.count >= 2, isRule(lines[1], "=") {
            out.append(.title(lines[0].trimmingCharacters(in: .whitespaces)))
            let rest = Array(lines.dropFirst(2))
            if !rest.isEmpty { out.append(contentsOf: parseRun(rest)) }
            return out
        }
        if lines.count >= 2, isRule(lines[1], "-") {
            out.append(.headline(lines[0].trimmingCharacters(in: .whitespaces)))
            let rest = Array(lines.dropFirst(2))
            if !rest.isEmpty { out.append(contentsOf: parseRun(rest)) }
            return out
        }
        // A lone rule line (e.g. trailing "====") carries no content.
        if lines.count == 1, isRule(lines[0], "=") || isRule(lines[0], "-") {
            return out
        }

        let hasBullets = lines.contains { bulletMatch($0) != nil }
        let maxIndent = lines.map(indent).max() ?? 0
        let minIndent = lines.map(indent).min() ?? 0
        let wideGap = lines.contains(where: hasWideGap)

        if !hasBullets {
            // Aligned table / preformatted run: every line indented and
            // either deeply indented or column-aligned → keep as code so
            // the columns line up.
            if minIndent >= 1, maxIndent >= 4 || wideGap {
                out.append(.code(lines.map { String($0.dropFirst(minIndent)) }))
                return out
            }
            // Plain prose.
            if maxIndent < 4, !wideGap {
                out.append(.paragraph(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
                return out
            }
            // "Lead-in line:" followed by an indented definition table.
            let lead = lines.prefix(while: { indent($0) == 0 })
            let rest = Array(lines.dropFirst(lead.count))
            if !lead.isEmpty, !rest.isEmpty, rest.allSatisfy({ indent($0) >= 1 }) {
                out.append(.paragraph(lead.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
                let restMin = rest.map(indent).min() ?? 0
                out.append(.code(rest.map { String($0.dropFirst(restMin)) }))
                return out
            }
        }

        // Mixed run: walk line by line.
        var para: [String] = []
        var code: [String] = []
        var bullet: (marker: String, text: String, level: Int, markerIndent: Int, cont: Int)? = nil

        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para.removeAll() }
        }
        func flushCode() {
            if !code.isEmpty { out.append(.code(code)); code.removeAll() }
        }
        func flushBullet() {
            if let b = bullet {
                if !b.text.isEmpty {
                    out.append(.bullet(marker: b.marker, text: b.text, level: b.level))
                }
                bullet = nil
            }
        }

        for line in lines {
            let ind = indent(line)
            if let m = bulletMatch(line) {
                flushPara(); flushCode(); flushBullet()
                let level = ind >= 5 ? 1 : 0
                bullet = (m.marker, m.text, level, ind, m.contIndent)
                continue
            }
            if let b = bullet {
                if ind >= b.cont + 3 || (hasWideGap(line) && ind >= b.markerIndent + 1) {
                    // Formula / table embedded in a list item: emit the
                    // item so far, the code, and keep the item open (with
                    // an empty marker) for any prose that follows.
                    if !b.text.isEmpty {
                        out.append(.bullet(marker: b.marker, text: b.text, level: b.level))
                    }
                    bullet = ("", "", b.level, b.markerIndent, b.cont)
                    code.append(String(line.dropFirst(min(ind, b.cont + 3))))
                    continue
                }
                if ind >= b.markerIndent && ind <= b.cont + 2 {
                    flushCode()
                    let piece = line.trimmingCharacters(in: .whitespaces)
                    bullet?.text = b.text.isEmpty ? piece : b.text + " " + piece
                    continue
                }
                flushCode()
                flushBullet()
            }
            if ind >= 4 {
                flushPara()
                code.append(String(line.dropFirst(4)))
            } else {
                flushCode()
                para.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        flushPara(); flushCode(); flushBullet()
        return out
    }
}

// MARK: - Window model

@MainActor
final class HelpWindowModel: ObservableObject {
    /// One window, one model. The menu bar observes this instance so
    /// Edit ▸ Find Next / Find Previous can enable themselves from the
    /// live match count without reaching into the window.
    static let shared = HelpWindowModel()

    @Published var selectedTopic: HelpTopic
    @Published var searchText: String = ""
    /// Bumped by `QnetHelpWindow.focusSearch()` (Edit ▸ Search Help…, ⌘F
    /// while this window is key); the view moves keyboard focus to the
    /// search field when it changes.
    @Published var searchFocusRequest = 0

    /// How many blocks of the open topic contain the query, and which of
    /// them the reader is parked on. `HelpTopicDetail` writes both; the
    /// menu bar and the breadcrumb's "i of n" readout read them.
    @Published private(set) var matchCount = 0
    @Published private(set) var matchIndex = 0

    private init() {
        selectedTopic = HelpTopic(rawValue: UserDefaults.standard.string(forKey: "help.lastTopic") ?? "")
            ?? .srbmOrthant
    }

    /// Called by the detail pane whenever the topic or the query changes.
    /// The cursor goes back to the first match — including when the new
    /// topic happens to have the same number of matches as the old one.
    func setMatchCount(_ count: Int) {
        if count != matchCount { matchCount = count }
        if matchIndex != 0 { matchIndex = 0 }
    }

    /// Edit ▸ Find Next / Find Previous, and the two breadcrumb buttons.
    /// Wraps around, which is what ⌘G does everywhere else on the Mac.
    func stepMatch(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
    }
}

// MARK: - Views

struct QnetHelpView: View {
    @ObservedObject var model: HelpWindowModel
    @AppStorage("help.lastTopic") private var lastTopicRaw: String = HelpTopic.srbmOrthant.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool

    private var query: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cost note: with a query active this scans every topic's body (about
    /// 250 KB of ASCII across the sidebar) once per keystroke. That is a
    /// few milliseconds today; if the corpus grows by an order of
    /// magnitude, index the bodies once instead of scanning them here.
    private func matches(_ topic: HelpTopic) -> Bool {
        guard !query.isEmpty else { return true }
        if topic.title.localizedCaseInsensitiveContains(query) { return true }
        if topic.windowTitle.localizedCaseInsensitiveContains(query) { return true }
        if let s = topic.subtitle, s.localizedCaseInsensitiveContains(query) { return true }
        return topic.text.localizedCaseInsensitiveContains(query)
    }

    private var visibleGroups: [(HelpTopicGroup, [HelpTopic])] {
        HelpTopicGroup.allCases.compactMap { g in
            let t = HelpTopic.topics(in: g).filter(matches)
            return t.isEmpty ? nil : (g, t)
        }
    }

    private var matchCount: Int { visibleGroups.reduce(0) { $0 + $1.1.count } }

    private var matchSummary: String {
        switch matchCount {
        case 0:  return "No topics match"
        case 1:  return "1 topic matches"
        default: return "\(matchCount) topics match"
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: DS.Layout.helpSidebarMinWidth,
                                                ideal: DS.Layout.helpSidebarIdealWidth,
                                                max: DS.Layout.helpSidebarMaxWidth)
        } detail: {
            HelpTopicDetail(topic: model.selectedTopic, highlight: query, model: model)
                .id(model.selectedTopic)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: DS.Layout.Window.auxWideMinWidth,
               minHeight: DS.Layout.Window.auxWideMinHeight)
        .onChange(of: model.selectedTopic) { _, new in
            lastTopicRaw = new.rawValue
        }
        .onChange(of: model.searchFocusRequest) { _, _ in
            columnVisibility = .all
            searchFocused = true
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // The DS search field (Edit ▸ Search Help…, ⌘F, focuses it).
            // Escape clears window-wide: this window's Escape has no
            // other meaning.
            DSSearchField(
                text: $model.searchText,
                placeholder: "Search help",
                shortcutHint: "⌘F",
                help: "Filter topics by title or body text; matches are highlighted in the page",
                accessibilityLabel: "Search Help",
                clearsOnWindowEscape: true,
                focus: $searchFocused
            )
            .padding(.horizontal, DS.Spacing.s)
            .padding(.top, DS.Spacing.s)
            .padding(.bottom, DS.Spacing.xs)

            List(selection: Binding(
                get: { Optional(model.selectedTopic) },
                set: { if let t = $0 { model.selectedTopic = t } }
            )) {
                ForEach(visibleGroups, id: \.0.id) { group, topics in
                    Section {
                        ForEach(topics) { topic in
                            HStack(spacing: DS.Spacing.s) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(topic.title)
                                    if let sub = topic.subtitle {
                                        Text(sub)
                                            .font(DS.Font.caption)
                                            .foregroundStyle(DS.Color.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .tag(topic)
                            .accessibilityIdentifier("help.topic.\(topic.rawValue)")
                            .accessibilityLabel(topic.title)
                        }
                    } header: {
                        Label(group.rawValue, systemImage: group.systemImage)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if visibleGroups.isEmpty {
                    DSEmptyState.search(query: query)
                        .allowsHitTesting(false)
                }
            }

            if !query.isEmpty {
                DSRule()
                Text(matchSummary)
                    .font(DS.Font.chrome)
                    .foregroundStyle(DS.Color.textSecondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.m)
                    .frame(height: DS.Layout.statusBarHeight)
                    .accessibilityLabel(matchSummary)
                    .transition(.opacity)
            }
        }
        .dsAnimation(DS.Motion.quick, value: query.isEmpty)
    }
}

/// Detail pane: typeset rendering of one topic.
///
/// Searching does more than paint: the blocks that contain the query form
/// an ordered match list, the reader is scrolled to the first one, and
/// ⌘G / ⇧⌘G (or the two breadcrumb buttons) walk the rest with an
/// "i of n" readout. The block under the cursor takes the strong tint;
/// the others take the ordinary one.
struct HelpTopicDetail: View {
    let topic: HelpTopic
    let highlight: String
    @ObservedObject var model: HelpWindowModel

    /// Cached parse (`HelpMarkup.blocks(for:)`); the body reads it once
    /// and passes the array down rather than re-deriving it per use.
    private var blocks: [HelpMarkup.Block] { HelpMarkup.blocks(for: topic) }

    /// Indices into `blocks` whose text contains the query, in reading order.
    private func matches(in blocks: [HelpMarkup.Block]) -> [Int] {
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return blocks.indices.filter {
            blocks[$0].searchText.localizedCaseInsensitiveContains(needle)
        }
    }

    private func currentMatchBlock(in matchList: [Int]) -> Int? {
        guard !matchList.isEmpty else { return nil }
        return matchList[min(model.matchIndex, matchList.count - 1)]
    }

    var body: some View {
        // Computed once per body evaluation and threaded through: the
        // block list, the match list and the cursor block.
        let blocks = blocks
        let matchList = matches(in: blocks)
        let cursorBlock = currentMatchBlock(in: matchList)
        VStack(spacing: 0) {
            // Breadcrumb: group · solver binary, and the match walker.
            // Kept inside the pane so the window title stays "Qnet Help"
            // (and so it lists that way in the Window menu).
            HStack(spacing: DS.Spacing.s) {
                Label(topic.group.rawValue, systemImage: topic.group.systemImage)
                    .foregroundStyle(DS.Color.textSecondary)
                if let sub = topic.subtitle {
                    Text("·").foregroundStyle(DS.Color.textTertiary)
                    Text(sub)
                        .font(DS.Font.monoCaption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                if !matchList.isEmpty {
                    matchWalker(count: matchList.count)
                }
            }
            .font(DS.Font.caption)
            // The one chrome for a bar above scrolling content; the
            // horizontal inset matches the page text below it.
            .dsChromeBar(.bottom, horizontal: DS.Spacing.xl, vertical: DS.Spacing.s)
            .accessibilityElement(children: .contain)

            ScrollViewReader { proxy in
                ScrollView {
                    HelpBlocksView(blocks: blocks,
                                   highlight: highlight,
                                   currentMatchBlock: cursorBlock)
                        .padding(.horizontal, DS.Spacing.xl)
                        .padding(.vertical, DS.Spacing.xl)
                        .frame(maxWidth: DS.Layout.readingMeasure + 2 * DS.Spacing.xl, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    model.setMatchCount(matchList.count)
                    // One turn of the run loop so the blocks have been laid
                    // out and `scrollTo` has somewhere to scroll to.
                    DispatchQueue.main.async { reveal(proxy) }
                }
                .onChange(of: highlight) { _, _ in
                    // The closure runs after the state change, so the
                    // cached parse is read once more here rather than
                    // captured stale from this body evaluation.
                    model.setMatchCount(matches(in: blocks).count)
                    reveal(proxy)
                }
                .onChange(of: model.matchIndex) { _, _ in
                    reveal(proxy)
                }
            }
        }
        .dsContentWell()
    }

    /// Scrolls the block under the match cursor into the middle of the
    /// page. No-op when nothing matched, so clearing the query leaves the
    /// reader where they were.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let block = currentMatchBlock(in: matches(in: blocks)) else { return }
        withAnimation(DS.Motion.standard) {
            proxy.scrollTo(block, anchor: .center)
        }
    }

    @ViewBuilder
    private func matchWalker(count: Int) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Text("\(min(model.matchIndex + 1, count)) of \(count)")
                .font(DS.Font.number)
                .monospacedDigit()
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityLabel("Match \(min(model.matchIndex + 1, count)) of \(count)")
            DSIconButton(systemImage: DS.Symbol.stepPrevious,
                         label: "Find Previous",
                         help: "Scroll to the previous match (⇧⌘G)") {
                model.stepMatch(-1)
            }
            DSIconButton(systemImage: DS.Symbol.stepNext,
                         label: "Find Next",
                         help: "Scroll to the next match (⌘G)") {
                model.stepMatch(+1)
            }
        }
    }
}

struct HelpBlocksView: View {
    let blocks: [HelpMarkup.Block]
    /// Search query; every case-insensitive occurrence is painted with the
    /// warning tint so the reader can see why a topic matched.
    var highlight: String = ""
    /// Index of the block the ⌘G cursor is parked on. That block's
    /// occurrences take the strong tint so "this one" is distinguishable
    /// from "also matched".
    var currentMatchBlock: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                render(block, isCurrentMatch: index == currentMatchBlock)
                    // Anchor for HelpTopicDetail's scroll-to-match.
                    .id(index)
            }
        }
        .textSelection(.enabled)
    }

    /// Attributed copy of `text` with the highlight ranges marked.
    private func marked(_ text: String, isCurrentMatch: Bool = false) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        let fill = isCurrentMatch
            ? DS.Color.tintFillStrong(DS.Color.warning)
            : DS.Color.tintFill(DS.Color.warning)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: attributed),
               let upper = AttributedString.Index(found.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = fill
                attributed[lower..<upper].foregroundColor = DS.Color.textPrimary
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return attributed
    }

    @ViewBuilder
    private func render(_ block: HelpMarkup.Block, isCurrentMatch: Bool) -> some View {
        switch block {
        case .title(let s):
            Text(marked(s, isCurrentMatch: isCurrentMatch))
                .font(DS.Font.pageTitle)
                .padding(.bottom, DS.Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        case .headline(let s):
            Text(marked(s.capitalizedHeading, isCurrentMatch: isCurrentMatch))
                .font(DS.Font.headline)
                .padding(.top, DS.Spacing.l)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let s):
            Text(marked(s, isCurrentMatch: isCurrentMatch))
                .font(DS.Font.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let marker, let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(marker.isEmpty ? " " : (marker.count > 1 ? marker : "•"))
                    .font(DS.Font.number)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: marker.count > 1 ? 28 : 12, alignment: .trailing)
                    .accessibilityHidden(marker.isEmpty)
                Text(marked(text, isCurrentMatch: isCurrentMatch))
                    .font(DS.Font.body)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * DS.Spacing.xl)
        case .code(let lines):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(marked(line.isEmpty ? " " : line, isCurrentMatch: isCurrentMatch))
                            .font(DS.Font.monoCallout)
                    }
                }
                .padding(DS.Spacing.s + DS.Spacing.xs)
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.subtleFill)
            )
            .padding(.vertical, DS.Spacing.xs)
        }
    }
}

private extension String {
    /// "WHEN IT WORKS WELL" → "When It Works Well" for shouty ASCII headings;
    /// mixed-case headings are left alone.
    var capitalizedHeading: String {
        let letters = filter { $0.isLetter }
        guard !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) else { return self }
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "with"]
        return split(separator: " ", omittingEmptySubsequences: false)
            .enumerated()
            .map { idx, word in
                let w = String(word)
                if w.count <= 3, w.allSatisfy({ $0.isUppercase }), !small.contains(w.lowercased()) { return w } // acronyms: QNA, SBD, LP
                let lower = w.lowercased()
                if idx > 0, small.contains(lower) { return lower }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}

// MARK: - Window

/// The single, retained Qnet Help window.
@MainActor
enum QnetHelpWindow {
    private static var retained: NSWindow?
    private static var model: HelpWindowModel { HelpWindowModel.shared }

    /// True while the Help window is the key window (Edit ▸ Search Help…).
    static var isKeyWindow: Bool {
        guard let w = retained else { return false }
        return NSApp.keyWindow === w
    }

    /// Moves keyboard focus to the sidebar search field, opening the
    /// window first if needed.
    static func focusSearch() {
        if retained == nil { show() }
        if let w = retained { AuxiliaryWindow.present(w) }
        model.searchFocusRequest += 1
    }

    /// Opens the help window; `topic == nil` restores the last topic.
    static func show(topic: HelpTopic? = nil) {
        let m = model
        if let topic { m.selectedTopic = topic }

        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }

        let window = AuxiliaryWindow.make(
            id: "help",
            title: "Qnet Help",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetHelpWindow"
        ) { _ in
            QnetHelpView(model: m)
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
}
