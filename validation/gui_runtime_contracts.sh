#!/usr/bin/env bash
# Source-level and shell-behaviour contracts for GUI solver launch wrappers.

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI_SOURCE="$CHECK_ROOT/Sources/Qnet/QnetGUIApp.swift"
SRBM_SOURCE="$CHECK_ROOT/Sources/Qnet/SRBMExporter.swift"
CTMC_SOURCE="$CHECK_ROOT/finite/fBNActmc/ctmc_dtandem.py"

fail() {
    printf 'GUI runtime contract failed: %s\n' "$*" >&2
    exit 1
}

cleanup_calls="$(grep -F -c 'command: commandWithCleanup(solve, paths: [inputFile.path])' "$GUI_SOURCE")"
[[ "$cleanup_calls" -eq 8 ]] \
    || fail "expected 8 Python runners to use cancellation-safe cleanup; found $cleanup_calls"
grep -Fq 'trap cleanup_qnet_solver_inputs EXIT' "$GUI_SOURCE" \
    || fail "Python cleanup wrapper lacks an EXIT trap"
grep -Fq "trap 'exit 130' INT TERM" "$GUI_SOURCE" \
    || fail "Python cleanup wrapper lacks signal traps"
if grep -Eq 'command: "\{ .*_solver_rc=.*rm -f' "$GUI_SOURCE"; then
    fail "a Python runner still relies on unreachable trailing cleanup"
fi

# Exercise the signal/EXIT trap pattern independently: TERM must still remove
# the exported input even though the body never reaches a trailing command.
cleanup_probe="$(mktemp "${TMPDIR:-/tmp}/qnet-cleanup-contract.XXXXXX")"
set +e
QNET_CLEANUP_PROBE="$cleanup_probe" bash -c '
    cleanup_contract_probe() { rm -f "$QNET_CLEANUP_PROBE"; }
    trap cleanup_contract_probe EXIT
    trap "exit 130" INT TERM
    kill -TERM "$$"
'
probe_status=$?
set -e
[[ "$probe_status" -eq 130 ]] || fail "signal trap returned $probe_status, expected 130"
[[ ! -e "$cleanup_probe" ]] || fail "signal trap left its temporary input behind"

grep -Fq 'guard blocking == 0 else { return nil }' "$GUI_SOURCE" \
    || fail "dense tandem CTMC is not restricted to exact loss semantics"
grep -Fq 'data.numberOfServers.allSatisfy({ $0 == 1 })' "$GUI_SOURCE" \
    || fail "dense tandem CTMC is not restricted to M/M/1 stations"
grep -Fq 'classExternalArrivalRates: lambdaExt' "$SRBM_SOURCE" \
    || fail "per-station external arrival rates are not retained"
grep -Fq 'external.dropFirst().allSatisfy' "$GUI_SOURCE" \
    || fail "tandem CTMC does not reject external arrivals after station 1"
grep -Fq 'stateSpace <= 1_000 / factor' "$GUI_SOURCE" \
    || fail "dense tandem CTMC lacks its overflow-safe 1,000-state cap"
grep -Fq 'QNET_METHOD_FAILURE_V1 method=ctmc' "$GUI_SOURCE" \
    || fail "failed optional CTMC output lacks a non-empty method sentinel"
grep -Fq '"exact CTMC runtime": ctmcRuntimeProvenance' "$GUI_SOURCE" \
    || fail "finite comparison does not record optional CTMC runtime provenance"

grep -Fq 'if mode != "loss"' "$CTMC_SOURCE" \
    || fail "standalone tandem CTMC does not reject inexact BAS semantics"
grep -Fq 'any(server != 1 for server in servers)' "$CTMC_SOURCE" \
    || fail "standalone tandem CTMC does not reject multi-server input"
grep -Fq 'if nstates > 1_000:' "$CTMC_SOURCE" \
    || fail "standalone tandem CTMC lacks its dense-solve state cap"

