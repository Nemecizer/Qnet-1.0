#!/usr/bin/env bash
#
# The two engines must agree. This is the test that says exactly how much.
#
# THE CONTRACT
#
#   1. The human report -- everything the GUI shows -- is byte-identical.
#      Same cycle count, same stopping reason, same table, same rows. This is
#      the strong claim, and it holds because bna_rmc draws CPython's own
#      Mersenne Twister stream (common/bnet_pyrandom.h), so both engines visit
#      the same events in the same order.
#
#   2. The machine records are byte-identical EXCEPT ci_half_width, ci_low and
#      ci_high, which agree to 1e-9 relative. Those three are the only values
#      that pass through a Student-t quantile, and CPython ships its own
#      lgamma (a Lanczos approximation) rather than calling the platform's.
#      Measured, the two lgammas differ by up to 1.6e-15 relative, and the
#      quantile's 100-step bisection amplifies that to about 1.7e-12. It is far
#      below the Monte Carlo standard error it qualifies (percent-scale) and it
#      does not reach the six decimals the report prints -- which is why the
#      report in (1) is identical anyway.
#
#   3. The wall-clock safeguard is excluded by construction. `maximum_wall_
#      seconds` stops a run by elapsed time, and the C engine is ~250x faster,
#      so a document whose run is cut short by that limit stops at a different
#      cycle in each engine. That is not a disagreement about the method; it is
#      the safeguard doing its job at two different speeds. Every fixture here
#      is given a wall budget it cannot reach, so the comparison is of the
#      simulation and not of the clock.
#
# A failure here means one engine has drifted from the other. Do not "fix" it
# by loosening the tolerance.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYTHON="${PYTHON:-python3}"
ENGINE="$ROOT/bna_rmc"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-rmc-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -x "$ENGINE" ] || { echo "parity: $ENGINE is not built (run make engine)" >&2; exit 1; }

failures=0
compared=0

compare() {
    local document="$1" label="$2"
    local py="$WORK/py.txt" c="$WORK/c.txt"

    PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$ROOT/regenerative_mc.py" "$document" > "$py" 2>&1 || true
    "$ENGINE" "$document" > "$c" 2>&1 || true

    # (1) the report
    grep -v '^QNET_NODE_METRIC_V1' "$py" > "$WORK/py_report.txt" || true
    grep -v '^QNET_NODE_METRIC_V1' "$c"  > "$WORK/c_report.txt"  || true
    if ! diff -u "$WORK/py_report.txt" "$WORK/c_report.txt" > "$WORK/report.diff"; then
        echo "FAIL $label: the human report differs between engines"
        head -40 "$WORK/report.diff"
        failures=$((failures + 1))
        return
    fi

    # (2) the machine records
    if ! "$PYTHON" - "$py" "$c" "$label" <<'PY'
import sys

TOLERANT = {"ci_half_width", "ci_low", "ci_high"}
TOLERANCE = 1e-9

def records(path):
    found = {}
    for line in open(path):
        if not line.startswith("QNET_NODE_METRIC_V1"):
            continue
        fields = dict(pair.split("=", 1) for pair in line.split()[1:])
        found[(fields["node_id"], fields["metric"], fields["class_id"])] = fields
    return found

py, c, label = records(sys.argv[1]), records(sys.argv[2]), sys.argv[3]
problems = []
if set(py) != set(c):
    problems.append("different record sets: only-python=%s only-c=%s"
                    % (sorted(set(py) - set(c)), sorted(set(c) - set(py))))
for key in sorted(set(py) & set(c)):
    for field, expected in py[key].items():
        actual = c[key].get(field)
        if actual == expected:
            continue
        if field not in TOLERANT:
            problems.append("%s %s: python=%s c=%s (must be exact)" % (key, field, expected, actual))
            continue
        try:
            a, b = float(expected), float(actual)
        except ValueError:
            problems.append("%s %s: unparseable (%s / %s)" % (key, field, expected, actual))
            continue
        relative = abs(a - b) / max(abs(a), 1e-300)
        if relative > TOLERANCE:
            problems.append("%s %s: relative difference %.3e exceeds %.0e"
                            % (key, field, relative, TOLERANCE))
if problems:
    print("FAIL %s: machine records disagree" % label)
    for problem in problems[:12]:
        print("   " + problem)
    sys.exit(1)
PY
    then
        failures=$((failures + 1))
        return
    fi
    compared=$((compared + 1))
    echo "ok   $label"
}

# Every packaged example, with the wall-clock safeguard lifted out of the way
# (see note 3 above) and nothing else changed.
for document in "$ROOT"/examples/*.json; do
    name="$(basename "$document")"
    "$PYTHON" - "$document" "$WORK/$name" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
stopping = document.setdefault("stopping", {})
stopping["maximum_wall_seconds"] = 3600.0
json.dump(document, open(sys.argv[2], "w"))
PY
    compare "$WORK/$name" "$name"
done

# A refusal must be refused the same way: same exit status, and the same
# sentence, not merely the same error code. The message is what the user reads
# in the Shell, so a document that one engine explains and the other merely
# rejects would put the engine choice exactly where it must not be visible.
#
# The cases live in make_refusal_fixtures.py, one per validation rule, so a
# reader can see which rule has no case.
"$PYTHON" "$HERE/make_refusal_fixtures.py" "$WORK"

while IFS=$'\t' read -r document label; do
    [ -n "$document" ] || continue
    py_out="$("$PYTHON" "$ROOT/regenerative_mc.py" "$document" 2>&1 || true)"
    if "$PYTHON" "$ROOT/regenerative_mc.py" "$document" >/dev/null 2>&1; then py_rc=0; else py_rc=$?; fi
    c_out="$("$ENGINE" "$document" 2>&1 || true)"
    if "$ENGINE" "$document" >/dev/null 2>&1; then c_rc=0; else c_rc=$?; fi
    py_line="$(printf '%s' "$py_out" | head -1)"
    c_line="$(printf '%s' "$c_out" | head -1)"
    if [ "$py_rc" -eq 0 ]; then
        # The fixture is meant to be invalid; if the reference engine accepts
        # it the CASE is wrong, and silently comparing two acceptances would
        # hide that.
        echo "FAIL refusal '$label': the Python engine accepted a document the case calls invalid"
        failures=$((failures + 1))
    elif [ "$py_rc" != "$c_rc" ] || [ "$py_line" != "$c_line" ]; then
        echo "FAIL refusal '$label': engines disagree"
        echo "   python (rc $py_rc): $py_line"
        echo "   c      (rc $c_rc): $c_line"
        failures=$((failures + 1))
    else
        compared=$((compared + 1))
    fi
done < "$WORK/refusals.tsv"

if [ "$failures" -ne 0 ]; then
    echo "engine parity: $failures comparison(s) failed" >&2
    exit 1
fi
echo "engine parity: $compared comparisons passed (report byte-identical; CI fields within 1e-9)"
