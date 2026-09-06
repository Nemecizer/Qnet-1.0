import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Ask the integrated terminal to print a block of text. `QnetGUIApp`
    /// observes it and pipes the payload through `printHelpToTerminal`.
    /// The Settings window no longer posts it (reference text is shown
    /// in-place in a popover) but the notification and its handler stay
    /// for other callers.
    static let bnetPrintToTerminal = Notification.Name("bnet.print.to.terminal")
}

// MARK: - Settings window

/// macOS Settings window: grouped sidebar (SF Symbols, search with per-pane
/// match counts) on the left, one grouped-form pane on the right. Every
/// control binds straight to `AppSettings` (immediate apply, like System
/// Settings); each pane owns a "Reset to Defaults" that touches only its
/// own keys via the `AppSettings.reset*()` helpers.
struct SettingsView: View {
    enum Group: String, CaseIterable, Identifiable {
        case general = "General"
        case solvers = "Solvers"
        case sweeps = "Sweeps"
        case interface = "Interface"
        case assistant = "Assistant"
        var id: String { rawValue }
    }

    /// Raw values are the historical pane names; they are persisted as
    /// the last-selected pane, so keep them stable and put the human title
    /// in `title`. The former "GCDG" (Analytical Tractability) pane held
    /// only prose and was removed; its text lives in Help ▸ Analytical
    /// Tractability, and a persisted "GCDG" selection falls back to General.
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case solverEngine = "Solver Engine"
        case simulation = "Simulation"
        case exactSimulation = "SRBM MLMC"
        case linearProgram = "Linear Program"
        case finiteLP = "Finite-Buffer LP"
        case finiteElement = "Finite Element"
        case spectral = "Spectral Method"
        case testSets = "Test Sets"
        case outputFormat = "Output Format"
        case shell = "Interactive Shell Window"
        case helpMenu = "Help menu"
        case ai = "AI Assistant"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:         return "General"
            case .solverEngine:    return "Solver Engine"
            case .simulation:      return "Discrete-Event Simulation"
            case .exactSimulation: return "SRBM MLMC"
            case .linearProgram:   return "Linear Program"
            case .finiteLP:        return "Finite-Buffer LP"
            case .finiteElement:   return "Finite Element"
            case .spectral:        return "Spectral Method"
            case .testSets:        return "Test Sets"
            case .outputFormat:    return "Output Format"
            case .shell:           return "Panes"
            case .helpMenu:        return "Help"
            case .ai:              return "AI Assistant"
            }
        }

        /// Every glyph is a `DS.Symbol` token, and a solver pane wears the
        /// glyph of its run sheet (`RunParameterSpecs`) and Help group, so
        /// Monte Carlo is the die, the spectral method the function sign
        /// and the finite element the grid wherever the user meets them.
        var systemImage: String {
            switch self {
            case .general:         return DS.Symbol.settings
            case .solverEngine:    return DS.Symbol.solverEngine
            case .simulation:      return DS.Symbol.simulation
            case .exactSimulation: return DS.Symbol.multilevel
            case .linearProgram:   return DS.Symbol.increasing
            case .finiteLP:        return DS.Symbol.lpRectangle
            case .finiteElement:   return DS.Symbol.grid
            case .spectral:        return DS.Symbol.formula
            case .testSets:        return DS.Symbol.testSet
            case .outputFormat:    return DS.Symbol.numberFormat
            case .shell:           return DS.Symbol.textAppearance
            case .helpMenu:        return DS.Symbol.help
            case .ai:              return DS.Symbol.assistant
            }
        }

        var group: Group {
            switch self {
            case .general:                                  return .general
            case .solverEngine:                             return .solvers
            case .simulation, .exactSimulation, .linearProgram,
                 .finiteLP, .finiteElement, .spectral:      return .solvers
            case .testSets:                                 return .sweeps
            case .outputFormat, .shell, .helpMenu:          return .interface
            case .ai:                                       return .assistant
            }
        }

        var summary: String {
            switch self {
            case .general:         return "Tab restore and Run Comparison behaviour"
            case .solverEngine:    return "C or Python for the three methods that ship both"
            case .simulation:      return "jackson_sim / fBNAsim run length, parallelism and blocking"
            case .exactSimulation: return "rbm_mlmc accuracy, overrides and reproducibility"
            case .linearProgram:   return "srbm_lp grid, basis and solver (orthant)"
            case .finiteLP:        return "fBNAlp grid, basis and solver (rectangle)"
            case .finiteElement:   return "bna_fm quadrature and mesh"
            case .spectral:        return "Polynomial degree and basis"
            case .testSets:        return "Defaults for random test-set sweeps"
            case .outputFormat:    return "Decimal places in result tables"
            case .shell:           return "Fonts and colours for the Shell, Status and AI Assistant panes"
            case .helpMenu:        return "Where Help menu text is shown"
            case .ai:              return "Provider, model, API key and generation"
            }
        }
    }

    @EnvironmentObject private var settings: AppSettings
    /// Last-selected pane, restored when the window reopens.
    @AppStorage("settings.selectedPane") private var selectedTabRaw: String = Tab.general.rawValue
    @State private var query = ""
    @State private var jump: SettingsJump? = nil
    @State private var jumpCounter = 0
    /// Position of the current match inside `matchingEntries`, so Return
    /// walks every hit ("3 of 5") instead of landing on the first one for
    /// ever. The list is registry order, which is grouped by pane, so
    /// advancing past a pane's last match steps into the next pane that
    /// has one.
    @State private var matchIndex = 0
    /// Invariant: `hasJumpedForQuery` is true exactly when the row the
    /// counter names (`matchingEntries[matchIndex]`) has been scrolled to
    /// and flashed. While it is false the next Return / ⌘G lands ON that
    /// row; once it is true a step advances to the next one. Every path
    /// that jumps — the sidebar click, the automatic pane switch in
    /// `queryDidChange`, `stepMatch` itself — sets it; every query edit
    /// clears it. (It used to stay false after the automatic switch, so
    /// "1 of N" was already flashed and the first Return re-flashed it
    /// instead of going to 2; before that it advanced whenever a stale
    /// `jump` survived the edit, so "1 of 8" + Return went to match 2.)
    @State private var hasJumpedForQuery = false
    /// Panes with at least one stored key away from its default, for the
    /// sidebar dot. Recomputed on every UserDefaults change.
    @State private var dirtyPanes: Set<Tab> = []
    @FocusState private var searchFocused: Bool
    /// What `SettingsRegistry.audit()` found wrong with the registry, read
    /// once in `onAppear`. Empty on a healthy registry, which is every build
    /// that ships, and only ever drawn in a debug build — see
    /// `registryAuditNotice`.
    @State private var registryProblems: [String] = []

    private var selectedTab: Tab { Tab(rawValue: selectedTabRaw) ?? .general }

    private var selection: Binding<Tab?> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard let tab = newValue else { return }
                selectedTabRaw = tab.rawValue
                if isFiltering, let idx = matchingEntries.firstIndex(where: { $0.pane == tab }) {
                    matchIndex = idx
                    hasJumpedForQuery = true
                    jumpTo(matchingEntries[idx])
                } else {
                    // A stale jump must not re-highlight a row the next
                    // time its pane is opened by hand.
                    jump = nil
                }
            }
        )
    }

    private var matchingEntries: [SettingEntry] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : SettingsRegistry.matches(query)
    }

    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: DS.Layout.settingsSidebarMinWidth,
                                                ideal: DS.Layout.settingsSidebarIdealWidth,
                                                max: DS.Layout.settingsSidebarMaxWidth)
        } detail: {
            // The audit band is a row of the column, not a
            // `.safeAreaInset`: it is not chrome floating over the pane, it
            // displaces the pane, and it is gone entirely (no reserved
            // space, no gap) whenever the registry is sound — which is
            // every build but a broken one.
            VStack(spacing: 0) {
                registryAuditNotice
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
        .toolbar(removing: .sidebarToggle)
        // `maxWidth` / `maxHeight` are what make the window resizable at
        // all. With only a min and an ideal, SwiftUI reports the ideal as
        // the maximum, AppKit sees a window that cannot grow and drops the
        // resize behaviour outright — `AXSize` comes back read-only and the
        // corner does not drag. Settings is a long scrolling form (the
        // Discrete-Event Simulation pane clips its Run Length section at
        // the ideal height on a laptop display) and every one of its panes
        // grows again at an accessibility text size, so it has to be able
        // to grow with them. The min and ideal are unchanged: the window
        // still OPENS at the size it always did.
        .frame(minWidth: DS.Layout.Window.settingsMinWidth,
               idealWidth: DS.Layout.Window.settingsIdealWidth,
               maxWidth: .infinity,
               minHeight: DS.Layout.Window.settingsMinHeight,
               idealHeight: DS.Layout.Window.settingsIdealHeight,
               maxHeight: .infinity)
        .environment(\.settingsJump, jump)
        // Every row that matches keeps a quiet tint while the query
        // stands, so all N hits on a pane are visible at once.
        .environment(\.settingsQuery, query)
        .background(SettingsWindowTagger())
        // The Settings scene declares no `.defaultPosition` and SwiftUI
        // rebuilds the SwiftUI view on every ⌘, (it re-shows the same
        // NSWindow), so without this it reopens centred at its ideal size no
        // matter where the user put it. The
        // autosaver tolerates the repeated attach/detach: each rebuilt view
        // gets a fresh coordinator, which attaches to exactly one window and
        // observes only that window.
        //
        // It is the authority for SAVING only. Its restore lands a run-loop
        // tick after the first layout pass, which the user sees as the
        // window landing centred and jumping; `SettingsWindowTagger` above
        // does the restore earlier, from `viewDidMoveToWindow`, off the same
        // key. See `SettingsWindowTagger.restoreFrameOnce`.
        .background(WindowFrameAutosave(name: SettingsWindowTagger.settingsFrameKey))
        .onAppear {
            SettingsRegistry.audit()
            registryProblems = SettingsRegistry.auditFindings
            recomputeDirtyPanes()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            recomputeDirtyPanes()
        }
        // ⌘G / ⇧⌘G — Edit ▸ Find Next / Find Previous route here while
        // this window is key (QnetCommands.stepFind).
        .onReceive(NotificationCenter.default.publisher(for: .bnetSettingsStepMatch)) { note in
            let delta = note.userInfo?["delta"] as? Int ?? 1
            stepMatch(delta < 0 ? -1 : 1)
        }
        // The one ⌘F path into Settings: while this window is key, Edit ▸
        // Search Settings… (QnetCommands.performFind) posts this and the
        // sidebar search field takes focus — by keyboard and by clicking
        // the menu item, which is enabled for the front window whether or
        // not a network is open. There is no hidden shortcut button any more.
        .onReceive(NotificationCenter.default.publisher(for: .bnetSettingsFocusSearch)) { _ in
            focusSearch()
        }
    }

    /// Give keyboard focus to the sidebar search field.
    private func focusSearch() {
        searchFocused = true
    }

    private func recomputeDirtyPanes() {
        let dirty = Set(Tab.allCases.filter { !SettingsRegistry.isPaneAtDefault($0) })
        if dirty != dirtyPanes { dirtyPanes = dirty }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Same gutter as the Help window's sidebar search field (the
            // app's other NavigationSplitView sidebar), so the two line up.
            searchField
                .padding(.horizontal, DS.Spacing.s)
                .padding(.top, DS.Spacing.s)
                .padding(.bottom, DS.Spacing.xs)

            List(selection: selection) {
                ForEach(Group.allCases) { group in
                    let tabs = visibleTabs(in: group)
                    if !tabs.isEmpty {
                        Section(group.rawValue) {
                            ForEach(tabs) { tab in
                                sidebarRow(tab)
                                    .badge(isFiltering ? matchCount(tab) : 0)
                                    .tag(tab)
                                    .help(tab.summary)
                                    .accessibilityLabel(tab.title)
                                    .accessibilityHint(dirtyPanes.contains(tab)
                                                       ? "\(tab.summary). Differs from defaults."
                                                       : tab.summary)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if isFiltering && matchingEntries.isEmpty {
                    DSEmptyState.search(query: query)
                        .allowsHitTesting(false)
                }
            }
            .dsAnimation(DS.Motion.quick, value: query)
        }
        .onChange(of: query) { _, newValue in
            queryDidChange(newValue)
        }
        // Other windows ask for a specific pane (userInfo["tab"] = Tab
        // raw value) via `openSettingsPane(_:)`.
        .onReceive(NotificationCenter.default.publisher(for: .bnetOpenSettingsTab)) { note in
            if let raw = note.userInfo?["tab"] as? String, let tab = Tab(rawValue: raw) {
                selection.wrappedValue = tab
            }
        }
    }

    /// Pane title with its glyph and, when any of its keys is away from
    /// the default, a small warning dot at the trailing edge — "what have I
    /// changed?" answered at a glance, without a count.
    private func sidebarRow(_ tab: Tab) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Label(tab.title, systemImage: tab.systemImage)
            Spacer(minLength: 0)
            if dirtyPanes.contains(tab) {
                Circle()
                    .fill(DS.Color.warning)
                    .frame(width: DS.Layout.indicatorDotSize, height: DS.Layout.indicatorDotSize)
                    .help("\(tab.title) differs from its defaults")
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .dsAnimation(DS.Motion.quick, value: dirtyPanes.contains(tab))
    }

    private var searchField: some View {
        DSSearchField(
            text: $query,
            placeholder: "Search settings",
            shortcutHint: "⌘F",
            help: "Search every setting by name, section or keyword. Return or ⌘G steps forward through the matches, ⇧↩ or ⇧⌘G back",
            status: matchStatus,
            accessibilityLabel: "Search settings",
            focus: $searchFocused,
            onSubmit: { stepMatch(+1) },
            onShiftSubmit: { stepMatch(-1) }
        )
        .accessibilityHint("Filters the sidebar to panes with matching settings. Press Return or Command-G to step forward through the matches in pane order, Shift-Return or Shift-Command-G to step back.")
    }

    /// "3 of 5" beside the query — the position Return will move on from.
    private var matchStatus: String? {
        guard isFiltering else { return nil }
        let total = matchingEntries.count
        guard total > 0 else { return nil }
        return "\(min(matchIndex, total - 1) + 1) of \(total)"
    }

    private func visibleTabs(in group: Group) -> [Tab] {
        Tab.allCases.filter { tab in
            tab.group == group && (!isFiltering || matchCount(tab) > 0)
        }
    }

    private func matchCount(_ tab: Tab) -> Int {
        matchingEntries.filter { $0.pane == tab }.count
    }

    private func queryDidChange(_ newValue: String) {
        // Any edit of the query starts a new walk: the stale jump must not
        // count as "already on match 1", and the menu bar's Find Next /
        // Find Previous follow the new match count.
        jump = nil
        hasJumpedForQuery = false
        let matches = matchingEntries
        SettingsSearchModel.shared.update(query: newValue.trimmingCharacters(in: .whitespaces),
                                          matchCount: matches.count)
        guard isFiltering else { matchIndex = 0; return }
        guard let first = matches.first else { matchIndex = 0; return }
        // Keep the current pane if it still has matches, otherwise move
        // to the first pane that does. Either way the counter names a
        // real position before the first Return.
        if let idx = matches.firstIndex(where: { $0.pane == selectedTab }) {
            // Not scrolled to yet: the first Return lands on it.
            matchIndex = idx
        } else {
            matchIndex = 0
            selectedTabRaw = first.pane.rawValue
            jumpTo(first)
            // The jump HAS happened — the row the counter names is on
            // screen and flashed — so the first Return must advance to
            // match 2, not re-flash match 1.
            hasJumpedForQuery = true
        }
    }

    /// Return / ⌘G (+1) and ⇧⌘G (−1): the first step after a query change
    /// scrolls to the match the counter already names; later steps move
    /// one match in `direction`, wrapping past the end of the pane into
    /// the next pane that has a match and round the ends of the list, so
    /// every match is reachable both ways and the counter and the
    /// highlighted row always agree.
    private func stepMatch(_ direction: Int) {
        let matches = matchingEntries
        guard !matches.isEmpty else { return }
        if matchIndex >= matches.count { matchIndex = 0 }
        if hasJumpedForQuery {
            matchIndex = (matchIndex + direction + matches.count) % matches.count
        } else {
            hasJumpedForQuery = true
        }
        let target = matches[matchIndex]
        selectedTabRaw = target.pane.rawValue
        jumpTo(target)
    }

    private func jumpTo(_ entry: SettingEntry) {
        jumpCounter += 1
        jump = SettingsJump(id: entry.id, token: jumpCounter)
    }

    // MARK: Detail

    /// How many audit findings the band draws before it stops counting them
    /// out. A registry broken wholesale produces dozens, and a band that
    /// grows with them pushes the pane it is warning about off the window.
    /// stderr always carries every line.
    private static let shownRegistryProblems = 4

    /// The registry audit's findings, across the top of whatever pane is
    /// showing — a DEVELOPER surface, hence DEBUG-only and phrased in the
    /// language of the source files that are wrong. On a correct registry
    /// `registryProblems` is empty and nothing is drawn, which is every
    /// build that ships. A release build with a broken registry reports on
    /// stderr and fails `SettingsRegistry.auditProblems()` instead; the
    /// user is never shown a sentence about `unindexedKeys`.
    ///
    /// It exists because the checks behind it used to be asserts, and an
    /// assert in this window's `onAppear` is a trap laid for the wrong
    /// person: it killed the app, and the open network with it, the first
    /// time anyone pressed ⌘, after a key was added to
    /// `AppSettings.defaultsByKey`. A band with the fix spelled out in it
    /// catches the same mistake without costing anybody their work.
    ///
    /// One `Text`, deliberately, rather than a stack of
    /// `SettingsStatusLabel` rows in a `dsChromeBar`: that composition
    /// leaves the split view's detail column with NOTHING drawn — window
    /// chrome and empty content, in both columns — which is a far worse
    /// failure than the one it was reporting. Verified by screenshot, both
    /// ways round. Keep it plain.
    @ViewBuilder private var registryAuditNotice: some View {
        #if DEBUG
        if !registryProblems.isEmpty {
            Text(registryAuditText)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.dangerText)
                .textSelection(.enabled)
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    /// The band's whole text as one selectable block: what this is, then
    /// the findings, then a count of any it did not draw.
    private var registryAuditText: String {
        var lines = [registryProblems.count == 1
                     ? "Settings registry problem:"
                     : "\(registryProblems.count) settings registry problems:"]
        lines += registryProblems.prefix(Self.shownRegistryProblems)
        if registryProblems.count > Self.shownRegistryProblems {
            lines.append("…and \(registryProblems.count - Self.shownRegistryProblems) more. "
                         + "The full list is on stderr.")
        }
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .general:         GeneralPane(settings: settings, openTab: { selectedTabRaw = $0.rawValue })
        case .solverEngine:    SolverEnginePane(settings: settings)
        case .simulation:      SimulationPane(settings: settings)
        case .exactSimulation: ExactSimulationPane(settings: settings)
        case .linearProgram:   LinearProgramPane(settings: settings)
        case .finiteLP:        FiniteLPPane(settings: settings)
        case .finiteElement:   FiniteElementPane(settings: settings)
        case .spectral:        SpectralPane(settings: settings)
        case .testSets:        TestSetsPane(settings: settings)
        case .outputFormat:    OutputFormatPane(settings: settings)
        case .shell:           AppearancePane(settings: settings)
        case .helpMenu:        HelpPane(settings: settings)
        case .ai:              AIAssistantPane(settings: settings)
        }
    }
}

// MARK: - Search registry

/// Every searchable control, keyed by its `@AppStorage` key (or a stable
/// synthetic id for rows without one). The id must match the
/// `settingsAnchor(_:)` on the row so a search hit can scroll to it.
enum SettingsRegistry {
    static let entries: [SettingEntry] = {
        typealias E = SettingEntry
        return [
            // General
            E("tabs.restoreBehavior", .general, "Tabs", "On quit", ["restore", "tabs", "quit", "reopen", "session"]),
            E("runCompare.remember", .general, "Run Comparison", "Remember blocking choice", ["comparison", "dialog", "popup", "skip", "prompt"]),
            E("general.blockingSummary", .general, "Run Comparison", "Default blocking regime", ["blocking", "loss", "bas", "regime", "finite"], keys: []),
            E("general.resetAll", .general, "All Settings", "Reset all panes", ["reset", "defaults", "everything", "all", "restore", "factory"], keys: []),
            E("general.exportImport", .general, "All Settings", "Configuration file", ["export", "import", "json", "file", "configuration", "share", "paper", "backup", "transfer"], keys: []),

            // Solver engine
            E("engine.regenerative", .solverEngine, "Regenerative Monte Carlo", "Engine", ["engine", "c", "python", "native", "speed", "fast", "simulation", "regenerative", "monte carlo"]),
            E("engine.qbd", .solverEngine, "Exact Matrix-Analytic QBD", "Engine", ["engine", "c", "python", "native", "speed", "fast", "qbd", "matrix", "analytic", "phase"]),
            E("engine.ctmc", .solverEngine, "Markovian CTMC", "Engine", ["engine", "c", "python", "native", "speed", "fast", "ctmc", "truncated", "markov", "generic"]),
            E("engine.parity", .solverEngine, "Why There Are Two", "How the engines are kept identical", ["parity", "identical", "reference", "verification", "same", "answer", "byte", "test"], keys: []),

            // Discrete-event simulation
            E("sim.parallel", .simulation, "Execution", "Parallelisation", ["gcd", "openmp", "sequential", "threads", "parallel", "simulation"]),
            E("sim.blocking", .simulation, "Finite Buffers", "Blocking mode", ["loss", "bas", "external", "blocking", "buffer", "finite"]),
            E("sim.replications", .simulation, "Run Length", "Replications", ["runs", "repeat", "confidence", "half-width", "simulation"]),
            E("sim.warmup", .simulation, "Run Length", "Warm-up period", ["warmup", "transient", "burn-in", "time", "simulation"]),
            E("sim.time", .simulation, "Run Length", "Simulation time", ["horizon", "length", "duration", "time", "simulation"]),
            E("sim.seed", .simulation, "Reproducibility", "Fixed random seed", ["seed", "random", "reproducible", "deterministic", "simulation"], keys: ["sim.seed", "sim.seedFixed"]),

            // Exact simulation (MLMC)
            E("mlmc.epsilon", .exactSimulation, "Accuracy", "Target RMSE (ε)", ["epsilon", "rmse", "error", "mlmc", "accuracy", "tolerance"]),
            E("mlmc.gamma", .exactSimulation, "Accuracy", "Step factor (γ)", ["gamma", "step", "mlmc", "level"]),
            E("mlmc.T", .exactSimulation, "Advanced Overrides", "Path length T", ["override", "path", "horizon", "transient", "mlmc"], keys: ["mlmc.T", "mlmc.overrideT"]),
            E("mlmc.L", .exactSimulation, "Advanced Overrides", "Number of levels L", ["override", "levels", "mlmc", "bias"], keys: ["mlmc.L", "mlmc.overrideL"]),
            E("mlmc.N", .exactSimulation, "Advanced Overrides", "Sample count N", ["override", "samples", "mlmc", "variance"], keys: ["mlmc.N", "mlmc.overrideN"]),
            E("mlmc.antithetic", .exactSimulation, "Variance Reduction", "Antithetic variates", ["antithetic", "variance", "reduction", "mlmc"]),
            E("mlmc.replications", .exactSimulation, "Variance Reduction", "Replications (K)", ["replications", "seeds", "standard error", "confidence", "mlmc"]),
            E("mlmc.adaptive", .exactSimulation, "Adaptive Sampling", "Adaptive sampling", ["adaptive", "stop", "standard error", "mlmc"]),
            E("mlmc.batchSize", .exactSimulation, "Adaptive Sampling", "Batch size", ["batch", "adaptive", "mlmc"]),
            E("mlmc.minSamples", .exactSimulation, "Adaptive Sampling", "Minimum samples", ["minimum", "samples", "adaptive", "mlmc"]),
            E("mlmc.maxSamples", .exactSimulation, "Adaptive Sampling", "Maximum samples", ["maximum", "cap", "samples", "adaptive", "mlmc"]),
            E("mlmc.backend", .exactSimulation, "Parallelism", "Backend", ["openmp", "gcd", "accelerate", "serial", "parallel", "mlmc"]),
            E("mlmc.threads", .exactSimulation, "Parallelism", "Threads", ["cores", "threads", "cpu", "parallel", "mlmc"]),
            E("mlmc.seed", .exactSimulation, "Reproducibility", "Fixed random seed", ["seed", "random", "reproducible", "deterministic", "mlmc"], keys: ["mlmc.seed", "mlmc.seedFixed"]),

            // Linear program (orthant)
            E("lp.recommended", .linearProgram, "Discretisation", "Recommended for the open network", ["recommended", "dimension", "stations", "network", "lp"], keys: []),
            E("lp.autoGrid", .linearProgram, "Discretisation", "Auto-scale grid_n by dimension", ["auto-scale", "auto", "scale", "grid", "dimension", "lp"], keys: ["lp.gridN"]),
            E("lp.gridN", .linearProgram, "Discretisation", "Grid size (grid_n)", ["grid", "cells", "resolution", "auto", "lp", "srbm_lp", "dimension", "recommended"]),
            E("lp.autoBasis", .linearProgram, "Discretisation", "Auto-scale basis_m by dimension", ["auto-scale", "auto", "scale", "basis", "dimension", "lp"], keys: ["lp.basisM"]),
            E("lp.basisM", .linearProgram, "Discretisation", "Basis size (basis_m)", ["basis", "polynomial", "degree", "auto", "lp", "dimension", "recommended"]),
            E("lp.gridType", .linearProgram, "Discretisation", "Grid type", ["exponential", "dyadic", "random", "grid", "lp"]),
            E("lp.solver", .linearProgram, "Solver", "LP backend", ["cplex", "glpk", "highs", "solver", "backend", "lp"]),
            E("lp.basisNormalize", .linearProgram, "Numerical Stability", "Normalise monomial basis", ["normalise", "normalize", "conditioning", "basis", "lp"]),
            E("lp.smoothness", .linearProgram, "Numerical Stability", "Smoothness weight", ["smoothness", "tv", "penalty", "degenerate", "lp"]),
            E("lp.askBeforeRun", .linearProgram, "Run-time Behaviour", "Ask for parameters before each run", ["ask", "dialog", "prompt", "run", "lp"]),
            E("lp.multiLevel", .linearProgram, "Run-time Behaviour", "Multi-level refinement", ["coarse", "fine", "preview", "refine", "lp"]),
            E("lp.hints", .linearProgram, "Reference", "Performance Hints…", ["hints", "performance", "table", "help", "lp"], keys: []),

            // Finite-buffer LP
            E("flp.recommended", .finiteLP, "Discretisation", "Recommended for the open network", ["recommended", "dimension", "stations", "network", "finite", "lp"], keys: []),
            E("flp.autoGrid", .finiteLP, "Discretisation", "Auto-scale grid_n by dimension", ["auto-scale", "auto", "scale", "grid", "dimension", "finite", "lp"], keys: ["flp.gridN"]),
            E("flp.gridN", .finiteLP, "Discretisation", "Grid size (grid_n)", ["grid", "cells", "resolution", "auto", "finite", "fbnalp", "rectangle", "dimension", "recommended"]),
            E("flp.autoBasis", .finiteLP, "Discretisation", "Auto-scale basis_m by dimension", ["auto-scale", "auto", "scale", "basis", "dimension", "finite", "lp"], keys: ["flp.basisM"]),
            E("flp.basisM", .finiteLP, "Discretisation", "Basis size (basis_m)", ["basis", "polynomial", "auto", "finite", "fbnalp", "dimension", "recommended"]),
            E("flp.gridType", .finiteLP, "Discretisation", "Grid type", ["uniform", "chebyshev", "grid", "finite", "lp"]),
            E("flp.solver", .finiteLP, "Solver", "LP backend", ["highs", "glpk", "cplex", "solver", "backend", "finite", "lp"]),
            E("flp.basisNormalize", .finiteLP, "Numerical Stability", "Normalise monomial basis", ["normalise", "normalize", "conditioning", "basis", "finite", "lp"]),

            // Finite element
            E("fem.solver", .finiteElement, "Quadrature", "Quadrature method", ["gauss", "legendre", "cbc", "quasi", "monte carlo", "fem", "finite element"]),
            E("fem.meshSize", .finiteElement, "Mesh", "Mesh size", ["mesh", "elements", "per dimension", "axis", "resolution", "fem", "finite element", "cap"]),

            // Spectral
            E("sm.degree", .spectral, "Basis", "Polynomial degree", ["degree", "polynomial", "galerkin", "spectral", "bnet"]),
            E("sm.legendre", .spectral, "Basis", "Use Legendre basis", ["legendre", "monomial", "basis", "spectral", "conditioning"]),

            // Test sets
            E("testset.inf.stations", .testSets, "Infinite Test Set", "Stations", ["stations", "dimension", "infinite", "test set", "sweep"], keys: ["testset.inf.stationsLo", "testset.inf.stationsHi"]),
            E("testset.inf.classes", .testSets, "Infinite Test Set", "Classes", ["classes", "customer", "infinite", "test set"], keys: ["testset.inf.classesLo", "testset.inf.classesHi"]),
            E("testset.inf.rho", .testSets, "Infinite Test Set", "Utilisation ρ", ["rho", "utilisation", "utilization", "load", "infinite", "test set"], keys: ["testset.inf.rhoLo", "testset.inf.rhoHi"]),
            E("testset.inf.numCases", .testSets, "Infinite Test Set", "Number of cases", ["cases", "count", "infinite", "test set"]),
            E("testset.inf.topology", .testSets, "Infinite Test Set", "Topology", ["feed-forward", "jackson", "feedback", "p-matrix", "re-entrant", "topology", "infinite"]),
            E("testset.fin.stations", .testSets, "Finite Test Set", "Stations", ["stations", "dimension", "finite", "test set", "sweep"], keys: ["testset.fin.stationsLo", "testset.fin.stationsHi"]),
            E("testset.fin.classes", .testSets, "Finite Test Set", "Classes", ["classes", "customer", "finite", "test set"], keys: ["testset.fin.classesLo", "testset.fin.classesHi"]),
            E("testset.fin.rho", .testSets, "Finite Test Set", "Utilisation ρ", ["rho", "utilisation", "utilization", "load", "finite", "test set"], keys: ["testset.fin.rhoLo", "testset.fin.rhoHi"]),
            E("testset.fin.numCases", .testSets, "Finite Test Set", "Number of cases", ["cases", "count", "finite", "test set"]),
            E("testset.fin.topology", .testSets, "Finite Test Set", "Topology", ["feed-forward", "jackson", "feedback", "p-matrix", "re-entrant", "topology", "finite"]),
            E("testset.spc.stations", .testSets, "Spectral Convergence", "Stations", ["stations", "dimension", "spectral", "convergence", "sweep"], keys: ["testset.spc.stationsLo", "testset.spc.stationsHi"]),
            E("testset.spc.classes", .testSets, "Spectral Convergence", "Classes", ["classes", "customer", "spectral", "convergence"], keys: ["testset.spc.classesLo", "testset.spc.classesHi"]),
            E("testset.spc.rhoRange", .testSets, "Spectral Convergence", "ρ sweep start … end", ["rho", "sweep", "start", "end", "spectral", "convergence"], keys: ["testset.spc.rhoStart", "testset.spc.rhoEnd"]),
            E("testset.spc.rhoStep", .testSets, "Spectral Convergence", "ρ step", ["rho", "step", "increment", "spectral", "convergence"]),
            E("testset.spc.numCases", .testSets, "Spectral Convergence", "Number of cases", ["cases", "count", "spectral", "convergence"]),
            E("testset.spc.topology", .testSets, "Spectral Convergence", "Topology", ["feed-forward", "jackson", "feedback", "p-matrix", "re-entrant", "topology", "spectral"]),

            // Output format
            E("output.decimals", .outputFormat, "Numeric Display", "Decimal places", ["decimals", "digits", "precision", "format", "table", "rho", "gamma", "sojourn"]),

            // Appearance (fonts and colours of the three text panes)
            // Titles are the rows' own labels (asserted in debug builds by
            // `registerAnchor`); the section ("Shell", "Status", "AI
            // Assistant") is part of the search haystack, so "shell font"
            // still finds the Shell ▸ Font row.
            E("shell.fontName", .shell, "Shell", "Font", ["font", "family", "typeface", "terminal", "shell", "monospaced", "appearance"]),
            E("shell.fontSize", .shell, "Shell", "Text size", ["font", "size", "points", "terminal", "shell", "zoom", "appearance"]),
            E("shell.classicTheme", .shell, "Shell", "Classic green-on-black", ["theme", "classic", "green", "black", "colours", "colors", "terminal", "shell", "dark", "appearance"]),
            E("status.fontSize", .shell, "Status", "Text size", ["font", "size", "points", "status", "log", "zoom", "appearance"]),
            E("ai.fontName", .shell, "AI Assistant", "Code font", ["font", "family", "typeface", "ai", "assistant", "transcript", "code", "monospaced", "appearance"]),
            E("ai.fontSize", .shell, "AI Assistant", "Text size", ["font", "size", "points", "ai", "assistant", "transcript", "zoom", "appearance"]),

            // Help
            E("help.outputDestination", .helpMenu, "Help Menu", "Send help output to", ["help", "popup", "status", "shell", "window", "destination"]),

            // AI assistant. The pane-visibility row lists no keys: like its
            // siblings under View ▸ Panes it is window state, and Reset
            // (per pane or All) must never show or hide a pane.
            E("ai.paneVisible", .ai, "Pane", "Show AI Assistant pane", ["show", "hide", "pane", "ai", "assistant", "layout"], keys: []),
            E("ai.provider", .ai, "Backend", "Provider", ["anthropic", "openai", "ollama", "lm studio", "provider", "claude", "gpt", "ai"], keys: []),
            E("ai.baseURL", .ai, "Backend", "Base URL", ["url", "endpoint", "server", "host", "api", "ai"],
              keys: LLMProvider.allCases.map { "ai.baseURL.\($0.rawValue)" }),
            E("ai.model", .ai, "Backend", "Model", ["model", "claude", "gpt", "llama", "ai", "discover", "refresh"],
              keys: LLMProvider.allCases.flatMap { ["ai.model.\($0.rawValue)", "ai.discovered.\($0.rawValue)"] }),
            E("ai.apiKey", .ai, "Backend", "API key", ["key", "secret", "token", "keychain", "credential", "ai"], keys: []),
            E("ai.systemPrompt", .ai, "Generation", "System prompt", ["prompt", "system", "instructions", "persona", "ai"]),
            E("ai.maxTokens", .ai, "Generation", "Max tokens", ["tokens", "length", "limit", "output", "ai"]),
            E("ai.temperature", .ai, "Generation", "Temperature", ["temperature", "randomness", "creativity", "sampling", "ai"]),
            E("ai.timeoutSec", .ai, "Generation", "Timeout", ["timeout", "seconds", "network", "request", "ai"]),
            E("ai.testConnection", .ai, "Connection", "Test Connection", ["test", "connection", "ping", "verify", "ai"], keys: []),
        ]
    }()

    private static let byID: [String: SettingEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    /// `@AppStorage` key → anchor id of the row that edits it. A key listed
    /// by several entries resolves to the entry whose id IS the key (the
    /// row that shows the value), falling back to the first that lists it.
    /// The LP auto-scale switches list `lp.gridN` / `lp.basisM` because
    /// they write those keys, and precede the field rows; without the
    /// preference Reset to Defaults flashed the switch instead of the
    /// field whose text just became the placeholder.
    private static let anchorByKey: [String: String] = {
        var map: [String: String] = [:]
        for e in entries { for k in e.keys where map[k] == nil { map[k] = e.id } }
        for e in entries where e.keys.contains(e.id) { map[e.id] = e.id }
        return map
    }()

    static func entry(_ id: String) -> SettingEntry? { byID[id] }

    /// "SRBM MLMC ▸ Path length T" for a stored key — the
    /// pane and row the user can see, for the import report — or the raw
    /// key when no row edits it.
    static func displayName(forKey key: String) -> String {
        guard let id = anchorByKey[key], let e = byID[id] else { return key }
        return "\(e.pane.title) ▸ \(e.title)"
    }

    static func matches(_ query: String) -> [SettingEntry] {
        entries.filter { $0.matches(query) }
    }

    // MARK: Drift guards (DEBUG)
    //
    // The registry and the `.settingsAnchor(id)` calls are two hand-kept
    // lists. A typo in either used to produce a search hit that scrolls
    // nowhere, or a row search can never reach, with no signal at all —
    // and the drift had already started (fem.meshSize was indexed under a
    // title the row no longer used). Both halves are now checked in debug
    // builds, the way `SettingsUnitAudit` checks the unit column.

    /// Called by every `settingsAnchor(_:label:)` as its row appears: the
    /// id must name a registry entry, or search can never reach the row;
    /// and the row's visible label must be the entry's title, or a search
    /// result names a row the user cannot find ("Shell font" vs "Font").
    @MainActor static func registerAnchor(_ id: String, label: String? = nil) {
        #if DEBUG
        guard seenAnchors.insert(id).inserted else { return }
        let entry = byID[id]
        assert(entry != nil,
               "Settings row anchor \"\(id)\" has no SettingsRegistry entry, so no search "
               + "can ever reach it. Add an E(\"\(id)\", …) to SettingsRegistry.entries, "
               + "or correct the id on the row.")
        if let entry, let label {
            assert(entry.title == label,
                   "Settings row \"\(id)\" is labelled \"\(label)\" but SettingsRegistry titles it "
                   + "\"\(entry.title)\". Search results show the registry title; make them the same.")
        }
        #endif
    }

    /// Stored keys that deliberately have no Settings row, so `audit()` can
    /// insist that every OTHER key in `AppSettings.defaultsByKey` is
    /// searchable. A new `@AppStorage` key must either get a registry entry
    /// or be listed here with its reason.
    static let unindexedKeys: [String: String] = [
        "gcdg.enabled":          "vestigial; the tractability detector no longer reads it",
        "flp.askBeforeRun":      "reserved; the finite-LP run path does not consult it yet",
        "palette.paneVisible":   "View ▸ Panes, not a setting",
        "inspector.paneVisible": "View ▸ Panes, not a setting",
        "status.paneVisible":    "View ▸ Panes, not a setting",
        "results.paneVisible":   "View ▸ Panes, not a setting; the Results workspace is revealed by the first solver run and hidden again from the menu",
        "shell.paneVisible":     "View ▸ Panes, not a setting",
        "ai.paneVisible":        "View ▸ Panes, not a setting; edited by the Show AI Assistant pane row, whose entry lists no keys because Reset never shows or hides a pane",
        "panes.soloed":          "View ▸ Panes ▸ Maximize Pane, not a setting — which pane currently has the whole window, restored on the next launch the way a hidden pane is",
        "panes.detached":        "View ▸ Panes ▸ Separate Windows, not a setting — which panes are torn out into windows of their own, restored on the next launch the way a window frame is",
        "results.autoShown":     "one-shot bookkeeping: whether the first solver run has already revealed the Results workspace. Not user-facing and never reset by a Settings pane",
        "ai.provider":           "edited by the Provider row, whose entry lists no keys because Reset never changes the provider",
    ]

    /// One-shot consistency check of the registry itself: no duplicate ids,
    /// every `keys` entry is a key `AppSettings` actually stores (Reset's
    /// "already at defaults" diff is keyed on those strings, so a dead one
    /// silently reads as "unchanged"), and — the converse — every stored
    /// key is edited by some row or listed in `unindexedKeys`, so a new
    /// setting cannot ship without a search entry.
    ///
    /// These checks used to be a wall of `assert`s. That cost more than it
    /// caught: a key added to `AppSettings.defaultsByKey` without a line in
    /// `unindexedKeys` is a mistake made in a *different file* by someone
    /// who never opened this one, and the trap it armed went off in the
    /// Settings window's `onAppear` — so the first ⌘, in any debug build
    /// killed the app and took the open, unsaved network with it. It
    /// happened twice. The invariants are worth keeping and the trap is
    /// not, so the checks now COLLECT their complaints: `audit()` writes
    /// them to stderr, and in a debug build draws them across the top of
    /// the Settings window (`SettingsView.registryAuditNotice`), where the
    /// developer who broke the registry reads the exact fix — and the user
    /// keeps their document.
    ///
    /// It is a plain function returning plain strings, compiled into every
    /// configuration, so a headless launch check can run the same list and
    /// fail a build on it — which is the gate that actually stops this
    /// regressing a third time. See `docs/gui_work/round3/W4-integration.md`
    /// for the `--audit-settings` request against `QnetGUIApp.swift`.
    ///
    /// `registerAnchor` above keeps its asserts on purpose: it fires only
    /// while the offending row is on screen, in this file, for whoever just
    /// mistyped its id — the developer is looking straight at the thing
    /// they broke, and no unrelated document is open behind it.
    @MainActor static func auditProblems() -> [String] {
        var problems: [String] = []
        /// Records `message` when the invariant does not hold. The message
        /// is an autoclosure because this runs on a healthy registry every
        /// time: nothing is interpolated unless something is wrong.
        func require(_ holds: Bool, _ message: @autoclosure () -> String) {
            if !holds { problems.append(message()) }
        }

        var seen = Set<String>()
        var indexed = Set<String>()
        var listers: [String: [String]] = [:]
        for e in entries {
            require(seen.insert(e.id).inserted,
                    "Duplicate SettingsRegistry id \"\(e.id)\" — ids are row anchors and must be unique.")
            for key in e.keys {
                require(AppSettings.defaultsByKey[key] != nil,
                        "SettingsRegistry entry \"\(e.id)\" lists stored key \"\(key)\", which "
                        + "AppSettings.defaultsByKey does not know. Reset to Defaults cannot diff "
                        + "it, so the pane would always look unchanged. Add the key to "
                        + "AppSettings.defaultsByKey, or correct the entry.")
                indexed.insert(key)
                listers[key, default: []].append(e.id)
            }
        }
        // A key several rows write must be anchored by the row that shows
        // it, or Reset flashes the wrong row (the LP auto-scale switch
        // instead of the field).
        for (key, ids) in listers where ids.count > 1 {
            require(ids.contains(key),
                    "Stored key \"\(key)\" is listed by \(ids.count) SettingsRegistry entries "
                    + "(\(ids.joined(separator: ", "))) but none of them has that id, so Reset to "
                    + "Defaults would flash \"\(ids[0])\" rather than the row that shows the value. "
                    + "Give the row that edits it the id \"\(key)\".")
        }
        for key in AppSettings.defaultsByKey.keys.sorted() where !indexed.contains(key) {
            require(unindexedKeys[key] != nil,
                    "AppSettings stores \"\(key)\" but no SettingsRegistry entry edits it, so it "
                    + "cannot be searched and Reset to Defaults cannot flash it. Add a row and an "
                    + "entry, or list it in SettingsRegistry.unindexedKeys with the reason.")
        }
        for key in unindexedKeys.keys.sorted() {
            require(AppSettings.defaultsByKey[key] != nil,
                    "SettingsRegistry.unindexedKeys names \"\(key)\", which AppSettings no longer stores.")
        }
        auditImportTables(into: &problems, require)
        return problems
    }

    /// What the last `audit()` found, for the notice at the top of the
    /// Settings window. Empty is the healthy state and the release state.
    @MainActor private(set) static var auditFindings: [String] = []

    /// Runs `auditProblems()` once per launch, remembers the result for the
    /// window, and writes it to stderr — the developer who broke the
    /// registry is usually looking at a terminal, and a `swift run` log is
    /// where the previous two regressions were eventually noticed.
    @MainActor static func audit() {
        guard !audited else { return }
        audited = true
        auditFindings = auditProblems()
        guard !auditFindings.isEmpty else { return }
        let plural = auditFindings.count == 1 ? "problem" : "problems"
        let report = "Qnet settings-registry audit: \(auditFindings.count) \(plural)\n"
            + auditFindings.map { "  • \($0)\n" }.joined()
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// The import validator's tables (`AppSettings.rangesByKey`,
    /// `allowedNumbersByKey`, `allowedStringsByKey`) are what stops a
    /// hand-edited file putting a solver into a state no pane can show.
    /// They are hand-kept, so: every numeric key is bounded by exactly one
    /// of the two numeric tables (a new key cannot import unbounded), every
    /// table names only stored keys, integer keys have integral bounds, and
    /// every default satisfies its own bound — which is how a `Ranges`
    /// constant edited without its table entry, or a `Choices` list the
    /// pane no longer offers, shows up.
    ///
    /// `problems` is passed `inout` as well as through `require` because the
    /// one unclassifiable case — a default of a type the importer has no
    /// bound for at all — is reported directly and then skipped.
    @MainActor private static func auditImportTables(
        into problems: inout [String],
        _ require: (Bool, @autoclosure () -> String) -> Void
    ) {
        let ranges = AppSettings.rangesByKey
        let numbers = AppSettings.allowedNumbersByKey
        let strings = AppSettings.allowedStringsByKey
        for key in Set(ranges.keys).union(numbers.keys).union(strings.keys).sorted() {
            require(AppSettings.defaultsByKey[key] != nil,
                    "The import tables bound \"\(key)\", which AppSettings no longer stores.")
        }
        for key in AppSettings.defaultsByKey.keys.sorted() {
            let def = AppSettings.defaultsByKey[key]!
            if def is Bool { continue }
            if let text = def as? String {
                if let allowed = strings[key] {
                    require(allowed.contains(text),
                            "The default of \"\(key)\" (\"\(text)\") is not one of its allowed values "
                            + "\(allowed), so Reset would produce a value Import refuses.")
                }
                continue
            }
            // Exact type, not `as?`: Foundation can bridge a boxed 10.0 to
            // Int, which would make an Int-bounds check fire on a Double key.
            let value: Double
            let isInt: Bool
            if type(of: def) == Int.self, let i = def as? Int { value = Double(i); isInt = true }
            else if type(of: def) == Double.self, let d = def as? Double { value = d; isInt = false }
            else {
                problems.append("Unexpected default type for \"\(key)\": \(type(of: def)) — the "
                                + "import validator can bound Bool, Int, Double and String only.")
                continue
            }
            let range = ranges[key], allowed = numbers[key]
            require((range != nil) != (allowed != nil),
                    "Numeric setting \"\(key)\" must be bounded by exactly one of "
                    + "AppSettings.rangesByKey (a Ranges constant) or AppSettings.allowedNumbersByKey "
                    + "(a Choices list); it is in \(range != nil && allowed != nil ? "both" : "neither"), "
                    + "so a settings file could import any number into it.")
            if let range {
                require(range.lowerBound <= range.upperBound && range.lowerBound.isFinite && range.upperBound.isFinite,
                        "rangesByKey[\"\(key)\"] is not a finite, ordered range.")
                require(!isInt || (range.lowerBound.rounded() == range.lowerBound && range.upperBound.rounded() == range.upperBound),
                        "rangesByKey[\"\(key)\"] bounds an Int setting with non-integral limits \(range).")
                require(range.contains(value),
                        "The default of \"\(key)\" (\(value)) lies outside rangesByKey's \(range), "
                        + "so Reset would produce a value Import refuses. One of the two is stale.")
            }
            if let allowed {
                require(!allowed.isEmpty && allowed.contains(where: { abs($0 - value) <= 1e-9 }),
                        "The default of \"\(key)\" (\(value)) is not one of allowedNumbersByKey's "
                        + "\(allowed) — the pane's menu could not show it.")
            }
        }
    }

    #if DEBUG
    @MainActor private static var seenAnchors = Set<String>()
    #endif
    /// `audit()` is idempotent: the Settings scene is rebuilt on every ⌘,,
    /// so its `onAppear` runs again on every visit.
    @MainActor private static var audited = false

    /// Every stored key edited on `tab`, in row order, without duplicates.
    static func keys(for tab: SettingsView.Tab) -> [String] {
        var seen = Set<String>()
        return entries.filter { $0.pane == tab }.flatMap(\.keys).filter { seen.insert($0).inserted }
    }

    /// The keys the pane's Reset to Defaults actually touches. Every pane
    /// but AI Assistant resets exactly `keys(for:)`; `resetAI()` restores
    /// the generation settings and only the CURRENT provider's endpoint,
    /// model and discovered list (other providers, the Keychain and the
    /// pane's visibility are left alone), so those must not count toward
    /// "already at defaults".
    @MainActor static func resetKeys(for tab: SettingsView.Tab) -> [String] {
        guard tab == .ai else { return keys(for: tab) }
        let raw = UserDefaults.standard.string(forKey: "ai.provider") ?? AppSettings.Defaults.aiProvider
        let p = (LLMProvider(rawValue: raw) ?? .anthropic).rawValue
        return ["ai.baseURL.\(p)", "ai.model.\(p)", "ai.discovered.\(p)",
                "ai.systemPrompt", "ai.maxTokens", "ai.temperature", "ai.timeoutSec"]
    }

    /// True when every key the pane's Reset would touch already holds its
    /// default — what disables the pane's Reset button and hides its
    /// sidebar dot.
    @MainActor static func isPaneAtDefault(_ tab: SettingsView.Tab) -> Bool {
        resetKeys(for: tab).allSatisfy { AppSettings.isStoredAtDefault($0) }
    }

    /// Row anchor for a stored key (nil for keys no row edits).
    static func anchorID(forKey key: String) -> String? { anchorByKey[key] }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    let openTab: (SettingsView.Tab) -> Void

    /// Outcome of the last Import / Export / Reset All, shown in the All
    /// Settings section until the next one.
    @State private var configurationStatus: SettingsStatusLabel.Kind? = nil
    @State private var configurationMessage = ""
    /// Every value the last import refused, named by pane and row, for
    /// the Show Details… popover (the inline line lists at most four).
    @State private var importRefusals: [RefusedValue] = []
    @State private var showImportDetails = false

    /// One refused import value, named the way the window names it.
    private struct RefusedValue: Identifiable {
        /// The stored key — unique within one report.
        let id: String
        /// "SRBM MLMC ▸ Path length T", or the raw key when
        /// no row edits it.
        let name: String
        let reason: String
    }
    /// Bumped on every UserDefaults change so the "N of 12 panes differ"
    /// caption and the Reset All button follow edits made on other panes
    /// (`@AppStorage` inside AppSettings does not publish them).
    @State private var defaultsTick = 0

    var body: some View {
        SettingsPane(.general, reset: { settings.resetGeneral() }) {
            Section {
                SettingsMenuRow(
                    "On quit",
                    selection: $settings.tabRestoreBehavior,
                    options: AppSettings.Choices.tabRestoreBehavior,
                    help: "What happens to open network tabs when Qnet quits and relaunches.",
                    title: { ["Ask", "Always restore", "Never restore"][$0] },
                    detail: {
                        ["Qnet asks on the next launch whether to reopen the tabs that were open at quit.",
                         "Tabs that were open at quit come back on the next launch without asking.",
                         "Every launch starts with one empty tab."][$0]
                    }
                )
                .settingsAnchor("tabs.restoreBehavior", label: "On quit")
            } header: {
                Text("Tabs")
            } footer: {
                SettingsFootnote("Open tabs and their canvases are saved on quit; this decides whether they come back automatically at the next launch.")
            }

            Section {
                SettingsToggleRow(
                    "Remember blocking choice",
                    caption: "Skip the blocking-regime dialog and use the default below.",
                    isOn: $settings.rememberRunComparisonChoice,
                    help: "When on, Run ▸ Run Comparison no longer asks which finite-buffer blocking regime to simulate."
                )
                .settingsAnchor("runCompare.remember", label: "Remember blocking choice")

                LabeledContent {
                    HStack(spacing: DS.Spacing.s) {
                        Text(SimulationPane.blockingName(settings.simBlocking))
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1)
                        Button("Change…") { openTab(.simulation) }
                            .help("Open the Discrete-Event Simulation pane, where the blocking mode is set.")
                            .accessibilityLabel("Change blocking mode in Discrete-Event Simulation")
                        DSGlossarySlot(label: "Default blocking regime", text: nil)
                    }
                } label: {
                    SettingsLabel("Default blocking regime",
                                  caption: "Shared with Discrete-Event Simulation ▸ Blocking mode.")
                }
                .settingsAnchor("general.blockingSummary", label: "Default blocking regime")
            } header: {
                Text("Run Comparison")
            } footer: {
                SettingsFootnote("Run Comparison simulates finite-buffer networks with this regime whenever the dialog is skipped. Change it in the Discrete-Event Simulation pane so there is a single place it is defined.")
            }

            allSettingsSection
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            defaultsTick &+= 1
        }
    }

    // MARK: All settings (reset everything, export, import)

    private var dirtyPaneCount: Int {
        _ = defaultsTick
        return SettingsView.Tab.allCases.filter { !SettingsRegistry.isPaneAtDefault($0) }.count
    }

    private var allSettingsSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: DS.Spacing.s) {
                    Button("Reset All Settings…") { resetAll() }
                        .disabled(dirtyPaneCount == 0)
                        .help(dirtyPaneCount == 0
                              ? "Every pane is already at its defaults"
                              : "Restore the defaults of every pane, after confirming. API keys in the Keychain are not touched.")
                        .accessibilityLabel("Reset all settings to defaults")
                    DSGlossarySlot(label: "Reset all panes", text: nil)
                }
            } label: {
                SettingsLabel("Reset all panes",
                              caption: dirtyPaneCount == 0
                                  ? "Every pane is at its defaults."
                                  : "\(dirtyPaneCount) of \(SettingsView.Tab.allCases.count) panes differ from their defaults (marked in the sidebar).")
            }
            .settingsAnchor("general.resetAll", label: "Reset all panes")

            LabeledContent {
                HStack(spacing: DS.Spacing.s) {
                    Button {
                        exportSettings()
                    } label: {
                        Label("Export…", systemImage: DS.Symbol.export)
                    }
                    .help("Write every setting and its current value to a JSON file — to attach to a run, or to carry to another Mac.")
                    .accessibilityLabel("Export settings to a file")

                    Button {
                        importSettings()
                    } label: {
                        Label("Import…", systemImage: DS.Symbol.download)
                    }
                    .help("Read a settings file written by Export. Each value is checked against its allowed range; anything refused is listed and left unchanged.")
                    .accessibilityLabel("Import settings from a file")
                    DSGlossarySlot(label: "Configuration file", text: nil)
                }
            } label: {
                SettingsLabel("Configuration file",
                              caption: "JSON of every stored setting. API keys stay in the Keychain and are never written.")
            }
            .settingsAnchor("general.exportImport", label: "Configuration file")

            if let configurationStatus {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    SettingsStatusLabel(kind: configurationStatus, text: configurationMessage)
                    if importRefusals.count > Self.inlineRefusalLimit {
                        Button("Show Details…") { showImportDetails.toggle() }
                            .controlSize(.small)
                            .help("List every value the import refused — the pane and row it belongs to, and why.")
                            .accessibilityLabel("Show every refused import value")
                            .popover(isPresented: $showImportDetails, arrowEdge: .bottom) {
                                importDetailsPopover
                            }
                    }
                }
            }
        } header: {
            Text("All Settings")
        } footer: {
            SettingsFootnote("Reset here restores every pane at once; each pane's own Reset to Defaults touches only that pane. An exported file records the exact solver configuration a set of results was produced with.")
        }
        .dsAnimation(DS.Motion.quick, value: configurationStatus)
    }

    /// Refused values listed inline before the report defers to the
    /// Show Details… popover.
    private static let inlineRefusalLimit = 4

    /// The full refusal list: pane ▸ row, then the stored key and reason
    /// in the caption, so a hand-edited file can be corrected line by line.
    private var importDetailsPopover: some View {
        DSPopover(title: "Refused values", systemImage: DS.Symbol.info,
                  trailing: "\(importRefusals.count) left unchanged") {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    ForEach(importRefusals) { refusal in
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(refusal.name)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Text("\(refusal.id) — \(refusal.reason)")
                                .font(DS.Font.monoCaption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DS.Layout.popoverListMaxHeight)
        }
    }

    private func resetAll() {
        let n = dirtyPaneCount
        guard n > 0 else { return }
        let confirmed = ConfirmAlert.destructive(
            title: "Reset all settings to their defaults?",
            message: "\(n) \(n == 1 ? "pane differs" : "panes differ") from the defaults and will be changed. "
                + "API keys in the Keychain, the selected AI provider and which panes are shown (View ▸ Panes) are not affected. "
                + "To keep a copy of the current values first, use Export.",
            confirmTitle: "Reset All Settings"
        )
        guard confirmed else { return }
        settings.resetAll()
        importRefusals = []
        configurationStatus = .success
        configurationMessage = "Every pane is back at its defaults."
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.nameFieldLabel = "Save As:"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "Qnet settings \(stamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AppSettings.exportedSettingsJSON().write(to: url, options: .atomic)
            importRefusals = []
            configurationStatus = .success
            configurationMessage = "Exported \(AppSettings.defaultsByKey.count) settings to \(url.lastPathComponent) (tagged Qnet \(AppVersion.fullVersion))."
        } catch {
            configurationStatus = .failure
            configurationMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = try settings.importSettings(json: Data(contentsOf: url))
            let applied = report.applied.count
            var text = "Imported \(url.lastPathComponent): \(applied) \(applied == 1 ? "setting" : "settings") changed"
            if !report.unchanged.isEmpty { text += ", \(report.unchanged.count) already matched" }
            // Name refused values the way the window does ("Exact
            // Simulation (MLMC) ▸ Path length T"), never by the storage
            // key alone, which appears nowhere else in the window.
            importRefusals = report.rejected.map {
                RefusedValue(id: $0.key,
                             name: SettingsRegistry.displayName(forKey: $0.key),
                             reason: $0.reason.description)
            }
            if importRefusals.isEmpty {
                text += "."
                configurationStatus = .success
            } else if importRefusals.count <= Self.inlineRefusalLimit {
                let listed = importRefusals.map { "\($0.name) (\($0.reason))" }
                text += "; \(importRefusals.count) refused and left unchanged: \(listed.joined(separator: "; "))."
                configurationStatus = applied > 0 ? .info : .failure
            } else {
                text += "; \(importRefusals.count) refused and left unchanged."
                configurationStatus = applied > 0 ? .info : .failure
            }
            configurationMessage = text
        } catch {
            importRefusals = []
            configurationStatus = .failure
            configurationMessage = "Could not import: \(error.localizedDescription)"
        }
    }
}

