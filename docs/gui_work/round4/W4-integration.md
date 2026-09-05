# W4 — round 4 integration requests

Workstream: **W4 — Movable windows, dialogs, settings**.
Assigned issues this round: **R8** (node / link parameter editors still pinned sheets) and
**R9** (Settings window cannot be resized).

Both are landed in W4-owned files. Two requests follow; the second is the one that matters.

---

## W4-INT-1 — none required for R8 (recorded for the integrator)

**ID** — `W4-INT-1`. Completes **R8**. R8 is shippable without any action here.

**Target file and anchor** — `Sources/Qnet/ContentView.swift` (W3-owned), the section
`// MARK: - The two parameter editors, as movable panels`, anchor line quoted from today's
source:

```swift
    private func syncParameterPanels() {
        NodeParameterEditorPanel.sync(editor: editor,
                                      targetID: editor.parameterEditorTarget?.id)
```

**Insert / replace** — nothing. W3 has **already** written this call site against the presenters
W4 published this round, and the two sides agree. This section exists only so the integrator does
not go looking for a missing handoff: the ContentView half of R8 is done and needs no patch.

**New symbols it depends on** — all in W4-owned files, all present:

| symbol | file | declaration |
| --- | --- | --- |
| `NodeParameterEditorPanel` | `Sources/Qnet/NodeParameterEditorSheet.swift` | `@MainActor enum NodeParameterEditorPanel` with `static let panelID = "node-parameters"` and `static func sync(editor: NetworkEditorModel, targetID: UUID?)` |
| `LinkParameterEditorPanel` | `Sources/Qnet/LinkParameterEditorSheet.swift` | `@MainActor enum LinkParameterEditorPanel` with `static let panelID = "link-parameters"` and `static func sync(editor: NetworkEditorModel, targetID: UUID?)` |
| `NodeParameterEditorPanelBody` / `LinkParameterEditorPanelBody` | same two files | the panel roots; they observe the editor so a retarget is followed instead of a stale id being edited |
| `NodeParameterEditorSheet.size(for:in:)` / `.idealHeight(for:in:)` | `Sources/Qnet/NodeParameterEditorSheet.swift` | the band rule, published as `static` so the window and the form cannot drift apart — this is what W3-INT-1 asked for, and it is why `ContentView.nodeParameterPanelSize` could be deleted |
| `DSPanelCloseGuard` | `Sources/Qnet/DSPanelWindow.swift` | `@MainActor final class` with `var allowsClose: (() -> Bool)?`; `DSPanelWindow.present(closeGuard:)` installs it as the window's delegate |
| `DSPanelWindow.reband(id:to:)` / `.bringForward(id:)` | `Sources/Qnet/DSPanelWindow.swift` | move an OPEN panel onto a new `DSSheetSize` band, and raise one without rebuilding its root |

**Two changes to shared panel infrastructure that every other panel inherits** (both in
`Sources/Qnet/DSPanelWindow.swift` / `Sources/Qnet/WindowSupport.swift`, both W4-owned, both
forced by R8 and confirmed live):

1. `DSPanelWindow.close(id:)` now calls `window.close()`, not `window.performClose(nil)`.
   **A window with a sheet attached silently ignores `performClose`**, and the moment
   `close(id:)` is most often reached is exactly such a moment: the node editor's
   "Save changes before closing?" prompt is a SwiftUI `confirmationDialog`, i.e. an alert sheet
   on the panel window, and answering it clears the document target, which brings us here while
   that sheet is still dismissing. Observed before the change: the registry entry was dropped
   and `modalPanelPresented` cleared (the Network menu re-enabled), while the panel stayed on
   screen with its stale draft — an orphaned window the app no longer knew about.
2. A `.documentModal` panel's parent now comes from `MainWindowRegistry.documentWindow()`
   instead of `NSApp.keyWindow ?? NSApp.mainWindow` — the improvement recorded in
   `IMPROVEMENTS.json` ("a document-modal panel adopts whatever window happens to be key").
   Only a registered canvas window is ever a parent; `nil` (no suitable parent) leaves the panel
   unparented, which is the right failure.

**Gate impact** — none. No `gui_runtime_contracts.sh` string, no new `.keyboardShortcut`,
no `DSEmptyState` title, `Divider()`, menu-path arrow or bare ⌘-digit. `design_lint.sh` passes.

