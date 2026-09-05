import SwiftUI
import AppKit

/// Scientific role of a solver result. Keeping this visible prevents a
/// numerical cross-check of one SRBM from being mistaken for independent
/// validation of the original queueing process.
enum MethodModelLayer: String, CaseIterable {
    case exactQueue = "Exact queue"
    case queueApproximation = "Queue approximation"
    case queueSimulation = "Queue simulation"
    case srbmAnalytical = "SRBM analytical"
    case srbmNumerical = "SRBM numerical"

    var tint: Color {
        switch self {
        case .exactQueue:         return DS.Color.success
        case .queueSimulation:    return DS.Color.info
        case .queueApproximation: return DS.Color.warning
        case .srbmAnalytical:     return DS.Color.accent
        case .srbmNumerical:      return DS.Color.accent
        }
    }
}

enum MethodSuitability: String {
    case recommended = "Recommended"
    case applicable = "Applicable"
    case caution = "Caution"
    case experimental = "Experimental"
    case unavailable = "Unavailable"

    var tint: Color {
        switch self {
        case .recommended: return DS.Color.success
        case .applicable:  return DS.Color.info
        case .caution:     return DS.Color.warning
        case .experimental:return DS.Color.warning
        case .unavailable: return DS.Color.textSecondary
        }
    }

    var rank: Int {
        switch self {
        case .recommended:  return 0
        case .applicable:   return 1
        case .caution:      return 2
        case .experimental: return 3
        case .unavailable:  return 4
        }
    }
}

struct MethodAdvice: Identifiable {
    let id: String
    let name: String
    let implementation: String
    let layer: MethodModelLayer
    let suitability: MethodSuitability
    let summary: String
    let assumptions: String
    let cost: String
    let outputs: String
    let helpTopic: HelpTopic
}

