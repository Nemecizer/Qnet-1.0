#!/usr/bin/env python3
"""
Exact CTMC solver for a d-station single-class M/M/1 tandem with finite buffers.

State (n_1, ..., n_d) where 0 <= n_i <= K_i and K_i = buffer_i + 1 (server slot
included, matching Qnet's SRBM convention). Supported blocking mode:

  loss          arrivals to a full station drop; same for internal handoff
                (S_i finishes service when S_{i+1} is full -> customer dropped)
For d=2 this matches `ctmc_tandem.py`. For d > 2 it is the natural product-
state extension. Multi-class is intentionally NOT supported — the Run
Comparison wiring falls back to a no-CTMC column when K > 1 or any service
distribution is not exponential. True blocking-after-service needs an explicit
blocked-server state and is intentionally not approximated here.

Output (one line per metric, parsable by Qnet's awk aggregator):

    rho_<i> = ...
    Gamma_<i> = ...
    sojourn_<i> = ...
    E[X_<i>] = ...

Usage:
    python3 ctmc_dtandem.py --buffers 10 10 10 10 --servers 1 1 1 1 \\
                            --lam 0.9 --mu 1.0 1.0 1.0 1.0 \\
                            --mode loss
"""
from __future__ import annotations
import argparse
import sys
import numpy as np
from itertools import product


