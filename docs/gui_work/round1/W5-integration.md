# W5 — integration requests, round 1

Workstream: **W5 — The interactive shell as the centrepiece**.
Files W5 changed this round: `Sources/Qnet/TerminalModel.swift`,
`Sources/Qnet/TerminalConsoleView.swift`, `Sources/Qnet/QnetCommands.swift`.

Three requests. Only the first is P0.

---

## W5-INT-1 — register the Shell's Find Next / Find Previous handler

1. **ID** — `W5-INT-1`. Completes **W5-01** (⌘F routes to the terminal find bar).
   The ⌘F half of W5-01 is already shipped and does **not** depend on this: the
   `.shell` find handler was already registered, and `performFind()` now dispatches
   through it. What is missing without this request is ⌘G / ⇧⌘G — Edit ▸ Find Next
   and Find Previous stay greyed out while the Shell has focus, because
   `FocusRouter.canStepFind` is false until a step handler is registered for the
   pane. Everything else in W5-01 is shippable as it stands.

2. **Target file and anchor** — `Sources/Qnet/ContentView.swift`, in
   `TerminalPaneView.body`'s `.onAppear` block. Anchor line, verbatim from today's
   source (line 1365):

   ```swift
            FocusRouter.shared.setFindHandler(.shell) { terminal.showFind() }
   ```

3. **Insert / replace** — insert immediately **after** that line, inside the same
   `.onAppear` block:

   ```swift
            // ⌘G / ⇧⌘G in the Shell. SwiftTerm searches for whatever is on the
            // system find pasteboard — its own find bar writes there on every
            // keystroke — so the step handler is registered without a `canStep`
            // predicate: the find bar is private, there is no event to
            // re-evaluate the menu on while the user types into it, and an
            // enabled item that finds nothing is a far smaller failure than a
            // dead ⌘G. Edit ▸ Find Next's tooltip does read the pasteboard
            // (`terminal.hasFindTerm`) and says which of the two states it is in.
            FocusRouter.shared.setFindStepHandler(.shell) { delta in
                terminal.findNext(delta)
            }
   ```

   Nothing is removed or reworded. Do **not** add a `canStep:` argument.

4. **New symbols it depends on** — one, added by W5 this round:

   - `TerminalModel.findNext(_ delta: Int)` — `Sources/Qnet/TerminalModel.swift`,
     declared `func findNext(_ delta: Int)` in the `MARK: - Clipboard / navigation`
     section, immediately after `showFind()`. It posts
     `NSTextFinder.Action.nextMatch` / `.previousMatch` through SwiftTerm's
     `performTextFinderAction`, and deliberately does not take first responder.

   `FocusRouter.setFindStepHandler(_:_:canStep:)` already exists
   (`Sources/Qnet/PaneChrome.swift:108`) and is used by the Status and AI panes;
   nothing there changes.

5. **Gate impact** — none. No string `validation/gui_runtime_contracts.sh` greps
   (it reads only `QnetGUIApp.swift`, `SRBMExporter.swift`, `ctmc_dtandem.py`). No
   new `.keyboardShortcut` — ⌘G and ⇧⌘G are already bound in `QnetCommands.swift`
   and `QNET_MENU_AUDIT=1` has already cleared them. No `DSEmptyState`, no
   `Divider()`, no menu-path arrow, no ⌘-digit. `validation/design_lint.sh` passes
   with this applied.

6. **Verification** — build, launch, click into the Shell so the pane header rule
   lights, press ⌘F, type a word that appears in the scrollback, then press ⌘G
   repeatedly: the highlight advances match by match and ⇧⌘G walks back. With the
   Shell focused, Edit ▸ Find Next reads enabled rather than greyed.

7. **Priority** — **P0**. Edit ▸ Find Next is dead in the Shell without it, and the
   Edit menu already advertises the pair.

---

## W5-INT-2 — do not log "Running …" after a refused launch

