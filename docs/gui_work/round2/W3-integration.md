# W3 — integration requests, round 2

Workstream: **W3 — Window layout, pane prominence and focus routing.**
Three requests, all in files W3 does not own. Two of them are round-1 requests that were reported
back by a round-2 critic as unapplied or as newly discovered in a neighbour's file; they are
restated here in full so the integrator does not have to go back a round.

New symbols this round, all in files W3 owns, so an integrator can confirm they exist before
applying anything:

| Symbol | File | Declaration |
| --- | --- | --- |
| `WorkspaceLayout` | `Sources/Qnet/ContentView.swift` | `@MainActor enum WorkspaceLayout` — `setOuterRowHeight(_:fraction:)`, `reapplySavedSizes()`, `beginPresetTransition()`, `registerRestorer(key:_:)`, `savesSuppressedUntil` |
| `AppSettings.didRepairResultsPane` | `Sources/Qnet/AppSettings.swift` | `@Published var didRepairResultsPane: Bool` (true for one launch after the stored-state repair) |
| `AppSettings.init()` | `Sources/Qnet/AppSettings.swift` | runs `repairAutoRevealedResultsPane()` once per install |
| `WorkspacePresetItems.shellRowFraction` / `.resultsRowFraction` | `Sources/Qnet/WorkspaceCommands.swift` | `static let … = 0.45` / `0.5` |
| `WorkspaceCommands.applyWorkspacePreset(…, outerRowFractions:)` | `Sources/Qnet/WorkspaceCommands.swift` | new trailing parameter, defaulted to `[:]` |

`WorkspaceCommands.maximizeTarget(_:)` changed signature this round: it returns a
**non-optional** `FocusRouter.Pane` (it falls back to `.canvas` when nothing has keyboard focus).
Both call sites are W3-owned and already updated; no other file calls it
(`grep -rn 'maximizeTarget' Sources/Qnet` returns only `WorkspaceCommands.swift`).

W3 needs **no new `DesignSystem.swift` token** this round either.

---

## W3-INT-8 — opt the three remaining `FocusRouter` registrants into owner tokens

*(This is round 1's W3-INT-7, restated verbatim in substance. A round-2 critic verified with
`grep -rn 'owner: handlerOwner.id' Sources/Qnet` that only `InspectorPaneView.swift` — the one
registrant W3 owns — passes a token. The three panes users toggle most still do not, so the
toggle-off/toggle-on race the mechanism was built for is live for exactly the panes that matter.)*

1. **ID** — `W3-INT-8`. Completes **W3-03(b)** for the panes W3 does not own. **W3-03 ships
   without it**: `owner:` defaults to `nil`, so a registrant that has not opted in behaves exactly
   as it did before. What is missing is the protection itself, for `.status`, `.ai` and
   `.results`.

2. **Target files and anchors** — three registrations, each an `onAppear` / `onDisappear` pair.
   Anchors quoted from today's source:

   * `Sources/Qnet/StatusLog.swift`, line 304:
     ```swift
             FocusRouter.shared.setFocusHandler(.status) { focusRequest += 1 }
     ```
     and its clearing counterpart in the same view's `onDisappear`,
     `FocusRouter.shared.setFocusHandler(.status, nil)`, plus every other
     `FocusRouter.shared.set…Handler(.status, …)` pair in that file (the zoom pair in the
     A+ / A− wiring).
   * `Sources/Qnet/AIPaneView.swift`, the block beginning near line 738 — its
     `setFocusHandler(.ai, …)`, `setZoomHandler(.ai, …)`, `setFindHandler(.ai, …)` and
     `setFindStepHandler(.ai, …)` calls and their nil-ing counterparts.
   * `Sources/Qnet/ResultsWorkspace.swift`, the block beginning near line 1016 — its
     `setFocusHandler(.results, …)` and `setFindHandler(.results, …)` calls and their nil-ing
     counterparts.

3. **Insert / replace** — in each of the three views, add one stored property:

   ```swift
       /// This instance's identity for its `FocusRouter` registrations, so a
       /// late `onDisappear` cannot clear a newer instance's handler.
       @State private var handlerOwner = PaneHandlerOwner()
   ```

   and pass `owner: handlerOwner.id` to **both** halves of every pair, e.g.

   * before → `FocusRouter.shared.setFocusHandler(.status) { focusRequest += 1 }`
   * after  → `FocusRouter.shared.setFocusHandler(.status, owner: handlerOwner.id) { focusRequest += 1 }`
   * before → `FocusRouter.shared.setFocusHandler(.status, nil)`
   * after  → `FocusRouter.shared.setFocusHandler(.status, owner: handlerOwner.id, nil)`

   The `owner:` label sits **between** the pane and the handler in all four setters
   (`setFocusHandler`, `setZoomHandler`, `setFindHandler`, `setFindStepHandler`). Passing it on
   the install but not on the clear is worse than passing it on neither — the clear would then
   never match, and the handler would outlive the pane.

4. **New symbols it depends on** — `PaneHandlerOwner` (`Sources/Qnet/PaneChrome.swift:376`,
   `final class PaneHandlerOwner { init(); var id: ObjectIdentifier }`) and the `owner:` parameter
   on the four `FocusRouter.set…Handler` methods (`PaneChrome.swift:152`, `:162`, `:178`, `:191`).
   All landed in round 1 and unchanged in round 2.

5. **Gate impact** — none. No contract string, no shortcut, no `design_lint.sh` pattern.

6. **Verification** — toggle the pane off and on twice in quick succession (⌥⌘2 four times for
   Status), then press ⌘F and ⌥⌘=. Both must still act on that pane. Before the change the second
   toggle can leave both dead until the pane is toggled again.

7. **Priority** — P1.

