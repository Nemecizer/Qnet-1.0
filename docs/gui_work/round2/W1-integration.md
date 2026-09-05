# W1 — Canvas gestures and rendering · round 2 integration requests

Round 2 closed the blocker (the archetype gallery had no affordance on the empty canvas) and
all eight polish findings against W1-owned files, and picked up the deferred **W1-05** part (1)
— arrow keys scroll when nothing is selected. Nothing shipped this round depends on a foreign
edit: both requests below are P1.

Files W1 changed: `NetworkCanvasView.swift`, `NetworkCanvasOverlays.swift`,
`NetworkCanvasScrollContainer.swift`, `MenuKeyAliases.swift`, `KeyboardShortcutReference.swift`.

---

## W1-INT-4 — "New from Template…" is now an address, not just a label

1. **ID** — `W1-INT-4`. Completes the round-2 blocker *"the archetype gallery has no affordance
   on the empty canvas"*. Shippable without it: this is a constraint to honour, not a patch to
   apply, and it costs nothing unless someone renames the item. It is the exact twin of round 1's
   `W1-INT-2`, which carried the same constraint for File ▸ Open Example….

2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift` (W5), `fileMenu`, line 252,
   quoted verbatim from today's source:
   ```swift
               Button("New from Template…") { actions.insertArchetype() }
                   .keyboardShortcut("n", modifiers: [.command, .option])
                   .disabled(sheetPresented)
                   .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```

3. **Insert / replace** — no edit is requested. The constraint: the empty canvas's
   "Start from a Template…" button performs this menu item **by title**, through
   `MenuBarCommand.perform(MenuBarCommand.newFromTemplate)`, where

   ```swift
       static let newFromTemplate = ["File", "New from Template…"]
   ```

   If the item's title, or the title of its parent menu, changes, change that constant in the
   same edit:

   ```swift
       static let newFromTemplate = ["File", "<the new title>"]
   ```

   A mismatch is neither a crash nor a wrong command: `canPerform` returns false, the canvas
   stops offering the button, and the empty state falls back to "Open an Example…" alone. That
   is the failure mode to look for if the button disappears.

   The same already-standing constraint applies to `openExample = ["File", "Open Example…"]`
   (line 248). Both constants live in `Sources/Qnet/MenuKeyAliases.swift` (W1-owned) beside each
   other, with a doc comment saying so.

   Note that `.disabled(sheetPresented)` is honoured, not fought: while a sheet is up the
   button is not offered. That is correct — the gallery is itself a sheet.

4. **New symbols it depends on** — `MenuBarCommand.newFromTemplate`, added this round in
   `Sources/Qnet/MenuKeyAliases.swift`:
   ```swift
       @MainActor
       enum MenuBarCommand {
           static let openExample = ["File", "Open Example…"]
           static let newFromTemplate = ["File", "New from Template…"]
           static func canPerform(_ path: [String]) -> Bool
           @discardableResult static func perform(_ path: [String]) -> Bool
       }
   ```
   `canPerform` was hardened this round for the question the round-2 critic raised — whether
   `NSMenuItem.isEnabled` is meaningful before the File menu has ever been opened. It now
   re-checks after `NSMenu.update()`, AppKit's documented forcing function for the validation
   pass, but *only* when the first read says `false`, so the common answer never touches the
   menu and the check stays off the hot path of a `body` that runs on every editor publish.

5. **Gate impact** — none. No new `.keyboardShortcut` is registered: both empty-state buttons
   deliberately carry no key equivalent, so they cannot compete with File's ⇧⌘O / ⌥⌘N or hide
   a collision from `QNET_MENU_AUDIT=1`. No `gui_runtime_contracts.sh` string, no `Divider()`,
   no menu-path arrow, no `DSEmptyState` title change (it is still "No Network Yet").

6. **Verification** — launch with an empty canvas: the hint shows two live buttons,
   "Start from a Template…" (the empty state's own action row) and "Open an Example…" beneath
   it; clicking the first opens the archetype gallery, the second the example picker.
   `QNET_MENU_AUDIT=1 swift run Qnet` still reports no collision.

7. **Priority** — P1. The gallery is reachable meanwhile at File ▸ New from Template… (⌥⌘N)
   and Network ▸ Insert Archetype…; only the empty-canvas affordance depends on the title
   matching.

---

## W1-INT-5 — changelog bullets for the round-2 canvas work

1. **ID** — `W1-INT-5`. Completes the round's exit-gate requirement that shipped work is
   described in the in-development changelog entry. The code runs without it; the release notes
   would be wrong without it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (W6), the topmost entry, quoted
   verbatim from today's source:
   ```swift
               timestamp: nil,  // uses current AppVersion.buildTimestamp
               notes: [
   ```

3. **Insert / replace** — add these three bullets to that entry's `notes` array (position is the
   integrator's call; they are self-contained strings). They describe round-2 work only; round
   1's two W1 bullets were requested separately as `W1-INT-3` and are not repeated here.

   ```swift
                   "The empty canvas now offers the two shortest routes out of a blank page: \"Start from a Template…\" opens the archetype gallery and \"Open an Example…\" opens the bundled literature networks. Both perform their own menu item rather than keeping a second copy of the command, so a network is three clicks from a launched app.",
                   "Canvas gestures answer where they used to go quiet. In the Link tool, dragging out of a station and back onto it draws the self-loop that clicking it twice already drew, and a source, buffer or sink says why it cannot have one instead of cancelling in silence; a drag that wobbles without leaving its node is honoured as the click it was. A double-click on empty canvas reaches sticky pan in the Multi-Select tool as well as the Pointer — a rubber-band with no area is a click, and is no longer committed as a selection. And with a node tool active, the second click of a double-click is suppressed by where the node would land rather than by how far the pointer moved, so a shaky trackpad double-click can no longer stack a second, invisible node on the first.",
                   "With nothing selected, the arrow keys scroll the canvas one wheel line (⇧ = four) instead of doing nothing at all; with a selection they still nudge it by a whole grid cell.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — none. `Changelog.swift` is prose; `design_lint.sh` reads it for menu-path
   arrows (these bullets use no menu path — "Start from a Template…" and "Open an Example…" are
   quoted button labels, not `Menu ▸ Item` paths), bare ⌘-digits (none) and TeX braces (none).
   The escaped `\"…\"` quotes are required by the Swift string literal.

6. **Verification** — `swift build`, then Help ▸ Release Notes shows the three bullets in the
   top (undated) entry.

7. **Priority** — P1.

---

## Notes for the integrator (no action required)

- `CanvasEmptyHint` now orders its two offers by usefulness rather than by declaration order:
  the template goes in `DSEmptyState`'s single action row and the example stacks beneath it.
  Either may be absent (its menu item missing or disabled) and one absent offer simply promotes
  the other, so no combination of menu states can produce an empty action area or a stray gap.
- W1 did **not** implement the round-1 backlog item W1-05 part (2), Escape-cancels-an-in-flight
  drag. It needs a published cancel flag on `NetworkEditorModel` (W2-owned) — the drag state
  lives in `@State` on `CanvasContentView` and is not reachable from the scroll container's
  `keyDown`. If a later round wants it, the model needs one seeded `@Published var
  cancelDragToken: Int` (or equivalent) in the same way `pendingLinkPoint` was seeded for
  round 1; W1 can then do the rest without a foreign edit. Part (1), arrow-keys-scroll, shipped.
