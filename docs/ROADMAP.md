# Qnet implementation roadmap

**From `Plans.md` (32 algorithm projects A01–A32, six hybrids H1–H6) to shipped revisions.**

`Plans.md` is a research playbook: it specifies *what* each project must do, its sources, its
oracles and its acceptance tests, and it deliberately stops short of sequencing them into releases.
This document does the sequencing. It answers three questions `Plans.md` leaves open:

1. Which projects extend code that **already exists**, and which are new ground?
2. What can be delivered in **one revision** without destabilising a shipped application?
3. What must happen **before any algorithm work starts at all**?

Version in progress: **0.90.34 → 0.91.0**.

---

## 1. The single most important fact

**Nothing in A01–A32 can start until F00 exists.** Thirty of the thirty-two project cards list
`F00` as a dependency. F00 is the shared model schema, the versioned result envelope, the metric
vocabulary and the independent BAR residual evaluator (`Plans.md` §2).

If algorithm work begins before F00 is frozen, every project invents its own JSON shape and its own
notion of what "mean queue length" means, and the comparison feature — the reason this application
exists — silently compares incomparable numbers. That failure is invisible until someone checks by
hand.

F00 is not glamorous and it is not optional. **It is the whole of the first milestone.**

---

## 2. What already exists (do not rebuild)

Several project cards read like new modules but are extensions of shipped code. Knowing which is
which changes the effort estimate by an order of magnitude.

| Project | Existing code it extends | What is genuinely new |
|---|---|---|
| A01 PH/MAP compilers | `infinite/BNAqbd/` (QBD solver, working) | PH/MAP validation, MAP/PH/1 compilation, logarithmic reduction |
| A02 CTMC truncation bounds | `infinite/BNAtc/` + `finite/fBNAgc/` | Non-product-form generators, Foster–Lyapunov certificates |
| A09 Bounded-domain BAR | **`finite/fBNAlp/` — a Phase-1 scaffold** | The entire rectangle extension. See §3.1 |
| A10 Exact MVA/convolution | `infinite/BNApf/` (closed BCMP by enumeration) | Polynomial-time algorithms replacing a 200,000-state cap |
| A21 RBM structure detection | `AnalyticalTractability.swift` (skew-symmetry check) | Broader exact-structure detection, special distributions |
| A22 Adaptive spectral | `infinite/BNAsm/`, `finite/fBNAsm/` | Adaptive reference density, error-driven refinement |
| A23 Occupation-measure LP | `infinite/BNAlp/` (orthant LP, working) | Adaptive basis and refinement |
| A24 Moment LP/SDP bounds | `infinite/BNAbb/` | Higher-order cones, verified certificates |
| A30/A31 Sampling | `infinite/BNArmc/`, `infinite/BNAmc/` | Perfect sampling; importance splitting |
| A32 Poisson controls | `infinite/BNAsim/`, `finite/fBNAsim/` | Martingale control variates |

**A07 (transfer-line decomposition)** overlaps `finite/fBNAdecomp/` but targets a different model
class — continuous material and machine failure states, not discrete-job M/M/c/K. Treat it as new.

---

## 3. Release plan

### 3.1 v0.91 — "Exact, at scale, and honest about the gaps"

**Theme:** make the exact methods scale, finish the one method that ships incomplete, and start
reporting distributions rather than only means.

Chosen because every item is either foundation, an extension of working code, or the closure of a
documented defect — and because none of it requires a scientific hold to be resolved first.

| # | Project | Effort | Deps | Why it is in this revision |
|---|---|---|---|---|
| 1 | **F00** foundation contracts | H | — | Everything depends on it |
| 2 | **F01** reference simulator | H | F00 | The independent oracle; without it every result is self-graded |
| 3 | **F02** fixture transcription (E01–E14) | M | F00 | Exact expected values, owned separately from the solvers |
| 4 | **A10** exact MVA + convolution | M | F00, E09 | Closed networks jump from a 200k-state cap to polynomial time |
| 5 | **A27** PGF/LST inversion | H | F00 | Unblocks distributions everywhere; `Plans.md` says it can start immediately |
| 6 | **A09** bounded-domain BAR | H | F00, E05, E13 | **Completes `finite/fBNAlp`, which ships as a scaffold today** |
| 7 | **A03** direct GJN multiscale BAR | M | F00 | Improves the core open-network approximation users actually run |

