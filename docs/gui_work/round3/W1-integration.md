# W1 — Canvas gestures and rendering · round 3 integration requests

Round 3 closed both polish findings against W1-owned files (the rubber band now previews a
self-loop; the empty canvas has a real primary action and two tooltips that say something) and
finished the last deferred backlog item, **W1-05 part (2)** — Escape cancels an in-flight drag.

Files W1 changed: `NetworkCanvasView.swift`, `NetworkCanvasLayers.swift`,
`NetworkCanvasOverlays.swift`, `NetworkCanvasScrollContainer.swift` (one comment),
`KeyboardShortcutReference.swift`.

Nothing shipped this round depends on a foreign edit. All three requests below are P1.

---

## W1-INT-6 — repair the round-2 changelog bullet that was spliced mid-sentence

1. **ID** — `W1-INT-6`. Completes nothing in code; it repairs a release note that no longer
   parses as English. Shippable without it only in the sense that the app runs.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (W6), the topmost (`timestamp:
   nil`) entry, line 56, quoted verbatim from today's source — the fragment that matters is in
   the middle of the bullet:

   ```swift
   The empty canvas itself gained a working \"Open an Example…\" button — the fifty literature networks now ship inside Qnet.app and are found there first, so the button opens on them rather than on wherever you were last, whatever directory the app was launched from and now states the rule a first network breaks: a station is served through exactly one buffer.
   ```

   Two bullets were merged here: W1's round-1 sentence ("gained a working button … and now
   states the rule a first network breaks") and W6's file-resolution sentence ("the fifty
   literature networks now ship inside Qnet.app … whatever directory the app was launched
   from"). The second was inserted inside the first, leaving "…on wherever you were last,
   whatever directory the app was launched from and now states the rule…", which reads as a
   sentence fragment glued to a clause that has lost its subject.

3. **Insert / replace** — replace that fragment with these two sentences, which keep every
   claim both bullets made and add none:

   ```swift
   The empty canvas itself gained a working \"Open an Example…\" button, and now states the rule a first network breaks: a station is served through exactly one buffer. The fifty literature networks ship inside Qnet.app and are found there first, so that button opens on them rather than on wherever you happened to be last, whatever directory the app was launched from.
   ```

   The rest of the bullet (the double-click / sticky-pan opening and the corner-grip closing) is
   unchanged.

4. **New symbols it depends on** — none.

5. **Gate impact** — none. Prose only: no menu path, no ⌘-digit, no TeX braces. The escaped
   `\"…\"` quotes are required by the Swift string literal.

6. **Verification** — `swift build`, then Help ▸ Release Notes: the bullet reads as two
   sentences, each with a subject.

7. **Priority** — P1.

---

## W1-INT-7 — changelog bullets for the round-3 canvas work

1. **ID** — `W1-INT-7`. Completes the round's exit-gate requirement that shipped work is
   described in the in-development changelog entry.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (W6), the topmost entry, quoted
   verbatim from today's source:
   ```swift
               timestamp: nil,  // uses current AppVersion.buildTimestamp
               notes: [
   ```