**Verification** — `swift build`; then double-click a station on the canvas: a **Node Parameters**
window with a title bar appears, can be dragged aside so the station stays visible, and resizes
inside its band. Double-click a second station while it is open: the same window retargets (and
asks to save first if the draft is dirty) instead of opening a second one. Type into a field and
press the window's close button: the Save / Don't Save / Cancel prompt appears rather than the
draft being lost.

**Priority** — P1 (nothing to apply).

---

## W4-INT-2 — R9: the Settings scene's `.frame(…)` change is NOT the fix; do not "simplify" it away

**ID** — `W4-INT-2`. Completes **R9**. R9 is shipped without it; this is a warning, not a patch.

**Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift` (W6-owned), the `Settings` scene:

```swift
        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }
        // SettingsView declares a minWidth/minHeight and an ideal size
        // (DS.Layout.Window.settings*); without this the scene's
        // resizability is whatever SwiftUI infers, and the window can be
        // dragged below the size its own split view needs.
        .windowResizability(.contentMinSize)
```

**Insert / replace** — **no change**. `.windowResizability(.contentMinSize)` must STAY exactly as
it is. It is load-bearing for the fix that landed: it is what leaves the Settings window's
`contentMaxSize` unbounded, which is what makes forcing the resize control safe. Replacing it with
`.contentSize`, or deleting it, re-pins the window.

**Why this is here.** R9's proposed fix — adding `maxWidth: .infinity, maxHeight: .infinity` to
`SettingsView`'s `.frame(…)` — does **not**, on its own, make the window resizable. Measured on
this OS with a minimal reproduction (a `Settings` scene wrapping a `NavigationSplitView` with the
same `.frame(minWidth:idealWidth:minHeight:idealHeight:)` and the same
`.windowResizability(.contentMinSize)`):

```
WITH_MAX=0  ->  title=Settings resizable=false min=(760, 608) max=(1.797e308, 1.797e308)
WITH_MAX=1  ->  title=Settings resizable=false min=(760, 608) max=(1.797e308, 1.797e308)
```

`contentMaxSize` is already infinite in BOTH cases, and the style mask lacks `.resizable` in both.
SwiftUI simply does not put `.resizable` in a `Settings` scene window's mask here, and nothing
declared in Swift moves it. So W4 landed two changes together, both in W4-owned files:

* `Sources/Qnet/SettingsComponents.swift` — `SettingsWindowTagger.makeResizable(_:)` inserts
  `.resizable` into the window's style mask on the one hook this app has into that window
  (`restoreFrameOnce`, which every attach path already calls). Idempotent, and safe on every ⌘,
  rebuild.
* `Sources/Qnet/SettingsView.swift` — the `maxWidth: .infinity, maxHeight: .infinity` on the
  existing `.frame(…)`. On its own it changes nothing, but once the window CAN grow it is what
  lets the panes grow into the extra room instead of leaving it blank.

Neither is a substitute for the other, and neither is a substitute for `.contentMinSize`.

**New symbols it depends on** — `SettingsWindowTagger.makeResizable(_:)`,
`Sources/Qnet/SettingsComponents.swift`, `@MainActor private static func makeResizable(_ window: NSWindow)`.

**Gate impact** — none. No contract string, no shortcut, no lint-inspected construct.
`design_lint.sh` passes.

**Verification** — run the app, ⌘,, and drag the window's bottom-right corner: it resizes. Measured
live with an `AXUIElementIsAttributeSettable` probe against the running process:

```
before:  title=Discrete-Event Simulation  sizeSettable=false  (zoom button enabled=false)
after:   title=Discrete-Event Simulation  sizeSettable=true   size=(900, 608)
         -> set to (1180, 840) -> size=(1180, 829), zoom button enabled=true
close it, then:  defaults read Qnet WindowFrame.QnetSettingsWindow
                 -> {{120, 53}, {1180, 829}}
```

At 1180 pt wide the sidebar still stops at `settingsSidebarMaxWidth` and the Discrete-Event
Simulation pane shows the whole Run Length section, trailing paragraph included — the exact
clipping R9 reported.

**Priority** — P0 as a *warning*: if `.windowResizability(.contentMinSize)` is removed from the
Settings scene while tidying, R9 regresses and the new resize control starts fighting a finite
`contentMaxSize`.
