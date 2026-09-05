# Round 5 — W5 integration requests

W5 (shell, commands and menus) closed two blockers this round entirely inside its own files:

* **R5** — Edit ▸ Undo / Redo now resolve title, enablement and action through one routing
  decision (`QnetCommands.undoRouting(redo:)`), so the item can no longer be named for a canvas
  step while the keystroke is swallowed by an invisible text field.
* **"Stop does not stop the solver"** — `TerminalModel` records the run's process group while the
  wrapper is still alive and escalates SIGINT → SIGTERM → SIGKILL against *that group*, and no
  longer retires the run merely because the wrapper's completion file appeared.

Three things the fixes need, or would be strengthened by, live in files W5 does not own.

---

## W5-INT-1 — Make a canvas click actually resign the field editor

1. **ID** — `W5-INT-1`. Completes the second half of blocker **R5**. R5's shipped half (the menu
   never lies, and the document stack is always reachable) is **shippable without this**; with it,
   the stale state stops existing at all.

2. **Target file and anchor** — `Sources/Qnet/NetworkCanvasScrollContainer.swift`, in
   `final class CanvasClipView: NSView`, the existing `mouseDown` override. Anchor, verbatim from
   today's source at lines 592-597:

   ```swift
    override func mouseDown(with event: NSEvent) {
        // Make sure we own keyDown events so Delete / Arrow-keys / tool
        // hotkeys work the moment the user clicks the canvas.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
   ```

   **The intent is already there and it does not take effect.** Measured on the round-5 W5 build
   (`/tmp/qnet-build-W5/debug/Qnet`, pid 43062 and 49672) with a real CGEvent click on the canvas
   after typing one character into the Status pane's "Search status log" field: the very next
   Edit ▸ Undo invocation still reports `NSApp.keyWindow?.firstResponder` as
   `_SystemTextFieldFieldEditor` and `MenuContext.textInputHasFocus == true`. Either the SwiftUI
   hosting view above this clip view consumes the `mouseDown` so this override never runs, or
   SwiftUI hands the field editor straight back after `makeFirstResponder(self)`.

3. **Insert / replace** — replace the body above with:

   ```swift
    override func mouseDown(with event: NSEvent) {
        // Make sure we own keyDown events so Delete / Arrow-keys / tool
        // hotkeys work the moment the user clicks the canvas.
        //
        // A SwiftUI text field's editor does not resign on its own when a
        // click lands on a non-focusable view, so ⌘Z, ⌘X and ⌘C keep going
        // to an invisible search box for the rest of the session. Commit
        // and end that edit first, then take the responder; check again,
        // because SwiftUI can hand the field editor straight back.
        if let window, window.firstResponder is NSText {
            window.endEditing(for: nil)
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
        }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
   ```

   If the diagnosis is that this override never runs at all (the SwiftUI layer eats the event),
   the same three lines belong wherever the canvas's SwiftUI click gesture begins — the
   requirement is only that **one** click on the canvas leaves
   `NSApp.keyWindow?.firstResponder is NSText` false.

