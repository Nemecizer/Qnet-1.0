#!/usr/bin/env bash
# Every awk and perl program QnetGUIApp.swift embeds must PARSE on this Mac.
#
# Why this exists: `Run > Run SRBM MLMC`'s aggregator carried a bare ternary
# inside a printf argument list (`adaptive_unmet > 0 ? "no" : "yes"`).  BWK
# awk -- /usr/bin/awk on macOS, one-true-awk -- reads that `>` as an output
# redirection, so the program died at PARSE time, both branches of the
# enclosing `if` were dead, and every MLMC run lost its whole formatted
# output while printing three parser errors.  It shipped for four rounds
# because nothing headless ever asked either program whether it parses.
#
# The two literals are found by their Swift declaration text
# (`private static let outputPrecisionProgram = """` and
# `awk -v mu="$MU" -v K=$K`).  Renaming either one is a deliberate act that
# must update this script in the same change -- the same convention
# gui_runtime_contracts.sh already documents.
set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI_SOURCE="$CHECK_ROOT/Sources/Qnet/QnetGUIApp.swift"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnet-formatter-parse.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'Embedded formatter parse check failed: %s\n' "$*" >&2; exit 1; }

# 1. The perl display-precision filter.  It is a single Swift multiline
#    literal, so it can be lifted whole and handed to `perl -c`.
python3 - "$GUI_SOURCE" "$WORK/filter.pl" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'private static let outputPrecisionProgram = """\n(.*?)\n(\s*)"""\n',
              src, re.S)
if not m:
    sys.exit("outputPrecisionProgram literal not found")
indent = m.group(2)
body = "\n".join(l[len(indent):] if l.startswith(indent) else l
                 for l in m.group(1).split("\n"))
out, i = [], 0
simple = {"\\": "\\", '"': '"', "n": "\n", "t": "\t", "r": "\r"}
while i < len(body):
    c = body[i]
    if c == "\\" and i + 1 < len(body) and body[i + 1] in simple:
        out.append(simple[body[i + 1]]); i += 2; continue
    out.append(c); i += 1
open(sys.argv[2], "w", encoding="utf-8").write("".join(out))
PY
perl -c "$WORK/filter.pl" >/dev/null 2>"$WORK/perl.err" \
    || fail "outputPrecisionProgram does not compile under perl -c: $(cat "$WORK/perl.err")"

# 2. The MLMC aggregator.  It is the one with the documented history, so it
#    is named explicitly rather than discovered, and it is exercised in BOTH
#    branches of the ternary that used to be a syntax error.
python3 - "$GUI_SOURCE" "$WORK/mlmc.awk" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index('awk -v mu="$MU" -v K=$K')
j = src.index("' < /dev/null", i)
seg = src[i:j]
seg = seg[seg.index("'") + 1:]
out, k = [], 0
simple = {"\\": "\\", '"': '"', "n": "\n", "t": "\t"}
while k < len(seg):
    c = seg[k]
    if c == "\\" and k + 1 < len(seg) and seg[k + 1] in simple:
        out.append(simple[seg[k + 1]]); k += 2; continue
    out.append(c); k += 1
open(sys.argv[2], "w", encoding="utf-8").write("".join(out))
PY
/usr/bin/awk -v mu="1" -v K=1 -v critical=1.96 -v base="$WORK/none" -v seeds="1" \
    -f "$WORK/mlmc.awk" </dev/null >/dev/null 2>"$WORK/awk.err" \
    || fail "MLMC aggregator does not parse under /usr/bin/awk: $(cat "$WORK/awk.err")"

printf '# antithetic=off adaptive=on stop=SE target achieved\n   1 1.0 0.1 0.2\n' \
    > "$WORK/rep.1"
/usr/bin/awk -v mu="1" -v K=1 -v critical=1.96 -v base="$WORK/rep" -v seeds="1" \
    -f "$WORK/mlmc.awk" </dev/null 2>/dev/null \
    | grep -Fq 'QNET_MLMC_STATUS_V1 adaptive=yes precision_met=yes cap_hits=0' \
    || fail "MLMC adaptive status record is missing or malformed"

printf '# antithetic=off adaptive=on stop=sample cap reached\n   1 1.0 0.1 0.2\n' \
    > "$WORK/rep.1"
/usr/bin/awk -v mu="1" -v K=1 -v critical=1.96 -v base="$WORK/rep" -v seeds="1" \
    -f "$WORK/mlmc.awk" </dev/null 2>/dev/null \
    | grep -Fq 'QNET_MLMC_STATUS_V1 adaptive=yes precision_met=no cap_hits=1' \
    || fail "MLMC cap-hit status record is missing or malformed"

printf 'Embedded formatter parse check passed.\n'
