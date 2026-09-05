# Multi-Class SRBM (Γ, R, θ) Preprocessor (DESIGN DOC)

## Status
**NOT IMPLEMENTED.** This is a design doc for Item 5 of the survey roadmap. Honest scope: **1-2 weeks** of dedicated work plus 1 week of validation.

## What it is
A Swift module that builds the SRBM data tuple `(θ, Γ, R)` from a multi-class queueing-network specification, following Chapter 3 of Xinyang Shen's UBC PhD thesis (May 2001). The output feeds the existing SRBM solvers `BNAsm` (orthant), `BNAfm` (orthant FEM, just delivered as Item 4), `BNAlp` (orthant LP), `fBNAsm` (hypercube), `fBNAfm` (hypercube FEM), `fBNAlp` (hypercube LP).

## Why
Qnet's current `Sources/Qnet/SRBMExporter.swift` builds (θ, Γ, R) from a multi-class network using a **station-aggregated** Harrison-Reiman decomposition:
- `θ_i = α_i − c_i` (per-station drift)
- `Γ` from a covariance decomposition that blends per-class arrival variances with the FCFS mixture service variance
- `R = (I − P^T)` (Skorokhod reflection for open Jackson networks)

This matches the SINGLE-CLASS Harrison-Reiman formulation. For MULTI-CLASS networks where different classes at the same station have very different mean service times, the aggregation loses per-class structure that affects the diffusion limit — the same root cause documented for QNA in `BNAqna.md`.

Shen Thesis Ch. 3 derives the SRBM data more carefully via the heavy-traffic limit of the multi-class network's workload process. The result: `(θ, Γ, R)` formulas (eqs. 3.31–3.35) that correctly account for per-class flow contributions, FIFO queueing within priority groups, and (optionally) static buffer-priority disciplines.

## The formulas (Shen Thesis eqs. 3.31–3.35)

**Inputs:**
- K classes, J stations, L priority groups
- α = (α_k): per-class external arrival rate (K-vector)
- m = (m_k): per-class mean service time (K-vector)
- κ = (κ_j): per-station service capacity (J-vector; = 1 for perfectly reliable)
- P = (p_ki): K×K class transition matrix
- Γ_E, Γ_V, Γ_c, Γ_Φ_k: covariance matrices of the driftless components