// MARK: - Discrete-Event Simulation

private struct SimulationPane: View {
    @ObservedObject var settings: AppSettings

    /// Short noun phrase for each regime — the pop-up title, and the
    /// General pane's read-only summary.
    static func blockingName(_ mode: Int) -> String {
        switch mode {
        case 0:  return "Loss"
        case 1:  return "BAS"
        default: return "BAS + external loss"
        }
    }

    /// What the regime does, as the row caption under the label.
    static func blockingDetail(_ mode: Int) -> String {
        switch mode {
        case 0:  return "Arrivals to a full buffer are discarded."
        case 1:  return "The server blocks after service; external arrivals are held."
        default: return "The server blocks after service; external arrivals to a full buffer are lost — matches the RBM model."
        }
    }

    var body: some View {
        SettingsPane(.simulation, reset: { settings.resetSimulation() }) {
            Section {
                SettingsMenuRow(
                    "Parallelisation",
                    selection: $settings.simParallel,
                    options: AppSettings.Choices.simParallel,
                    help: "How replications are distributed across cores. Sequential is useful for debugging or reproducing a single-thread run.",
                    title: { ["Apple GCD", "OpenMP", "Sequential"][$0] },
                    detail: {
                        ["Replications run on all cores through Grand Central Dispatch.",
                         "Replications run on all cores through OpenMP (when the binary was built with it).",
                         "One replication at a time on one thread — for debugging or reproducing a single-thread run."][$0]
                    }
                )
                .settingsAnchor("sim.parallel", label: "Parallelisation")
            } header: {
                Text("Execution")
            }

            Section {
                SettingsMenuRow(
                    "Blocking mode",
                    selection: $settings.simBlocking,
                    options: AppSettings.Choices.simBlocking,
                    help: "What a finite-buffer station does when the next buffer is full.",
                    glossary: DS.Glossary.bas,
                    title: Self.blockingName,
                    detail: Self.blockingDetail
                )
                .settingsAnchor("sim.blocking", label: "Blocking mode")
            } header: {
                Text("Finite Buffers")
            } footer: {
                SettingsFootnote("Applies to fBNAsim runs on finite-buffer networks. Run Comparison uses it as the default regime when “Remember blocking choice” is on in General.")
            }

            Section {
                SettingsNumberRow(
                    "Replications",
                    value: $settings.simReplications,
                    range: AppSettings.Ranges.simReplications,
                    step: 10,
                    unit: "runs",
                    help: "Independent simulation runs averaged for each estimate. More runs narrow the reported half-width at proportionally higher cost.",
                    glossary: DS.Glossary.replications
                )
                .settingsAnchor("sim.replications", label: "Replications")

                SettingsNumberRow(
                    "Warm-up period",
                    value: $settings.simWarmup,
                    range: AppSettings.Ranges.simWarmup,
                    step: 100_000,
                    unit: "time units",
                    help: "Simulated time discarded before statistics are collected (jackson_sim -w), so the initial empty-system transient does not bias the estimates.",
                    glossary: DS.Glossary.warmup
                )
                .settingsAnchor("sim.warmup", label: "Warm-up period")

                SettingsNumberRow(
                    "Simulation time",
                    value: $settings.simTime,
                    range: AppSettings.Ranges.simTime,
                    step: 500_000,
                    unit: "time units",
                    help: "Simulated time over which statistics are collected in each replication (jackson_sim -T).",
                    glossary: DS.Glossary.simulationTime
                )
                .settingsAnchor("sim.time", label: "Simulation time")
            } header: {
                Text("Run Length")
            } footer: {
                SettingsFootnote("Warm-up and simulation time are simulated time in the model's units (jackson_sim -w / -T), not wall-clock seconds. Wall-clock cost scales with simulation time × replications ÷ cores.")
            }

            Section {
                SettingsNumberRow(
                    "Fixed random seed",
                    caption: "When off, Qnet generates a fresh seed for every run and records the seed with the result.",
                    value: $settings.simSeed,
                    range: AppSettings.Ranges.simSeed,
                    help: "Base seed for the simulation streams. Turn the switch on to replay the same streams.",
                    toggle: $settings.simSeedFixed
                )
                .settingsAnchor("sim.seed", label: "Fixed random seed")
            } header: {
                Text("Reproducibility")
            }
        }
    }
}

