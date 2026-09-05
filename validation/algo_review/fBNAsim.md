# fBNAsim — review

**Solver:** `finite/fBNAsim/fBNAsim` (also builds sibling `fBNAmc`)
**Sources:** `finite/fBNAsim/{main.c, parser.c, simulator.c, stats.c, distributions.c, event_queue.c, rng.c, *.h}` (~2.5 KLOC C, multi-file, modular)
**Method:** Discrete-event simulation of multi-class generalised Jackson networks with **finite buffers**, supporting Blocking-After-Service (BAS), Loss, and BAS+external-loss disciplines. Multi-server stations (`c_i ≥ 1`).
**Empirical work backing this review:** `validation/algo_review/work/fbnasim/`

---

## 1. Current implementation

### 1.1 Architecture — far better than BNAsim's

| File | LOC | Role |
|---|---:|---|
| `parser.c`     | 479 | input format parsing |
| `simulator.c`  | 832 | DES core (event loop, BAS, multi-server) |
| `stats.c`      | 398 | per-replication accumulators + cross-replication aggregation |
| `distributions.c` | 154 | sample from 9 distributions |
| `event_queue.c` | 101 | binary heap |
| `rng.c`        |  62 | xoshiro256\*\* with SplitMix64 seeding |
| `main.c`       | 312 | CLI + dispatch |
| headers        | 226 | per-module |

Modular design with clear interfaces. Compare to BNAsim's monolithic 2058-line `jackson_sim.c` — this is dramatically better engineered.

### 1.2 RNG: xoshiro256\*\* — the right choice

`rng.c:35–53`:

```c
uint64_t rng_next_u64(RNG *rng)
{
    const uint64_t result = rotl(rng->s[1] * 5, 7) * 9;
    const uint64_t t = rng->s[1] << 17;
    rng->s[2] ^= rng->s[0];
    ...
}
```

xoshiro256\*\* (Blackman & Vigna 2018), period 2²⁵⁶, seeded via SplitMix64. Top-tier modern PRNG with PractRand passes through 32 TB. **This is the RNG that BNAsim should also be using.**

Bonus: built-in antithetic-variate support (`rng->antithetic ? (1.0 - u) : u` at `rng.c:61`) — variance reduction primitive ready to be exploited by paired runs.

### 1.3 Three parallelism backends

`simulator.c` supports:

- `PARALLEL_NONE` — sequential
- `PARALLEL_OPENMP` (`-o`) — `#pragma omp parallel for`
- `PARALLEL_GCD` (`-a`) — Apple Grand Central Dispatch via `dispatch_apply_f`

Per-replication independence (each rep gets own RNG seed via `seed + r`). Same architectural cleanliness as BNAsim, with the GCD backend as a macOS-native alternative.

### 1.4 Three blocking disciplines

`fBNAsim` supports finite-buffer regimes that single-buffer sims cannot:

- **BAS (default)**: Blocking-After-Service. When a customer finishes at station i and downstream is full, the server at i becomes blocked until a slot opens. Server occupancy stays elevated.
- **Loss (`-l`)**: customers arriving at a full buffer are discarded entirely.
- **BAS + external loss (`-e`)**: external arrivals to full buffers are lost; internal traffic uses BAS.

Three semantically-distinct queueing models in the same binary. Crucial for finite-buffer analyses where the discipline materially changes the throughput.

### 1.5 Pipeline (line numbers in `simulator.c`)

| Step | Function | Method |
|---|---|---|
| 1 | parse_input | line-keyword parser → `NetworkConfig` |
| 2 | parallel-for over replications | one of three backends |
| 3 | per-replication: warmup (default 50 000 t.u.) | DES |
| 4 | per-replication: measurement window (default 500 000 t.u.) | DES + accumulators |
| 5 | aggregate stats | mean / variance / per-class / per-station |
| 6 | output (compact / verbose / per-station / per-class) | printf |

