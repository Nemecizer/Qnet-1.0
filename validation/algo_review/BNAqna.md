# BNAqna — review

**Solver:** `infinite/BNAqna/bna_qna`
**Source:** `infinite/BNAqna/bna_qna.c` (762 LOC, single file, plain C, `-O2 -ansi -pedantic`)
**Method:** Whitt 1983 "Queueing Network Analyzer" — two-parameter (rate, SCV) parametric decomposition.
**Empirical work backing this review:** `validation/algo_review/work/bnaqna/`

---

## 1. Current implementation

QNA reduces an open queueing network to a collection of independent GI/G/m queues represented by two moments per flow: rate `λ` and squared coefficient of variation `c²`. The pipeline:

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 1 | `parse_input`              | 98–276  | line-buffered `fgets` + `strtok`             | O(n²) read |
| 2 | `eliminate_feedback`       | 282–307 | per-station self-loop elimination, `Q_ii → 0` | O(n²) |
| 3 | `solve_traffic_rates`      | 315–378 | dense LU on `(I − Qᵀ) λ = λ₀` (partial pivoting) | O(n³) |
| 4 | `solve_variability`        | 386–502 | builds `B`, `a` per Whitt eqs. 24–43; dense LU on `(I − Bᵀ) c²_a = a` | O(n³) |
| 5 | `compute_congestion`       | 536–598 | GI/G/1 (KLB) or GI/G/m (Whitt eq. 70) per node | O(n) |
| 6 | `compute_class_stats`      | 604–620 | visit-ratio aggregation                       | O(K·n) |

All matrices and vectors are statically sized `[MAX_NODES][MAX_NODES]` with `MAX_NODES = 64` (`bna_qna.c:24`). The intermediates (`p`, `B`, `A`, `Qt`, …) are **function-local** stack allocations, ~7 × 64² × 8 B ≈ 230 KB on each call. External deps: `libm` only.

---

## 2. Empirical performance

### 2.1 Wall-time scaling (validated)

Built `bna_qna_n256` from a copy of the source with `MAX_NODES=256` and ran the synthetic generators in `work/bnaqna/`. Times in ms (process-startup-included), 5–20 reps each, on M-series MacBook:

| n | sparse tandem | dense topology |
|---:|---:|---:|
|   4 |  1.7 |  — |
|   8 |  1.6 |  — |
|  16 |  2.6 |  3.5 |
|  32 |  2.7 |  2.7 |
|  64 |  2.6 |  2.7 |
| 128 |  3.7 |  6.5 |
| 200 |  4.4 |  5.8 |

The numerical work is invisible at n ≤ 64 (process startup ≈ 1.5 ms dominates). Two Gaussian eliminations at n=200 dense ≈ 2.7 × 200³ FLOPs ≈ 22 M ops, well under 1 ms with `-O2`. **At any size where the current code is stable, performance is not a concern.**

### 2.2 The MAX_NODES cap is not just cosmetic — it's load-bearing in a load-bearing way

Re-compiling the solver with larger `MAX_NODES`:

| `MAX_NODES` | Local stack frame in `solve_variability` | Behaviour |
|---:|---:|---|
|  64 |  130 KB | works (current default) |
| 256 |  2.0 MB | works |
| 512 |  8.0 MB | works (right at the 8 MB stack ceiling) |
| 1024| 32.0 MB | **segfaults on every input**, including n=4 |
| 2048| 128.0 MB | **segfaults on every input** |

**This is a real bug masquerading as a config knob.** Bumping `MAX_NODES` past ~512 causes immediate segfaults because `solve_variability` (`bna_qna.c:386`) has 4 function-local `MAX_NODES²` matrices on the stack, and macOS's default per-thread stack is 8 MB. An unsuspecting user who edits the `#define` to support, say, n=300 will likely set 1024 "for headroom" and silently break the binary for every input.

The fix has to go heap-side: turn `solve_variability`'s scratch matrices into one `malloc`/`free` block sized to actual `n`, not `MAX_NODES`. Same for `solve_traffic_rates` and the file-scope `Q[MAX_NODES][MAX_NODES]` etc. (those are BSS, not stack, so they only waste memory — but if you're touching it, do it once).

---

## 3. Empirical accuracy

### 3.1 Latent bug: KLB g-factor never applied at m ≥ 2

`compute_congestion` has two branches:

```c
if (m[i] == 1) {
    /* GI/G/1 with KLB g-correction when ca_sq < 1 — bna_qna.c:543-553 */
    ...
    ew_fb = tau_t[i] * rho[i] * (ca_sq[i] + cs_t[i]) * g / (2.0 * (1.0 - rho[i]));
} else {
    /* GI/G/m WITHOUT g — bna_qna.c:555-561 */
    double Cm = erlang_c(m[i], offered);
    ew_mmm = Cm * tau_t[i] / ((double)m[i] * (1.0 - rho[i]));
    ew_fb = ew_mmm * (ca_sq[i] + cs_t[i]) / 2.0;
}
```