// MARK: - SRBM MLMC (BNAmc / Blanchet-Chen-Glynn-Si 2021)

private struct ExactSimulationPane: View {
    @ObservedObject var settings: AppSettings

    /// The paper requires 1/γ to be an integer; the pane offers the values
    /// its analysis covers rather than free-form entry. The list lives in
    /// `AppSettings.Choices` so Import accepts exactly what the menu shows.
    private static var gammaOptions: [Double] { AppSettings.Choices.exactSimGamma }

    private var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    private var adaptiveOrderError: String? {
        if settings.exactSimMinSamples > settings.exactSimMaxSamples {
            return "Minimum samples must not exceed the maximum cap"
        }
        if settings.exactSimBatchSize > settings.exactSimMaxSamples {
            return "Batch size must not exceed the maximum cap"
        }
        return nil
    }

    var body: some View {
        SettingsPane(.exactSimulation, reset: { settings.resetExactSimulation() }) {
            accuracySection
            overridesSection
            varianceSection
            adaptiveSection
            parallelismSection
            reproducibilitySection
        }
        .dsAnimation(DS.Motion.quick, value: epsilonCaution)
        .onAppear { snapGamma() }
    }

    /// A stored γ that is not one of the offered values (older builds
    /// allowed free entry) would leave the picker blank — snap it to the
    /// nearest option.
    private func snapGamma() {
        let g = settings.exactSimGamma
        guard !Self.gammaOptions.contains(g) else { return }
        if let nearest = Self.gammaOptions.min(by: { abs($0 - g) < abs($1 - g) }) {
            settings.exactSimGamma = nearest
        }
    }

