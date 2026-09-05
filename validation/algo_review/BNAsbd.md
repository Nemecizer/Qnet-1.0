# BNAsbd — review

**Solver:** `infinite/BNAsbd/bna_sbd`
**Source:** `infinite/BNAsbd/bna_sbd.c` (1013 LOC, single file, plain C, `-O2`)
**Method:** Sequential Bottleneck Decomposition (Dai-Nguyen-Reiman 1994). Stations are partitioned by ρ-proximity into ordered subnetworks; each subnetwork is solved as a Reflected Brownian Motion (RBM) by shelling out to `infinite/BNAsm/bnet`.
**Empirical work backing this review:** `validation/algo_review/work/bnasbd/`

---

## 1. Current implementation

| Step | Function | Lines | Method | Cost |
|---|---|---|---|---|
| 1 | `parse_input`             | 86–180 | same QNA-format reader as bna_qna | O(n²) |
| 2 | `solve_traffic`           | 187–249 | dense LU on `(I − Pᵀ) λ = α` | O(n³) |
| 3 | `partition_stations`      | 297–346 | sort by ρ, group when `ρ_max/ρ_min > 1.5` or size > 5 | O(n log n) |
| 4 | `solve_subnetwork` × g    | 543–850 | RBM via popen-call to `bnet`; 1-D analytic fallback when |B|=1 or bnet fails | O(d_g³ + bnet) per group |
| 5 | `compute_sojourn`         | 856–863 | Little's law per station | O(n) |

Static arrays: `MAX_NODES = 64`, `MAX_GROUPS = 64`. Like QNA, all scratch matrices are function-local stack allocations. RBM solves are dispatched as separate `bnet` processes via `popen("../BNAsm/bnet -v 0 …")`.

External deps: `libm`, plus a runtime dependency on the sibling `bnet` binary at the relative path `../BNAsm/bnet`.

---

## 2. Empirical performance

### 2.1 Wall-time (same harness as QNA, sparse tandem)

| n | bna_sbd time | bna_qna time | ratio |
|---:|---:|---:|---:|
|  4 |   21 ms |  1.7 ms | 12× |
|  8 |   37 ms |  1.6 ms | 23× |
| 16 |   55 ms |  2.6 ms | 21× |
| 32 |  120 ms |  2.7 ms | 44× |
| 64 |  220 ms |  2.6 ms | 85× |

SBD is 10–80× slower than QNA. Cause: each subnetwork dispatches a separate `bnet` process via `popen` (`bna_sbd.c:506`). At default partition size ~5, an n=64 network produces ~13 groups, each costing ~15 ms of `bnet` startup + spectral solve. The numerical work in SBD itself is small; **process launch dominates**.

### 2.2 The same `MAX_NODES` stack-overflow bug as QNA

SBD's `solve_subnetwork` (`bna_sbd.c:543`) holds **6** function-local `MAX_NODES²` matrices on the stack (`Ptilde`, `Qtilde`, `Phat`, `Ghat`, `Omega`, `Rhat`), plus `invert_matrix`'s `2·MAX_NODES²` workspace `W`. Total stack frame:

| `MAX_NODES` | per-call stack | observed |
|---:|---:|---|
|  64 |  0.2 MB | works |
| 256 |  4.0 MB | works (close to ceiling) |
| 512 | 16.0 MB | **always segfaults** |
| 1024| 64.0 MB | **always segfaults** (verified: exit 139 on n=8 input) |

The fix is the same as QNA: heap-allocate the per-call scratch sized to actual `nB` / `n`.

---

## 3. Empirical accuracy — multiple silent-fallback bugs

### 3.1 The relative-path bug to `bnet` (already noted in `validation/feedback_networks_validation.md` §A)

`bna_sbd.c:506`:

```c
snprintf(cmd, sizeof(cmd), "../BNAsm/bnet -v 0 %s 2>/dev/null", tmpname);
```

This only resolves when SBD is invoked with cwd = `infinite/BNAsbd`. Run Comparison invokes SBD with cwd = a temp directory, so the `bnet` launch *always* fails. The failure is detected (`if (count != dim) return -1`) but the recovery is to silently re-run each station with a 1-D RBM approximation (lines 830–844).

Reproduced:

