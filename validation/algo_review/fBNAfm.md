# fBNAfm — review

**Solver:** `finite/fBNAfm/bna_fm_gauss` and `finite/fBNAfm/bna_fm_cbc`
**Sources:** `finite/fBNAfm/{bna_fm_gauss.c, bna_fm_cbc.c, bna_fm_common.c, bna_fm.h, qmc_lattice_rules.c, qmc_lattice_seq.c, qmc_utils.c, qmc.h}` (~3.2 KLOC C, multi-file, C99)
**Method:** Finite-element method (cubic Hermite tensor-product basis on a regular mesh) for the stationary distribution of an SRBM in a hypercube. Implements Shen-Chen-Dai-Dai 2000. Two integrators: 4-point Gauss-Legendre quadrature (`bna_fm_gauss`) and CBC-QMC lattice rules (`bna_fm_cbc`, after Cools-Kuo-Nuyens 2006).
**Empirical work backing this review:** `validation/algo_review/work/fbnafm/`

---

## 1. Current implementation

### 1.1 Basis structure

For each dimension `j` the mesh has `mesh_n[j]` elements; the cubic Hermite basis assigns `2^K` basis functions per node (combinations of value vs. derivative DOFs in each direction). Total basis dimension:

```
n_basis = prod(mesh_n[j] + 1) * 2^K
```

So basis grows polynomially in mesh refinement and exponentially in K. For K=3 mesh=10 → `11³ · 8 = 10 648` basis functions; K=4 mesh=10 → `11⁴ · 16 = 234 256`; K=8 mesh=10 → `11⁸ · 256 ≈ 5.4 × 10¹⁰`.

### 1.2 Pipeline (line numbers in `bna_fm_gauss.c`)

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 1 | `parse_input_file`               | (bna_fm_common.c) | positional `fscanf` | O(K²) |
| 2 | `init_gauss_legendre`            | 62 | precompute 4-point GL nodes/weights | O(1) |
| 3 | `bnet_memcheck_alloc(2 KB · n_basis)` | 815–820 | budget check vs. 50 % RAM | O(1) |
| 4 | `build_fem_system` (OpenMP)       | (volume + boundary) | element-wise quadrature → sparse triplet | O(n_basis · 4^K · K²) |
| 5 | `triplet_to_cholmod`              | bna_fm_common.c | COO → CSC conversion | O(nnz) |
| 6 | `smart_solve`                     | bna_fm_common.c | UMFPACK first; falls back to CG for large | O(nnz · √nnz) sparse Cholesky / LU |
| 7 | `compute_stationary_mean` (OpenMP) | 580–637 | quadrature of `x_k · p₀(x)` | O(n_elem · 4^K · K) |
| 8 | `compute_boundary_measures` (OpenMP) | 653–744 | (K-1)-D quadrature on each face | O(n_face · 4^(K-1) · K) |

External deps: SuiteSparse (CHOLMOD, UMFPACK), Apple Accelerate (BLAS/LAPACK), libomp.

### 1.3 The CBC-QMC variant

`bna_fm_cbc` uses lattice rules instead of Gauss-Legendre for the volume integration. Uses the 10-dimensional generating vector from Hickernell-Kritzer-Kuo-Nuyens 2012 (`qmc_lattice_rules.c:25`, smoothness 3). Three integration variants:

