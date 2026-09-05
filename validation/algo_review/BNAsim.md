# BNAsim — review

**Solver:** `infinite/BNAsim/jackson_sim`
**Sources:** `infinite/BNAsim/jackson_sim.c` (~2 KLOC C, single file)
**Method:** Discrete-event simulation of multi-class generalised Jackson networks with infinite buffers. OpenMP parallelisation across replications. Used as the *ground-truth* reference in the validation report and `test.sh`.
**Sibling binaries:** `gjn.c`, `mcn.c`, `jackson_sim_finite.c` — variants for specific use cases (kept here for compatibility, not exercised by Run Comparison).
**Empirical work backing this review:** `validation/algo_review/work/bnasim/`

---

## 1. Current implementation

### 1.1 Architecture

| Step | Lines | Method | Cost |
|---|---|---|---|
| 1 | parse `.sim` file | input loop | O(network size) |
| 2 | OMP parallel-for replication loop | `#pragma omp threadprivate` for `network`, `event_heap`, `rng_state`, etc. | O(n_reps / n_threads) |
| 3 | per-replication: warmup (default 1000 time units) | DES on event heap | depends on rate |
| 4 | per-replication: measurement window (`run_length`) | DES + per-class/per-station accumulators | depends on rate |
| 5 | aggregate across replications | mean / variance per metric | O(n_reps · n_metrics) |
| 6 | output (compact / verbose) | printf | O(n_classes · n_stations) |

Caps: `MAX_STATIONS = 100`, `MAX_CLASSES = 100` (`jackson_sim.c:82–83`). 1.5–2× more generous than the analytical solvers (which all use 64).

### 1.2 Distribution support

`DistType` enum (line 89): exponential, Erlang, gamma, uniform, deterministic, hyperexp2, lognormal, Weibull, Pareto. **Broader than any other solver in the family** — the analytical methods only model first two moments via SCV.

Sampling implementations:
- exponential: inverse CDF
- Erlang: sum of k exponentials
- gamma: Marsaglia-Tsang shape-shifted method
- lognormal, Weibull, Pareto: standard inverse-CDF / Box-Muller
- normal: Box-Muller (used internally by gamma and lognormal)

### 1.3 OpenMP threadprivate replication parallelism

```c
#pragma omp threadprivate(network, event_heap, current_time, next_customer_id, warmup_complete, rng_state)
```

Each thread gets its own copy of the network state. Master parses the input once and `copyin`-broadcasts to all threads at the start of the parallel region. Each replication seeds `rng_init(seed + r)` for reproducibility. **Architecturally clean** — independent replications are embarrassingly parallel.

### 1.4 RNG: Numerical Recipes LCG

`jackson_sim.c:300`:

```c
rng_state = rng_state * 1103515245UL + 12345UL;
return (double)(rng_state & 0x7FFFFFFF) / (double)0x80000000;
```

Linear congruential generator from Numerical Recipes. Period 2³², 31-bit output. **Statistically inadequate for serious simulation work**:

- Poor low-order bit randomness (well-known LCG flaw)
- Period 2³² = ~4 billion samples; a single n=100 r=20000 sim run at λ=3 generates ~6 billion arrivals across all replications, **wrapping the period more than once**
- LCGs with modulus 2^k have notoriously bad correlation in successive triples (Marsaglia 1968)

This is the most significant single technical issue in BNAsim.

---

## 2. Empirical performance

### 2.1 OMP scaling (n=20 reps, run_length=10000, LuKumar91 input)

| `OMP_NUM_THREADS` | wall time | speedup |
|---:|---:|---:|
| 1 |  321 ms | 1.0× |
| 2 |  152 ms | 2.1× |
| 4 |   74 ms | 4.3× |
| 8 |  120 ms | 2.7× (regression) |

Linear up to 4 threads. **8 threads regresses** because n=20 reps doesn't divide evenly across 8 cores (some threads get 3 reps, others 2; the slower-than-average reps dominate). At n=24 or n=40 (divisible by 8) the regression would disappear.

### 2.2 Convergence on Lu-Kumar (analytical truth: sojourn₁ = 2.09, sojourn₂ = 2.53)