**Deliberately excluded from v0.91:** anything needing D3 (CVXPY/SDP), D4 (PyTorch) or a resolved
scientific hold. Those are §3.5 and §4.

#### Why A09 is not optional

`finite/fBNAlp/README.md` states the binary is the orthant LP "copied from `OLD/BNA/BNAlp` and
renamed", with the rectangle mathematics unfinished. `Run ▸ Run Finite-Buffer LP` is in the menu and
returns numbers. The README says those numbers must not be presented as a validated
bounded-rectangle answer.

That is the worst state a scientific tool can be in: a working-looking control over unfinished
mathematics. Either A09 completes it, or the menu item should be removed. **Ship one or the other in
v0.91.** Leaving it as-is for another release is a decision to keep shipping a trap.

### 3.2 v0.92 — Priority and re-entrant networks

The largest scientific gap for the users this tool is aimed at: semiconductor fabs, re-entrant
lines, any system with scheduling.

| Project | Effort | Notes |
|---|---|---|
| **A15** FBFS/LBFS priority workload-to-RBM mapping | H | Needs the priority reference DES from F01 milestone 2 |
| **A16** Static-buffer-priority multiscale BAR | H | Gated on the stability-admission hold (§4) |
| **A17** Two-class priority OU / piecewise-linear diffusion | H | E10 exact marginal first; X2 golden comparison is held |
| **A01** PH/MAP compilers | H | Richer input laws; extends the working QBD solver |

Requires a **document schema migration**: per-station class ordering, preemptive-resume semantics,
stage identity distinct from customer type. `Plans.md` §9.1 — old `.bnet` files must keep loading,
with round-trip tests, and closed populations must never be inferred from a canvas cycle.

### 3.3 v0.93 — Manufacturing and closed networks

| Project | Effort | Notes |
|---|---|---|
| **A06** exact two-machine building blocks | H | Exact enumerator; the oracle for A07 |
| **A08** Markov-modulated fluid queues | H | Continuous material, failure clocks |
| **A07** blocking-aware transfer-line decomposition | H | Depends on A06 or A08 by model |
| **A14** CONWIP, pallets, closed loops | H | Depends on A06/A10 |
| **A11** multi-branched normalizer recursions | H | Depends on A10's exact normalizers |
| **A12** approximate MVA / Linearizer | M | **Held**: full Linearizer text unavailable (§4) |

This is where the manufacturing-model contract from `Plans.md` §2.1 earns its keep: discrete jobs
versus continuous material, calendar-time versus operation-dependent failure clocks, repair while
blocked. Those choices cannot be averaged away.

### 3.4 v0.94 — Bounds, certificates and better sampling

| Project | Effort | Profile |
|---|---|---|
| **A23** adaptive occupation-measure BAR LP | H | D1/D3 |
| **A24** stronger moment LP/SDP bounds | H | D3 + rational verification |
| **A25** dual BAR/Poisson certificates | H | D3 candidates, D0 verifier |
| **A30** perfect stationary sampling | H | D0/D1 |
| **A31** rare-event importance sampling | H | D0/D1 |
| **A32** Poisson-equation martingale controls | H | D1 |
| **H1** point estimate + verified BAR interval | — | The payoff: a number *and* a bound around it |

**The certificate rule, non-negotiable:** a floating-point CVXPY optimum is a *candidate*, not a
certificate. A candidate becomes certified only through independent rational or outward-rounded
verification (`Plans.md` §11). The existing `infinite/BNAbb/` already marks CVXPY output
`certified: false` — keep that discipline as the bar rises.

### 3.5 Research track (parallel, unscheduled)

Run alongside, never blocking a release. Each is explicitly experimental in the UI.

- **A29** Dai–Zhang neural Laplace-BAR — blocked on A29.1 (sign/exponent/architecture
  reconciliation) and on pinning the authors' code licence before any reuse.
- **A04** higher-order diffusion corrections, **A05** tensor-train CTMC — effort class R.
- **A13** closed Brownian on a simplex, **A19** N-system, **A20** polling, **A26** 2D kernel
  transforms, **A28** compensation method — each needs its own source/derivation gate first.