@MainActor
enum MethodAdvisor {
    static func recommendations(for editor: NetworkEditorModel) -> [MethodAdvice] {
        let stations = editor.nodes.filter { $0.kind == .station }
        let classIDs = Set(
            editor.links.flatMap { link in
                [link.customerClass, link.toCustomerClass ?? link.customerClass]
            } + stations.flatMap { Array($0.serviceDistributions.keys) }
        )
        let classes = max(classIDs.count, 1)
        let warningSuffix = editor.networkWarningList.isEmpty
            ? ""
            : " Review the \(editor.networkWarningList.count) current network warning\(editor.networkWarningList.count == 1 ? "" : "s")."
        var rows: [MethodAdvice] = []

        if editor.isAnalyticallyTractable {
            rows.append(MethodAdvice(
                id: "analytical",
                name: editor.tractabilityIsExact ? "Analytical solution" : "Asymptotic product form",
                implementation: editor.tractabilityDetail,
                layer: editor.tractabilityIsExact ? .exactQueue : .srbmAnalytical,
                suitability: .recommended,
                summary: editor.tractabilityTitle,
                assumptions: editor.tractabilityExplanation.isEmpty
                    ? "The current network passed Qnet's tractability test."
                    : editor.tractabilityExplanation,
                cost: "Immediate",
                outputs: "Per-station steady-state means",
                helpTopic: .analyticalTractability
            ))
        }

        if editor.infiniteBuffers {
            rows += infiniteRows(editor: editor, stationCount: stations.count,
                                 classCount: classes, warningSuffix: warningSuffix)
        } else {
            rows += finiteRows(editor: editor, stationCount: stations.count,
                               classCount: classes, warningSuffix: warningSuffix)
        }
        return rows.sorted {
            if $0.suitability.rank != $1.suitability.rank {
                return $0.suitability.rank < $1.suitability.rank
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func infiniteRows(
        editor: NetworkEditorModel,
        stationCount: Int,
        classCount: Int,
        warningSuffix: String
    ) -> [MethodAdvice] {
        let diffusionStatus: MethodSuitability = editor.networkHasWarnings ? .caution : .applicable
        let qnaStatus: MethodSuitability = editor.hasFeedback ? .caution : .recommended
        let sourcesArePoisson = editor.nodes.filter { $0.kind == .source }.allSatisfy {
            $0.distribution == .poisson || $0.distribution == .exponential
        }
        let servicesAreExponential = editor.nodes.filter { $0.kind == .station }.allSatisfy {
            $0.distribution == .exponential
                && $0.serviceDistributions.values.allSatisfy { $0.distribution == .exponential }
        }
        let truncatedApplicable = classCount == 1 && sourcesArePoisson && servicesAreExponential
        let regenerativeApplicable = sourcesArePoisson && servicesAreExponential
            && !editor.links.contains(where: { $0.hasClassTransition })
            && hasClassIndependentService(editor)
        let productFormResult = ProductFormExporter.export(
            editor: editor, name: "Applicability preview"
        )
        let productFormApplicable: Bool
        let productFormReason: String
        switch productFormResult {
        case .success:
            productFormApplicable = true
            productFormReason = "All exact open FCFS BCMP/Jackson assumptions pass."
        case .failure(let error):
            productFormApplicable = false
            productFormReason = error.localizedDescription
        }
        let qbdResult = QBDExporter.export(
            editor: editor, name: "Applicability preview"
        )
        let qbdApplicable: Bool
        let qbdReason: String
        switch qbdResult {
        case .success:
            qbdApplicable = true
            qbdReason = "The network maps exactly to a scalar, level-independent QBD."
        case .failure(let error):
            qbdApplicable = false
            qbdReason = error.localizedDescription
        }
        let productFormRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "solver.py", subdirectory: "BNApf", groups: ["infinite"]
        )
        let qbdRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "qbd_solver.py", subdirectory: "BNAqbd", groups: ["infinite"]
        )
        let regenerativeRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "regenerative_mc.py", subdirectory: "BNArmc", groups: ["infinite"]
        )
        let truncatedRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "truncated_ctmc.py", subdirectory: "BNAtc", groups: ["infinite"]
        )
        let adaptiveBARRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "low_rank_bar.py", subdirectory: "BNAalr", groups: ["infinite"]
        )
        let momentBoundsRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "solver.py", subdirectory: "BNAbb", groups: ["infinite"]
        )
        let productFormReady = productFormApplicable && productFormRuntime.url != nil
        let qbdReady = qbdApplicable && qbdRuntime.url != nil
        let regenerativeReady = regenerativeApplicable && regenerativeRuntime.url != nil
        let truncatedReady = truncatedApplicable && truncatedRuntime.url != nil
        let heavyJackson = editor.tractabilityIsExact
            && editor.tractabilityMeansLabel.localizedCaseInsensitiveContains("Jackson")
            && editor.tractabilityMeans.reduce(0, +) > 20
        let multiClassRuntimeAvailable = SolverRuntimeResolver.shared.resolveExecutable(
            name: "mc_solver", subdirectory: "BNAmd"
        ).url != nil
        return [
            MethodAdvice(
                id: "open-product-form", name: "Exact Open Product Form",
                implementation: "product_form · open_bcmp",
                layer: .exactQueue,
                suitability: productFormReady ? .recommended : .unavailable,
                summary: !productFormApplicable
                    ? productFormReason
                    : (productFormRuntime.url == nil
                       ? "The model qualifies, but \(pythonRuntimeReason(productFormRuntime))."
                       : "Computes exact M/M/c station measures analytically without truncating the infinite state space."),
                assumptions: "Infinite-capacity open network; independent Poisson arrivals; exponential, class-independent FCFS service; class-preserving routing; strict station stability.",
                cost: "Very low; traffic equations plus local Erlang-C normalizers",
                outputs: "Exact station population, throughput, utilization and stability margin",
                helpTopic: .analyticalTractability
            ),
            MethodAdvice(
                id: "qbd", name: "Exact Matrix-Analytic QBD",
                implementation: "matrix_analytic · qbd_solver.py",
                layer: .exactQueue,
                suitability: qbdReady ? .recommended : .unavailable,
                summary: !qbdApplicable
                    ? qbdReason
                    : (qbdRuntime.url == nil
                       ? "The model qualifies, but \(pythonRuntimeReason(qbdRuntime))."
                       : qbdReason),
                assumptions: "Infinite-capacity open one-station M/M/1 queue; one Poisson source/class; exponential service; optional class-preserving feedback; strict positive recurrence.",
                cost: "Very low for the scalar adapter; matrix-geometric iteration with residual checks",
                outputs: "Exact mean, variance, empty probability, tail probabilities and matrix-geometric numerical evidence",
                helpTopic: .analyticalTractability
            ),
            MethodAdvice(
                id: "simulation-infinite", name: "Monte Carlo", implementation: "BNAsim · jackson_sim",
                layer: .queueSimulation, suitability: .recommended,
                summary: "Directly simulates the queueing process and supplies the main cross-model reference.",
                assumptions: "Uses the distributions, classes and routing represented by the simulator. Report confidence intervals and check warm-up sensitivity.",
                cost: "High; grows with replications, event count and mixing time",
                outputs: "Means, throughput, sojourn and confidence intervals",
                helpTopic: .simulationInfinite
            ),
            MethodAdvice(
                id: "regenerative-mc", name: "Regenerative Monte Carlo",
                implementation: "regenerative_mc · regenerative_mc.py",
                layer: .queueSimulation,
                suitability: regenerativeReady
                    ? (heavyJackson ? .caution : .applicable) : .unavailable,
                summary: !regenerativeApplicable
                    ? "Requires class-preserving Poisson/exponential Markov primitives and one service rate per station across classes."
                    : (regenerativeRuntime.url == nil
                       ? pythonRuntimeReason(regenerativeRuntime)
                       : "Uses complete empty-to-empty cycles and stops when every monitored precision requirement is met."),
                assumptions: "Open FCFS M/M/c network with strict Jackson load below one. Cycle-level t intervals are asymptotic; empty-system returns may be slow in heavy traffic.",
                cost: "Adaptive; can be high when cycles are long or the requested interval is narrow",
                outputs: "Station/class means, utilization, flow, cycle-level intervals, effective cycles and stopping reason",
                helpTopic: .regenerativeSimulation
            ),
            MethodAdvice(
                id: "qna", name: "Whitt QNA", implementation: "BNAqna · bna_qna",
                layer: .queueApproximation, suitability: qnaStatus,
                summary: editor.hasFeedback
                    ? "Fast two-moment approximation; feedback can weaken renewal assumptions."
                    : "Fast first estimate for station means and delays.",
                assumptions: "Open network, class-blind FCFS station approximation and two-moment arrival/service descriptions.\(warningSuffix)",
                cost: "Very low",
                outputs: "Per-station mean queue, waiting and utilisation",
                helpTopic: .qna
            ),
            MethodAdvice(
                id: "truncated-ctmc", name: "Adaptive Truncated CTMC",
                implementation: "truncated_ctmc · truncated_ctmc.py",
                layer: .queueApproximation,
                suitability: truncatedReady
                    ? (heavyJackson ? .caution : .applicable) : .unavailable,
                summary: !truncatedApplicable
                    ? "Requires one class, Poisson arrivals and exponential service."
                    : (truncatedRuntime.url == nil
                       ? pythonRuntimeReason(truncatedRuntime)
                       : "Solves sparse finite caps until boundary mass and successive queue moments stabilize."),
                assumptions: "Open single-class M/M/c network. Stability is certified; truncation convergence remains heuristic unless a separately reported Foster bound applies.",
                cost: "Potentially combinatorial in station count and selected population cap",
                outputs: "Queue means, utilization, departures, residuals, refinement history and optional tail/moment certificates",
                helpTopic: .adaptiveTruncatedCTMC
            ),
            MethodAdvice(
                id: "adaptive-low-rank-bar", name: "Adaptive Low-Rank BAR",
                implementation: "adaptive_srbm · low_rank_bar.py",
                layer: .srbmNumerical,
                suitability: stationCount <= 32 && adaptiveBARRuntime.url != nil
                    ? .experimental : .unavailable,
                summary: stationCount > 32
                    ? "The maintained Halton construction is limited to thirty-two SRBM dimensions."
                    : (adaptiveBARRuntime.url == nil
                       ? pythonRuntimeReason(adaptiveBARRuntime)
                       : "Fits an adaptive low-rank exponential mixture and validates it on held-out BAR points."),
                assumptions: "Stable orthant SRBM with positive-semidefinite covariance and nonsingular M-matrix reflection. Residual and refinement checks are evidence, not moment-error bounds.",
                cost: "Moderate; grows with selected mixture rank rather than a tensor grid",
                outputs: "Workload means and variances, rank history, held-out BAR residuals and convergence warnings",
                helpTopic: .adaptiveLowRankBAR
            ),
            MethodAdvice(
                id: "bar-moment-bounds", name: "BAR Moment Bounds",
                implementation: "bar_bounds · solver.py",
                layer: .srbmNumerical,
                suitability: momentBoundsRuntime.url == nil
                    ? .unavailable : (stationCount <= 4 ? .experimental : .caution),
                summary: momentBoundsRuntime.url == nil
                    ? pythonRuntimeReason(momentBoundsRuntime)
                    : (stationCount == 1
                       ? "Returns a certified exact stationary workload moment for the one-dimensional SRBM."
                       : "Builds a Stieltjes moment-SDP outer relaxation; an optional SDP backend is needed for general numerical bounds."),
                assumptions: "Stable orthant SRBM with positive-definite covariance and nonsingular M-matrix reflection. Only exact 1D or exact product-form branches are certified without an external conic certificate.",
                cost: stationCount > 4
                    ? "High; moment and PSD block counts grow combinatorially"
                    : "Low for exact cases; potentially high for the SDP relaxation",
                outputs: "Certified special-case bounds or explicitly uncertified lower/upper SDP results with feasibility diagnostics",
                helpTopic: .barMomentBounds
            ),
            MethodAdvice(
                id: "rqna", name: "Whitt–You RQNA", implementation: "BNArqna · bna_rqna",
                layer: .queueApproximation, suitability: editor.hasFeedback ? .recommended : .applicable,
                summary: "Propagates variability over multiple time scales and is useful when a scalar SCV is insufficient.",
                assumptions: "Robust single-server waiting formulation; multi-server portions remain QNA-like.\(warningSuffix)",
                cost: "Very low",
                outputs: "Per-station means and robust variability estimates",
                helpTopic: .rqna
            ),
            MethodAdvice(
                id: "sbd", name: "Sequential Bottleneck Decomposition", implementation: "BNAsbd · bna_sbd",
                layer: .srbmNumerical, suitability: diffusionStatus,
                summary: "Decomposes the heavy-traffic network into bottleneck RBM subproblems.",
                assumptions: "Most persuasive when important stations operate in heavy traffic; station-aggregate output.\(warningSuffix)",
                cost: "Low to moderate",
                outputs: "Per-station steady-state means",
                helpTopic: .sbd
            ),
            MethodAdvice(
                id: "spectral-infinite", name: "Spectral Method", implementation: "BNAsm · bnet",
                layer: .srbmNumerical,
                suitability: stationCount > 8 ? .caution : diffusionStatus,
                summary: "Global Galerkin approximation of the stationary SRBM density.",
                assumptions: "Heavy-traffic Brownian model; basis cost grows rapidly with dimension and degree.\(warningSuffix)",
                cost: stationCount > 8 ? "High at \(stationCount) stations" : "Moderate; degree-dependent",
                outputs: "Stationary density moments and per-station means",
                helpTopic: .spectralInfinite
            ),
            MethodAdvice(
                id: "mlmc", name: "SRBM MLMC", implementation: "BNAmc · rbm_mlmc",
                layer: .srbmNumerical, suitability: diffusionStatus,
                summary: "Monte Carlo estimator for the stationary reflected Brownian model, with confidence intervals.",
                assumptions: "Infinite-buffer SRBM. Finite path length T and level L leave explicit bias; workload conversion is station-aggregated.\(warningSuffix)",
                cost: "Moderate to high; approximately linear in station count",
                outputs: "SRBM workload/queue means and Monte Carlo intervals",
                helpTopic: .exactSimulation
            ),
            MethodAdvice(
                id: "lp-infinite", name: "Linear Program", implementation: "BNAlp · srbm_lp",
                layer: .srbmNumerical,
                suitability: stationCount > 15 ? .unavailable
                    : (stationCount > 8 ? .caution : diffusionStatus),
                summary: "BAR occupation-measure relaxation for SRBM stationary moments.",
                assumptions: "Heavy-traffic SRBM; accuracy and cost depend on grid and basis.\(warningSuffix)",
                cost: "Moderate to high; grid-dependent",
                outputs: "Stationary moment estimates and marginals",
                helpTopic: .linearProgramInfinite
            ),
            MethodAdvice(
                id: "multiclass-srbm", name: "Multi-Class SRBM",
                implementation: "multiclass_diffusion · mc_solver",
                layer: .srbmNumerical,
                suitability: classCount > 1 && multiClassRuntimeAvailable
                    ? .experimental : .unavailable,
                summary: classCount > 1 && multiClassRuntimeAvailable
                    ? "Experimental class-aware service moments, traffic equations and routing covariance."
                    : (classCount <= 1
                       ? "The current network has only one customer class."
                       : "The optional solver is unavailable in this build; its dependency manifest explains why."),
                assumptions: "Heavy traffic and state-space collapse; the diffusion retains one workload coordinate per station and maps it back to classes.",
                cost: "Research implementation; mesh-dependent",
                outputs: "Station and class-derived workload estimates",
                helpTopic: .multiClassSRBM
            )
        ]
    }

    private static func finiteRows(
        editor: NetworkEditorModel,
        stationCount: Int,
        classCount: Int,
        warningSuffix: String
    ) -> [MethodAdvice] {
        let diffusionStatus: MethodSuitability = editor.networkHasWarnings ? .caution : .applicable
        let sourcesArePoisson = editor.nodes.filter { $0.kind == .source }.allSatisfy {
            $0.distribution == .poisson || $0.distribution == .exponential
        }
        let servicesAreExponential = editor.nodes.filter { $0.kind == .station }.allSatisfy {
            $0.distribution == .exponential
                && $0.serviceDistributions.values.allSatisfy { $0.distribution == .exponential }
        }
        let markovian = sourcesArePoisson && servicesAreExponential
        let regenerativeApplicable = markovian
            && !editor.links.contains(where: { $0.hasClassTransition })
            && hasClassIndependentService(editor)
        let ctmcLikely = markovian && stationCount <= 6
        let regenerativeRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "regenerative_mc.py", subdirectory: "BNArmc", groups: ["infinite"]
        )
        let ctmcRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "solver.py", subdirectory: "fBNAgc", groups: ["finite"]
        )
        let decompositionRuntime = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "fbna_decomp.py", subdirectory: "fBNAdecomp", groups: ["finite"]
        )
        let regenerativeReady = regenerativeApplicable && regenerativeRuntime.url != nil
        let ctmcReady = ctmcLikely && ctmcRuntime.url != nil
        let decompositionReady = markovian && decompositionRuntime.url != nil
        return [
            MethodAdvice(
                id: "simulation-finite", name: "Monte Carlo", implementation: "fBNAsim",
                layer: .queueSimulation, suitability: .recommended,
                summary: "Direct queue-process reference for loss, BAS, or BAS with external loss.",
                assumptions: "Choose the blocking rule that matches the real system; retain confidence intervals and check warm-up sensitivity.",
                cost: "High; grows with event count and mixing time",
                outputs: "Queue means, throughput, blocking, sojourn and intervals",
                helpTopic: .simulationFinite
            ),
            MethodAdvice(
                id: "regenerative-mc", name: "Regenerative Monte Carlo",
                implementation: "regenerative_mc · regenerative_mc.py",
                layer: .queueSimulation,
                suitability: regenerativeReady ? .applicable : .unavailable,
                summary: !regenerativeApplicable
                    ? "Requires class-preserving Poisson/exponential primitives and one service rate per station across classes."
                    : (regenerativeRuntime.url == nil
                       ? pythonRuntimeReason(regenerativeRuntime)
                       : "Cycle-level fixed-width simulation for the finite loss-on-full queueing process."),
                assumptions: "All stations use finite total capacities and loss on full. The optional rare-event likelihood-ratio mode is intentionally limited to one-node M/M/1/K input.",
                cost: "Adaptive; grows with requested interval width and empty-return cycle length",
                outputs: "Station/class means, blocking, throughput, intervals, effective cycles and stopping reason",
                helpTopic: .regenerativeSimulation
            ),
            MethodAdvice(
                id: "ctmc", name: "Exact Sparse CTMC", implementation: "generic_ctmc · solver.py",
                layer: .exactQueue, suitability: ctmcReady ? .applicable : .unavailable,
                summary: !ctmcLikely
                    ? (markovian
                       ? "The Markov assumptions hold, but the state space may be large; the solver will stop safely at its configured limit."
                       : "Requires Poisson arrivals and exponential service for every represented class.")
                    : (ctmcRuntime.url == nil
                       ? pythonRuntimeReason(ctmcRuntime)
                       : "Exact queue-process benchmark with reachable-state enumeration and a hard state-space safety limit."),
                assumptions: "Finite loss-on-full network, FCFS, Markovian primitives, state-independent routing and a manageable reachable ordered-class state space.",
                cost: "Potentially exponential in capacities, classes and stations",
                outputs: "Stationary distribution, queue means, loss, throughput, delays and generator residual",
                helpTopic: .ctmc
            ),
            MethodAdvice(
                id: "finite-decomposition", name: "Finite-Buffer Decomposition",
                implementation: "fBNAdecomp · fbna_decomp.py",
                layer: .queueApproximation,
                suitability: decompositionReady ? .recommended : .unavailable,
                summary: !markovian
                    ? "Requires Poisson arrivals and exponential FCFS service."
                    : (decompositionRuntime.url == nil
                       ? pythonRuntimeReason(decompositionRuntime)
                       : "A fast M/M/c/K fixed point for networks too large for exact state enumeration."),
                assumptions: "Poisson arrivals and exponential FCFS service. Loss is a station-independence approximation; BAS modes add a clearly labeled frozen-server closure.\(warningSuffix)",
                cost: "Low; station state spaces are solved independently",
                outputs: "Queue means, full/loss probabilities, throughput, delay, conservation and convergence residuals",
                helpTopic: .finiteDecomposition
            ),
            MethodAdvice(
                id: "spectral-finite", name: "Finite Spectral Method", implementation: "fBNAsm · srbm_solver",
                layer: .srbmNumerical, suitability: diffusionStatus,
                summary: "Global polynomial approximation of a bounded SRBM on the buffer hypercube.",
                assumptions: "Continuous upper-face reflection is not identical to every discrete loss/BAS rule.\(warningSuffix)",
                cost: "Moderate to high; degree and dimension dependent",
                outputs: "Bounded-SRBM density moments and queue means",
                helpTopic: .spectralFinite
            ),
            MethodAdvice(
                id: "fem-finite", name: "Finite Element", implementation: "fBNAfm · bna_fm_gauss",
                layer: .srbmNumerical, suitability: diffusionStatus,
                summary: "Local Hermite finite-element approximation of the bounded SRBM density.",
                assumptions: "Best suited to low/moderate dimension; retain the selected blocking convention when comparing to DES.\(warningSuffix)",
                cost: stationCount > 4 ? "High at \(stationCount) stations" : "Moderate; mesh-dependent",
                outputs: "Bounded-SRBM stationary density and moments",
                helpTopic: .finiteElement
            ),
            MethodAdvice(
                id: "lp-finite", name: "Finite-Buffer LP", implementation: "fBNAlp · fBNAlp_solver",
                layer: .srbmNumerical, suitability: diffusionStatus,
                summary: "BAR relaxation with lower- and upper-face occupation measures.",
                assumptions: "Bounded SRBM; grid/basis resolution and blocking corrections matter.\(warningSuffix)",
                cost: "Moderate to high; grid-dependent",
                outputs: "Stationary moment estimates and marginals",
                helpTopic: .finiteLP
            )
        ]
    }

    private static func pythonRuntimeReason(_ lookup: SolverRuntimeLookup) -> String {
        if let failure = lookup.attempts.last(where: {
            $0.outcome == .runtimeUnavailable
                || $0.outcome == .notReadable
                || $0.outcome == .loaderRejected
        }) {
            return failure.detail
        }
        if let reason = lookup.declaredUnavailableReason, !reason.isEmpty {
            return reason
        }
        return "the Python-backed solver support is unavailable in this installation"
    }

    private static func hasClassIndependentService(_ editor: NetworkEditorModel) -> Bool {
        var classes = Set(editor.links.flatMap { [$0.customerClass, $0.exitClass] })
        for source in editor.nodes where source.kind == .source {
            classes.insert(editor.customerClassIndex(for: source.id))
        }
        if classes.isEmpty { classes.insert(0) }
        return editor.nodes.filter { $0.kind == .station }.allSatisfy { station in
            let rates = classes.compactMap { classIndex -> Double? in
                let config = station.serviceDistributions[classIndex]
                    ?? ServiceDistributionConfig(
                        distribution: station.distribution,
                        distributionParameters: station.distributionParameters
                    )
                guard config.distribution == .exponential else { return nil }
                let parameters = QueueDistribution.parseParameterStrings(
                    config.distributionParameters
                )
                return parameters["rate"].flatMap(Double.init)
            }
            guard rates.count == classes.count, let first = rates.first,
                  first.isFinite, first > 0 else { return false }
            return rates.allSatisfy {
                $0.isFinite && $0 > 0
                    && abs($0 - first) <= 1e-10 * max(1, max(abs(first), abs($0)))
            }
        }
    }
}

