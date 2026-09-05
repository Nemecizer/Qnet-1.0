# BNAfm — Brownian Network Analyzer (Finite-Element Method, Orthant)

## Status
First-pass implementation delivered (Item 4 of the survey roadmap). Wraps `finite/fBNAfm/bna_fm_gauss` in an outer loop that grows the hypercube until convergence, per Chen-Shen 2003.

## Summary
**Method:** Sequence of cubic-Hermite tensor-product FEM solves on hypercubes `[0, b^n]^K` with `b^n = b^1 + (n-1)c`. The hypercube SRBM data is `(R̄ = (R, -I), θ, Γ)` per Lemma 2.2 of Chen-Shen 2003. As `b^n → ∞` the hypercube SRBM converges weakly to the orthant SRBM; the algorithm terminates when (a) the upper-boundary measure `|δ^n_{K+i}| ≤ ε_1` and (b) the relative change in the stationary mean `|q^n_i − q^{n-1}_i| / q^{n-1}_i ≤ ε_2`.

**Reference:** Chen & Shen, "Computing the Stationary Distribution of an SRBM in an Orthant with Applications to Queueing Networks," Queueing Systems 45:27-45, 2003.

**Source:** `infinite/BNAfm/bna_fm.c` (~280 LOC C). Calls `../../finite/fBNAfm/bna_fm_gauss` via `popen`, parses E[X_i] and δ_upper from stdout. Adaptive mesh: `mesh_n = max(input_mesh, ceil(4·b^n))` per dim, capped at 60.

## What it fixes
BNAsm (the global-polynomial spectral solver) suffers Cholesky breakdown on Lu-Kumar at degree ≥ 12 (documented in `BNAsm.md` and `BNAsbd.md`). FEM with cubic-Hermite tensor products is more numerically stable than global polynomials and degrades gracefully under boundary-layer roughness.

## Validation
- 2D Harrison-Reiman (θ = -1, Γ = I, R = I): theoretical E[X_k] = 0.5; BNAfm gives 0.506 in 3 iterations.
- 2D coupled (θ = -0.3, Γ off-diag 0.2, R off-diag -0.5): converges in 4 iterations.

## Known limitations
- **K=1 not supported.** fBNAfm has a 1D FEM degeneracy that produces flat solutions; for the orthant case use `BNAsm` directly when K=1.
- **K ≥ 4 expensive.** Mesh grows as `b^K`; at b ≈ 20 with K=4 the system is ~10⁵ DOFs and each solve takes minutes.
- **Mesh scaling is heuristic.** The `4·b` rule was empirically tuned for exponential-decay densities; bursty arrivals or off-diagonal Γ may need finer mesh.
- **No service-rate-aware initial b^1.** Uses the product-form approximation `γ_k = 2|θ_k|·R_kk/Γ_kk` always, even when the network is far from product-form.

## Recommendations for next iteration
- **R1: Library-mode interface.** Currently calls fBNAfm via `popen` per iteration. Refactor `finite/fBNAfm` to expose `bna_fm_solve(BNAParams*, double *q_out, double *delta_out)` so BNAfm-orthant can call it in-process. Cuts per-iteration overhead and lets BNAfm reuse the SuiteSparse symbolic factorization across iterations. (Cross-cutting with `BNAsm.md` R7 and `fBNAsm.md` R6.)
- **R2: Fix K=1.** The fBNAfm 1D FEM degeneracy needs investigation. Either fix the underlying FEM or special-case K=1 to dispatch to a scalar SRBM solver (closed-form: Exp(γ)).
- **R3: Adaptive mesh refinement.** Instead of uniform `4·b` mesh, use error indicators to refine near the boundary where the density is sharpest.
- **R4: Bnet integration.** Add a Swift exporter (`BNAfmExporter`) that writes the orthant input format, plus a `runBNAfm()` button in the GUI.
- **R5: Validation suite.** Compare BNAfm-orthant against BNAsm on networks where BNAsm is reliable (low-d, low-degree). The Cholesky-failure cases (Lu-Kumar deg 12) are exactly where BNAfm-orthant should provide ground truth.

## Test it
```
cd /Users/nemecj/Dropbox/0_CODE/0_CLAUDE/Qnet/infinite/BNAfm
make
./bna_fm /tmp/hr_2d.in
```
Where `/tmp/hr_2d.in` is the K-dim orthant SRBM data:
```
K
theta[1..K]
Gamma[i][j]   (K rows)
R[i][j]       (K rows, K cols — orthant only)
mesh_n[1..K]  (FEM mesh; default 20 if absent)
```
