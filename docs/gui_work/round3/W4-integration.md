# W4 — integration requests, round 3

Workstream **W4 — Movable windows, dialogs, settings**. Every request below is a patch expressed in
prose against a file W4 does not own. Nothing here has been applied by W4.

**State of earlier rounds, verified against today's source before writing this:**

| Request | Status today | Evidence |
| --- | --- | --- |
| `W4-INT-1` … `W4-INT-6` (round 1) | **applied** | `grep -rn setFrameAutosaveName Sources/Qnet` returns one comment only; the Settings scene carries `.windowResizability(.contentMinSize)`; the three dead `dialog*` tokens are gone |
| `W4-INT-R2-1` — archetype gallery becomes a panel | **applied** | `QnetGUIApp.swift:773` is `.onChange(of: showArchetypeSheet)`, `:1038` calls `ArchetypeGalleryPanel.sync` |
| `W4-INT-R2-2` — one word for the archetype dialog | **applied**, option (a) | `QnetCommands.swift:252` reads `Button("New from Archetype…")`, and the doc line at `:88` matches |
| **The five sheet → panel conversions** (round 1, "The recipe" / "The five forms") | **still unapplied** | `grep -c '\.sheet(' Sources/Qnet/QnetGUIApp.swift` is still 6 |

So exactly two things are outstanding: the new request `W4-INT-R3-1` below, and the round-1 five
form conversions, carried forward as `W4-INT-R3-2` with today's line numbers.

---

## W4-INT-R3-1 — `--audit-settings`: make the settings-registry audit a build gate

1. **ID** — `W4-INT-R3-1`. It completes the second half of critic 2's round-3 blocker ("consider
   covering `SettingsRegistry.audit()` from a headless check so this cannot regress silently a third
   time"). The blocker's first half — the missing `"results.paneVisible"` line — **is fixed in
   `SettingsView.swift` and needs nothing from anyone.** This request is what stops a *fourth*
   occurrence: without it the audit still only runs when a human opens the Settings window.

   It is **not shippable another way**: the only entry point into the process is
   `handleCLIIfNeeded()` in `QnetGUIApp.swift`, which W4 does not own.

   Background for the integrator, because it changes what a failure now looks like: the audit no
   longer traps. It used to be a wall of `assert`s run from the Settings window's `onAppear`, so one
   missing dictionary line killed any debug build the first time somebody pressed ⌘, — twice, losing
   an unsaved network each time. `SettingsRegistry.auditProblems()` now returns the same complaints
   as `[String]`; `SettingsRegistry.audit()` writes them to stderr in every configuration and, in a
   DEBUG build only, draws them across the top of the Settings window (a release build never shows a
   user a sentence about `unindexedKeys`). A regression is therefore loud but survivable in the GUI — and
   this flag is what makes it *fatal to the build*, which is where it belongs.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, inside `handleCLIIfNeeded()`.
   Anchor, verbatim at lines 106–109 at the time of writing:
   ```swift
    if args[1] == "--version" {
        print("Qnet \(AppVersion.version)")
        exit(0)
    }
   ```

3. **Insert / replace** — insert immediately **after** that closing brace (before the blank line and
   `func loadDoc`). Nothing is removed.
   ```swift
    // `Qnet --audit-settings` — the settings registry checked without a
    // GUI, for the release gate. Every stored key must be edited by a
    // SettingsRegistry row or listed in `unindexedKeys` with a reason, and
    // every numeric key must be bounded by exactly one import table; a key
    // added to `AppSettings.defaultsByKey` without its registry line is
    // invisible to Settings search and to Reset to Defaults. That mistake
    // shipped twice and was found both times by a person pressing ⌘,, so
    // it is checked here instead, where a script can fail on it. Prints
    // nothing and exits 0 when the registry is sound.
    if args[1] == "--audit-settings" {
        let problems = SettingsRegistry.auditProblems()
        for problem in problems {
            FileHandle.standardError.write(Data("Qnet settings-registry audit: \(problem)\n".utf8))
        }
        exit(problems.isEmpty ? 0 : 1)
    }
   ```
   `handleCLIIfNeeded()` is already `@MainActor`, which is what `auditProblems()` requires, and
   `Foundation` is already imported at the top of the file.

   **Optional, and W4 recommends it**: add the line
   ```sh
   swift run Qnet --audit-settings
   ```
   to the round exit gate in `docs/gui_work/round1/README.md` beside `swift run Qnet --version`.
   W4 has deliberately **not** put this check under `validation/`: that directory is off limits this
   round, and a new gate script there is the integrator's call, not a workstream's.