grep -Fq 'gammaIsNativeCompatible' "$GUI_SOURCE" \
    || fail "MLMC launch does not preflight integral reciprocal gamma"
grep -Fq 'minimum >= 2, maximum >= 2' "$GUI_SOURCE" \
    || fail "MLMC adaptive launch permits a one-sample variance estimate"
grep -Fq '# Replication %d: seed=%s N=%s stop=%s' "$GUI_SOURCE" \
    || fail "MLMC aggregation omits realized per-replication provenance"

# ── Edit ▸ Undo / Redo describe themselves from the decision they act on ──
# Blocker R5 (rounds 2-5): the item was titled from the document's undo
# manager while the keystroke went to an invisible text field's, so
# "Undo Add Station" was enabled, was pressed, and did nothing. Title,
# enablement and action must all read ONE routing decision.
COMMANDS_SOURCE="$CHECK_ROOT/Sources/Qnet/QnetCommands.swift"
TERMINAL_SOURCE="$CHECK_ROOT/Sources/Qnet/TerminalModel.swift"

expect_count() { # expect_count <n> <literal> <file>
    local want="$1" lit="$2" file="$3" got
    got="$(grep -F -c -- "$lit" "$file" || true)"
    [[ "$got" -eq "$want" ]] \
        || fail "expected $want occurrence(s) of '$lit' in $(basename "$file"); found $got"
}
expect_at_least() { # expect_at_least <n> <literal> <file>
    local want="$1" lit="$2" file="$3" got
    got="$(grep -F -c -- "$lit" "$file" || true)"
    [[ "$got" -ge "$want" ]] \
        || fail "expected at least $want occurrence(s) of '$lit' in $(basename "$file"); found $got"
}

expect_count 1 'let undo = undoRouting(redo: false)' "$COMMANDS_SOURCE"
expect_count 1 'let redo = undoRouting(redo: true)'  "$COMMANDS_SOURCE"
expect_count 1 '.disabled(!undo.available)'          "$COMMANDS_SOURCE"
expect_count 1 '.disabled(!redo.available)'          "$COMMANDS_SOURCE"

# ── The menu re-reads the focused field editor's undo stack (round 6) ─────
# `undoRouting` resolves title, enablement and action from non-observable
# AppKit state, so a SwiftUI Commands body only re-evaluated when something
# it observes published. Typing into a DSNumericField (every numeric row in
# Settings) published nothing, so Edit ▸ Undo named a canvas step while ⌘Z
# edited the text. `MenuContext` fixes that by publishing a fingerprint of
# the field editor's own undo stack. NOTHING READS THAT PROPERTY — republishing
# it is the entire mechanism, so it must not be deleted as unused state.
WINDOW_SUPPORT_SOURCE="$CHECK_ROOT/Sources/Qnet/WindowSupport.swift"
expect_count 1 'private static func focusedTextUndoState' "$WINDOW_SUPPORT_SOURCE"
expect_count 1 'if undoState != textUndoState { textUndoState = undoState }' "$WINDOW_SUPPORT_SOURCE"

# ── A stopped run is a cancellation, not a failure (round 6) ──────────────
# `TerminalRunSummary.cancelled` used to pattern-match an exit-code whitelist
# (130, 143). The cancel path escalates SIGINT → SIGTERM → SIGKILL and the
# wrapper reports whichever signal won, so a Stop that ended on 129 was
# reported as "[ERROR] … failed (exit 129)" plus a red-X Failed record. The
# verdict must come from the model's own record that Stop was pressed, and a
# run that exited 0 must never be reclassified as cancelled.
expect_count 1 'userStopped: cancelRequestedAt != nil'      "$TERMINAL_SOURCE"
expect_count 1 'guard exitCode != 0 else { return false }'  "$TERMINAL_SOURCE"
expect_count 1 'store.delete(summary.id)'                   "$GUI_SOURCE"