/// What the Method Chooser window is currently advising about.
///
/// The window is built once and then reused, because rebuilding it throws
/// away the frame the user dragged it to (`AuxiliaryWindow.make` centres
/// what it builds, and the autosaver only remembers the frame — not the
/// fact that this window was already open where they left it). So the two
/// things that change between one Run ▸ Choose a Method… and the next —
/// which editor is active, and the closure that launches a method into it
/// — cannot be baked into the view at construction; they live here, and
/// the hosted `MethodChooserWindowRoot` observes them.
@MainActor
final class MethodChooserModel: ObservableObject {
    static let shared = MethodChooserModel()

    @Published fileprivate var editor: NetworkEditorModel?
    /// Not `@Published`: swapping the launcher must not redraw the list,
    /// and a closure is not Equatable so it could not be diffed anyway.
    fileprivate var runMethod: (String) -> Void = { _ in }

    private init() {}

    fileprivate func update(editor: NetworkEditorModel, runMethod: @escaping (String) -> Void) {
        self.runMethod = runMethod
        if self.editor !== editor { self.editor = editor }
    }
}

/// Root of the reused window: renders the chooser for whichever editor the
/// model currently points at.
private struct MethodChooserWindowRoot: View {
    @ObservedObject var model: MethodChooserModel
    let close: () -> Void