| reps × runtime | sojourn₁ obs | sojourn₂ obs | Δ vs truth |
|---:|---:|---:|---:|
|   5 ×   1 000 | 2.06 | 2.33 | -1.5 % / -8 % |
|   5 ×  20 000 | 2.02 | 2.42 | -3.5 % / -4 % |
|  20 ×   1 000 | 1.97 | 2.38 | -6 % / -6 % |
|  20 ×  20 000 | 2.08 | 2.53 | -0.5 % / 0 % |
| 100 ×   1 000 | 2.09 | 2.49 | 0 % / -2 % |
| 100 ×  20 000 | 2.10 | 2.54 | +0.5 % / +0.4 % |
| 500 ×  20 000 | 2.09 | 2.53 | 0 % / 0 % |

Convergence is well-behaved. **At ρ=0.8 the practical convergence floor is `n ≥ 20, runtime ≥ 20000`** (≈ 0.5 % per-station error). This is exactly the band the validation report's strict `test.sh` uses.

`test.sh`'s default `SIM_REPS=5, SIM_RUN=2000` is **inside the noise band** — it gives 5–8 % error at ρ=0.8 and worse at ρ=0.9. Documented in §B of `validation/feedback_networks_validation.md`.

### 2.3 RNG period saturation at high simulation budgets

At λ=3 customers/unit-time, n=500 reps × runtime=20000 generates ≈ 30 billion exponential samples (one per arrival, one per service). LCG period = 2³² ≈ 4.3 billion. **The same RNG sequence repeats ~7 times across the run.** Reproducibility from `seed + r` per-replication seeding only buys independence between *replications*, not across the lifespan of a single replication.

This contaminates the central limit theorem assumptions used to compute the `(stderr)` band in BNAsim's output. At low ρ the LCG's flaws are masked by the dominant noise; at high ρ with long runs the structural sampling artefacts can bias the estimate by 1–3 % even with massive replication budgets.

---

## 3. Correctness — bugs & footguns

### 3.1 Inadequate RNG (the headline issue)

§1.4 + §2.3. Replace with a modern PRNG:

- **PCG64** (~ 60 LOC, zero deps, 2¹²⁸ period, `O'Neill 2014`)
- **xoshiro256**\*\* (`Vigna 2018`, smaller state, fast, similar quality)
- **Mersenne Twister** (~200 LOC, 2¹⁹⁹³⁷ period, well-tested)

PCG64 is the modern default. ~1 day to swap in, ~30 LOC of `rng_*` code changes plus header reshuffling.

### 3.2 OMP scaling regression at high thread count when reps < 4 × n_threads

§2.1 — at n=20 reps, 8 threads is *slower* than 4. Static partitioning (`#pragma omp for schedule(static)`) gives uneven workloads.

Fix: switch to `schedule(dynamic, 1)` so threads pick replications one at a time. Trades a small per-rep dispatch cost for load-balanced execution. Also: warn at startup when `n_reps < 4 × omp_get_max_threads()` ("under-replicated for n_threads; consider increasing -n").

### 3.3 No warmup-tuning advice or auto-detection

`warmup_time` defaults to 1000 (`jackson_sim.c:767`). For ρ=0.5 networks this is plenty; for ρ=0.95 it's barely enough to drain the initial transient. Common practice (Pawlikowski 1990; Welch 1983) is to *adaptively* detect warmup completion using a moving-window stationarity test. Currently the user has to know the right value or accept biased early estimates.

`--auto-warmup` mode: simulate a short calibration run, find when running mean stops trending, set warmup to 2× that point.

### 3.4 Default convergence at high ρ is worse than `test.sh` knows

`test.sh` ships with `SIM_REPS=5, SIM_RUN=2000`. At ρ ≤ 0.7 these defaults are within ~5 %; at ρ = 0.9 they're 10–20 % off. The defaults need either:

- An adaptive recommendation (`if max(rho) > 0.85, suggest n=100, r=20000`)
- A clear "results may be unreliable; rerun with -n 50 -r 10000" message when stderr exceeds e.g. 5 % of the mean

### 3.5 Per-replication accumulator allocation per thread

`RUN_VALUES_COLS = 3·100 + 3·100 + 100·100 + 3·100 + 100 = 11 200` doubles per replication × `n_reps` total = 112 K doubles for n=10. Fine, but for n=10000 it's 112 M (~900 MB). No memcheck. Add `bnet_memcheck_alloc` per the family-wide pattern.

### 3.6 Customer linked-list memory not pooled

`Customer *next` linked list per queue. Each customer is `malloc`-ed and `free`-d. At λ=3, n=500 reps × runtime=20000, that's 30 billion malloc/free pairs. The per-allocation overhead (~30 ns each on macOS arm64) adds ~900 seconds — **likely the dominant cost** of the entire run.