3. **Insert / replace** — add these two bullets to that entry's `notes` array (position is the
   integrator's call; they are self-contained strings). They describe round-3 work only.

   ```swift
                   "The self-loop is now as visible as every other link while it is being drawn. Dragging out of a station and back onto it — or, in the two-click flow, moving off the pending start and back — shows the loop arc the release would leave behind, nested outside any loop the station already carries, instead of a dashed line running back into the node it came from. On a source, buffer or sink, which cannot have one, the band promises nothing and the click still says why.",
                   "Escape puts a drag back. Pressing it while nodes, a link or a link being drawn is in flight returns everything to where the drag started, drops the alignment guides, and leaves no undo step behind — the group is closed, not committed — and the release that follows commits nothing and is not read as a click either. With nothing being dragged, Escape still means Deselect All. An ⌥-drag is the one exception: it has already made the copies it is carrying, so Escape keeps its other meaning there rather than stacking an invisible node on every original.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — none. `design_lint.sh` reads `Changelog.swift` for menu-path arrows (none
   here), bare ⌘-digits (none) and TeX braces (none).

6. **Verification** — `swift build`, then Help ▸ Release Notes shows the two bullets in the top
   (undated) entry.

7. **Priority** — P1.

---

## W1-INT-8 — a way to discard an open mutation, so an ⌥-drag can be cancelled too

1. **ID** — `W1-INT-8`. Completes the remaining sliver of **W1-05** part (2). W1-05 shipped
   without it: Escape cancels an ordinary node drag, a group drag, a link drag and a link being
   drawn. The one drag it does not cancel is the duplicating ⌥-drag, and that is a *deliberate*
   refusal, not a bug — see the reason in `cancelDragInFlight()`'s doc comment. This request is
   what would let a later round lift the exception. **Do not apply it in isolation**: it is only
   useful together with the W1 follow-up described in point 3, which is a change to a W1-owned
   file and is not part of this round.

2. **Target file and anchor** — `Sources/Qnet/NetworkEditorModel.swift` (W2), immediately after
   `endMutation()`, quoted verbatim from today's source (line 2801):

   ```swift
       func endMutation() {
           guard let before = pendingMutationSnapshot,
                 let name = pendingMutationName else { return }
   ```

3. **Insert / replace** — add this method after `endMutation()`:

   ```swift
       /// Abandons an open mutation group and puts the network back as it
       /// was when `beginMutation` took its snapshot — the cancel half of
       /// the pair, for a gesture the user aborts rather than completes
       /// (Escape during an ⌥-drag, which has already made the copies it is
       /// carrying).  Registers no undo entry, because nothing survives to
       /// be undone; the group is discarded, not committed.
       ///
       /// A no-op when no group is open, so a cancel path may call it
       /// unconditionally.  Returns true when a group was actually
       /// discarded.
       @discardableResult
       func cancelMutation() -> Bool {
           guard let before = pendingMutationSnapshot else { return false }
           pendingMutationSnapshot = nil
           pendingMutationName = nil
           pendingGroupTouchedParameters = false
           restore(from: before)
           return true
       }
   ```

   `restore(from:)` is `private` today and is called here from inside the same type, so no
   access-level change is needed. It already posts
   `.bnetNetworkParametersDidChange`, which is correct: the network really did change back.

   The W1 side, for whoever picks this up: in
   `NetworkCanvasView.swift`'s `cancelDragInFlight()`, replace the
   `guard !dragStartPositions.isEmpty, !dragDuplicated else { return false }` line with
   `guard !dragStartPositions.isEmpty else { return false }`, and take the
   `!dragDuplicated` term out of `dragIsCancellable`; then, when `dragDuplicated` is true,
   call `editor.cancelMutation()` in place of the restore-then-`endMutation()` pair. The
   `dragDuplicated` @State already exists and is already maintained.

4. **New symbols it depends on** — none of W1's. It depends on the model's existing
   `pendingMutationSnapshot`, `pendingMutationName`, `pendingGroupTouchedParameters` and
   `restore(from:)`, all of which are in `NetworkEditorModel.swift` today.

5. **Gate impact** — none. No string `gui_runtime_contracts.sh` greps, no `.keyboardShortcut`,
   no `DSEmptyState` title, no `Divider()`, no menu-path arrow.

6. **Verification** — ⌥-drag a group of nodes, press Escape before releasing: the copies are
   gone, the originals have not moved, and the Edit menu offers no new undo step (it still
   offers whatever it offered before the drag).

7. **Priority** — P1 as a pair with the W1 follow-up; P2 on its own, since the model gains an
   unused method until W1's side lands.

---

## Notes for the integrator (no action required)

- The empty canvas's two offers are drawn by `CanvasEmptyHint` itself now, not by
  `DSEmptyState`'s action row: two buttons of equal weight are two buttons with no primary, and
  `DSEmptyState` (W4-owned) renders its single action as a plain `Button` with a `.dsTooltip`
  that can only repeat the title it was given. So "Start from an Archetype…" takes
  `.buttonStyle(.borderedProminent)` — the same system style `AIPaneView` and `MethodChooserView`
  already use — "Open an Example…" stays plain beneath it, and each carries the sentence its own
  menu item carries. If W4 ever gives `DSEmptyState` a prominent-action option plus a per-action
  help string, this is the call site that should move back into it.
- Both empty-state buttons still carry no key equivalent, so `QNET_MENU_AUDIT=1` has nothing new
  to clear; the round-2 constraint recorded as `W1-INT-4` (the two `MenuBarCommand` menu-path
  constants in W1-owned `MenuKeyAliases.swift` must track the File-menu titles) still stands
  unchanged.
- The Escape monitor is a local `NSEvent` keyDown monitor installed by `CanvasContentView` only
  for the length of a cancellable drag, and it swallows the key **only** when a drag was really
  cancelled. Escape's one documented meaning (`editor.deselectAll()`, shared with ⌥⌘A and the
  context menu) is untouched on every other press; `NetworkCanvasScrollContainer`'s `case 53`
  carries a comment saying so.
