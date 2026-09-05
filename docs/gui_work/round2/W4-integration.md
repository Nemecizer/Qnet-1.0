# W4 — integration requests, round 2

Workstream **W4 — Movable windows, dialogs, settings**. Every request below is a patch expressed in
prose against a file W4 does not own. Nothing here has been applied.

Round 1's six requests (`docs/gui_work/round1/W4-integration.md`) were **all applied** — verified
this round: `grep -rn setFrameAutosaveName Sources/Qnet` returns only a comment, seven windows carry
`frameKey:`, `QnetCommands.sheetPresented` reads `menuContext.modalPanelPresented`, the Settings
scene carries `.windowResizability(.contentMinSize)`, and the three dead `dialog*` tokens are gone.
The **round-2 conversion recipes for the five `QnetGUIApp`-presented forms** published at the end of
that document are still unapplied and still correct; this document does not repeat them.

**New symbols W4 landed this round** (confirm they exist before applying anything below):

| Symbol | File | Declaration |
| --- | --- | --- |
| `ArchetypeGalleryPanel` | `Sources/Qnet/ArchetypeGalleryPanel.swift` (new, W4-owned) | `@MainActor enum` with `panelID`, `windowTitle`, `isOpen`, `close()`, `present(canvasNodeCount:canvasSourceCount:onInsert:onClose:)` and `sync(presented:canvasNodeCount:canvasSourceCount:onInsert:onDismiss:)` |
| `SettingsWindowTagger.settingsFrameKey` | `Sources/Qnet/SettingsComponents.swift` | `static let settingsFrameKey = "QnetSettingsWindow"` — the one spelling of the Settings frame key, now shared by the early restore and by `WindowFrameAutosave` |

---

## W4-INT-R2-1 — The archetype gallery becomes a movable panel

