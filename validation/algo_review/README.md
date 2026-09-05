# Qnet algorithm review — cross-cutting summary

Ten production solvers reviewed in `validation/algo_review/`. Empirical scaffolding under `work/<solver>/`.

| File | Solver | Method | Status |
|---|---|---|---|
| `BNAqna.md` | infinite/BNAqna  | QNA (Whitt 1983)                    | done |
| `BNAsbd.md` | infinite/BNAsbd  | SBD (Dai-Nguyen-Reiman 1994)        | done |
| `BNAsm.md`  | infinite/BNAsm   | Spectral / orthogonal Galerkin       | done |
| `fBNAsm.md` | finite/fBNAsm    | Spectral on hypercube                | done |
| `fBNAfm.md` | finite/fBNAfm    | Finite-element Hermite mesh          | done |
| `BNAlp.md`  | infinite/BNAlp   | LP relaxation (Saure et al. 2008)    | done |
| `fBNAlp.md` | finite/fBNAlp    | LP relaxation, rectangle             | done |
| `BNAsim.md` | infinite/BNAsim  | DES, infinite buffer                 | done |
| `fBNAsim.md`| finite/fBNAsim   | DES, finite buffer (BAS / Loss)      | done |
| `BNAmc.md`  | infinite/BNAmc   | MLMC (Blanchet-Chen-Glynn-Si 2021)   | done |

---

## Cross-cutting findings

### Family-wide footguns (recurring across solvers)

1. **`exit(0)` on user errors** — every analytical solver returns success exit code on parse / dimension / configuration errors. Run Comparison and `test.sh` parse this as success and move on. **One-line fix per solver, ten solvers.**
2. **Silent dimension-cap truncation** — most solvers refuse `d > MAX_DIM` cleanly, but `BNAsm` silently truncates output past `BNET_MAX_DIM = 64` (means past index 64 are lost without warning). Same pattern in `BNAsm`'s `CC_MAX = 64` for customer classes.
3. **No `bnet_memcheck` in BNAqna, BNAsbd, BNAlp, fBNAlp, BNAsim, fBNAsim, BNAmc** — only BNAsm, fBNAsm, fBNAfm use the existing `common/bnet_memcheck.h` pre-flight RAM check. The other seven can OOM-thrash on misconfigured inputs.
4. **Reflection-matrix layout convention drift** — fBNAsm interleaves `R[i, 2k] / R[i, 2k+1]`, fBNAfm groups columns 0..d-1 lower then d..2d-1 upper, fBNAlp uses two separate matrices `R / R_plus`. Three solvers, three conventions, one GUI exporter trying to keep them all happy.
5. **Stack-overflow at `MAX_NODES > 512`** — BNAqna and BNAsbd both have function-local `MAX_NODES²` matrices on the stack. Bumping `MAX_NODES` to 1024 to "make room" causes immediate segfaults on every input including n=4. Heap-allocate per-call scratch.
6. **No multi-class data path in BNAsbd** — silently aggregates classes; the GUI shows it as a multi-class result.

### Family-wide quality differences

| Aspect | Worst | Best |
|---|---|---|
| RNG quality | BNAsim (LCG, period 2³²) | fBNAsim, BNAmc (xoshiro256\*\*, period 2²⁵⁶) |
| Memory pre-flight | BNAqna, BNAsbd (none) | BNAsm, fBNAsm, fBNAfm (`bnet_memcheck`) |
| Modularity | BNAsim (one 2058-LOC file) | fBNAsim (7 files, clean interfaces) |
| Adaptive sampling | BNAsim, fBNAsim (none) | BNAmc (`--adaptive`, SE-target stop) |
| Backend dispatch | most (one path) | BNAlp/fBNAlp (vtable: HiGHS/CPLEX/GLPK), BNAmc (Accelerate/OpenMP/serial), fBNAsim (sequential/OpenMP/GCD) |
| Sparse autodetection | most (dense) | BNAmc (auto-detects Σ and R sparsity per run), BNAlp (per-row relative-tolerance gate) |
| Verbose introspection | BNAsim (terse) | BNAmc (Σ/R nnz ratios, T, L, N, threads), BNAlp (per-step timings) |

### Family-wide opportunity for code consolidation

Three recurring patterns are reimplemented in multiple solvers and would benefit from extraction to `common/`:

| Pattern | Currently in | Should live in |
|---|---|---|
| Progress file (`-P PATH`) | BNAsm, BNAsim, fBNAsm, fBNAfm, fBNAsim, BNAmc | `common/bnet_progress.h` |
| `xoshiro256**` RNG | fBNAsim, BNAmc; would replace BNAsim's LCG | `common/rng.h` |
| Distribution sampling (9 distributions) | BNAsim, fBNAsim | `common/distributions.h` |

---

## The 10 highest-leverage changes across the entire codebase

Ranked by `(impact × likelihood-of-firing) / effort`:

| # | Change | File(s) | Effort |
|---:|---|---|---:|
| 1 | **Replace BNAsim's LCG with fBNAsim's xoshiro256\*\*** | `infinite/BNAsim/jackson_sim.c:300` → use `finite/fBNAsim/rng.c` | 1 d |
| 2 | **Fix `exit(0) → exit(EXIT_FAILURE)` on errors across all 10 solvers** | one-line per solver | 0.5 d |
| 3 | **Fix BNAsbd's relative `bnet` path** (`../BNAsm/bnet`) | `infinite/BNAsbd/bna_sbd.c:506` | 0.25 d |
| 4 | **Heap-allocate BNAqna/BNAsbd's stack scratch** so `MAX_NODES > 512` works | `infinite/BNAqna/bna_qna.c:386`, `infinite/BNAsbd/bna_sbd.c:543` | 1 d each |
| 5 | **Apply Whitt-1993 g-factor in QNA's `m ≥ 2` branch** | `infinite/BNAqna/bna_qna.c:555–561` | 0.25 d |
| 6 | **Add `bnet_memcheck` to BNAqna, BNAsbd, BNAlp, fBNAlp, BNAsim, fBNAsim, BNAmc** | one block per solver | 1 d total |
| 7 | **Auto-dispatch fBNAfm's CBC backend at K ≥ 5** | `Sources/Qnet/QnetGUIApp.swift` finder + `finite/fBNAfm/bna_fm_*` | 1 d |
| 8 | **Pool-allocate BNAsim/fBNAsim's per-customer mallocs** | both simulators | 1 d each |
| 9 | **Wire BNAmc into `test.sh` as ground-truth alternative** for high-d cases | `test.sh` + `Sources/Qnet/QnetGUIApp.swift` | 1 d |
| 10| **Loud failure when bnet's Cholesky fails (auto-retry LU / regularised LU)** | `infinite/BNAsm/bnet.c:362–387` | 0.5 d |

Total effort estimate: **~10 person-days** for *all ten*.

Most of these are bug-fix-class changes, not algorithmic improvements. The four largest *algorithmic* opportunities — Allen-Cunneen + Whitt 1993 in QNA, per-class variability fixed-point in QNA (Whitt 1988), library mode for the spectral solvers, and Reiman-Wein iterative refinement — are 3-5 day items each, separately documented in the relevant `.md` files.

---

## Suggested execution order

1. **Bug sweep (week 1)**: items 1, 2, 3, 5, 10. Closes the silent-failure footguns.
2. **Memory hygiene (week 2)**: items 4, 6, 8. Closes the OOM / stack-overflow class.
3. **GUI integration (week 3)**: item 7, item 9, plus library-mode extraction. Closes the user-experience gaps.
4. **Algorithm work (months)**: per-solver improvements as ranked in each `.md` file.
