# BNAsm — review

**Solver:** `infinite/BNAsm/bnet`
**Sources:** `infinite/BNAsm/{bnet.c, bnet.h, bnetio.c, index.c, suitesparse_compat.c}` (~2.5 KLOC C, multi-file)
**Method:** Spectral / orthogonal-polynomial Galerkin for the stationary distribution of a reflected Brownian motion (RBM) in the orthant. Implements Dai-Harrison 1992 / Dai's 1990 dissertation. Backed by SuiteSparse CHOLMOD + UMFPACK + Apple Accelerate (BLAS/LAPACK), parallelised with OpenMP.
**Empirical work backing this review:** `validation/algo_review/work/bnasm/`

---

## 1. Current implementation

The spectral method represents the stationary density `ρ(x)` as a polynomial of total degree `n` in `d` station-workload variables. The basis size is

```
N(d, n) = C(d + n, n) − 1     (basis polynomials)
```

so the dense Galerkin system matrix `A` has dimension `N × N`. The solver pipeline (line numbers from `bnet.c`):

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 2  | `get_dimension` / `get_drift` / `get_covariance` / `get_reflection` | 173–188 | `fscanf` | O(d²) |
| 3  | optional `customer_classes …` block | 192–228 | `fscanf` | O(K·d) |
| 4  | `ComputeC`, `ComputeIndex`, `ComputeIndex(d−1)` | 239–261 | binomial table + inverse-index | O(N) |
| 4½ | `bnet_memcheck_alloc(N²·8 B)` | 250–258 | RAM budget vs. dense matrix size | O(1) |
| 5  | `scaling` | 282–284 | normalise Γ, μ, R; compute γ_max | O(d²) + LU |
| 6  | `ComputeWeight` | 294–295 | `w[l][i] = i! / (2γ_l)^(i+1)` | O(d·n) |
| 7  | `Basis` (OpenMP `parallel for`) | 315 → 562 | construct each basis polynomial Aφ_i | O(N · d²) |
| 8  | `coefficient` (OpenMP) | 328 → 792 | dense N×N Galerkin matrix via `inner_2`; rhs `b` via `inner` | O(N² · d⁴)
| 9  | linear solve: CHOLMOD (default), or LAPACK LU `-l`, or built-in Cholesky `-b` | 347–401 | dense | O(N³) |
| 10 | `Density1` | 409 → 668 | recombine into stationary density polynomial | O(N · n) |
| 11 | `Output` | 418 → 314 | inner products to extract per-station means | O(N) |

External deps: SuiteSparse (CHOLMOD, UMFPACK, AMD/COLAMD, …), Apple Accelerate (BLAS/LAPACK), OpenMP via Homebrew `gcc-13`.

---

## 2. Empirical performance

### 2.1 Wall-time vs. (d, n) — scaling matches the C(d+n,n)² growth

Generated synthetic d-station tandems at ρ=0.7 across a degree-by-dimension grid (`work/bnasm/gen_bnet.py`):

| d \ n | 3 | 5 | 8 |
|---:|---:|---:|---:|
|  2 |  37 ms |  29 ms |  27 ms |
|  3 |  27 ms |  27 ms |  27 ms |
|  4 |  25 ms |  27 ms |  39 ms |
|  5 |  25 ms |  33 ms | 126 ms |
|  8 |  32 ms | 164 ms |  25.4 s |
| 10 |  35 ms | 1.18 s | 156 s |

Wall-time floor of ~25 ms is OpenMP runtime initialisation and process startup. Above d≈5 the time tracks `N(d,n)² ~ C(d+n,n)²`. d=10 n=8 has N = 43 757 basis polys; the dense matrix alone is 43 757² × 8 B = **15 GB**. The memcheck guard at line 250 saved this from OOM-thrashing — it allocated, ran in 156 s with peak RSS ≈ 1.7 GB after CHOLMOD did its sparse factorisation.

