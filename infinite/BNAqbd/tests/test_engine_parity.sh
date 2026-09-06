#!/usr/bin/env bash
#
# The two QBD engines must agree, and here that means EXACTLY: byte for byte,
# report and machine records alike, on stdout, with the same exit status.
#
# Unlike the regenerative simulator this method has no random stream and no
# wall-clock safeguard, so there is nothing that can legitimately differ. Any
# difference is a bug in one engine. Do not add a tolerance to this test; if it
# fails, one of the two is wrong.
#
# The comparison covers:
#   - every packaged example, in --human (what the GUI runs) and in JSON;
#   - a phase-count sweep, because the interior dimension is what the
#     functional iteration scales in and a transcription error in the matrix
#     kernel shows up only once the matrices are bigger than 1x1;
#   - every refusal, because an invalid document must be refused with the same
#     code and the same sentence by both.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYTHON="${PYTHON:-python3}"
ENGINE="$ROOT/bna_qbd"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-qbd-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -x "$ENGINE" ] || { echo "parity: $ENGINE is not built (run make engine)" >&2; exit 1; }

failures=0
compared=0

compare() {
    local document="$1" label="$2" mode="$3"
    local py="$WORK/py.txt" c="$WORK/c.txt" py_rc c_rc

    set +e
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$ROOT/$( [ "$mode" = "--human" ] && echo qbd_solver.py || echo qbd_solver.py )" "$document" $mode > "$py" 2>&1
    py_rc=$?
    "$ENGINE" "$document" $mode > "$c" 2>&1
    c_rc=$?
    set -e

    if [ "$py_rc" != "$c_rc" ]; then
        echo "FAIL $label $mode: exit status python=$py_rc c=$c_rc"
        failures=$((failures + 1))
        return
    fi
    if [ "$mode" = "--human" ]; then
        if ! diff -u "$py" "$c" > "$WORK/d.txt"; then
            echo "FAIL $label $mode: output differs"
            head -30 "$WORK/d.txt"
            failures=$((failures + 1))
            return
        fi
    else
        # The JSON documents are not byte-comparable by design: the Python's is
        # written by json.dump with sorted keys and repr() floats, and the C one
        # is hand-written. What must agree is every number the C engine
        # publishes, exactly -- so they are compared by value.
        if ! "$PYTHON" "$HERE/compare_json.py" "$py" "$c" "$label"; then
            failures=$((failures + 1))
            return
        fi
    fi
    compared=$((compared + 1))
}

for document in "$ROOT"/examples/*.json; do
    name="$(basename "$document")"
    compare "$document" "$name" "--human"
    compare "$document" "$name" "--compact"
done

# A phase-count sweep. 1x1 matrices hide every indexing and ordering mistake in
# the matrix kernel; these do not.
for k in 2 3 5 8 13 21; do
    "$PYTHON" "$HERE/make_phase_fixture.py" "$k" "$WORK/phases_$k.json"
    compare "$WORK/phases_$k.json" "M/E$k/1" "--human"
done

# Refusals: same status, same first line.
"$PYTHON" "$HERE/make_refusal_fixtures.py" "$WORK"
while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    set +e
    py_out="$("$PYTHON" "$ROOT/qbd_solver.py" "$document" --human 2>&1)"
    py_rc=$?
    c_out="$("$ENGINE" "$document" --human 2>&1)"
    c_rc=$?
    set -e
    if [ "$py_rc" -eq 0 ]; then
        echo "FAIL refusal '$label': the Python engine accepted a document the case calls invalid"
        failures=$((failures + 1))
    elif [ "$py_rc" != "$c_rc" ] || [ "$py_out" != "$c_out" ]; then
        echo "FAIL refusal '$label': engines disagree"
        echo "   python (rc $py_rc): $(printf '%s' "$py_out" | head -2 | tr '\n' '|')"
        echo "   c      (rc $c_rc): $(printf '%s' "$c_out"  | head -2 | tr '\n' '|')"
        failures=$((failures + 1))
    else
        compared=$((compared + 1))
    fi
done < "$WORK/refusals.tsv"

if [ "$failures" -ne 0 ]; then
    echo "engine parity: $failures comparison(s) failed" >&2
    exit 1
fi
echo "engine parity: $compared comparisons passed (byte-identical, no tolerance)"