---

## W3-INT-9 — the corner resize grips must survive a hidden Tools palette

1. **ID** — `W3-INT-9`. Not attached to a W3 task; it is a defect in a W1-owned file that a
   round-2 critic filed against W3 because the pane visibility that triggers it is W3's. Nothing
   W3 shipped is broken without it; what is broken is the bottom row's corner grip whenever the
   Tools pane or the right column is hidden — which is one click in View ▸ Panes, and is the state
   the Shell and Canvas Only workspace presets deliberately produce.

2. **Target file and anchor** — `Sources/Qnet/CornerResizeOverlay.swift`,
   `CornerResizeOverlay.intersections`. Anchor, verbatim, lines 90–95:

   ```swift
       private var intersections: [CornerSpot] {
           guard let outer = registry.split("OuterVSplit"),
                 let top = registry.split("TopHSplit"),
                 outer.arrangedSubviews.count >= 2,
                 top.arrangedSubviews.count >= 3
           else { return [] }
   ```

3. **Insert / replace** — the single guard covers the whole function, including the bottom-row
   grip appended at lines 121–138, so hiding the palette (`ContentView.topPanes` drops to two
   entries) removes *every* grip in the window rather than the two that no longer exist.
   Replace lines 90–119 with:

   ```swift
       private var intersections: [CornerSpot] {
           guard let outer = registry.split("OuterVSplit"),
                 outer.arrangedSubviews.count >= 2
           else { return [] }

           var out: [CornerSpot] = []

           // The top row's own T-junctions exist only while the top split
           // really has three arranged subviews — palette | canvas | right
           // column. Hiding the Tools pane or the whole right column (one
           // click in View ▸ Panes, and what the Shell and Canvas Only
           // presets do) leaves two, and there is no interior T-junction to
           // draw. That must not take the bottom row's grip with it.
           if let top = registry.split("TopHSplit"), top.arrangedSubviews.count >= 3 {
               let topRowDividerY = outerDividerY(in: outer, at: 0)
               let topDivider0X = top.arrangedSubviews[0].frame.width
               let topDivider1X = topDivider0X
                   + top.dividerThickness
                   + top.arrangedSubviews[1].frame.width

               out.append(CornerSpot(
                   id: "top.palette.canvas",
                   center: CGPoint(x: topDivider0X, y: topRowDividerY),
                   hSplitName: "TopHSplit",
                   hSplitDividerIndex: 0,
                   outerDividerIndex: 0
               ))
               out.append(CornerSpot(
                   id: "top.canvas.status",
                   center: CGPoint(x: topDivider1X, y: topRowDividerY),
                   hSplitName: "TopHSplit",
                   hSplitDividerIndex: 1,
                   outerDividerIndex: 0
               ))
           }
   ```

   Everything from `if aiPaneVisible,` (line 121) to `return out` (line 140) stays exactly as it
   is: it already checks the two things it needs, `outer.arrangedSubviews.count >= 2` (now the
   only precondition of the function) and `bot.arrangedSubviews.count >= 2`.

4. **New symbols it depends on** — none. `outerDividerY(in:at:)` and `CornerSpot` are unchanged
   and in the same file.

5. **Gate impact** — none: no DS token, no frame literal (`cornerHitSize` is a file-scope
   constant that already exists), no contract string, no shortcut.

6. **Verification** — hide the Tools pane (⌥⌘1) with the Shell and AI panes both showing. The
   L-shaped grip at the junction of the Shell / AI divider and the row divider above it must still
   appear on hover and must still drag both dividers. Before the change it disappears. Then apply
   View ▸ Panes ▸ Workspace Presets ▸ Shell and confirm no grip is drawn (there is no interior
   junction left) without a crash or an out-of-range index.

7. **Priority** — P1.

---

## W3-INT-10 — changelog bullets for round 2

1. **ID** — `W3-INT-10`. Housekeeping for the round-2 fixes. Nothing is broken without it, except
   that one of them closes a pane the user has been looking at for months and the release notes
   are where that is explained.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost entry, the one with
   `timestamp: nil`. Add to its bullet list; do **not** create a new release entry, and do not
   touch `AppVersion.swift` (still 0.90.34). Round 1's W3-INT-6 bullets stay; these are additional.

3. **Insert / replace** — add these three bullets:

   ```swift
                "The Shell workspace preset now moves the divider it promises: the shell row takes 45 % of the window height, and Analyze Results gives the Results workspace half. A saved divider position used to be restored straight over both, so the preset appeared to do nothing.",
                "One-time repair for anyone carrying the old auto-reveal's state: an earlier version reopened the Results workspace on every solver run and left it open, which reduced the canvas and the Shell to what was left of the window. It is closed once, only when the Shell is showing (the run is visible there), and the status log says so. No run record is touched; View ▸ Panes ▸ Results (⌥⌘6) brings it back.",
                "Maximize Pane (⌃⌘↩) acts on the canvas when nothing else has keyboard focus, instead of being dimmed at launch, and the canvas status bar carries the same maximize / restore control every other pane header has — so a maximize remembered across a relaunch is visible on screen.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — `design_lint.sh` reads these strings: the menu paths use `▸` (required), and
   `⌥⌘6` / `⌃⌘↩` are modifier-plus-key, not a bare `⌘6`, so the stray-⌘-digit rule does not fire.
   The modifier orders ⌥⌘ and ⌃⌘ are the canonical ones. `%` is preceded by a normal space here
   deliberately: the narrow no-break space used in the tooltips is a code-side detail, and the
   changelog is plain prose.

6. **Verification** — `validation/design_lint.sh` passes; Help ▸ Release Notes shows the three
   bullets under the in-development entry.

7. **Priority** — P1.
