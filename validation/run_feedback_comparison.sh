#!/usr/bin/env bash
# Drive Run-Comparison's analytical solvers and simulation (Spectral, QNA,
# RQNA, SBD, jackson_sim) on
# every feedback / reentrant network in input/examples/ and capture per-station
# rho, throughput Gamma, sojourn, and queue length so we can compare the three
# analytical approximations against simulation (the ground-truth baseline).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QNET="$ROOT/.build/debug/Qnet"
QNA="$ROOT/infinite/BNAqna/bna_qna"
RQNA="$ROOT/infinite/BNArqna/bna_rqna"
SBD="$ROOT/infinite/BNAsbd/bna_sbd"
SIM="$ROOT/infinite/BNAsim/jackson_sim"
SM="$ROOT/infinite/BNAsm/bnet"
OUT="$ROOT/validation/feedback_runs"
EX="$ROOT/input/examples"

mkdir -p "$OUT"

# Networks with feedback (station-graph cycle). Ordered by complexity.
networks=(
  "DaiNguyenReiman94.d3.c1.1.inf.bnet"
  "DaiHarrison92.d2.c2.1.inf.bnet"
  "GuangChenDaiGlynn25.sec3.2.2d.inf.bnet"
  "GuangChenDaiGlynn25.sec3.3.3d.inf.bnet"
  "KumarSeidman90.d2.c4.reentrant.inf.bnet"
  "LuKumar91.d2.c5.reentrant.inf.bnet"
  "Bramson94.d2.c5.reentrant.inf.bnet"
  "Bramson94.d3.c5.reentrant.inf.bnet"
  "DaiMeyn95.d3.c9.reentrant.inf.bnet"
  "BanksDai96.d3.c9.spt.reentrant.inf.bnet"
)

SIM_REPS=${SIM_REPS:-100}
SIM_RUN=${SIM_RUN:-2000}

for net in "${networks[@]}"; do
  base="${net%.bnet}"
  dir="$OUT/$base"
  mkdir -p "$dir"
  echo "================================================================"
  echo "  $net"
  echo "================================================================"

  "$QNET" --export-cmp "$EX/$net" "$dir" >/dev/null

  echo "--- Spectral (bnet $dir/cmp_sm.in) ---" | tee "$dir/sm.out" >/dev/null
  ( "$SM" -c "$dir/cmp_sm.in" 2>&1 || true ) >> "$dir/sm.out"

  echo "--- QNA (bna_qna $dir/qna.qna -c) ---"  | tee "$dir/qna.out" >/dev/null
  ( "$QNA" "$dir/qna.qna" -c 2>&1 || true ) >> "$dir/qna.out"

  echo "--- RQNA (bna_rqna $dir/qna.qna -c) ---" | tee "$dir/rqna.out" >/dev/null
  ( "$RQNA" "$dir/qna.qna" -c 2>&1 || true ) >> "$dir/rqna.out"

  echo "--- SBD (bna_sbd $dir/qna.qna -c) ---"  | tee "$dir/sbd.out" >/dev/null
  ( "$SBD" "$dir/qna.qna" -c 2>&1 || true ) >> "$dir/sbd.out"

  echo "--- Sim (jackson_sim, n=$SIM_REPS, run=$SIM_RUN) ---" | tee "$dir/sim.out" >/dev/null
  ( "$SIM" "$dir/cmp_sim.sim" -c -n "$SIM_REPS" -r "$SIM_RUN" 2>&1 || true ) >> "$dir/sim.out"
done

echo "Done. Raw outputs under $OUT/"