- **H2–H6** hybrids — bounded experiments after their component projects land.

---

## 4. Holds that must be resolved before the work they block

From `Plans.md` §11. These are not risks to manage; they are gates. **Do not guess past them.**

| Hold | Blocks | Resolution |
|---|---|---|
| Linearizer / compensation / some closed-network papers unavailable | A12, A28 | Obtain authorised full text. Implement the explicitly specified MVA parts meanwhile — and do not name a missing algorithm as completed |
| P24 priority OU X2 example under-parameterised | A17, B04 | Reconcile P38/author data. E10 exact X1 can proceed |
| Neural paper sign/exponent/architecture issues | A29 | Resolve as A29.1 before any reproduction claim |
| Author code licence not pinned | A29 reuse | Inspect and hash the licence, or reimplement independently |
| General multiclass stability admission | A16, A19 | Support proved subclasses with explicit checks. **Unknown is not stable. Simulation evidence is not proof** |
| Rigorous certificate verification | A24, A25, H1 | Independent rational verification, or report candidates only |
| Closed Brownian parameter mapping incomplete | A13, A21 | Complete the source transcription first |

---

## 5. Engineering discipline

### 5.1 Dependency profiles

`Plans.md` §1.2 defines D0–D5. Two rules that will otherwise be violated:

- **Keep the standard-library solvers working without the research environment.** Qnet's current
  Python methods run on a bare interpreter. A research venv at `.venv-research` must be additive; if
  installing NumPy becomes a prerequisite for methods that work today, that is a regression.
- **Probe capability, not import success.** HiGHS solves LP/QP, not SDP. Run a tiny PSD-constrained
  problem before declaring D3 usable. Test PyTorch complex forward evaluation and second derivatives
  before declaring D4 usable — and remember a Mac GPU is not a CUDA GPU.

### 5.2 Oracle independence

The rule that makes the rest of this credible: **expected values are never regenerated by the
algorithm under test.** A failing test is not repaired by pasting in the new solver output. The
fixture owner reviews changes to `expected.json`. Publication-table comparisons run separately from
exact-oracle tests, because a genuine improvement may legitimately differ from an old approximate
table (`Plans.md` §8.2).

### 5.3 Shared-file ownership

`Plans.md` §8.3 names the files that need a single integration owner: `Models.swift`,
`QnetGUIApp.swift`, `ResultsWorkspace.swift`, `ResultOutputParser.swift`,
`StartupDependencyChecker.swift`, `MethodChooserView.swift`, `AnalyticalTractability.swift`,
`RunParameterSpecs.swift`, `build_all_algorithms.sh`, `build_app.sh`, and the release inventories.

This project has already paid for that lesson twice. During the GUI work, six agents editing one
tree required disjoint file ownership and a written hand-off protocol; and the one round where
critique routing silently failed produced three rounds of "fixed" work that was never handed to
anyone. **An algorithm agent delivers an adapter contract and tests. It does not patch shared files
while another agent is in them.**

The repository is now under git, which removes the specific constraint that made that painful — a
branch per project, and the integration owner merges.

### 5.4 Release gates

Every revision must pass what already exists, unchanged:

```sh
swift build
./validation/design_lint.sh                  # 40 checks + WCAG contrast
./validation/gui_runtime_contracts.sh
./validation/result_output_parser_check.sh
./validation/embedded_formatter_parse_check.sh
./validation/steady_state_suite.sh
./verify_source_package.sh                   # both build paths, signature, 35 RQNA examples
./make_release.sh                            # standalone proof + checksummed archive
```

Plus, for every new method:

- `make -C <module> test` and `make -C <module> check` wired into `steady_state_suite.sh`
- The method's executable or module added to **both** `build_app.sh` **and**
  `validation/required_release_executables.txt` — which are deliberately maintained independently,
  so that dropping a build target cannot silently remove a method from a release
- Whole Python module directories packaged, not just the CLI entry file
- `.app` verification that actually **invokes** the solver, rather than syntax-checking its source

**Never weaken a gate to make new work pass.** The one legitimate edit is tightening an assertion
when you deliberately rewrite the line it pins.