```
$ cd /tmp && bna_sbd /tmp/sbd_dnr94/qna.qna -c
bna_sbd: bnet returned 0 values, expected 2
bna_sbd: bnet failed for subnetwork 1 (stations 1 2)
SBD (BNAsbd)
rho_1 = 0.700000
sojourn_1 = 1.687501   <-- 1-D fallback
$ cd .../BNAsbd && ./bna_sbd /tmp/sbd_dnr94/qna.qna -c
SBD (BNAsbd)
sojourn_1 = 1.583334   <-- "real" multi-station RBM
```

Note the stderr lines never reach the GUI's terminal pane (they go to stderr, not stdout), so a Run Comparison user has no signal that the fallback is in use.

### 3.2 The fallback is sometimes *more accurate* than the intended RBM solve

This is the wrinkle. On all the multi-class re-entrant cases, the 1-D fallback and the multi-station RBM diverge — and not always in favor of RBM:

| Network | Method | sojourn_1 | sojourn_2 | sim sojourn |
|---|---|---:|---:|---:|
| KumarSeidman90 | 1-D fallback | 1.688 | 1.688 | 2.132 |
| KumarSeidman90 | multi-D bnet | 1.583 | 1.583 | 2.133 |
| LuKumar91      | 1-D fallback | 2.530 | 2.009 | 2.089 |
| LuKumar91      | multi-D bnet | 1.983 | 1.724 | 2.527 |

For LuKumar91 the fallback's `sojourn_1 = 2.53` is closer to sim's `2.09` than the multi-D `1.98`; the fallback's `sojourn_2 = 2.01` is *worse* than multi-D's `1.72` (sim is 2.53, both miss). So fixing the relative-path bug is not unambiguously an accuracy win — it changes the SBD output, and on the documented multi-class re-entrant cases the change can be in either direction.

This is consistent with the literature: at FIFO multi-class re-entrant networks the moment-closure approximations are simply *off*, and which off-version you get is partly accidental.

### 3.3 High polynomial degree silently breaks bnet too

`-n` controls bnet's polynomial degree. Default 5. Tested at 3, 5, 8, 12 on Lu-Kumar:

```
degree= 3  sojourn_1 = 1.970  sojourn_2 = 1.734
degree= 5  sojourn_1 = 1.983  sojourn_2 = 1.724    [default]
degree= 8  sojourn_1 = 1.984  sojourn_2 = 1.724
degree=12  sojourn_1 = 2.530  sojourn_2 = 2.009    [identical to fallback!]
```

At degree 12, bnet's Cholesky factorization fails with "matrix not positive definite", so SBD silently falls back to the 1-D approximation. The deg=12 numbers above are **not** a deg=12 solution — they're the fallback output, indistinguishable from the deg≤8 output to anyone not watching stderr.

So users who increase polynomial degree expecting "more accuracy" get *worse* approximation (the fallback) plus a stderr message they probably don't see.

### 3.4 No multi-class data path

SBD parses only the single-class section of the QNA-format input (`bna_sbd.c:173` returns immediately after the `P` matrix). The `customer_classes`, `cc_alpha`, `cc_mu` blocks added by `BNASRBMExporter` for QNA are silently ignored. SBD treats every multi-class network as if it were single-class with aggregated rates.

For Lu-Kumar / Kumar-Seidman this is consistent with the original Dai-Nguyen-Reiman 1994 paper (single-class only), but misleading: the GUI shows SBD column as if it represents a full multi-class analysis. A clearer design would either (a) emit a warning that classes are being ignored, or (b) extend SBD to per-class flows.

### 3.5 Other silent input mutations

- `servers[i] < 1 → 1` (`bna_sbd.c:112`) without warning. Not actually harmful (SBD assumes `m=1` everywhere), but worth logging.
- `tmpname = "/tmp/bna_sbd_<pid>.in"` (`bna_sbd.c:470`) — fine for unique per-process, fails to handle the case where two SBDs are forked from the same shell (different pid, fine; same pid via fork-without-exec, race).

---

## 4. Recommendations, ranked

