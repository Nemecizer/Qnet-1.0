#!/usr/bin/env bash
#
# The two adaptive-truncated-CTMC engines must agree.
#
# THE CONTRACT
#
#   1. A document that SOLVES produces byte-identical stdout, in --human (what
#      the GUI runs) and in JSON by value. No tolerance: the method is
#      deterministic, so a difference is a defect in one engine.
#
#   2. A document that is REFUSED produces the same exit status, the same error
#      `code` and the same `message`. Not the same bytes: the Python attaches a
#      diagnostic `details` payload to some errors -- for a stability refusal,
#      the whole traffic-and-stability dictionary -- and the C engine does not.
#      The code and the sentence are what identify a failure, and those match.
#
# The sweep matters as much as the packaged examples. A one-node model
# exercises none of the state-ranking arithmetic, the routing matrix or the
# multi-node moment sums, so it would pass with any of those transcribed wrong.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYTHON="${PYTHON:-python3}"
ENGINE="$ROOT/bna_tc"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-tc-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -x "$ENGINE" ] || { echo "parity: $ENGINE is not built (run make engine)" >&2; exit 1; }

failures=0
compared=0

compare_human() {
    local document="$1" label="$2" py_rc c_rc
    set +e
    "$PYTHON" "$ROOT/truncated_ctmc.py" "$document" --human > "$WORK/py.txt" 2>&1
    py_rc=$?
    "$ENGINE" "$document" --human > "$WORK/c.txt" 2>&1
    c_rc=$?
    set -e
    if [ "$py_rc" -ne 0 ]; then
        echo "FAIL $label: the reference engine could not solve a document the case calls valid"
        head -3 "$WORK/py.txt"
        failures=$((failures + 1))
        return
    fi
    if [ "$py_rc" != "$c_rc" ]; then
        echo "FAIL $label: exit status python=$py_rc c=$c_rc"
        head -5 "$WORK/c.txt"
        failures=$((failures + 1))
        return
    fi
    if ! diff -u "$WORK/py.txt" "$WORK/c.txt" > "$WORK/d.txt"; then
        echo "FAIL $label --human: output differs"
        head -30 "$WORK/d.txt"
        failures=$((failures + 1))
        return
    fi
    compared=$((compared + 1))
}

compare_json() {
    local document="$1" label="$2"
    set +e
    "$PYTHON" "$ROOT/truncated_ctmc.py" "$document" --compact > "$WORK/py.json" 2>&1
    "$ENGINE" "$document" --json > "$WORK/c.json" 2>&1
    set -e
    if "$PYTHON" "$HERE/compare_json.py" "$WORK/py.json" "$WORK/c.json" "$label"; then
        compared=$((compared + 1))
    else
        failures=$((failures + 1))
    fi
}

"$PYTHON" "$HERE/make_fixtures.py" "$WORK"

for document in "$ROOT"/examples/*.json; do
    name="$(basename "$document")"
    # unstable_mm1 is a refusal fixture, handled by the refusal loop's rules.
    if "$PYTHON" "$ROOT/truncated_ctmc.py" "$document" --compact >/dev/null 2>&1; then
        compare_human "$document" "$name"
        compare_json "$document" "$name"
    fi
done

while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    compare_human "$document" "$label"
    compare_json "$document" "$label"
done < "$WORK/sweep.tsv"

while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    set +e
    "$PYTHON" "$ROOT/truncated_ctmc.py" "$document" --human > "$WORK/py.txt" 2>&1
    py_rc=$?
    "$ENGINE" "$document" --human > "$WORK/c.txt" 2>&1
    c_rc=$?
    set -e
    if [ "$py_rc" -eq 0 ]; then
        echo "FAIL refusal '$label': the reference engine accepted a document the case calls invalid"
        failures=$((failures + 1))
        continue
    fi
    if [ "$py_rc" != "$c_rc" ]; then
        echo "FAIL refusal '$label': exit status python=$py_rc c=$c_rc"
        failures=$((failures + 1))
        continue
    fi
    if ! "$PYTHON" "$HERE/compare_error.py" "$WORK/py.txt" "$WORK/c.txt" "$label"; then
        failures=$((failures + 1))
        continue
    fi
    compared=$((compared + 1))
done < "$WORK/refusals.tsv"

if [ "$failures" -ne 0 ]; then
    echo "engine parity: $failures comparison(s) failed" >&2
    exit 1
fi
echo "engine parity: $compared comparisons passed (solved runs byte-identical; refusals match code and message)"
