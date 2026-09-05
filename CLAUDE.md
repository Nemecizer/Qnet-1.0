# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Qnet 0.90.34 — a macOS (Apple-silicon, SwiftUI) GUI for building queueing
networks on a canvas and analyzing their steady state with ~20 independent
numerical solvers written in C and Python. The Swift app is not a library
wrapper: it *exports* a network to a solver-specific input file, runs the
solver as a shell command in an embedded SwiftTerm terminal, and parses the
solver's stdout back into typed results.

The distribution is self-contained: `Vendor/SwiftTerm` is vendored (no network
needed for `swift run`), and a pre-built `Qnet.app` sits beside `Package.swift`.
Keep the app there — a source-launched GUI resolves its solvers from it.

## Commands

```sh
swift run                       # build + launch the GUI from source
./run_qnet.sh                   # same, but auto-selects a working SDK + local caches
swift run Qnet --version        # -> "Qnet 0.90.34", no GUI

./build_all_algorithms.sh       # make every native solver; syntax-check every Python solver
./build_app.sh                  # design lint -> native builds -> release Swift -> assemble,
                                #   relocate dylibs, ad-hoc sign, audit Qnet.app
./verify_source_package.sh      # full gate: both build paths + signature + bundle audit +
                                #   RQNA self-test + all 35 packaged RQNA examples

validation/steady_state_suite.sh   # the regression suite (Python unit tests + all contracts)
validation/design_lint.sh          # DS token lint; build_app.sh runs it first and aborts on failure
```

Per-solver builds and tests (each `finite/*` and `infinite/*` directory owns its
Makefile):

```sh
make -C infinite/BNAqna                 # one native solver
make -C infinite/BNApf test      # Python unit tests for one method
make -C infinite/BNApf check     # tests + run its examples/*.json
make -C infinite/BNApf open-example
```

A single Python test: `cd infinite/BNApf && python3 -m unittest tests.test_bcmp.TestX.test_y -v`.

Headless CLI entry points on the app binary, used by the validation scripts and
useful for driving a network without the GUI: `--dump-help <method>`,
`--dump-rho`, `--gen-random`, `--export-cmp`, `--export-finite-markov`,
`--export-truncated-ctmc`, `--export-srbm-json`, `--export-regenerative`,
`--export-product-form`, `--export-qbd`, `--ds-gallery`.

### Toolchain caveat on this Mac