# ── Stop reaches the work, not just the wrapper ───────────────────────────
# The run's process group is recorded while the wrapper is still alive, the
# escalation targets that group, and the completion file is not believed
# while the group still has members. Without this, Stop retired the run and
# left the solver at ~1750 % CPU until it finished on its own.
expect_count 1 'private func captureActiveRunGroup'      "$TERMINAL_SOURCE"
expect_count 1 'private func cancelSurvivorsOutstanding' "$TERMINAL_SOURCE"
expect_at_least 1 'if self.cancelSurvivorsOutstanding()' "$TERMINAL_SOURCE"
expect_at_least 1 'activeRunGroupIsAlive'                "$TERMINAL_SOURCE"

# ── The check with teeth: a real native run, cancelled the way the GUI
#    cancels it, must be gone inside the cancel deadline ─────────────────
# Source-text contracts cannot see a regression in the *behaviour*; this
# starts a long jackson_sim run in its own process group, sends the same
# SIGINT → SIGTERM escalation TerminalModel sends, and asserts the solver
# is gone within TerminalModel.cancelDeadline (3 s) rather than the ~90 s
# it used to take to finish on its own.
cancel_sim=""
for candidate in \
    "$CHECK_ROOT/Qnet.app/Contents/Resources/bin/infinite/BNAsim/jackson_sim" \
    "$CHECK_ROOT/infinite/BNAsim/jackson_sim"
do
    [[ -x "$candidate" ]] && { cancel_sim="$candidate"; break; }
done
cancel_input="$CHECK_ROOT/infinite/BNAsim/example_m2.sim"
if [[ -n "$cancel_sim" && -r "$cancel_input" ]]; then
    cancel_work="$(mktemp -d "${TMPDIR:-/tmp}/qnet-cancel-gate.XXXXXX")"
    cp "$cancel_input" "$cancel_work/net.sim"
    # `set -m` gives the job its own process group, so the group signals
    # below can never reach this script. The equality assertion that
    # follows is the belt to that braces.
    set -m
    bash -c '{ "$0" "$1" -c -n 4 -w 1000 -r 1000000000 -s 1 >/dev/null 2>&1 ; } & _p=$! ; wait $_p' \
        "$cancel_sim" "$cancel_work/net.sim" &
    cancel_wrapper=$!
    set +m
    sleep 2
    cancel_group="$(ps -o pgid= -p "$cancel_wrapper" 2>/dev/null | tr -d ' ' || true)"
    own_group="$(ps -o pgid= -p $$ | tr -d ' ')"
    if [[ -z "$cancel_group" ]]; then
        fail "cancellation gate: the solver wrapper exited before it could be cancelled"
    fi
    [[ "$cancel_group" != "$own_group" ]] \
        || fail "cancellation gate refuses to signal its own process group ($own_group)"
    pgrep -f "jackson_sim $cancel_work/net.sim" >/dev/null \
        || fail "cancellation gate: jackson_sim never started"
    kill -INT  "-$cancel_group" 2>/dev/null || true
    sleep 1.5
    kill -TERM "-$cancel_group" 2>/dev/null || true
    sleep 1.5
    if pgrep -f "jackson_sim $cancel_work/net.sim" >/dev/null; then
        kill -KILL "-$cancel_group" 2>/dev/null || true
        wait "$cancel_wrapper" 2>/dev/null || true
        rm -rf "$cancel_work"
        fail "a cancelled solver survived the 3 s cancel deadline"
    fi
    kill -KILL "-$cancel_group" 2>/dev/null || true
    wait "$cancel_wrapper" 2>/dev/null || true
    rm -rf "$cancel_work"
else
    printf 'note: jackson_sim not built; skipping the run-cancellation gate\n' >&2
fi

python3 - "$CTMC_SOURCE" <<'PY'
import ast
from pathlib import Path
import sys

ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])
PY

printf 'GUI runtime contracts passed.\n'
