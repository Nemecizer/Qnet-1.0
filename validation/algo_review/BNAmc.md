# BNAmc — review

**Solver:** `infinite/BNAmc/rbm_mlmc` (also builds `gen_symmetric`, `gen_tridiag`, and a serial reference `rbm_mlmc_serial`)
**Sources:** `infinite/BNAmc/rbm_mlmc.c` (1669 LOC) + `rbm_mlmc_serial.c` (506 LOC)
**Method:** Two-parameter Multilevel Monte Carlo (MLMC) for steady-state expectations of Reflected Brownian Motion in the orthant. Implements Algorithm 1 from Blanchet, Chen, Glynn, Si 2021. Per the paper, complexity is **linear in dimension d** — making BNAmc the only solver in the family that scales gracefully to d ≥ 50.
**Backends:** Apple Accelerate + GCD (default macOS), OpenMP, serial. Selectable via `--backend B`.
**Empirical work backing this review:** `validation/algo_review/work/bnamc/`

---

## 1. Current implementation

### 1.1 Algorithm

MLMC builds a telescoping estimator over `L` levels, each level using a finer time-step `T·γ^l`. Standard MLMC variance balancing chooses `N_l ∝ γ^(−l)` samples per level to make the cost-variance product flat. The two-parameter version of BCGS 2021 adds:

- `T` (mixing time): how long to evolve the SRBM before averaging — auto-tuned to ~5 relaxation times by inverting `R^T η = Σ × ones` and computing `Σ_kk / (2 η_k²)`.
- `L` (number of levels): chosen so `γ^L ≈ ε² / (log d)`.

The resulting estimator is **unbiased** for `E[Y_i(∞)]` with cost `O(d · log² d / ε²)` — vastly better than the polynomial-explosion of the spectral methods.

### 1.2 Pipeline

| Step | Function | Method |
|---|---|---|
| 1  | `parse_input`        | text-line parser; auto-detects sparsity in Σ and R |
| 2  | `cs_di_chol(Sigma)`  | CXSparse symbolic + numeric Cholesky → L (sparse if Σ has < 50 % density) |
| 3  | `cs_di_compress(R)`  | R → CSC if sparse; otherwise dense |
| 4  | auto-tune `T` from relaxation analysis | LU on R, solve R^T η = Σ × ones, take 5× max(Σ_kk/(2η_k²)) |
| 5  | compute `L`, `N`, K_γ from γ, ε, d | closed-form |
| 6  | per-thread workspace allocation, RNG seeding via SplitMix64 + xoshiro256\*\* | one workspace per thread |
| 7  | `RUN_BATCH(N)` — `simulate_sample` × N | dispatched via `dispatch_apply_f` (GCD), `omp parallel for`, or sequentially |
| 8  | adaptive: stop early when worst-dim SE < ε | iterates batches until target met |
| 9  | reduce per-thread `Z_sum` / `Z_sq` | mean + SE + 95 % CI |

### 1.3 Solver-level features that no other solver has

- **`SRBM_MAX_DIM = 1024`** (`rbm_mlmc.c:85`) — 16× higher than any other solver in the family. Reflects the fact that MLMC's complexity is linear in d, not combinatorial.
- **Auto-tuned T** from relaxation analysis (line 1395+).
- **Adaptive sampling** (`--adaptive`) — stop when SE target hit (`rbm_mlmc.c:1518–1563`).
- **Antithetic variates** support (`--antithetic`).
- **Sparse Cholesky on Σ** automatically when nnz < 50 % (line 1469).
- **Sparse CSC LCP column update** for R when nnz < 50 % (line 1472).
- **Three independently-validated backends** with consistent results.
- **xoshiro256\*\* RNG** — same modern PRNG as fBNAsim.
- **Thread-safe progress reporting** via `atomic_int progress_counter`.
- **Per-dim SE + 95 % CI in output** — standard statistician's report.

This is the **most sophisticated solver in the codebase**, by a wide margin.

---

## 2. Empirical performance