    /// Cost of the chosen ε relative to the default, from the 1/ε² law.
    private var epsilonCaution: String? {
        let eps = settings.exactSimEpsilon
        guard eps > 0, eps < 0.001 else { return nil }
        let multiple = (AppSettings.Defaults.exactSimEpsilon / eps) * (AppSettings.Defaults.exactSimEpsilon / eps)
        let shown = multiple.formatted(.number.precision(.significantDigits(1...3)).grouping(.automatic))
        let epsText = eps.formatted(.number.precision(.fractionLength(1...4)))
        return "ε = \(epsText) costs about \(shown)× the default (ε = 0.01) — cost scales as 1/ε²."
    }

    private var accuracySection: some View {
        Section {
            SettingsNumberRow(
                "Target RMSE (ε)",
                caption: "Cost scales as 1/ε²: halving ε costs about 4× the runtime. Stepper halves / doubles.",
                value: $settings.exactSimEpsilon,
                range: AppSettings.Ranges.exactSimEpsilon,
                step: 2,
                logarithmic: true,
                format: .number.precision(.fractionLength(1...4)),
                help: "Target root-mean-square error of the stationary moments. Typical values 0.001–0.1.",
                glossary: DS.Glossary.epsilon
            )
            .settingsAnchor("mlmc.epsilon", label: "Target RMSE (ε)")

            if let epsilonCaution {
                InlineFieldMessage(epsilonCaution, severity: .warning)
            }

            SettingsMenuRow(
                "Step factor (γ)",
                selection: $settings.exactSimGamma,
                options: Self.gammaOptions,
                help: "0.05 is the optimum analysed in the paper; smaller γ gives less bias per level but more cost per path. 1/γ must be an integer.",
                glossary: DS.Glossary.stepFactor,
                title: { g in
                    g == 0.05 ? "0.05 (paper-optimal)" : g.formatted(.number.precision(.fractionLength(2)))
                },
                detail: { g in
                    let levels = Int((1 / g).rounded())
                    return "Ratio of consecutive MLMC time-step sizes: each level refines the step \(levels)×."
                }
            )
            .settingsAnchor("mlmc.gamma", label: "Step factor (γ)")
        } header: {
            Text("Accuracy")
        }
    }

