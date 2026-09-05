# BNAlp — review

**Solver:** `infinite/BNAlp/srbm_lp`
**Sources:** `infinite/BNAlp/src/{main.c, srbm_*.c, srbm_*.h}` (~3 KLOC C, multi-file, C11)
**Method:** Linear-programming relaxation for the stationary distribution of an SRBM in the orthant. Implements Saure-Glynn-Zeevi 2008. Discretizes the state space on a tensor grid, parameterizes the distribution by a linear combination of basis functions, and solves an LP with one inequality per basis function (BAR — Basic Adjoint Relationship) plus normalization, finiteness, and tightness constraints. Smoothness regularization (TV(λ)) is optional.
**Backends:** HiGHS (default, ships with the app), CPLEX (developer machines), GLPK (alternate open-source). Selectable via `--solver name`.
**Empirical work backing this review:** `validation/algo_review/work/bnalp/`

---

## 1. Current implementation

### 1.1 Pipeline

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 1 | `srbm_params_parse`           | srbm_params.c | line-keyword reader | O(d²) |
| 2 | `srbm_grid_build`             | srbm_grid.c | tensor grid (`exponential` / `dyadic` / `exprandom`) | O(n^d) |
| 3 | `srbm_index_build`            | srbm_index.c | enumerate `1 ≤ |α| ≤ m` | O(n_basis) |
| 4 | `srbm_basis_init`             | srbm_basis.c | precompute basis-function tensor | O(n_basis · d) |
| 5 | `srbm_eval_interior`          | srbm_eval.c | evaluate V[grid][basis] | O(n^d · n_basis) |
| 6 | `srbm_eval_boundary`          | srbm_eval.c | evaluate D[k][bdy_pt][basis] | O(d · n^(d-1) · n_basis) |
| 7 | `srbm_build_lp`               | srbm_build.c | assemble LP in COO with relative-tolerance gate, convert to CSC | O(n_basis · n^d) |
| 8 | `srbm_solve_*` (HiGHS / CPLEX / GLPK) | dispatch via `srbm_solver_backend_t` vtable | LP solve | depends on backend |
| 9 | `srbm_output_write`           | srbm_output.c | per-coordinate marginal CSV + first-moment summary | O(n^d) |

### 1.2 Solver vtable

`srbm_types.h:114`:

```c
typedef struct srbm_solver_backend {
    const char *name;
    int  (*init)(void);
    int  (*solve)(const srbm_lp_t *lp, srbm_solution_t *sol);
    void (*cleanup)(void);
} srbm_solver_backend_t;
```

Three backends register at compile time. Mature pattern; arbitrary new backends (Mosek, Gurobi, …) plug in via the same interface. Linker flags `make SOLVERS="cplex glpk highs"` or any subset.

### 1.3 Network-sparsity gate (already best-practice)

`srbm_build.c:188`:

```c
#define SRBM_COO_ABS_EPS  1e-14
double tol = SRBM_COO_ABS_EPS * (row_max > 1.0 ? row_max : 1.0);
...
if (fabs(v) > tol) srbm_coo_push(&coo, i, j, v);
```

Per-row relative tolerance to skip floating-point noise in the BAR coefficients. Comment specifically calls out the case for tandem / banded reflection where many coefficients are mathematically zero but show up as `~1e-16`. Without this gate, the LP is bloated with bogus near-zero entries that CPLEX-style presolve has to chew through. Best-of-codebase preprocessing.

### 1.4 Smoothness regularization

`srbm_types.h:27`: `smoothness_weight` adds an L1 penalty on the discrete TV(λ) (lex-2 in the paper, eq. 18 / §6.3). Disabled by default. Per-edge `h_e`-weighted slack variables (`srbm_build.c:306–360`) so the regularizer approximates `∫|∇λ|` rather than raw TV — grid-spacing aware, important for exponential grids where edges near the origin are O(1/n) and edges in the tail are O(1).

---

## 2. Empirical performance

### 2.1 Scaling vs. grid_n (d=2, default `basis_m = 6`)

`work/bnalp/`:

