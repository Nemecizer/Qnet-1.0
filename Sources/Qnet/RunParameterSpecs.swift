import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// The forms behind Run ▸ …, File ▸ Export ▸ All Solver Inputs and the
// Run Comparison blocking prompt. Kept out of QnetGUIApp so the specs read as
// one family — same section names ("Method", "Run Length", "Performance"),
// same verbs, same units — and so the App file keeps only the launch logic.
//
// Every key is declared in `RunKey` so the spec and the code that reads the
// answer can never drift apart.
// ─────────────────────────────────────────────────────────────────────────────

/// Field keys shared by a spec and its `onRun` closure.
enum RunKey {
    static let blocking = "blocking"
    static let parallel = "parallel"
    static let replications = "replications"
    static let warmup = "warmup"
    static let simTime = "simTime"
    static let seedFixed = "seedFixed"
    static let seed = "seed"
    static let degree = "degree"
    static let legendre = "legendre"
    static let quadrature = "quadrature"
    static let mesh = "mesh"
    static let formulation = "formulation"
    static let gridN = "gridN"
    static let basisM = "basisM"
    static let solver = "solver"
    static let gridType = "gridType"
    static let smoothness = "smoothness"
    static let normalise = "normalise"
    static let multiLevel = "multiLevel"
    static let remember = "remember"
    static let convention = "convention"
    static let confidence = "confidence"
    static let absoluteHalfWidth = "absoluteHalfWidth"
    static let relativeHalfWidth = "relativeHalfWidth"
    static let minimumCycles = "minimumCycles"
    static let maximumCycles = "maximumCycles"
    static let maximumWallSeconds = "maximumWallSeconds"
    static let stream = "stream"
}

extension RunParameterSpec {

    // MARK: Shared field vocabulary

    /// The three finite-buffer blocking regimes, worded identically in the
    /// simulation dialog, the comparison prompt and the export sheet.
    static let blockingRegimes = [
        "Loss network (jobs discarded when full)",
        "BAS blocking (server blocks, external held)",
        "BAS + external loss (matches SRBM)",
    ]

    private static func replicationFields(warmupStep: Int = 100_000,
                                          timeStep: Int = 1_000_000) -> [RunParameterField] {
        [
            RunParameterField(RunKey.replications, "Replications",
                              .integer(range: 1...100_000),
                              help: "Independent runs averaged into the reported estimate; more replications narrow the confidence interval",
                              glossary: DS.Glossary.replications),
            RunParameterField(RunKey.warmup, "Warm-up period",
                              .integer(range: 0...1_000_000_000, step: warmupStep),
                              help: "Simulated model time discarded before statistics are collected, so the estimate is not biased by the empty initial state",
                              glossary: DS.Glossary.warmup,
                              unit: "time units"),
            RunParameterField(RunKey.simTime, "Simulation time",
                              .integer(range: 1...1_000_000_000, step: timeStep),
                              help: "Simulated time per replication",
                              unit: "time units"),
        ]
    }

    private static let runLengthFooter =
        "Statistics are collected after the warm-up period. The half-widths printed beside each result are 95 % confidence intervals."

    private static func reproducibilityFields(seedFixed: Bool, seed: Int) -> [RunParameterField] {
        [
            RunParameterField(
                RunKey.seedFixed, "Use fixed seed", .flag,
                help: "Use the entered base seed so this simulation can be reproduced exactly"
            ),
            RunParameterField(
                RunKey.seed, "Base random seed", .integer(range: 0...Int(Int32.max)),
                help: "The simulator derives each replication's stream deterministically from this base seed"
            ),
        ]
    }

    // MARK: Monte Carlo