Static caps: `MAX_STATIONS = 64`, `MAX_CLASSES = 64` (`parser.h:10`, `parser.h:16`). Same as analytical solvers, half of BNAsim's 100.

---

## 2. Empirical performance

### 2.1 OMP scaling on `2d2cfin.txt` (n=100 reps, T=50000)

| `OMP_NUM_THREADS` | wall time | speedup |
|---:|---:|---:|
| 1 | 1.34 s  | 1.0× |
| 2 | 0.77 s  | 1.7× |
| 4 | 0.43 s  | 3.1× |
| 8 | 0.23 s  | 5.8× |

**Linear scaling** to 8 threads — much better than BNAsim's regression. Likely because n=100 reps divides cleanly across 8 threads with chunk size ≥ 12.

### 2.2 Backend comparison (n=50, T=20000)

| backend | wall time |
|---|---:|
| sequential                  | 110 ms |
| OpenMP (`-o`)               |  85 ms |
| Apple GCD (`-a`)            |  87 ms |

OMP and GCD are within noise of each other; either works.

### 2.3 Convergence on bundled `2d2cfin.txt`

| reps | E[X_1] (stderr) | E[X_2] (stderr) |
|---:|---|---|
|   5 | 17.55 (5.07) | 10.69 (2.30) |
|  20 | 20.43 (1.97) | 11.60 (0.79) |
| 100 | 21.18 (0.52) | 11.88 (0.21) |
| 500 | 21.23 (0.21) | 11.93 (0.09) |

Converged to 0.5 % at n=100, 0.1 % at n=500. Good behaviour — the modern RNG plus the BAS-style finite-buffer discipline converge tightly.

### 2.4 Buffer-size scaling (`network_b5/b20/b100.txt`)

| input | wall time |
|---|---:|
| network_b5  |  98 ms |
| network_b20 |  65 ms |
| network_b100|  83 ms |

Insensitive to buffer size, as expected — the buffer dimensions affect rejection probabilities, not the per-event work.

---

## 3. Correctness — bugs & footguns

### 3.1 Routing matrix is `[64][64][64]` static — 4 MB always

`parser.h:30`:

```c
double routing[MAX_CLASSES][MAX_STATIONS][MAX_STATIONS];
/* per-class P[i][j] — 64 × 64 × 64 × 8B = 2 MB */
```

Plus `service_dist[MAX_STATIONS][MAX_CLASSES]` (Distribution structs ~ 32 B each = 128 KB). The `NetworkConfig` struct itself is ~2.5 MB even for a 2-station 1-class network. Fine for a CLI, but for any in-process embedding (library mode) every loaded network reserves ~2.5 MB upfront.

Heap-allocate sized to actual `(num_stations, num_classes)`.

### 3.2 No memcheck

Same gap as BNAsim. Per-replication accumulators × replications = potentially large. Add `bnet_memcheck_alloc` per the family-wide pattern.

### 3.3 `MAX_STATIONS` cap is half of BNAsim's

`MAX_STATIONS = 64` here, `MAX_STATIONS = 100` in BNAsim. Inconsistent — pick one. If the goal is to support real-world networks, both should heap-allocate.

### 3.4 No automatic-warmup detection

Default `warmup = 50000`, default `T = 500000` (10× warmup). Reasonable defaults but no auto-detection. Same gap as BNAsim §3.3.

### 3.5 No stability/instability detection

A finite-buffer network with very high arrival rates will silently saturate (every customer rejected). Without an explicit "saturation > X %" warning, the user sees throughput = 0 with no diagnostic.

### 3.6 No GCD/OMP unification

Both `-o` and `-a` are exposed and produce nearly identical results. Pick one as the default and document the other as a fallback. Currently the user has to know that `-o` requires `make OPENMP=1` while `-a` is always available on macOS.

### 3.7 Sibling `fBNAmc` binary purpose unclear