1. **ID** — `W5-INT-2`. Completes **W5-05** (busy-shell guard). W5-05 itself is
   shipped and works without this: `TerminalModel.sendCommand` now refuses to type
   into a shell that a full-screen program or a stdin-reading command owns, reports
   the refusal to the originating tab's Status pane as an error, retires the run
   through `finishRun` (so the status bar returns to Idle and
   `finalizeStructuredResult` closes the Results record), and beeps. What this
   request fixes is only the *order* of two Status lines: each caller writes its own
   optimistic "Running …" line straight after `sendCommand`, so a refused launch
   currently reads
   `QNA was not started. The Shell is busy …` followed by `Running QNA...`.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`. Nine call sites,
   all of the same shape. Anchors, verbatim from today's source:

   | line | anchor |
   |------|--------|
   | 1753 | `                    terminalModel.sendCommand(script)` |
   | 2528 | `                terminalModel.sendCommand(script)` |
   | 2609 | `                terminalModel.sendCommand(script)` |
   | 2717 | `            terminalModel.sendCommand(script)` |
   | 2803 | `                terminalModel.sendCommand(script)` |
   | 3201 | `            terminalModel.sendCommand(script)` |
   | 6257 | `                terminalModel.sendCommand(script)` |
   | 6312 | `                terminalModel.sendCommand(script)` |

   (Line 6005, `terminalModel.sendCommand("bash \"\(script.path)\"")` inside
   `runScript`, needs no change: it is the last statement before `return true` and
   writes no follow-up status line. If W6 wants `runScript` to report the truth to
   its caller, change that line to
   `return terminalModel.sendCommand("bash \"\(script.path)\"")` and delete the
   following `return true`.)

3. **Insert / replace** — at each of the eight sites, guard the status line on the
   return value. `sendCommand` is now
   `@discardableResult func sendCommand(_ command: String) -> Bool`, so every site
   still compiles untouched; this is the improvement, not a fix for a break. Before
   → after, using line 2528 as the worked example:

   ```swift
   // before
               ) {
                   terminalModel.sendCommand(script)
                   activeEditor.addStatus("Running finite element (…)...", severity: .info)
               }

   // after
               ) {
                   // The Shell can refuse the command (a full-screen program or a
                   // stdin-reading command owns it); TerminalModel has already
                   // said so and retired the run, so do not follow it with a
                   // "Running …" line that is not true.
                   if terminalModel.sendCommand(script) {
                       activeEditor.addStatus("Running finite element (…)...", severity: .info)
                   }
               }
   ```

   Apply the identical shape at the other seven sites, wrapping **only** the
   `addStatus` call (and, at line 3201, the two lines that build and log the
   `chain` description) in `if terminalModel.sendCommand(script) { … }`. No message
   text changes.

4. **New symbols it depends on** — one signature change, made by W5 this round:

   - `TerminalModel.sendCommand(_ command: String) -> Bool` —
     `Sources/Qnet/TerminalModel.swift`, declared
     `@discardableResult func sendCommand(_ command: String) -> Bool`. Returns true
     when the command was typed. It is `@discardableResult`, so existing call sites
     compile unchanged.
   - `ShellCommandBlocker` (top-level enum in the same file) and
     `TerminalModel.commandBlocker: ShellCommandBlocker?` are the reason it can
     return false. Nothing outside `TerminalModel` needs to name them.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` asserts the
   EXIT/INT/TERM trap text, the count of exactly 8 `commandWithCleanup` Python
   runners and the `${PIPESTATUS[0]}` pipeline shape; this request touches none of
   those — it changes neither the wrapper script text nor the command string, only
   Swift control flow around a status message. No shortcut, no DS surface.

6. **Verification** — run `cat` in the Shell (no arguments), then Run ▸ QNA. The
   Status pane must show exactly one line, the error
   `QNA was not started. The Shell is busy — finish or interrupt what is running
   there first.`, with no `Running QNA...` after it, and the status bar must return
   to Idle. Then press ⌃C in the Shell to end `cat` and Run ▸ QNA again: it launches
   normally.

7. **Priority** — **P1**. The guard works and the run retires correctly either way;
   this only removes a contradictory second line from the log.

---

## W5-INT-3 — changelog bullets

1. **ID** — `W5-INT-3`. Documents W5-01 … W5-05. No task depends on it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost entry,
   the one marked in-development. Anchor lines, verbatim from today's source
   (lines 42–45):

   ```swift
               version: "0.90.02",
               timestamp: nil,  // uses current AppVersion.buildTimestamp
               notes: [
   ```

3. **Insert / replace** — append these two strings to that entry's `notes` array
   (order within the array is presentation order; W5 has no opinion on where they
   sit relative to other workstreams' bullets):

   ```swift
                   "The Shell behaves like a terminal. ⌘F opens its own find bar over the scrollback instead of the canvas's Find Node prompt, ⌘G and ⇧⌘G walk the matches, ⌘C copies the shell selection — SwiftTerm's view is not a text field, so Edit ▸ Copy could not see a selection there at all — and a right-click offers Copy, Paste, Select All, Find in Shell…, Scroll to Bottom and Clear Shell, with the same titles those commands carry in the pane header and in Window ▸ Shell.",
                   "Wide solver output no longer wraps into an unreadable zig-zag. Qnet measures the width of the lines the shell prints, straight off the byte stream and ignoring colour codes, progress-bar redraws and the shell's own prompt sequences, so a comparison table wider than the pane keeps every row on one line and offers the horizontal scroller instead. Clearing the Shell retracts it again, and changing the shell font re-computes it.",
                   "A solver run is typed into the interactive shell, so Qnet now checks that the shell is free before typing. A half-typed command line is discarded rather than concatenated into the launch, and a run is refused outright — with the reason in the Status pane and the status bar back at Idle — when a full-screen program such as vim or less owns the screen, or a command such as cat is reading the keyboard.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — none. The strings contain no ⌘-digit, no `→`, no TeX braces,
   and no DS surface. Note the `⌘F` / `⌘G` / `⇧⌘G` / `⌘C` spellings are already in
   canonical modifier order.

6. **Verification** — `swift build && DS_SKIP_CONTRAST=1 ./validation/design_lint.sh`,
   then Help ▸ Release Notes shows the bullets under the in-development entry.

7. **Priority** — **P1**.

---

## Not requested, deliberately

- **No new DS token.** W5 added no view chrome this round: the context menu is
  AppKit `NSMenu` / `NSMenuItem.separator()`, which is outside the `Divider()` rule
  and outside the token surface entirely.
- **No `QnetGUIApp.swift` change for the Results record.** The backlog's W5-05 note
  worried that a refused launch would leave a permanently "running" row in the
  Results workspace. It does not: `refuseCommand` retires the run through
  `finishRun`, which publishes `lastRunSummary`, which the existing
  `.onChange(of: terminalModel.lastRunSummary)` at `QnetGUIApp.swift:904` feeds to
  `finalizeStructuredResult`, which calls `ResultsStore.failRun`. This is the same
  path the pre-existing `failRunToLaunch` (script could not be written) already
  used. The only wart is the message it produces — "QNA exited with status -1" —
  which is inherited, not new; if a later round wants a better one, it belongs in
  `finalizeStructuredResult`, not here.
- **No `PaneChrome.swift` change.** `setFindStepHandler` already supports
  everything W5-INT-1 needs.