### 5.5 Version policy

`AppVersion.swift` is pinned and `verify_source_package.sh` asserts it in three places. Bumping to
0.91.0 is a deliberate edit in the integration change that ships it — with the topmost `timestamp:
nil` entry in `Changelog.swift` frozen and a new one opened above it.

---

## 6. GUI integration

`Plans.md` §9 is emphatic and correct: **integrate one admitted model family at a time.** Do not
expose thirty experimental methods in the existing open-network menu.

For each family, in order:

1. **Document schema** — additive, versioned, with round-trip tests on existing `.bnet` files.
2. **Admission** — `AnalyticalTractability` answers *is this model in scope*;
   `StartupDependencyChecker` answers *is the dependency present*. These stay separate: an
   unsupported scheduling policy gets a mathematical explanation, not an offer to install a package.
3. **Run parameters** — resource caps, accuracy target, seed, variant. Model fields are not solver
   knobs. Neural training and checkpoint evaluation are different actions with different warnings.
4. **Typed results** — `ResultOutputParser` gains the new semantic rows; distribution, transform and
   boundary-rate payloads are separate from scalar metrics. **A mean-only method must not enable CDF
   export.** Failed metrics are shown with the reason, not hidden.
5. **Comparison** — same observable, same model fingerprint. A mixed-model comparison states the
   difference explicitly. A diffusion certificate does not bound a queue by association.

The GUI already enforces the result-claim vocabulary (exact queue process / approximation /
simulation / SRBM / certified). Every new method must declare its `model_layer` and `claim` in the
result envelope, and the UI must keep saying which is which.

---

## 7. Where to start

Concretely, the first four tasks, in order. Everything else waits.

1. **Freeze F00's schemas.** `common/qnet_models/` and `schemas/`. Only the fields the first
   admitted family needs — but freeze the conventions: row-major arrays, reflection **columns** as
   directions, covariance **Σ** rather than its square root, explicit units, stable IDs.
2. **Write the independent BAR residual evaluator** (`Plans.md` §2.3) and run it against the
   existing SRBM solvers. It is ~200 lines, it is reusable by six later projects, and pointing it at
   `infinite/BNAsm` and `infinite/BNAlp` tonight tells you whether today's numbers satisfy the
   identity they claim to.
3. **Transcribe E01–E05.** The small exact fixtures: M/M/1, M/E2/1, finite M/M/1/2 loss, 1-D orthant
   RBM, bounded 1-D RBM. Each with `expected.json`, `provenance.md` and an oracle test. These are the
   ground truth everything later is measured against.
4. **Decide A09 or removal** for `finite/fBNAlp`. This needs no new infrastructure and closes a
   documented gap in a shipping product.

Items 2 and 4 are independently valuable **even if the rest of the roadmap is never executed** —
which is the right property for the first work in a long programme.

---

## 8. Honest scoping

A01–A32 plus H1–H6 is a multi-year research programme, not a release. Twenty-five of the thirty-two
cards are effort class **H**; three are class **R** (open research); only four are **M**. Several depend on papers not
currently in hand.

The value of `Plans.md` is not that it will all be built. It is that each project is specified well
enough to be **started, bounded, and honestly reported on** — including reporting that it did not
work. `Plans.md` §8.5 requires a handoff record with an explicit claim classification for every
output, and one line that matters more than the rest:

> Do not call incomplete or unsupported science a successful implementation.

That sentence is the standard this roadmap is built to serve. A revision that ships two projects
with certified oracles and an honest limitations note is worth more than one that ships ten with
plausible numbers.

---

## References

- [`Plans.md`](../Plans.md) — the full playbook: project cards, fixtures, acceptance matrix
- [`docs/STEADY_STATE_METHODS.md`](STEADY_STATE_METHODS.md) — contracts for the methods that exist today
- [`docs/ALGORITHM_RESEARCH_2026-09-04.md`](ALGORITHM_RESEARCH_2026-09-04.md) — the survey behind the project list
- [`Papers/Qnet_Literature_Survey.md`](../Papers/Qnet_Literature_Survey.md) — sources, by paper ID
- [`validation/algo_review/`](../validation/algo_review/) — per-solver review of the current implementations
