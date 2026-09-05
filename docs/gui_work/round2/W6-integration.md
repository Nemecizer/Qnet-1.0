# W6 — integration requests, round 2

Three requests plus one release-hygiene note. None of them blocks a shipped task; the first is
the one that matters, because without it three formatters that this workstream exists to keep in
agreement will disagree about two specific classes of number.

The two round-1 requests (`W6-INT-1`, `W6-INT-2`) are unchanged and still pending;
`W6-INT-5` below amends the footnote text `W6-INT-1` installs, so apply them in order.

---

## W6-INT-3 — `DS.Number.display` must adopt the two guards the other two formatters now carry

1. **ID** — `W6-INT-3`. Completes **W6-01** (universal decimal places). W6-01 ships without it:
   the terminal and the awk tables agree with each other. What is missing is the third
   formatter. `DesignSystem.swift` is frozen and integrator-owned, so this is the only way in.

2. **Target file and anchor** — `Sources/Qnet/DesignSystem.swift`, `enum Number`, function
   `display(_:decimals:)`. Anchor quoted verbatim from today's source, lines 1499-1511:

   ```swift
        static func display(_ value: Double, decimals: Int) -> String {
            guard !value.isNaN else { return "—" }
            guard value.isFinite else { return value < 0 ? "-∞" : "∞" }
            let d = max(0, min(9, decimals))
            if value != 0, d > 0, abs(value) < pow(10.0, Double(-d)) {
                return String(format: "%.\(max(1, d - 1))e", value)
            }
            return String(format: "%.\(d)f", value)
        }
   ```

3. **Insert / replace** — replace the body, before → after. The doc comment above it is
   unchanged except for one added sentence, given last.

   ```swift
        static func display(_ value: Double, decimals: Int) -> String {
            guard !value.isNaN else { return "—" }
            guard value.isFinite else { return value < 0 ? "-∞" : "∞" }
            let d = max(0, min(9, decimals))
            // Symmetric magnitude guards. Below 10^-d a fixed rendering prints a
            // flat zero for a value that is not zero; at or above 1e9 it prints
            // up to twenty digits of floating-point noise the solver never
            // computed, in a cell sized for eight characters. The same two
            // thresholds are spelled in `fmt7` (buildComparisonAwk) and in the
            // terminal's display-precision filter, and the three must agree or
            // the Shell and the Results pane show different numbers.
            let small = d > 0 && abs(value) < pow(10.0, Double(-d))
            let large = abs(value) >= 1e9
            let text = (value != 0 && (small || large))
                ? String(format: "%.\(max(1, d - 1))e", value)
                : String(format: "%.\(d)f", value)
            // A displayed "-0.000" reads as a sign error rather than as a small
            // negative. Both other formatters strip it; this one used to not,
            // so the same value showed as "0" in the Shell and "-0" here.
            if text.hasPrefix("-"), Double(text.dropFirst()) == 0 {
                return String(text.dropFirst())
            }
            return text
        }
   ```

   And, in the doc comment immediately above, replace this line:

   ```swift
        ///   * everything else is `%.<decimals>f`.
   ```
   with:
   ```swift
        ///   * everything else is `%.<decimals>f`, except that a magnitude at or
        ///     above 1e9 falls back to scientific for the same reason a magnitude
        ///     below 10^-decimals does, and a signed zero loses its sign.
   ```

4. **New symbols it depends on** — none. `pow`, `String(format:)` and `Double(_:)` are already
   used in this file; nothing from any other workstream is referenced.

5. **Gate impact** — none. `validation/design_lint.sh` exempts `DesignSystem.swift` from every
   token rule and inspects only the constants `validation/ds_contrast.swift` parses (colour
   definitions), which this does not touch. `validation/gui_runtime_contracts.sh` greps no string
   in this file. No `DSEmptyState` title, `Divider()`, menu path or shortcut.

6. **Verification** — `swift build`, then `swift run Qnet --ds-gallery` still renders. Behavioural
   proof, from a Swift snippet or the Results pane: with Output decimals = 3,
   `DS.Number.display(-0.0001, decimals: 3)` must return `"0.000"`, not `"-0.000"`, and
   `DS.Number.display(2.5e15, decimals: 3)` must return `"2.50e+15"`, not
   `"2500000000000000.000"`. Both match what the Interactive Shell prints for the same value.

7. **Priority** — **P1**. The disagreement is confined to |v| ≥ 1e9 and to values that round to a
   signed zero. It is reachable (a diverged network, a blocking probability that rounds to zero
   from below) but it is not on the default path.

---

## W6-INT-4 — the bundle audit should assert the fifty example networks

1. **ID** — `W6-INT-4`. Completes **W6-04** (ship the examples inside Qnet.app). W6-04 ships
   without it — `build_app.sh` now copies the examples and `die`s if the count does not match the
   source directory, so a release cannot silently drop them. What is missing is the *independent*
   assertion. `validation/` is off-limits to a build agent this round, and the standing rule is
   that the release inventory is maintained independently of the packager precisely so that
   dropping something from the packager cannot go unnoticed.

2. **Target file and anchor** — `validation/solver_bundle_audit.sh`. Anchor quoted verbatim from
   today's source, lines 57-61:

   ```sh
   [[ -d "$AUDIT_APP" ]] || { echo "bundle audit: app not found: $AUDIT_APP" >&2; exit 1; }
   [[ -d "$AUDIT_BIN" ]] || { echo "bundle audit: solver directory not found: $AUDIT_BIN" >&2; exit 1; }
   [[ -f "$AUDIT_MANIFEST" ]] || { echo "bundle audit: runtime manifest not found: $AUDIT_MANIFEST" >&2; exit 1; }
   ```

