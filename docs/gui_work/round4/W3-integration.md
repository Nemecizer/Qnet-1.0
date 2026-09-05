# W3 — round 4 integration requests

Workstream: **W3 — Window layout and panes**.
Owned files touched this round: `Sources/Qnet/ContentView.swift`, `Sources/Qnet/AppSettings.swift`,
`Sources/Qnet/PaneDetachment.swift`, `Sources/Qnet/PaneChrome.swift`.

W3 had no assigned blocker this round. It shipped its half of **R8** (the node and link parameter
editors off `.sheet`) plus IMPROVEMENTS entries 3/16/17/20/30/32/35 that name W3.

---

## W3-INT-1 — R8: nothing to apply, but read this before you reconcile W4's half

**ID** — `W3-INT-1`. Completes: R8 (W3's half). The task is shippable as it stands; this section
exists so the integrator does not apply a *second* implementation on top of it.

**Target file and anchor** — `Sources/Qnet/ContentView.swift`, in `ContentView.body`, the modifier
chain that used to read (verbatim, from the round-3 source, line 490):

```swift
        .sheet(item: $editor.parameterEditorTarget, onDismiss: {
            editor.closeParameterEditor()
        }) { target in
            NodeParameterEditorSheet(nodeID: target.id)
                .environmentObject(editor)
        }
        .sheet(item: $editor.linkParameterEditorTarget, onDismiss: {
            editor.closeLinkParameterEditor()
        }) { target in
            LinkParameterEditorSheet(linkID: target.id)
                .environmentObject(editor)
        }
```

**Insert / replace** — already applied by W3. Those two `.sheet(item:)` presentations are gone and
the chain now reads:

```swift
        .onChange(of: editor.parameterEditorTarget?.id) { _, _ in
            syncParameterPanels()
        }
        .onChange(of: editor.linkParameterEditorTarget?.id) { _, _ in
            syncParameterPanels()
        }
        .onAppear { syncParameterPanels() }
        .onDisappear { closeParameterPanels() }
```

with two private helpers on `ContentView` (`syncParameterPanels()`, `closeParameterPanels()`) that
do nothing but forward to W4's presenters:

```swift
    private func syncParameterPanels() {
        NodeParameterEditorPanel.sync(editor: editor,
                                      targetID: editor.parameterEditorTarget?.id)
        LinkParameterEditorPanel.sync(editor: editor,
                                      targetID: editor.linkParameterEditorTarget?.id)
    }

    private func closeParameterPanels() {
        DSPanelWindow.close(id: NodeParameterEditorPanel.panelID)
        DSPanelWindow.close(id: LinkParameterEditorPanel.panelID)
    }
```

`.sheet(isPresented: $editor.showSRBMExportSheet)` is untouched, as R8 requires, and so is the
startup check in `QnetGUIApp.swift`.

**New symbols it depends on** — all four are W4's, and all four exist in the tree as this was
written:

| symbol | file | declaration |
| --- | --- | --- |
| `NodeParameterEditorPanel.sync(editor:targetID:)` | `Sources/Qnet/NodeParameterEditorSheet.swift:515` | `static func sync(editor: NetworkEditorModel, targetID: UUID?)` |
| `NodeParameterEditorPanel.panelID` | `Sources/Qnet/NodeParameterEditorSheet.swift:498` | `static let panelID = "node-parameters"` |
| `LinkParameterEditorPanel.sync(editor:targetID:)` | `Sources/Qnet/LinkParameterEditorSheet.swift:266` | `static func sync(editor: NetworkEditorModel, targetID: UUID?)` |
| `LinkParameterEditorPanel.panelID` | `Sources/Qnet/LinkParameterEditorSheet.swift:251` | `static let panelID = "link-parameters"` |

If W4 renames either presenter or changes `sync`'s signature, the ONLY edit needed in W3's files is
inside those two helper bodies — the watchers above stay as they are.

**Why `.onAppear` and `.onDisappear` are there** — a panel is an AppKit window, not part of this
view tree. `.onAppear` re-presents a panel for a target that is already set when the view is built
(a reopened scene); `.onDisappear` takes the windows down without clearing the targets, because
`DSPanelWindow.close(id:)` deliberately does not run the presenter's `onClose` and writing to the
document during teardown is what we do not want.

**Gate impact** — none. No string `validation/gui_runtime_contracts.sh` greps, no new
`.keyboardShortcut`, no `DSEmptyState` title, no `Divider()`, no menu-path arrow.
`DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` passes.

**Verification** — `grep -n '\.sheet(' Sources/Qnet/ContentView.swift` must return exactly one hit,
the SRBM export sheet. Then, in the running app, double-click a station: the editor must open as a
window titled **Node Parameters** listed in the Window menu, movable, with the canvas live behind
it. See "Honest note on verification" at the end of this document.

**Priority** — P0 (it is W3's half of a blocker).

---

## W3-INT-2 — `DS.Layout` token for a detached pane window's title separator (P1, cosmetic only)

**ID** — `W3-INT-2`. Completes: IMPROVEMENTS 16 and 17. Both are already shipped without it; this is
a tidiness request only, and the round can ship untouched if the integrator would rather not open
the frozen file.

**Target file and anchor** — `Sources/Qnet/PaneDetachment.swift`, `PaneWindowController.windowTitle`:

```swift
        return "\(document) — \(pane.displayName)"
```

**Insert / replace** — nothing is required. If the integrator wants the em-dash separator to live in
one place alongside the other window-title composition in the app, add it to `DesignSystem.swift`
(integrator-owned) as a `DS.Text`-style constant and have this line read it. W3 did NOT do this,
because `DesignSystem.swift` is frozen and one literal separator in one function is not worth a
token.

**New symbols it depends on** — none.

**Gate impact** — none.

**Verification** — none needed; behaviour is identical either way.

**Priority** — P1.

---

## Notes for the integrator on what W3 changed in its OWN files

Recorded here because these touch behaviour other workstreams reason about.

1. **`AppSettings.detachedPanes` is memoized** (IMPROVEMENTS 30). The getter caches the parsed
   `Set<FocusRouter.Pane>` against the raw string it came from, in a new private stored property
   `detachedPanesCache`. Keying on the string rather than invalidating in the setter is deliberate:
   a settings import, a reset or a `defaults write` changes the value without going through the
   setter, and a stale memo there would be a correctness bug rather than a performance one.
   No API changed.

2. **A detached pane's window is titled `<network> — <pane>`** (IMPROVEMENTS 16 and 17), through the
   new `PaneWindowController.windowTitle(_:networkTitle:)`. The title is refreshed in `reconcile`
   when the document name changes, and only when it actually differs. `FocusRouter.Pane.displayName`
   remains the single table the headers, toggles and tooltips read — the window title composes with
   it, it does not replace it. This is what removes the two-items-both-called-"Shell" collision in
   the Window menu, so `WorkspaceCommands`' `Menu("Shell")` actions submenu was left alone; if a
   later round would rather rename that submenu instead, the title composition can be dropped.

3. **`WindowFrameAutosave.savedFrame` clamps onto one screen** (IMPROVEMENTS 20) — the attached
   screen whose visible frame the saved rect overlaps most, falling back to `NSScreen.main` and then
   to the first screen. It no longer clamps into the union of every screen, which for two displays
   of different heights contains dead space belonging to neither. `AuxiliaryWindow.savedFrame`
   forwards to this, so every auxiliary and panel window inherits the fix.

4. **`FocusRouter.Pane.canBeDetached`'s comment now states the palette's own reason**
   (IMPROVEMENTS 3 and 32), including the mechanical one: `ToolPaletteView` builds its header with
   the no-trailing `DSSectionHeader` overload (`ToolPaletteView.swift:18`), so a detached palette
   window would carry none of the controls the other detached panes reattach themselves with.
   The behaviour is unchanged — 5 of 6 detachable, two stated exclusions.

---

## Honest note on verification

`swift build` (own scratch path, against a snapshot of the tree so five concurrent builds could not
corrupt each other) and `DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` both pass with every change
above.

**Verified in the running app (PID-targeted AX, not screenshots):**

* **R8, node editor.** With a station selected, Edit ▸ Edit Parameters… produced
  `[Node Parameters sheets=0 sub=AXStandardWindow @356,34 sz800x897]` beside the main window, which
  reported `sheets=0` — a real, standard, *movable* window, not a sheet. Setting its position to
  {620, 120} moved it, which a sheet cannot do. While it was up, Tools ▸ Station Tool and Edit ▸
  Delete were disabled, i.e. the `.documentModal` gate that keeps bare canvas tool letters dead
  under a form full of number fields still holds. Clicking its title-bar close button closed it and
  re-enabled both, so the target is cleared exactly once and the "a dialog is up" flag cannot stick.
  Re-invoking Edit Parameters… opened it again.
* **IMPROVEMENTS 16 and 17.** With the Shell torn out, the window list reads
  `[Untitled — Shell][Untitled – Unsaved network]` and the Window menu reads
  `… Focus Results, Shell, ──, Untitled — Shell, Untitled (Unsaved network)`. Before this round both
  the actions submenu and the pane window were called "Shell"; they are now distinct, and the title
  bar carries the document context the pane's own `DSSectionHeader` ("Shell ● ~/…/2_QNET") does not.

**Not verified in the running app:**

* **R8, link editor.** Selecting a link needs a click on a link curve on the canvas, and canvas
  clicks could not be aimed reliably (see below). It goes through the same two watchers and W4's
  mirror-image `LinkParameterEditorPanel`, and it compiles, but a human should double-click a link
  once before signing R8 off.
* **IMPROVEMENTS 20** (`savedFrame` clamping to the best-overlapping screen) — this machine has one
  display, so the two-display case cannot be exercised here at all.
* **IMPROVEMENTS 30** (the `detachedPanes` memo) — behaviour is unchanged by construction; only the
  cost differs.

**Why canvas clicks could not be aimed.** Five Qnet instances built by five workstreams were running
on the one display at once, all with windows at the same origin. `System Events` resolves
`process "Qnet"` to an arbitrary one of them (every query in this document was PID-targeted for that
reason), other agents' automation repeatedly raised, retargeted and closed windows in whichever app
was frontmost — this session's app had a canvas tab closed, an example file opened into it and its
Settings window raised, none of it by this session — and synthetic clicks aimed at this session's
window landed on another instance's window whenever theirs was on top. One screenshot taken early in
that period shows a node parameter editor as a pinned sheet; it was taken while `System Events` was
driving a different workstream's binary, and is not evidence about this change.