A bare `swift run` can fail with a compiler/SDK mismatch diagnostic. Every build
script (and `run_qnet.sh`) probes for that and falls back to
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk` plus
project-local module caches under `.build/module-cache`. Inside a managed runner
that rejects SwiftPM's nested sandbox, set `QNET_SWIFT_DISABLE_SANDBOX=1` (opt-in;
never on by default). See `VERIFICATION.md`.

## Architecture

### Solver-launch pipeline

Every "Run ▸ …" action in `Sources/Qnet/QnetGUIApp.swift` follows the same shape,
and a new method must follow it too:

1. `SolverRuntimeResolver.shared.resolveExecutable(name:subdirectory:)` (native)
   or `.resolvePythonSupportFile(...)` (Python). Search order is
   **bundled app Resources → `QNET_SOLVER_ROOT` → a nearby `Qnet.app` → the
   development source tree**; each attempt is recorded with a provenance string
   that ends up in the result record and in `lookup.actionableDiagnostic` (shown
   verbatim in the "not found" alert). A packaged copy always beats a loose
   binary in the source tree.
2. A per-method exporter (`SRBMExporter`, `BNASRBMExporter`, `QNAExporter`,
   `QBDExporter`, `ProductFormExporter`, `RegenerativeExporter`,
   `FiniteMarkovExporter`, `NetworkExporter`, `BNANetworkExporter`) turns the
   canvas `nodes`/`links` into that solver's input text.
3. The input is written to a PID-stamped temp file, and a shell command string is
   assembled (progress bar, stderr-on-failure wrapper, output formatter) and run
   through the embedded terminal (`TerminalModel` / `TerminalConsoleView`).
4. `ResultOutputParser` reads the captured stdout by **semantic row name**
   (`rho_i`, `Gamma_i`, `sojourn_i`, `E[X_i]`, `L_i`, …) — never by column
   position — into `ResultsWorkspace` measurements. Failures/skips are reported
   with the `QNET_METHOD_FAILURE_V1 method=… exit=…` sentinel so an empty output
   is never mistaken for success.

Method availability shown in the UI comes from `MethodChooserView` +
`AnalyticalTractability` (is this network in the method's domain?) and
`StartupDependencyChecker` (is the binary/interpreter/module actually present?).
Those are separate questions and are reported separately.

### Solver tree

- `infinite/` — infinite-buffer methods. `BNAqna` (QNA), `BNArqna` (refined QNA),
  `BNAsbd` (sequential bottleneck decomposition), `BNAsim` (discrete-event sim),
  `BNAsm` (spectral/Galerkin), `BNAfm`, `BNAlp` (LP relaxation), `BNAmc` (MLMC),
  plus Python methods `product_form`, `matrix_analytic`, `truncated_ctmc`,
  `regenerative_mc`, `bar_bounds`, `adaptive_srbm`, and the optional
  `multiclass_diffusion` (needs cJSON).
- `finite/` — finite-buffer counterparts, prefixed `fBNA*`, plus `generic_ctmc`
  and `fBNAdecomp` (Python) and `fBNActmc` (dense tandem CTMC, needs NumPy).
- `common/` — shared C headers (`bnet_memcheck.h` RAM pre-flight, `rng.h`).

`validation/algo_review/*.md` is a per-solver code review with the known
family-wide footguns (uniform `exit(0)` on user errors, differing
reflection-matrix layout conventions between fBNAsm/fBNAfm/fBNAlp, stack-allocated
`MAX_NODES²` matrices in BNAqna/BNAsbd, missing `bnet_memcheck` in seven solvers).
Read the relevant file before touching a solver.

`infinite/BNAsim/gjn.c` and `mcn.c` are archival Meschach-era experiments, are not
Makefile targets, and must not be revived — see `ARCHIVAL_SOURCES.md`.

### Design system — hard gate

`Sources/Qnet/DesignSystem.swift` is the **only** token namespace and the only
file allowed to define one. Views compose `DS.*` tokens and `DS*` components;
they never write font point sizes, `Color.x.opacity(…)`, `.foregroundStyle(.secondary)`,
raw signal colours, materials, hand-built animations, or stroke/radius/frame
literals, and never re-implement a DS component or write `extension DS…` in
another file. Accessibility (Reduce Motion / Increase Contrast / Differentiate
Without Color) is read through `@DSAccessibility private var a11y`, not static flags.
The full rule list is the header comment of `validation/design_lint.sh`; the
adoption guide is the header of `DesignSystem.swift`; `Qnet --ds-gallery` renders
every token for eyeballing. `build_app.sh` runs the lint first and refuses to build
on a violation.

### Validation conventions

Three distinct kinds of check live in `validation/`, and they fail for different reasons:

- **Headless Swift unit checks** (`result_output_parser/`, `qbd_exporter/`,
  `product_form_exporter/`, `rqna_exporter/`, `solver_runtime_resolver/`,
  `source_distribution/`, `startup_dependency_check/`) compile `stubs.swift` +
  *one* real file from `Sources/Qnet/` + `main.swift` with `swiftc`. Adding a new
  dependency to the file under test breaks its check until the stub grows to match.
- **Source-text contracts** (`gui_runtime_contracts.sh`) `grep` for exact strings
  and counts in `QnetGUIApp.swift` / `SRBMExporter.swift` / `ctmc_dtandem.py` —
  e.g. "exactly 8 Python runners use `commandWithCleanup`", the EXIT/INT/TERM trap
  pattern, the 1,000-state cap on the dense tandem CTMC. Rewording those lines is
  a deliberate act: update the contract in the same change.
- **Release inventory** (`required_release_executables.txt`) is intentionally
  maintained *independently* of `build_app.sh`'s build list, so dropping a target
  from the packager cannot silently remove a GUI method from a release.

### Versioning

`Sources/Qnet/AppVersion.swift` pins `0.90.34`; rebuilding does **not** bump the
patch number, and `verify_source_package.sh` asserts the version in three places.
`Changelog.swift` keeps the newest entry at the top with `timestamp: nil` to mark
the in-development entry; freeze it with a real timestamp when shipping and add a
new `nil` entry above.

## Result-claim vocabulary

`docs/STEADY_STATE_METHODS.md` fixes the terminology this project uses, and status
messages, help text, and commit descriptions are expected to respect it: an
*exact queue-process* result, a *queue approximation*, a *queue simulation*
(confidence interval = sampling error only, not warm-up bias), and an
*SRBM/diffusion* result (solving the Brownian model accurately is not solving the
queue; two SRBM solvers agreeing is a numerical cross-check, not validation).
"Certified" is reserved for theorem-backed statements whose assumptions were
checked — a residual, mesh comparison, or effective sample size is evidence, not a
certificate.

`docs/ALGORITHM_RESEARCH_2026-09-04.md` surveys methods that are **proposed, not
implemented**; don't describe anything there as available.

## Prerequisites for a rebuild

`brew install python libomp suite-sparse highs gcc@13` (plus optional `cjson` for
the multiclass diffusion solver). NumPy is optional and only enables the dense
finite tandem CTMC; CVXPY + an SDP backend are optional and only enable numerical
BAR bounds. The shipped app's native solvers do not need Homebrew at runtime —
`build_app.sh` copies and rewrites their dylib load paths into `Contents/Frameworks`.
