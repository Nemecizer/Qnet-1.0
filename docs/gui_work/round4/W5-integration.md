# W5 — round 4 integration requests

Workstream: **W5 — Shell, commands and menus**.
Assigned issue this round: **R5** (Undo does nothing). R5 itself was fixed entirely inside
`Sources/Qnet/QnetCommands.swift`, which W5 owns; nothing below is required for R5 to work.

---

## W5-INT-1 — add an undo-routing source contract to `validation/gui_runtime_contracts.sh`

1. **ID** — `W5-INT-1`. Completes the last clause of blocker **R5**
   ("Add a headless or scripted regression for it — nothing in `validation/` currently covers
   undo"). **R5 is shippable without it**: the routing fix is in place and was verified by driving
   the app. This request exists only because W5 is forbidden to modify anything under
   `validation/`, and because the whole reason R5 survived three rounds is that no gate could see
   it.

2. **Target file and anchor** — `validation/gui_runtime_contracts.sh`.
   Anchor, quoted verbatim from today's source, at line 9 (the constant block at the top):

   ```sh
   CTMC_SOURCE="$CHECK_ROOT/finite/fBNActmc/ctmc_dtandem.py"
   ```

   and the final line of the file, line 79:

   ```sh
   printf 'GUI runtime contracts passed.\n'
   ```

3. **Insert / replace** — two edits, both pure additions.

   (a) After the `CTMC_SOURCE=` line, add:

   ```sh
   COMMANDS_SOURCE="$CHECK_ROOT/Sources/Qnet/QnetCommands.swift"
   ```

   (b) Immediately **before** the closing `printf 'GUI runtime contracts passed.\n'`, add:

   ```sh
   # Edit ▸ Undo / Redo must not use NSApp.sendAction's return value as the
   # test for "a text field claimed this". sendAction reports success as soon
   # as any responder in the chain claims undo:, and with a live text input
   # context something always does, so the canvas undo stack becomes
   # unreachable and ⌘Z silently does nothing (round-4 blocker R5).
   if grep -Fq 'if !NSApp.sendAction(Selector(("undo:"))' "$COMMANDS_SOURCE"; then
       fail "Edit ▸ Undo routes on NSApp.sendAction's return value; the canvas undo stack is unreachable"
   fi
   if grep -Fq 'if !NSApp.sendAction(Selector(("redo:"))' "$COMMANDS_SOURCE"; then
       fail "Edit ▸ Redo routes on NSApp.sendAction's return value; the canvas redo stack is unreachable"
   fi
   grep -Fq 'Self.textEntryOwnsUndo(published: textFocused)' "$COMMANDS_SOURCE" \
       || fail "Edit ▸ Undo / Redo no longer gate the responder chain on text-entry focus"
   undo_focus_gates="$(grep -F -c 'Self.textEntryOwnsUndo(published: textFocused)' "$COMMANDS_SOURCE")"
   [[ "$undo_focus_gates" -eq 2 ]] \
       || fail "expected exactly 2 text-entry undo gates (Undo and Redo); found $undo_focus_gates"
   grep -Fq 'editor.undoManager.undo()' "$COMMANDS_SOURCE" \
       || fail "Edit ▸ Undo no longer reaches the canvas undo stack"
   grep -Fq 'editor.undoManager.redo()' "$COMMANDS_SOURCE" \
       || fail "Edit ▸ Redo no longer reaches the canvas redo stack"
   ```

4. **New symbols it depends on** — one, added by W5 this round in
   `Sources/Qnet/QnetCommands.swift` (line 375 as of this writing):

   ```swift
   private static func textEntryOwnsUndo(published: Bool) -> Bool {
       published || NSApp.keyWindow?.firstResponder is NSText
   }
   ```

   The greps also reference `editor.undoManager.undo()` / `.redo()`, which are unchanged from
   before this round.

5. **Gate impact** — this **is** a gate change: it adds four assertions to
   `gui_runtime_contracts.sh` and one new `COMMANDS_SOURCE` constant. It greps only
   `QnetCommands.swift`, a file `gui_runtime_contracts.sh` does not currently read, so it cannot
   affect any existing assertion. No `design_lint.sh` surface is touched (no `Divider()`, no
   `DSEmptyState` title, no menu-path arrow, no ⌘-digit). No `.keyboardShortcut` is added, so
   `QNET_MENU_AUDIT=1` is unaffected.

6. **Verification** —

   ```sh
   cd <repo> && validation/gui_runtime_contracts.sh    # must print "GUI runtime contracts passed."
   ```

   Then prove the check has teeth: temporarily restore the old body of the Undo button in
   `QnetCommands.swift` (`if !NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) { editor.undoManager.undo() }`),
   re-run the script, and confirm it now fails with
   "Edit ▸ Undo routes on NSApp.sendAction's return value". Revert.

7. **Priority** — **P0**. The blocker text names the missing regression as part of the required
   fix, and R5 was reported-and-not-fixed for three rounds precisely because nothing in
   `validation/` looks at undo.

---

## W5-INT-2 — a *redo* logs "Undid: …" in the Status pane

1. **ID** — `W5-INT-2`. Not part of any task; it is a defect found while verifying **R5** by hand.
   R5 is shippable without it — the wrong word is cosmetic, and the redo itself is correct.

2. **Target file and anchor** — `Sources/Qnet/NetworkEditorModel.swift`, inside
   `private func registerReversal(to state: NetworkSnapshot, name: String)`.
   Anchor, quoted verbatim from today's source, at line 2888:

   ```swift
               self.addStatus("Undid: \(name).")
   ```

3. **Insert / replace** — `registerReversal` re-registers itself from inside its own undo closure,
   so the identical closure is what the *redo* stack runs; it therefore logs "Undid: …" for a redo
   too. Observed live: `Edit ▸ Redo` of an "Add Station" wrote
   `[03:53:31] [SUCCESS] Undid: Add Station.` to the Status pane.

   Before:

   ```swift
       private func registerReversal(to state: NetworkSnapshot, name: String) {
           undoManager.registerUndo(withTarget: self) { [weak self] target in
               guard let self else { return }
               let current = self.snapshot()
               self.restore(from: state)
               self.registerReversal(to: current, name: name)
               // An undone field run never continues: the next blur in the
               // docked Inspector registers its own entry instead of folding
               // into the one that was just reversed.
               self.endParameterRun()
               self.addStatus("Undid: \(name).")
           }
           undoManager.setActionName(name)
       }
   ```

   After — ask the undo manager which direction it is running in, and say so:

   ```swift
       private func registerReversal(to state: NetworkSnapshot, name: String) {
           undoManager.registerUndo(withTarget: self) { [weak self] target in
               guard let self else { return }
               // `isUndoing` is true only while the UNDO stack is running;
               // the same closure is re-registered onto the redo stack below,
               // so this is what tells the two apart.
               let verb = self.undoManager.isUndoing ? "Undid" : "Redid"
               let current = self.snapshot()
               self.restore(from: state)
               self.registerReversal(to: current, name: name)
               // An undone field run never continues: the next blur in the
               // docked Inspector registers its own entry instead of folding
               // into the one that was just reversed.
               self.endParameterRun()
               self.addStatus("\(verb): \(name).")
           }
           undoManager.setActionName(name)
       }
   ```

   Note the `verb` must be read **before** `restore(from:)` and the re-registration, while the
   manager is still inside the invocation it is running.

4. **New symbols it depends on** — none. `UndoManager.isUndoing` is AppKit API;
   `undoManager` is the existing `let undoManager = UndoManager()` at
   `NetworkEditorModel.swift:268`.

5. **Gate impact** — none. `gui_runtime_contracts.sh` does not read
   `NetworkEditorModel.swift`. `design_lint.sh` does not inspect status-log strings, and "Undid" /
   "Redid" are not menu paths, empty-state titles or DS tokens. No shortcut is added.

6. **Verification** — build, launch, place a station, `⌘Z`, then `⇧⌘Z`. The Status pane must read
   `Undid: Add Station.` followed by `Redid: Add Station.` — today the second line also says
   "Undid".

7. **Priority** — **P1**. The action is correct; only the word is wrong.

---

## W5-INT-3 — Changelog bullet for the undo fix

1. **ID** — `W5-INT-3`. Records **R5** in the release notes. R5 is shippable without it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (W6-owned). The topmost entry, the
   one carrying `timestamp: nil`. Add to its bullet list; do not create a new release entry, and do
   not touch `AppVersion.swift`.

3. **Insert / replace** — add these two bullets:

   ```swift
   "Undo and Redo work again. Edit ▸ Undo and ⌘Z decided whether a text field had claimed the keystroke from NSApp.sendAction's return value, which is true whenever any responder claims undo: — so the canvas undo stack was never reached and Delete Selection and Clear Canvas could not be taken back. They now route on keyboard focus, and a focused text field still undoes its own typing.",
   "The Edit menu names the step: Undo Insert Tandem Line, Redo Delete Selection, rather than a bare Undo, so ⌘Z says what it will cost before you press it.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — none. `Changelog.swift` is not read by `gui_runtime_contracts.sh`.
   `design_lint.sh` checks that menu paths use `▸`; the bullets above use `▸` in
   "Edit ▸ Undo", which is the correct form. No TeX superscript braces, no ⌘-digit shortcut.

6. **Verification** — `swift build`, then Help ▸ Release Notes shows both bullets under the
   in-development entry.

7. **Priority** — **P1**.
