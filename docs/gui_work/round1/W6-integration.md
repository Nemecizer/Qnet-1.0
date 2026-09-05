# W6 — integration requests, round 1

Two requests. Both are one-line text or one-line range edits; neither blocks a shipped task,
but the first leaves a false statement on screen until it is applied.

---

## W6-INT-1 — Settings ▸ Output Format now describes a setting that no longer exists

1. **ID** — `W6-INT-1`. Completes **W6-01** (universal decimal places). W6-01 is shipped and
   working without it; what is missing is that the Settings pane still describes the *old*,
   narrower behaviour, so the UI now tells the user something untrue.

2. **Target file and anchor** — `Sources/Qnet/SettingsView.swift`, `OutputFormatPane.body`.
   Two anchors, quoted verbatim from today's source:

   line 2031:
   ```swift
                       help: "Digits after the decimal point for ρ, Γ, sojourn and E[X] in result tables."
   ```
   line 2037:
   ```swift
                   SettingsFootnote("Affects only how Run Comparison and single-method tables print numbers; solver precision is unchanged.")
   ```

3. **Insert / replace** — two string replacements, nothing structural.

   Line 2031, before → after:
   ```swift
                       help: "Digits after the decimal point for ρ, Γ, sojourn and E[X] in result tables."
   ```
   ```swift
                       help: "Digits after the decimal point for every number the solvers print, in the Interactive Shell and in the Results pane."
   ```

   Line 2037, before → after:
   ```swift
                   SettingsFootnote("Affects only how Run Comparison and single-method tables print numbers; solver precision is unchanged.")
   ```
   ```swift
                   SettingsFootnote("Applies to every method's output in the Interactive Shell and to the Results pane. Display only: solver precision, the saved run output and CSV export all keep full precision. A value too small to show at this precision is printed in scientific notation rather than as a flat zero.")
   ```

4. **New symbols it depends on** — none. `SettingsFootnote(_:)` (SettingsComponents.swift:410)
   and the `help:` parameter of `SettingsNumberRow` are both unchanged; this is text only.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` greps no string in
   SettingsView.swift. No `DSEmptyState` title, no `Divider()`, no keyboard shortcut, no menu
   path — nothing `validation/design_lint.sh` inspects. The new text contains no menu-path arrow,
   no TeX braces and no ⌘-digit. `SettingsRegistry`'s entry for `output.decimals`
   (SettingsView.swift:503) keeps its keywords and needs no change.

6. **Verification** — `swift run Qnet`, ⌘, → Output Format. The footnote under "Numeric
   Display" must mention the Results pane and say the run output and CSV keep full precision.
   Then: set Decimal places to 3, run any method (Run ▸ QNA is the fastest), and confirm the
   terminal shows three fraction digits — the footnote is now describing what actually happens.

7. **Priority** — **P0**. Not because a feature is dead without it, but because the sentence
   now on screen is false: it names two of the twenty-two run paths and denies the Results pane.

---

## W6-INT-2 — Clamp Output decimals to 0…6, the precision the solvers actually print

1. **ID** — `W6-INT-2`. Completes **W6-02** (stop the Exact Result column fabricating digits).
   W6-02 is shipped without it: the Exact Result column now carries real digits at every setting.
   This request is the other half of the honesty fix — the *algorithm* columns cannot.

2. **Target file and anchor** — `Sources/Qnet/AppSettings.swift`, `enum Ranges`.
   Anchor quoted verbatim from today's source, line 196:
   ```swift
           static let outputDecimals  = 0...9
   ```

3. **Insert / replace** — one line, before → after:
   ```swift
           static let outputDecimals  = 0...9
   ```
   ```swift
           /// Ceiling of 6, not 9: every native solver prints its numbers with
           /// C's `%f` default or an explicit `%.6f`, so a seventh fraction
           /// digit does not exist in the text this app parses. Asking for 9
           /// used to print six real digits and three zeros — precision the
           /// number never had. The Exact Result column, computed in Swift,
           /// could honour more; a table whose columns disagree about how many
           /// of their digits are real is worse than one that stops at 6.
           static let outputDecimals  = 0...6
   ```

   Also, in `Sources/Qnet/SettingsView.swift` (W4-owned), append this sentence to the footnote
   text that W6-INT-1 installs, inside the same string literal, after the last sentence:

   ```
    Six is the ceiling because that is the precision the solvers themselves print.
   ```

   No other edit is needed. `AppSettings.swift:866` (`"output.decimals": r(Ranges.outputDecimals)`)
   reads the range rather than restating it, so the range map follows automatically; the
   `SettingsNumberRow` stepper at SettingsView.swift:2029 also reads
   `AppSettings.Ranges.outputDecimals` and needs no change.

4. **New symbols it depends on** — none. `Defaults.outputDecimals` is 6
   (AppSettings.swift:143), already inside the narrowed range, so no stored value is orphaned and
   `resetOutputFormat()` is unaffected. Everything that consumes the setting already clamps
   defensively: `DS.Number.display(_:decimals:)` clamps to `0...9`, `buildComparisonAwk` does
   `max(0, min(9, …))`, and `outputPrecisionFilter(decimals:)` clamps in both Swift and perl —
   so a user who already stored 9 degrades to a legal value rather than crashing.

5. **Gate impact** — none. No gui-runtime-contract string, no design-lint pattern, no shortcut.
   Two behavioural consequences, both intended and neither a gate: `rangesByKey`
   (AppSettings.swift:817) is what `importSettings` validates against, so a hand-edited settings
   file carrying `output.decimals: 9` will now be refused and reported rather than written; and
   `SettingsRegistry.audit()` asserts in debug builds that every numeric key's *default* lies
   inside its range — 6 does, so the audit stays clean. Note what does **not** happen: nothing
   rewrites a value already in `UserDefaults`, so a user who set 9 before this change keeps 9
   until they touch the stepper, which will then only move down. Every consumer clamps
   defensively, so that state is legal, merely wider than the pane now offers.

6. **Verification** — ⌘, → Output Format, hold the stepper's up arrow: it must stop at 6, and
   the caption example must read `ρ = 0.812346`. Then export settings, hand-edit
   `output.decimals` to 9, import: the import must refuse that key and say so.

7. **Priority** — **P1**. Reachable another way meanwhile: a user who sets 7–9 today gets real
   digits in the Exact Result column and trailing zeros in the algorithm columns — misleading,
   but not broken, and the default of 6 is unaffected.