### 2.2 OpenMP scaling on d=8 n=8 (basis = 12 870)

| `OMP_NUM_THREADS` | wall time | speedup |
|---:|---:|---:|
| 1 | 93.8 s | 1.0× |
| 2 | 51.8 s | 1.8× |
| 4 | 33.4 s | 2.8× |
| 8 | 26.3 s | 3.6× |

OpenMP scaling is sub-linear: 8 threads give 3.6× because the assembly loop in `coefficient()` is memory-bound at large basis (matrix `A` is N² doubles = 1.3 GB at d=8 n=8). Once the matrix can't fit in L3, threads contend for memory bandwidth. This is a real ceiling — a smarter approach would compute `A` directly in sparse / blocked form, not as a dense matrix.

### 2.3 Cholesky vs LU vs built-in (d=5, n=5; basis = 251)

| Solver | Step 9 wall time | Notes |
|---|---:|---|
| CHOLMOD Cholesky (default)        | 37.6 ms | dense → triplet → factor → solve |
| LAPACK LU `-l`                    | 35.8 ms | direct dense via Accelerate |
| built-in Cholesky `-b`            | 29.9 ms | hand-rolled gaxpy form |

At small N the SuiteSparse triplet-conversion overhead (`suitesparse_compat.c:198`) is comparable to the factorisation itself, so the built-in path wins. The CHOLMOD advantage only kicks in at large N where the sparse pattern has slack to exploit (it's not currently exploited — the matrix is fed dense → CHOLMOD reconstructs the same sparse pattern from scratch). See R5 below.

---

## 3. Empirical correctness — bugs already fixed, footguns still present

### 3.1 Defensive guard rails (good — already present)

Three things are well done relative to the rest of the codebase:

- **`bnet_memcheck_alloc`** (`bnet.c:257`, header `common/bnet_memcheck.h`) checks every dense-matrix allocation against `min(BNET_MAX_BYTES env, 50 % of physical RAM)`. Prevents the d=20 n=8 case (76 TB matrix) from locking the user's machine. **This same guard should be ported to QNA, SBD, and the LP solvers** — they have the same combinatorial-blowup risk and don't check.
- **`combi()` overflow fix** (`index.c:25–51`) — accumulates in `long double` and clamps to `INT_MAX − 47`. Previously cast a `double` accumulator to `int`, silently wrapping to negative and breaking the inverse-index search. Comment documents the original bug.
- **`InverseIndex` bounded search** (`index.c:117`) — added an explicit `k[j] < n` guard that prevented walk-off-array crashes.

These fixes were retro-applied; the comments capture the reasoning so the lesson isn't lost.

### 3.2 Hard caps — `BNET_MAX_DIM = 64`, `CC_MAX = 64`

`bnet.h:41` defines `BNET_MAX_DIM = 64`; `bnet.c:55` defines `CC_MAX = 64`. The output arrays `bnet_means[BNET_MAX_DIM]`, `cc_*[CC_MAX]`, etc. silently truncate at d > 64 (`bnet.c:202–225` clamps with `&& ii < CC_MAX`). The numerical solver itself uses dynamic allocation (DMAT/DVEC, `dmat_alloc`), so it won't segfault — but a network with d=65 will run, allocate, solve, and then **silently drop everything past station 64 from the output** with no warning. Less catastrophic than QNA's stack overflow, more insidious.

### 3.3 `factorial(k)` overflow at k ≥ 21

`index.c:71–80` computes `factorial(k)` into a `long`. On macOS arm64 `long` is 64-bit, so 21! = 5.1 × 10¹⁹ overflows (max long ≈ 9.2 × 10¹⁸). `factorial` is called with `i = 0 … 2n` from `ComputeWeight` (`index.c:67`); for `n ≥ 11` the upper end `2n ≥ 22` overflows silently and the weight matrix `w[l][i]` becomes garbage. Symptom would be wildly wrong inner products at high polynomial degree. Fix: switch to `long double` accumulator with overflow check.

(In practice users rarely set n > 10 because of memory; but a 0.1-day fix removes the latent risk.)

### 3.4 Default polynomial degree is conservative

`bnet.c:1136`: `def = (d <= 3) ? 5 : (d <= 10) ? 4 : 3`. For d > 10 the default of 3 is a very low spectral order — Dai-Harrison 1992 generally found n ≥ 8 needed for relative error < 1 %. The default protects users from the d=20 n=8 76 TB case, but errs hard on the side of "fast and inaccurate." A user-facing **convergence diagnostic** (run at n=3, 4, 5 and report the relative change) would let users decide.

This is also exactly the gap that bit SBD: SBD calls `bnet -v 0 file` with a default `-n 5` (its own default), but `bnet`'s internal default would have picked something different. The two tools have inconsistent defaults.

### 3.5 Known instability at high polynomial degree (Cholesky failure)

Already documented in the BNAsbd review: `bnet -n 12` on the Lu-Kumar 2-station subnetwork produces "matrix not positive definite", forcing the user to add `-l` (LU) or `-r` (regularization). The error message is **excellent** — explicit and points at the right flags (`bnet.c:362–387`). But there is no auto-retry; a wrapper that tries Cholesky → LU → regularised LU on failure would close the gap without user intervention. Currently every caller (SBD, Run Comparison, scripted invocations) has to know the recipe.

### 3.6 Multi-class data parsing is silent-truncating

The optional `customer_classes K` block (`bnet.c:192–228`) reads at most `min(d, CC_MAX)` per row and at most `K ≤ CC_MAX` classes. `K > 64` simply doesn't read into the arrays past index 63 — the `fscanf` calls keep consuming tokens (advancing the file pointer) but write nowhere. No diagnostic. Fix: `if (K > CC_MAX) Bneterror("too many customer classes")`.

### 3.7 Inner-product hotspot is non-trivial to improve

`inner_2()` (`bnet.c:920–1098`) is the bottleneck — called O(N²) times from `coefficient()`, each call does O(d⁴) work via deeply nested `for` loops over `(i, j, k, l)` index tuples. The structure is dictated by the polynomial inner-product expansion; any meaningful speedup needs an algorithmic change (precompute weight tensor products, SIMD-vectorise the innermost `prod *= w[m][K[m]]` chain) rather than a simple rewrite.

The OpenMP loop is `#pragma omp for schedule(dynamic)` over `t` (rows of A), and each row's work scales linearly in `t` (because `i` runs from `2 … t`). `dynamic` is the right schedule — but each call's inner `K[]` scratch is allocated as `ivector(1, d)` per thread (`bnet.c:821`) and used inside `inner_2`. Using a stack-allocated `int K[MAX_DIM]` would shave allocation cost.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Loud failure when `d > BNET_MAX_DIM` or `K > CC_MAX`: error + exit, not silent truncation | 0.25 d | §3.2, §3.6 | Correctness — closes a silent-data-loss footgun |
| **R2** | Auto-retry chain Cholesky → LU → regularised LU on solve failure (controlled by `--auto-solve`) | 0.5 d | §3.5 + the SBD high-degree silent-fallback finding | Closes a documented user-facing failure mode |
| **R3** | `factorial` accumulator → `long double` with overflow check | 0.1 d | §3.3 | Latent silent-corruption fix |
| **R4** | Convergence-diagnostic mode `--converge`: solve at n = 3, 4, 5 and report Δmean per station; suggest the lowest n satisfying ε | 1 d | §3.4 — defaults are conservative, no signal | Right-sizes the cost/accuracy trade-off |
| **R5** | Sparse Galerkin matrix path: `coefficient` already builds a dense N×N matrix that's empirically very sparse (most polynomial pairs have disjoint support). Build directly into a CHOLMOD `cholmod_triplet` with thresholding `|a_{ij}| > ε`, hand to CHOLMOD's *sparse* factor-and-solve | 5 d | §2.2 — at d=8 n=8 the dense matrix is the bottleneck (memory-bound at 8 threads) | 5–20× wall time + opens up d=10 n=10 |
| **R6** | Block-tile `coefficient`'s assembly loop to keep working set in L3; replace per-thread `ivector(1,d)` with stack `int K[BNET_MAX_DIM]` | 0.5 d | §3.7 — current OpenMP scaling is sub-linear | 1.5–2× at 8+ threads, no algorithmic change |
| **R7** | Library mode (`libbnet.a` + header) so callers (SBD, Qnet) link instead of `popen`. Eliminates ~10 ms startup × number of invocations; lets SBD batch all subnetwork solves into one process. | 2 d | BNAsbd §2.1 — SBD popen overhead is 95 % of its wall time | 5–20× speedup *for SBD* and any future caller |
| **R8** | Consistent default-degree heuristic shared with SBD (extract into a header constant) | 0.25 d | §3.4 — conflicting defaults across the two tools | Predictability, no perf change |
| **R9** | `--report-residual`: print `‖Aφ̂ − b‖∞` so users can spot under-resolved cases without re-deriving | 0.5 d | similar suggestion on QNA | Diagnostics |
| **R10**| Port `bnet_memcheck` calls to `bna_qna`'s and `bna_sbd`'s pre-allocations | 0.5 d | §3.1 — feature already exists in this codebase, just not used elsewhere | Defensive |

### Engineering hygiene (separately)

- The `#ifndef ANSI_C` / K&R fallback prototypes are scaffolding that hasn't been exercised in 30 years — Apple's gcc-13 and Linux gcc all support C89+. Removing them would shrink each function ~10 LOC and improve readability.
- `Bneterror` calls `printf` (not `fprintf(stderr, …)`) and `exit(0)` (success!). This means a fatal error returns success to the caller — Run Comparison can't distinguish "everything fine" from "fatal halt." Fix: `fprintf(stderr, …)` + `exit(2)`.
- Per-thread `int *K = ivector(1, d)` inside the OpenMP region (`bnet.c:821`) is allocated once per thread spawn — fine. But `Basis` allocates two ivectors *per loop iteration* (`bnet.c:589–590`) and frees them at the end. Hoist them out of the loop with `#pragma omp threadprivate` or `firstprivate(scratch)`.

---

## 5. Suggested order of work

If you do nothing else: **R1 + R3**. Together a 0.5-day fix that closes two silent-corruption paths.

Next: **R2 (auto-retry)** + **R7 (library mode)**. R2 is the user-visible win (no more "use -l flag" surprises). R7 unblocks SBD's 95 %-of-wall-time overhead, and is also the precondition for embedding the spectral solver in the GUI without forking processes.

R5 (sparse Galerkin) is the only path to scaling beyond d=10 n=8 within reasonable RAM. It's a 5-day job; worth doing only when there's a concrete user demand for d ≥ 10 networks. Right now the test suite tops out at d=4.

R10 is the cross-cutting one — `bnet_memcheck` is a great pattern that QNA and SBD both lack. Their failure modes (segfault on stack overflow for QNA, silent fallback for SBD) would be replaced with the same friendly diagnostic that `bnet` gives today.

---

## 6. Test plan when changes land

- R1: deliberately feed d=65 input — pre-fix silently truncates the means; post-fix exits with a clear error.
- R2: re-run Lu-Kumar at degree 12; pre-fix Cholesky fails and exits, post-fix it falls back to LU and gives a deg=12 answer (currently impossible without manual `-l`).
- R3: feed n=12 to a small d=2 input; pre-fix `factorial(24)` returns garbage; post-fix it errors out cleanly.
- R5: confirm the sparse path produces means within 1 e-9 of the dense path on the existing test suite (`test.sh` should pass with no tolerance change).
- R7: bench SBD on the 10-network feedback suite — pre-fix ~10 s, post-fix should drop below 1 s.
