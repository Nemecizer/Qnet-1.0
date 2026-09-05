# W1 — Canvas gestures and rendering · round 1 integration requests

Shipped this round: **W1-01** sticky pan, **W1-02** drag-to-connect with an elastic
preview, **W1-03** corner-grip geometry, **W1-04** actionable empty canvas. **W1-05**
deferred.

Everything below is a request against a file W1 does not own. All three are P1: every
shipped task works without them.

---

## W1-INT-1 — clear `pendingLinkPoint` where `pendingLinkStartID` is cleared

1. **ID** — `W1-INT-1`. Completes **W1-02**. W1-02 is shippable without it: the canvas
   view clears `pendingLinkPoint` itself on drag end and on the next hover event, and the
   preview layer is gated on `pendingLinkStartID`, so a stale point draws nothing. This is
   model hygiene — the two properties describe one gesture and should die together.

2. **Target file and anchor** — `Sources/Qnet/NetworkEditorModel.swift` (W2).
   Two sites, both quoted from today's source:

   - `func setTool(_ tool: EditorTool)`, line 438:
     ```swift
         func setTool(_ tool: EditorTool) {
             selectedTool = tool

             if tool != .addLink {
                 pendingLinkStartID = nil
                 activeLinkSourceID = nil
             }
     ```
   - `func deselectAll()`, line 561:
     ```swift
         func deselectAll() {
             endNudgeRun()
             clearMultiSelection()
             pendingLinkStartID = nil
             activeLinkSourceID = nil
     ```

3. **Insert / replace** — add one line to each, immediately after the existing
   `activeLinkSourceID = nil`:

   `setTool`, before → after:
   ```swift
             if tool != .addLink {
                 pendingLinkStartID = nil
                 activeLinkSourceID = nil
             }
   ```
   ```swift
             if tool != .addLink {
                 pendingLinkStartID = nil
                 activeLinkSourceID = nil
                 // The rubber-band's free end belongs to the same gesture
                 // as its start: leaving the Link tool ends both.
                 pendingLinkPoint = nil
             }
   ```

   `deselectAll`, before → after:
   ```swift
             pendingLinkStartID = nil
             activeLinkSourceID = nil
   ```
   ```swift
             pendingLinkStartID = nil
             activeLinkSourceID = nil
             pendingLinkPoint = nil
   ```

4. **New symbols it depends on** — none new. `pendingLinkPoint` is the pre-round seed
   already declared at `NetworkEditorModel.swift:398`
   (`@Published var pendingLinkPoint: CGPoint?`).

5. **Gate impact** — none. No string `gui_runtime_contracts.sh` greps, no
   `.keyboardShortcut`, no `DSEmptyState` title, no `Divider()`, no menu-path arrow.

6. **Verification** — Link tool, click S1 (a dashed line follows the pointer), press
   Escape, then move the pointer: the line is gone and stays gone. Then `swift build`.

7. **Priority** — P1.

---

## W1-INT-2 — "Open Example…" is now an address, not just a label

1. **ID** — `W1-INT-2`. Completes **W1-04**. W1-04 is shippable without it — this is a
   constraint to honour, not a patch to apply, and it costs nothing unless someone renames
   the item.

