# BNArqna — Robust Queueing Network Analyzer (DESIGN DOC)

## Status
**NOT IMPLEMENTED.** This is a design doc for Item 3 of the survey roadmap. Honest scope: **2-3 weeks** of dedicated work.

## Why a separate solver
QNA-1983 characterizes each arrival/departure stream by two scalars: rate λ and squared coefficient of variation c². For renewal arrivals at light load this is asymptotically exact. For multi-class re-entrant networks under heavy load — exactly the Lu-Kumar / Kumar-Seidman / Bramson regime — the assumption fails because the actual stream is non-renewal and exhibits temporal correlation that c² alone cannot capture.

Per the survey, the documented 20-25% sojourn-estimate gap on those networks is largely from this two-moment limitation, not from the per-class aggregation that Item 2 (BNAqna's per-class variability fix, Bitran-Tirupati 1988 / Whitt 1988) addresses.

## Method
Whitt & You, "A Robust Queueing Network Analyzer Based on Indices of Dispersion," Naval Research Logistics 69(1):36-56, 2022 ([arXiv:2003.11174](https://arxiv.org/abs/2003.11174)).

**Index of Dispersion for Counts (IDC):** instead of a scalar c², characterize an arrival/departure process by the function
```
I(t) = Var(N(t)) / E(N(t))
```
where N(t) is the cumulative count in [0, t]. For a Poisson process I(t) = 1 ∀t. For a renewal process I(t) → c² as t → ∞ and I(0+) = c² + (other terms). For non-renewal flows (re-entrant traffic, bursty inputs) I(t) varies with t and captures multi-timescale variability.

**Pipeline (replaces QNA's variability propagation):**
1. **Discretize** I(t) at a finite set of timescales `{t_1, t_2, …, t_m}`. Whitt-You use ~10 logarithmically spaced points spanning `[0.01·E[S], 100·E[S]]`.
2. **External arrivals:** compute I_arrival(t) from the input distribution. Closed forms exist for Poisson, Erlang, hyperexponential, lognormal, MMPP (Markov-modulated Poisson).
3. **Per-class flows:** propagate I through the network. The propagation rules (Whitt-You §3-4):
   - **Superposition** of independent streams: I_super(t) = (Σ_k λ_k I_k(t)) / λ_total — weighted average at each timescale.
   - **Departures** from a station: I_d(t) involves a convolution with the Index of Dispersion for Work (IDW) of the service distribution, and depends on ρ. For ρ → 1: I_d → I_a (departures look like arrivals). For ρ small: I_d → I_s (departures look like service).
   - **Splitting** with probability p: I_split(t) = p·I(t) + (1-p) — Bernoulli thinning.
4. **Per-station congestion:** at each station, compute `E[W]` from `I_a(t)` and `I_s(t)` via Whitt-You's robust GI/G/1 formula (their eq. 4-5), which depends on the IDC at the timescale `t* = E[W]/E[S]` (a self-consistent fixed point).

## Why it should help on Bramson / Lu-Kumar
Bramson 1994 instability arises from temporal correlation: a class's arrivals at station j are correlated with that class's previous service times at station i. Two-moment QNA can't see this. IDC propagation captures it as long-timescale persistence in I(t).

Empirically, Whitt-You report 5-15% accuracy improvement on standard benchmarks vs QNA-1983, with the largest gains on bursty inputs and high-utilization networks.

## Implementation plan (~2-3 weeks)

### Week 1 — IDC infrastructure
- New solver dir `infinite/BNArqna/`.
- `Idc` struct: `t[NUM_SCALES], values[NUM_SCALES]` (~10 scales).
- IDC formulas for the standard input distributions (Poisson, exponential, Erlang-k, hyperexp-2, lognormal, deterministic). Reference: Whitt 1982 "Approximating a point process by a renewal process."
- Test: IDC of Poisson is constant 1; IDC of Erlang-k matches closed form.

### Week 2 — Propagation rules
- Implement superposition (weighted mixture of IDCs).
- Implement Bernoulli splitting.
- Implement departure-IDC formula (Whitt-You §3.2). This is the hardest piece — involves a fixed-point iteration on the per-station effective ρ.
- Test on a known case: 2-station tandem M/M/1 → M/M/1, verify each station sees IDC = 1 (Poisson preserved through M/M/1 in steady state).

### Week 3 — Wait-time computation + GUI
- Whitt-You's GI/G/1 formula at each station (eq. 4-5) with a Newton iteration for the self-consistent t*.
- Per-class extension: track per-class IDC, compute per-class congestion.
- New CLI `bna_rqna` with the same input format as `bna_qna` plus optional IDC initial conditions (defaults to Poisson when absent).
- Wire into Run Comparison alongside QNA. Validate on Lu-Kumar / Kumar-Seidman / Bramson with target gap ≤ 5%.

## File-format extension
The current `qna.qna` format is two-moment. RQNA needs IDC inputs:
```
# Per-class arrival IDC at NUM_SCALES timescales (K rows × NUM_SCALES cols)
# (omitted → Poisson assumed)
```
The Swift exporter (`Sources/Qnet/QNAExporter.swift`) computes the IDC from each external source's distribution at parse time and writes it. Reuses the same per-class machinery already added in Item 2.

## Why not implement now
Departure-IDC formula has subtle edge cases at extreme ρ (near 0 or 1) that the Whitt-You paper handles with a piecewise approximation (their Appendix A). Implementing this in a hurry would produce a solver that gives plausible-looking but quietly wrong answers on the very networks it's supposed to fix. A full first-pass with validation matches the 2-3 week estimate.

## Validation targets (post-implementation)
- Lu-Kumar 1991 with rates (10, 10, 1.667): expect sojourn close to 1.625-1.736 (current QNA: 1.625; sim: 2.03; theoretical M/H2/1: 1.736). Goal: ≤ 5% gap to sim.
- Kumar-Seidman 1990: same target.
- Bramson 1994 c=2: target ≤ 10% on per-station means.
- BanksDai96: target ≤ 10% on the documented benchmark cases.

## Reference implementation
Wei You's PhD thesis (Columbia, 2019) has a Python reference implementation. Useful for cross-validation but not directly portable to Qnet's C codebase.