4. **New symbols it depends on** — one, landed this round by W4:

   | Symbol | File | Declaration |
   | --- | --- | --- |
   | `SettingsRegistry.auditProblems()` | `Sources/Qnet/SettingsView.swift` | `@MainActor static func auditProblems() -> [String]` — compiled into **every** configuration, not just DEBUG, precisely so a release binary can be gated on it |

   Also present, not needed by this snippet but worth knowing: `SettingsRegistry.audit()`
   (unchanged signature, still called from the Settings window's `onAppear`) and
   `SettingsRegistry.auditFindings` (`@MainActor private(set) static var auditFindings: [String]`),
   which is what the in-window band renders.

5. **Gate impact** — none. It adds no `.keyboardShortcut`, so `QNET_MENU_AUDIT=1` re-clears
   unchanged. It touches no string `validation/gui_runtime_contracts.sh` greps: that script asserts
   the awk formatters, the EXIT/INT/TERM trap pattern, the count of exactly 8 `commandWithCleanup`
   Python runners and `${PIPESTATUS[0]}` semantics, and this insertion is above all of them in
   `handleCLIIfNeeded()`, inside no run action. It adds no `DSEmptyState` title, `Divider()`,
   menu-path arrow or bare ⌘-digit, so `validation/design_lint.sh` is unaffected (it does not lint
   `#`-free CLI code differently — the snippet contains no DS-adjacent construct at all).

6. **Verification** —
   ```sh
   swift build --scratch-path /tmp/qnet-audit
   /tmp/qnet-audit/debug/Qnet --audit-settings ; echo "exit=$?"      # expect: no output, exit=0
   ```
   Then prove it can fail: delete the line `"shell.paneVisible": "View ▸ Panes, not a setting",`
   from `SettingsRegistry.unindexedKeys` in `SettingsView.swift`, rebuild, re-run — it must print
   one `AppSettings stores "shell.paneVisible" but no SettingsRegistry entry edits it …` line and
   exit 1. Restore the line. (W4 ran exactly this negative test through the GUI this round; see
   §Verification in the W4 round-3 report.)

7. **Priority** — **P1.** The shipped blocker fix does not depend on it; it is the guard that keeps
   the fix fixed. Please do not downgrade it further: this is the third round in which this one
   dictionary has been wrong, and it is the only request here whose absence guarantees a fourth.

---

## W4-INT-R3-2 — Carry-forward: the five sheet → panel conversions

1. **ID** — `W4-INT-R3-2`, a verbatim carry-forward of the round-1 document's closing sections
   ("The recipe" and "The five forms", `docs/gui_work/round1/W4-integration.md:399-520`). It
   completes the remainder of **W4-01/W4-02** — ask 6, "popup windows movable by the user" — for the
   five forms that are still `.sheet`s. It is **not shippable another way**: the presentations live
   in `QnetGUIApp.swift`.

   **Do not re-derive it. Apply the round-1 text.** It is a full worked example plus a five-row
   table, and the five rules it lists were each learned from a conversion that shipped
   (Canvas Export Options) or from one applied since (the archetype gallery, `W4-INT-R2-1`, which
   used this exact recipe and works). Nothing in it has gone stale: `DSPanelWindow.present(id:title:
   size:escapeCloses:onClose:)`, `DSPanelWindow.close(id:)` and the `ref.close()` teardown contract
   are unchanged in `Sources/Qnet/DSPanelWindow.swift`.

2. **Target file and anchors** — `Sources/Qnet/QnetGUIApp.swift`. Line numbers drifted since round 1
   (the archetype conversion moved everything below it); **these are today's**, and each anchor line
   is still verbatim unique in the file:

   | Form | Anchor line, verbatim | Round-1 line | Today | Panel id | `size:` |
   | --- | --- | --- | --- | --- | --- |
   | Run Test Set | `                .sheet(isPresented: $showTestSetSheet) {` | 710 | **718** | `test-set` | `.regular` |
   | Spectral Convergence | `                .sheet(isPresented: $showSpectralConvergenceSheet) {` | 728 | **736** | `spectral-convergence` | `.tall` |
   | Generate Random Network | `                .sheet(isPresented: $showGenerateRandomSheet) {` | 745 | **776** | `generate-random` | `.regular` |
   | Run parameters (7 solvers) | `                .sheet(item: $runParameterRequest) { request in` | 759 | **790** | `run-parameters` | `.regular` |
   | Find Node | `                .sheet(isPresented: $showFindNodeSheet) {` | 763 | **794** | `find-node` | `.compact` |

   The sixth `.sheet(` — `                .sheet(isPresented: $showStartupDependencyCheck) {` at
   **709** — stays a sheet. It blocks launch on purpose; that is the one dialog the user must not be
   able to drag aside and ignore.

3. **Insert / replace** — as written in `docs/gui_work/round1/W4-integration.md:399-520`, unchanged.
   The per-form ordering notes in that table are load-bearing, in particular: close the panel
   **before** `createRandomNetworkTab(params:)` (the new tab must take key status from a window that
   is already gone), before `Task.detached { await executeTestSet(…) }` (the sweep drives the shell),
   and route the run-parameter panel's teardown through `RunParameterRequest.onCancel` rather than
   around it.

4. **New symbols it depends on** — all landed in round 1 and still present:
   `DSPanelWindow.present(id:title:size:escapeCloses:onClose:content:)` and
   `DSPanelWindow.close(id:)` in `Sources/Qnet/DSPanelWindow.swift`.

5. **Gate impact** — as stated in the round-1 document: none of the strings
   `validation/gui_runtime_contracts.sh` greps lives inside a `.sheet(` modifier, no run action's
   shell command changes, no `.keyboardShortcut` moves, and no lint-visible construct is added.
   `appSheetPresented` (`QnetGUIApp.swift:1586` in round 1, today the property feeding
   `.onChange(of: appSheetPresented, initial: true)` at **816**) must keep listing every converted
   flag — a panel is still a dialog as far as the menus are concerned.

6. **Verification** —
   ```sh
   grep -c '\.sheet(' Sources/Qnet/QnetGUIApp.swift    # 6 today → 1
   swift build
   validation/gui_runtime_contracts.sh
   ```
   Then per form: open it from its menu item, drag it aside, confirm the canvas is visible and
   scrollable behind it, complete the form, confirm the result is identical to today's — and press
   `S` on the canvas while each panel is up: the tool must **not** change, because the `@State` flag
   is still set and `appSheetPresented` still mirrors it.

7. **Priority** — **P1.** Each of the five is reachable and correct today as a sheet; what is missing
   is the movability ask. Run parameters and Find Node are the two worth doing first if only some
   can be taken: the run-parameter dialog is the one users meet most often, and Find Node covers the
   canvas it is searching.

---

## Note to the integrator, not a request

`AppSettings.swift` gained `"panes.detached"` (`:908`, with the `@AppStorage` at `:574`) during this
round, from whichever workstream owns pane detachment. Under the pre-round-3 code that would have
been a **fresh instance of the same blocker** — a debug build dying on ⌘,. W4 found it by running
the new audit and has added the matching `SettingsRegistry.unindexedKeys` line for it in
`SettingsView.swift`:

```swift
        "panes.detached":        "View ▸ Panes ▸ Separate Windows, not a setting — which panes are torn out into windows of their own, restored on the next launch the way a window frame is",
```

If that key is renamed or dropped before the round closes, this line must move with it — the audit
will say so in one sentence rather than crashing, but it will say so.