def solve_dtandem(buffers: list[int], servers: list[int],
                  lam: float, mu: list[float],
                  mode: str = "loss") -> dict:
    d = len(buffers)
    if not (d >= 1 and len(mu) == d and len(servers) == d):
        raise ValueError("buffers, servers, and service rates must have equal nonzero length")
    if mode != "loss":
        raise ValueError("ctmc_dtandem supports loss-on-full only; true BAS needs blocked-server state")
    if any(server != 1 for server in servers):
        raise ValueError("ctmc_dtandem is an M/M/1 tandem solver; every server count must equal 1")
    if any(buffer < 0 for buffer in buffers):
        raise ValueError("buffer sizes must be nonnegative")
    if not (np.isfinite(lam) and lam > 0):
        raise ValueError("the external arrival rate must be finite and positive")
    if any(not np.isfinite(rate) or rate <= 0 for rate in mu):
        raise ValueError("every service rate must be finite and positive")
    # Capacity per station = buffer + 1 server slot (single-server tandem).
    K = [b + s for b, s in zip(buffers, servers)]
    shape = tuple(k + 1 for k in K)
    nstates = 1
    for s in shape:
        nstates *= s
    if nstates > 1_000:
        raise ValueError(
            f"state space {nstates} exceeds the 1,000-state dense-solve safety cap"
        )

    # Index helpers
    strides = [1] * d
    for i in range(d - 2, -1, -1):
        strides[i] = strides[i + 1] * shape[i + 1]

    def idx(state):
        s = 0
        for i, n in enumerate(state):
            s += n * strides[i]
        return s

    Q = np.zeros((nstates, nstates), dtype=np.float64)

    for state in product(*(range(k + 1) for k in K)):
        i = idx(state)
        # External arrival to S_1.
        if state[0] < K[0]:
            new = list(state); new[0] += 1
            Q[i, idx(tuple(new))] += lam
        # Otherwise the external arrival is lost.
        # Service at S_k for k = 1..d-1 -> moves customer to S_{k+1}.
        for k in range(d - 1):
            if state[k] > 0:
                if state[k + 1] < K[k + 1]:
                    new = list(state); new[k] -= 1; new[k + 1] += 1
                    Q[i, idx(tuple(new))] += mu[k]
                elif mode == "loss":
                    # S_{k+1} is full and we're in loss mode: completed
                    # customer at S_k is dropped (internal loss).
                    new = list(state); new[k] -= 1
                    Q[i, idx(tuple(new))] += mu[k]
        # Service at the last station -> exits the network.
        if state[d - 1] > 0:
            new = list(state); new[d - 1] -= 1
            Q[i, idx(tuple(new))] += mu[d - 1]

    # Diagonal = -row sum
    for i in range(nstates):
        Q[i, i] = -Q[i, :].sum()

    # Solve pi Q = 0 with sum(pi) = 1: replace last column of Q^T with ones
    # and last row of RHS with 1. Standard normalization trick.
    A = Q.T.copy()
    b = np.zeros(nstates)
    A[-1, :] = 1.0
    b[-1] = 1.0
    pi = np.linalg.solve(A, b)
    if pi.min() < -1e-9:
        print(f"warning: negative probability {pi.min():.3e}", file=sys.stderr)
    pi = np.clip(pi, 0.0, None)
    pi /= pi.sum()

    # Marginal stats
    EX = [0.0] * d
    busy = [0.0] * d
    full = [0.0] * d
    for state in product(*(range(k + 1) for k in K)):
        p = pi[idx(state)]
        for k in range(d):
            EX[k] += state[k] * p
            if state[k] >= 1:
                busy[k] += p
            if state[k] == K[k]:
                full[k] += p

    # In loss mode every busy server completes at rate mu, including a
    # completion whose attempted internal handoff is dropped.
    Gamma = [0.0] * d
    for state in product(*(range(k + 1) for k in K)):
        p = pi[idx(state)]
        for k in range(d):
            if state[k] == 0:
                continue
            if k == d - 1:
                Gamma[k] += mu[k] * p
            else:
                Gamma[k] += mu[k] * p

    rho = [Gamma[k] / mu[k] if mu[k] > 0 else 0.0 for k in range(d)]
    sojourn = [EX[k] / Gamma[k] if Gamma[k] > 1e-15 else float("nan")
               for k in range(d)]
    external_loss = lam * full[0]

    return {
        "rho": rho, "Gamma": Gamma, "EX": EX, "sojourn": sojourn,
        "external_loss": external_loss, "P_full": full,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--buffers", type=int, nargs="+", required=True,
                    help="buffer slot count per station (excludes server)")
    ap.add_argument("--servers", type=int, nargs="+", required=True,
                    help="server count per station")
    ap.add_argument("--lam", type=float, required=True,
                    help="external arrival rate at S_1 (single class)")
    ap.add_argument("--mu", type=float, nargs="+", required=True,
                    help="service rate per station")
    ap.add_argument("--mode", choices=["loss"], default="loss")
    ap.add_argument("--grid", action="store_true",
                    help="emit grid-format output (E[X_k] = ...) for Qnet")
    args = ap.parse_args()

    if not (len(args.buffers) == len(args.servers) == len(args.mu)):
        print("ERROR: --buffers, --servers, --mu must all have the same length",
              file=sys.stderr)
        sys.exit(1)
    r = solve_dtandem(args.buffers, args.servers, args.lam, args.mu, args.mode)

    if args.grid:
        print("CTMC (exact loss)")
        print("==================")
        d = len(args.buffers)
        for k in range(d):
            print(f"rho_{k+1} = {r['rho'][k]:.6f}")
        print()
        for k in range(d):
            print(f"Gamma_{k+1} = {r['Gamma'][k]:.6f}")
        print()
        for k in range(d):
            sj = r["sojourn"][k]
            print(f"sojourn_{k+1} = {sj if not np.isnan(sj) else 0.0:.6f}")
        print()
        for k in range(d):
            print(f"E[X_{k+1}] = {r['EX'][k]:.6f}")
        return

    d = len(args.buffers)
    print(f"  mode               : {args.mode}")
    print(f"  d                  : {d}")
    print(f"  buffers            : {args.buffers}")
    print(f"  servers            : {args.servers}")
    print(f"  lambda, mu         : {args.lam:.4f}, {args.mu}")
    for k in range(d):
        sj = r["sojourn"][k]
        print(f"  S{k+1}: rho={r['rho'][k]:.6f}  Gamma={r['Gamma'][k]:.6f}  "
              f"E[X]={r['EX'][k]:.6f}  sojourn={sj:.6f}  P(full)={r['P_full'][k]:.6f}")
    print(f"  external loss rate : {r['external_loss']:.6f}")


if __name__ == "__main__":
    main()
