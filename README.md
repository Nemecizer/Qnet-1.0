# Qnet

**A macOS application for building queueing networks on a canvas and solving their steady state
with a suite of independent numerical methods — then comparing what those methods disagree about.**

Seventeen solvers are one click away in the Run menu; more are available from the command line.

Version 0.90.34 · Apple silicon · macOS 26 or later · MIT licensed

Qnet is a research tool for open and closed queueing networks. You draw the network — sources,
buffers, stations, sinks, routing arcs, customer classes — and Qnet exports it to whichever solver
you choose, runs that solver in an embedded terminal, and parses its output back into a comparable
result. The methods span exact Markov-chain solutions, two-moment approximations, discrete-event
simulation, and semimartingale reflecting Brownian motion (SRBM) numerics.

The distinguishing idea is that **Qnet never lets a number pretend to be more than it is.** An exact
product-form mean, a heavy-traffic diffusion approximation, and a simulation estimate with a
confidence interval are three different kinds of claim, and the interface says which is which,
every time.

---

## Contents

- [What Qnet does](#what-qnet-does)
- [Getting started](#getting-started)
- [The interface](#the-interface)
- [Methods](#methods)
- [How results are labelled](#how-results-are-labelled)
- [Building from source](#building-from-source)
- [Repository layout](#repository-layout)
- [Validation](#validation)
- [GUIKit](#guikit)
- [Documentation](#documentation)
- [Limitations](#limitations)
- [License](#license)

---

## What Qnet does

- **Model.** Draw a network of sources, buffers, multi-server stations and sinks, with probabilistic
  routing, multiple customer classes, feedback and re-entrant flows, and either infinite or finite
  buffers. Service and interarrival times can be exponential, Erlang, gamma, Weibull, lognormal,
  Pareto, uniform, or deterministic — entered either by native parameters or by mean and squared
  coefficient of variation.
- **Analyse.** Run any applicable method from the Run menu. Qnet decides applicability from two
  independent questions it reports separately: *is this network inside the method's mathematical
  domain* (`AnalyticalTractability`), and *is the solver binary or interpreter actually present*
  (`StartupDependencyChecker`).
- **Compare.** `Run ▸ Run Comparison` executes several methods on one network and prints a single
  aligned table — every method a column, every metric a row, with an exact analytical column
  appended when the network happens to be tractable in closed form. This is the feature the rest of
  the application exists to serve.
- **Interrogate.** Results carry their provenance: which binary ran, from which path, with which
  parameters, and what residual, interval or diagnostic the method reported about itself.

---

## Getting started

### Get a running application

The repository holds source only — `Qnet.app` is a build product and is not committed. Build it:

```sh
./build_app.sh     # → a fully standalone Qnet.app beside Package.swift
```

or build a double-clickable installer with `./make_pkg.sh`, or a checksummed archive with
`./make_release.sh`.

Because a locally built app is ad-hoc signed rather than notarized, macOS warns on first launch:
Control-click `Qnet.app` → **Open**, and confirm once. Subsequent launches are silent.

Keep the built app beside `Package.swift`: a source-launched GUI (`swift run`) resolves its solver
binaries from it.

### Draw your first network in four clicks

`File ▸ New from Archetype…` opens the archetype gallery. Choose one, set its knobs, insert:

| Archetype | Shape |
|---|---|
| **M/M/c Station** | `Src1 → B1 → S1 → Sink1`, with *c* parallel servers |
| **Tandem Line** | `Src1 → B1 → S1 → … → Sd → Sink1`, every station at the same ρ |
| **Fork and Merge** | `S1` splits its output evenly into `S2` and `S3`, both to `Sink1` |
| **Line with Rework** | every station returns a fraction *p* of its output to its own buffer |
| **Re-entrant Pair** | `S1 → S2`, and `S2` sends a fraction *p* back to `B1` — a two-station cycle |

Every archetype arrives **stable by construction** (ρ < 1, not the ρ = 1.000 you get from naive
defaults), correctly named, laid out, and inserted as a **single undo step**. From an empty canvas
to a network `Run ▸ Whitt QNA` will solve is four clicks and no typed numbers.

Alternatively, `File ▸ Open Example…` lists **50 bundled networks**, several named for the papers
they come from — `DaiHarrison91`, `Bramson94`, `BanksDai96`, `Reiman84`, `Schwerer01`,
`Whitt83Style` — plus tandem chains, re-entrant lines and multiclass finite-buffer models.

---

## The interface

### Canvas

Tool hotkeys follow the Figma / OmniGraffle convention: **V** pointer, **M** marquee, **H** pan,
**S** station, **B** buffer, **O** source, **X** sink, **L** link.

- **Sticky pan** — double-click empty canvas to enter the hand; a single click returns to the
  previous tool.
- **Drag to connect** — drag from one node to another to create a link, with an elastic preview.
- **Smart alignment guides** — edge, centre and equal-spacing matches against every other node,
  arbitrated per axis against Snap to Grid, suspended live while ⌃ is held.
- **Marquee selection** on the intersection rule, with a live candidate highlight that reads the
  same predicate the commit does.
- **⌥-drag** duplicates and moves in one undo step.
- **Arrow-key nudge**, coalesced so a held key is one undo entry, stepping a whole grid cell while
  snapping is on.
- **Arrange** — eight align and distribute commands in the menu bar.
- **Self-loops and feedback arcs** are first-class; a link *out of* a sink is refused with a reason
  rather than silently dropped.
- Full keyboard navigation (Tab walks nodes, ⌥Tab walks a node's links) and VoiceOver labels on
  every node and link.

### Panes and windows

Six panes — Tools, Canvas, Inspector, Shell, Status, Results — each of which can **fill the window**
(solo/maximize) or **tear out into its own window** and re-dock, the way MATLAB detaches panels.
Every window remembers where you left it, and a frame saved on a display you have since unplugged is
clamped back onto a screen that exists.

Dialogs that you may want to check against the canvas behind them — export options, run parameters,
the node and link parameter editors — are **real movable, resizable windows**, not pinned sheets.

### Interactive shell

The embedded terminal is the centrepiece, not a footer. Solver runs happen there, visibly:
progress bars, elapsed time, and a Stop that signals the solver's process *group* and escalates
SIGINT → SIGTERM → SIGKILL. `⌘F` opens the terminal's find bar, `⌘G` steps it, `⌘C` copies the
terminal selection. Wide comparison tables do not wrap. A run you stop is reported as *cancelled* —
not as a failure.

### Consistent numeric output

`Settings ▸ Output Format ▸ Decimal places` governs **every decimal number from every
method**, whether the solver is C or Python and whatever precision it printed natively.
Normalization happens at the terminal boundary, so one setting reaches all of them; integers,
station indices, seeds, exit codes, scientific notation and table alignment are preserved.

---

## Methods

Seventeen solver actions in the Run menu, plus three analytical branches computed in-app and several
CLI-only solvers. Grouped below by **model layer** — what mathematical object the number actually
describes. `docs/STEADY_STATE_METHODS.md` gives the full contract for each: supported network class,
inputs and outputs, the error or uncertainty evidence it reports, and its limitations.

### Exact queue-process methods

Exact for the stated assumptions, up to floating point or an iterative tolerance.

| Method | Scope |
|---|---|
| Jackson product form | Open single-class M/M/s Jackson networks, state-independent routing |
| **Run Exact Open Product Form** | BCMP product form: open, closed and mixed class-preserving networks; FCFS, PS, IS, LCFS-PR |
| **Run Exact Sparse CTMC** | Open finite-capacity multiclass Markovian networks, loss on full |
| **Run Exact Matrix-Analytic QBD** | Level-independent skip-free QBD with matrix-geometric tail |
| Tandem CTMC | Very small single-class M/M/1 tandems, loss on full (dense; 1,000-state cap) |
| Kaufman–Roberts | Single multi-rate loss resource (CLI only) |

### Queue approximations

Still about the discrete queue, but closing or truncating part of the model.

| Method | Scope |
|---|---|
| **Run Whitt QNA** | Two-moment decomposition; exact in the Jackson special case |
| **Run Whitt–You RQNA** | Refined QNA with multi-timescale IDC propagation, per-class when present |
| **Run SBD** | Sequential bottleneck decomposition built from RBM/SRBM subproblems |
| **Run Finite-Buffer Decomposition** | Open multiclass M/M/c/K fixed point, loss and BAS variants |
| **Run Adaptive Truncated CTMC** | Finite reflection of an infinite chain, with refinement history |

### Queue simulation

Samples the discrete process. Confidence intervals describe **sampling error only** — not warm-up
bias, and not a mismatch between the modelled and the real blocking rule.

| Method | Scope |
|---|---|
| **Run Monte Carlo** (infinite) | Open infinite-capacity multiclass DES, general distributions |
| **Run Monte Carlo** (finite) | Finite-capacity multiclass DES with Loss, BAS, or BAS + external loss |
| **Run Regenerative Monte Carlo** | Empty-to-empty regeneration cycles with ratio-estimator intervals |

### SRBM and diffusion methods

These first replace the queue with a semimartingale reflecting Brownian motion, usually under heavy
traffic. **Solving that SRBM accurately is not solving the queue**, and two SRBM solvers agreeing is
a numerical cross-check, not validation of the approximation.

| Method | Scope |
|---|---|
| Harrison–Williams product form | Exact for an orthant SRBM satisfying the checked skew-symmetry identity |
| GCDG multi-scaling | Asymptotic; labelled `Asymptotic E[X]`, never `Exact` |
| **Run Spectral Method** | Orthant (and bounded hypercube) spectral/Galerkin |
| **Run Finite Element** | Bounded hypercube FEM, Gaussian-quadrature and CBC-QMC assembly |
| **Run Linear Program** | Orthant BAR linear-programming relaxation (HiGHS / GLPK / CPLEX) |
| **Run SRBM MLMC** | Multilevel Monte Carlo on the SRBM, with SE-targeted adaptive sampling |
| **Run BAR Moment Bounds** | Conic outer relaxation; certified only in documented special cases |
| **Run Adaptive Low-Rank BAR** | Nonnegative mixture of separable exponentials with BAR residuals |
| **Run Finite-Buffer LP** | Bounded-rectangle LP — **an incomplete scaffold**; see [Limitations](#limitations) |
| **Run Multi-Class SRBM** | *Experimental*; requires the optional cJSON runtime |

---

## How results are labelled

This vocabulary is fixed, and status messages, help text and result records respect it. It is the
most important thing to understand about Qnet's output.

- **Queue process** — the original discrete-customer stochastic network. An exact queue-process
  result is exact *only* for the stated arrival, service, discipline, routing, capacity and
  stability assumptions.
- **Queue approximation** — still targets discrete queues, but closes or truncates part of the
  model. Its residual may show its own equations were solved; it does not bound queue-model error.
- **Queue simulation** — samples the discrete process. A confidence interval describes sampling
  error, not warm-up bias or a blocking-semantics mismatch.
- **SRBM / diffusion** — replaces the queue by a Brownian model. Accuracy about the SRBM is not
  accuracy about the queue.
- **Certified** — reserved for a theorem-backed statement whose stated assumptions were checked. A
  solver residual, mesh comparison, truncation boundary mass, effective sample size or held-out BAR
  residual is **evidence**, not a certificate, unless the implementation says otherwise explicitly.

---

## Building from source

### Requirements

- Apple silicon Mac, macOS 26 or later
- Xcode Command Line Tools, Swift 6.2+
- Python 3 and `make`
- `brew install python libomp suite-sparse highs gcc@13`
- Optional: `brew install cjson` (enables the experimental multiclass diffusion solver)
- Optional: NumPy (dense finite tandem CTMC); CVXPY + an SDP backend (numerical BAR bounds)

`Vendor/SwiftTerm` is vendored, so a clean build needs no network access.

### Build and run

```sh
swift run                    # build and launch the GUI from source
./run_qnet.sh                # same, but selects a working SDK and local caches
swift run Qnet --version     # → "Qnet 0.90.34", no GUI

./build_all_algorithms.sh    # every native solver; syntax-check every Python solver
./build_app.sh               # → a fully standalone Qnet.app
./make_pkg.sh                # → a double-clickable .pkg installer for /Applications
./make_release.sh            # → a checksummed .zip for drag-and-drop installs
./verify_source_package.sh   # the full gate: both build paths, signature, examples
```

`make_pkg.sh` produces `dist/Qnet-<version>-arm64.pkg`: double-click it, click through, and Qnet is
in Applications and Launchpad. The installer enforces the minimum macOS and architecture computed
from the bundled binaries, so it refuses a machine that could not run the app rather than installing
one that fails to launch. Both packaging scripts refuse to package an app that still links against
Homebrew.

`build_app.sh` produces a genuinely standalone bundle: all fifteen required libraries — `libomp`,
SuiteSparse, HiGHS, cJSON, and the GCC runtime — are copied into `Contents/Frameworks` with their
load paths rewritten, so the app does not need Homebrew at runtime. `make_release.sh` *proves* that
by walking every Mach-O file in the bundle for external links, then packages with `ditto` and
re-verifies the signature after a round trip through the archive.

### Headless use

The app binary doubles as a CLI, which is how the validation suite drives it:

```sh
swift run Qnet --dump-help rqna          # method documentation
swift run Qnet --dump-rho model.bnet     # traffic equations and tractability
swift run Qnet --export-cmp model.bnet   # export for the comparison path
swift run Qnet --ds-gallery              # render every design token
```

Also `--gen-random`, `--export-finite-markov`, `--export-truncated-ctmc`, `--export-srbm-json`,
`--export-regenerative`, `--export-product-form`, `--export-qbd`.

---

## Repository layout

```
Sources/Qnet/          the SwiftUI application (92 files)
infinite/              infinite-buffer solvers  (BNAqna, BNArqna, BNAsbd, BNAsim, BNAsm,
                       BNAfm, BNAlp, BNAmc, product_form, matrix_analytic, truncated_ctmc,
                       regenerative_mc, bar_bounds, adaptive_srbm, multiclass_diffusion)
finite/                finite-buffer counterparts, prefixed fBNA*, plus generic_ctmc,
                       fBNAdecomp and fBNActmc
common/                shared C headers (bnet_memcheck.h RAM pre-flight, rng.h)
input/examples/        50 example networks
GUIKit/                the GUI framework, extracted and reusable — see GUIKit/GUI.md
validation/            the regression suite and the design-system lint
docs/                  method catalogue, algorithm survey, GUI work log
Vendor/SwiftTerm/      vendored terminal emulator
ThirdPartyLicenses/    license texts for every bundled native library
Papers/                literature index and bibliography (PDFs not redistributed)
```

Each `finite/*` and `infinite/*` directory owns its Makefile:

```sh
make -C infinite/BNAqna                # build one native solver
make -C infinite/BNApf test     # Python unit tests for one method
make -C infinite/BNApf check    # tests plus its bundled examples
```

---

## Validation

```sh
validation/steady_state_suite.sh          # the regression suite
validation/design_lint.sh                 # design-system lint + WCAG contrast gate
validation/gui_runtime_contracts.sh       # source-text contracts on the solver-launch wrappers
./verify_source_package.sh                # everything, including a release build
```

Three distinct kinds of check live in `validation/`, and they fail for different reasons:

- **Headless Swift unit checks** compile one real file from `Sources/Qnet/` against stubs, so the
  logic under test is exercised without a GUI.
- **Source-text contracts** pin exact strings and counts in the solver-launch code — for example
  that exactly eight Python runners use the cancellation-safe wrapper, and that the completion file
  is written from an `EXIT` trap. Rewording a pinned line is then a deliberate act.
- **The release inventory** (`required_release_executables.txt`) is maintained *independently* of
  the packager's build list, so dropping a build target cannot silently remove a method from a
  release.

`build_app.sh` runs the design lint first and refuses to build on a violation.

---

## GUIKit

`GUIKit/` is Qnet's GUI layer extracted as a **reusable framework** for other macOS SwiftUI
applications: the design token system, ~25 components, movable panel windows, pane detachment,
window frame persistence, the accessibility contract, and the lint that enforces all of it. It
compiles standalone and its own lint passes on it — 40 checks including a computed WCAG contrast
gate. See **[GUIKit/GUI.md](GUIKit/GUI.md)**.

It carries none of Qnet's domain: no canvas, no solvers, no queueing theory.

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/STEADY_STATE_METHODS.md`](docs/STEADY_STATE_METHODS.md) | The full contract for every method: scope, inputs, evidence, limitations |
| [`docs/ALGORITHM_REVIEW.md`](docs/ALGORITHM_REVIEW.md) | Measured execution, scaling limits and improvement priorities for every solver |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | How the research playbook becomes shipped revisions |
| [`docs/ALGORITHM_RESEARCH_2026-09-04.md`](docs/ALGORITHM_RESEARCH_2026-09-04.md) | Survey of further methods — **proposed, not implemented** |
| [`BUILDING.md`](BUILDING.md) | Dependencies and the SDK workaround for the tested Mac |
| [`VERIFICATION.md`](VERIFICATION.md) | Exactly what was and was not tested, and on what host |
| [`GUIKit/GUI.md`](GUIKit/GUI.md) | The GUI framework guide |
| [`validation/algo_review/`](validation/algo_review/) | Per-solver code review, including known family-wide footguns |
| [`ARCHIVAL_SOURCES.md`](ARCHIVAL_SOURCES.md) | Two retained historical experiments that are not build targets |
| [`Papers/Qnet_Literature_Survey.md`](Papers/Qnet_Literature_Survey.md) | The literature behind the implemented and proposed methods |

---

## Limitations

Stated plainly, because a research tool that hides these is worse than one that lacks features.

- **Apple silicon only**, macOS 26 or later. No Intel build; no older-macOS compatibility
  established.
- **Ad-hoc signed, not notarized.** First launch on another Mac needs Control-click → Open.
- **`finite/fBNAlp` is an incomplete scaffold** — the menu item and binary exist, but its README
  documents the bounded-rectangle BAR work as unfinished. Do not present its output as a validated
  bounded-rectangle answer.
- Several methods are **CLI-only** (Kaufman–Roberts, closed and mixed BCMP, the growing-box orthant
  FEM), and the multiclass diffusion solver is **experimental** and needs an optional dependency.
- State-space methods grow combinatorially. Qnet enforces explicit budgets — a 200,000-state default
  guard, a 2 GiB spectral matrix ceiling, a two-million-variable LP refusal — and declines a run
  rather than thrashing.
- `docs/ALGORITHM_RESEARCH_2026-09-04.md` describes methods that are **not implemented**.

---

## License

Qnet's own source — the Swift GUI, the solvers under `finite/` and `infinite/`, the GUIKit
framework, the validation suite and the build scripts — is released under the MIT License. See
[LICENSE](LICENSE).

Third-party components keep their own terms. `Vendor/SwiftTerm` is MIT. A built `Qnet.app` also
redistributes the native libraries its solvers link against — libomp, HiGHS, cJSON, SuiteSparse and
the GCC 13 runtime libraries — each under its own license, with the texts retained in
`ThirdPartyLicenses/`. The GCC runtime libraries carry the GCC Runtime Library Exception, which is
what allows them to ship inside an MIT-licensed application. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full statement.

The published papers under `Papers/` are third-party copyrighted works, excluded from this
repository and not redistributed; `Papers/Qnet_Bibliography.ris` cites them so they can be obtained
from their publishers.