    private var overridesSection: some View {
        Section {
            SettingsNumberRow(
                "Path length T",
                caption: "Auto: max(log(d)²/2, 5 × relaxation time).",
                value: $settings.exactSimT,
                range: AppSettings.Ranges.exactSimT,
                step: 1,
                format: .number.precision(.fractionLength(0...2)),
                unit: "time units",
                help: "Length of each simulated path. Larger T removes initial-transient bias but costs linearly.",
                toggle: $settings.exactSimOverrideT
            )
            .settingsAnchor("mlmc.T", label: "Path length T")

            SettingsNumberRow(
                "Number of levels L",
                caption: "Auto: L = ⌈(log log d + 2 log(1/ε) + k) / log(1/γ)⌉.",
                value: $settings.exactSimL,
                range: AppSettings.Ranges.exactSimL,
                unit: "levels",
                help: "More levels shrink discretisation bias exponentially, but cost grows as γ^(−L).",
                toggle: $settings.exactSimOverrideL
            )
            .settingsAnchor("mlmc.L", label: "Number of levels L")

            SettingsNumberRow(
                "Sample count N",
                caption: "Fixed-sample mode only. Auto: N = ⌈K(γ)⁻¹ γ^(−L) L⌉.",
                value: $settings.exactSimN,
                range: AppSettings.Ranges.exactSimN,
                step: 1_000,
                unit: "samples",
                help: "Total MLMC samples in fixed-sample mode. Adaptive mode uses its maximum-sample cap instead.",
                toggle: $settings.exactSimOverrideN
            )
            .disabled(settings.exactSimAdaptive)
            .settingsAnchor("mlmc.N", label: "Sample count N")
        } header: {
            Text("Advanced Overrides")
        } footer: {
            SettingsFootnote("Leave the overrides off for the paper's auto-tuning. Turn one on only to reproduce a specific configuration.")
        }
    }

    private var varianceSection: some View {
        Section {
            SettingsToggleRow(
                "Antithetic variates",
                caption: "Each sample simulates a ±noise pair; roughly halves the variance for ~1.5–2× runtime, no bias.",
                isOn: $settings.exactSimAntithetic,
                help: "Recommended. Averages each path with its sign-flipped twin.",
                glossary: DS.Glossary.antithetic
            )
            .settingsAnchor("mlmc.antithetic", label: "Antithetic variates")

            SettingsNumberRow(
                "Replications (K)",
                caption: "K = 1 keeps the native within-run station intervals; K = 5–10 also identifies a joint network-average interval.",
                value: $settings.exactSimReplications,
                range: AppSettings.Ranges.exactSimReplications,
                unit: "runs",
                help: "Run the whole algorithm K times with different seeds and report mean ± sample standard error."
            )
            .settingsAnchor("mlmc.replications", label: "Replications (K)")
        } header: {
            Text("Variance Reduction")
        }
    }

    private var adaptiveSection: some View {
        Section {
            SettingsToggleRow(
                "Adaptive sampling",
                caption: "Stop once the sample standard-error target is met.",
                isOn: $settings.exactSimAdaptive,
                help: "Adaptive mode targets only the sample standard error, not discretisation or transient bias."
            )
            .settingsAnchor("mlmc.adaptive", label: "Adaptive sampling")

            Group {
                SettingsNumberRow(
                    "Batch size",
                    value: $settings.exactSimBatchSize,
                    range: AppSettings.Ranges.exactSimBatch,
                    step: 100,
                    unit: "samples",
                    help: "Samples drawn between successive standard-error checks.",
                    glossary: DS.Glossary.batchSize
                )
                .settingsAnchor("mlmc.batchSize", label: "Batch size")

                SettingsNumberRow(
                    "Minimum samples",
                    value: $settings.exactSimMinSamples,
                    range: AppSettings.Ranges.exactSimSamples,
                    step: 1_000,
                    unit: "samples",
                    help: "Never stop before this many samples have been drawn; at least two are required to estimate variance.",
                    glossary: DS.Glossary.minSamples,
                    crossCheck: adaptiveOrderError
                )
                .settingsAnchor("mlmc.minSamples", label: "Minimum samples")

                SettingsNumberRow(
                    "Maximum samples",
                    value: $settings.exactSimMaxSamples,
                    range: AppSettings.Ranges.exactSimSamples,
                    step: 10_000,
                    unit: "samples",
                    help: "Hard cap on samples when the target is never reached; at least two are required to estimate variance.",
                    glossary: DS.Glossary.maxSamples,
                    crossCheck: adaptiveOrderError
                )
                .settingsAnchor("mlmc.maxSamples", label: "Maximum samples")
            }
            .disabled(!settings.exactSimAdaptive)
        } header: {
            Text("Adaptive Sampling")
        } footer: {
            Label {
                SettingsFootnote("Run adaptively only when T and L are large enough that bias is below ε (the auto defaults usually are). The maximum is a required hard cost cap; estimates that reach it before the SE target are saved as Partial.")
            } icon: {
                Image(systemName: DS.Symbol.warning)
                    .foregroundStyle(DS.Color.warningText)
            }
        }
    }

    private var parallelismSection: some View {
        Section {
            SettingsMenuRow(
                "Backend",
                selection: $settings.exactSimBackend,
                options: AppSettings.Choices.exactSimBackend,
                help: "Threading library used by rbm_mlmc. Auto prefers OpenMP when the binary was built with it.",
                glossary: DS.Glossary.mlmcBackend,
                title: { ["Auto", "OpenMP", "Apple GCD", "Serial"][$0] },
                detail: {
                    ["OpenMP when rbm_mlmc was built with it, otherwise Apple GCD.",
                     "OpenMP worker threads; fastest when the binary was built with libomp.",
                     "Grand Central Dispatch with Accelerate; no OpenMP needed.",
                     "One thread — reproduces a run exactly, at single-core speed."][$0]
                }
            )
            .settingsAnchor("mlmc.backend", label: "Backend")

            SettingsNumberRow(
                "Threads",
                caption: "Leave empty for one thread per logical core (\(coreCount) on this Mac). Ignored by the Serial backend.",
                value: $settings.exactSimThreads,
                range: AppSettings.Ranges.exactSimThreads,
                unit: "cores",
                help: "Worker threads. Empty (stored as 0) uses one thread per logical core.",
                placeholder: "auto (\(coreCount))",
                zeroMeansAuto: true
            )
            .disabled(settings.exactSimBackend == 3)
            .settingsAnchor("mlmc.threads", label: "Threads")
        } header: {
            Text("Parallelism")
        }
    }

    private var reproducibilitySection: some View {
        Section {
            SettingsNumberRow(
                "Fixed random seed",
                caption: "When off, Qnet chooses a random base seed. Replication streams are hashed and recorded.",
                value: $settings.exactSimSeed,
                range: AppSettings.Ranges.exactSimSeed,
                help: "Base seed for deterministic, widely separated replication streams. Fix it to reproduce every recorded stream exactly.",
                toggle: $settings.exactSimSeedFixed
            )
            .settingsAnchor("mlmc.seed", label: "Fixed random seed")
        } header: {
            Text("Reproducibility")
        }
    }
}

// MARK: - Linear Program (BNAlp / srbm_lp)

/// Discretisation section shared by the orthant and rectangle LP panes:
/// auto / manual switches for grid_n and basis_m, the fields themselves,
/// the grid-type picker, and the recommendation for the network that is
/// actually open (`AppSettings.activeNetworkDimension`).
///
/// Auto / manual is local view state seeded from the stored value
/// (0 = auto) and changed only by the switch, so clearing or retyping the
/// field can never flip the row back to Auto under the user's cursor.
private struct LPDiscretisationSection<GridTypePicker: View>: View {
    @ObservedObject var settings: AppSettings
    let gridN: Binding<Int>
    let basisM: Binding<Int>
    /// "lp" or "flp" — prefix of the row anchors.
    let anchorPrefix: String
    /// Dimension quoted when no network is open.
    let fallbackDimension: Int
    let recommend: (Int) -> (Int, Int)
    let autoGridHelp: String
    let gridHelp: String
    let autoBasisHelp: String
    let basisHelp: String
    let tableFootnote: String
    @ViewBuilder let gridTypePicker: () -> GridTypePicker

    @State private var manualGrid = false
    @State private var manualBasis = false

    /// Station count of the front document, or the fallback.
    private var openDimension: Int? {
        guard let d = settings.activeNetworkDimension, d > 0 else { return nil }
        return d
    }

    private var dimension: Int { openDimension ?? fallbackDimension }
    private var recommended: (Int, Int) { recommend(dimension) }

    private var recommendationCaption: String {
        if let d = openDimension {
            return "For the open network (d = \(d))."
        }
        return "No network open — showing d = \(fallbackDimension)."
    }

    private var gridAuto: Binding<Bool> {
        Binding(
            get: { !manualGrid },
            set: { auto in
                manualGrid = !auto
                if auto {
                    gridN.wrappedValue = 0
                } else if gridN.wrappedValue == 0 {
                    gridN.wrappedValue = recommended.0
                }
            }
        )
    }

