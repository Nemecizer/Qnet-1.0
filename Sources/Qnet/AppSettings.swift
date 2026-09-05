import SwiftUI
import Combine

@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Active network (not persisted)
    //
    // Station count (dimension d) of the front document, so Settings panes
    // can quote the grid / mesh recommendation for the network the user is
    // actually working on. `nil` until a tab has been tracked; 0 for an
    // empty canvas. QnetGUIApp calls `trackActiveEditor(_:)` whenever the
    // active tab changes; the Combine subscription follows node edits.
    @Published var activeNetworkDimension: Int? = nil
    private var activeEditorSubscription: AnyCancellable?

    /// Runs the one-shot stored-state repairs before anything reads a pane
    /// flag. `@AppStorage` initialises from `UserDefaults` on first access,
    /// and `QnetGUIApp` builds the single instance as a `@StateObject`
    /// before the window exists, so this is the last moment at which the
    /// stored values can still be corrected without a visible re-layout.
    init() {
        didRepairResultsPane = Self.repairAutoRevealedResultsPane()
    }

    /// True for exactly one launch, when `init` had to close the Results
    /// workspace that the old auto-reveal had pinned open. `ContentView`
    /// reads it once, writes the reason into the status log and clears it:
    /// a pane that closes itself between launches has to say so, or the
    /// repair is indistinguishable from a pane that has gone missing.
    /// Not persisted — it describes this launch, not the install.
    @Published var didRepairResultsPane = false

    /// Undoes the pane state the old "reveal the Results workspace on a
    /// run" behaviour left behind.
    ///
    /// That reveal fired on EVERY run and wrote `results.paneVisible = true`
    /// permanently, so a single solve added a seventh pane for good: three
    /// rows whose ideal heights sum to ~1016 pt in ~848 pt of content, which
    /// letterboxed the canvas to ~330 pt and the Shell to eleven rows. The
    /// guard added alongside `results.autoShown` stops the NEXT occurrence;
    /// it cannot help a user who is already carrying the state, because the
    /// guard reads `!resultsPaneVisible`, which is exactly what the bug
    /// made false.
    ///
    /// So: the first time this build runs on an install that predates
    /// `results.autoShown`, stamp the one-shot flag and — only in the case
    /// the bug actually created — put the pane back. "The case the bug
    /// created" is deliberately the same predicate the new auto-reveal
    /// uses: the Shell is showing, so the run was already visible there and
    /// the Results row was pure letterboxing. A user who works with the
    /// Shell closed keeps the Results pane, because for them it is the only
    /// place a run appears. The pane is one keystroke away either way
    /// (View ▸ Panes ▸ Results, ⌥⌘6) and no result record is touched.
    ///
    /// Absence of `results.paneVisible` means a fresh install that has never
    /// shown the pane, which must keep its one-shot reveal — hence the
    /// `object(forKey:)` read rather than `bool(forKey:)`.
    ///
    /// - Returns: true when it actually closed the pane, so the launch can
    ///   say so in the status log; false when there was nothing to repair.
    private static func repairAutoRevealedResultsPane() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "results.autoShown") == nil,
              let wasVisible = defaults.object(forKey: "results.paneVisible") as? Bool
        else { return false }
        defaults.set(true, forKey: "results.autoShown")
        let shellVisible = defaults.object(forKey: "shell.paneVisible") as? Bool
            ?? Defaults.shellPaneVisible
        guard wasVisible, shellVisible else { return false }
        defaults.set(false, forKey: "results.paneVisible")
        return true
    }

    /// Follow `editor.nodes` and keep `activeNetworkDimension` equal to its
    /// station count. Replaces any previous subscription.
    func trackActiveEditor(_ editor: NetworkEditorModel) {
        activeEditorSubscription = editor.$nodes
            .map { nodes in nodes.filter { $0.kind == .station }.count }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] d in
                guard let self, self.activeNetworkDimension != d else { return }
                self.activeNetworkDimension = d
            }
    }

    // MARK: - Defaults table
    //
    // Every default value lives here exactly once. The `@AppStorage`
    // declarations below reference these constants, the per-pane
    // "Reset to Defaults" buttons in SettingsView call the `reset*()`
    // helpers further down, and run-dialog fallbacks in QnetGUIApp can
    // read `AppSettings.Defaults.*` instead of repeating the literals.
    //
    // The `@AppStorage` key strings are part of the on-disk contract and
    // must never change; only the values here may.
    enum Defaults {
        // Discrete-event simulation (jackson_sim / fBNAsim)
        static let simReplications = 50
        static let simWarmup       = 1_000_000
        static let simTime         = 5_000_000
        static let simParallel     = 0     // 0 = GCD, 1 = OpenMP, 2 = Sequential
        static let simBlocking     = 2     // 0 = Loss, 1 = BAS, 2 = BAS + external loss
        static let simSeedFixed    = false
        static let simSeed         = 12_345

        // Finite element (fBNAfm)
        static let femSolver   = 0         // 0 = Gauss-Legendre, 1 = CBC QMC
        static let femMeshSize = 10

        // Spectral (BNAsm / fBNAsm)
        static let smDegree   = 8
        static let smLegendre = false

        // SRBM MLMC (rbm_mlmc). Values match the binary's own
        // defaults so a fresh install reproduces the paper's settings.
        static let exactSimEpsilon      = 0.01
        static let exactSimGamma        = 0.05
        static let exactSimOverrideT    = false
        static let exactSimT            = 10.0
        static let exactSimOverrideL    = false
        static let exactSimL            = 3
        static let exactSimOverrideN    = false
        static let exactSimN            = 25_000
        static let exactSimBackend      = 0
        static let exactSimThreads      = 0
        static let exactSimSeedFixed    = false
        static let exactSimSeed         = 12_345
        static let exactSimAntithetic   = false
        static let exactSimAdaptive     = false
        static let exactSimBatchSize    = 1_000
        static let exactSimMinSamples   = 5_000
        static let exactSimMaxSamples   = 200_000
        static let exactSimReplications = 1

        // Linear program, orthant (BNAlp / srbm_lp)
        static let lpGridN          = 0    // 0 = auto-scaled by dimension
        static let lpBasisM         = 0
        static let lpSolver         = 0    // 0 = auto, 1 = cplex, 2 = glpk, 3 = highs
        static let lpGridType       = 0    // 0 = exponential, 1 = dyadic, 2 = exprandom
        static let lpSmoothness     = 0.0
        static let lpBasisNormalize = false
        static let lpAskBeforeRun   = false
        static let lpMultiLevel     = false

        // Linear program, rectangle (fBNAlp)
        static let flpGridN          = 0
        static let flpBasisM         = 0
        static let flpSolver         = 0   // 0 = highs, 1 = glpk, 2 = cplex
        static let flpGridType       = 0   // 0 = uniform, 1 = chebyshev
        static let flpBasisNormalize = false
        static let flpAskBeforeRun   = false

        // Test sets
        static let testsetInfStationsLo = 3
        static let testsetInfStationsHi = 6
        static let testsetInfClassesLo  = 1
        static let testsetInfClassesHi  = 3
        static let testsetInfRhoLo      = 0.5
        static let testsetInfRhoHi      = 0.85
        static let testsetInfNumCases   = 20
        static let testsetInfTopology   = 0

        static let testsetFinStationsLo = 2
        static let testsetFinStationsHi = 4
        static let testsetFinClassesLo  = 1
        static let testsetFinClassesHi  = 2
        static let testsetFinRhoLo      = 0.5
        static let testsetFinRhoHi      = 0.85
        static let testsetFinNumCases   = 10
        static let testsetFinTopology   = 0

        static let testsetSpcStationsLo = 3
        static let testsetSpcStationsHi = 6
        static let testsetSpcClassesLo  = 1
        static let testsetSpcClassesHi  = 3
        static let testsetSpcRhoStart   = 0.50
        static let testsetSpcRhoEnd     = 0.95
        static let testsetSpcRhoStep    = 0.05
        static let testsetSpcNumCases   = 10
        static let testsetSpcTopology   = 0

        // General
        static let tabRestoreBehavior          = 0    // 0 = ask, 1 = always, 2 = never
        static let rememberRunComparisonChoice = false
        static let gcdgEnabled                 = false

        // Interface
        static let shellFontSize   = 12.0
        static let shellFontName   = ""
        static let shellClassicTheme = false
        static let palettePaneVisible = true
        static let statusPaneVisible  = true
        static let resultsPaneVisible = false
        static let shellPaneVisible   = true
        static let inspectorPaneVisible = true
        static let resultsAutoShown   = false
        static let soloedPane         = ""
        static let detachedPanes      = ""
        static let statusFontSize  = 12.0
        static let outputDecimals  = 6
        static let helpOutputDestination = HelpOutputDestination.popup.rawValue

        // AI assistant
        static let aiProvider     = LLMProvider.anthropic.rawValue
        static let aiSystemPrompt = "You are an assistant embedded in BNET, a tool for Brownian Network analysis of queueing systems. Answer concisely."
        static let aiMaxTokens    = 4096
        static let aiTemperature  = 0.7
        static let aiTimeoutSec   = 60.0
        /// Off for a fresh install. Six panes at once do not fit a
        /// 1500 × 900 window: their ideal heights sum to ~1016 pt against
        /// ~848 pt of content, so every row is squeezed below its ideal
        /// before the user has done anything. The assistant is the pane a
        /// new user is least likely to want first, it costs an API key to
        /// be useful, and View ▸ Panes ▸ AI Assistant (⌥⌘4) is one key
        /// away. An existing user who has ever toggled it keeps their
        /// stored value.
        static let aiPaneVisible  = false
        static let aiFontSize     = 12.0
        static let aiFontName     = ""
    }

    // MARK: - Validation ranges
    //
    // Shared by the Settings panes (validated fields) and available to
    // run dialogs so both clamp to the same bounds.
    enum Ranges {
        static let simReplications = 1...10_000
        static let simWarmup       = 0...1_000_000_000
        static let simTime         = 1...1_000_000_000
        static let simSeed         = 0...Int(Int32.max)
        static let femMeshSize     = 2...20
        static let smDegree        = 2...30
        static let exactSimEpsilon = 1e-4...1.0
        static let exactSimT       = 0.01...10_000.0
        static let exactSimL       = 1...20
        static let exactSimN       = 100...100_000_000
        static let exactSimSeed    = 0...Int(Int32.max)
        static let exactSimBatch   = 1...10_000_000
        // Adaptive uncertainty requires at least two independent samples.
        static let exactSimSamples = 2...100_000_000
        static let exactSimReplications = 1...1_000
        static let lpGrid          = 1...1_000
        static let lpBasis         = 1...64
        static let lpSmoothness    = 0.0...1.0
        static let testsetStations = 1...12
        static let testsetClasses  = 1...8
        static let testsetRho      = 0.01...0.99
        static let testsetRhoStep  = 0.01...0.5
        static let testsetNumCases = 1...1_000
        static let aiMaxTokens     = 1...200_000
        static let aiTimeoutSec    = 1.0...600.0
        static let aiTemperature   = 0.0...2.0
        /// Ceiling of 6, not 9: every native solver prints its numbers with
        /// C's `%f` default or an explicit `%.6f`, so a seventh fraction
        /// digit does not exist in the text this app parses. Asking for 9
        /// used to print six real digits and three zeros — precision the
        /// number never had. The Exact Result column, computed in Swift,
        /// could honour more; a table whose columns disagree about how many
        /// of their digits are real is worse than one that stops at 6.
        static let outputDecimals  = 0...6
        static let fontSize        = 8.0...28.0

        /// Upper bound for the thread count: 0 = auto, otherwise one
        /// thread per logical core.
        static var exactSimThreads: ClosedRange<Int> {
            0...max(1, ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    // MARK: - Enumerated choices
    //
    // Every pop-up menu in the Settings window offers exactly one of these
    // lists, and `validateImported` accepts exactly the same list — one
    // table for both, so a tag the pane could never show cannot be
    // imported (an out-of-menu value would leave the pop-up blank). Enum-
    // backed choices are derived from the enum's `allCases`; the integer
    // tags are the solver conventions documented beside the `@AppStorage`
    // declarations below.
    enum Choices {
        static let simParallel        = [0, 1, 2]        // GCD, OpenMP, Sequential
        static let simBlocking        = [0, 1, 2]        // Loss, BAS, BAS + external loss
        static let femSolver          = [0, 1]           // Gauss–Legendre, CBC QMC
        /// The MLMC paper requires 1/γ to be an integer; these are the
        /// values its analysis covers, so the pane offers them as a menu
        /// rather than free entry.
        static let exactSimGamma: [Double] = [0.01, 0.05, 0.1, 0.25, 0.5]
        static let exactSimBackend    = [0, 1, 2, 3]     // Auto, OpenMP, GCD, Serial
        static let lpSolver           = [0, 1, 2, 3]     // Auto, CPLEX, GLPK, HiGHS
        static let lpGridType         = [0, 1, 2]        // exponential, dyadic, exprandom
        static let flpSolver          = [0, 1, 2]        // HiGHS, GLPK, CPLEX
        static let flpGridType        = [0, 1]           // uniform, chebyshev
        static let tabRestoreBehavior = [0, 1, 2]        // Ask, Always, Never
        static let testsetTopology: [Int] = RandomNetworkGenerator.Topology.allCases.map(\.rawValue)
        static let helpOutputDestination: [Int] = HelpOutputDestination.allCases.map(\.rawValue)
        static let aiProvider: [String] = LLMProvider.allCases.map(\.rawValue)
    }

    /// Mesh-size cap applied by the finite-element run dialog for a
    /// network of `d` stations (the FEM cost grows as n²ᵈ). Mirrors the
    /// `meshCap` table in QnetGUIApp so Settings can quote it.
    static func femMeshCap(forDimension d: Int) -> Int {
        switch d {
        case ..<4: return 20
        case 4:    return 8
        case 5:    return 6
        default:   return 4
        }
    }

    // ── Simulation (Monte Carlo) ──
    @AppStorage("sim.replications")   var simReplications: Int = Defaults.simReplications
    @AppStorage("sim.warmup")         var simWarmup: Int = Defaults.simWarmup
    @AppStorage("sim.time")           var simTime: Int = Defaults.simTime
    @AppStorage("sim.parallel")       var simParallel: Int = Defaults.simParallel   // 0=GCD, 1=OpenMP, 2=Sequential
    @AppStorage("sim.blocking")       var simBlocking: Int = Defaults.simBlocking   // 0=Loss, 1=BAS, 2=BAS+ExtLoss
    @AppStorage("sim.seedFixed")      var simSeedFixed: Bool = Defaults.simSeedFixed
    @AppStorage("sim.seed")           var simSeed: Int = Defaults.simSeed

    // ── Finite Element ──
    @AppStorage("fem.solver")         var femSolver: Int = Defaults.femSolver       // 0=Gauss, 1=CBC
    @AppStorage("fem.meshSize")       var femMeshSize: Int = Defaults.femMeshSize

    // ── Spectral Method ──
    @AppStorage("sm.degree")          var smDegree: Int = Defaults.smDegree
    @AppStorage("sm.legendre")        var smLegendre: Bool = Defaults.smLegendre

    // ── SRBM MLMC (Blanchet-Chen-Glynn-Si 2021) ──
    //
    // Accuracy knobs:
    //   exactSimEpsilon   - target RMSE; cost scales as 1/epsilon^2
    //   exactSimGamma     - MLMC step factor; paper-optimal 0.05; 1/gamma
    //                       must be a positive integer
    //   override{T,L,N}   - set non-zero to override the auto-chosen
    //                       path-length / levels / samples
    //
    // Speed knobs:
    //   exactSimBackend   - 0=auto, 1=OpenMP, 2=Accelerate GCD, 3=Serial
    //   exactSimThreads   - 0 = auto-detect (all cores)
    //   exactSimSeed      - 0 = time-based (non-reproducible)
    @AppStorage("mlmc.epsilon")       var exactSimEpsilon: Double = Defaults.exactSimEpsilon
    @AppStorage("mlmc.gamma")         var exactSimGamma:   Double = Defaults.exactSimGamma
    @AppStorage("mlmc.overrideT")     var exactSimOverrideT: Bool = Defaults.exactSimOverrideT
    @AppStorage("mlmc.T")             var exactSimT:       Double = Defaults.exactSimT
    @AppStorage("mlmc.overrideL")     var exactSimOverrideL: Bool = Defaults.exactSimOverrideL
    @AppStorage("mlmc.L")             var exactSimL:       Int    = Defaults.exactSimL
    @AppStorage("mlmc.overrideN")     var exactSimOverrideN: Bool = Defaults.exactSimOverrideN
    @AppStorage("mlmc.N")             var exactSimN:       Int    = Defaults.exactSimN
    @AppStorage("mlmc.backend")       var exactSimBackend: Int    = Defaults.exactSimBackend
    @AppStorage("mlmc.threads")       var exactSimThreads: Int    = Defaults.exactSimThreads
    @AppStorage("mlmc.seedFixed")     var exactSimSeedFixed: Bool = Defaults.exactSimSeedFixed
    @AppStorage("mlmc.seed")          var exactSimSeed:    Int    = Defaults.exactSimSeed
    // Variance reduction + replication
    @AppStorage("mlmc.antithetic")    var exactSimAntithetic: Bool = Defaults.exactSimAntithetic
    @AppStorage("mlmc.adaptive")      var exactSimAdaptive:   Bool = Defaults.exactSimAdaptive
    @AppStorage("mlmc.batchSize")     var exactSimBatchSize:  Int  = Defaults.exactSimBatchSize
    @AppStorage("mlmc.minSamples")    var exactSimMinSamples: Int  = Defaults.exactSimMinSamples
    @AppStorage("mlmc.maxSamples")    var exactSimMaxSamples: Int  = Defaults.exactSimMaxSamples
    @AppStorage("mlmc.replications")  var exactSimReplications: Int = Defaults.exactSimReplications

    // ── Linear Program (Saure-Glynn-Zeevi 2008 / BNAlp) ──
    //
    // All grid / basis / solver knobs exposed by the srbm_lp binary, plus
    // flow-control toggles for the GUI (ask-before-run, multi-level
    // refinement).  Use 0 for "auto-scaled by dimension" (see
    // BNASRBMExporter.recommendedBNAlpGrid).
    @AppStorage("lp.gridN")            var lpGridN: Int    = Defaults.lpGridN
    @AppStorage("lp.basisM")           var lpBasisM: Int   = Defaults.lpBasisM
    /// 0 = auto (cplex if available, else glpk, else highs),
    /// 1 = cplex, 2 = glpk, 3 = highs
    @AppStorage("lp.solver")           var lpSolver: Int   = Defaults.lpSolver
    /// 0 = exponential, 1 = dyadic, 2 = exprandom
    @AppStorage("lp.gridType")         var lpGridType: Int = Defaults.lpGridType
    @AppStorage("lp.smoothness")       var lpSmoothness: Double = Defaults.lpSmoothness
    @AppStorage("lp.basisNormalize")   var lpBasisNormalize: Bool = Defaults.lpBasisNormalize
    /// If true, pop up a parameter-override dialog before each LP run.
    @AppStorage("lp.askBeforeRun")     var lpAskBeforeRun: Bool = Defaults.lpAskBeforeRun
    /// If true, run a fast coarse LP (half the target grid_n) first, then
    /// re-run at the target grid.  Gives the user an early preview and
    /// sanity check before committing to the full-resolution solve.
    @AppStorage("lp.multiLevel")       var lpMultiLevel: Bool = Defaults.lpMultiLevel

    // ── Finite-buffer Linear Program (fBNAlp) ──
    //
    // Mirrors the lp* knobs but for the rectangle-case solver. Use 0 for
    // "auto-scaled by dimension" (see SRBMExporter.recommendedFiniteLPGrid).
    @AppStorage("flp.gridN")          var flpGridN: Int = Defaults.flpGridN
    @AppStorage("flp.basisM")         var flpBasisM: Int = Defaults.flpBasisM
    /// 0 = highs (default, redistributable), 1 = glpk, 2 = cplex
    @AppStorage("flp.solver")         var flpSolver: Int = Defaults.flpSolver
    /// 0 = uniform, 1 = chebyshev
    @AppStorage("flp.gridType")       var flpGridType: Int = Defaults.flpGridType
    @AppStorage("flp.basisNormalize") var flpBasisNormalize: Bool = Defaults.flpBasisNormalize
    /// Reserved: the finite-LP run path does not consult this yet (the
    /// orthant LP path reads `lpAskBeforeRun`). Kept so the key survives;
    /// the Settings pane deliberately shows no control for it.
    @AppStorage("flp.askBeforeRun")   var flpAskBeforeRun: Bool = Defaults.flpAskBeforeRun

    // ── Test Sets ──
    //
    // Defaults for the "Run Infinite Test Set" / "Run Finite Test Set"
    // sweep dialogs. Stored per regime since finite cases are typically
    // run with smaller dimensions (the FE solver cost scales as n²ᵈ)
    // and fewer replicas. Topology is stored as the
    // RandomNetworkGenerator.Topology raw int (0 = feed-forward,
    // 1 = jackson-feedback, 2 = general P-matrix, 3 = re-entrant).
    @AppStorage("testset.inf.stationsLo") var testsetInfStationsLo: Int = Defaults.testsetInfStationsLo
    @AppStorage("testset.inf.stationsHi") var testsetInfStationsHi: Int = Defaults.testsetInfStationsHi
    @AppStorage("testset.inf.classesLo")  var testsetInfClassesLo:  Int = Defaults.testsetInfClassesLo
    @AppStorage("testset.inf.classesHi")  var testsetInfClassesHi:  Int = Defaults.testsetInfClassesHi
    @AppStorage("testset.inf.rhoLo")      var testsetInfRhoLo:      Double = Defaults.testsetInfRhoLo
    @AppStorage("testset.inf.rhoHi")      var testsetInfRhoHi:      Double = Defaults.testsetInfRhoHi
    @AppStorage("testset.inf.numCases")   var testsetInfNumCases:   Int = Defaults.testsetInfNumCases
    @AppStorage("testset.inf.topology")   var testsetInfTopology:   Int = Defaults.testsetInfTopology

    @AppStorage("testset.fin.stationsLo") var testsetFinStationsLo: Int = Defaults.testsetFinStationsLo
    @AppStorage("testset.fin.stationsHi") var testsetFinStationsHi: Int = Defaults.testsetFinStationsHi
    @AppStorage("testset.fin.classesLo")  var testsetFinClassesLo:  Int = Defaults.testsetFinClassesLo
    @AppStorage("testset.fin.classesHi")  var testsetFinClassesHi:  Int = Defaults.testsetFinClassesHi
    @AppStorage("testset.fin.rhoLo")      var testsetFinRhoLo:      Double = Defaults.testsetFinRhoLo
    @AppStorage("testset.fin.rhoHi")      var testsetFinRhoHi:      Double = Defaults.testsetFinRhoHi
    @AppStorage("testset.fin.numCases")   var testsetFinNumCases:   Int = Defaults.testsetFinNumCases
    @AppStorage("testset.fin.topology")   var testsetFinTopology:   Int = Defaults.testsetFinTopology

    // Spectral-convergence sweep defaults. ρ here is start / end / step
    // (not min / max) — for each case we generate one network and sweep
    // ρ across that single network at every value in the grid.
    @AppStorage("testset.spc.stationsLo") var testsetSpcStationsLo: Int = Defaults.testsetSpcStationsLo
    @AppStorage("testset.spc.stationsHi") var testsetSpcStationsHi: Int = Defaults.testsetSpcStationsHi
    @AppStorage("testset.spc.classesLo")  var testsetSpcClassesLo:  Int = Defaults.testsetSpcClassesLo
    @AppStorage("testset.spc.classesHi")  var testsetSpcClassesHi:  Int = Defaults.testsetSpcClassesHi
    @AppStorage("testset.spc.rhoStart")   var testsetSpcRhoStart:   Double = Defaults.testsetSpcRhoStart
    @AppStorage("testset.spc.rhoEnd")     var testsetSpcRhoEnd:     Double = Defaults.testsetSpcRhoEnd
    @AppStorage("testset.spc.rhoStep")    var testsetSpcRhoStep:    Double = Defaults.testsetSpcRhoStep
    @AppStorage("testset.spc.numCases")   var testsetSpcNumCases:   Int = Defaults.testsetSpcNumCases
    @AppStorage("testset.spc.topology")   var testsetSpcTopology:   Int = Defaults.testsetSpcTopology

    // ── Tab Restore ──
    // 0 = Ask, 1 = Always restore, 2 = Never restore
    @AppStorage("tabs.restoreBehavior") var tabRestoreBehavior: Int = Defaults.tabRestoreBehavior

    // ── Run Comparison prompt ──
    // When true, Run Comparison skips the blocking-regime dialog and uses
    // `simBlocking` (the "Default Choice") silently. When false (default),
    // the dialog pops every time. The dialog itself offers a "Remember
    // choice" checkbox that flips this to true.
    @AppStorage("runCompare.remember") var rememberRunComparisonChoice: Bool = Defaults.rememberRunComparisonChoice

    // ── Analytical Tractability (GCDG 2025) ──
    // Vestigial: the detector now always tries every branch (exact + GCDG
    // asymptotic) and the pill / Run Comparison column reflects whichever
    // matched. The popover labels exact vs asymptotic so the user can tell.
    // The AppStorage key is kept so previously-stored values don't leak
    // into anything; future use TBD (e.g., visual badge toggle). Settings
    // has no pane or control for it — a toggle with no effect would
    // mislead; the explanatory text lives in Help ▸ Analytical Tractability.
    @AppStorage("gcdg.enabled")       var gcdgEnabled: Bool = Defaults.gcdgEnabled

    // ── Shell pane ──
    // `shellFontName` is a font family name; empty string means "system
    // monospaced default".
    @AppStorage("shell.fontSize") var shellFontSize: Double = Defaults.shellFontSize
    @AppStorage("shell.fontName") var shellFontName: String = Defaults.shellFontName
    /// When true the Shell pane uses the classic green-on-black palette
    /// instead of the semantic text/background colours.
    @AppStorage("shell.classicTheme") var shellClassicTheme: Bool = Defaults.shellClassicTheme

    // ── Pane visibility (View ▸ Panes) ──
    // `ai.paneVisible` lives with the AI settings below; these three are
    // its siblings for the other collapsible panes.
    @AppStorage("palette.paneVisible") var palettePaneVisible: Bool = Defaults.palettePaneVisible
    @AppStorage("status.paneVisible")  var statusPaneVisible:  Bool = Defaults.statusPaneVisible
    /// Structured run history and station-level measurements. Kept off for
    /// new installs until the first result is captured; unlike Shell output,
    /// opening it never changes or reruns a calculation.
    @AppStorage("results.paneVisible") var resultsPaneVisible: Bool = Defaults.resultsPaneVisible
    @AppStorage("shell.paneVisible")   var shellPaneVisible:   Bool = Defaults.shellPaneVisible
    /// The docked parameter Inspector (right column, above Status).
    @AppStorage("inspector.paneVisible") var inspectorPaneVisible: Bool = Defaults.inspectorPaneVisible

    /// True once the first solver run has revealed the Results workspace
    /// by itself. The reveal is one-shot: a pane that forces itself open
    /// on every run is a pane the user cannot keep closed, and the
    /// letterboxing it caused (canvas ~330 pt, Shell ~11 rows) was
    /// permanent because `results.paneVisible` then stayed true forever.
    @AppStorage("results.autoShown") var resultsAutoShown: Bool = Defaults.resultsAutoShown

    // ── Pane prominence (View ▸ Panes ▸ Maximize Pane) ──
    //
    // Which pane, if any, currently has the whole content area. Stored as
    // a `FocusRouter.Pane` raw value, empty for "none", so `defaults read`
    // is legible and an unrecognised name fails closed to "nothing is
    // maximized" rather than to a pane that no longer exists.
    //
    // This is deliberately NOT a seventh visibility flag: maximizing hides
    // no pane and writes no divider position, so restoring is exact.
    @AppStorage("panes.soloed") private var soloedPaneRawValue: String = Defaults.soloedPane

    /// Whether the user's View ▸ Panes choice currently shows this pane.
    /// The canvas has no toggle — it is the document.
    func isPaneEnabled(_ pane: FocusRouter.Pane) -> Bool {
        switch pane {
        case .palette:   return palettePaneVisible
        case .canvas:    return true
        case .status:    return statusPaneVisible
        case .inspector: return inspectorPaneVisible
        case .results:   return resultsPaneVisible
        case .shell:     return shellPaneVisible
        case .ai:        return aiPaneVisible
        }
    }

    /// The write half of `isPaneEnabled`, for the callers that have a
    /// `FocusRouter.Pane` in hand rather than a specific toggle — the
    /// pane-window menu, which switches a pane on as it tears it out
    /// (a pane torn into a window nobody can see is not a feature).
    /// The canvas is not switchable and is silently ignored.
    func setPaneEnabled(_ pane: FocusRouter.Pane, _ enabled: Bool) {
        switch pane {
        case .palette:   palettePaneVisible = enabled
        case .canvas:    break
        case .status:    statusPaneVisible = enabled
        case .inspector: inspectorPaneVisible = enabled
        case .results:   resultsPaneVisible = enabled
        case .shell:     shellPaneVisible = enabled
        case .ai:        aiPaneVisible = enabled
        }
    }

    /// The maximized pane, or nil.
    ///
    /// The getter is the ONE sanitizer, so the split tree, the pane
    /// headers' buttons and the View ▸ Panes item cannot disagree about
    /// whether something is maximized. It fails closed on a pane that
    /// cannot usefully dominate (the width-capped Tools palette), on a
    /// name this build no longer knows, on a pane the user has since
    /// switched off, and on a pane that is currently in a window of its
    /// own — a maximize stored before a relaunch must not resurrect a
    /// hidden pane or claim a main window the pane has left, and a check
    /// mark that disagrees with the screen is worse than losing the
    /// maximize.
    ///
    /// The setter announces the change explicitly: `@AppStorage` inside an
    /// `ObservableObject` does not publish on a direct property write, and
    /// every derived pane list in `ContentView` reads this.
    var soloedPane: FocusRouter.Pane? {
        get {
            guard let pane = FocusRouter.Pane(rawValue: soloedPaneRawValue),
                  pane.canBeMaximized, isPaneEnabled(pane),
                  !isDetached(pane) else { return nil }
            return pane
        }
        set {
            let raw = newValue?.rawValue ?? ""
            guard raw != soloedPaneRawValue else { return }
            objectWillChange.send()
            soloedPaneRawValue = raw
        }
    }

    /// True while a pane is *stored* as maximized, eligible or not. The
    /// getter above hides an ineligible one from the layout; this is how
    /// the stale string itself gets cleared once the user rearranges.
    var hasStoredSolo: Bool { !soloedPaneRawValue.isEmpty }

    /// Maximize `pane`, or restore the saved arrangement when it already
    /// has the window. Maximizing a second pane replaces the first rather
    /// than stacking, so there is never more than one thing to undo.
    ///
    /// Refuses a pane the getter would reject anyway, so a caller cannot
    /// store a maximize that never appears on screen.
    func toggleSolo(_ pane: FocusRouter.Pane) {
        guard pane.canBeMaximized, isPaneEnabled(pane), !isDetached(pane) else { return }
        soloedPane = (soloedPane == pane) ? nil : pane
    }

    // ── Pane windows (View ▸ Panes ▸ Separate Windows) ──
    //
    // Which panes are currently torn out of the main window into windows
    // of their own. Stored as a comma-joined list of `FocusRouter.Pane`
    // raw values in ONE key rather than one Bool per pane, so `defaults
    // read` shows the whole arrangement on one line and a pane added or
    // renamed later cannot leave a stale key behind: an unrecognised name
    // is simply dropped by the getter.
    //
    // Deliberately not in `allowedStringsByKey`: that table enumerates the
    // legal values of a single-choice key, and this is a *set*. Import
    // therefore accepts it as free text — and the getter below is what
    // makes that safe, exactly as it is for `panes.soloed`.
    @AppStorage("panes.detached") private var detachedPanesRawValue: String = Defaults.detachedPanes

    /// The panes that are in windows of their own.
    ///
    /// The getter drops anything this build does not know and anything that
    /// cannot be detached at all, so a bad stored value fails closed to
    /// "docked". It does NOT drop a pane the user has since hidden: being
    /// detached is a *placement* preference, like a window's frame, and it
    /// has to survive ⌥⌘3 off and on again or hiding the Shell for a minute
    /// would silently dock it. `ContentView.shows(_:)` and the window
    /// reconciler both require the pane to be enabled as well, so a hidden
    /// detached pane is on screen nowhere until it is shown again.
    ///
    /// The setter writes the canonical spelling — `Pane.allCases` order,
    /// no duplicates, no unknown names — so an imported or hand-edited
    /// value is tidied the first time anything changes, and announces the
    /// change itself: `@AppStorage` inside an `ObservableObject` does not
    /// publish on a direct property write.
    ///
    /// The parse is memoized against the raw string it came from.
    /// `ContentView.shows(_:)` asks `isDetached` before anything else, and
    /// `shows` is asked fifteen times per body evaluation — on every editor
    /// publish, i.e. every frame of a node drag. Keying the memo on the
    /// stored string rather than invalidating it in the setter is what
    /// keeps it correct when the value changes from outside this object
    /// (a settings import, a reset, `defaults write`): a raw value that
    /// differs from the one the memo was built from re-parses.
    var detachedPanes: Set<FocusRouter.Pane> {
        get {
            let raw = detachedPanesRawValue
            if let cache = detachedPanesCache, cache.raw == raw { return cache.panes }
            let panes = Set(raw
                .split(separator: ",")
                .compactMap { FocusRouter.Pane(rawValue: String($0)) }
                .filter(\.canBeDetached))
            detachedPanesCache = (raw, panes)
            return panes
        }
        set {
            let sanitized = newValue.filter(\.canBeDetached)
            let raw = FocusRouter.Pane.allCases
                .filter(sanitized.contains)
                .map(\.rawValue)
                .joined(separator: ",")
            guard raw != detachedPanesRawValue else { return }
            objectWillChange.send()
            detachedPanesRawValue = raw
            detachedPanesCache = (raw, Set(sanitized))
        }
    }

    /// Memo for the getter above: the raw string it was parsed from, and
    /// the result. Not `@AppStorage`, not published — it is derived state,
    /// and every write that matters goes through `detachedPanesRawValue`.
    private var detachedPanesCache: (raw: String, panes: Set<FocusRouter.Pane>)?

    func isDetached(_ pane: FocusRouter.Pane) -> Bool {
        detachedPanes.contains(pane)
    }

    /// True while any pane is in a window of its own — what "Return All
    /// Panes to the Main Window" enables on.
    var hasDetachedPane: Bool { !detachedPanes.isEmpty }

    /// Move `pane` out to its own window, or bring it back.
    ///
    /// Detaching the maximized pane also ends the maximize: the pane it
    /// applied to is no longer in the main window, and leaving the flag set
    /// would blank every other pane there for a maximize the user cannot
    /// see. (The `soloedPane` getter already refuses such a pane, so this
    /// is about clearing the stored string, not about the layout.)
    func setDetached(_ pane: FocusRouter.Pane, _ detached: Bool) {
        guard pane.canBeDetached else { return }
        if detached, soloedPaneRawValue == pane.rawValue { soloedPane = nil }
        var next = detachedPanes
        if detached { next.insert(pane) } else { next.remove(pane) }
        detachedPanes = next
    }

    /// Bring every detached pane back into the main window. The one
    /// command that undoes any arrangement of pane windows, however it was
    /// reached — and what a workspace preset does before it lays the panes
    /// out, since a preset the user cannot see land is not a preset.
    func reattachAllPanes() {
        detachedPanes = []
    }

    // ── Status pane ──
    @AppStorage("status.fontSize") var statusFontSize: Double = Defaults.statusFontSize

    static let statusMinFontSize: Double = Ranges.fontSize.lowerBound
    static let statusMaxFontSize: Double = Ranges.fontSize.upperBound

    func increaseStatusFontSize() {
        statusFontSize = min(statusFontSize + 1, Self.statusMaxFontSize)
    }

    func decreaseStatusFontSize() {
        statusFontSize = max(statusFontSize - 1, Self.statusMinFontSize)
    }

    // ── Output Format ──
    //
    // Controls the formatting of numeric values printed in the Run Comparison
    // and single-method tables (rho, Gamma, sojourn, E[X], etc.). Default is
    // 6 to roughly match the legacy 7-digit-total formatter. Range 0..9.
    @AppStorage("output.decimals") var outputDecimals: Int = Defaults.outputDecimals

    // ── Help menu ──
    //
    // Destination for the Help → * menu items. Each value corresponds to
    // a `HelpOutputDestination` case. The SRBM MLMC help is
    // excluded — it always opens its own rich SwiftUI window.
    @AppStorage("help.outputDestination") var helpOutputDestination: Int = Defaults.helpOutputDestination

    // ── AI Assistant ──
    //
    // Provider is stored as the `LLMProvider.rawValue` string. Per-provider
    // base URL and model name are stored separately so switching providers
    // preserves each one's settings. API keys live in the Keychain
    // (LLMKeychain) rather than UserDefaults.
    @AppStorage("ai.provider")       var aiProvider: String = Defaults.aiProvider
    @AppStorage("ai.baseURL.anthropic") var aiBaseURLAnthropic: String = LLMProvider.anthropic.defaultBaseURL
    @AppStorage("ai.baseURL.openai")    var aiBaseURLOpenAI:    String = LLMProvider.openai.defaultBaseURL
    @AppStorage("ai.baseURL.ollama")    var aiBaseURLOllama:    String = LLMProvider.ollama.defaultBaseURL
    @AppStorage("ai.baseURL.lmstudio")  var aiBaseURLLMStudio:  String = LLMProvider.lmstudio.defaultBaseURL
    @AppStorage("ai.model.anthropic")   var aiModelAnthropic:   String = LLMProvider.anthropic.defaultModel
    @AppStorage("ai.model.openai")      var aiModelOpenAI:      String = LLMProvider.openai.defaultModel
    @AppStorage("ai.model.ollama")      var aiModelOllama:      String = LLMProvider.ollama.defaultModel
    @AppStorage("ai.model.lmstudio")    var aiModelLMStudio:    String = LLMProvider.lmstudio.defaultModel
    /// Comma-separated cache of model ids most recently discovered from
    /// each provider's listing endpoint. Persisted so the Settings
    /// dropdown is pre-populated on launch even before the user clicks
    /// "Refresh". Empty string = never refreshed.
    @AppStorage("ai.discovered.anthropic") var aiDiscoveredAnthropic: String = ""
    @AppStorage("ai.discovered.openai")    var aiDiscoveredOpenAI:    String = ""
    @AppStorage("ai.discovered.ollama")    var aiDiscoveredOllama:    String = ""
    @AppStorage("ai.discovered.lmstudio")  var aiDiscoveredLMStudio:  String = ""
    @AppStorage("ai.systemPrompt")   var aiSystemPrompt: String = Defaults.aiSystemPrompt
    @AppStorage("ai.maxTokens")      var aiMaxTokens:    Int    = Defaults.aiMaxTokens
    @AppStorage("ai.temperature")    var aiTemperature:  Double = Defaults.aiTemperature
    @AppStorage("ai.timeoutSec")     var aiTimeoutSec:   Double = Defaults.aiTimeoutSec
    /// When false, the AI Assistant pane is hidden and the Interactive
    /// Shell pane expands to the full width of the bottom row.
    @AppStorage("ai.paneVisible")    var aiPaneVisible:  Bool   = Defaults.aiPaneVisible
    /// Transcript font for the AI Assistant pane. Empty family string
    /// means "system monospaced default" (matches the Interactive Shell
    /// convention).
    @AppStorage("ai.fontSize")       var aiFontSize:     Double = Defaults.aiFontSize
    @AppStorage("ai.fontName")       var aiFontName:     String = Defaults.aiFontName

    static let aiMinFontSize: Double = Ranges.fontSize.lowerBound
    static let aiMaxFontSize: Double = Ranges.fontSize.upperBound

    /// Last-known AI pane width, derived from the bottom HSplit's persisted
    /// subview sizes. Used as `idealWidth` so that when the AI pane is
    /// toggled off and back on, the new HSplit opens at the same width the
    /// user had before it was hidden. Falls back to 255 when nothing is
    /// saved yet. Not an @AppStorage — recomputed from the per-pane key
    /// `SplitPane.BottomHSplit.ai`, which `SplitViewConfigurator` writes on
    /// every drag whatever the pane set; the legacy `SplitSizes.BottomHSplit`
    /// array (only written while both bottom panes are visible) is the
    /// fallback for defaults saved by older builds.
    var aiPaneWidth: Double {
        if let w = UserDefaults.standard.object(forKey: "SplitPane.BottomHSplit.ai") as? Double, w > 10 {
            return w
        }
        guard let sizes = UserDefaults.standard.array(forKey: "SplitSizes.BottomHSplit") as? [Double],
              sizes.count >= 2,
              let w = sizes.last,
              w > 10
        else { return 255 }
        return w
    }

    /// Resolve the current provider enum (fallback to `.anthropic`).
    var aiProviderResolved: LLMProvider {
        LLMProvider(rawValue: aiProvider) ?? .anthropic
    }

    /// Per-provider base URL accessor.
    func aiBaseURL(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return aiBaseURLAnthropic
        case .openai:    return aiBaseURLOpenAI
        case .ollama:    return aiBaseURLOllama
        case .lmstudio:  return aiBaseURLLMStudio
        }
    }

    func setAIBaseURL(_ value: String, for provider: LLMProvider) {
        switch provider {
        case .anthropic: aiBaseURLAnthropic = value
        case .openai:    aiBaseURLOpenAI    = value
        case .ollama:    aiBaseURLOllama    = value
        case .lmstudio:  aiBaseURLLMStudio  = value
        }
    }

    /// Per-provider model-name accessor.
    func aiModel(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return aiModelAnthropic
        case .openai:    return aiModelOpenAI
        case .ollama:    return aiModelOllama
        case .lmstudio:  return aiModelLMStudio
        }
    }

    func setAIModel(_ value: String, for provider: LLMProvider) {
        switch provider {
        case .anthropic: aiModelAnthropic = value
        case .openai:    aiModelOpenAI    = value
        case .ollama:    aiModelOllama    = value
        case .lmstudio:  aiModelLMStudio  = value
        }
    }

    /// Cached list of discovered model ids for a provider. Empty when
    /// the user has never clicked "Refresh" for that provider.
    func aiDiscoveredModels(for provider: LLMProvider) -> [String] {
        let raw: String
        switch provider {
        case .anthropic: raw = aiDiscoveredAnthropic
        case .openai:    raw = aiDiscoveredOpenAI
        case .ollama:    raw = aiDiscoveredOllama
        case .lmstudio:  raw = aiDiscoveredLMStudio
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func setAIDiscoveredModels(_ models: [String], for provider: LLMProvider) {
        let joined = models.joined(separator: ",")
        switch provider {
        case .anthropic: aiDiscoveredAnthropic = joined
        case .openai:    aiDiscoveredOpenAI    = joined
        case .ollama:    aiDiscoveredOllama    = joined
        case .lmstudio:  aiDiscoveredLMStudio  = joined
        }
    }

    /// Build a full LLMConfig for the currently-selected provider.
    func currentAIConfig() -> LLMConfig {
        let p = aiProviderResolved
        return LLMConfig(
            provider:       p,
            baseURL:        aiBaseURL(for: p),
            model:          aiModel(for: p),
            apiKey:         LLMKeychain.load(for: p),
            systemPrompt:   aiSystemPrompt,
            maxTokens:      aiMaxTokens,
            temperature:    aiTemperature,
            timeoutSeconds: aiTimeoutSec
        )
    }

    // MARK: - Stored-value introspection (Reset to Defaults)
    //
    // The Settings window disables "Reset to Defaults" when every key on
    // the pane already holds its default, and flashes only the rows a
    // reset actually changed. Both need a key → default table and a way to
    // compare what UserDefaults holds with that default without knowing
    // the Swift type. Every `@AppStorage` key above appears here exactly
    // once; keep the two lists in step when adding a setting.
    static let defaultsByKey: [String: Any] = {
        var t: [String: Any] = [
            "sim.replications": Defaults.simReplications,
            "sim.warmup": Defaults.simWarmup,
            "sim.time": Defaults.simTime,
            "sim.parallel": Defaults.simParallel,
            "sim.blocking": Defaults.simBlocking,
            "sim.seedFixed": Defaults.simSeedFixed,
            "sim.seed": Defaults.simSeed,
            "fem.solver": Defaults.femSolver,
            "fem.meshSize": Defaults.femMeshSize,
            "sm.degree": Defaults.smDegree,
            "sm.legendre": Defaults.smLegendre,
            "mlmc.epsilon": Defaults.exactSimEpsilon,
            "mlmc.gamma": Defaults.exactSimGamma,
            "mlmc.overrideT": Defaults.exactSimOverrideT,
            "mlmc.T": Defaults.exactSimT,
            "mlmc.overrideL": Defaults.exactSimOverrideL,
            "mlmc.L": Defaults.exactSimL,
            "mlmc.overrideN": Defaults.exactSimOverrideN,
            "mlmc.N": Defaults.exactSimN,
            "mlmc.backend": Defaults.exactSimBackend,
            "mlmc.threads": Defaults.exactSimThreads,
            "mlmc.seedFixed": Defaults.exactSimSeedFixed,
            "mlmc.seed": Defaults.exactSimSeed,
            "mlmc.antithetic": Defaults.exactSimAntithetic,
            "mlmc.adaptive": Defaults.exactSimAdaptive,
            "mlmc.batchSize": Defaults.exactSimBatchSize,
            "mlmc.minSamples": Defaults.exactSimMinSamples,
            "mlmc.maxSamples": Defaults.exactSimMaxSamples,
            "mlmc.replications": Defaults.exactSimReplications,
            "lp.gridN": Defaults.lpGridN,
            "lp.basisM": Defaults.lpBasisM,
            "lp.solver": Defaults.lpSolver,
            "lp.gridType": Defaults.lpGridType,
            "lp.smoothness": Defaults.lpSmoothness,
            "lp.basisNormalize": Defaults.lpBasisNormalize,
            "lp.askBeforeRun": Defaults.lpAskBeforeRun,
            "lp.multiLevel": Defaults.lpMultiLevel,
            "flp.gridN": Defaults.flpGridN,
            "flp.basisM": Defaults.flpBasisM,
            "flp.solver": Defaults.flpSolver,
            "flp.gridType": Defaults.flpGridType,
            "flp.basisNormalize": Defaults.flpBasisNormalize,
            "flp.askBeforeRun": Defaults.flpAskBeforeRun,
            "testset.inf.stationsLo": Defaults.testsetInfStationsLo,
            "testset.inf.stationsHi": Defaults.testsetInfStationsHi,
            "testset.inf.classesLo": Defaults.testsetInfClassesLo,
            "testset.inf.classesHi": Defaults.testsetInfClassesHi,
            "testset.inf.rhoLo": Defaults.testsetInfRhoLo,
            "testset.inf.rhoHi": Defaults.testsetInfRhoHi,
            "testset.inf.numCases": Defaults.testsetInfNumCases,
            "testset.inf.topology": Defaults.testsetInfTopology,
            "testset.fin.stationsLo": Defaults.testsetFinStationsLo,
            "testset.fin.stationsHi": Defaults.testsetFinStationsHi,
            "testset.fin.classesLo": Defaults.testsetFinClassesLo,
            "testset.fin.classesHi": Defaults.testsetFinClassesHi,
            "testset.fin.rhoLo": Defaults.testsetFinRhoLo,
            "testset.fin.rhoHi": Defaults.testsetFinRhoHi,
            "testset.fin.numCases": Defaults.testsetFinNumCases,
            "testset.fin.topology": Defaults.testsetFinTopology,
            "testset.spc.stationsLo": Defaults.testsetSpcStationsLo,
            "testset.spc.stationsHi": Defaults.testsetSpcStationsHi,
            "testset.spc.classesLo": Defaults.testsetSpcClassesLo,
            "testset.spc.classesHi": Defaults.testsetSpcClassesHi,
            "testset.spc.rhoStart": Defaults.testsetSpcRhoStart,
            "testset.spc.rhoEnd": Defaults.testsetSpcRhoEnd,
            "testset.spc.rhoStep": Defaults.testsetSpcRhoStep,
            "testset.spc.numCases": Defaults.testsetSpcNumCases,
            "testset.spc.topology": Defaults.testsetSpcTopology,
            "tabs.restoreBehavior": Defaults.tabRestoreBehavior,
            "runCompare.remember": Defaults.rememberRunComparisonChoice,
            "gcdg.enabled": Defaults.gcdgEnabled,
            "shell.fontSize": Defaults.shellFontSize,
            "shell.fontName": Defaults.shellFontName,
            "shell.classicTheme": Defaults.shellClassicTheme,
            "palette.paneVisible": Defaults.palettePaneVisible,
            "status.paneVisible": Defaults.statusPaneVisible,
            "results.paneVisible": Defaults.resultsPaneVisible,
            "shell.paneVisible": Defaults.shellPaneVisible,
            "inspector.paneVisible": Defaults.inspectorPaneVisible,
            "results.autoShown": Defaults.resultsAutoShown,
            "panes.soloed": Defaults.soloedPane,
            "panes.detached": Defaults.detachedPanes,
            "status.fontSize": Defaults.statusFontSize,
            "output.decimals": Defaults.outputDecimals,
            "help.outputDestination": Defaults.helpOutputDestination,
            "ai.provider": Defaults.aiProvider,
            "ai.systemPrompt": Defaults.aiSystemPrompt,
            "ai.maxTokens": Defaults.aiMaxTokens,
            "ai.temperature": Defaults.aiTemperature,
            "ai.timeoutSec": Defaults.aiTimeoutSec,
            "ai.paneVisible": Defaults.aiPaneVisible,
            "ai.fontSize": Defaults.aiFontSize,
            "ai.fontName": Defaults.aiFontName,
        ]
        for p in LLMProvider.allCases {
            t["ai.baseURL.\(p.rawValue)"] = p.defaultBaseURL
            t["ai.model.\(p.rawValue)"] = p.defaultModel
            t["ai.discovered.\(p.rawValue)"] = ""
        }
        return t
    }()

    /// Type-agnostic fingerprint of a stored value (`UserDefaults` hands
    /// back `NSNumber` for Int / Double / Bool and `String` for strings).
    /// Two values compare equal iff their signatures are equal.
    static func storageSignature(_ value: Any?) -> String {
        guard let value else { return "∅" }
        if let s = value as? String { return "s:" + s }
        if let n = value as? NSNumber { return "n:\(n.doubleValue)" }
        return "x:\(String(describing: value))"
    }

    /// Fingerprint of what UserDefaults currently holds for `key`, with a
    /// missing entry resolved to the key's default.
    static func storedSignature(forKey key: String) -> String {
        if let stored = UserDefaults.standard.object(forKey: key) {
            return storageSignature(stored)
        }
        return storageSignature(defaultsByKey[key])
    }

    /// True when `key` holds its default (or is unknown to the table).
    static func isStoredAtDefault(_ key: String) -> Bool {
        guard let def = defaultsByKey[key] else { return true }
        return storedSignature(forKey: key) == storageSignature(def)
    }

    // MARK: - Whole-configuration operations (Settings ▸ General ▸ All Settings)
    //
    // Twelve panes each own a Reset, which answers "put this pane back" but
    // not "what have I changed?" or "put everything back", and a research
    // tool needs to say "these are the solver settings the paper's numbers
    // were produced with". Export writes every stored key and its current
    // value as one JSON object; Import validates each value against the
    // key's type and `Ranges` before writing it and reports what it
    // refused, rather than writing a hand-edited file blind.

    /// Numeric bounds by stored key, for `importSettings` — every entry is
    /// the `Ranges` constant the Settings field clamps into (a stored 0 on
    /// the LP grid / basis keys means "auto", so those admit 0 below the
    /// field's own minimum). Pop-up tags and γ are enumerations, not
    /// ranges: they live in `allowedNumbersByKey`. `SettingsRegistry.audit()`
    /// checks in debug builds that every numeric key is in exactly one of
    /// the two tables and that its default satisfies it.
    static let rangesByKey: [String: ClosedRange<Double>] = {
        func r(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
            Double(range.lowerBound)...Double(range.upperBound)
        }
        return [
            "sim.replications": r(Ranges.simReplications),
            "sim.warmup": r(Ranges.simWarmup),
            "sim.time": r(Ranges.simTime),
            "sim.seed": r(Ranges.simSeed),
            "fem.meshSize": r(Ranges.femMeshSize),
            "sm.degree": r(Ranges.smDegree),
            "mlmc.epsilon": Ranges.exactSimEpsilon,
            "mlmc.T": Ranges.exactSimT,
            "mlmc.L": r(Ranges.exactSimL),
            "mlmc.N": r(Ranges.exactSimN),
            "mlmc.threads": r(Ranges.exactSimThreads),
            "mlmc.seed": r(Ranges.exactSimSeed),
            "mlmc.batchSize": r(Ranges.exactSimBatch),
            "mlmc.minSamples": r(Ranges.exactSimSamples),
            "mlmc.maxSamples": r(Ranges.exactSimSamples),
            "mlmc.replications": r(Ranges.exactSimReplications),
            "lp.gridN": 0...Double(Ranges.lpGrid.upperBound),
            "lp.basisM": 0...Double(Ranges.lpBasis.upperBound),
            "lp.smoothness": Ranges.lpSmoothness,
            "flp.gridN": 0...Double(Ranges.lpGrid.upperBound),
            "flp.basisM": 0...Double(Ranges.lpBasis.upperBound),
            "testset.inf.stationsLo": r(Ranges.testsetStations),
            "testset.inf.stationsHi": r(Ranges.testsetStations),
            "testset.inf.classesLo": r(Ranges.testsetClasses),
            "testset.inf.classesHi": r(Ranges.testsetClasses),
            "testset.inf.rhoLo": Ranges.testsetRho,
            "testset.inf.rhoHi": Ranges.testsetRho,
            "testset.inf.numCases": r(Ranges.testsetNumCases),
            "testset.fin.stationsLo": r(Ranges.testsetStations),
            "testset.fin.stationsHi": r(Ranges.testsetStations),
            "testset.fin.classesLo": r(Ranges.testsetClasses),
            "testset.fin.classesHi": r(Ranges.testsetClasses),
            "testset.fin.rhoLo": Ranges.testsetRho,
            "testset.fin.rhoHi": Ranges.testsetRho,
            "testset.fin.numCases": r(Ranges.testsetNumCases),
            "testset.spc.stationsLo": r(Ranges.testsetStations),
            "testset.spc.stationsHi": r(Ranges.testsetStations),
            "testset.spc.classesLo": r(Ranges.testsetClasses),
            "testset.spc.classesHi": r(Ranges.testsetClasses),
            "testset.spc.rhoStart": Ranges.testsetRho,
            "testset.spc.rhoEnd": Ranges.testsetRho,
            "testset.spc.rhoStep": Ranges.testsetRhoStep,
            "testset.spc.numCases": r(Ranges.testsetNumCases),
            "shell.fontSize": Ranges.fontSize,
            "status.fontSize": Ranges.fontSize,
            "output.decimals": r(Ranges.outputDecimals),
            "ai.maxTokens": r(Ranges.aiMaxTokens),
            "ai.temperature": Ranges.aiTemperature,
            "ai.timeoutSec": Ranges.aiTimeoutSec,
            "ai.fontSize": Ranges.fontSize,
        ]
    }()

    /// Enumerated numeric keys (pop-up tags and γ): an imported value must
    /// be one of these, which are exactly the options the pane's menu
    /// offers (`Choices`).
    static let allowedNumbersByKey: [String: [Double]] = {
        func d(_ list: [Int]) -> [Double] { list.map(Double.init) }
        return [
            "sim.parallel": d(Choices.simParallel),
            "sim.blocking": d(Choices.simBlocking),
            "fem.solver": d(Choices.femSolver),
            "mlmc.gamma": Choices.exactSimGamma,
            "mlmc.backend": d(Choices.exactSimBackend),
            "lp.solver": d(Choices.lpSolver),
            "lp.gridType": d(Choices.lpGridType),
            "flp.solver": d(Choices.flpSolver),
            "flp.gridType": d(Choices.flpGridType),
            "testset.inf.topology": d(Choices.testsetTopology),
            "testset.fin.topology": d(Choices.testsetTopology),
            "testset.spc.topology": d(Choices.testsetTopology),
            "tabs.restoreBehavior": d(Choices.tabRestoreBehavior),
            "help.outputDestination": d(Choices.helpOutputDestination),
        ]
    }()

    /// Enumerated string keys. Every other string key (font families, the
    /// system prompt, endpoints, model ids) is free text.
    static let allowedStringsByKey: [String: [String]] = [
        "ai.provider": Choices.aiProvider,
        // "" is "no pane is maximized"; the rest are FocusRouter.Pane raw
        // values, generated from the enum so a renamed case cannot leave a
        // stale string behind that Import would happily write.
        "panes.soloed": [""] + FocusRouter.Pane.allCases.map(\.rawValue),
    ]

    /// Why an imported value was refused.
    enum ImportRejection: Equatable {
        case unknownKey
        case wrongType(expected: String)
        case outOfRange(ClosedRange<Double>)
        /// The key is an enumeration (a pop-up tag, γ, the AI provider)
        /// and the value is none of the options the pane offers.
        case notOneOf([String])

        var description: String {
            switch self {
            case .unknownKey:                  return "not a Qnet setting"
            case .wrongType(let expected):     return "expected \(expected)"
            case .outOfRange(let range):       return "outside \(DS.Number.format(range.lowerBound, significantDigits: 4))…\(DS.Number.format(range.upperBound, significantDigits: 4))"
            case .notOneOf(let allowed):       return "not one of \(allowed.joined(separator: ", "))"
            }
        }
    }

    struct ImportReport: Equatable {
        var applied: [String] = []
        var unchanged: [String] = []
        var rejected: [(key: String, reason: ImportRejection)] = []

        static func == (a: ImportReport, b: ImportReport) -> Bool {
            a.applied == b.applied && a.unchanged == b.unchanged
                && a.rejected.map(\.key) == b.rejected.map(\.key)
                && a.rejected.map(\.reason) == b.rejected.map(\.reason)
        }
    }

    /// Format version written into every export. Bump it when a key's
    /// meaning changes; `importSettings(json:)` refuses a file whose tag
    /// is newer than this build understands.
    static let exportFormatVersion = 1
    static let exportFormatKey = "qnet.settingsFormat"
    static let exportDateKey = "qnet.exportedAt"
    /// The build that wrote the file (`AppVersion.fullVersion`), so an
    /// export attached to a paper says which Qnet produced the numbers.
    static let exportVersionKey = "qnet.appVersion"
    /// Keys in an export that are metadata, not settings.
    static let exportMetadataKeys: Set<String> = [exportFormatKey, exportDateKey, exportVersionKey]

    /// Every stored key and its current value (the default when nothing
    /// is stored), plus the format, date and app-version tags. API keys
    /// live in the Keychain and are never exported.
    static func exportedSettings() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in defaultsByKey.keys.sorted() {
            out[key] = UserDefaults.standard.object(forKey: key) ?? defaultsByKey[key]
        }
        out[exportFormatKey] = exportFormatVersion
        out[exportDateKey] = ISO8601DateFormatter().string(from: Date())
        out[exportVersionKey] = AppVersion.fullVersion
        return out
    }

    /// Pretty-printed JSON of `exportedSettings()`.
    static func exportedSettingsJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: exportedSettings(),
                                   options: [.prettyPrinted, .sortedKeys])
    }

    /// Check one candidate value against the key's stored type and range.
    /// Returns nil when acceptable, else the reason.
    static func validateImported(key: String, value: Any) -> ImportRejection? {
        guard let def = defaultsByKey[key] else { return .unknownKey }
        // Bool must be checked before Int / Double: JSON true / false
        // arrive as NSNumber and bridge to both.
        if def is Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                return .wrongType(expected: "true or false")
            }
            return nil
        }
        if def is String {
            guard let text = value as? String else { return .wrongType(expected: "text") }
            if let allowed = allowedStringsByKey[key], !allowed.contains(text) { return .notOneOf(allowed) }
            return nil
        }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            return .wrongType(expected: def is Int ? "a whole number" : "a number")
        }
        let d = n.doubleValue
        guard d.isFinite else { return .wrongType(expected: "a finite number") }
        if def is Int, d.rounded() != d { return .wrongType(expected: "a whole number") }
        if let allowed = allowedNumbersByKey[key] {
            guard allowed.contains(where: { abs($0 - d) <= 1e-9 }) else {
                return .notOneOf(allowed.map { DS.Number.format($0, significantDigits: 4) })
            }
            return nil
        }
        if let range = rangesByKey[key], !range.contains(d) { return .outOfRange(range) }
        return nil
    }

    /// Apply a dictionary of stored keys → values (the shape `exportedSettings`
    /// writes). Every value is validated first; rejected keys are reported
    /// and left untouched, so a bad line in a hand-edited file cannot put
    /// a solver into a state its Settings pane could never produce.
    @discardableResult
    func importSettings(_ dict: [String: Any]) -> ImportReport {
        var report = ImportReport()
        for key in dict.keys.sorted() {
            if Self.exportMetadataKeys.contains(key) { continue }
            guard let value = dict[key] else { continue }
            if let reason = Self.validateImported(key: key, value: value) {
                report.rejected.append((key, reason))
                continue
            }
            let before = Self.storedSignature(forKey: key)
            let stored: Any
            if Self.defaultsByKey[key] is Int, let n = value as? NSNumber {
                stored = n.intValue
            } else {
                stored = value
            }
            if Self.storageSignature(stored) == before {
                report.unchanged.append(key)
                continue
            }
            UserDefaults.standard.set(stored, forKey: key)
            report.applied.append(key)
        }
        // `@AppStorage` inside an ObservableObject does not publish on an
        // external UserDefaults write; tell observers explicitly.
        if !report.applied.isEmpty { objectWillChange.send() }
        return report
    }

    /// Parse and apply a JSON export. Throws on malformed JSON, a file
    /// whose top level is not an object, or a file whose format tag is
    /// newer than this build writes — its keys may mean something else,
    /// so nothing is applied rather than half of it.
    @discardableResult
    func importSettings(json data: Data) throws -> ImportReport {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSLocalizedDescriptionKey: "The file is not a Qnet settings export (expected a JSON object of setting keys)."])
        }
        if let format = (dict[Self.exportFormatKey] as? NSNumber)?.intValue, format > Self.exportFormatVersion {
            let writer = (dict[Self.exportVersionKey] as? String).map { " by Qnet \($0)" } ?? ""
            throw CocoaError(.fileReadUnsupportedScheme,
                             userInfo: [NSLocalizedDescriptionKey:
                                "The file uses settings format \(format) (written\(writer)); this build reads format \(Self.exportFormatVersion) or older. Update Qnet to import it."])
        }
        return importSettings(dict)
    }

    // MARK: - Per-area reset helpers
    //
    // Each helper restores exactly the keys shown on the matching Settings
    // pane and nothing else. QnetGUIApp's run dialogs may call these (or
    // read `Defaults.*` directly) instead of hardcoding literals.

    func resetGeneral() {
        tabRestoreBehavior          = Defaults.tabRestoreBehavior
        rememberRunComparisonChoice = Defaults.rememberRunComparisonChoice
    }

    func resetSimulation() {
        simReplications = Defaults.simReplications
        simWarmup       = Defaults.simWarmup
        simTime         = Defaults.simTime
        simParallel     = Defaults.simParallel
        simBlocking     = Defaults.simBlocking
        simSeedFixed    = Defaults.simSeedFixed
        simSeed         = Defaults.simSeed
    }

    func resetExactSimulation() {
        exactSimEpsilon      = Defaults.exactSimEpsilon
        exactSimGamma        = Defaults.exactSimGamma
        exactSimOverrideT    = Defaults.exactSimOverrideT
        exactSimT            = Defaults.exactSimT
        exactSimOverrideL    = Defaults.exactSimOverrideL
        exactSimL            = Defaults.exactSimL
        exactSimOverrideN    = Defaults.exactSimOverrideN
        exactSimN            = Defaults.exactSimN
        exactSimBackend      = Defaults.exactSimBackend
        exactSimThreads      = Defaults.exactSimThreads
        exactSimSeedFixed    = Defaults.exactSimSeedFixed
        exactSimSeed         = Defaults.exactSimSeed
        exactSimAntithetic   = Defaults.exactSimAntithetic
        exactSimAdaptive     = Defaults.exactSimAdaptive
        exactSimBatchSize    = Defaults.exactSimBatchSize
        exactSimMinSamples   = Defaults.exactSimMinSamples
        exactSimMaxSamples   = Defaults.exactSimMaxSamples
        exactSimReplications = Defaults.exactSimReplications
    }

    func resetLinearProgram() {
        lpGridN          = Defaults.lpGridN
        lpBasisM         = Defaults.lpBasisM
        lpSolver         = Defaults.lpSolver
        lpGridType       = Defaults.lpGridType
        lpSmoothness     = Defaults.lpSmoothness
        lpBasisNormalize = Defaults.lpBasisNormalize
        lpAskBeforeRun   = Defaults.lpAskBeforeRun
        lpMultiLevel     = Defaults.lpMultiLevel
    }

    func resetFiniteLP() {
        flpGridN          = Defaults.flpGridN
        flpBasisM         = Defaults.flpBasisM
        flpSolver         = Defaults.flpSolver
        flpGridType       = Defaults.flpGridType
        flpBasisNormalize = Defaults.flpBasisNormalize
        flpAskBeforeRun   = Defaults.flpAskBeforeRun
    }

    func resetFiniteElement() {
        femSolver   = Defaults.femSolver
        femMeshSize = Defaults.femMeshSize
    }

    func resetSpectral() {
        smDegree   = Defaults.smDegree
        smLegendre = Defaults.smLegendre
    }

    func resetTestSets() {
        testsetInfStationsLo = Defaults.testsetInfStationsLo
        testsetInfStationsHi = Defaults.testsetInfStationsHi
        testsetInfClassesLo  = Defaults.testsetInfClassesLo
        testsetInfClassesHi  = Defaults.testsetInfClassesHi
        testsetInfRhoLo      = Defaults.testsetInfRhoLo
        testsetInfRhoHi      = Defaults.testsetInfRhoHi
        testsetInfNumCases   = Defaults.testsetInfNumCases
        testsetInfTopology   = Defaults.testsetInfTopology

        testsetFinStationsLo = Defaults.testsetFinStationsLo
        testsetFinStationsHi = Defaults.testsetFinStationsHi
        testsetFinClassesLo  = Defaults.testsetFinClassesLo
        testsetFinClassesHi  = Defaults.testsetFinClassesHi
        testsetFinRhoLo      = Defaults.testsetFinRhoLo
        testsetFinRhoHi      = Defaults.testsetFinRhoHi
        testsetFinNumCases   = Defaults.testsetFinNumCases
        testsetFinTopology   = Defaults.testsetFinTopology

        testsetSpcStationsLo = Defaults.testsetSpcStationsLo
        testsetSpcStationsHi = Defaults.testsetSpcStationsHi
        testsetSpcClassesLo  = Defaults.testsetSpcClassesLo
        testsetSpcClassesHi  = Defaults.testsetSpcClassesHi
        testsetSpcRhoStart   = Defaults.testsetSpcRhoStart
        testsetSpcRhoEnd     = Defaults.testsetSpcRhoEnd
        testsetSpcRhoStep    = Defaults.testsetSpcRhoStep
        testsetSpcNumCases   = Defaults.testsetSpcNumCases
        testsetSpcTopology   = Defaults.testsetSpcTopology
    }

    func resetOutputFormat() {
        outputDecimals = Defaults.outputDecimals
    }

    /// Shell, Status and AI Assistant pane type and colours (Settings ▸
    /// Panes; the stored pane id is still "Interactive Shell Window").
    func resetInterface() {
        shellFontSize  = Defaults.shellFontSize
        shellFontName  = Defaults.shellFontName
        shellClassicTheme = Defaults.shellClassicTheme
        statusFontSize = Defaults.statusFontSize
        aiFontSize     = Defaults.aiFontSize
        aiFontName     = Defaults.aiFontName
    }

    func resetHelp() {
        helpOutputDestination = Defaults.helpOutputDestination
    }

    /// Every pane's reset in one call (Settings ▸ General ▸ Reset All
    /// Settings…). Like the per-pane helpers it leaves the Keychain, the
    /// selected AI provider, the visibility of every pane (Palette,
    /// Inspector, Status, Shell and AI Assistant — View ▸ Panes state, not
    /// a setting), which pane is maximized, the one-shot "Results has
    /// revealed itself once" flag, and the vestigial `gcdg.enabled` alone
    /// — only what a Settings pane shows is reset, and a Reset never
    /// rearranges the main window.
    func resetAll() {
        resetGeneral()
        resetSimulation()
        resetExactSimulation()
        resetLinearProgram()
        resetFiniteLP()
        resetFiniteElement()
        resetSpectral()
        resetTestSets()
        resetOutputFormat()
        resetInterface()
        resetHelp()
        resetAI()
    }

    /// Generation parameters plus the current provider's endpoint and
    /// model. Does not touch the Keychain (the API key is the user's
    /// secret, never "reset"), does not change the selected provider, and
    /// does not show or hide the AI Assistant pane — `ai.paneVisible` is
    /// View ▸ Panes state like its four siblings, and a Reset button must
    /// never rearrange the main window.
    func resetAI() {
        let p = aiProviderResolved
        setAIBaseURL(p.defaultBaseURL, for: p)
        setAIModel(p.defaultModel, for: p)
        setAIDiscoveredModels([], for: p)
        aiSystemPrompt = Defaults.aiSystemPrompt
        aiMaxTokens    = Defaults.aiMaxTokens
        aiTemperature  = Defaults.aiTemperature
        aiTimeoutSec   = Defaults.aiTimeoutSec
    }
}