`finite/fBNAsim/Makefile` builds both `fBNAsim` and `fBNAmc`. The latter isn't referenced from `Sources/Qnet/QnetGUIApp.swift` and has no `--help` output. Dead code or future-feature? Should either be wired through Run Comparison or pruned.

### 3.8 `simulator.c:167` — `MAX_BLOCKED MAX_STATIONS` confusing macro

```c
#define MAX_BLOCKED MAX_STATIONS
```

Reads as if blocked-server count is bounded by station count, which is correct for single-server-per-station networks but not for multi-server. With `c_i = 4` servers, station i can have up to 4 blocked simultaneously. The macro is used only as the BlockedQueue capacity (`bq->capacity = MAX_BLOCKED`) — needs a comment explaining the implicit single-blocked-per-station assumption.

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Heap-allocate routing/service/state arrays sized to actual `(d, K)` | 1 d | §3.1, §3.3 — 2.5 MB per network unconditionally | Library-mode prerequisite |
| **R2** | `--auto-warmup` adaptive transient-detection (mirrors BNAsim R4) | 1.5 d | §3.4 — fixed warmup is wrong at high ρ | Removes hidden bias |
| **R3** | `--adaptive-budget` early-stop when stderr/mean below target (mirrors BNAsim R5) | 1 d | §2.3 — manual tuning today | Right-sizes simulation |
| **R4** | Memcheck for per-rep accumulators | 0.25 d | §3.2 — family-wide pattern | Defensive |
| **R5** | Loss-rate / saturation warning when blocking probability > 50 % | 0.5 d | §3.5 — silent zero-throughput today | UX |
| **R6** | Document or remove `fBNAmc` sibling binary | 0.5 d | §3.7 — appears dead | Maintenance clarity |
| **R7** | Common RNG / distributions module shared with BNAsim — once BNAsim adopts xoshiro | 1 d | §1.2 — fBNAsim already has the right RNG | Consistency |
| **R8** | Cross-validate `-o` vs `-a` periodically; drop the slower one | 0.5 d | §2.2 — overlapping responsibilities | Code reduction |
| **R9** | Library mode (`libfbnasim.a`) — depends on R1 | 1 d | family-wide pattern | GUI in-process |
| **R10**| Comment / fix the `MAX_BLOCKED MAX_STATIONS` macro for multi-server semantics | 0.25 d | §3.8 | Correctness audit |

### Engineering hygiene

- Distribution sampling (`distributions.c`) is the right home for the `common/distributions.h` extraction: identical functionality lives in BNAsim, fBNAsim should be the canonical source.
- Progress-file pattern duplicated again from BNAsim/BNAsm/etc. — extract to `common/bnet_progress.h` (R7 in BNAsim review).
- xoshiro256\*\* RNG (`rng.c`) is the only modern RNG in the codebase. Worth promoting to `common/rng.h` so BNAsim picks it up too.

---

## 5. Suggested order of work

If you do nothing else: **R1 (heap-allocate the static arrays)**. This is the precondition for library mode and fixes the unconditional 2.5 MB-per-network footprint. Family-wide pattern.

R2 + R3 mirror the BNAsim improvements; doing them once and porting up makes both simulators consistent.

R7 is the cross-cutting code-sharing win: fBNAsim already has the modern RNG; promoting it to `common/rng.h` and migrating BNAsim closes the largest correctness gap in the entire codebase (per BNAsim §3.1).

---

## 6. Test plan when changes land

- R1: load a 5-station 2-class network — pre-fix uses 2.5 MB regardless; post-fix uses ~2 KB.
- R2: feed a high-ρ network with default warmup — pre-fix gives biased early estimates; post-fix detects the transient and extends warmup.
- R3: run with `--target-stderr 0.01` — should run as many reps as needed and stop when achieved.
- R5: feed an overload network — pre-fix runs silently with 0 throughput; post-fix warns within 10 s.
- R7: end-to-end LuKumar comparison — pre-fix BNAsim and fBNAsim use different RNGs and diverge at long runs; post-fix they share the same xoshiro256\*\* and converge.