    private var basisAuto: Binding<Bool> {
        Binding(
            get: { !manualBasis },
            set: { auto in
                manualBasis = !auto
                if auto {
                    basisM.wrappedValue = 0
                } else if basisM.wrappedValue == 0 {
                    basisM.wrappedValue = recommended.1
                }
            }
        )
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: DS.Spacing.s) {
                    Text("grid_n \(recommended.0)  ·  basis_m \(recommended.1)")
                        .font(DS.Font.number)
                        .foregroundStyle(DS.Color.textPrimary)
                        .accessibilityLabel("Recommended grid_n \(recommended.0), basis_m \(recommended.1)")
                    DSGlossarySlot(label: "Recommended for the open network", text: nil)
                }
            } label: {
                SettingsLabel("Recommended for the open network", caption: recommendationCaption)
            }
            .help("The dimension-dependent sizes each run uses while a value is set to Auto. Follows the front network as you edit it.")
            .settingsAnchor("\(anchorPrefix).recommended", label: "Recommended for the open network")

            SettingsToggleRow(
                "Auto-scale grid_n by dimension",
                caption: "Off: the value below is used for every network.",
                isOn: gridAuto,
                help: autoGridHelp
            )
            .settingsAnchor("\(anchorPrefix).autoGrid", label: "Auto-scale grid_n by dimension")
            SettingsNumberRow(
                "Grid size (grid_n)",
                value: gridN,
                range: AppSettings.Ranges.lpGrid,
                unit: "cells / axis",
                help: gridHelp,
                glossary: DS.Glossary.gridN,
                placeholder: "\(recommended.0)",
                zeroMeansAuto: true
            )
            .disabled(!manualGrid)
            .settingsAnchor("\(anchorPrefix).gridN", label: "Grid size (grid_n)")

            SettingsToggleRow(
                "Auto-scale basis_m by dimension",
                caption: "Off: the value below is used for every network.",
                isOn: basisAuto,
                help: autoBasisHelp
            )
            .settingsAnchor("\(anchorPrefix).autoBasis", label: "Auto-scale basis_m by dimension")
            SettingsNumberRow(
                "Basis size (basis_m)",
                value: basisM,
                range: AppSettings.Ranges.lpBasis,
                unit: "terms",
                help: basisHelp,
                glossary: DS.Glossary.basisM,
                placeholder: "\(recommended.1)",
                zeroMeansAuto: true
            )
            .disabled(!manualBasis)
            .settingsAnchor("\(anchorPrefix).basisM", label: "Basis size (basis_m)")

            gridTypePicker()
        } header: {
            Text("Discretisation")
        } footer: {
            SettingsFootnote(tableFootnote)
        }
        .onAppear {
            manualGrid = gridN.wrappedValue != 0
            manualBasis = basisM.wrappedValue != 0
        }
        // Reset to Defaults (or any other external write) puts the switch
        // back in step with the stored value.
        .onChange(of: gridN.wrappedValue) { _, v in
            if v == 0 { manualGrid = false } else if !manualGrid { manualGrid = true }
        }
        .onChange(of: basisM.wrappedValue) { _, v in
            if v == 0 { manualBasis = false } else if !manualBasis { manualBasis = true }
        }
    }
}

private struct LinearProgramPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPane(.linearProgram, reset: { settings.resetLinearProgram() }) {
            LPDiscretisationSection(
                settings: settings,
                gridN: $settings.lpGridN,
                basisM: $settings.lpBasisM,
                anchorPrefix: "lp",
                fallbackDimension: 3,
                recommend: BNASRBMExporter.recommendedBNAlpGrid(forDimension:),
                autoGridHelp: "When on, the grid size follows the dimension-dependent table from the paper's experiments.",
                gridHelp: "Points per axis of the discretisation grid. The LP has roughly nᵈ variables, so n must shrink as d grows.",
                autoBasisHelp: "When on, the polynomial basis size follows the dimension-dependent table.",
                basisHelp: "Number of monomial basis functions per boundary block.",
                tableFootnote: "LP size is about nᵈ variables. Recommended (grid_n, basis_m): d ≤ 2 → (100, 6), d = 3 → (25, 5), d = 4 → (12, 4), d = 5 → (10, 3), d = 6 → (8, 3), d ≥ 7 → (6, 3)."
            ) {
                SettingsMenuRow(
                    "Grid type",
                    selection: $settings.lpGridType,
                    options: AppSettings.Choices.lpGridType,
                    help: "Spacing of the grid points along each axis.",
                    glossary: DS.Glossary.gridTypeOrthant,
                    title: { ["Exponential", "Dyadic", "Exponential (randomised)"][$0] },
                    detail: {
                        ["Default. Points cluster near the origin, where the density has most of its mass.",
                         "Spacing halves at each step from the origin.",
                         "The exponential grid, jittered to break ties in a degenerate LP."][$0]
                    }
                )
                .settingsAnchor("lp.gridType", label: "Grid type")
            }

            Section {
                SettingsMenuRow(
                    "LP backend",
                    selection: $settings.lpSolver,
                    options: AppSettings.Choices.lpSolver,
                    help: "CPLEX is fastest for d ≤ 3, HiGHS scales better at d ≥ 4, GLPK is the universal fallback.",
                    glossary: DS.Glossary.lpBackend,
                    title: { ["Auto", "CPLEX", "GLPK", "HiGHS"][$0] },
                    detail: {
                        ["CPLEX if installed, then HiGHS, then GLPK.",
                         "Fastest on d ≤ 3. Must be installed separately.",
                         "The universal fallback; slowest on large programs. Must be installed separately.",
                         "Scales best at d ≥ 4 and ships with the app."][$0]
                    }
                )
                .settingsAnchor("lp.solver", label: "LP backend")
            } header: {
                Text("Solver")
            } footer: {
                SettingsFootnote("CPLEX is fastest on d ≤ 3; HiGHS scales better at d ≥ 4; GLPK is the universal fallback. Auto picks the first one that is installed.")
            }

            Section {
                SettingsToggleRow(
                    "Normalise monomial basis",
                    caption: "Recommended for d ≥ 3.",
                    isOn: $settings.lpBasisNormalize,
                    help: "Rescales polynomial columns to unit magnitude, which reduces LP conditioning problems at higher degrees."
                )
                .settingsAnchor("lp.basisNormalize", label: "Normalise monomial basis")

                SettingsNumberRow(
                    "Smoothness weight",
                    caption: "0 = off. Try 1e-4 if a run reports a range of plausible solutions.",
                    value: $settings.lpSmoothness,
                    range: AppSettings.Ranges.lpSmoothness,
                    step: 0.0001,
                    format: .number.precision(.fractionLength(0...6)),
                    help: "Adds a total-variation penalty that breaks degenerate LPs toward a smooth solution.",
                    glossary: DS.Glossary.smoothness
                )
                .settingsAnchor("lp.smoothness", label: "Smoothness weight")
            } header: {
                Text("Numerical Stability")
            }

            Section {
                SettingsToggleRow(
                    "Ask for parameters before each run",
                    caption: "A small dialog after Run ▸ Linear Program lets you adjust these values for that run only.",
                    isOn: $settings.lpAskBeforeRun,
                    help: "Show a per-run parameter dialog."
                )
                .settingsAnchor("lp.askBeforeRun", label: "Ask for parameters before each run")

                SettingsToggleRow(
                    "Multi-level refinement",
                    caption: "Runs a fast coarse LP (grid_n ÷ 2) as a preview, then the full-resolution LP.",
                    isOn: $settings.lpMultiLevel,
                    help: "Useful for d ≥ 3 where the full run is slow."
                )
                .settingsAnchor("lp.multiLevel", label: "Multi-level refinement")
            } header: {
                Text("Run-time Behaviour")
            }

            Section {
                SettingsReferenceButton(
                    title: "Performance Hints…",
                    text: AlgorithmHelp.linearProgramPerformanceHints,
                    help: "Show the recommended grid / basis table and timing notes."
                )
                .settingsAnchor("lp.hints", label: "Performance Hints…")
            } header: {
                Text("Reference")
            }
        }
    }
}

// MARK: - Finite-Buffer Linear Program (fBNAlp)

private struct FiniteLPPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPane(.finiteLP, reset: { settings.resetFiniteLP() }) {
            LPDiscretisationSection(
                settings: settings,
                gridN: $settings.flpGridN,
                basisM: $settings.flpBasisM,
                anchorPrefix: "flp",
                fallbackDimension: 2,
                recommend: SRBMExporter.recommendedFiniteLPGrid(forDimension:),
                autoGridHelp: "When on, the grid size follows the finite-buffer table (smaller than the orthant LP because the rectangle has 2d boundary blocks).",
                gridHelp: "Points per axis of the discretisation grid on the rectangle.",
                autoBasisHelp: "When on, the polynomial basis size follows the finite-buffer table.",
                basisHelp: "Number of monomial basis functions per boundary block.",
                tableFootnote: "Recommended (grid_n, basis_m) for the rectangle LP: d = 1 → (64, 8), d = 2 → (20, 6), d = 3 → (12, 4), d = 4 → (8, 3), d ≥ 5 → (6, 3)."
            ) {
                SettingsMenuRow(
                    "Grid type",
                    selection: $settings.flpGridType,
                    options: AppSettings.Choices.flpGridType,
                    help: "Uniform spacing, or Chebyshev nodes clustered toward the buffer boundaries.",
                    glossary: DS.Glossary.gridTypeRectangle,
                    title: { ["Uniform", "Chebyshev"][$0] },
                    detail: {
                        ["Default. Points are evenly spaced across the rectangle.",
                         "Points cluster toward the two buffer boundaries, where the density changes fastest."][$0]
                    }
                )
                .settingsAnchor("flp.gridType", label: "Grid type")
            }

            Section {
                // Tag order follows fBNAlp's `solverNames = ["highs", "glpk",
                // "cplex"]` in QnetGUIApp — note this differs from lp.solver.
                SettingsMenuRow(
                    "LP backend",
                    selection: $settings.flpSolver,
                    options: AppSettings.Choices.flpSolver,
                    help: "LP solver passed to fBNAlp_solver --solver. HiGHS ships with the app; GLPK and CPLEX must be installed separately.",
                    glossary: DS.Glossary.lpBackend,
                    title: { ["HiGHS", "GLPK", "CPLEX"][$0] },
                    detail: {
                        ["Default. Ships with the app, so it works everywhere.",
                         "The universal fallback. Must be installed separately.",
                         "Fastest when available. Must be installed separately."][$0]
                    }
                )
                .settingsAnchor("flp.solver", label: "LP backend")
            } header: {
                Text("Solver")
            } footer: {
                SettingsFootnote("HiGHS is bundled and works everywhere; CPLEX is fastest when available; GLPK is the universal fallback.")
            }

            Section {
                SettingsToggleRow(
                    "Normalise monomial basis",
                    caption: "Recommended for d ≥ 3.",
                    isOn: $settings.flpBasisNormalize,
                    help: "Rescales polynomial columns to unit magnitude, which reduces LP conditioning problems at higher degrees."
                )
                .settingsAnchor("flp.basisNormalize", label: "Normalise monomial basis")
            } header: {
                Text("Numerical Stability")
            } footer: {
                // flp.askBeforeRun is intentionally not exposed: the finite LP
                // run path never reads it (only the orthant LP honours
                // lp.askBeforeRun). The key is kept in AppSettings so a
                // future wiring can pick it up without a migration.
                SettingsFootnote("Used by Run ▸ Finite-Buffer LP and by finite test-set sweeps. Reference text: Help ▸ Finite-Buffer LP Algorithm.")
            }
        }
    }
}

// MARK: - Solver Engine

/// Which implementation runs, for the three methods that ship two.
///
/// The pane's job is to make the choice legible: these are not two algorithms
/// with two answers. Each C engine reproduces its Python counterpart's
/// arithmetic step for step and a parity test compares them on every packaged
/// example, so the picker chooses how long the user waits and nothing else. The
/// footnote under each row carries the measured speedup rather than an
/// adjective, and the section at the bottom says what is actually verified —
/// including the two places where agreement is a tolerance rather than an
/// equality, because a claim of "identical" that quietly has exceptions is
/// worse than a precise one.
private struct SolverEnginePane: View {
    @ObservedObject var settings: AppSettings

    private func engineRow(_ method: DualEngineMethod, selection: Binding<Int>) -> some View {
        // `detail` is the caption under the row and describes the CURRENT
        // selection, so it carries the consequence of the choice the user has
        // actually made rather than a general blurb.
        SettingsMenuRow(
            "Engine",
            selection: selection,
            options: AppSettings.Choices.solverEngine,
            help: "\(method.summary) Both engines compute the same result; the C one is "
                + "faster. \(method.measuredSpeedup).",
            title: { SolverEngine(storedValue: $0).title },
            // The caption describes the CURRENT selection and nothing else.
            // The measurement lives in the section footnote, once — an earlier
            // draft printed it here as well and the same sentence appeared
            // twice, six lines apart.
            detail: {
                SolverEngine(storedValue: $0) == .c
                    ? "The native binary. Same result as the Python engine, sooner."
                    : "The reference implementation: readable, needs no compiler, "
                      + "and the engine to reach for when a result looks wrong."
            }
        )
        .settingsAnchor(method.storageKey, label: "Engine")
    }

    var body: some View {
        SettingsPane(.solverEngine, reset: { settings.resetSolverEngine() }) {
            Section {
                engineRow(.regenerativeMonteCarlo, selection: $settings.engineRegenerative)
            } header: {
                Text("Regenerative Monte Carlo")
            } footer: {
                SettingsFootnote("Run ▸ Regenerative Monte Carlo. Both engines draw the same random stream, so a run reports the same cycles and the same estimates whichever is selected. \(DualEngineMethod.regenerativeMonteCarlo.measuredSpeedup).")
            }

            Section {
                engineRow(.matrixAnalyticQBD, selection: $settings.engineQBD)
            } header: {
                Text("Exact Matrix-Analytic QBD")
            } footer: {
                SettingsFootnote("Run ▸ Exact Matrix-Analytic QBD. \(DualEngineMethod.matrixAnalyticQBD.measuredSpeedup); the gap widens as the fourth power of the phase count, so the choice matters most on the models that take longest.")
            }

            Section {
                engineRow(.truncatedCTMC, selection: $settings.engineCTMC)
            } header: {
                Text("Markovian CTMC")
            } footer: {
                SettingsFootnote("One choice for two solvers: Run ▸ Adaptive Truncated CTMC and Run ▸ Exact Sparse CTMC share a power-iteration kernel, so they share this setting. \(DualEngineMethod.truncatedCTMC.measuredSpeedup).")
            }

            Section {
                SettingsFootnote(
                    "These are two implementations of one algorithm, not two methods. "
                    + "Each C engine was written to reproduce its Python counterpart's "
                    + "arithmetic operation by operation, and each ships a parity test that "
                    + "runs both on every packaged example and compares the output."
                )
                .settingsAnchor("engine.parity", label: "How the engines are kept identical")
                SettingsFootnote(
                    "What is verified: the report each method prints is byte-identical "
                    + "between engines, and so is every refusal message for an invalid "
                    + "document. Two known exceptions, both measured: confidence-interval "
                    + "bounds in the 17-digit machine records agree to about 1e-12 rather "
                    + "than exactly, because Python ships its own lgamma; and a "
                    + "simulation stopped by its wall-clock safeguard stops at a different "
                    + "cycle in each engine, because one of them is 250 times faster."
                )
                SettingsFootnote(
                    "If the selected engine is not installed — a source checkout that has "
                    + "not run build_all_algorithms.sh, say — the other one runs and the "
                    + "Status pane says so. A missing binary never turns into a method you "
                    + "cannot run."
                )
            } header: {
                Text("Why There Are Two")
            }
        }
    }
}

// MARK: - Finite Element

private struct FiniteElementPane: View {
    @ObservedObject var settings: AppSettings

    /// Mesh exceeds the run dialog's cap for the open network's dimension.
    private var meshCaution: String? {
        guard let d = settings.activeNetworkDimension, d > 0 else { return nil }
        let cap = AppSettings.femMeshCap(forDimension: d)
        guard settings.femMeshSize > cap else { return nil }
        return "Mesh \(settings.femMeshSize) exceeds the cap of \(cap) for the open network (d = \(d)); the run dialog will start from \(cap). Cost grows as n²ᵈ."
    }