1. **ID** — `W4-INT-R2-1`, completes the round-2 half of **W4-01/W4-02** (the critics' "ask 6 went
   backwards by one"). It is **not** shippable another way: the presentation lives in
   `QnetGUIApp.swift`, which W4 does not own. `ArchetypeGalleryPanel.swift` compiles and is
   reviewed, but it has **no caller until this patch lands** — treat it as dead code until then.
2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, the scene body's modifier chain.
   Anchor, verbatim at line 754 at the time of writing:
   ```swift
                .sheet(isPresented: $showArchetypeSheet) {
   ```
   The comment block immediately above it (lines 747–753, "Archetype gallery — builds one of the
   five starting networks …") is kept; only the modifier below it changes.
3. **Insert / replace** — before (lines 754–770 at the time of writing):
   ```swift
                .sheet(isPresented: $showArchetypeSheet) {
                    ArchetypeGallerySheet(
                        canvasNodeCount: activeEditor.nodes.count,
                        canvasSourceCount: activeEditor.nodes.filter { $0.kind == .source }.count,
                        onCancel: { showArchetypeSheet = false },
                        onInsert: { archetype, parameters in
                            showArchetypeSheet = false
                            let built = NetworkArchetypeBuilder.build(archetype, parameters)
                            activeEditor.insertSubnetwork(
                                nodes: built.nodes,
                                links: built.links,
                                infiniteBuffers: built.infiniteBuffers,
                                at: NetworkArchetypeBuilder.canvasOrigin,
                                actionName: "Insert " + NetworkArchetypeBuilder.blueprint(for: archetype).title,
                                detail: NetworkArchetypeBuilder.summary(archetype, parameters)
                            )
                        }
                    )
                }
   ```
   after:
   ```swift
                // …and it is a movable PANEL, not a sheet: the form's own
                // footer promises the archetype lands clear to the right of
                // what is already on the canvas, which is a promise the user
                // cannot check while a sheet covers the canvas.
                // `showArchetypeSheet` stays the single switch — the flag is
                // still the state, the panel is only the presentation — so
                // `insertArchetype()`, `appSheetPresented` and both menu
                // items are unchanged.
                .onChange(of: showArchetypeSheet) { _, presented in
                    ArchetypeGalleryPanel.sync(
                        presented: presented,
                        canvasNodeCount: activeEditor.nodes.count,
                        canvasSourceCount: activeEditor.nodes.filter { $0.kind == .source }.count,
                        onInsert: { archetype, parameters in
                            let built = NetworkArchetypeBuilder.build(archetype, parameters)
                            activeEditor.insertSubnetwork(
                                nodes: built.nodes,
                                links: built.links,
                                infiniteBuffers: built.infiniteBuffers,
                                at: NetworkArchetypeBuilder.canvasOrigin,
                                actionName: "Insert " + NetworkArchetypeBuilder.blueprint(for: archetype).title,
                                detail: NetworkArchetypeBuilder.summary(archetype, parameters)
                            )
                        },
                        onDismiss: { showArchetypeSheet = false }
                    )
                }
   ```
   Four things about the shape, each learned from the two conversions W4 has now shipped
   (`CanvasExportOptionsPresenter`, and the station picture picker in `NodeInspectorSections`):
   * **`onDismiss:` is the one teardown path.** It runs however the panel goes away — Cancel,
     Insert, the title-bar button, ⌘W, Escape, Quit — so `showArchetypeSheet` is cleared exactly
     once. A stuck flag disables the canvas tool letters and ⌫ until relaunch, which is the bug the
     comment at `QnetGUIApp.presentRunParameters` records.
   * **The re-entrancy is safe.** `ref.close()` → `willClose` → `onDismiss` →
     `showArchetypeSheet = false` → this `.onChange` fires again with `presented == false` →
     `ArchetypeGalleryPanel.close()`, which is a no-op because the registry entry is already gone.
   * **`onCancel` disappears from the call site** — `ArchetypeGalleryPanel` wires the form's
     `onCancel` to `ref.close()`, which routes through `onDismiss` like every other close.
   * **`activeEditor` is read when the panel opens, not continuously.** That matches the sheet it
     replaces (a `.sheet` closure also captured the counts at presentation time), and the two counts
     only feed the form's "what this will do to your network" line.
4. **New symbols it depends on** — `ArchetypeGalleryPanel` (`Sources/Qnet/ArchetypeGalleryPanel.swift`,
   see the table above), which in turn uses `DSPanelWindow.present` (`Sources/Qnet/DSPanelWindow.swift`,
   landed round 1). `ArchetypeGallerySheet`, `NetworkArchetype`, `ArchetypeParameters` and
   `NetworkArchetypeBuilder` are unchanged.
5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` greps `QnetGUIApp.swift` for the awk
   formatters, the EXIT/INT/TERM trap pattern, the count of exactly 8 `commandWithCleanup` Python
   runners and `${PIPESTATUS[0]}`; none of those strings is inside this modifier and no run action's
   shell command changes. No `.keyboardShortcut` is added or moved, so `QNET_MENU_AUDIT=1` re-clears
   unchanged. No `DSEmptyState` title, `Divider()`, menu-path arrow or ⌘-digit is introduced, so
   `validation/design_lint.sh` is unaffected. **Do not touch `appSheetPresented`
   (`QnetGUIApp.swift:1639`)** — it must keep listing `showArchetypeSheet`: converting a sheet into a
   panel does not change whether a dialog is up.
6. **Verification** —
   ```sh
   grep -c '\.sheet(' Sources/Qnet/QnetGUIApp.swift   # 7 today → 6
   swift build
   validation/gui_runtime_contracts.sh
   ```
   Then: File ▸ New from Template… (⌥⌘N). Drag the window by its title bar to one side — the canvas
   is visible and scrollable behind it. Resize it: it stops at the `.wide` band's limits. Press `S`
   on the canvas: the tool must **not** change (the panel is `.documentModal`, and the flag is still
   set). Press Insert: the panel closes first, then the archetype lands to the right of the existing
   network as ONE undo step. Reopen it: it comes back where it was dragged, and does so again after
   quit + relaunch.
7. **Priority** — **P0**.

---

## W4-INT-R2-2 — One word for the thing the gallery inserts

1. **ID** — `W4-INT-R2-2`, follows **W4-INT-R2-1**. That request **is** shippable without this one;
   this settles the naming the critics flagged: File ▸ **New from Template…** and Network ▸ **Insert
   Archetype…** open one dialog headed **Insert Archetype**, so one of the two menu items leads to a
   dialog named after neither, and the window title bar the panel adds makes the mismatch louder.
2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift` (owned by W5), the File menu.
   Anchor, verbatim at lines 252–255 at the time of writing:
   ```swift
            Button("New from Template…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sheetPresented)
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```
   Second anchor, `Sources/Qnet/QnetCommands.swift:88`:
   ```swift
   ///   File     ⌘N New · ⌘O Open · ⇧⌘O Open Example · ⌥⌘N New from Template
   ```
3. **Insert / replace** — **recommended option (a): make everything say "archetype".** The word is
   already what the code, the help text and the changelog use, and the dialog is already headed with
   it, so this is one string plus its documentation line:
   ```swift
            Button("New from Archetype…") { actions.insertArchetype() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(sheetPresented)
                .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```
   ```swift
   ///   File     ⌘N New · ⌘O Open · ⇧⌘O Open Example · ⌥⌘N New from Archetype
   ```
   Then both menu items and the dialog agree, and nothing else changes: `ArchetypeGalleryPanel.windowTitle`
   already equals the form's `DSSheetHeader` title verbatim, and both stay "Insert Archetype".

   **Option (b): make everything say "template"** — friendlier to a first-time user, but four files
   move together and they must move in one patch or the vocabulary splits:
   `QnetCommands.swift:778` `Button("Insert Archetype…")` → `Button("Insert Template…")`;
   `ArchetypeGallerySheet.swift:116` `"Insert Archetype"` → `"Insert Template"` (W2-owned);
   `ArchetypeGalleryPanel.swift`'s `windowTitle` → `"Insert Template"` (W4-owned, and its doc
   comment already says to change the two together); and the `Changelog.swift:45` bullet (W6-owned),
   which names "Network ▸ Insert Archetype…" in prose.
   Do **not** apply half of either option: a dialog whose title bar, header and menu item disagree is
   worse than today.
4. **New symbols it depends on** — none. `ArchetypeGalleryPanel.windowTitle`
   (`Sources/Qnet/ArchetypeGalleryPanel.swift`) is only referenced by option (b).
5. **Gate impact** — `validation/design_lint.sh` checks menu-path arrows (`▸`) and bare ⌘-digit
   shortcuts; neither option adds either, and the ⌥⌘N key equivalent is unchanged, so
   `QNET_MENU_AUDIT=1` re-clears unchanged. `gui_runtime_contracts.sh` does not grep
   `QnetCommands.swift`. Option (b) touches a `Changelog.swift` bullet, which no gate inspects.
6. **Verification** —
   ```sh
   grep -rn 'Insert Archetype\|New from Template\|Insert Template\|New from Archetype' Sources/Qnet
   ```
   must show one vocabulary, not two. Then open the dialog from both menu items: the title bar, the
   header and the menu item that opened it all use the same noun.
7. **Priority** — **P1**.

---

## Note for the integrator: what is now proven, and what still is not

Round 1's critics flagged `DSPanelModality.documentModal`, `.appModal`, `syncMenuFlag()`'s true
branch, `MenuContext.modalPanelPresented`'s consumer and the whole `\.qnetDismiss` bridge as compiled
but never run. This round exercises all of them, in `Sources/Qnet/NodeInspectorSections.swift` —
the station picture picker is now a panel, `.documentModal` from the docked inspector pane and
`.appModal` from the ⌘I sheet host, and `PicturePickerSheet` dismisses itself through
`\.qnetDismiss`. Two things remain unproven and want a reviewer's eye rather than a rubber stamp:

* **`addChildWindow` under a SwiftUI sheet.** The picker deliberately does *not* use
  `.documentModal` when its opener is the ⌘I sheet, because AppKit orders a sheet's window out
  without closing it, and a child of that window would be dragged out of sight while still
  registered — the stuck-flag bug. If a future conversion presents a `.documentModal` panel from
  inside a sheet, that reasoning has to be re-checked.
* **`remembersFrame: false`.** Every panel to date takes the `true` default; the false branch has
  still never run.

One further caveat on `\.qnetDismiss`: the bridge that substitutes SwiftUI's `dismiss` is installed
by `DSSheet`, i.e. *below* the form struct that reads the environment value. A top-level form that
reads `@Environment(\.qnetDismiss)` on itself therefore sees the claimed action in a panel (the host
installs it above the form) but the inert default in a `.sheet`. `PicturePickerSheet` is panel-only,
so this is correct today; any form converted later that reads `\.qnetDismiss` at its own top level
and is *still* presented as a sheet somewhere must have `.qnetDismissBridge()` applied at that sheet
call site.