4. **New symbols it depends on** — none. Pure AppKit (`NSWindow.endEditing(for:)`,
   `NSWindow.makeFirstResponder(_:)`), no DS tokens, no W5 symbol.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` does not grep
   `NetworkCanvasScrollContainer.swift`; no `.keyboardShortcut`, no `Divider()`, no DS token, no
   menu-path arrow, so `design_lint.sh` is untouched.

6. **Verification** — build, launch, insert an archetype (Edit ▸ Undo reads
   "Undo Insert Tandem Line"), click the Status pane's search field and type one character
   (Edit ▸ Undo reads "Undo Typing"), then click once on empty canvas. Edit ▸ Undo must read
   **"Undo Insert Tandem Line"** immediately — today it still reads "Undo Typing" until the text
   field's own stack is drained.

7. **Priority** — **P0** for R5 being closed at the root rather than at the menu. The menu is
   already honest without it.

---

## W5-INT-2 — Let the first SIGINT reach the solver (progress-bar / spinner wrappers)

1. **ID** — `W5-INT-2`. Item 3 of the required fix for the blocker *"Stop does not stop the
   solver"*. **Shippable without it**: W5's group-targeted escalation already kills the solver
   1.5–2.0 s after Stop (measured three times: +1.89 s, +2.30 s, +2.04 s from click to
   `pgrep -f BNAsim/jackson_sim` empty, against the 3 s bar). This request removes the 1.5 s wait
   by making the *first* signal effective.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, the two shell wrappers that start
   the solver as a background job. Anchors, verbatim from today's source:

   * `withProgress(...)`, line 6168:

     ```
             { \(command) ; } & \
     ```

   * `withSpinner(...)`, the equivalent line (currently 6266):

     ```
             { \(command) ; } > "\(capture)" 2>&1 & \
     ```

   **Why this matters.** `{ … } &` is a bash *async list*: POSIX and bash set SIGINT and SIGQUIT
   to `SIG_IGN` in such a job, and every process it execs inherits that disposition. Confirmed
   against the solver source — `grep -rn 'SIGINT\|signal(' infinite/BNAsim/*.c` returns nothing,
   so `jackson_sim` installs no handler of its own; it is deaf to SIGINT purely by inheritance.
   Confirmed live: `kill -INT <jackson_sim>` leaves it at ~1750 % CPU, `kill -TERM` kills it
   instantly.

3. **Insert / replace** — restore the default SIGINT disposition inside the subshell, before the
   command runs. Before → after, in both wrappers:

   * `withProgress`:

     ```
             { \(command) ; } & \
     ```
     →
     ```
             { trap - INT ; \(command) ; } & \
     ```

   * `withSpinner`:

     ```
             { \(command) ; } > "\(capture)" 2>&1 & \
     ```
     →
     ```
             { trap - INT ; \(command) ; } > "\(capture)" 2>&1 & \
     ```

   Nothing else in either wrapper changes: `_sim_pid=$!`, `wait $_sim_pid`, `_rc=$?`, the poller
   subshell and the final `( exit $_rc )` all keep their present shape.

4. **New symbols it depends on** — none; this is shell text only.

5. **Gate impact** — `validation/gui_runtime_contracts.sh` asserts the EXIT/INT/TERM trap pattern
   and the count of exactly 8 `commandWithCleanup` Python runners. This edit adds a `trap` **inside
   the two spinner/progress wrappers**, which are not `commandWithCleanup`, and removes no existing
   trap, so neither assertion should move — but the contract greps on exact strings, so run
   `validation/gui_runtime_contracts.sh` in the same change and update the contract in the same
   commit if a count is phrased as "the only `trap` in this function".

6. **Verification** — Run ▸ Run Monte Carlo… at 1,000,000,000 time units on a 3-station tandem,
   press Stop, and assert `pgrep -f 'BNAsim/jackson_sim'` is empty within **1 second** (rather than
   the ~2 s the SIGTERM escalation currently needs). Also confirm a *normal* run still completes
   and reports its exit code: a clean Monte Carlo at the default 5,000,000 time units must still
   retire on its own (verified today: Run ▸ Stop Run returns to disabled ~3–4 s after launch).

7. **Priority** — **P1**. Stop already stops the solver without it.

---

## W5-INT-3 — The run-cancellation and undo-routing regression gates (validation/ is off-limits to W5)

1. **ID** — `W5-INT-3`. Item 4 of the *"Stop does not stop the solver"* required fix, and the
   second, smaller residual named in **R5** ("the scripted regression the blocker explicitly asks
   for does not exist"). Both blockers are **shippable without it**; without it they are once again
   ungated, which is exactly why R5 survived three rounds.

   W5 was instructed never to modify anything under `validation/`, so this is written out in full
   rather than applied.

2. **Target file and anchor** — `validation/gui_runtime_contracts.sh`, appended as two new
   source-text contracts, plus one new runtime check. Today that file contains no occurrence of
   `textEntryOwnsUndo`, `undoRouting`, `activeRunGroup` or `cancelSurvivorsOutstanding`
   (`grep -c` returns 0 for each), so nothing there can currently see either defect.

3. **Insert / replace** — three assertions.

   **(a) Undo routing is resolved once.** The R5 defect is precisely "the title and the action
   disagree". Assert in `Sources/Qnet/QnetCommands.swift` that the Undo and Redo buttons take both
   their title and their `.disabled(…)` from the routing struct, and that neither reads
   `editor.undoManager` directly in the `CommandGroup(replacing: .undoRedo)` block:

   ```sh
   # Edit ▸ Undo/Redo must describe themselves from the same routing decision
   # they act on — an item titled "Undo Add Station" must not hand ⌘Z to a
   # text field. (blocker R5, rounds 2-5)
   expect_count 1 'let undo = undoRouting(redo: false)'  Sources/Qnet/QnetCommands.swift
   expect_count 1 'let redo = undoRouting(redo: true)'   Sources/Qnet/QnetCommands.swift
   expect_count 1 '.disabled(!undo.available)'           Sources/Qnet/QnetCommands.swift
   expect_count 1 '.disabled(!redo.available)'           Sources/Qnet/QnetCommands.swift
   ```

   **(b) A cancelled run is judged by its process group, not by the wrapper pid.**

   ```sh
   # Stop must reach the work, not just the wrapper: the group is recorded
   # while the wrapper is alive, and the completion file is not believed
   # while that group still has members.
   expect_count 1 'private func captureActiveRunGroup'      Sources/Qnet/TerminalModel.swift
   expect_count 1 'private func cancelSurvivorsOutstanding' Sources/Qnet/TerminalModel.swift
   expect_at_least 1 'if self.cancelSurvivorsOutstanding()' Sources/Qnet/TerminalModel.swift
   ```

   (Use whatever the file's existing helper for "this exact string appears N times" is called —
   the two names above are placeholders for it.)

   **(c) The check with teeth: a real cancelled native run.** This is the one that would have
   caught the defect. It needs no GUI:

   ```sh
   # A long native solver run, cancelled the way the GUI cancels it, must be
   # gone within TerminalModel.cancelDeadline (3 s) — not 90.
   sim="$(ls Qnet.app/Contents/Resources/bin/infinite/BNAsim/jackson_sim 2>/dev/null \
          || echo infinite/BNAsim/jackson_sim)"
   if [ -x "$sim" ]; then
     inp="$(mktemp -t qnet_cancel_gate)"
     # smallest tandem the sim accepts; 1e9 time units so it cannot finish
     write_minimal_tandem_input "$inp"
     bash -c '{ trap - INT ; "$0" "$1" -c -n 50 -w 1000000 -r 1000000000 -s 1 ; } &
              echo $! > "$2" ; wait' "$sim" "$inp" /tmp/qnet_cancel_gate.pid &
     wrapper=$!
     sleep 2
     group=$(ps -o pgid= -p "$wrapper" | tr -d ' ')
     kill -INT  "-$group" 2>/dev/null
     sleep 1.5
     kill -TERM "-$group" 2>/dev/null
     sleep 1.5
     if pgrep -f 'BNAsim/jackson_sim' >/dev/null; then
       kill -KILL "-$group" 2>/dev/null
       fail "cancelled solver survived the 3 s cancel deadline"
     fi
   fi
   ```

   The important property is the assertion, not the plumbing: **start a long native run, cancel it
   the way `TerminalModel` cancels it, and assert the solver pid is gone within
   `TerminalModel.cancelDeadline`.** A gate that only exercises the clean case will pass while the
   bug is live — which is what happened for three rounds.

4. **New symbols it depends on** — `undoRouting(redo:)` and the `UndoRouting` struct
   (`Sources/Qnet/QnetCommands.swift`, added round 5, `private`), and
   `captureActiveRunGroup()` / `activeRunGroupIsAlive()` / `cancelSurvivorsOutstanding()` /
   `static let cancelAbandonAfter: TimeInterval = 10` (`Sources/Qnet/TerminalModel.swift`, added
   round 5, `private` except the constant). All exist in the delivered tree.

5. **Gate impact** — this *is* gate work. It adds assertions to
   `validation/gui_runtime_contracts.sh`; it must not change any existing assertion. Whoever
   applies it owns keeping the quoted strings in step with the two source files.

6. **Verification** — `validation/gui_runtime_contracts.sh` passes on the delivered tree, and
   fails if either fix is reverted: revert `signalActiveRun` to `let group = getpgid(pid)` and
   check (b)/(c) fail; retitle the Undo button back to
   `Button(undoRedoTitle("Undo", editor.undoManager.undoActionName, …))` and check (a) fails.

7. **Priority** — **P0** as a gate. Both defects are fixed and verified by hand today; nothing
   automated can see a regression.