    var body: some View {
        SettingsPane(.finiteElement, reset: { settings.resetFiniteElement() }) {
            Section {
                SettingsMenuRow(
                    "Quadrature method",
                    selection: $settings.femSolver,
                    options: AppSettings.Choices.femSolver,
                    help: "Integration rule used to assemble the finite-element matrices (bna_fm_gauss or bna_fm_cbc).",
                    glossary: DS.Glossary.quadrature,
                    title: { ["Gauss–Legendre", "CBC quasi-Monte Carlo"][$0] },
                    detail: {
                        ["Exactly-weighted points per element (bna_fm_gauss); the accurate choice at low dimension.",
                         "Lattice rule (bna_fm_cbc); cost grows far more slowly with the number of stations."][$0]
                    }
                )
                .settingsAnchor("fem.solver", label: "Quadrature method")
            } header: {
                Text("Quadrature")
            }

            Section {
                SettingsNumberRow(
                    "Mesh size",
                    caption: "Elements along each axis of the hypercube.",
                    value: $settings.femMeshSize,
                    range: AppSettings.Ranges.femMeshSize,
                    unit: "/ axis",
                    help: "Finer meshes are more accurate, but cost grows as n²ᵈ.",
                    glossary: DS.Glossary.meshSize
                )
                .settingsAnchor("fem.meshSize", label: "Mesh size")

                if let meshCaution {
                    InlineFieldMessage(meshCaution, severity: .warning)
                }
            } header: {
                Text("Mesh")
            } footer: {
                SettingsFootnote("Cost grows as n²ᵈ, so the run dialog caps the mesh by dimension: d ≤ 3 → \(AppSettings.femMeshCap(forDimension: 3)), d = 4 → \(AppSettings.femMeshCap(forDimension: 4)), d = 5 → \(AppSettings.femMeshCap(forDimension: 5)), d ≥ 6 → \(AppSettings.femMeshCap(forDimension: 6)). The value here is the suggestion the dialog starts from.")
            }
        }
        .dsAnimation(DS.Motion.quick, value: meshCaution)
    }
}

// MARK: - Spectral Method

private struct SpectralPane: View {
    @ObservedObject var settings: AppSettings

    /// Monomials above degree 10 are ill-conditioned; the footnote says so,
    /// this row says so at the moment it applies.
    private var basisCaution: String? {
        guard settings.smDegree > 10, !settings.smLegendre else { return nil }
        return "Monomial basis is ill-conditioned above degree 10 — enable Legendre."
    }

    var body: some View {
        SettingsPane(.spectral, reset: { settings.resetSpectral() }) {
            Section {
                SettingsNumberRow(
                    "Polynomial degree",
                    caption: "Maximum total degree of the Galerkin trial space.",
                    value: $settings.smDegree,
                    range: AppSettings.Ranges.smDegree,
                    help: "Higher degree converges faster on smooth densities but the linear system grows combinatorially with d.",
                    glossary: DS.Glossary.polynomialDegree
                )
                .settingsAnchor("sm.degree", label: "Polynomial degree")

                SettingsToggleRow(
                    "Use Legendre basis",
                    caption: "Orthogonal basis instead of raw monomials.",
                    isOn: $settings.smLegendre,
                    help: "Legendre polynomials keep the system well-conditioned at high degree."
                )
                .settingsAnchor("sm.legendre", label: "Use Legendre basis")

                if let basisCaution {
                    InlineFieldMessage(basisCaution, severity: .warning)
                }
            } header: {
                Text("Basis")
            } footer: {
                SettingsFootnote("Legendre basis is recommended above degree 10; the monomial basis becomes ill-conditioned there. Used by bnet (orthant) and srbm_solver (rectangle).")
            }
        }
        .dsAnimation(DS.Motion.quick, value: basisCaution)
    }
}

// MARK: - Test Sets

private struct TestSetsPane: View {
    @ObservedObject var settings: AppSettings

    private func topologyBinding(_ raw: Binding<Int>) -> Binding<RandomNetworkGenerator.Topology> {
        Binding(
            get: { RandomNetworkGenerator.Topology(rawValue: raw.wrappedValue) ?? .feedForward },
            set: { raw.wrappedValue = $0.rawValue }
        )
    }

    var body: some View {
        SettingsPane(.testSets, reset: { settings.resetTestSets() }) {
            Section {
                SettingsRangeRow("Stations", lo: $settings.testsetInfStationsLo, hi: $settings.testsetInfStationsHi,
                                 range: AppSettings.Ranges.testsetStations,
                                 help: "Range of station counts (dimension d) drawn for each random case.")
                    .settingsAnchor("testset.inf.stations", label: "Stations")
                SettingsRangeRow("Classes", lo: $settings.testsetInfClassesLo, hi: $settings.testsetInfClassesHi,
                                 range: AppSettings.Ranges.testsetClasses,
                                 help: "Range of customer-class counts drawn for each random case.")
                    .settingsAnchor("testset.inf.classes", label: "Classes")
                SettingsRangeRow("Utilisation ρ", lo: $settings.testsetInfRhoLo, hi: $settings.testsetInfRhoHi,
                                 range: AppSettings.Ranges.testsetRho, step: 0.05,
                                 help: "Range of bottleneck utilisations targeted by the generated networks.",
                                 glossary: DS.Glossary.rho)
                    .settingsAnchor("testset.inf.rho", label: "Utilisation ρ")
                SettingsNumberRow("Number of cases", value: $settings.testsetInfNumCases,
                                  range: AppSettings.Ranges.testsetNumCases, unit: "cases",
                                  help: "Random networks generated and solved in one sweep.")
                    .settingsAnchor("testset.inf.numCases", label: "Number of cases")
                topologyPicker(topologyBinding($settings.testsetInfTopology))
                    .settingsAnchor("testset.inf.topology", label: "Topology")
            } header: {
                Text("Infinite Test Set")
            } footer: {
                SettingsFootnote("Pre-populates Test ▸ Run Infinite Test Set. Values entered in that dialog override these for the one run.")
            }

            Section {
                SettingsRangeRow("Stations", lo: $settings.testsetFinStationsLo, hi: $settings.testsetFinStationsHi,
                                 range: AppSettings.Ranges.testsetStations,
                                 help: "Range of station counts (dimension d). Finite solvers scale as n²ᵈ, so keep this small.")
                    .settingsAnchor("testset.fin.stations", label: "Stations")
                SettingsRangeRow("Classes", lo: $settings.testsetFinClassesLo, hi: $settings.testsetFinClassesHi,
                                 range: AppSettings.Ranges.testsetClasses,
                                 help: "Range of customer-class counts drawn for each random case.")
                    .settingsAnchor("testset.fin.classes", label: "Classes")
                SettingsRangeRow("Utilisation ρ", lo: $settings.testsetFinRhoLo, hi: $settings.testsetFinRhoHi,
                                 range: AppSettings.Ranges.testsetRho, step: 0.05,
                                 help: "Range of bottleneck utilisations targeted by the generated networks.",
                                 glossary: DS.Glossary.rho)
                    .settingsAnchor("testset.fin.rho", label: "Utilisation ρ")
                SettingsNumberRow("Number of cases", value: $settings.testsetFinNumCases,
                                  range: AppSettings.Ranges.testsetNumCases, unit: "cases",
                                  help: "Random networks generated and solved in one sweep.")
                    .settingsAnchor("testset.fin.numCases", label: "Number of cases")
                topologyPicker(topologyBinding($settings.testsetFinTopology))
                    .settingsAnchor("testset.fin.topology", label: "Topology")
            } header: {
                Text("Finite Test Set")
            } footer: {
                SettingsFootnote("Pre-populates Test ▸ Run Finite Test Set.")
            }

            Section {
                SettingsRangeRow("Stations", lo: $settings.testsetSpcStationsLo, hi: $settings.testsetSpcStationsHi,
                                 range: AppSettings.Ranges.testsetStations,
                                 help: "Range of station counts (dimension d) drawn for each generated network.")
                    .settingsAnchor("testset.spc.stations", label: "Stations")
                SettingsRangeRow("Classes", lo: $settings.testsetSpcClassesLo, hi: $settings.testsetSpcClassesHi,
                                 range: AppSettings.Ranges.testsetClasses,
                                 help: "Range of customer-class counts drawn for each generated network.")
                    .settingsAnchor("testset.spc.classes", label: "Classes")
                SettingsRangeRow("ρ sweep start … end", lo: $settings.testsetSpcRhoStart, hi: $settings.testsetSpcRhoEnd,
                                 range: AppSettings.Ranges.testsetRho, step: 0.05,
                                 help: "Each generated network is solved at every ρ from start to end.",
                                 glossary: DS.Glossary.rho,
                                 strict: true)
                    .settingsAnchor("testset.spc.rhoRange", label: "ρ sweep start … end")
                SettingsNumberRow("ρ step", value: $settings.testsetSpcRhoStep,
                                  range: AppSettings.Ranges.testsetRhoStep, step: 0.01,
                                  format: .number.precision(.fractionLength(2)),
                                  help: "Increment between successive ρ values in the sweep.",
                                  glossary: DS.Glossary.rho)
                    .settingsAnchor("testset.spc.rhoStep", label: "ρ step")
                SettingsNumberRow("Number of cases", value: $settings.testsetSpcNumCases,
                                  range: AppSettings.Ranges.testsetNumCases, unit: "cases",
                                  help: "Random networks generated; each is swept across the whole ρ grid.")
                    .settingsAnchor("testset.spc.numCases", label: "Number of cases")
                topologyPicker(topologyBinding($settings.testsetSpcTopology))
                    .settingsAnchor("testset.spc.topology", label: "Topology")
            } header: {
                Text("Spectral Convergence")
            } footer: {
                SettingsFootnote("Pre-populates Test ▸ Run Infinite Spectral Convergence. ρ is a start / end / step grid rather than a min–max range. \(spectralSweepSummary)")
            }
        }
    }

    /// Number of ρ values in the start … end grid at the given step.
    private var spectralRhoCount: Int {
        let start = settings.testsetSpcRhoStart, end = settings.testsetSpcRhoEnd, step = settings.testsetSpcRhoStep
        guard step > 0, end >= start else { return 0 }
        return Int(((end - start) / step + 1e-9).rounded(.down)) + 1
    }

    /// "10 cases × 10 ρ values = 100 spectral solves", live.
    private var spectralSweepSummary: String {
        let cases = settings.testsetSpcNumCases
        let rhos = spectralRhoCount
        guard rhos > 0 else { return "The ρ grid is empty — end must be greater than start." }
        let total = cases * rhos
        return "\(cases.formatted()) \(cases == 1 ? "case" : "cases") × \(rhos.formatted()) ρ \(rhos == 1 ? "value" : "values") = \(total.formatted()) spectral \(total == 1 ? "solve" : "solves")."
    }

    private func topologyPicker(_ selection: Binding<RandomNetworkGenerator.Topology>) -> some View {
        SettingsMenuRow(
            "Topology",
            selection: selection,
            options: RandomNetworkGenerator.Topology.allCases,
            help: "Routing structure of the generated networks.",
            glossary: DS.Glossary.topology,
            title: { t in
                switch t {
                case .feedForward:       return "Feed-forward"
                case .jacksonFeedback:   return "Jackson + feedback"
                case .generalPMatrix:    return "General P-matrix"
                case .reentrantFeedback: return "Re-entrant"
                }
            },
            detail: { t in
                switch t {
                case .feedForward:       return "Every job routes strictly downstream."
                case .jacksonFeedback:   return "Feed-forward plus random return arcs."
                case .generalPMatrix:    return "An arbitrary routing matrix."
                case .reentrantFeedback: return "A class revisits a station — the hardest case for decompositions."
                }
            }
        )
    }
}

// MARK: - Output Format

private struct OutputFormatPane: View {
    @ObservedObject var settings: AppSettings

    private var example: String {
        let d = max(0, min(9, settings.outputDecimals))
        return String(format: "ρ = %.\(d)f", 0.8123456789)
    }

    var body: some View {
        SettingsPane(.outputFormat, reset: { settings.resetOutputFormat() }) {
            Section {
                SettingsNumberRow(
                    "Decimal places",
                    caption: "Example: \(example)",
                    value: $settings.outputDecimals,
                    range: AppSettings.Ranges.outputDecimals,
                    unit: "digits",
                    help: "Digits after the decimal point for every number the solvers print, in the Interactive Shell and in the Results pane."
                )
                .settingsAnchor("output.decimals", label: "Decimal places")
            } header: {
                Text("Numeric Display")
            } footer: {
                SettingsFootnote("Applies to every method's results in the Interactive Shell and to the Results pane. Display only: solver precision, the saved run output and CSV export all keep full precision. A value too small to show at this precision is printed in scientific notation rather than as a flat zero, and so is one large enough that a fixed rendering would be mostly floating-point noise. Whole numbers, percentages, version numbers, file paths and the advisory text of Analyze Network, Network Primitives and the Help pages keep their values; only the spelling of an exponent is regularised, so one line cannot show both 1e-9 and 6.02e23. Six is the ceiling because that is the precision the solvers themselves print.")
            }
        }
    }
}

// MARK: - Panes (fonts and colours of the Shell, Status and AI panes)

/// Tab raw value stays "Interactive Shell Window" for the persisted
/// selection; the user sees "Panes", the pane that sets the type and
/// colours of the Shell, Status and AI Assistant panes. Every value here
/// is also reachable from the matching pane header (font menu, A+ / A−),
/// which writes the same keys — Settings is the place to see all three at
/// once.
private struct AppearancePane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPane(.shell, reset: { settings.resetInterface() }) {
            Section {
                SettingsFontFamilyRow(
                    label: "Font",
                    caption: "Fixed-pitch families only — the Shell pane needs equal-width cells.",
                    selection: $settings.shellFontName,
                    help: "Font family for the Shell pane. Also in the Shell pane header.",
                    allowsProportional: false
                )
                .settingsAnchor("shell.fontName", label: "Font")

                SettingsSliderRow(
                    "Text size",
                    value: $settings.shellFontSize,
                    range: AppSettings.Ranges.fontSize,
                    step: 1,
                    unit: "pt",
                    help: "Point size of the Shell pane font. Also the A+ / A− buttons in the Shell pane header (⌘= / ⌘− while it has focus)."
                )
                .settingsAnchor("shell.fontSize", label: "Text size")

                SettingsToggleRow(
                    "Classic green-on-black",
                    caption: "Off: the Shell pane follows the system text and background colours (light and dark).",
                    isOn: $settings.shellClassicTheme,
                    help: "Use the classic green-on-black palette in the Shell pane instead of the semantic text and background colours."
                )
                .settingsAnchor("shell.classicTheme", label: "Classic green-on-black")
            } header: {
                Text("Shell")
            } footer: {
                SettingsFootnote("Changes apply immediately. The font and text size are also in the Shell pane header; both places edit the same setting.")
            }

            Section {
                SettingsSliderRow(
                    "Text size",
                    value: $settings.statusFontSize,
                    range: AppSettings.Ranges.fontSize,
                    step: 1,
                    unit: "pt",
                    help: "Point size of the Status pane log. Also the A+ / A− buttons in the Status pane header."
                )
                .settingsAnchor("status.fontSize", label: "Text size")
            } header: {
                Text("Status")
            } footer: {
                // The one asymmetry in this pane, stated rather than left
                // for the reader to notice: Shell and AI offer a family,
                // Status does not.
                SettingsFootnote("Only the size is adjustable here. The Status log is fixed to the system monospaced face so its severity glyph, timestamp and message columns line up with the solver output pasted into it — a proportional family would break that grid. Text size is also in the Status pane header (A+ / A−).")
            }