    var body: some View {
        if let editor = model.editor {
            MethodChooserView(
                editor: editor,
                close: close,
                // Read through the model, not captured: the window outlives
                // the presentation that opened it.
                runMethod: { model.runMethod($0) })
        } else {
            // Only reachable if the window is somehow shown before any
            // editor has claimed it; a live empty state beats a blank pane.
            DSEmptyState(
                systemImage: DS.Symbol.network,
                title: "No Active Network",
                message: "Open or create a network, then choose a method for it.")
            .frame(minWidth: DS.Layout.Window.auxMinWidth,
                   minHeight: DS.Layout.Window.auxMinHeight)
        }
    }
}

struct MethodChooserView: View {
    @ObservedObject var editor: NetworkEditorModel
    let close: () -> Void
    let runMethod: (String) -> Void
    @State private var search = ""

    private var methods: [MethodAdvice] {
        let rows = MethodAdvisor.recommendations(for: editor)
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            [$0.name, $0.implementation, $0.layer.rawValue, $0.suitability.rawValue,
             $0.summary, $0.assumptions, $0.outputs]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSRule()
            summary
            DSRule()
            ScrollView {
                LazyVStack(spacing: DS.Spacing.m) {
                    ForEach(methods) { advice in
                        MethodAdviceRow(advice: advice) {
                            close()
                            DispatchQueue.main.async { runMethod(advice.id) }
                        }
                    }
                    if methods.isEmpty {
                        DSEmptyState.search(query: search)
                            .padding(DS.Spacing.xl)
                    }
                }
                .padding(DS.Spacing.l)
            }
            DSRule()
            HStack {
                Text("Guidance describes applicability and model scope; it is not an error guarantee.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.m)
            .background(DS.Color.surface)
        }
        .frame(minWidth: DS.Layout.Window.auxMinWidth,
               minHeight: DS.Layout.Window.auxMinHeight)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: DS.Symbol.network)
                .font(DS.Font.sheetGlyph)
                .foregroundStyle(DS.Color.infoText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Choose a Method")
                    .font(DS.Font.sheetTitle)
                Text("Ranked for the active network")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            DSSearchField(
                text: $search,
                placeholder: "Filter methods",
                help: "Filter by method, model layer, assumptions or output",
                accessibilityLabel: "Filter methods"
            )
            .frame(width: DS.Layout.wideFieldWidth)
        }
        .padding(DS.Spacing.l)
        .background(DS.Color.surface)
    }