| grid_n | wall time | grid points |
|---:|---:|---:|
|  50 |  158 ms |  2 500 |
| 100 |  843 ms | 10 000 |
| 200 |  2.77 s | 40 000 |
| 400 | 13.1 s  | 160 000 |

Scaling is roughly cubic in `grid_n`: O(n^d · n_basis · LP_solve). At d=2 grid_n=400 the LP has 160 K columns and ~84 (= 2 · 28 · 1.5) K rows; HiGHS solves it in 13 s.

### 2.2 Scaling vs. basis_m (d=2, `grid_n = 100`)

| basis_m | n_basis | wall time |
|---:|---:|---:|
|  4 |  14 |  213 ms |
|  6 |  27 |  497 ms |
|  8 |  44 | 1.12 s  |
| 10 |  65 |  4.1 s  |
| 12 |  90 |  6.5 s  |

Roughly linear in `n_basis` (LP rows scale with `n_basis`). At higher m the LP solve dominates because more BAR constraints get tight.

### 2.3 Bundled examples

| Example | wall time |
|---|---:|
| `example1.txt` (Harrison 2D, n=100, m=6) | 1.0 s |
| `example2_sym.txt` (symmetric)            | 0.5 s |
| `example3_skew.txt` (skew)                | 0.7 s |
| `test_suite/11_symmetric_3d_r0p30_rhop0p0` | 0.07 s |

The 3D test runs faster than the 2D — likely because grid_n is smaller in the 3D test (10^3 = 1000 grid points vs 100^2 = 10000).

### 2.4 The hard cap is `SRBM_MAX_DIM = 10`

`srbm_types.h:8`: `#define SRBM_MAX_DIM 10`. Same as fBNAsm. Going past it returns `Invalid dimension d=N (must be 1..10)` — and exits with status **0** (same family-wide bug).

The cap is binding because `n^d` grid points is the actual ceiling: at d=5 grid_n=20 → 3.2 M grid points, LP has ~6.4 M cols. At d=10 grid_n=4 → 1 M cols, but the basis tightness degrades. The cap is where the LP becomes practical.

---

## 3. Correctness — bugs & footguns

### 3.1 No memcheck integration

Unlike BNAsm, fBNAsm, fBNAfm — which all use `common/bnet_memcheck.h` — BNAlp has no pre-flight RAM check. The dominant allocations are:

- `V` matrix: `n^d · n_basis` doubles
- `D[k]` matrices: `d · n^(d-1) · n_basis` doubles
- LP CSC arrays: `~n_basis · n^d` doubles for non-zeros

At d=4 grid_n=100 m=8 the LP would need `n_basis * n^d * 8B ≈ 44 · 10^8 · 8 = 35 GB`. Currently the binary just calls `malloc`, gets ENOMEM, and aborts — or worse, the OS swaps and locks the machine.

**Fix:** add `bnet_memcheck_alloc(...)` calls before each large allocation. Same pattern as BNAsm/fBNAsm/fBNAfm. ~10 LOC, half-day total.

### 3.2 `exit(0)` on parse errors

Same family-wide pattern: invalid `d`, missing required field, parse failure all exit with status 0. Run Comparison can't detect them.

### 3.3 No backend-fallback chain

`--solver glpk` on a system without GLPK linked produces "solver glpk not available, exiting" — but doesn't try the other backends. Auto-fallback `--solver auto` (try first available in priority order) would be friendlier.

### 3.4 Smoothness weight has no auto-tune

`smoothness_weight = 0` by default, `--smoothness-weight WEIGHT` to enable. The paper recommends tuning per problem; there's no built-in cross-validation or sensitivity scan. A `--auto-smoothness` mode that runs at weights 0, 0.01, 0.1, 1 and reports the L1 reconstruction residual would let users find a good weight without manual sweeps.

### 3.5 Auto-grid spacing is implicit

The verbose output shows `Auto rho = 2.0000 2.0000 / Effective grid_spacing (rho/4) = 0.5000 0.5000`. The "auto-rho" formula `rho = -R^{-1} mu` is implemented in `srbm_grid.c` but not documented in the input format help. Users who want to override it must know the keyword `mu_grid` and an empirically-good value.

### 3.6 Output CSVs go to cwd

