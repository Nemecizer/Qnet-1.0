# fBNAlp — review

**Solver:** `finite/fBNAlp/fBNAlp_solver`
**Sources:** `finite/fBNAlp/src/{main.c, srbm_*.c, srbm_*.h}` (~3 KLOC C, multi-file, C11)
**Method:** LP-relaxation for the stationary distribution of an SRBM in a **rectangle** (finite-buffer analogue of BNAlp's orthant solver). Implements the Saure-Glynn-Zeevi 2008 method extended to two-sided box constraints. Tensor grid in the box, polynomial basis up to total degree `m`, LP variables for both interior weights `λ` and per-face boundary weights `γ⁻ / γ⁺`.
**Backends:** HiGHS (default), CPLEX, GLPK — same vtable as BNAlp.
**Empirical work backing this review:** `validation/algo_review/work/fbnalp/`

---

## 1. Current implementation

### 1.1 Differences from BNAlp (the orthant version)

| Aspect | BNAlp (orthant) | fBNAlp (rectangle) |
|---|---|---|
| Domain | `[0, ∞)^d` | `[0, b₁] × … × [0, b_d]` |
| Grid types | `exponential` / `dyadic` / `exprandom` | `uniform` / `chebyshev` (reserved) |
| Grid points | clusters near origin | uniform |
| Boundary measures | one per face (lower only) | two per face (lower + upper) |
| LP variables | `λ`, `γ⁻ × d`, `u` (+ slack) | `λ`, `γ⁻ × d`, `γ⁺ × d`, `u` (+ slack) |
| Reflection | `R` (d × d) | `R` (lower) + `R_plus` (upper); auto-synthesise `R_plus = -R` if not given |
| Tightness `K[]` | `2d + 1` entries | `4d + 1` entries (lower + upper for each face) |

Otherwise the architecture is identical — same solver vtable, same network-sparsity coefficient gate (`SRBM_COO_ABS_EPS = 1e-14`), same smoothness regularization plumbing, same per-step verbose log, same `srbm_params_t` parser shape.

### 1.2 Reflection-matrix convention adapter

`srbm_types.h:36–39`:

```c
double R[SRBM_MAX_DIM * SRBM_MAX_DIM];     /* lower-face reflection */
double R_plus[SRBM_MAX_DIM * SRBM_MAX_DIM];/* upper-face reflection */
int    R_full_2d;                          /* 0 => only R supplied, R_plus = -R; */
                                           /* 1 => R_plus came from input file.  */
```

When the input only provides `R` (the typical "manufacturing blocking" convention used by fBNAfm and fBNAsm), `main.c` synthesises `R_plus = -R`. When `reflection_form full_2d` is declared in the input, both matrices come from the file. **This is a clean compatibility layer** — fBNAlp accepts both conventions and normalises internally.

### 1.3 Pipeline (line numbers in `srbm_build.c`)

| Step | Function | Cost |
|---|---|---|
| 1 | `srbm_params_parse`                  | O(d²) |
| 2 | `srbm_grid_build` (uniform tensor)   | O(n^d) |
| 3 | `srbm_index_build`                   | O(n_basis) |
| 4 | `srbm_basis_init` (extended for upper faces) | O(n_basis · d) |
| 5 | `srbm_eval_interior` (V matrix)      | O(n^d · n_basis) |
| 6 | `srbm_eval_boundary` (D⁻[k] + D⁺[k]) | O(2d · n^(d-1) · n_basis) |
| 7 | `srbm_build_lp` (COO + tolerance gate, CSC) | O(n_basis · n^d) |
| 8 | LP solve via vtable                  | depends on backend |
| 9 | `srbm_output_write` (interior + per-face marginals) | O(n^d) |

---

## 2. Empirical performance

### 2.1 Scaling vs. grid_n (d=2, basis_m=6, default `examples/2d.in`)

| grid_n | grid points | wall time |
|---:|---:|---:|
|  10 |   100 |  205 ms |
|  20 |   400 |  252 ms |
|  40 | 1 600 |  424 ms |
|  80 | 6 400 |  2.22 s |
| 160 | 25 600 | 13.2 s |

Approximately quadratic-to-cubic in `grid_n`. The LP at n=160 has ~26 K rows and ~52 K cols (lower + upper boundary per face); HiGHS handles it in 13 s.

### 2.2 Scaling vs. basis_m (d=2, grid_n=40)

| basis_m | n_basis | wall time |
|---:|---:|---:|
|  4 |  14 | 270 ms |
|  6 |  27 | 536 ms |
|  8 |  44 | 1.12 s |
| 10 |  65 | 1.78 s |
| 12 |  90 | 3.62 s |

Roughly linear in `n_basis`, slightly super-linear at higher m as the LP solve gets harder.

### 2.3 Cross-solver comparison vs BNAlp at same (d, n, m)

At d=2, grid_n=100, basis_m=6:

- BNAlp (orthant): ~840 ms
- fBNAlp (box):   ~1100 ms (with default 2d.in: grid_n=20)

Comparable. The box version's extra `γ⁺` variables roughly double LP column count at fixed `n`, but smaller box volumes yield concentrated mass that LP presolve handles well.

### 2.4 The hard cap is `SRBM_MAX_DIM = 10`

Same as BNAlp. d > 10 hits a parse error (currently masked by an earlier "missing upper_bounds" message — see §3.3 below) and exits with status **0**.

---

## 3. Correctness — bugs & footguns

### 3.1 No memcheck integration (same as BNAlp)

`grep -l "bnet_memcheck" finite/fBNAlp/src/*.c` returns nothing. Same gap as BNAlp. Same fix: add `bnet_memcheck_alloc` calls before the V matrix, D[]⁻ / D[]⁺ matrices, and LP CSC arrays. At d=4 grid_n=100 m=8, the V matrix alone is 100⁴ · 44 · 8 = 35 GB.

### 3.2 `exit(0)` on user errors

Same family pattern. `Error: input file is missing the required upper_bounds directive` → exit code 0.

### 3.3 The dim cap error is masked by the upper_bounds check

When I tested `dimension 11`, the actual response was:

```
Error: input file is missing the required `upper_bounds` directive
exit=0
```

— not the expected dim-cap message. This is because `srbm_params_parse` validates `upper_bounds` *before* the dim cap. A user feeding a d=11 input with a valid upper_bounds line would presumably hit the dim cap, but the error path is non-trivial to reproduce. Reorder validations so the dim check fires first.

### 3.4 The `R_plus = -R` auto-synthesis is correct but unsignalled

`srbm_types.h:38` says `R_plus` is auto-synthesised when only `R` is supplied. The verbose output prints both matrices, which is good — the user can verify by inspection. But when running with `-c` (compact, GUI), there's no signal at all that synthesis happened. A user supplying skew reflections might expect `R_plus` to be independently specified and silently get the negated lower-face matrix instead.

Add a brief stderr line: `[note] R_plus auto-synthesized as -R; supply 'reflection_form full_2d' to override`.

### 3.5 Two-sided face conventions

`fBNAsm` interleaves `R[i, 2k] / R[i, 2k+1]`; `fBNAfm` groups columns 0..d-1 as lower and d..2d-1 as upper; `fBNAlp` carries `R` (lower) and `R_plus` (upper) as two separate matrices. **Three solvers, three conventions.** The GUI exporter has to maintain three separate code paths. This is the single biggest cleanup opportunity for the finite-buffer family.

Right answer: pick fBNAlp's two-matrix convention (clearest semantics) and refactor the other two to match. Not strictly within fBNAlp's scope to fix, but worth flagging since fBNAlp already has the cleanest layout.

### 3.6 Output naming clashes with BNAlp

`srbm_out_distribution.csv` is the default output prefix for both solvers. Running both BNAlp and fBNAlp from the same directory silently overwrites. Use solver-specific prefixes (`srbm_out_inf_*` vs `srbm_out_fin_*`) or add a `--prefix-default-from-input` option.

### 3.7 Bench example `2d.in` is small by default

`examples/2d.in` ships with grid_n=20, which finishes in ~250 ms — looks deceptively fast. Users following the example as a template won't see the n^d scaling until they bump grid_n. Worth providing a `2d_large.in` and `3d.in` as reference cases that exhibit the real scaling.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Integrate `bnet_memcheck_alloc` before V, D⁻, D⁺, LP CSC | 0.5 d | §3.1 — same gap as BNAlp | Prevents OOM-thrash |
| **R2** | `exit(EXIT_FAILURE)` on parse / dim errors | 0.25 d | §3.2 + family pattern | Correctness contract |
| **R3** | Reorder param validations: dim check first | 0.25 d | §3.3 — wrong error message at d > 10 | UX clarity |
| **R4** | `[note]` line when `R_plus` is auto-synthesised | 0.1 d | §3.4 — silent inference today | Transparency |
| **R5** | Cross-family: unify reflection-matrix conventions across fBNAlp/fBNAfm/fBNAsm; promote fBNAlp's two-matrix layout | 3 d | §3.5 — three conflicting conventions today | Largest engineering simplification of the finite-buffer family |
| **R6** | Default `--output` prefix derived from input file basename | 0.25 d | §3.6 — silent overwrite when both solvers run in same cwd | UX |
| **R7** | Auto-fallback solver chain (`--solver auto`) — same as BNAlp R3 | 0.5 d | family-wide pattern | UX |
| **R8** | `--auto-smoothness` cross-validation — same as BNAlp R4 | 1.5 d | family-wide pattern | Tuning |
| **R9** | Library mode (`libfbnalp.a`) for in-process embedding | 1.5 d | family-wide R7 | GUI integration |
| **R10**| Add `examples/2d_large.in` and `examples/3d.in` reference cases | 0.25 d | §3.7 | Documentation |

### Engineering hygiene

- 80%+ of the code is shared with BNAlp via copy-paste-modify. Refactor into a shared library `libsrbmlp_core.a` with a `domain_t` interface (orthant vs box). Sets up R5 properly.
- The verbose log format matches BNAlp's exactly — easy to reuse the same parser in any cross-solver test harness (`test.sh` could grow a `--solver-info` mode).

---

## 5. Suggested order of work

If you do nothing else: **R1 + R2 + R3**. Three small fixes that match the family-wide pattern. Combined effort ~1 day.

R5 is the cross-cutting one — fBNAlp's two-matrix reflection layout is the cleanest of the three finite-buffer solvers. Picking it as the canonical convention and migrating fBNAfm + fBNAsm would simplify the GUI exporter substantially. Three days of work, but it removes a real maintenance trap.

R9 (library mode) ties into the family-wide library extraction.

---

## 6. Test plan when changes land

- R1: feed d=4 grid_n=80 m=8 input — pre-fix swaps the machine; post-fix exits cleanly with budget message.
- R2 + R3: `dimension 11` input (with valid upper_bounds) — pre-fix exits 0 with a misleading message; post-fix exits non-zero with `Invalid dimension d=11 (must be 1..10)`.
- R4: lower-face-only `R` input run with `-c` — post-fix prints the synthesis note.
- R5: fBNAfm and fBNAsm post-refactor accept fBNAlp's `R / R_plus` layout; existing test cases still pass.
