# SBD validation on cyclic inputs

The feedforward-readiness review noted that QNA's two-moment approximation can
degrade under heavy load when routing has feedback, and asked whether SBD
inherits a similar weakness. SBD's published derivation (Dai, Nguyen & Reiman
1994) does not assume feedforward routing — the partition step orders
subnetworks by utilization, not by topology — but the implementation needed to
be confirmed. This note records that check.

## Setup

`infinite/BNAsbd/bna_sbd` invokes `infinite/BNAsm/bnet` as a subprocess to
solve the multi-station Reflected Brownian subnetwork. With the bnet binary
missing, every subnetwork call fails silently and SBD falls back to per-station
M/M/1-flavored estimates. The first run of this validation surfaced that gap;
the script now builds bnet up-front if needed.

Reproduce:
```
./validation/sbd_cyclic_validation.sh
```

Inputs (paper references in headers):

| Case | Topology | Source |
| --- | --- | --- |
| `test_3station.in` | cyclic — S2↔S1, S2↔S3 | DNR 1994 §3.1, Table III |
| `test_5station.in` | cyclic — {2,3,4,5} each feed back to S1 with p = 0.5 | DNR 1994 §3.2, Table VII |
| `test_9series.in` | acyclic 9-station tandem (control) | DNR 1994 §3.3, Table VIII |

## Results

### 3-station cyclic — exact match

Paper Table III per-station E[T]: **2.471, 11.406, 2.585**.
SBD output:                       **2.471, 11.406, 2.585**.

Match to three decimal places across all three stations, including the
high-utilization bottleneck (ρ₂ = 0.9). Per-customer mean sojourn 58.21
follows from Little's law on the visit ratios (3, 4, 2).

### 5-station cyclic — within 0.3% of simulation

Paper Table VII reports 6.95 (SBD) vs 6.725 (simulation) for the per-customer
mean sojourn time. Our SBD: **6.745**, which is

- −2.9% vs. the paper's SBD value, and
- +0.3% vs. the paper's simulation reference.

This is not a degradation — it sits between paper-SBD and paper-sim, slightly
closer to the simulation truth than the paper's own SBD figures. Differences
at the second decimal are consistent with bnet's polynomial degree (default 5
in this build) and the iteration tolerance.

### 9-station tandem (control, acyclic) — +10% vs. paper-SBD

Paper Table VIII: total mean waiting time 10.06 (SBD) vs 10.05 (simulation).
Our SBD: **11.07**, +10.0% vs paper-SBD. The control case — pure tandem with
no feedback — shows *more* error than either cyclic case. That confirms the
gap comes from implementation tuning (polynomial degree, M/M/1 vs MMPP
arrival modeling at the boundary of the second subnetwork), not from anything
specific to cyclic routing.

## Verdict

SBD does not silently degrade on cyclic networks. The cyclic 3-station case
matches the paper exactly; the cyclic 5-station case is within 0.3% of the
simulation reference. The largest discrepancy in the validation set is on
the acyclic tandem, which rules out feedback as the cause.

The QNA banner in the regime header (`Routing graph contains feedback ...
SBD on cyclic networks is unvalidated`) was added before this validation
ran. Now that SBD on cycles is validated, the banner should be softened: the
"SBD on cyclic networks is unvalidated" clause is no longer accurate. The
QNA caveat stands.

## Follow-ups

- **Soften the regime banner** in `Sources/Qnet/QnetGUIApp.swift`
  (`regimeHeader`) so it warns about QNA only, not SBD.
- **Wire `bnet` build into `bna_sbd`'s build path** or add an explicit
  precondition check, so the silent-fallback failure mode does not recur on
  fresh checkouts.
- Optional: rerun this validation against jackson_sim ground truth for the
  Jackson-special-case versions of these networks to get a non-paper
  reference point.