`srbm_output.c` writes `srbm_out_distribution.csv`, `srbm_out_marginal_<k>.csv` to the current working directory by default. When SBD-style fork chains call `srbm_lp` with cwd elsewhere, these CSVs land in unexpected places — same kind of footgun as SBD's relative `bnet` path. Use `--output PREFIX` to control, but that's not surfaced in error messages.

### 3.7 `srbm_solve_glpk.c` smaller than the others

123 LOC vs HiGHS's 132 and CPLEX's 182. Inspection suggests GLPK path doesn't expose the same options (presolve thresholds, time limits). Worth a parity audit when adopting GLPK as a fallback.

### 3.8 No residual / dual-feasibility check post-solve

After LP solve, `srbm_output.c` prints first moments without verifying the LP solution's primal residual `‖A x - b‖∞` or the duality gap. The HiGHS / CPLEX / GLPK solvers report these, but the solver dispatch swallows them. Add a `--report-residual` flag for users to validate borderline cases.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Integrate `bnet_memcheck_alloc` before V, D[], LP CSC allocations | 0.5 d | §3.1 — only solver in the family without it | Prevents OOM-thrash on misconfigured runs |
| **R2** | `exit(EXIT_FAILURE)` on parse / dim errors | 0.25 d | §3.2 | Correctness contract |
| **R3** | `--solver auto` fallback chain (highs → cplex → glpk → first available) | 0.5 d | §3.3 | UX |
| **R4** | `--auto-smoothness` cross-validation mode | 1.5 d | §3.4 — currently zero guidance for the most accuracy-relevant knob | Right-sizes regularization |
| **R5** | Use `--output` prefix relative to input file directory by default; document in help | 0.25 d | §3.6 | Avoids cwd-dependent footgun |
| **R6** | `--report-residual` post-solve metrics | 0.5 d | §3.8 | Diagnostics |
| **R7** | Extend GLPK path to expose the same options as HiGHS / CPLEX | 1 d | §3.7 | Backend parity |
| **R8** | Document the input format more thoroughly; emit sample with all keywords as `--print-template` | 0.5 d | §3.5 | Discoverability |
| **R9** | Convergence-study mode `--converge`: solve at grid_n = 50, 100, 200; report Δ E[X_k] | 1 d | mirrors family-wide pattern | Right-sizes grid_n |
| **R10**| Library mode (`libsrbmlp.a`) for in-process embedding | 1.5 d | mirrors family-wide R7 | GUI integration |

### Engineering hygiene

- The verbose log (`[Parse] 0.000 s` / `[Grid] 10000 points, 0.001 s` / etc.) is a great template for the rest of the family — port the per-step timing pattern back to BNAsm and the others.
- LP CSC conversion (`srbm_coo_to_csc`) handles duplicate-merging implicitly via `lp->nnz = lp->col_start[ncols]` after conversion. Worth a comment about when duplicates can arise (the boundary tightness loop emits one row per face — guaranteed unique per (row, col) pair, but a future change might break this assumption).
- `srbm_solver_list` (`--list-solvers`) is a friendly UX touch absent from the other solvers — add equivalent `--list-bases`, `--list-grid-types` for completeness.

---

## 5. Suggested order of work

If you do nothing else: **R1 + R2**. R1 is the consistency win — every other solver in the family has memcheck except this one. R2 closes the family-wide exit-code bug.

R3 + R4 are user-facing UX wins for the LP-method-specific knobs (backend fallback, smoothness regularization tuning).

R10 (library mode) is the cross-cutting deliverable with BNAsm / fBNAsm / fBNAfm.

---

## 6. Test plan when changes land

- R1: feed d=4 grid_n=100 m=8 input — pre-fix swaps the machine; post-fix exits with the standard memcheck message.
- R2: invalid dimension input — pre-fix `echo $?` shows 0; post-fix shows non-zero.
- R3: build with `SOLVERS=glpk` only, run `--solver auto` — should pick GLPK.
- R4: on `example1.txt`, run `--auto-smoothness` and confirm the suggested weight gives a smaller marginal-density TV without changing the first moment by more than 0.5 %.