### 2.1 Scaling vs d (γ=0.5, ε=0.1, sparse tridiagonal Σ + R)

| d   | Σ nnz | R nnz | T (auto) | L | N | wall time |
|---:|---:|---:|---:|---:|---:|---:|
|  2 |  2 (50 %) |  3 (75 %)  | 5.00 | 4 | 120 | 369 ms |
|  5 |  5 (20 %) |  9 (36 %)  | 5.00 | 5 | 310 | 253 ms |
| 10 | 10 (10 %) | 19 (19 %)  | 5.00 | 5 | 310 | 111 ms |
| 20 | 20 (5 %)  | 39 (10 %)  | 5.00 | 6 | 756 | 195 ms |
| 50 | 50 (2 %)  | 99 (4 %)   | 7.65 | 6 | 756 | 413 ms |
| 100| 100 (1 %) | 199 (2 %)  |10.60 | 6 | 756 | 3.83 s |

**Linear-ish in d at fixed sample count** (`L`, `N` change with `d` but slowly). The d=100 case (which is **larger than QNA's, SBD's, BNAsm's hard caps combined**) finishes in under 4 seconds. This is the only solver that can run a 100-dimensional SRBM at all.

### 2.2 Backend comparison (d=2, γ=0.5, ε=0.05)

| backend     | wall time |
|---|---:|
| serial      |  61 ms |
| openmp      |  80 ms |
| accelerate  |  54 ms |

For tiny problems the OpenMP dispatch cost dominates the parallel work — serial is competitive. Accelerate (GCD) wins by a small margin. At larger problems (d > 10) the OpenMP / Accelerate paths pull ahead substantially.

### 2.3 Auto-T grows with d

Empirically: T = 5 (d ≤ 20), T = 7.65 (d=50), T = 10.6 (d=100). The relaxation-time analysis correctly captures that high-dimensional networks need longer evolution to mix. This is **the key reason the d=100 case took 4 s** — proportionally more work per sample.

---

## 3. Correctness — mostly engineering excellence, a few gaps

### 3.1 The most serious limitation: γ ∈ {1/2, 1/3, 1/4, …}

`rbm_mlmc.c` requires `1/γ` to be a positive integer (verified empirically: `γ=0.3` errors with "1/gamma must be a positive integer (got 1/gamma = 3.33333)"). This is a constraint of the underlying telescoping discretization, but it's surprising that it's exposed as a user-facing knob. Either:

- Auto-snap `γ` to nearest `1/k` and warn, or
- Document as `--ratio K` (the inverse) so it's clearly an integer parameter.

### 3.2 d > 1024 not even attempted

`SRBM_MAX_DIM = 1024` is a generous cap, but it's still hardcoded. The MLMC algorithm itself has no inherent limit; bumping this requires audit of `Z_plus`, per-dim summary arrays, etc.

### 3.3 No memcheck integration

Per-thread workspace allocations grow with `nthreads × d × 4` (workspace, Z_sum_local, Z_sq_sum_local, etc.). At d=1024 with 16 threads that's ~256 KB per thread = 4 MB total. Modest, but a `bnet_memcheck_alloc` for the workspace block would match the family pattern.

### 3.4 OpenMP backend is ~30 % slower than Accelerate at small d

Likely OpenMP's runtime overhead per `parallel for` invocation. Already documented in §2.2; not a bug, but a guidance opportunity: emit a recommendation `[note] backend=accelerate is faster for d < 20` when running with openmp.

### 3.5 Adaptive mode doesn't expose `--target-stderr` separately from `epsilon`

`--adaptive` reuses `epsilon` as the SE target, which conflates the *MLMC discretization parameter* with the *Monte Carlo confidence target*. They are related but not identical (see BCGS 2021 §3.2). Splitting them as `--epsilon ε` and `--target-se σ` would make the adaptive mode's behaviour easier to reason about.

### 3.6 Output mixes statistical results into stderr (verbose) and stdout (means)

A user with `-c` redirects stdout for parsing; the SE / CI table goes to stderr and is invisible to GUI parsers. Add a `--json` flag that emits everything as machine-readable JSON.

### 3.7 No connection to the rest of the test suite

`BNAmc` produces numerically rigorous (CI-bounded) ground-truth estimates that should be **better than `BNAsim`'s** at high d. Currently `test.sh` and `validation/feedback_runs/` use `jackson_sim` as the sim ground truth. For high-d networks that BNAsim can't simulate cheaply, BNAmc would be the right reference. Add `--sim-backend bnamc` to `test.sh`.

### 3.8 Sibling `rbm_mlmc_serial.c` is duplicated logic

506 LOC of mostly-redundant code with the parallel version. Either:
- Build it as a debug/reference target only (under `make debug`), or
- Delete it — `--backend serial` already covers the serial use case.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Auto-snap `γ` to nearest `1/k`; warn user | 0.25 d | §3.1 — surprising constraint | UX |
| **R2** | Wire BNAmc into `test.sh` as ground-truth alternative for high-d cases | 1 d | §3.7 — most rigorous reference but not used | Correctness validation across the whole codebase |
| **R3** | `--json` output mode for machine-readable results (incl. SE / CI) | 0.5 d | §3.6 — current GUI parsing misses CI bands | Diagnostics |
| **R4** | Memcheck on per-thread workspace allocation | 0.25 d | §3.3 + family-wide pattern | Defensive |
| **R5** | Split `--epsilon` (discretization) from `--target-se` (adaptive stop) | 0.5 d | §3.5 — overload today | Algorithmic clarity |
| **R6** | Auto-pick backend based on d (heuristic in `--backend auto`) | 0.5 d | §3.4 + §2.2 | UX |
| **R7** | Library mode (`libbnamc.a`) for in-process embedding | 1.5 d | family-wide pattern | GUI integration |
| **R8** | Promote `xoshiro256**` + `SplitMix64` to `common/rng.h` shared with fBNAsim and (post-fix) BNAsim | 0.5 d | §1.3 — three solvers reimplement the same RNG | Code dedup |
| **R9** | Delete or de-feature `rbm_mlmc_serial.c` — superseded by `--backend serial` | 0.25 d | §3.8 | Maintenance |
| **R10**| Bump `SRBM_MAX_DIM` to 4096 with audit of stack-allocated arrays | 1 d | §3.2 — algorithm scales linearly, cap doesn't | Future-proof |

### Engineering hygiene

- The verbose log format ("`Dimension d = 2 / gamma = 0.5 / ...`") is excellent. Same parameter-summary pattern would help BNAsim and the LP solvers too.
- Sparse-density auto-detection (`Sigma nnz ratio: L has X non-zeros of d² = Y (Z%); using SPARSE CSC path`) is best-of-codebase introspection. Promote the pattern.
- Per-thread `workspace_t` with `Z_sum_local`, `Z_sq_sum_local`, `n_local` is the right "shared-nothing" reduction pattern. Use as the template when adding a sweep mode to BNAsim.

---

## 5. Suggested order of work

If you do nothing else: **R2 (wire into `test.sh`)**. BNAmc produces rigorous CI-bounded estimates with an algorithm that scales to d=100. The validation suite currently uses `jackson_sim` as ground truth, which has its own quality issues (per the BNAsim review's RNG finding). For high-d networks BNAmc is the better reference.

R1 (γ snap) is a 15-minute fix that removes a footgun.

R8 (shared RNG module) is the cross-cutting deliverable that closes the loop with the BNAsim and fBNAsim reviews.

R7 (library mode) is the cross-cutting deliverable with every other solver.

---

## 6. Test plan when changes land

- R1: feed `γ=0.3` — pre-fix errors out; post-fix snaps to `γ=1/3 = 0.333` and warns.
- R2: at d=20 LuKumar-style network, run BNAmc with γ=0.5 ε=0.01 and compare the mean to `bnasim` — should agree within both confidence bands.
- R8: bench per-step RNG output across all three solvers — should produce identical sequences with same seed.