3. **Insert / replace** — insert immediately after the `$AUDIT_MANIFEST` line above:

   ```sh
   # The empty canvas's only action is "Open an Example…", and the File menu
   # promises "one of the bundled literature networks". Neither is true unless
   # the documents are actually in the bundle: findExamplesDirectory() prefers
   # Bundle.main.resourceURL/examples, and a Finder-launched app has no useful
   # working directory to fall back to. Counted, not merely present, because a
   # partial copy is the failure that would otherwise ship.
   AUDIT_EXAMPLES="$AUDIT_RESOURCES/examples"
   [[ -d "$AUDIT_EXAMPLES" ]] \
       || audit_fail "example networks are not bundled: $AUDIT_EXAMPLES"
   audit_example_count="$(find "$AUDIT_EXAMPLES" -type f -name '*.bnet' 2>/dev/null | wc -l | tr -d ' ')"
   [[ "${audit_example_count:-0}" -ge 50 ]] \
       || audit_fail "bundled example networks: $audit_example_count, expected at least 50"
   ```

4. **New symbols it depends on** — `audit_fail` (already defined at line 20 of the same script)
   and `AUDIT_RESOURCES` (line 13). Nothing new. On the Qnet side it depends on
   `build_app.sh`'s new "3a-ter" block, which is already in the tree and writes
   `Contents/Resources/examples`.

5. **Gate impact** — this *is* a gate change: it adds an assertion to
   `validation/solver_bundle_audit.sh`, which `build_app.sh` and `verify_source_package.sh` both
   run. It will fail against any `Qnet.app` built before this round; the fix is to re-run
   `./build_app.sh`, which is required anyway (see the release note at the bottom).

6. **Verification** — `./build_app.sh` (which ends by running the audit), then
   `find Qnet.app -name '*.bnet' | wc -l` → `50`. Negative check:
   `mv Qnet.app/Contents/Resources/examples /tmp/x && ./validation/solver_bundle_audit.sh ./Qnet.app`
   must fail with "example networks are not bundled"; move it back afterwards.

7. **Priority** — **P1**. `build_app.sh` already refuses to ship without the examples; this is
   the independent second opinion, not the only one.

---

## W6-INT-5 — amend the Output Format footnote to promise what the filter actually does

1. **ID** — `W6-INT-5`. Completes **W6-01**. Amends the text `W6-INT-1` installs; apply after it.
   W6-01 ships without it. The problem is that the acceptance sentence written in round 1 —
   "every decimal number in the Interactive Shell shows exactly N fraction digits" — is broader
   than the filter's behaviour by design, and a reader chasing the gap will find deliberate
   exclusions and read them as bugs.

2. **Target file and anchor** — `Sources/Qnet/SettingsView.swift`, `OutputFormatPane.body`,
   the `SettingsFootnote(...)` call at line 2037 — i.e. the same string literal `W6-INT-1`
   replaces. Anchor is the text `W6-INT-1` installs:

   ```swift
                   SettingsFootnote("Applies to every method's output in the Interactive Shell and to the Results pane. Display only: solver precision, the saved run output and CSV export all keep full precision. A value too small to show at this precision is printed in scientific notation rather than as a flat zero.")
   ```

3. **Insert / replace** — replace that string literal with (one line, including the sentence
   `W6-INT-2` also appends, so applying all three leaves exactly this):

   ```swift
                   SettingsFootnote("Applies to every method's results in the Interactive Shell and to the Results pane. Display only: solver precision, the saved run output and CSV export all keep full precision. A value too small to show at this precision is printed in scientific notation rather than as a flat zero, and so is one large enough that a fixed rendering would be mostly floating-point noise. Whole numbers, percentages, version numbers, file paths and the advisory text of Analyze Network, Network Primitives and the Help pages are left as they are written. Six is the ceiling because that is the precision the solvers themselves print.")
   ```

4. **New symbols it depends on** — none; text only.

5. **Gate impact** — none. No gui-runtime-contract string, no design-lint pattern (no menu-path
   arrow, no TeX braces, no ⌘-digit, no `DSEmptyState` title, no `Divider()`), no shortcut.
   `SettingsRegistry`'s `output.decimals` entry (SettingsView.swift:503) keeps its keywords.

   Separately — not a code change, so not a numbered request — the acceptance criterion of
   **W6-01** in `docs/gui_work/BACKLOG.json` should be amended the same way: the filter rewrites
   *decimal-pointed numbers that are not immediately followed by a letter, `%`, `/` or `@`*, and
   deliberately leaves bare integers, bare exponentials such as `1e-7`, percentages, and the
   three prose surfaces above untouched.

6. **Verification** — `swift run Qnet`, ⌘, → Output Format. Read the footnote; then run
   `Network ▸ Analyze Network` (⇧⌘A) at Output decimals = 6 and confirm the sentence
   "Target ρ < 1 with comfortable margin, ideally 0.85–0.99." is printed exactly as written.

7. **Priority** — **P1**. The behaviour is right; only the description is broader than the deed.

---

## Release note — not a request, but the round is not finished without it

* `./build_app.sh` must be re-run before this release is packaged. The `Qnet.app` currently
  beside `Package.swift` predates this round and contains **zero** `.bnet` documents; the Swift
  side prefers a bundled copy but falls back to the source tree, so a checkout works today and a
  copied-away bundle does not until the packager runs.
* `FILES.sha256` is stale — six agents edited source this round. Regenerate it at release time
  with the same command that produced it.