Fix: pool allocator. Pre-allocate a `Customer *pool` of (say) 1M entries; recycle on completion. ~50 LOC, would speed long sims by 5–10×.

### 3.7 No stability/instability detection

A network with `ρ > 1` is silently un-simulated — the sim runs forever (or until OOM as the queue grows). Bramson-style FIFO instability is also un-detected: the sim happily runs with `ρ < 1` per-station while sojourn diverges. A periodic check ("queue length > 100 × E[Q] in last window — likely instability, abort") would catch both.

### 3.8 Static `MAX_STATIONS = 100` cap

Higher than QNA/SBD/SM (64), but still a hard cap. For very-large networks (>100 stations) the sim silently rejects. Heap-allocate `network.stations[]` sized to actual `num_stations`.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Replace LCG with PCG64 (or xoshiro256**) | 1 d | §3.1 — period saturation at high budgets, well-known LCG flaws | Removes the largest quality risk in the entire codebase |
| **R2** | Pool-allocate `Customer` instead of per-arrival `malloc/free` | 1 d | §3.6 — likely dominant runtime cost at long sims | 5–10× speedup at high-rate / long-run cases |
| **R3** | `schedule(dynamic, 1)` for the replication loop; warn when reps < 4 × threads | 0.25 d | §2.1 — observed regression at OMP=8 | 2× at high thread count with low rep count |
| **R4** | `--auto-warmup` adaptive transient-detection | 1.5 d | §3.3 — fixed 1000 is wrong at high ρ | Removes a hidden bias |
| **R5** | `--adaptive-budget`: at end of each replication, check whether `(stderr / mean)` is below target; stop early or extend automatically | 1 d | §3.4 — current defaults too low at high ρ | Right-sizes simulation budget without user tuning |
| **R6** | Stability-detection heuristic: abort with diagnosis on suspected instability | 0.5 d | §3.7 — silent infinite-runs today | UX |
| **R7** | Heap-allocate `stations[]` and `classes[]`; drop fixed `MAX_STATIONS` | 1 d | §3.8 + family-wide pattern | Unblocks > 100 stations |
| **R8** | Memcheck for the per-replication accumulator block | 0.25 d | §3.5 — family-wide pattern | Defensive |
| **R9** | Variance-reduction: common random numbers across "matched" replications (different ρ, same arrival pattern) | 2 d | sensitivity-study quality | 2–4× confidence interval shrink for sweeps |
| **R10**| Warm-start from a previous run's state (snapshot/restore) so a 2× confidence-interval refinement doesn't restart from empty | 2 d | rare but useful for sweeps | Sweep speedup |

### Engineering hygiene

- The `RUN_VALUES_COLS` macro at line 86 is defined as `3*MAX_CLASSES + 3*MAX_STATIONS + MAX_CLASSES*MAX_STATIONS + 3*MAX_CLASSES + MAX_STATIONS = 11 200` — but the layout assumed by the consuming code is opaque. Replace with a typed struct.
- `progress_open / progress_tick / progress_close` is duplicated verbatim across BNAsm, BNAsim, fBNAsm, fBNAfm, fBNAsim. Extract `common/bnet_progress.h`.
- Distribution sampling functions are pure (no shared state) — could be moved into `common/distributions.h` and shared with fBNAsim.

---

## 5. Suggested order of work

If you do nothing else: **R1 (PCG64)**. The LCG is the single biggest quality liability in the codebase. Until it's replaced, every "ground-truth" sim claim has a small structural-sampling bias that's invisible to the user.

R2 (pool allocator) is the biggest speed win. R3 (dynamic schedule) is a 15-minute fix that closes the OMP=8 regression.

R4 + R5 are paired user-facing correctness wins. The current defaults give silently-biased results at ρ ≥ 0.85 — adaptive warmup + adaptive budget would close the gap.

---

## 6. Test plan when changes land

- R1: run 500 reps × runtime 20000 on Lu-Kumar; compare LCG output histogram to PCG64 output histogram — expect tighter convergence on stable estimates.
- R2: time a long sim (n=100, r=200000) before/after; expect 5–10× speedup.
- R3: bench OMP=1..16 at n=20 reps; expect monotone speedup.
- R4: feed a Bramson-instability network — pre-fix runs forever; post-fix detects and aborts within ~5 s.
- R5: deliberately under-budgeted run (`-n 5 -r 2000`) at ρ=0.95 — pre-fix returns silently biased numbers; post-fix warns "stderr 8 %, recommend -n 50".