    private var summary: some View {
        HStack(spacing: DS.Spacing.s) {
            DSBadge(text: editor.infiniteBuffers ? "Infinite buffers" : "Finite buffers")
            DSBadge(text: "\(editor.nodes.filter { $0.kind == .station }.count) stations")
            if editor.hasFeedback {
                DSBadge(text: "Feedback", tint: DS.Color.warning, emphasis: .tinted)
            }
            if editor.networkHasWarnings {
                DSBadge(text: "\(editor.networkWarningList.count) warnings",
                        tint: DS.Color.warning, emphasis: .tinted)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Color.subtleFill)
    }
}

private struct MethodAdviceRow: View {
    let advice: MethodAdvice
    let run: () -> Void
    @DSAccessibility private var a11y

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(advice.name)
                        .font(DS.Font.headline)
                    Text(advice.implementation)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                DSBadge(text: advice.layer.rawValue, tint: advice.layer.tint, emphasis: .tinted)
                DSBadge(text: advice.suitability.rawValue,
                        tint: advice.suitability.tint, emphasis: .tinted)
            }

            Text(advice.summary)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.xs) {
                detailRow("Assumptions", advice.assumptions)
                detailRow("Cost", advice.cost)
                detailRow("Outputs", advice.outputs)
            }

            HStack {
                if advice.suitability != .unavailable {
                    Button("Run Method", action: run)
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Open Method Reference") {
                    QnetHelpWindow.show(topic: advice.helpTopic)
                }
                .buttonStyle(.link)
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .stroke(DS.Color.separator(a11y.contrast),
                        lineWidth: DS.Stroke.hairline(a11y.contrast))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(DS.Font.tableHeader)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Layout.compactFieldWidth, alignment: .leading)
            Text(value)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum MethodChooserWindow {
    private static var retained: NSWindow?

    /// Opens the chooser, or brings the open one forward and re-points it
    /// at `editor`. It is deliberately NOT closed and rebuilt: rebuilding
    /// lost the position the user had dragged it to within a single
    /// session, which is the whole complaint this window was fixed for.
    static func show(editor: NetworkEditorModel, runMethod: @escaping (String) -> Void) {
        let model = MethodChooserModel.shared
        model.update(editor: editor, runMethod: runMethod)

        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }

        let window = AuxiliaryWindow.make(
            id: "method-chooser",
            title: "Choose a Method",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetMethodChooserWindow"
        ) { ref in
            MethodChooserWindowRoot(model: model, close: { ref.close() })
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
}