Whitt 1993 ("Approximations for the GI/G/m queue", *Production and Operations Management* 2(2)) explicitly extended the KLB g-correction to m > 1 with the *same* functional form. Dropping it causes a substantial overestimate of `E[W]` whenever `c²_a < 1` at a multi-server station.

Reproduced in `work/bnaqna/whitt93_gfactor.py` — gap of `current` (no g) vs `whitt93` (g applied), at a single GI/G/m station, c²_s = 1:

| m | ρ | c²_a = 0.1 | c²_a = 0.25 | c²_a = 0.5 | c²_a = 1 | c²_a = 2 |
|---:|---:|---:|---:|---:|---:|---:|
| 2 | 0.50 | **−38.8 %** | −25.9 % | −10.5 % | 0 | 0 |
| 2 | 0.80 | −11.5 %     | −7.2 %  | −2.7 %  | 0 | 0 |
| 2 | 0.90 | −5.3 %      | −3.3 %  | −1.2 %  | 0 | 0 |
| 4 | 0.50 | **−38.8 %** | −25.9 % | −10.5 % | 0 | 0 |
| 8 | 0.80 | −11.5 %     | −7.2 %  | −2.7 %  | 0 | 0 |

(The gap is m-independent because both formulas factor through the same `Cm · τ / (m(1−ρ))` and only the SCV-mixing factor differs.)

**Why this hasn't surfaced in any existing test case:** none of the example `.bnet` files use multi-server stations (`grep '"numberOfServers" : [2-9]' input/examples/*.bnet` is empty). The bug is latent. The first user to build a multi-server network with low arrival variability (think Poisson into a short-batch processor) will get silently overestimated waits.

**Fix:** ~10 lines, one block. Apply the same g formula in the m > 1 branch.

```c
if (m[i] >= 1) {
    double g = 1.0;
    if (ca_sq[i] < 1.0) {
        double num = -2.0 * (1.0 - rho[i]) * (1.0 - ca_sq[i]) * (1.0 - ca_sq[i]);
        double den = 3.0 * rho[i] * (ca_sq[i] + cs_t[i]);
        if (fabs(den) > 1e-15) g = exp(num / den);
    }
    if (m[i] == 1) {
        ew_fb = tau_t[i] * rho[i] * (ca_sq[i] + cs_t[i]) * g / (2.0 * (1.0 - rho[i]));
    } else {
        double offered = rho[i] * (double)m[i];
        double Cm = erlang_c(m[i], offered);
        ew_fb = Cm * tau_t[i] / ((double)m[i] * (1.0 - rho[i]))
              * (ca_sq[i] + cs_t[i]) / 2.0 * g;
    }
}
```

### 3.2 Silent input mutation: cs_eff floor at 0.2

`bna_qna.c:439`:

```c
double cs_eff = cs_t[i];
if (cs_eff < 0.2) cs_eff = 0.2;
```

Whitt 1983 §IV recommends a floor on c²_s in the variability propagation to avoid spurious near-zero arrival SCV estimates downstream of a low-variance station. Sound advice — but currently this clamping is silent. A user who specifies a deterministic-batch service (c²_s = 0) gets it quietly upgraded to c²_s = 0.2 with no log line.

Cost of fixing: ~3 lines. Track whether any clamping occurred and log it once at the end of `solve_variability`.

### 3.3 Documented multi-class re-entrant gap

`validation/feedback_networks_validation.md` already shows the QNA → sim sojourn deviation on Lu-Kumar / Kumar-Seidman / Bramson networks: 20–25 % at the per-station level, 1–10 % at the per-job aggregate. Root cause: the variability fixed point uses station-aggregated `c²_s` (`bna_qna.c:439`, `cs_t` is the aggregated service SCV after self-loop elimination), so it cannot represent the fact that two classes visit the same station with very different service SCV. Whitt 1988 ("Approximations for networks of GI/G/m queues with class-dependent service times", *Performance Evaluation* 8(3)) gives a per-class extension with a `K·n × K·n` variability system instead of `n × n`.

The structural issue is: with K classes the fix turns the O(n³) Gaussian elimination into O((Kn)³). For Lu-Kumar (n=2, K=5) that's still trivial; for n=20 K=10 it's 8M ops, still fine.

### 3.4 Self-loop elimination only — no two-station feedback elimination

