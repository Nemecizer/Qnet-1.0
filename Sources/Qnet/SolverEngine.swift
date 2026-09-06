import Foundation

/// Which implementation of a method runs.
///
/// Three methods ship two engines: a C one and the original Python one. They
/// are not two algorithms — each C engine was written to reproduce its Python
/// counterpart's arithmetic step for step, and every one has a parity test that
/// runs both on the packaged examples and compares the output. The choice is
/// therefore a choice of *wait*, not of answer, and the Settings pane says so.
///
/// Python remains the reference implementation: it is the readable statement of
/// the algorithm, it needs no compiler, and it is what to reach for when a
/// result looks wrong.
enum SolverEngine: Int, CaseIterable, Identifiable, Sendable {
    case c = 0
    case python = 1

    var id: Int { rawValue }

    /// Menu label. Deliberately not "fast"/"slow": both are correct, and the
    /// speed claim belongs beside the measurement in the pane's footnote.
    var title: String {
        switch self {
        case .c:      return "C"
        case .python: return "Python"
        }
    }

    /// Used in Status-pane lines and result provenance, where "the C engine"
    /// reads better than a bare "C".
    var descriptiveName: String {
        switch self {
        case .c:      return "C engine"
        case .python: return "Python engine"
        }
    }

    var other: SolverEngine { self == .c ? .python : .c }

    init(storedValue: Int) {
        self = SolverEngine(rawValue: storedValue) ?? .c
    }
}

/// A method that ships both engines, and where each one lives.
///
/// The names here are the single place the two file names for one method are
/// written down. `StartupDependencyChecker` and the Settings pane read them, so
/// a renamed binary breaks in one place rather than three.
enum DualEngineMethod: String, CaseIterable, Identifiable, Sendable {
    case regenerativeMonteCarlo
    case matrixAnalyticQBD
    /// The two CTMC solvers share one power-iteration kernel and one Settings
    /// row, so they share a `storageKey` while keeping their own binaries.
    case truncatedCTMC
    case finiteGenericCTMC

    var id: String { rawValue }

    /// As the Run menu names it.
    var displayName: String {
        switch self {
        case .regenerativeMonteCarlo: return "Regenerative Monte Carlo"
        case .matrixAnalyticQBD:      return "Exact Matrix-Analytic QBD"
        case .truncatedCTMC:          return "Adaptive Truncated CTMC"
        case .finiteGenericCTMC:      return "Exact Sparse CTMC"
        }
    }

    /// What the pane says the choice costs, in the one sentence a reader needs.
    var summary: String {
        switch self {
        case .regenerativeMonteCarlo:
            return "Discrete-event simulation over regenerative cycles."
        case .matrixAnalyticQBD:
            return "Matrix-geometric rate matrix by functional iteration."
        case .truncatedCTMC, .finiteGenericCTMC:
            return "The adaptive truncated CTMC and the finite generic CTMC, which share a power-iteration kernel."
        }
    }

    /// Measured speedup of the C engine over the Python one, and the case it
    /// was measured on. Shown in the pane so the choice is made against a
    /// number rather than a promise.
    ///
    /// The three differ by more than an order of magnitude, and the reason is
    /// worth knowing: what a C engine gains depends on whether its hot loop can
    /// use plain arithmetic. The regenerative simulator's inner loop is event
    /// bookkeeping and ordinary accumulation, so the C engine keeps the whole
    /// interpreter gap. The QBD's inner loop is a matrix multiply the Python
    /// performs with `math.fsum` — exact summation — and reproducing that
    /// arithmetic exactly, which is what makes the two engines agree to the
    /// last bit, costs about 23× against naive accumulation. That is a
    /// deliberate trade: roughly 16× with a guarantee, rather than 200× with a
    /// caveat. See `common/bnet_fsum.h`.
    var measuredSpeedup: String {
        switch self {
        case .regenerativeMonteCarlo:
            return "252× measured (200,000 cycles on a two-node two-class network: 10.10 s → 0.04 s)"
        case .matrixAnalyticQBD:
            return "16× measured (48 interior phases: 38.9 s → 2.4 s)"
        case .truncatedCTMC, .finiteGenericCTMC:
            // Two solvers, one row, and their gains differ for the reason
            // above: the truncated CTMC normalises each iterate with an exact
            // sum and the finite one does not.
            return "21× to 78× measured (truncated CTMC, 12,341 states: 9.09 s → 0.43 s; "
                 + "finite CTMC, 60,929 states: 9.31 s → 0.12 s)"
        }
    }

    /// Native executable name and its solver directory.
    var nativeExecutable: (name: String, subdirectory: String, groups: [String]) {
        switch self {
        case .regenerativeMonteCarlo: return ("bna_rmc", "BNArmc", ["infinite"])
        case .matrixAnalyticQBD:      return ("bna_qbd", "BNAqbd", ["infinite"])
        case .truncatedCTMC:          return ("bna_tc", "BNAtc", ["infinite"])
        case .finiteGenericCTMC:      return ("fbna_gc", "fBNAgc", ["finite"])
        }
    }

    /// The `@AppStorage` key holding this method's engine choice. Part of the
    /// on-disk contract; never rename.
    var storageKey: String {
        switch self {
        case .regenerativeMonteCarlo: return "engine.regenerative"
        case .matrixAnalyticQBD:      return "engine.qbd"
        case .truncatedCTMC, .finiteGenericCTMC: return "engine.ctmc"
        }
    }
}

/// How a run should be launched once the engine is settled.
///
/// `fellBack` is the field that matters: a chosen engine that could not be
/// resolved must produce a working run under the other one plus a visible
/// explanation, never a method that has quietly stopped working. Callers are
/// expected to surface `note` in the Status pane whenever it is non-nil.
struct ResolvedEngine {
    /// The engine that will actually run, which may not be the one requested.
    let engine: SolverEngine
    /// The command prefix: the executable for C, `<python> -B <script>` for Python.
    let launchPrefix: String
    /// For the result record's provenance line.
    let provenance: String
    /// Non-nil when the requested engine was unavailable and the other was used.
    let note: String?
    var fellBack: Bool { note != nil }
}

/// Why no engine could be launched. A `String` is not an `Error`, and this
/// carries the one thing the caller needs: a sentence naming both attempts.
struct SolverEngineUnavailable: Error {
    let diagnostic: String
}
