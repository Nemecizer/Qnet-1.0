# fBNAsm — review

**Solver:** `finite/fBNAsm/srbm_solver`
**Sources:** `finite/fBNAsm/{main.c, srbm_solver.c, srbm_types.h, gram_matrix.c, suitesparse_wrapper.c, input_parser.c, poly_ops.c, verify_mc.c}` (~3.2 KLOC C, multi-file, C11)
**Method:** Spectral / Galerkin solver for the stationary distribution of an SRBM in the **hypercube** (finite-buffer analogue of BNAsm's orthant solver). Implements Dai-Harrison 1991. Two solver backends: SuiteSparse (default) and pure Gram-Schmidt (`-g`).
**Empirical work backing this review:** `validation/algo_review/work/fbnasm/`

---

## 1. Current implementation

The polynomial basis is the same `{x^α : 1 ≤ |α| ≤ n}` as BNAsm; the difference is the integration domain — a hypercube `[0, a_1] × … × [0, a_d]` instead of an orthant. The pipeline (line numbers in `srbm_solver.c`):

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 1 | `parse_input_file`               | (input_parser.c) | positional `fscanf` | O(d²) |
| 2 | reflection-matrix sanity check   | 553–578 | warns on skew-reflection (`v_k_lower ≤ 0` etc.) | O(d) |
| 3 | `generate_multi_indices`         | 132 | recursive enumerate `1 ≤ |α| ≤ n` | O(N) |
| 4 | `bnet_memcheck_alloc(N²·8 B)`    | 596 | budget vs. dense Gram matrix | O(1) |
| 5 | `compute_Af` (or `compute_Af_legendre`) parallel | 619–626 | per-monomial Galerkin operator action | O(N · d²) |
| 6 | `init_power_table` × interior + d boundary | 629–649 | precompute `a_d^e/(e+1)` for fast monomial integration | O(d · n) |
| 7a | **GS path** — `gram_schmidt` | 511–540 | Modified Gram-Schmidt + 1 re-orth pass | O(N³ · d) |
| 7b | **SS path** — `srbm_solve_suitesparse` | 798+ | precompute monomial integral cache, build dense Gram matrix, dense Cholesky | O(N²) build + O(N³) solve |
| 8 | projection coefficients `(φ₀, φ̂_i)` parallel | 670–673 | `inner_product` over orthogonal basis | O(N · n) |
| 9 | normalisation `α`, mean `q[k]`, boundary measures `δ[face]` | 681–771 | analytic integration via power tables | O(N · d) |

Static caps: `MAX_DIM = 10`, `MAX_TERMS = 10000`, `MAX_POLY_ORDER = 20`, `CC_MAX = 32` (`srbm_types.h:14–17`).

---

## 2. Empirical performance

### 2.1 SuiteSparse vs Gram-Schmidt — three orders of magnitude

`work/fbnasm/`, synthetic d-station tandem with `K = 5` buffer, ρ = 0.7 (the reflection matrix is geometrically degenerate but numerically valid; only the absolute timings depend on it):

| (d, n) | basis N | SS path | GS path | speedup |
|---|---:|---:|---:|---:|
| 2, 4 |   14 | 238 ms | 26 ms  | (SS warm-up) |
| 2, 8 |   44 | 28 ms  | 33 ms  | 1.2× |
| 3, 8 |  164 | 38 ms  | 387 ms | 10× |
| 4, 6 |  209 | 28 ms  | 1.15 s | 41× |
| 4, 8 |  494 | 37 ms  | 29.1 s | **787×** |
| 5, 6 |  461 | 30 ms  | 26.6 s | 887× |
| 5, 8 | 1286 | 17 ms  | (>3 min — killed) | ≥ 11 000× |

GS scales as O(N³ · d): at N = 1286 with d = 5 each Gram-Schmidt step needs ~6 N inner products of d-variate polynomials. The SS path's integral-cache + dense Cholesky is essentially constant up to N ≈ 2000 because the build dominates the solve and the cache hits are O(1) per pair.

**Default is SS — good.** Recommend deprecating `-g` outside of debugging; the GS path produces no correctness benefit (modified GS with reorth is numerically equivalent to the Cholesky path for SPD systems) and the speed gap is irrecoverable above n ≥ 6.

### 2.2 OpenMP scaling is weak on the SS path

At d=5 n=8 (basis 1286):

| `OMP_NUM_THREADS` | wall time | speedup |
|---:|---:|---:|
| 1 | 207 ms | 1.0× |
| 2 | 149 ms | 1.4× |
| 4 | 127 ms | 1.6× |
| 8 | 119 ms | 1.7× |

Sub-linear because the SS path's parallel section (Gram matrix entries) is already so fast (~50 ms) that thread-spawn overhead dominates. The Gram matrix build *is* the bulk of the wall time, but it's already hand-tuned to use the integral cache, so thread parallelism isn't the bottleneck — memory bandwidth is. At larger basis (N > 5000) OMP would matter more.

### 2.3 Memcheck cleanly catches OOM-grade configurations

```
$ srbm_solver fbnasm_d8_n12.in
SRBM solver (SuiteSparse): n=8 dimensions, order=12
Basis dimension: 125969

ERROR: requested allocation exceeds the memory budget.
  data structure   : SRBM finite-buffer Gram matrix
  requested        : 118.23 GB
  per-run budget   : 16.00 GB  (50% of physical RAM, or BNET_MAX_BYTES)
  physical RAM     : 32.00 GB
```

Same `common/bnet_memcheck.h` integration as BNAsm. Already best-practice.

---

## 3. Correctness — bugs & footguns

### 3.1 The hard cap is `MAX_DIM = 10`, not 64

`srbm_types.h:14` defines `#define MAX_DIM 10`. Crossing it exits *cleanly* (good!) — `Error: Invalid dimension` (`input_parser.c`). But:

- The exit code is **0** (success), not non-zero. Callers can't distinguish a successful solve from an over-dim refusal.
- 10 is much tighter than BNAsm's 64. The reason is that `MAX_DIM` propagates into stack arrays (`int new_exp[MAX_DIM]` in `compute_Af`, `int boundary_exp[MAX_DIM]`, `LegendreTable.coeffs[MAX_POLY_ORDER+1][MAX_POLY_ORDER+1]` etc.) — a generous bump would cost stack frames the way the QNA/SBD case does. **The fix is the same: heap-allocate the per-call scratch sized to actual `n_dim`.**

For finite-buffer queueing networks, d > 10 is genuinely useful (10-station rail-control systems, multi-stage assembly lines). The cap is the binding accuracy / scalability blocker.

### 3.2 `exit(0)` on user error — same pattern as BNAsm

`main.c:104, 134, 179` all return 1 from main, but `parse_input_file` and the dim cap path go through `exit(0)` indirectly (`Error: Invalid dimension` followed by main's own return path). Run Comparison and `test.sh` parse exit-non-zero as failure; this would silently mark a bad input as success.

### 3.3 The reflection-matrix validator only warns

`srbm_solver.c:553–578` checks the diagonal of `R` against the geometric requirement that lower face pushes `+x_k` and upper face pushes `−x_k`. On violation it prints `WARNING:` but proceeds. Skew reflections are a known un-validated regime — silent "may not converge properly" is the wrong contract; a `--strict` flag should make these refusals.

### 3.4 Legendre basis is plumbed but underused

`-L` activates `compute_Af_legendre` + `init_power_table_legendre`. The Legendre basis is supposed to give better conditioning at high polynomial degree (n ≥ 10). On the d=4 n=8 test it gave **identical** numerical output to the power basis (E[X_k] match to 6 digits). Useful when it matters — but no automatic switch and no diagnostic that says "Power basis condition number > 10⁹, recommend `-L`". Currently the user must know to try it.

### 3.5 Modified Gram-Schmidt does the right thing already

`srbm_solver.c:525`: `for (int pass = 0; pass < 2; pass++)` — Modified Gram-Schmidt with one re-orthogonalization pass, the textbook recipe for ill-conditioned bases. Best-of-codebase numerical hygiene.

### 3.6 The reflection matrix file format is fragile

`srbm_solver.c:231` reads `R[i, face] = R[i * 2 * n_dim + face]` (row-major, d × 2d). The exporter (`Sources/Qnet/SRBMExporter.swift`) and the parser must agree on layout, dimensions, and convention (lower vs. upper face ordering). A typo would produce a perfectly valid-looking input with completely wrong geometry — and the warnings in §3.3 only catch the most blatant violations. Worth adding a brief diagnostic header to the input format (`# d=4 K=5 …`) and validating before solving.

### 3.7 Stale comment about `MAX_TERMS = 10000`

`srbm_types.h:15`: `#define MAX_TERMS 10000`. I couldn't find any code path that actually uses `MAX_TERMS` (the polynomial growth uses `Polynomial.capacity` which doubles dynamically in `poly_add_term`). Looks like a leftover from a previous static-cap design. Removing it would clarify the actual limits.

### 3.8 Wall-time floor of ~25 ms is process startup

Same as BNAsm — Apple Accelerate + OpenMP runtime initialisation accounts for the ~25 ms minimum. Library mode would close this gap.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Lift `MAX_DIM` to 32 (or remove): heap-allocate per-call scratch (`int new_exp[]`, etc.) sized to actual `n_dim` | 1 d | §3.1 — d > 10 is a real use case for finite-buffer networks; cap is the hard ceiling | Unblocks d in 11..32 |
| **R2** | `exit(EXIT_FAILURE)` on user / dim errors so callers see non-zero status | 0.25 d | §3.2 | Correctness for shells, `test.sh`, GUI |
| **R3** | Auto-pick Legendre basis at high `n_approx` (e.g. n ≥ 10) and emit a warning when condition number of Gram matrix exceeds 10⁹ | 1 d | §3.4 — feature exists, never auto-selected | Reliability at high polynomial degree |
| **R4** | Deprecate `-g`: keep behind a `--debug-gramschmidt` flag, default-off | 0.1 d | §2.1 — 1000× slower with no correctness benefit | Removes a footgun, simplifies UX |
| **R5** | `--strict` flag promotes reflection-matrix warnings to errors; default still warns | 0.5 d | §3.3 | User control over correctness |
| **R6** | Library-mode (`libsrbm_finite.a`) so a future SBD-equivalent for finite buffers, or the GUI, can avoid the 25 ms popen cost | 1.5 d | §2.3 — not currently bottleneck, but pre-condition for in-process embedding | Unblocks GUI integration |
| **R7** | Self-consistency residual `‖A φ̂ − b‖∞` in `-v` output | 0.5 d | similar to QNA / BNAsm | Diagnostics |
| **R8** | Cache `compute_Af` results across multiple solver invocations on the same network (parameter sweep mode) | 1.5 d | not currently supported; would help users running ρ-sweeps | Sweep speedup |
| **R9** | Drop `MAX_TERMS = 10000` dead constant and the comments around it | 0.1 d | §3.7 | Code clarity |
| **R10** | Convergence-diagnostic mode: solve at n = 4, 6, 8 and report Δq per station; stop early when relative change < ε | 1 d | mirrors BNAsm R4 | Right-sizes the cost/accuracy trade |

### Engineering hygiene

- Move `g_compact`, `g_use_legendre`, `g_gui_mode` from globals to a `SolverOptions` struct passed through the call chain. Currently the printer-vs-solver coupling is invisible.
- The progress-file pattern (`srbm_progress_open`/`tick`/`close`) is duplicated verbatim from `bnet.c`. Extract into `common/bnet_progress.h` next time someone touches both.
- `srbm_solve` and `srbm_solve_suitesparse` are 90 % duplicate code (validation, multi-index gen, memcheck, Af compute, integral cache setup). Refactor into a shared frontend with a backend dispatch.

---

## 5. Suggested order of work

If you do nothing else: **R1 + R2**. R1 is the biggest scalability lift (d=10 → d=32 unlocks real multi-station finite-buffer analyses); R2 is a 15-minute correctness fix.

R3 (auto-Legendre) is the most leveraged accuracy improvement — currently the `-L` flag exists but no signal tells the user when to use it.

R6 (library mode) is the cross-cutting one with BNAsm's R7. Both spectral solvers are good candidates for in-process embedding; doing them together once means the same `libspectral.a` interface for orthant and hypercube cases.

---

## 6. Test plan when changes land

- R1: feed d=15 input — pre-fix exits with "Invalid dimension"; post-fix runs and produces means within 1e-9 of a hand-derived 15-station tandem product-form bound.
- R2: deliberately bad input (d=11 or missing `n_approx`) — pre-fix `echo $?` shows 0; post-fix shows non-zero.
- R3: synthetic case with high cond-number Gram (e.g. d=2 n=14 stretched hypercube) — pre-fix produces NaN/garbage at high n; post-fix automatically uses Legendre and converges.
- R4: `srbm_solver -g` prints "deprecated, use --debug-gramschmidt" and exits with usage hint.