`eliminate_feedback` (`bna_qna.c:282`) handles only `Q[i][i]`. Whitt 1983 §III also gives a closed-form 2-cycle elimination (`Q[i][j] Q[j][i] > 0`). Lu-Kumar's bottleneck is precisely a 2-cycle on `(B1 → S1 → B2 → S2 → B1)`. Adding 2-cycle elimination might close some of the 20–25 % gap; would have to validate empirically.

### 3.5 Bramson-style instability undetected

`solve_traffic_rates` exits with an error at `ρ ≥ 1` (line 372) but has no virtual-traffic check (Bertsimas-Gamarnik-Tsitsiklis 1996; Dai-Vande Vate 2000) for multi-class FIFO instability with all `ρ_i < 1`. On the Bramson examples QNA returns "stable, sojourn ≈ 6" while sim diverges to 462. Right behavior is debatable — the discrepancy *is* the demonstration of Bramson's theorem in Run Comparison — but a `! Warning` line in the output would help users who don't already know the literature.

---

## 4. Recommendations, re-ranked by empirical evidence

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Heap-allocate `solve_variability`'s scratch matrices, drop `MAX_NODES` cap | 1 d | §2.2 — segfault cliff documented | Unblocks any n > 512; closes a footgun |
| **R2** | Apply Whitt-1993 g-factor at m ≥ 2 | 0.25 d | §3.1 — up to 38.8 % gap shown | Latent, fires on first multi-server use |
| **R3** | Two-station feedback elimination | 1.5 d | §3.4 — directly addresses Lu-Kumar bottleneck | 5–15 % on per-station re-entrant accuracy (needs validation) |
| **R4** | Per-class variability fixed point (Whitt 1988) | 3–5 d | §3.3 — root cause of documented 20–25 % gap | Largest accuracy gain, biggest engineering lift |
| **R5** | Allen-Cunneen with Whitt 1993 ψ-correction at GI/G/m | 0.5 d | §3.1 builds the framework | Refines the m ≥ 2 fix above |
| **R6** | Replace hand-rolled GE with LAPACK `dgesv` | 0.5 d | §2.1 — current GE invisible at n ≤ 200 but won't scale | Speed gain only kicks in at n > 500 |
| **R7** | Bramson stability check, emit warning | 1 d | §3.5 — doc-described, no current detection | Correctness signal, no behaviour change |
| **R8** | Surface `cs_eff` clamping in output | 0.1 d | §3.2 — silent mutation | Transparency only |
| **R9** | Reiman-Wein iterative refinement (one extra pass) | 1 d | speculative — needs benchmark to confirm | 3–10 % on coupled networks (literature claim) |
| **R10** | Sparse `(I−Qᵀ)` via UMFPACK (already a SuiteSparse dep of BNAsm) | 1.5 d | not currently bottleneck | Unlocks n > 5000 with sparse routing |

### Engineering hygiene (separately worth doing)

- Wrap pipeline so it can return an error code instead of `exit(1)`; would let Qnet embed QNA in-process rather than fork a CLI.
- Pivot threshold should be relative (`|pivot| < ε · ‖A‖∞`) rather than absolute `< 1e-15`.
- Add `--residual` flag emitting `‖λ − Qᵀλ − λ₀‖∞` and `‖c²_a − a − Bᵀc²_a‖∞` so downstream callers can detect ill-conditioning without re-deriving it.
- JSON output mode would let `validation/parse_feedback_runs.py` and `test.sh` retire their regex parsers.

---

## 5. Suggested order of work

If you do nothing else: **R1 + R2**. Half a day combined, fixes a real footgun and a latent silent-overestimate bug, and matches the existing test surface (no current example exercises either).

If you want to attack the documented Lu-Kumar gap: **R3 → benchmark → R4** if R3 alone doesn't move the per-station numbers far enough. R4 is the right answer if the goal is "QNA matches sim on multi-class re-entrant lines"; R3 is the cheaper bet that may or may not close it.

R6 / R10 (LAPACK / sparse) only matter once R1 unblocks scaling enough to make them visible.

---

## 6. Test plan when changes land

For each accepted recommendation, add a `.testcases/<base>.expected` covering the regime where the fix is supposed to bite:

- R2 → a multi-server M/M/m comparison case (`M_M_m.d1.cm.inf.bnet`) with c²_a = 0.5 — current code overestimates by ~3 %, post-fix should be < 1 %.
- R3, R4 → re-run `LuKumar91`, `KumarSeidman90`, `BanksDai96` through `test.sh` with `SIM_PCT=10` (relaxed band) to measure regression, then tighten to 5 % once the new code lands.
- R7 → `Bramson94` cases should now emit a stability warning; capture it in the expected output.
