# Round 4 — W1 (Canvas gestures and rendering) integration requests

Two requests. Both belong to **R6** ("The empty canvas primary button is dead while the panel it
opens is up"). W1's half of R6 — offering both empty-state buttons unconditionally and taking
`NSMenu.update()` out of `MenuBarCommand.canPerform` — has landed in
`Sources/Qnet/NetworkCanvasView.swift` and `Sources/Qnet/MenuKeyAliases.swift`. The button is now
always drawn and always live, but the command it fires is still refused while `sheetPresented` is
true, so **R6 is not closed until W1-INT-1 is applied**.

---

## W1-INT-1 — remove `.disabled(sheetPresented)` from File ▸ New from Archetype…

1. **ID** — `W1-INT-1`, completes **R6**. R6 is **not** shippable without it: with the modifier in
   place `MenuBarCommand.perform` finds the item disabled and returns false, so the canvas's
   "Start from an Archetype…" button does nothing whenever the archetype panel is open — which,
   because that panel is a movable window the user is meant to work beside, is exactly when they
   press it again.

2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift`, the File `CommandGroup`.
   Anchor, verbatim from today's source, lines 252–255:

   ```swift
            Button("New from Archetype…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sheetPresented)
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```

3. **Insert / replace** — delete the single line `.disabled(sheetPresented)` (line 254). Before →
   after:

   ```swift
   // before
            Button("New from Archetype…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sheetPresented)
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")

   // after
            Button("New from Archetype…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```

   Nothing else in that Button changes: same title (it is the address `MenuBarCommand` matches on —
   `MenuKeyAliases.swift:85` spells `["File", "New from Archetype…"]`), same shortcut, same help.
   The neighbouring `Button("Open Example…")` already carries no `.disabled`, so this makes the two
   onboarding commands consistent.

   Safety of the removal: the gallery is presented through `DSPanelWindow`, keyed by id, and
   `DSPanelWindow.present` brings an already-open panel forward rather than stacking a second one —
   so a second request is a raise, not a duplicate presentation. This is the "one sheet per scene"
   hazard the `sheetPresented` comment at `QnetCommands.swift:176-190` describes, and it does not
   apply to a panel.

4. **New symbols it depends on** — none. The request only deletes a line.

5. **Gate impact** — none known. `validation/gui_runtime_contracts.sh` greps
   `QnetGUIApp.swift` / `SRBMExporter.swift` / `ctmc_dtandem.py`, not this Button; no title,
   shortcut, `Divider()`, menu arrow or `DSEmptyState` title changes, so `design_lint.sh` and
   `QNET_MENU_AUDIT=1` are unaffected. `DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` passes on
   W1's side of the change already.

6. **Verification** —
   ```sh
   swift build --scratch-path /tmp/qnet-build-int && /tmp/qnet-build-int/debug/Qnet &
   ```
   Dismiss the startup check, then File ▸ New Network for an empty canvas. Press the canvas's
   "Start from an Archetype…" button — the "Insert Archetype" window opens. Move it aside and press
   the button again: the panel must come forward (today nothing at all happens). With the panel
   open, File ▸ New from Archetype… must also read enabled.

7. **Priority** — **P0**.

---

## W1-INT-2 — `showArchetypeSheet` can be left true after the panel is gone, disabling the command for the rest of the session

1. **ID** — `W1-INT-2`, hardens **R6**. R6's user-visible symptom is fixed by W1-INT-1 for the
   normal case; this one is a separate stuck-state bug found while verifying R6, and it makes the
   command dead *permanently*, not only while the panel is up. Shippable without it, but the
   archetype path stays fragile.

2. **Target file and anchor** — the archetype panel's presentation and dismissal in
   `Sources/Qnet/QnetGUIApp.swift` (**W6-owned**), the `showArchetypeSheet` state that
   `appSheetPresented` folds in. Anchor, verbatim from today's source,
   `QnetGUIApp.swift:1974-1978`:

   ```swift
       private var appSheetPresented: Bool {
           showStartupDependencyCheck || showGenerateRandomSheet || showArchetypeSheet
               || showFindNodeSheet || showTestSetSheet
               || showSpectralConvergenceSheet || runParameterRequest != nil
       }
   ```

   Related anchor, `Sources/Qnet/DSPanelWindow.swift:396` (**W4-owned**), which recomputes the
   other half of the same gate from the live registry and is the pattern to copy:

   ```swift
           if context.modalPanelPresented != blocked { context.modalPanelPresented = blocked }
   ```

3. **Insert / replace** — no literal patch is offered, because the fix belongs to whoever owns the
   presentation: `showArchetypeSheet` must be driven back to `false` on **every** path that
   removes the panel — the panel's own `onClose`, `NSWindow.willCloseNotification`, and a window
   that is merely ordered out — in the same way `DSPanelWindow.syncMenuFlag()` recomputes
   `modalPanelPresented` from the open-panel registry rather than incrementing and decrementing it.
   The minimal shape: have the archetype panel's `DSPanelWindow.present(… onClose:)` set
   `showArchetypeSheet = false`, and assert on the same path that no other flag in
   `appSheetPresented` is left standing.

4. **New symbols it depends on** — none from W1.

5. **Gate impact** — none known; it is a state-lifetime fix, no strings or shortcuts.

6. **Verification** — observed on a clean launch of `/tmp/qnet-build-W1/debug/Qnet` at 03:52 on
   2026-09-05: after the Insert Archetype panel had been opened once and then went away (it was no
   longer listed among the process's AX windows, with the app frontmost), an AX read of the menu
   item reported `enabled=false` **after** forcing AppKit's validation pass by opening the File
   menu, and it stayed false for the rest of the session — so File ▸ New from Archetype…, Network ▸
   Insert Archetype… and every bare tool letter (`canvasCommandsActive`) were dead until relaunch,
   while File ▸ Open Example… (which carries no `sheetPresented` gate) stayed enabled. To
   reproduce: launch, dismiss the startup check, open the archetype panel, click another
   application so Qnet deactivates, come back, and read the File menu. After the fix the item must
   read enabled whenever no archetype panel is actually on screen.

7. **Priority** — **P1**.
