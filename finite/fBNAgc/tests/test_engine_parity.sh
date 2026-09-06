#!/usr/bin/env bash
#
# The two generic-finite-CTMC engines must agree, byte for byte, on stdout and
# on stderr, with the same exit status. This chain is deterministic and nothing
# in it uses exact summation, so there is no tolerance to grant and none is
# granted: a difference is a defect in one engine.
#
# The sweep is the part that earns its keep. State indices here are assigned in
# discovery order during a breadth-first enumeration, and discovery order is the
# order transitions are generated in, so a mis-ordered event loop produces a
# correct stationary distribution over a differently numbered state space --
# and every line of the report moves. A single-station single-class fixture
# would not notice.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYTHON="${PYTHON:-python3}"
ENGINE="$ROOT/fbna_gc"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-gc-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -x "$ENGINE" ] || { echo "parity: $ENGINE is not built (run make engine)" >&2; exit 1; }

failures=0
compared=0

compare() {
    local document="$1" label="$2" expect_success="$3" py_rc c_rc
    shift 3
    set +e
    "$PYTHON" "$ROOT/solver.py" "$document" "$@" > "$WORK/py.out" 2> "$WORK/py.err"
    py_rc=$?
    "$ENGINE" "$document" "$@" > "$WORK/c.out" 2> "$WORK/c.err"
    c_rc=$?
    set -e
    if [ "$expect_success" = "yes" ] && [ "$py_rc" -ne 0 ]; then
        echo "FAIL $label: the reference engine could not solve a document the case calls valid"
        head -3 "$WORK/py.err"
        failures=$((failures + 1))
        return
    fi
    if [ "$expect_success" = "no" ] && [ "$py_rc" -eq 0 ]; then
        echo "FAIL $label: the reference engine accepted a document the case calls invalid"
        failures=$((failures + 1))
        return
    fi
    if [ "$py_rc" != "$c_rc" ]; then
        echo "FAIL $label: exit status python=$py_rc c=$c_rc"
        echo "   python: $(head -1 "$WORK/py.err")"
        echo "   c     : $(head -1 "$WORK/c.err")"
        failures=$((failures + 1))
        return
    fi
    if ! diff -u "$WORK/py.out" "$WORK/c.out" > "$WORK/d.txt"; then
        echo "FAIL $label: stdout differs"
        head -30 "$WORK/d.txt"
        failures=$((failures + 1))
        return
    fi
    if ! diff -u "$WORK/py.err" "$WORK/c.err" > "$WORK/e.txt"; then
        echo "FAIL $label: stderr differs"
        head -20 "$WORK/e.txt"
        failures=$((failures + 1))
        return
    fi
    compared=$((compared + 1))
}

for document in "$ROOT"/examples/*.json; do
    compare "$document" "$(basename "$document")" yes
done

"$PYTHON" "$HERE/make_fixtures.py" "$WORK"
while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    compare "$document" "$label" yes
    # The GUI passes --top-states 0, but the listing is part of the human
    # output and has its own ordering rule (a STABLE sort by descending
    # probability, and Python's own dict repr for the state). A count larger
    # than the state space is included because the slice must not run off it.
    compare "$document" "$label --top-states 5" yes --top-states 5
    compare "$document" "$label --top-states 10000" yes --top-states 10000
done < "$WORK/sweep.tsv"
while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    compare "$document" "refusal: $label" no
done < "$WORK/refusals.tsv"

if [ "$failures" -ne 0 ]; then
    echo "engine parity: $failures comparison(s) failed" >&2
    exit 1
fi
echo "engine parity: $compared comparisons passed (byte-identical, no tolerance)"