    /// Run ▸ Run Monte Carlo (finite buffers) — fBNAsim.
    static func monteCarloFinite(blocking: Int, parallel: Int,
                                 replications: Int, warmup: Int, simTime: Int,
                                 seedFixed: Bool, seed: Int) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Monte Carlo",
            subtitle: "Discrete-event simulation of the finite-buffer network (fBNAsim). The blocking regime decides what happens to a job that finishes while the next buffer is full.",
            helpTopic: .simulationFinite,
            systemImage: DS.Symbol.simulation,
            sections: [
                RunParameterSection("Model", fields: [
                    RunParameterField(RunKey.blocking, "Blocking", .choice(blockingRegimes),
                                      help: "Which finite-buffer convention the simulator enforces",
                                      glossary: DS.Glossary.bas),
                ]),
                RunParameterSection("Run Length", footer: runLengthFooter,
                                    fields: replicationFields()),
                RunParameterSection(
                    "Reproducibility",
                    footer: "When the switch is off, Qnet generates a fresh base seed and still stores the seed used with the result.",
                    fields: reproducibilityFields(seedFixed: seedFixed, seed: seed)
                ),
                RunParameterSection("Performance", fields: [
                    RunParameterField(RunKey.parallel, "Parallelism", .choice([
                        "Apple GCD (recommended)",
                        "OpenMP",
                        "Sequential",
                    ]), help: "How replications are spread across CPU cores"),
                ]),
            ],
            values: [
                RunKey.blocking: .int(blocking),
                RunKey.parallel: .int(parallel),
                RunKey.replications: .int(replications),
                RunKey.warmup: .int(warmup),
                RunKey.simTime: .int(simTime),
                RunKey.seedFixed: .flag(seedFixed),
                RunKey.seed: .int(seed),
            ]
        )
    }

    /// Run ▸ Run Monte Carlo (infinite buffers) — jackson_sim.
    static func monteCarloInfinite(replications: Int, warmup: Int, simTime: Int,
                                   seedFixed: Bool, seed: Int) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Monte Carlo",
            subtitle: "Discrete-event simulation of the infinite-buffer network (jackson_sim). No blocking regime applies — buffers are unbounded.",
            helpTopic: .simulationInfinite,
            systemImage: DS.Symbol.simulation,
            size: .compact,
            sections: [
                RunParameterSection("Run Length", footer: runLengthFooter,
                                    fields: replicationFields()),
                RunParameterSection(
                    "Reproducibility",
                    footer: "When the switch is off, Qnet generates a fresh base seed and still stores the seed used with the result.",
                    fields: reproducibilityFields(seedFixed: seedFixed, seed: seed)
                ),
            ],
            values: [
                RunKey.replications: .int(replications),
                RunKey.warmup: .int(warmup),
                RunKey.simTime: .int(simTime),
                RunKey.seedFixed: .flag(seedFixed),
                RunKey.seed: .int(seed),
            ]
        )
    }

    /// Sequential fixed-width regenerative simulation for either supported
    /// buffer regime. Unlike replication/warm-up simulation, complete
    /// empty-to-empty cycles are the IID units and no warm-up is discarded
    /// when the network starts empty.
    static func regenerativeMonteCarlo(
        infiniteBuffers: Bool,
        seedFixed: Bool,
        seed: Int
    ) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Regenerative Monte Carlo",
            subtitle: infiniteBuffers
                ? "Cycle-level sequential simulation of the infinite-buffer Markovian queueing process."
                : "Cycle-level sequential simulation of the finite loss-on-full Markovian queueing process.",
            helpTopic: .regenerativeSimulation,
            systemImage: DS.Symbol.simulation,
            size: .regular,
            sections: [
                RunParameterSection(
                    "Precision",
                    footer: "Stopping is checked only after complete empty-to-empty cycles. The wider of the absolute and relative targets is used.",
                    fields: [
                        RunParameterField(
                            RunKey.confidence, "Confidence level",
                            .decimal(range: 0.80...0.999, step: 0.01),
                            help: "Nominal confidence for regenerative-ratio intervals"
                        ),
                        RunParameterField(
                            RunKey.absoluteHalfWidth, "Absolute half-width",
                            .decimal(range: 0...1000, step: 0.01),
                            help: "Smallest absolute interval target; 0 disables this component"
                        ),
                        RunParameterField(
                            RunKey.relativeHalfWidth, "Relative half-width",
                            .decimal(range: 0...1, step: 0.01),
                            help: "Target half-width as a fraction of the current estimate"
                        ),
                    ]
                ),
                RunParameterSection("Cycle Safeguards", fields: [
                    RunParameterField(
                        RunKey.minimumCycles, "Minimum cycles",
                        .integer(range: 30...1_000_000, step: 100),
                        help: "Complete cycles required before precision can stop the run"
                    ),
                    RunParameterField(
                        RunKey.maximumCycles, "Maximum cycles",
                        .integer(range: 30...10_000_000, step: 1000),
                        help: "Hard complete-cycle limit"
                    ),
                    RunParameterField(
                        RunKey.maximumWallSeconds, "Maximum wall time",
                        .integer(range: 1...86_400, step: 10),
                        help: "Stop cleanly at the next safe point after this elapsed time",
                        unit: "seconds"
                    ),
                ]),
                RunParameterSection(
                    "Reproducibility",
                    footer: "A separate stream value gives a deterministic replication stream. The effective component seeds are retained in structured output.",
                    fields: reproducibilityFields(seedFixed: seedFixed, seed: seed) + [
                        RunParameterField(
                            RunKey.stream, "Stream",
                            .integer(range: 0...Int(Int32.max)),
                            help: "Deterministic stream identifier mixed with the base seed"
                        ),
                    ]
                ),
            ],
            values: [
                RunKey.confidence: .double(0.95),
                RunKey.absoluteHalfWidth: .double(0.05),
                RunKey.relativeHalfWidth: .double(0.10),
                RunKey.minimumCycles: .int(500),
                RunKey.maximumCycles: .int(20_000),
                RunKey.maximumWallSeconds: .int(30),
                RunKey.seedFixed: .flag(seedFixed),
                RunKey.seed: .int(seed),
                RunKey.stream: .int(0),
            ]
        )
    }

    // MARK: Spectral

    /// Run ▸ Run Spectral Method (finite buffers) — srbm_solver.
    static func spectralFinite(degree: Int, legendre: Bool) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Spectral Method",
            subtitle: "Polynomial Galerkin solution of the SRBM on the hypercube (fBNAsm). Higher degrees are more accurate and cost more memory.",
            helpTopic: .spectralFinite,
            systemImage: DS.Symbol.formula,
            size: .compact,
            sections: [
                RunParameterSection("Basis",
                                    footer: "The Legendre basis is better conditioned above degree 10; the monomial basis is faster below it.",
                                    fields: [
                    RunParameterField(RunKey.degree, "Polynomial degree", .integer(range: 2...40),
                                      help: "Order of the polynomial basis (2–40). Cost grows quickly with degree and with the number of stations",
                                      glossary: DS.Glossary.polynomialDegree),
                    RunParameterField(RunKey.legendre, "Use Legendre basis", .flag,
                                      help: "Recommended above degree 10, where the monomial basis becomes ill-conditioned"),
                ]),
            ],
            values: [
                RunKey.degree: .int(degree),
                RunKey.legendre: .flag(legendre),
            ]
        )
    }

    /// Run ▸ Run Spectral Method (infinite buffers) — bnet.
    static func spectralInfinite(degree: Int) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Spectral Method",
            subtitle: "Polynomial Galerkin solution of the SRBM in the orthant (BNAsm). Higher degrees are more accurate and cost more memory.",
            helpTopic: .spectralInfinite,
            systemImage: DS.Symbol.formula,
            size: .compact,
            sections: [
                RunParameterSection("Basis",
                                    footer: "Degree 8–12 is enough for most networks; raise it if the reported residual is large.",
                                    fields: [
                    RunParameterField(RunKey.degree, "Polynomial degree", .integer(range: 2...40),
                                      help: "Order of the polynomial basis (2–40). Cost grows quickly with degree and with the number of stations",
                                      glossary: DS.Glossary.polynomialDegree),
                ]),
            ],
            values: [RunKey.degree: .int(degree)]
        )
    }

    // MARK: Finite element

    /// Run ▸ Run Finite Element — bna_fm_gauss / bna_fm_cbc.
    static func finiteElement(quadrature: Int, mesh: Int, meshCap: Int, stations: Int) -> RunParameterSpec {
        let capNote = stations >= 4
            ? "The mesh is capped at \(meshCap) for d = \(stations): the finite-element cost grows as n^2d, so larger meshes run much longer."
            : "Cost grows as n^2d in the mesh size n and the number of stations d."
        return RunParameterSpec(
            title: "Run Finite Element",
            subtitle: "Hermite finite-element solution of the SRBM density on a hypercube (fBNAfm).",
            helpTopic: .finiteElement,
            systemImage: DS.Symbol.grid,
            size: .compact,
            sections: [
                RunParameterSection("Discretisation", footer: capNote, fields: [
                    RunParameterField(RunKey.quadrature, "Quadrature", .choice([
                        "Gauss–Legendre (recommended)",
                        "Component-by-component quasi-Monte Carlo",
                    ]), help: "How the element integrals are evaluated"),
                    RunParameterField(RunKey.mesh, "Mesh size per dimension", .integer(range: 2...40),
                                      help: "Number of elements along each axis (2–40)",
                                      glossary: DS.Glossary.meshSize,
                                      unit: "cells"),
                ]),
            ],
            values: [
                RunKey.quadrature: .int(quadrature),
                RunKey.mesh: .int(mesh),
            ]
        )
    }

    // MARK: Multi-class SRBM (experimental)

    static func multiClassSRBM() -> RunParameterSpec {
        RunParameterSpec(
            // Title matches the Run-menu item word for word (the menu item
            // no longer repeats "(Experimental)" — it already sits in a
            // Section with that name).
            title: "Run Multi-Class SRBM",
            subtitle: "Class-aware workload diffusion: per-class traffic, compound service moments and routing covariance on infinite-buffer networks.",
            helpTopic: .multiClassSRBM,
            systemImage: DS.Symbol.experiment,
            tint: DS.Color.warning,
            size: .compact,
            sections: [
                RunParameterSection("Formulation",
                                    footer: "Leave the mesh at 0 to let the solver pick a dimension-aware value.",
                                    fields: [
                    RunParameterField(RunKey.formulation, "Formulation", .choice([
                        "Research (compound service + routing variance)",
                        "Legacy (matches production SRBM export)",
                    ]), help: "Which set of drift and covariance formulas the solver uses"),
                    RunParameterField(RunKey.mesh, "Mesh size per dimension",
                                      .integer(range: 0...40, emptyFor: 0),
                                      help: "Elements along each axis; leave blank for the automatic, dimension-aware cap",
                                      glossary: DS.Glossary.meshSize,
                                      unit: "cells"),
                ]),
            ],
            values: [
                RunKey.formulation: .int(0),
                RunKey.mesh: .int(0),
            ]
        )
    }

    // MARK: Linear program

    /// Run ▸ Run Linear Program, shown when Settings ▸ Linear Program asks
    /// to confirm the parameters before each run.
    static func linearProgram(gridN: Int, basisM: Int, solver: Int, gridType: Int,
                              smoothness: Double, normalise: Bool, multiLevel: Bool,
                              dimension: Int) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Linear Program",
            subtitle: "LP relaxation of the SRBM stationary distribution (BNAlp, Saure–Glynn–Zeevi 2008) for d = \(dimension).",
            helpTopic: .linearProgramInfinite,
            systemImage: DS.Symbol.increasing,
            size: .tall,
            sections: [
                RunParameterSection("Discretisation",
                                    footer: "Leave grid size and basis size blank for values auto-scaled to the number of stations.",
                                    fields: [
                    RunParameterField(RunKey.gridN, "Grid size n",
                                      .integer(range: 0...100_000, emptyFor: 0),
                                      help: "Constraint points per dimension; blank = auto",
                                      glossary: DS.Glossary.gridN),
                    RunParameterField(RunKey.basisM, "Basis size m",
                                      .integer(range: 0...100_000, emptyFor: 0),
                                      help: "Number of monomial basis functions; blank = auto",
                                      glossary: DS.Glossary.basisM),
                    RunParameterField(RunKey.gridType, "Grid type", .choice([
                        "Exponential", "Dyadic", "Exponential (random)",
                    ]), help: "How constraint points are spaced along each axis"),
                ]),
                RunParameterSection("Solver", fields: [
                    RunParameterField(RunKey.solver, "LP backend", .choice([
                        "Auto", "CPLEX", "GLPK", "HiGHS",
                    ]), help: "Which linear-programming backend solves the relaxation"),
                    RunParameterField(RunKey.smoothness, "Smoothness weight",
                                      .decimal(range: 0...100_000, step: 0.1),
                                      help: "Penalty on the curvature of the fitted density; 0 disables it",
                                      glossary: DS.Glossary.smoothness),
                    RunParameterField(RunKey.normalise, "Normalise monomial basis", .flag,
                                      help: "Greatly improves conditioning for d ≥ 3"),
                    RunParameterField(RunKey.multiLevel, "Multi-level refinement", .flag,
                                      help: "Run a coarse preview first, then refine on the full grid"),
                ]),
            ],
            values: [
                RunKey.gridN: .int(gridN),
                RunKey.basisM: .int(basisM),
                RunKey.gridType: .int(gridType),
                RunKey.solver: .int(solver),
                RunKey.smoothness: .double(smoothness),
                RunKey.normalise: .flag(normalise),
                RunKey.multiLevel: .flag(multiLevel),
            ]
        )
    }

    // MARK: Comparison

    /// Run ▸ Run Comparison, finite buffers: which blocking regime the
    /// simulation column should use.
    static func comparisonBlocking(blocking: Int) -> RunParameterSpec {
        RunParameterSpec(
            title: "Run Comparison",
            subtitle: "Spectral, finite-element and finite-LP all solve the SRBM under manufacturing blocking. Pick the regime the simulation column should use.",
            helpTopic: .srbmHypercube,
            systemImage: DS.Symbol.paneSplit,
            confirmHelp: "Run every method and tabulate the results (Return)",
            size: .compact,
            sections: [
                RunParameterSection("Simulation",
                                    footer: "BAS + external loss matches the SRBM convention, so all four methods solve the same problem.",
                                    fields: [
                    RunParameterField(RunKey.blocking, "Blocking regime", .choice(blockingRegimes),
                                      help: "Finite-buffer convention used by the simulation column",
                                      glossary: DS.Glossary.bas),
                    RunParameterField(RunKey.remember, "Skip this dialog from now on", .flag,
                                      help: "Remember this choice and use it for every comparison; change it again in Settings ▸ General"),
                ]),
            ],
            values: [
                RunKey.blocking: .int(blocking),
                RunKey.remember: .flag(false),
            ]
        )
    }

    // MARK: Export

    /// File ▸ Export ▸ All Solver Inputs to Folder…, finite buffers only:
    /// which blocking convention the exported SRBM files encode.
    static func exportBlockingConvention(convention: Int, conventions: [String]) -> RunParameterSpec {
        RunParameterSpec(
            title: "Export All Solver Inputs",
            subtitle: "Writes every solver's input file into one folder — the same files Qnet --export-cmp produces.",
            helpTopic: .solverInputs,
            systemImage: DS.Symbol.newFolder,
            confirmTitle: "Choose Folder…",
            confirmHelp: "Pick the destination folder and write the files (Return)",
            cancelHelp: "Close without exporting (Esc)",
            size: .compact,
            sections: [
                RunParameterSection("Finite Buffers",
                                    footer: "Only sm.in, fm.in and lp.in depend on this choice; the QNA and simulator inputs are unaffected.",
                                    fields: [
                    RunParameterField(RunKey.convention, "Blocking convention", .choice(conventions),
                                      help: "How finite buffers block upstream stations in sm.in, fm.in and lp.in",
                                      glossary: DS.Glossary.bas),
                ]),
            ],
            values: [RunKey.convention: .int(convention)]
        )
    }
}
