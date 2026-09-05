# W5 — integration requests, round 2

Workstream: **W5 — The interactive shell as the centrepiece**.
Files W5 changed this round: `Sources/Qnet/TerminalModel.swift`,
`Sources/Qnet/TerminalConsoleView.swift`, `Sources/Qnet/QnetCommands.swift`.

Round 2 was a fix round: both critic blockers and all four polish items landed
inside those three files. Two requests follow, both P1, and both are consequences
of one round-2 change — `TerminalModel.sendCommand` now asks `commandBlocker`
*before* unwrapping `terminalView`, which makes `ShellCommandBlocker.shellUnavailable`
reachable for the first time. Its message tells the user to open the Shell with
**Window ▸ Focus Shell**, so that command has to actually be able to open it.

---

## W5-INT-4 — Window ▸ Focus Shell must un-maximize a soloed sibling pane

1. **ID** — `W5-INT-4`. Completes the round-2 blocker fix
   *"ShellCommandBlocker.shellUnavailable is unreachable"* (W5-05's refusal path).
   The fix itself is shipped and shippable without this: a run launched with the
   Shell never mounted is now refused with words instead of failing silently as
   "exit -1" half a second later. What this request fixes is the **advice** in
   that message in one specific new state.

   `TerminalPaneView` mounts only under `if shows(.shell)`
   (`ContentView.swift:263`), and `shows(_:)` is
   `if let solo = appSettings.soloedPane { return solo == pane }`
   (`ContentView.swift:61-62`). So with another pane maximized — W3's new persisted
   `panes.soloed` — the Shell is not mounted, `terminalView` is nil, a run is
   refused with `.shellUnavailable`, and its message says
   *"show it with Window ▸ Focus Shell, then run again."* But `revealShell` only
   sets `shellPaneVisible`; it never clears `soloedPane`, so Focus Shell reveals
   nothing, focus does not move, and the user follows correct instructions into a
   dead end. (The pre-existing hidden-pane case — `shellPaneVisible == false`, no
   solo — works correctly today and is unaffected.)

2. **Target file and anchor** — `Sources/Qnet/WorkspaceCommands.swift`,
   `static func revealShell(appSettings:then:)`. Anchor lines, verbatim from
   today's source (lines 318–324):

   ```swift
       static func revealShell(appSettings: AppSettings,
                               then action: @escaping @MainActor () -> Void) {
           if !appSettings.shellPaneVisible {
               withAnimation(DS.Motion.standard) { appSettings.shellPaneVisible = true }
           }
           afterLayout(action)
       }
   ```

3. **Insert / replace** — before → after. Replace the body only; the signature,
   the `afterLayout(action)` tail and the doc comment above it are unchanged.

   ```swift
   // before
       static func revealShell(appSettings: AppSettings,
                               then action: @escaping @MainActor () -> Void) {
           if !appSettings.shellPaneVisible {
               withAnimation(DS.Motion.standard) { appSettings.shellPaneVisible = true }
           }
           afterLayout(action)
       }

   // after
       static func revealShell(appSettings: AppSettings,
                               then action: @escaping @MainActor () -> Void) {
           // "Visible" is two conditions, not one: a pane is drawn when its own
           // toggle is on AND no *other* pane has the window to itself
           // (ContentView's `shows(_:)`). Focus Shell promises to show the Shell,
           // so it has to answer both — otherwise, with the Results pane
           // maximized, this sets a flag nobody reads and focus lands nowhere.
           // Maximizing the Shell itself is left alone: that already shows it.
           withAnimation(DS.Motion.standard) {
               if let solo = appSettings.soloedPane, solo != .shell {
                   appSettings.soloedPane = nil
               }
               if !appSettings.shellPaneVisible {
                   appSettings.shellPaneVisible = true
               }
           }
           afterLayout(action)
       }
   ```

   Note the two mutations are inside **one** `withAnimation` so the restore and
   the reveal are a single transition rather than two overlapping ones.

   **Optional, same reasoning, W3's call:** the four sibling Focus commands
   (`Focus Tools`, `Focus Status`, `Focus AI Input`, `Focus Inspector`, and
   `Focus Canvas`) have the identical gap — each sets only its own
   `…PaneVisible`. W5 asks for the Shell because a refusal message now points at
   it by name; the others are W3's to judge.

4. **New symbols it depends on** — none new. `appSettings.soloedPane`
   (`Sources/Qnet/AppSettings.swift:515`, `var soloedPane: FocusRouter.Pane?`) and
   `FocusRouter.Pane.shell` both already exist and are already written by
   `WorkspaceCommands.applyWorkspacePreset` (`:400`) in exactly this way
   (`appSettings.soloedPane = nil` inside a `withAnimation(DS.Motion.standard)`).

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` reads only
   `QnetGUIApp.swift`, `SRBMExporter.swift` and `ctmc_dtandem.py`. No
   `.keyboardShortcut` is added or changed, so `QNET_MENU_AUDIT=1` has nothing new
   to clear. No `DSEmptyState` title, no `Divider()`, no menu-path arrow, no
   ⌘-digit, no raw colour or literal: `DS.Motion.standard` is the token already in
   use on the line being replaced. `validation/design_lint.sh` passes with this
   applied.

6. **Verification** — View ▸ Panes ▸ Maximize Pane (⌃⌘↩) with the **Results** pane
   focused, then Run ▸ QNA. The Status pane must read
   *"QNA was not started. The Shell has not been opened yet — show it with
   Window ▸ Focus Shell, then run again."* Choose Window ▸ Focus Shell: the split
   layout must come back with the Shell in it and keyboard focus in the terminal.
   Run ▸ QNA again: it launches.

7. **Priority** — **P1**. The refusal itself is correct and actionable in the
   common case (Shell simply hidden); only the maximized-sibling variant sends the
   user to a command that does nothing.

---

## W5-INT-5 — one changelog clause for the never-opened Shell

1. **ID** — `W5-INT-5`. Documents the round-2 blocker fix. No task depends on it.
   W5-INT-3's three bullets from round 1 are already applied and all three are
   still accurate; this amends one clause of one of them.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost
   (`timestamp: nil`) entry. Anchor line, verbatim from today's source (line 55):

   ```swift
                   "A solver run is typed into the interactive shell, so Qnet now checks that the shell is free before typing. A half-typed command line is discarded rather than concatenated into the launch, and a run is refused outright — with the reason in the Status pane and the status bar back at Idle — when a full-screen program such as vim or less owns the screen, or a command such as cat is reading the keyboard.",
   ```

3. **Insert / replace** — replace that one string with:

   ```swift
                   "A solver run is typed into the interactive shell, so Qnet now checks that the shell is free before typing. A half-typed command line is discarded rather than concatenated into the launch, and a run is refused outright — with the reason in the Status pane and the status bar back at Idle — when a full-screen program such as vim or less owns the screen, when a command such as cat is reading the keyboard, or when the Shell pane has not been opened yet, which used to surface a minute later as a bare “exit -1”.",
   ```

   The only change is the tail: `or when the Shell pane has not been opened yet,
   which used to surface a minute later as a bare “exit -1”.` Curly quotes, to
   match the surrounding entries.

4. **New symbols it depends on** — none.

5. **Gate impact** — none. No ⌘-digit, no `→`, no TeX braces, no DS surface. The
   string contains a `▸`-free menu reference only by pane name.

6. **Verification** — `swift build && DS_SKIP_CONTRAST=1 ./validation/design_lint.sh`,
   then Help ▸ Release Notes shows the amended bullet under the in-development
   entry.

7. **Priority** — **P1**.

---

## Not requested, deliberately

- **No change to `ContentView.copyFromShell()`.** A critic asked that
  `copySelectionOrAll()` be split so "copy everything" can never be the silent
  fallback of a command called Copy. It was: `TerminalModel` now has
  `copySelection() -> String?` (selection only, nil when there is none) and
  `copyEntireScrollback() -> String?`, and ⌘C and the context menu both call the
  first. `copySelectionOrAll()` survives as a two-line composition
  (`copySelection() ?? copyEntireScrollback()`) for exactly one caller — the pane
  header's Copy button, whose help already reads *"Copy the selection, or the
  whole scrollback when nothing is selected"* and whose status line then says
  which of the two happened. That button is the announced affordance the critic
  wanted the fallback confined to, so it needs no edit; its doc comment now says
  so, and points anything else at `copySelection()`.
- **No `QnetGUIApp.swift` change.** All nine `sendCommand(` call sites already
  guard their "Running …" line on the return value (W5-INT-2, applied), and
  reordering the two checks inside `sendCommand` does not change its contract:
  it still returns false without typing, only now with a report attached.
- **No new DS token.** Nothing W5 changed this round draws anything.
