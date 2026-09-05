# Algorithm review — measured, 2026-09-05

> **Status: recommendations 1–3 and 5–7 implemented or resolved, and re-measured.** See
> [§5 Implemented](#5-implemented-2026-09-05) for before/after numbers and for one
> correction to recommendation 2, which was partly wrong as originally written.

Every solver in `infinite/` and `finite/` was built, executed, and timed on this machine
(Apple silicon, 128 GB RAM, macOS 26, Python 3.9.6, NumPy 2.0.2). This document records what was
**measured**, not what the code appears to do.

## What this review is and is not

**Is:** an execution and scaling audit. Does each solver build? Does it run? Do its own tests pass?
Where does it stop scaling, and how does it behave when it gets there? What would make it faster,
more accurate, or able to solve larger networks?

**Is not:** an independent validation of mathematical accuracy. Each module's tests are written by
the same author as the module, so a passing suite proves internal consistency, not correctness
against an outside oracle. That gap is exactly what `Plans.md` F01/F02 and
[`docs/ROADMAP.md`](ROADMAP.md) exist to close, and it is the single most valuable thing missing
from this codebase. **Read every "PASS" below as "self-consistent", not as "verified correct".**

Test networks were exported from the shipped examples through Qnet's own `--export-cmp`, so the
inputs are byte-identical to what the GUI produces.

---

## 1. Measured results

### Python modules — own test suites

All 135 tests pass. Wall-clock for `make -C <module> test`:

| Module | Method | Tests | Time | Note |
|---|---|---:|---:|---|
| `infinite/BNApf` | BCMP product form | 38 | 0.18 s | |
| `infinite/BNAqbd` | Matrix-analytic QBD | 12 | 0.28 s | |
| `infinite/BNAtc` | Truncated CTMC | 10 | 0.26 s | |
| `infinite/BNAbb` | BAR moment bounds | 25 | 0.13 s | |
| `infinite/BNArmc` | Regenerative MC | 19 | 2.41 s | |
| `infinite/BNAalr` | Adaptive low-rank BAR | 11 | **73.30 s** | **300× the next slowest** |
| `finite/fBNAgc` | Generic finite CTMC | 12 | 0.08 s | |
| `finite/fBNAdecomp` | M/M/c/K decomposition | 8 | 0.14 s | |

### Native solvers — scaling on a tandem network

Identical networks at increasing station count *d*, exported through `--export-cmp`:

| Solver | d=2 | d=3 | d=5 | d=10 | d=15 | d=20 |
|---|---:|---:|---:|---:|---:|---:|
| `BNAqna` QNA | — | — | 0.02 s | 0.02 s | 0.02 s | 0.02 s |
| `BNArqna` RQNA | — | — | 0.02 s | 0.02 s | 0.02 s | 0.02 s |
| `BNAsbd` SBD | — | — | 0.04 s | 0.04 s | 0.06 s | 0.07 s |
| `BNAsim` DES (10 rep) | — | — | 0.04 s | 0.05 s | 0.09 s | — |
| `BNAmc` MLMC | — | — | 8.87 s | — | — | — |
| `BNAsm` spectral (p=8) | — | — | 0.08 s | **388 s** | refused | refused |
| `fBNAsm` finite spectral | — | — | 0.09 s | **fails at 51 s** | fails | — |
| `fBNAfm` finite FEM (mesh 12) | 0.04 s | 0.27 s | **>90 s** | — | — | — |
| `fBNAlp` finite LP | — | — | 5.29 s | fails | — | — |

**The decomposition methods are effectively free** — QNA, RQNA and SBD are all under 0.1 s at
twenty stations, and DES is nearly as cheap. Every scaling problem in Qnet is in the *diffusion*
solvers.

---

## 2. Per-algorithm findings

### `BNAqna` — Whitt QNA · **PASS**

Runs in 0.02 s at every dimension tested. Exits 1 on a missing input (the `exit(0)`-on-user-error
footgun recorded in `validation/algo_review/` has been fixed across the family — verified on five
solvers). Carries `bnet_memcheck`.

**Improvements**
- *Scale:* `validation/algo_review/BNAqna.md` records function-local `MAX_NODES²` matrices on the
  stack; raising `MAX_NODES` segfaults immediately, even for small inputs. Heap-allocate per-call
  scratch before anyone tries to raise the cap.
- *Accuracy:* QNA aggregates classes at a station. Per-class variability propagation already exists
  in `BNArqna`; the useful comparison for a user is QNA-vs-RQNA on the same network, which
  `Run Comparison` can already show.

### `BNArqna` — Refined QNA · **PASS**

0.02 s at all dimensions. Self-test passes (`bna_rqna --selftest`). Per-class IDC propagation active
at 20 timescales.

**Improvements**
- *Robustness:* **UNGUARDED** — no `bnet_memcheck`. It is cheap today, but the guard is one include
  and one call, and it is the difference between a clean refusal and an OOM.

### `BNAsbd` — Sequential bottleneck decomposition · **PASS**

0.04–0.07 s across d=5…20. Depends on `BNAsm/bnet` for subproblems and degrades to 1-D
approximations if that fails, which is the right behaviour.

**Improvements**
- *Accuracy:* classes are aggregated silently. The GUI presents SBD results for multiclass networks
  without saying the classes were merged — that belongs in the result record, not just the docs.
- *Scale:* same stack-allocated `MAX_NODES²` issue as QNA.

### `BNAsim` / `fBNAsim` — Discrete-event simulation · **PASS**

The fastest useful method in the suite: 0.09 s for 10 replications at d=20.

**Improvements**
- *Accuracy:* `BNAsim` uses an LCG with period 2³² (`validation/algo_review/BNAsim.md`). At
  10⁸ arrivals — the budget `Plans.md` cites for paper reproduction — that period is a real
  correlation risk. `fBNAsim` and `BNAmc` already use xoshiro256\*\* (period 2²⁵⁶). **Port it.**
- *Accuracy:* neither simulator has adaptive stopping. `BNAmc` has `--adaptive` with an SE target;
  the same idea applied here would let a user ask for a precision instead of guessing a horizon.
- *Speed:* `BNAsim` is one 2,058-line file with a single event path; `fBNAsim` is seven files with
  clean interfaces and three parallel backends. The consolidation direction is obvious.
- *Robustness:* both **UNGUARDED**.

### `BNAsm` — Orthant spectral/Galerkin · **PASS, with a hard wall**

The most important measurement in this review:

```
d=5   0.08 s
d=10  388 s          ← 4,850× for 2× the dimension
d=15  refused instantly: "requested 1791.18 GB, budget 64.00 GB"
d=20  refused instantly: "requested 71974.92 GB"
```

The cost is a dense C(d+p, p) × C(d+p, p) system: 1,287 basis functions at d=5, 43,758 at d=10,
490,314 at d=15.

**This solver's failure behaviour is the best in the codebase and should be the template.** It
refuses in 0.03 s with the requested size, the budget, the physical RAM and the name of the data
structure. Nothing is more useful to a user who has just asked for something impossible.

**Improvements**
- *Scale, biggest available win:* the system matrix is dense but the underlying operator is sparse
  in the polynomial basis — products of low-degree terms couple only nearby multi-indices. A sparse
  assembly plus an iterative solve (GMRES with a diagonal or incomplete-LU preconditioner) would
  replace an O(N²) matrix and O(N³) factorisation with O(nnz) storage and O(N·nnz) work. This is the
  difference between d=10 and d=15+.
- *Speed:* at d=10 the 388 s is dominated by the dense factorisation; even keeping the dense path,
  the assembly loop is a natural target for the OpenMP already linked in.
- *Accuracy:* degree refinement is manual. Solve at p and p−2 and report the change, so the user
  gets a convergence signal instead of a single unqualified number.

### `fBNAsm` — Bounded spectral · **PASS at d=5, FAILS BADLY at d=10**

```
d=5   0.09 s
d=10  51 s of work, then: "Error: Failed to allocate boundary integral cache"
```

**This is the worst failure mode measured.** It has `bnet_memcheck` — but the guard does not cover
the boundary integral cache, so it computes 43,757 basis functions over 51 seconds and *then* dies.
`BNAsm` refuses the equivalent request in 0.03 s.

**Improvements**
- *Robustness, highest priority in this document:* extend the existing pre-flight to size the
  boundary integral cache. The pattern is already in the file; it simply does not cover every
  allocation. Fifty-one seconds spent to reach a failure that was predictable at second zero is
  strictly worse than an immediate refusal.
- *Scale:* the boundary cache is 2d faces × basis²; the same sparsity argument as `BNAsm` applies.

### `fBNAfm` — Bounded finite element · **PASS at d≤3, unusable at d≥4**

```
d=2   0.04 s
d=3   0.27 s
d=4   >90 s (killed)
d=5   >600 s (killed)
```

A tensor-product mesh of 12 per dimension is 12^d elements: 144, 1,728, 20,736, 248,832. It also
produces **no progress output**, so from the GUI a d=4 run is indistinguishable from a hang.

**Improvements**
- *Speed and scale:* tensor-product meshing cannot go past d=3. Sparse-grid (Smolyak) construction
  gives comparable accuracy at O(m·(log m)^(d−1)) instead of m^d, and is the standard remedy for
  exactly this wall.
- *Usability:* emit a progress line per box or per assembly phase. Qnet's shell already renders
  progress; the solver just has to speak.
- *Robustness:* a pre-flight that estimates m^d before assembling and refuses above budget, as
  `BNAsm` does.

### `fBNAlp` — Finite-buffer LP · **INCOMPLETE — not a validated method**

5.29 s at d=5; fails at d=10. Its own README states the binary is the orthant LP copied from
`OLD/BNA/BNAlp` and renamed, with the rectangle mathematics unfinished.

At d=10 it reports `Face 9: lower=10077696 upper=10077696` then produces 286 basis functions and
exits 2.

**This should not be presented as a bounded-rectangle answer.** `Run ▸ Run Finite-Buffer LP` is in
the menu and returns numbers. Either complete it (roadmap `A09`) or remove the menu item; see
[`docs/ROADMAP.md`](ROADMAP.md) §3.1.

### `BNAlp` — Orthant BAR LP · **PASS**

Runs through HiGHS. Guarded. The GUI auto-scales grid/basis by dimension and refuses an estimated
model above two million variables.

**Improvements**
- *Accuracy:* the finite-grid result is not advertised as a rigorous bound, correctly. Roadmap `A23`
  (adaptive basis) and `A24`/`A25` (verified certificates) are the path to making it one.

### `BNAmc` — SRBM MLMC · **PASS**

8.87 s at d=5 for RMSE 0.05/0.02. Already the best-engineered native solver: xoshiro256\*\*,
`--adaptive` with SE-target stopping, antithetic variates, three backends (Accelerate/OpenMP/serial),
automatic sparsity detection.

**Improvements**
- *Robustness:* **UNGUARDED** — the one gap in an otherwise exemplary solver.
- *Accuracy:* it estimates the SRBM, not the queue. The interval is honest about that today; keep it
  that way.

### `BNAqbd` — Matrix-analytic QBD · **PASS** (12 tests, 0.28 s)

**Improvements**
- *Speed:* functional iteration is retained as the solver. Logarithmic reduction converges
  quadratically rather than linearly — roadmap `A01` milestone 4, and the single biggest constant
  factor available here.
- *Scale:* the GUI adapter accepts only one-source, one-class, one-station M/M/1 with optional
  feedback. The solver underneath is far more general than what the GUI exposes; widening the
  adapter is cheap capability.

### `BNApf` — BCMP product form · **PASS** (38 tests, 0.18 s — the best-tested module)

**Improvements**
- *Scale, highest-value algorithmic change in the codebase:* closed networks are solved by **state
  enumeration** under a 200,000-state cap. Mean Value Analysis is O(N·K·R) and convolution is
  similar — polynomial instead of combinatorial. A closed network with 50 jobs and 6 stations is
  impossible today and trivial under MVA. Roadmap `A10`.

### `BNAtc` — Truncated CTMC · **PASS** (10 tests, 0.26 s)

**Improvements**
- *Scale:* total-population truncation is combinatorial in stations. Per-station caps chosen from
  the marginal geometric decay rate would retain the same mass in far fewer states.
- *Accuracy:* the Foster–Lyapunov certificate applies only where the exponential drift inequality
  holds. Roadmap `A02` extends it to non-product-form generators.

### `BNAbb` — BAR moment bounds · **PASS** (25 tests, 0.13 s)

Correctly marks CVXPY output `certified: false`. That discipline is right and should not be relaxed.

**Improvements**
- *Accuracy:* a floating-point conic optimum is a candidate. Independent rational or
  outward-rounded verification is what turns it into a certificate — roadmap `A24`/`A25`.

### `BNArmc` — Regenerative Monte Carlo · **PASS** (19 tests, 2.41 s)

**Improvements**
- *Scale:* empty-and-idle regeneration is rare in large or heavily loaded networks, so cycles become
  unaffordable exactly where the method is wanted. Roadmap `A30` (perfect sampling) and `A31`
  (splitting) address this directly.

### `BNAalr` — Adaptive low-rank BAR · **PASS, but 300× slower than any peer**

73.3 s for 11 tests. Profiled: **99.8% of runtime is `_fit_weights` (`low_rank_bar.py:197`)** —
113.9 s of 114.1 s across 42 calls, 2.7 s each.

The function is FISTA (accelerated projected gradient) **written in pure Python lists** — no NumPy —
calling `_objective_and_gradient` up to four times per iteration. NumPy 2.0.2 is installed on this
machine and the module does not import it. The convergence test is
`projected_change <= 2e-13 and relative_drop <= 2e-14`, within a factor of ~100 of float64 epsilon,
so late iterations chase rounding noise.

**Improvements**
- *Speed, easiest large win in the codebase:* vectorise `_objective_and_gradient` and
  `_project_groups` with NumPy behind an optional import, keeping the pure-Python path as fallback
  (the project's convention is that stdlib solvers keep working without the research environment).
  A dense mat-vec moving from Python lists to BLAS is typically 50–200×; 73 s becomes about a second.
- *Speed:* loosen the tolerance to ~1e-10 with an iteration cap, and report the achieved residual
  rather than iterating to noise.
- *Accuracy:* unchanged by either — both are about how quickly the same optimum is reached.

### `BNAmd` — Multiclass workload diffusion · **PASS (experimental)**

Builds only with the optional cJSON dependency. Correctly reported as unavailable when absent.

### `fBNAgc` — Generic finite CTMC · **PASS** (12 tests, 0.08 s)

**Improvements**
- *Scale:* reachable ordered-FCFS state space is combinatorial with a 200,000-state guard. Roadmap
  `A05` (tensor-train) is the research answer; a sparse iterative solve with a better ordering is
  the engineering one.

### `fBNAdecomp` — Finite M/M/c/K decomposition · **PASS** (8 tests, 0.14 s)

**Improvements**
- *Accuracy:* loss mode assumes independent station occupancies and Poissonised internal flows; the
  BAS variants add an explicitly heuristic closure. These are disclosed in the module docs but not
  in the result record the user sees.

### `fBNActmc` — Dense tandem CTMC · **PASS**

Deliberately narrow: tandem only, M/M/1 only, loss only, 1,000-state cap, NumPy required. The
`gui_runtime_contracts.sh` gate pins all four restrictions. Correct as designed.

---

## 3. Cross-cutting findings

### 3.1 The `exit(0)` footgun is fixed

`validation/algo_review/README.md` recorded that every analytical solver returned success on parse
and configuration errors, so `Run Comparison` treated a failure as a result. **Re-tested on five
solvers: all now exit 1 on a missing input.** Resolved.

### 3.2 Memory guards are adopted in 7 of 12 native solvers

| Guarded | Unguarded |
|---|---|
| BNAqna, BNAsbd, BNAsm, BNAlp, fBNAsm, fBNAfm, fBNAlp | **BNArqna, BNAmc, BNAsim, BNAfm, fBNAsim** |

And guarded is not the same as fully guarded: `fBNAsm` has `bnet_memcheck` yet still dies on an
unguarded boundary-integral allocation after 51 seconds of work.

**Recommendation:** the guard is one include and one call. Add it to the five, and audit the seven
for allocations the pre-flight does not size.

### 3.3 Failure behaviour is inconsistent, and it matters more than speed

Three solvers were asked for something impossible:

- `BNAsm` — refused in **0.03 s** with requested size, budget, physical RAM, and the structure name.
- `fBNAsm` — worked for **51 s**, then failed on an allocation.
- `fBNAfm` — ran past **600 s** with no output at all.

From the GUI these are: a helpful error, a long wait ending in an error, and an apparent hang. The
first is a good product; the third is indistinguishable from a bug. **Make `BNAsm`'s pre-flight the
family standard.**

### 3.4 No solver emits progress except through the shell wrapper

`fBNAfm` at d=4 produces nothing for minutes. Qnet's shell already renders progress bars from a
progress file. Long-running solvers should write one.

### 3.5 Self-consistent is not verified

All 135 Python tests pass, but each module's tests were written alongside the module. There is no
independent oracle for any method. The exact fixtures E01–E14 in `Plans.md` §4 exist precisely to
supply one, and **nothing in this review should be read as confirming numerical correctness.**

---

## 4. Recommendations, in priority order

| # | Change | Solver | Kind | Why first |
|---|---|---|---|---|
| 1 | Size the boundary integral cache in the pre-flight | `fBNAsm` | Robustness | 51 s to reach a predictable failure |
| 2 | Add `bnet_memcheck` to the five unguarded solvers | 5 native | Robustness | One include and one call each |
| 3 | Vectorise `_fit_weights` with NumPy | `BNAalr` | Speed | 99.8% of runtime in one function; 50–200× available |
| 4 | Complete or remove the finite LP | `fBNAlp` | Integrity | Ships as a scaffold behind a working-looking menu item |
| 5 | MVA / convolution for closed networks | `BNApf` | Scale | 200k-state cap → polynomial |
| 6 | Sparse assembly + iterative solve | `BNAsm` | Scale | The d=10 → d=15 wall; 388 s → tractable |
| 7 | Sparse-grid (Smolyak) meshing | `fBNAfm` | Scale | m^d → m·(log m)^(d−1); unlocks d≥4 |
| 8 | xoshiro256\*\* for `BNAsim` | `BNAsim` | Accuracy | 2³² period is a real risk at 10⁸ arrivals |
| 9 | Progress output from long solvers | several | Usability | A hang and a long run look identical today |
| 10 | Logarithmic reduction | `BNAqbd` | Speed | Quadratic vs linear convergence |
| 11 | Independent oracles (E01–E14) | all | **Correctness** | Everything above assumes the maths is right |

Item 11 is last by dependency and first by importance. Items 1–3 are each under a day and are the
best immediate value: two prevent bad failures, one is a 50–200× speedup in a single function.

---

## Reproducing this review

```sh
# Python module suites
for m in infinite/BNApf infinite/BNAqbd infinite/BNAtc infinite/BNAbb \
         infinite/BNArmc infinite/BNAalr finite/fBNAgc finite/fBNAdecomp; do
    make -C "$m" test
done

# Export identical networks at increasing dimension
./Qnet.app/Contents/MacOS/Qnet --export-cmp input/examples/10stationtandem.inf.bnet /tmp/d10

# Native solvers (cmp_sm.in is the orthant export; sm.in/fm.in/lp.in are the finite ones)
infinite/BNAqna/bna_qna /tmp/d10/qna.qna -c
infinite/BNAsm/bnet -c /tmp/d10/cmp_sm.in
finite/fBNAsm/srbm_solver /tmp/d10/sm.in -G

# Profile the slow module
cd infinite/BNAalr && python3 -c "import cProfile,unittest;\
cProfile.run('unittest.TextTestRunner().run(unittest.TestLoader().discover(\"tests\"))','p');\
import pstats;pstats.Stats('p').sort_stats('cumulative').print_stats(8)"
```


---

## 5. Implemented (2026-09-05)

### #1 — `fBNAsm` boundary integral cache

| | Before | After |
|---|---|---|
| d=10 | 51 s of work, then `Failed to allocate boundary integral cache` | **0.39 s**, clean refusal naming the size (15,020 GB), the budget (64 GB), physical RAM and the remedy |
| d=5 | 0.09 s, `N_total = 8.842176` | 0.08 s, `N_total = 8.842176` — unchanged |

**A correctness bug was found while fixing this.** `compute_cache_size` returned `int` and
multiplied in `int`, so `(max_degree+1)^n_dim` **silently wrapped** past `INT_MAX`. This is
reachable inside the solver's own `MAX_DIM 10`: at `n_approx=6, d=9` the true size is
10,604,499,373 entries and the wrapped value is 2,014,564,781 — positive, allocatable as 16 GB on a
large machine, and then indexed with strides that overflowed the same way. That path returns
**numbers rather than an error**, which is the worst outcome available.

Fixed by computing in `uint64_t`, pre-flighting through `bnet_memcheck_alloc` before any allocation,
and refusing explicitly above `INT_MAX` since the index arithmetic downstream is `int`-typed. One
guard covers both caches because every boundary face routes through `integral_cache_init`.

### #2 — Memory guards: partly implemented, and the recommendation was partly wrong

Guards added where the allocation genuinely scales with user input:

- **`BNArqna`** — the `N x N` per-class coefficient matrix.
- **`BNAsim`** — replication storage, sized by `-n`, which is user-supplied and unbounded.
- **`fBNAsim`** — the same, via `num_runs`.

Verified firing: `jackson_sim -n 900000000` now refuses in milliseconds with
`requested 73760.75 GB, budget 64.00 GB`, and normal runs are unaffected (0.04 s; RQNA self-test
passes).

**Not implemented, because on inspection a memory guard is the wrong control:**

- **`BNAfm`** allocates nothing dynamically. It uses fixed stack arrays under `MAX_DIM 8`. A guard
  here would be dead code.
- **`BNAmc`** allocates O(d), O(d²), O(K), O(C·K) and O(threads) — all small. MLMC is bounded by
  *time*, not memory; its existing `--adaptive` SE-target stopping is the control that matters.

Recommendation 2 originally said "add the guard to five solvers". Two of those five do not need it,
and adding ceremonial guards to satisfy a checklist would have been worse than not adding them.
Guarded native solvers: **7 of 12 → 10 of 12**, with the remaining two justified above.

### #3 — `BNAalr` vectorisation

| | Time | Tests |
|---|---:|---|
| Before | 73.30 s | 11 pass |
| After, NumPy present | **3.56 s** | 11 pass |
| After, NumPy hidden (fallback) | 71.97 s | 11 pass |

**20.6× faster**, and the pure-Python path is genuinely unchanged — its 71.97 s matches the original
73.30 s.

NumPy is an **optional** import. This module is one of the standard-library solvers that must keep
working on a bare interpreter, which is what the packaged app relies on; when NumPy is absent the
original code runs untouched.

Only the two O(rows × n) primitives were swapped — `A x` and `Aᵀ r`. The FISTA body is O(n) per
iteration with n = rank × groups and was left alone.

**Numerical agreement was verified, not assumed.** The same example run through both paths and
compared field by field: 157 numeric fields, worst relative difference **3.19e-12**, status and
claim strings identical. That is the expected difference between `math.fsum` (exact summation) and
BLAS (pairwise) — well inside every tolerance the module asserts.

The tolerance loosening also suggested under #3 was **not** applied. The speedup made it
unnecessary, and changing a convergence criterion changes results; that belongs with the independent
oracles (§3.5), not bundled into a performance change.

### Gate after all three

`build_all_algorithms.sh`, `steady_state_suite.sh`, `gui_runtime_contracts.sh`,
`mlmc_native_check.sh`, `verify_source_package.sh`, `make_pkg.sh` — all pass.


---

## 6. Second tier (2026-09-05)

### #5 — Exact MVA for closed networks · **implemented**

New `infinite/BNApf/mva.py`: exact multiclass Mean Value Analysis (Reiser–Lavenberg), including the
load-dependent recursion with marginal probabilities for multi-server FCFS stations. `solver.py`
now chooses per model, and `include_states` still forces enumeration because MVA never forms the
joint law.

**Cross-validated against an independent oracle.** The existing enumerating solver is separate code
reaching the same product form by a different route, so agreement is a real check rather than a
restatement. `tests/test_mva.py` asserts agreement to **1e-9** across eight model shapes: single
class, delay stations, FCFS single- and multi-server, multiclass, multiclass with multi-server, a
class that skips a station, and a zero-population class.

What it unlocks, measured on a 120-job / 8-station machine-repair model:

| | Enumeration | MVA |
|---|---|---|
| Work | **89,356,415,775 states — refused** | 121 lattice points |
| Time | n/a | **0.9 ms** |
| Little's law residual | n/a | 0.00e+00 |
| Population conservation | n/a | 0.00e+00 |

Throughput came out at exactly 5.000000 = 1/0.20, the saturated bottleneck demand, and the delay
station held exactly 40.0 = X·D. Both are analytic checks the result must satisfy.

MVA is polynomial in population and exponential only in the *number of classes*; enumeration is
combinatorial in both. So this is a strict gain where enumeration cannot go, and the dispatcher
picks on that basis rather than always preferring one.

### #6 — Sparse assembly for `BNAsm` · **NOT implemented: the recommendation was wrong**

The recommendation assumed the spectral system matrix is sparse. **It is not.** Measured by
instrumenting a scratch build and counting entries above 1e-12 of the maximum:

| Dimension | Basis size N | Density |
|---|---:|---:|
| d=3 | 164 | **45.7%** |
| d=5 | 1,286 | **47.3%** |
| d=10 | 43,757 | **47.7%** |

Density is essentially constant in d. A sparse representation would store half of N² — no
meaningful saving — and an iterative solve on a 47%-dense operator is normally *slower* than a
dense direct factorisation.

The 388 s at d=10 is also not slack: dense LU on N=43,757 is 2.79e13 flops, so 388 s is about
**72 GFLOP/s**, a substantial fraction of peak for this machine. There is no large constant factor
left in the linear algebra.

**The lever is N, not the solve.** N = C(d+p, p), so the tractable move is a smaller approximation
space:

| | N | Dense LU flops |
|---|---:|---:|
| d=10, p=8 | 43,758 | 2.79e13 |
| d=10, p=6 | 8,008 | 1.71e11 |
| d=10, p=4 | 1,001 | 3.34e08 |
| d=15, p=4 | 3,876 | 1.94e10 |

`BNAsm`'s existing guard already tells the user exactly this — it refuses and names the degree as
the thing to reduce. Recommendation #6 is therefore withdrawn and folded into #7: the remedy for
both solvers is a reduced index set, not faster linear algebra.

### #7 — `fBNAfm` scaling · **partly implemented**

**Done — the trap is closed.** The measured cost is a *time* explosion, not memory: at d=5 the
working set is only ~483 MB, so a memory budget cannot see it. Charged against a work budget
instead, with the estimate shown:

| | Before | After |
|---|---|---|
| d=2 | 0.04 s | 0.03 s |
| d=3 | 0.27 s | 0.27 s |
| d=5 | **ran past 600 s, no output** | **refuses in 0.02 s** |

```
ERROR: finite-element assembly exceeds the work budget.
  mesh elements    : 248832 (mesh^d)
  quadrature points: 1024 per element
  local basis pairs: 1024 per point
  estimated work   : 2.609e+11 operations
  budget           : 8.000e+09 operations
```

Default 8e9 operations (~5 minutes at the measured 2.6e7 ops/s), overridable with
`BNAFM_MAX_WORK` for a deliberate long run — verified both that it refuses and that the override
proceeds. Applied to both the Gaussian-quadrature and CBC-QMC variants. `prod_u64` was added
alongside `prod_int` because `mesh^K` wraps an `int` past d=8 at mesh 12, the same defect class
found in `fBNAsm`.

**Not done — Smolyak sparse grids.** Replacing the tensor-product mesh with a sparse grid is the
actual scaling fix, and it changes the approximation space, so it changes results. `fBNAfm` has no
independent oracle, which means a subtly wrong sparse-grid assembly would produce plausible numbers
that nothing here could catch. That is the one failure mode this codebase's conventions exist to
prevent, so it is left for the roadmap where the exact fixtures come first.

### Gate

`build_all_algorithms.sh`, `steady_state_suite.sh` (now 48 BNApf tests), `gui_runtime_contracts.sh`,
`verify_source_package.sh` — all pass.