**Derived:**
- λ = (I − P')⁻¹ α (K-vector of nominal per-class arrival rates)
- M = diag(m), Λ = diag(λ): K×K
- C: J×K indicator matrix, C_jk = 1 iff class k is served at station j
- H: L×K indicator (cumulative over priorities). For pure FIFO (one group per station): **H = C**, L = J
- G: K×K indicator, G_kk' = 1 iff σ(k) = σ(k') AND π(k) ≤ π(k'). For FIFO single-group: G is block-diagonal of all-ones per station

**SRBM data:**
```
β = HMλ                                  (group traffic intensities, L-vector)
ρ = CGMλ                                 (per-station traffic intensity, J-vector)
Δ = ΛG' [HMΛG']⁻¹                        (K×L proportional-allocation matrix)
N = HM(I − P')⁻¹ P' Δ                    (L×L)
R = (I + N)⁻¹ = (HMΛG')[HM(I−P')⁻¹ΛG']⁻¹ (eq. 3.32, L×L SRBM reflection)
θ = R(β − C'κ)                           (eq. 3.33, L-vector SRBM drift)
Γ_X̂ = R[HM(I−P')⁻¹(Γ_E + Σ_k λ_k Γ_Φ_k)(I−P)⁻¹MH'
       + HΛΓ_VH' + C'Γ_cC] R'            (eq. 3.35, L×L SRBM covariance)
```

For FIFO single-group (L = J), the SRBM is J-dimensional — same dimension as the current Harrison-Reiman output. The DIFFERENCE is in the *values* of (θ, Γ, R), specifically how multi-class flows propagate through the formulas.

## What changes vs current SRBMExporter
The current exporter computes:
- `drift[i] = α[i] − c[i]` per station (one-line aggregation)
- `gamma[i][j]` = sum of three per-station covariance contributions
- `R[i][j] = (I − P^T)_{ij}` per station

The Shen approach computes the same dimensions (J × J) but uses the multi-class formulas above. For Kumar-Seidman / Lu-Kumar-style 4-class networks, the off-diagonal entries of R and Γ change measurably; per the Shen thesis numerical examples (§3.6), the impact on E[Q_i] is 5-15% on multi-class re-entrant networks vs the simpler aggregation.

For pure single-class networks (K = J = 1 class per station), the Shen formulas reduce to standard Harrison-Reiman → no change.

## Implementation plan (~1-2 weeks)

### Week 1 — Core formulas
- New Swift file `Sources/Qnet/SRBMMulticlassExporter.swift`.
- Linear-algebra helpers: matrix-inverse, multiply, transpose (~50 LOC; the codebase already has these for QNA per-class fix).
- `computeShenSRBMData(nodes:, links:) -> SRBMData` building K, J, L (FIFO single-group case first), C, H, G, M, Λ.
- Apply eqs. 3.31–3.35.
- Output the same `SRBMData` struct as the existing exporter — this lets it be a drop-in alternative.

### Week 2 — GUI integration + validation
- Add `appSettings.useMulticlassExporter: Bool`. When true, all SRBM-bound exports (sm.in, fm.in, lp.in) use the new formulas.
- Add a sanity check: when K = J (single-class-per-station), Shen and Harrison-Reiman should agree to floating-point precision. Assert this.
- Validate on Kumar-Seidman / Lu-Kumar via Run Comparison: expect Γ and R to differ; E[Q_i] should move closer to sim ground truth.

### Optional Week 3 — Priority extension
- Generalize H from FIFO single-group to multiple priority groups per station (L > J).
- Required for static buffer-priority disciplines (LBFS, FBFS, SMPT).
- More involved because H now reflects priority cumulation; G also changes.

## Why not implement now
Three risks justify deferral:
1. **Sign / transpose conventions.** The Shen Thesis uses `P'` (transpose) consistently with column vectors; getting one transpose wrong silently produces a "valid-looking" SRBM that gives quantitatively wrong answers on the test cases. Validation requires deliberate cross-check against sim, not just regression-passes-don't-break-anything.
2. **Dimension reduction for state-space collapse.** §3.5.3 of the thesis discusses an alternative SRBM with state-space-collapse: under static priority, the L-dim SRBM may collapse to a J-dim one with explicit `Δ̃` matrix (eq. 3.46). Whether to use the L-dim version (no SSC assumption) or the J-dim collapsed version depends on the discipline. A first-pass should commit to one (FIFO single-group → just J-dim, no SSC) but document the choice.
3. **Validation cost.** The Shen thesis §3.6 has 4 numerical examples with sim comparisons (single-class with breakdown, generalized Jackson, Bramson variant, multi-class). Reproducing these as Qnet test cases takes most of "Week 2 of the validation."

## Cross-references
- Shen Thesis §3.2.2 (primitive process definitions) — needed to map Qnet's distribution parameters to (m_k, c²_k, etc.).
- Shen Thesis §3.4 (SRBM construction) — the core derivation.
- Shen Thesis §3.5.1 (well-definedness via completely-S R) — necessary condition the new R must satisfy; if violated, the exporter must fall back or warn.
- `Sources/Qnet/SRBMExporter.swift` lines 295-366 — current single-class exporter to extend or replace.
- `validation/algo_review/BNAqna.md` R4 — the per-class QNA fix (now delivered as Item 2) that this preprocessor would feed analogous improvements to the SRBM solvers.

## Estimated impact
Per the survey, Items 2 (per-class QNA) + 5 (Shen multi-class preprocessor) together should close ~10-15% of the documented Lu-Kumar / Kumar-Seidman gap. Item 2 alone closes very little on those specific networks because they use exponential service throughout (per-class cs = mixture cs = 1); Item 5 should help more because the per-class **flow** structure differs even when service distributions are identical.