            Section {
                SettingsFontFamilyRow(
                    // Same words as the tooltip on the font menu in the AI
                    // pane header, because it is the same setting: this
                    // family draws fenced code and tool output only.
                    label: "Code font",
                    // The pane header's font menu is tooltipped "Code font
                    // (fenced code and tool output; prose uses the system
                    // font)"; it is the same setting, so it is described the
                    // same way here. "Show all fonts" stays available — the
                    // header menu lists fixed-pitch families only, and this
                    // is the one place a proportional face can be chosen.
                    caption: "Fenced code and tool output; prose uses the system font. Fixed-pitch families only unless “Show all fonts” is on.",
                    selection: $settings.aiFontName,
                    help: "Code font (fenced code and tool output; prose uses the system font). Also in the AI Assistant pane header."
                )
                .settingsAnchor("ai.fontName", label: "Code font")

                SettingsSliderRow(
                    "Text size",
                    value: $settings.aiFontSize,
                    range: AppSettings.Ranges.fontSize,
                    step: 1,
                    unit: "pt",
                    help: "Point size of the AI Assistant transcript — prose and code alike. Also the A+ / A− buttons in the AI Assistant pane header."
                )
                .settingsAnchor("ai.fontSize", label: "Text size")
            } header: {
                Text("AI Assistant")
            } footer: {
                SettingsFootnote("Text size governs prose and code together, so the transcript reads at one size. Both settings are also in the AI Assistant pane header (font menu, A+ / A−).")
            }
        }
    }
}

// MARK: - Help

private struct HelpPane: View {
    @ObservedObject var settings: AppSettings

    private var destination: Binding<HelpOutputDestination> {
        Binding(
            get: { HelpOutputDestination(rawValue: settings.helpOutputDestination) ?? .popup },
            set: { settings.helpOutputDestination = $0.rawValue }
        )
    }

    var body: some View {
        SettingsPane(.helpMenu, reset: { settings.resetHelp() }) {
            Section {
                // A pop-up like every other choice in the window (it was
                // the one radio group), with the destination's behaviour as
                // the selection-dependent caption.
                SettingsMenuRow(
                    "Send help output to",
                    selection: destination,
                    options: HelpOutputDestination.allCases,
                    help: "Where the text of the Help menu items is shown.",
                    title: { $0.displayName },
                    detail: { hint(for: $0) }
                )
                .settingsAnchor("help.outputDestination", label: "Send help output to")
            } header: {
                Text("Help Menu")
            } footer: {
                SettingsFootnote("Applies to the Method Reference and Connect an AI Provider topics in the Help menu. Qnet Help (⌘?) — including the SRBM MLMC Guide — and Release Notes always open their own windows.")
            }
        }
    }

    private func hint(for d: HelpOutputDestination) -> String {
        switch d {
        case .statusWindow:
            return "Help text is appended to the Status pane in the top-right of the main window, bracketed by divider lines."
        case .interactiveShell:
            return "Help text is piped into the Shell pane and stays in the scrollback alongside command results."
        case .popup:
            return "The topic opens in the searchable Qnet Help window (non-modal, alongside the main window). The main window stays interactive."
        }
    }
}

// MARK: - AI Assistant

private struct AIAssistantPane: View {
    @ObservedObject var settings: AppSettings

    private struct TestResult: Equatable {
        let kind: SettingsStatusLabel.Kind
        let text: String
    }

    // The API key is the one deferred value: it is written to the Keychain
    // when the field loses focus, when the provider changes, when the pane
    // disappears, or via the explicit Save Key button.
    @State private var apiKey = ""
    /// Value last read from / written to the Keychain; `keyDirty` means
    /// the field differs from it.
    @State private var loadedKey = ""
    @State private var keyDirty = false
    @State private var showKey = false
    @FocusState private var keyFocused: Bool

    @State private var discoveredModels: [String] = []
    @State private var refreshingModels = false
    @State private var refreshError = ""

    @State private var testing = false
    @State private var testResult: TestResult? = nil

    private var provider: Binding<LLMProvider> {
        Binding(
            get: { settings.aiProviderResolved },
            set: { new in
                let old = settings.aiProviderResolved
                guard new != old else { return }
                flushKey(for: old)
                settings.aiProvider = new.rawValue
                loadPerProvider(new)
            }
        )
    }

    private var baseURL: Binding<String> {
        Binding(
            get: { settings.aiBaseURL(for: settings.aiProviderResolved) },
            set: { settings.setAIBaseURL($0, for: settings.aiProviderResolved) }
        )
    }

    private var model: Binding<String> {
        Binding(
            get: { settings.aiModel(for: settings.aiProviderResolved) },
            set: { settings.setAIModel($0, for: settings.aiProviderResolved) }
        )
    }

    var body: some View {
        SettingsPane(.ai, reset: { resetPane() }, resetKeys: SettingsRegistry.resetKeys(for: .ai)) {
            paneSection
            backendSection
            generationSection
            connectionSection
        }
        .onAppear { loadPerProvider(settings.aiProviderResolved) }
        .onDisappear { flushKey(for: settings.aiProviderResolved) }
    }

    // MARK: Sections

    private var paneSection: some View {
        Section {
            SettingsToggleRow(
                "Show AI Assistant pane",
                caption: "When off, the Shell pane expands to fill the bottom of the window.",
                isOn: $settings.aiPaneVisible,
                help: "Show or hide the AI Assistant pane in the main window. The same switch is under View ▸ Panes."
            )
            .settingsAnchor("ai.paneVisible", label: "Show AI Assistant pane")
        } header: {
            Text("Pane")
        } footer: {
            SettingsFootnote("Window layout rather than a setting: it is also under View ▸ Panes, and Reset to Defaults leaves it as it is.")
        }
    }

    private var backendSection: some View {
        Section {
            SettingsMenuRow(
                "Provider",
                selection: provider,
                options: LLMProvider.allCases,
                help: "Which chat-completion service the assistant talks to. Each provider keeps its own URL, model and key.",
                glossary: DS.Glossary.aiProvider,
                title: { $0.displayName },
                detail: { p in
                    p.requiresAPIKey
                        ? "Cloud service — needs an API key. Its URL, model and key are kept separately from the other providers'."
                        : "Local server — no key needed. Its URL and model are kept separately from the other providers'."
                }
            )
            .settingsAnchor("ai.provider", label: "Provider")

            DSTextField(
                label: "Base URL",
                caption: providerHint,
                text: baseURL,
                placeholder: provider.wrappedValue.defaultBaseURL,
                monospaced: true,
                help: "Endpoint of the chat-completion service for this provider",
                width: nil
            ) {
                DSIconMenu(
                    systemImage: DS.Symbol.list,
                    label: "Recommended endpoints",
                    help: "Pick a recommended endpoint for this provider"
                ) {
                    endpointMenuItems
                }
            }
            .settingsAnchor("ai.baseURL", label: "Base URL")

            DSTextField(
                label: "Model",
                text: model,
                placeholder: provider.wrappedValue.defaultModel,
                monospaced: true,
                help: "Model identifier sent with every request",
                width: nil
            ) {
                DSIconMenu(
                    systemImage: DS.Symbol.list,
                    label: "Model list",
                    help: "Pick a model for this provider"
                ) {
                    modelMenuItems
                }

                // The spinner replaces the glyph in place, so the row does
                // not change width while the request is out.
                if refreshingModels {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                        .accessibilityLabel("Refreshing model list")
                } else {
                    DSIconButton(
                        systemImage: DS.Symbol.refresh,
                        label: "Refresh model list",
                        help: "Ask the server for its list of available models"
                    ) {
                        refreshDiscoveredModels()
                    }
                }
            }
            .settingsAnchor("ai.model", label: "Model")

            if !refreshError.isEmpty {
                SettingsStatusLabel(kind: .failure, text: refreshError)
            }

            if provider.wrappedValue.requiresAPIKey {
                DSTextField(
                    label: "API key",
                    caption: "Stored in the macOS Keychain, never in preferences.",
                    text: $apiKey,
                    isSecure: !showKey,
                    monospaced: true,
                    help: "Secret key for this provider. Saved to the Keychain on Return, on focus loss or with Save Key",
                    width: nil,
                    focus: $keyFocused,
                    onSubmit: { flushKey(for: settings.aiProviderResolved) }
                ) {
                    DSIconToggle(
                        systemImage: showKey ? DS.Symbol.conceal : DS.Symbol.reveal,
                        isOn: $showKey,
                        label: "Reveal the API key",
                        help: showKey ? "Hide the API key" : "Show the API key in clear text"
                    )

                    Button("Save Key") { flushKey(for: settings.aiProviderResolved) }
                        .controlSize(.small)
                        .disabled(!keyDirty)
                        .help("Write the key to the macOS Keychain now. It is also saved automatically when the field loses focus.")
                        .accessibilityLabel("Save API key to Keychain")
                }
                .settingsAnchor("ai.apiKey", label: "API key")
                .onChange(of: apiKey) { _, newValue in keyDirty = (newValue != loadedKey) }
                .onChange(of: keyFocused) { _, focused in
                    if !focused { flushKey(for: settings.aiProviderResolved) }
                }
            } else {
                LabeledContent {
                    HStack(spacing: DS.Spacing.s) {
                        Text("Not required")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textSecondary)
                        DSGlossarySlot(label: "API key", text: nil)
                    }
                } label: {
                    SettingsLabel("API key", caption: "Local servers need no key. Make sure the server is running at the Base URL above.")
                }
                .settingsAnchor("ai.apiKey", label: "API key")
            }
        } header: {
            Text("Backend")
        }
    }

    private var generationSection: some View {
        Section {
            DSTextArea(
                label: "System prompt",
                caption: "Sent before every conversation.",
                text: $settings.aiSystemPrompt,
                monospaced: true,
                help: "Instructions the assistant receives before every conversation."
            )
            .settingsAnchor("ai.systemPrompt", label: "System prompt")

            SettingsNumberRow(
                "Max tokens",
                value: $settings.aiMaxTokens,
                range: AppSettings.Ranges.aiMaxTokens,
                step: 256,
                unit: "tokens",
                help: "Upper bound on the length of each reply."
            )
            .settingsAnchor("ai.maxTokens", label: "Max tokens")

            SettingsSliderRow(
                "Temperature",
                value: $settings.aiTemperature,
                range: AppSettings.Ranges.aiTemperature,
                step: 0.05,
                format: .number.precision(.fractionLength(2)),
                help: "Sampling randomness: 0 is deterministic, 1 is the provider default, above 1 is increasingly creative."
            )
            .settingsAnchor("ai.temperature", label: "Temperature")

            SettingsNumberRow(
                "Timeout",
                value: $settings.aiTimeoutSec,
                range: AppSettings.Ranges.aiTimeoutSec,
                step: 5,
                format: .number.precision(.fractionLength(0)),
                unit: "s",
                help: "How long to wait for a reply before giving up."
            )
            .settingsAnchor("ai.timeoutSec", label: "Timeout")
        } header: {
            Text("Generation")
        }
    }

    private var connectionSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                Button {
                    testConnection()
                } label: {
                    Label("Test Connection", systemImage: DS.Symbol.connection)
                }
                .disabled(testing)
                .help("Send a one-word prompt to the configured endpoint and show the reply.")
                .accessibilityLabel("Test connection")

                if testing {
                    SettingsStatusLabel(kind: .running, text: "Contacting \(provider.wrappedValue.displayName)…")
                } else if let testResult {
                    SettingsStatusLabel(kind: testResult.kind, text: testResult.text)
                }
                Spacer(minLength: 0)
            }
            .dsAnimation(DS.Motion.quick, value: testing)
            .dsAnimation(DS.Motion.quick, value: testResult)
            .settingsAnchor("ai.testConnection", label: "Test Connection")
        } header: {
            Text("Connection")
        } footer: {
            SettingsFootnote("Uses the provider, URL, model and key above exactly as the assistant will.")
        }
    }

    // MARK: Menu content

    /// Items of the Base URL row's endpoint menu (a Menu, so the
    /// separator is AppKit's own `Divider`).
    @ViewBuilder
    private var endpointMenuItems: some View {
        ForEach(provider.wrappedValue.recommendedBaseURLs, id: \.self) { url in
            Button(url) { baseURL.wrappedValue = url }
        }
        Divider()
        Button("Reset to default (\(provider.wrappedValue.defaultBaseURL))") {
            baseURL.wrappedValue = provider.wrappedValue.defaultBaseURL
        }
    }

    /// Items of the Model row's model menu.
    @ViewBuilder
    private var modelMenuItems: some View {
        if !discoveredModels.isEmpty {
            Section("From Server") {
                ForEach(discoveredModels, id: \.self) { name in
                    Button(name) { model.wrappedValue = name }
                }
            }
        }
        Section("Recommended") {
            ForEach(provider.wrappedValue.recommendedModels, id: \.self) { name in
                Button(name) { model.wrappedValue = name }
            }
        }
        Divider()
        Button("Reset to default (\(provider.wrappedValue.defaultModel))") {
            model.wrappedValue = provider.wrappedValue.defaultModel
        }
    }

    // MARK: Helpers

    private var providerHint: String {
        switch provider.wrappedValue {
        case .anthropic: return "Messages API; /v1/messages is appended."
        case .openai:    return "Chat Completions; /chat/completions is appended."
        case .ollama:    return "Start Ollama with `ollama serve`; /api/chat is appended."
        case .lmstudio:  return "Start LM Studio's OpenAI-compatible server; /chat/completions is appended."
        }
    }

    private func loadPerProvider(_ p: LLMProvider) {
        loadedKey = LLMKeychain.load(for: p)
        apiKey = loadedKey
        keyDirty = false
        discoveredModels = settings.aiDiscoveredModels(for: p)
        refreshError = ""
        testResult = nil
    }

    private func flushKey(for p: LLMProvider) {
        guard keyDirty, p.requiresAPIKey else { keyDirty = false; return }
        LLMKeychain.save(apiKey, for: p)
        loadedKey = apiKey
        keyDirty = false
    }

    private func resetPane() {
        settings.resetAI()
        discoveredModels = []
        refreshError = ""
        testResult = nil
    }

    private func refreshDiscoveredModels() {
        let p = settings.aiProviderResolved
        let url = baseURL.wrappedValue
        let key = apiKey
        refreshingModels = true
        refreshError = ""
        Task { @MainActor in
            defer { refreshingModels = false }
            do {
                let models = try await p.discoverModels(baseURL: url, apiKey: key)
                discoveredModels = models
                settings.setAIDiscoveredModels(models, for: p)
                if models.isEmpty {
                    refreshError = "Server returned an empty list. " +
                        (p == .lmstudio
                            ? "Load a model in LM Studio's Local Server tab and refresh again."
                            : "")
                }
            } catch {
                refreshError = "Refresh failed: \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() {
        flushKey(for: settings.aiProviderResolved)
        testing = true
        testResult = nil

        let config = settings.currentAIConfig()
        Task { @MainActor in
            defer { testing = false }
            do {
                let client = try LLMClientFactory.make(from: config)
                let blocks = try await client.send(
                    history: [LLMMessage(role: .user, text: "Say the single word: pong")],
                    tools: []
                )
                let text = blocks.compactMap { block -> String? in
                    if case let .text(t) = block { return t }
                    return nil
                }.joined(separator: " ")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
                testResult = TestResult(
                    kind: .success,
                    text: preview.isEmpty ? "Connected (no text returned)." : "Reply: \(preview)"
                )
            } catch {
                testResult = TestResult(kind: .failure, text: error.localizedDescription)
            }
        }
    }
}
