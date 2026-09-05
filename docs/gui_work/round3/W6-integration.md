# W6 — integration requests, round 3

Two requests and one release note. Both requests are small; the first is a re-statement of
round 2's `W6-INT-4`, which was correctly deferred rather than applied (applying it against
today's `Qnet.app` would have turned a green gate red), and which is now sequenced so it cannot.

Round 2's `W6-INT-1`, `W6-INT-2`, `W6-INT-3` and `W6-INT-5` are all **applied** — verified in
today's source (`DesignSystem.swift` carries the symmetric magnitude guard and the signed-zero
strip; `SettingsView.swift:2173` carries the amended footnote). Nothing from earlier rounds is
outstanding except `W6-INT-4`, restated below as `W6-INT-6`.

---

## W6-INT-6 — the bundle audit must assert the fifty example networks (restates `W6-INT-4`)

1. **ID** — `W6-INT-6`. Completes **W6-04** (ship the examples inside `Qnet.app`). W6-04 ships
   without it: `build_app.sh`'s "3a-ter" block copies `input/examples` into
   `Contents/Resources/examples` and `die`s if the count does not match the source directory, so
   a *release built today* cannot silently drop them. What is missing is the **independent**
   assertion — the release inventory is deliberately maintained apart from the packager so that
   dropping something from the packager cannot go unnoticed. Round 3's critic re-raised it after
   measuring `find Qnet.app -name '*.bnet' | wc -l` = **0**, which is true and is a fact about the
   stale bundle in the tree, not about the packager.

   **Ordering matters.** Apply this *after* running `./build_app.sh` (see the release note), never
   before. The bundle beside `Package.swift` predates round 1; asserting against it turns a
   passing gate into a failing one for a reason that has nothing to do with the source.

2. **Target file and anchor** — `validation/solver_bundle_audit.sh`. Anchor quoted verbatim from
   today's source, lines 58-60:

   ```sh
   [[ -d "$AUDIT_APP" ]] || { echo "bundle audit: app not found: $AUDIT_APP" >&2; exit 1; }
   [[ -d "$AUDIT_BIN" ]] || { echo "bundle audit: solver directory not found: $AUDIT_BIN" >&2; exit 1; }
   [[ -f "$AUDIT_MANIFEST" ]] || { echo "bundle audit: runtime manifest not found: $AUDIT_MANIFEST" >&2; exit 1; }
   ```

3. **Insert / replace** — insert immediately after the `$AUDIT_MANIFEST` line above:

   ```sh
   # The empty canvas's only action is "Open an Example…", and the File menu
   # promises "one of the bundled literature networks". Neither is true unless
   # the documents are actually in the bundle: locateExamples() prefers
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

4. **New symbols it depends on** — `audit_fail` (defined at line 20 of the same script) and
   `AUDIT_RESOURCES` (line 13). Nothing new. On the Qnet side it depends on `build_app.sh`'s
   "3a-ter" block, already in the tree. The comment references `locateExamples()`, which is the
   round-3 name of the Swift lookup (`Sources/Qnet/QnetGUIApp.swift`); the old name
   `findExamplesDirectory()` no longer exists.

5. **Gate impact** — this **is** a gate change: it adds an assertion to
   `validation/solver_bundle_audit.sh`, which both `build_app.sh` and `verify_source_package.sh`
   run. It strengthens the gate; it does not weaken anything. It fails against any `Qnet.app`
   built before round 1 — hence the ordering rule in (1).

6. **Verification** — `./build_app.sh` (which ends by running the audit), then
   `find Qnet.app -name '*.bnet' | wc -l` → `50`. Negative check:
   `mv Qnet.app/Contents/Resources/examples /tmp/x && ./validation/solver_bundle_audit.sh ./Qnet.app`
   must fail with "example networks are not bundled"; move it back afterwards.

7. **Priority** — **P1**. `build_app.sh` already refuses to ship without the examples, and the
   Swift side now says out loud in the Status pane when it cannot find them (round 3), so the
   user-visible dead end is closed either way. This is the independent second opinion.

---

## W6-INT-7 — the Output Format footnote's "whole numbers" clause needs four words

1. **ID** — `W6-INT-7`. Amends **W6-01**'s footnote (installed by `W6-INT-1`, revised by
   `W6-INT-5`). W6-01 ships without it. The filter changed in round 3: a number written in
   scientific notation is now normalised to one spelling even when its mantissa has no decimal
   point, so `2E+11` prints as `2e+11`. That is a whole number whose *spelling* changed, and the
   footnote currently promises that whole numbers are "left as they are written". The behaviour
   is right — a line that printed `1e-9` beside `6.02e23` used to show two spellings of the same
   notation — but the sentence should say so.

2. **Target file and anchor** — `Sources/Qnet/SettingsView.swift`, `OutputFormatPane.body`, the
   `SettingsFootnote(...)` call at line 2173. The clause to change, quoted verbatim from today's
   source:

   ```swift
   Whole numbers, percentages, version numbers, file paths and the advisory text of Analyze Network, Network Primitives and the Help pages are left as they are written.
   ```

3. **Insert / replace** — replace that clause, in place, inside the same string literal, with:

   ```swift
   Whole numbers, percentages, version numbers, file paths and the advisory text of Analyze Network, Network Primitives and the Help pages keep their values; only the spelling of an exponent is regularised, so one line cannot show both 1e-9 and 6.02e23.
   ```

   Nothing else in the literal changes; the sentences before and after it stay as they are.

4. **New symbols it depends on** — none; text only.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` greps no string in
   `SettingsView.swift`. No `DSEmptyState` title, no `Divider()`, no menu-path arrow, no
   ⌘-digit, no TeX braces, no shortcut. `SettingsRegistry`'s `output.decimals` entry keeps its
   keywords.

6. **Verification** — `swift run Qnet`, ⌘, → Output Format, read the footnote. Behavioural proof
   of the sentence: with Output decimals = 3, a solver line reading
   `tolerance=1e-9 upper=2E+11 avo=6.02e23` now prints as
   `tolerance=1e-09 upper=2e+11 avo=6.02e+23` — three tokens, one notation.

7. **Priority** — **P1**. The behaviour is right and the footnote is only narrower than the
   deed by one clause.

---

## Release note — not a request, but the round is not finished without it

* **`./build_app.sh` must be re-run before this release is packaged, and before `W6-INT-6` is
  applied.** The `Qnet.app` beside `Package.swift` predates round 1 and contains **zero** `.bnet`
  documents. Three rounds of source changes are not in it either. A build agent is forbidden to
  run it (several minutes, code signing), which is why this keeps arriving as a note.
* **`FILES.sha256` is stale.** Regenerate it at release time with the command that produced it,
  after `build_app.sh`.
* No `validation/` file was modified by W6 in any round. `AppVersion.swift` is untouched and
  `swift run Qnet --version` still prints `Qnet 0.90.34`.