| Rank | Change | Effort | Evidence | Impact |
|---:|---|---:|---|---|
| **R1** | Fix relative path to `bnet` (env var `BNET_BIN`, or `argv[0]`-based discovery, or absolute symlink) | 0.25 d | §3.1 — bug fires on every Run Comparison invocation | Removes silent fallback; output then reflects the documented method |
| **R2** | Fail loudly on bnet failure: write the failure into the SBD report header so the user knows the fallback engaged | 0.25 d | §3.1, §3.3 — stderr messages don't reach the GUI | Visibility — fix R1 first or this fires on every run |
| **R3** | Heap-allocate the scratch matrices in `solve_subnetwork` and `invert_matrix`; drop `MAX_NODES` | 1 d | §2.2 — same stack-overflow cliff as QNA | Unblocks n > 256 |
| **R4** | Cache `bnet` output across subnetwork solves: link `bnet` as a library, or have SBD batch-write all subnetwork inputs and let one `bnet` invocation process them in sequence | 2 d | §2.1 — popen overhead is ~95 % of wall time | 5–20× speedup |
| **R5** | Auto-fallback on bnet's Cholesky failure: `bnet -l` (LU mode) before falling back to 1-D | 0.25 d | §3.3 — high-degree silently fails today | Accuracy at high polynomial degree |
| **R6** | Convergence study mode: `bna_sbd --auto-degree` runs degrees 4, 6, 8, 10, 12 and stops when relative change < ε; warns if the sequence didn't converge | 1 d | §3.3 — no guidance on choosing `-n` | User-facing correctness |
| **R7** | Per-class mode: parse the multi-class section of the QNA file; build per-class arrival/service moments and feed a class-aggregated `Ghat` per Reiman 1990 | 4 d | §3.4 — currently silently aggregates | Multi-class re-entrant accuracy (still bounded by moment-closure limit) |
| **R8** | Bigger partitions for low-`n` networks: at `n ≤ 8` skip partitioning entirely (one group); the bnet RBM solve is robust at small dimension | 0.5 d | §2.1 — 13 popen calls for n=64 with default size-5 cap | Speed and arguably accuracy |
| **R9** | Document the partition heuristic — paper Section 2.2 calls for a *bottleneck-aware* partition (groups around traffic bottlenecks), not the current "sort by ρ" | 1 d | partition heuristic is unjustified relative to source | Closes a literature gap; potential accuracy win |
| **R10**| LU-instead-of-Gauss-Jordan for `invert_matrix`; use LAPACK `dgesv` for `solve_traffic` | 0.5 d | §2.1 — numerics are not currently bottleneck | Cleaner code, marginal speed |

### Engineering hygiene

- `popen + 2>/dev/null` swallows bnet's stderr — bad for debugging. At minimum capture it into a log line.
- `remove(tmpname)` is called only on success; on early-return paths (the `count != dim` branch returns -1 *after* `remove`, so this is OK in practice — but the temp file leaks if `popen` itself fails before the `remove`).
- Use `mkstemp` instead of hard-coded `/tmp/bna_sbd_<pid>.in` for portability and TOCTOU safety.
- Add a `--print-partition` flag (or always print it) so users can see how SBD chose the groups; the partition is the single most important accuracy lever.

---

## 5. Suggested order of work

If you do nothing else: **R1 + R2**. Half a day combined; closes a documented bug that fires on every GUI invocation today, and makes future failures visible. The accuracy "win" from R1 is non-monotone (§3.2), but at minimum the user is now seeing the algorithm SBD claims to be running.

Next tier: **R3 (heap)** because it's the same fix as QNA's R1 and they should land together. Then **R4 (popen amortization)** — biggest speed win, opens up larger networks.

R7 (per-class) is the only path to closing the documented Lu-Kumar gap from the SBD side, but it's a 4-day job and the gain is bounded by the same moment-closure limit that constrains QNA.

---

## 6. Test plan when changes land

- R1: `test.sh` starts running SBD against networks and the per-station sojourn changes. Capture the new values into `.testcases/*.expected` so tests calibrate against the post-fix output.
- R3: bench at MAX-removed binary on n = 256, 512, 1024 sparse tandem; verify no regression vs current at n ≤ 64.
- R4: end-to-end timing on the 10-network feedback validation suite — should drop from ~10 s to ~1 s.
- R5: verify deg=12 on Lu-Kumar produces a *different* answer than deg=5 (not the silent fallback).
- R6: on Lu-Kumar, log the deg-by-deg progression and confirm convergence at deg=8.