2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift` (W5), `fileMenu`,
   line 239, quoted verbatim:
   ```swift
               Button("Open Example…") { actions.openExample() }
                   .keyboardShortcut("o", modifiers: [.command, .shift])
                   .help("Open one of the bundled literature networks")
   ```

3. **Insert / replace** — no edit is requested. The constraint: the empty canvas's
   "Open an Example…" button performs this menu item by title, through
   `MenuBarCommand.perform(MenuBarCommand.openExample)`, where
   `openExample = ["File", "Open Example…"]`. If the item's title or its parent menu's
   title changes, change that constant in the same edit:

   ```swift
       static let openExample = ["File", "<the new title>"]
   ```

   A mismatch is not a crash and not a wrong command: `canPerform` returns false, so the
   canvas simply stops offering the button and the empty state reverts to text. That is
   the failure mode to look for if the button disappears.

   If W5 would rather not carry the constraint, the alternative is to hand the canvas a
   closure: `QnetGUIApp` already owns `loadExample()` (wired at `QnetGUIApp.swift:1014`,
   `openExample: { loadExample() }`), and passing it down to `NetworkCanvasView` would let
   `CanvasEmptyHint(onOpenExample:)` take it directly. That touches `QnetGUIApp.swift`
   (W6) and `ContentView.swift`, which is why round 1 did not take that route.

4. **New symbols it depends on** — `MenuBarCommand` (new this round),
   `Sources/Qnet/MenuKeyAliases.swift`:
   ```swift
       @MainActor
       enum MenuBarCommand {
           static let openExample: [String]
           static func canPerform(_ path: [String]) -> Bool
           @discardableResult static func perform(_ path: [String]) -> Bool
       }
   ```

5. **Gate impact** — none. No new `.keyboardShortcut` is registered (see the note in the
   W1 report: the button deliberately carries no key equivalent, so it cannot compete with
   the File menu's ⇧⌘O or hide a collision from `QNET_MENU_AUDIT=1`).

6. **Verification** — launch, empty canvas: the hint shows a live "Open an Example…"
   button and clicking it opens the example picker. `QNET_MENU_AUDIT=1 swift run Qnet`
   still reports no collision.

7. **Priority** — P1.

---

## W1-INT-3 — changelog bullets for the four shipped tasks

1. **ID** — `W1-INT-3`. Completes the round's exit-gate requirement that shipped work is
   described in the in-development changelog entry. Shippable without it in the sense that
   the code runs; not shippable in the sense that the release notes would be wrong.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (W6), the topmost entry,
   line 43, quoted verbatim:
   ```swift
               timestamp: nil,  // uses current AppVersion.buildTimestamp
               notes: [
   ```

3. **Insert / replace** — add these two bullets to that entry's `notes` array (position is
   the integrator's call; they are self-contained strings):

   ```swift
                   "The canvas draws links the way every diagram editor does: with the Link tool, press on a node and drag to another one — a dashed line in the chain's class colour follows the pointer, and over a candidate it becomes the exact arrow the release would create. The two-click flow shows the same preview between its clicks, and both run one implementation, so class selection, the refusal to repeat a pair and chain continuation behave identically whichever way the link is drawn.",
                   "A double-click on empty canvas hands the canvas to the hand — the pointer becomes an open hand and dragging pans — and the next single click gives the previous tool back; H, the Tools palette and the Space bar are unaffected. With a node tool active, a fast double-click now places exactly one node instead of stacking a second, invisible one on the same grid point. The empty canvas itself gained a working \"Open an Example…\" button and now states the rule a first network breaks: a station is served through exactly one buffer. The pane corner-resize grips follow the Results pane: each T-junction sits on the divider that actually crosses there, and dragging one moves only the two dividers that meet at it.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — none. `Changelog.swift` is prose; `design_lint.sh` reads it for menu
   arrows (these bullets use no menu path), bare ⌘-digits (none) and TeX braces (none).
   The escaped `\"Open an Example…\"` quotes are required by the Swift string literal.

6. **Verification** — `swift build`, then Help ▸ Release Notes shows the two bullets in
   the top (undated) entry.

7. **Priority** — P1.

---

## Notes for the integrator (no action required)

- `CanvasEmptyHint` already takes `onStartTemplate: (() -> Void)?`, defaulting to nil and
  hidden while nil. When W2's archetype gallery exists, the only edit needed is in
  `NetworkCanvasView.swift` (W1-owned) — no change to `CanvasEmptyHint` itself.
- W1-03 deliberately did **not** register the Results pane's inner split with
  `SplitRegistry`; `CornerResizeOverlay` derives the bottom row's junction as the outer
  split's last divider, so it needed no `ContentView.swift` change and none is requested.