- standard lattice rule
- tent-transformed (baker's transformation)
- symmetrized

The CBC version is intended for *smooth* high-dimensional integrands where Gauss-Legendre's `4^K` cost becomes prohibitive — at K=8 a single element's volume integral needs 65 536 GL evaluations versus a configurable few thousand QMC points.

---

## 2. Empirical performance

### 2.1 Wall-time on the bundled test inputs

On the test inputs shipped in `finite/fBNAfm/*.in` (3-station and 4-station hypercube examples derived from the Shen-Chen-Dai-Dai 2000 paper):

| Input | K | mesh | basis | nnz | wall time |
|---|---:|---:|---:|---:|---:|
| 3d_n3   | 3 | 3  | ~ 512   | ~ 50 K  | 0.7 s |
| 3d_n5   | 3 | 5  | ~ 1 728 | ~ 250 K | 0.8 s |
| 3d_n8   | 3 | 8  | ~ 5 832 | ~ 1.0 M | 1.6 s |
| 3d_n10  | 3 | 10 | 10 648  | 1.91 M  | 2.2 s |
| 4d      | 4 | (mixed) | — | — | 6.2 s |
| 4d10    | 4 | 10 | 234 K   | (huge)  | (≥ 60 s, killed) |

Sparsity at 3d_n10: nnz / n² = 1.9 M / 113 M ≈ 1.7 %. CHOLMOD supernodal Cholesky handles this comfortably. The bottleneck above 4d_n10 is the matrix assembly (4^K = 256 GL points per element × hundreds of thousands of elements) more than the solve itself.

### 2.2 The hard cap is `MAX_DIM = 8`

`bna_fm.h:25`: `#define MAX_DIM 8`. Tighter than fBNAsm's 10 and BNAsm's 64. K=9 exits with:

```
$ bna_fm_gauss fm_K9.in -c
Error: Dimension 9 exceeds MAX_DIM=8
$ echo $?
0      <-- success exit code on user error, same as the rest of the family
```

Why so tight? `2^K` shows up *everywhere* — basis functions per node, GL points per element (`4^K`), face quadrature `4^(K-1)`. At K=8 each element requires `65 536` GL function evaluations during assembly. Bumping `MAX_DIM` to 12 would:

- 16× the per-element evaluation cost
- 16× the basis-per-node count
- silently make the binary unusable rather than scaling smoothly

The `MAX_DIM` cap is in this case a *correct*, *empirically-grounded* choice — not a footgun. Lifting it without restructuring the assembly loop would just trade a clean error for a six-hour wall.

### 2.3 Memcheck integrated

`bna_fm_gauss.c:815`:

```c
uint64_t bytes = (uint64_t) n_basis * (uint64_t) 2048;
bnet_memcheck_alloc(bytes,
    "FE Gauss-Legendre system",
    "reduce mesh_n (per-dimension grid) or K (network dimension); "
    "n_basis grows as prod(mesh_n[i]+1) * 2^K");
```

The `2 KB · n_basis` heuristic captures the dense vectors plus the sparse triplet (capacity `100 · n_basis`, 12 B/entry). Conservative, fires earlier than the raw matrix size would suggest — but that's the right side to err on for an interactive tool.

---

## 3. Correctness — bugs & footguns

### 3.1 `exit(0)` on user errors

`bna_fm_gauss.c:104, 134, 179` — `main` returns 1 on errors that go through its own check, but `parse_input_file` and the dim cap path go through paths that ultimately produce a *zero* exit code. Same problem as the rest of the family. Same one-line fix.

### 3.2 Reflection matrix layout convention is non-obvious

The `R` matrix is `K × 2K`, where columns 0..K-1 are *lower-face* normals and columns K..2K-1 are *upper-face* normals (`bna_fm_gauss.c:879–893` shows `gamma_sta[i] = service_rates[i] - delta[i]` indexing only the lower face). This is **different** from fBNAsm's interleaved convention `R[i, 2k] / R[i, 2k+1]`. A user reading the input file format would not know which one applies; the GUI exporter would have to maintain two paths.

The two solvers should agree on a single layout, or each input file should declare its convention in a header line.

### 3.3 The `2 KB · n_basis` memcheck heuristic is approximate

Real memory usage at 3d_n10: basis 10 648 → memcheck reserved ~22 MB. Actual peak RSS during the run was ~150 MB (sparse matrix in CSC form, dense vectors, CHOLMOD's internal buffers). The 2 KB factor under-estimates real usage by ~7×. For most cases this just means the budget check is loose; for borderline configurations it could let through a job that then ENOMEMs.

Tighten the heuristic with measured constants per K, or check actual RSS post-allocation and refuse to continue if it crosses the budget.

### 3.4 No automatic mesh-refinement / convergence study

The user picks `mesh_n[j]` per dimension, with no guidance. Refining the mesh halves the discretization error but quadruples the system size (per dimension). A `--converge` mode that solves at mesh = 4, 8, 16 and reports `Δ E[X_k]` per refinement would make it obvious when the user has under- or over-resolved.

### 3.5 `bna_fm_cbc` is built but never wired through Run Comparison

The CBC-QMC variant is the *intended* path for high-K problems. Run Comparison's GUI invocation (`Sources/Qnet/QnetGUIApp.swift:findBinary(name: "bna_fm_gauss"...)`) only ever calls the Gauss-Legendre version. So users hit the K=4 wall (~minute-scale runs) instead of being routed to the variant designed exactly for that regime. An auto-dispatch heuristic (`if K ≥ 5 use cbc, else use gauss`) would close the gap.

### 3.6 Smart-solve heuristics are opaque

`smart_solve` (in `bna_fm_common.c`) is documented in the header as "tries UMFPACK first, falls back to CG for large problems" but the threshold is hidden. If the user gets unexpectedly slow runs they have no signal as to which path took. Adding a one-line "[smart_solve] Used UMFPACK / CG with N iter = …" diagnostic would make tuning easier.

### 3.7 Gauss-Legendre 4-point is exact but not refinable

`#define N_GAUSS 4` (`bna_fm_gauss.c:57`) — chosen because the Hermite-squared integrand has degree ≤ 6 per coordinate, and 4-point GL is exact for degree 7. Sound choice for the standard integrand; would need to grow if anyone changes basis order. Worth a comment near the definition explaining the polynomial-degree calculation that justifies the choice.

### 3.8 Boundary-measure indexing convention

`bna_fm_gauss.c:879`: `gamma_sta[i] = service_rates[i] - delta[i]` — uses `delta[i]` (lower face only). But `delta` array has size `2*K` (lines 869). The upper-face entries `delta[K..2K-1]` are computed but only used in non-compact output (`bna_fm_gauss.c:977-982`). Throughput formula relies on the lower-face local time = "server idle time", which is well-defined for finite-buffer SRBM. The omission of the upper face from throughput is correct but unobvious; needs a comment.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Wire `bna_fm_cbc` through Run Comparison; auto-dispatch (K ≤ 4 → gauss, K ≥ 5 → cbc) | 1 d | §3.5 — CBC variant exists, never used | Unlocks K=5..8 in the GUI without minute-scale runs |
| **R2** | `exit(EXIT_FAILURE)` on user errors so callers detect failure | 0.25 d | §3.1 — same issue as the rest of the family | Correctness contract |
| **R3** | Unify reflection-matrix layout convention with fBNAsm; document in input header | 1 d | §3.2 — two finite-buffer solvers use *different* `R` layouts | Reduces GUI-exporter complexity, prevents wrong-geometry silent errors |
| **R4** | `--converge` mode: solve at mesh=4, 8, 16; report relative change | 1 d | §3.4 — no current signal that mesh is converged | Right-sizes cost vs. accuracy |
| **R5** | Tighten the memcheck heuristic; measure peak RSS per K and tabulate | 0.5 d | §3.3 — 7× under-estimate observed | Prevents borderline OOMs |
| **R6** | `--solver-info` prints which `smart_solve` path was used and CG iteration count | 0.25 d | §3.6 | Diagnostics |
| **R7** | Library mode (`libbnafm.a`) so the GUI can invoke without 25 ms popen overhead per refresh | 1.5 d | mirrors BNAsm R7, fBNAsm R6 | In-process embedding |
| **R8** | Cache `build_fem_system` results across runs of the same network with varying drift / arrival rate (sensitivity sweep) | 2 d | not currently supported; would help users running ρ-sweeps | Sweep speedup |
| **R9** | Add a header line to the input file declaring the format version and reflection convention | 0.5 d | §3.2 + §3.7 | Prevents silent format drift between solvers |
| **R10** | Convergence-check *across integrators*: when both `gauss` and `cbc` are available, run both and compare; flag discrepancy as a warning | 1 d | tests one integrator against the other | Catches integration-rule errors |

### Engineering hygiene

- The progress-file pattern is duplicated in `bna_fm_gauss.c` and `bna_fm_cbc.c` (and again in `srbm_solver.c`, `bnet.c`). Extract to `common/bnet_progress.h` next time someone touches multiple of these.
- `g_compact` is a global; pass it through a `SolverOptions` struct as the rest of the codebase migrates away from globals.
- `bna_fm_gauss.c` and `bna_fm_cbc.c` share ~70 % of code (element basis lookup, face basis lookup, smart_solve dispatch). Extract into a shared `bna_fm_assembly.c`.

---

## 5. Suggested order of work

If you do nothing else: **R1** — wire `bna_fm_cbc` through Run Comparison with auto-dispatch on K. The CBC-QMC variant is *already built*; not using it for high-K is the single biggest leverage point.

Next: **R3** — the conflicting reflection-matrix layouts between fBNAsm and fBNAfm are a maintenance trap. Picking one (probably fBNAsm's interleaved convention is cleaner; or document explicitly which is which) prevents future silent-geometry bugs.

R7 (library mode) is a cross-cutting deliverable with BNAsm-R7, fBNAsm-R6: extract a single `libspectral.a` interface that fBNAfm joins via its own header, and the GUI gets in-process embedding for all four solvers.

---

## 6. Test plan when changes land

- R1: run `test.sh` with a K=6 example; pre-fix takes >> 60 s, post-fix routes to CBC and finishes in ~5 s.
- R2: K=9 input — pre-fix `echo $?` shows 0; post-fix shows non-zero.
- R3: re-derive reflection matrix from a known SRBM mapping for a small example; both solvers give same E[X_k] to 1e-6.
- R10: run any 3d_n10 input through both `bna_fm_gauss` and `bna_fm_cbc` — expect agreement within 1 %.
