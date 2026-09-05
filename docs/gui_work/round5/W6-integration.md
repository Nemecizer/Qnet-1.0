# W6 — round 5 integration requests

Workstream: **W6 — Output, results, numeric consistency.**
Files edited this round, all W6-owned: `Sources/Qnet/QnetGUIApp.swift`, `Sources/Qnet/Changelog.swift`.
Nothing outside W6 ownership was touched. `AppVersion.swift` is untouched (still 0.90.34).

There is exactly one request, and it is for a file under `validation/`, which W6 is forbidden to
modify.

---

## W6-INT-1 — a headless gate that every embedded awk/perl formatter still parses

1. **ID** — `W6-INT-1`. Completes the second half of the round-4 verifier's blocker
   *"Run ▸ Run SRBM MLMC produces no results at all: its awk output formatter fails to parse on
   macOS awk, and the failure is never reported."* The first half (the parenthesised ternary) is
   **already fixed and verified in W6-owned source**, so the blocker itself is shippable without
   this. This request exists so the next one of these is caught before a user sees it.

2. **Target file and anchor** — new file `validation/embedded_formatter_parse_check.sh`, and one
   new invocation of it from `validation/steady_state_suite.sh`. Anchor for the suite edit, quoted
   verbatim from today's source, `validation/gui_runtime_contracts.sh:1-4`:

   ```sh
   #!/usr/bin/env bash
   # Source-level and shell-behaviour contracts for GUI solver launch wrappers.

   set -euo pipefail
   ```

   (The new script should sit beside `gui_runtime_contracts.sh` and be run from the same place in
   the suite; the integrator owns where exactly.)

3. **Insert / replace** — add, do not replace. The check, in full:

   ```sh
   #!/usr/bin/env bash
   # Every awk and perl program QnetGUIApp.swift embeds must PARSE on this Mac.
   #
   # Why this exists: `Run > Run SRBM MLMC`'s aggregator carried a bare ternary
   # inside a printf argument list (`adaptive_unmet > 0 ? "no" : "yes"`).  BWK
   # awk -- /usr/bin/awk on macOS, one-true-awk 20200816 -- reads that `>` as an
   # output redirection, so the program died at PARSE time, both branches of the
   # enclosing `if` were dead, and every MLMC run lost its whole formatted output
   # while printing three parser errors.  It shipped for at least four rounds.
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
   perl -c "$WORK/filter.pl" >/dev/null 2>&1 \
       || fail "outputPrecisionProgram does not compile under perl -c"

   # 2. Every awk program.  Parse-only: feed each one /dev/null and require
   #    exit 0, which is what a syntax error costs.  The MLMC aggregator is the
   #    one with the documented history, so it is named explicitly rather than
   #    discovered, and it is checked in BOTH of its branches.
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
   ```

   Make it executable (`chmod +x`).

4. **New symbols it depends on** — none. It reads today's `QnetGUIApp.swift` text and uses
   `python3`, `perl` and `/usr/bin/awk`, all of which the existing validation scripts already
   assume.

5. **Gate impact** — none on the existing gates. It adds no Swift, no `DS.*` token, no
   `.keyboardShortcut`, no `DSEmptyState` title and no menu path, so `validation/design_lint.sh`
   and `QNET_MENU_AUDIT=1` are unaffected. It does **not** grep any string that
   `validation/gui_runtime_contracts.sh` also greps; it extracts two literals by their Swift
   declaration text (`private static let outputPrecisionProgram = """` and
   `awk -v mu="$MU" -v K=$K`), so renaming either one is a deliberate act that must update this
   script in the same change — the same convention `gui_runtime_contracts.sh` already documents.

6. **Verification** — `bash validation/embedded_formatter_parse_check.sh` prints
   `Embedded formatter parse check passed.` and exits 0 on today's tree. To prove it actually bites,
   temporarily remove the parentheses at `Sources/Qnet/QnetGUIApp.swift`
   (`(adaptive_unmet > 0 ? "no" : "yes")` → `adaptive_unmet > 0 ? "no" : "yes"`) and re-run: it must
   exit 1 with `MLMC aggregator does not parse under /usr/bin/awk`. Restore the parentheses
   afterwards.

7. **Priority** — **P1.** The defect it guards is fixed; this is the check that stops the next one.

---

## Not requests — notes for the integrator and for round 6

* **W6 changed no file it does not own.** `TerminalModel.swift` (W5) was read, not edited: the
  Status-log line for a failed run is added in `finalizeStructuredResult` in W6's own
  `QnetGUIApp.swift`, reading `TerminalRunSummary.text` / `.cancelled` / `.ownerID`, all of which
  already exist at `TerminalModel.swift:354-380`. If W5 adds a failure report of its own inside
  `TerminalModel.finishRun`, the two would double-report and one of them should go — W6's is the
  one to drop, because W5's would also cover runs that never register a Results record.

* **Two residuals disclosed rather than fixed**, both explicitly outside the assigned issues'
  required fixes, both recorded in the program's own comments so round 6 does not re-derive them
  as new bugs:
  1. A **bare integer in prose** keeps the solver's spelling — `external_blocking_probability: 0`
     beside `departure_rate: 0.999550`. A prose token carries no key to consult, and there a bare
     integer is as likely to be a count (`Complete empty-to-empty cycles: 20000`, a station index,
     an iteration count) as a measurement. Rewriting them all would break the one guarantee the
     filter is built on. The honest fix is solver-side, in the three human-output writers that
     print a measurement with `%g` (`infinite/regenerative_mc/regenerative_mc.py`,
     `infinite/truncated_ctmc/truncated_ctmc.py`, `infinite/product_form/solver.py`).
  2. **Prose that carries no `=`, `:` or `,` at all still takes padding**, and so does prose whose
     first numeric token is an unmatched bare integer. Both are reachable only *below* the shipped
     default of 6 decimals — at 6 and at 9 the whitespace scanner reports **zero** inserted spaces
     on every real solver output tested (srbm_lp, truncated_ctmc, regenerative_mc, qbd).
     * `[Parse] 0.000 s` -> `[Parse]     0 s` at decimals 0, and the same on `[Basis]`,
       `[Eval interior]`, `[Eval boundary]`, `[Grid]` and `[Build LP]`
       (`infinite/BNAlp`). There is no introducer anywhere on those lines.
     * `external_blocking_probability: 0 (95% CI [0, 0]; effective cycles 4345.2)` at decimals 0:
       the `0`, the `95` and the `[0, 0]` are all unmatched (bare integers, or a `%`-suffixed
       token), so the sentence's prose flag is never raised and `4345.2 -> 4345` is right-aligned
       inside its old width, inserting two spaces.

     Two candidate rules were tried and rejected, and the reasons should be recorded before anyone
     tries them again. (a) Raising the prose flag on an introducer followed by a bare integer:
     `infinite/BNAlp/src/srbm_output.c:140` prints `  k=%-5d` in front of a real right-aligned
     `  %12.6f` column table (:142), so that rule shears a genuine table. (b) Adding `]` to the
     introducer set to catch `[Parse]`: the comparison tables' own row labels are `E[Q_1]`,
     `E[X_1]`, `Exact E[N]`, so `]` immediately precedes a column in the one table shape the
     padding machinery exists to protect. A safe fix, if round 6 wants one, is a positive test for
     a column rather than a negative test for prose — e.g. require that the same character offset
     carries a token on the preceding or following record — but that is a redesign of rule 2, not
     a tightening of rule 3, and it should not be attempted in a close-out round.
