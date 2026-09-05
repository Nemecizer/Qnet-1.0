# W4 — integration requests, round 1

Workstream **W4 — Movable windows, dialogs, settings**. Every request below is a patch expressed
in prose against a file W4 does not own. Nothing here has been applied.

**New symbols W4 landed this round** (referenced by several requests; confirm they exist first):

| Symbol | File | Declaration |
| --- | --- | --- |
| `DSPanelWindow` | `Sources/Qnet/DSPanelWindow.swift` (new) | `@MainActor enum DSPanelWindow` with `present(id:title:size:modality:escapeCloses:remembersFrame:onClose:root:) -> NSWindow`, `close(id:)`, `isOpen(id:) -> Bool`, `frameKey(for:) -> String` |
| `DSPanelModality` | `Sources/Qnet/DSPanelWindow.swift` | `enum DSPanelModality { case modeless, documentModal, appModal }` |
| `QnetDismissAction` / `EnvironmentValues.qnetDismiss` | `Sources/Qnet/DSPanelWindow.swift` | `struct QnetDismissAction` with `callAsFunction()`; `DSSheet` fills the environment slot from `\.dismiss` when no panel has claimed it |
| `AuxiliaryWindow.make(… escapeCloses:fullScreenAuxiliary:frameKey:onClose: …)` | `Sources/Qnet/WindowSupport.swift` | four **additive** parameters, all defaulted; the six pre-existing call sites compile unchanged |
| `AuxiliaryWindow.savedFrame(named:) -> NSRect?` | `Sources/Qnet/WindowSupport.swift` | reads `WindowFrame.<name>` and clamps onto the currently attached screens |
| `MenuContext.modalPanelPresented` | `Sources/Qnet/WindowSupport.swift` | `@Published var modalPanelPresented = false`; also folded into the existing `anySheetPresented` |

---

## W4-INT-1 — Qnet Help remembers its frame and opens into the user's full-screen space

1. **ID** — `W4-INT-1`, completes **W4-03**. W4-03 is **not** shippable without it: the task's
   acceptance criteria name Qnet Help explicitly and `grep -rn setFrameAutosaveName Sources/Qnet`
   must come back empty.
2. **Target file and anchor** — `Sources/Qnet/QnetHelpWindow.swift`, inside
   `enum QnetHelpWindow` → `static func show(topic:)`. Anchor, verbatim at line 966:
   ```swift
        window.setFrameAutosaveName("QnetHelpWindow")
   ```
   and the `AuxiliaryWindow.make(…)` call immediately above it (lines 958–965 at the time of writing).
3. **Insert / replace** — before:
   ```swift
        let window = AuxiliaryWindow.make(
            id: "help",
            title: "Qnet Help",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin
        ) { _ in
            QnetHelpView(model: m)
        }
        window.setFrameAutosaveName("QnetHelpWindow")
        retained = window
   ```
   after:
   ```swift
        let window = AuxiliaryWindow.make(
            id: "help",
            title: "Qnet Help",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetHelpWindow"
        ) { _ in
            QnetHelpView(model: m)
        }
        retained = window
   ```
   The `setFrameAutosaveName` line is **deleted**, not moved: it is the call the app's own comment
   at `ContentView.swift:1564-1568` records as unreliable under SwiftUI, and `frameKey:` installs
   `WindowFrameAutosave` instead. The defaults key is unchanged (`WindowFrame.QnetHelpWindow` vs.
   AppKit's `NSWindow Frame QnetHelpWindow`), so a user loses at most one remembered position once.
4. **New symbols it depends on** — `AuxiliaryWindow.make`'s `fullScreenAuxiliary:` and `frameKey:`
   parameters (`Sources/Qnet/WindowSupport.swift`, see table above).
5. **Gate impact** — none. No string `gui_runtime_contracts.sh` greps, no `.keyboardShortcut`, no
   `DSEmptyState` title, no `Divider()`, no menu path, no ⌘-digit. `design_lint.sh` is unaffected
   (no frame, radius or stroke literal is added).
6. **Verification** —
   ```sh
   grep -rn setFrameAutosaveName Sources/Qnet     # must print nothing
   ```
   Then: Help ▸ Qnet Help, drag the window to a corner and resize it, ⌘W, quit, relaunch, Help ▸
   Qnet Help — it opens at the moved and resized frame, not centred.
7. **Priority** — **P0**.

---

## W4-INT-2 — The Network Model guide stops rebuilding itself, and remembers its frame

1. **ID** — `W4-INT-2`, completes **W4-03**. W4-03 is **not** shippable without it: this is one of
   the two windows the task names as "worse", because it loses its position within a single session.
2. **Target file and anchor** — `Sources/Qnet/NetworkModelGuideView.swift`, inside
   `enum NetworkModelGuideWindow` → `static func show(editor:settings:)`. Anchors, verbatim:
   ```swift
        retained?.close()                                  // line 365
   ```
   ```swift
        window.setFrameAutosaveName("QnetNetworkModelWindow")   // line 378
   ```
3. **Insert / replace** — replace the whole body of `show(editor:settings:)`. Before:
   ```swift
    static func show(editor: NetworkEditorModel, settings: AppSettings) {
        retained?.close()
        let window = AuxiliaryWindow.make(
            id: "network-model",
            title: "Network Model",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin
        ) { ref in
            NetworkModelGuideView(
                editor: editor,
                settings: settings,
                close: { ref.close() }
            )
        }
        window.setFrameAutosaveName("QnetNetworkModelWindow")
        retained = window
        AuxiliaryWindow.present(window)
    }
   ```
   after:
   ```swift
    /// Opens the guide, or brings the open one forward re-pointed at
    /// `editor`. It is deliberately NOT closed and rebuilt: rebuilding
    /// throws away the frame the user dragged it to, within one session.
    static func show(editor: NetworkEditorModel, settings: AppSettings) {
        let model = NetworkModelGuideModel.shared
        model.update(editor: editor, settings: settings)

        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }

        let window = AuxiliaryWindow.make(
            id: "network-model",
            title: "Network Model",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetNetworkModelWindow"
        ) { ref in
            NetworkModelGuideWindowRoot(model: model, close: { ref.close() })
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
   ```
   Reusing the window means the editor and settings it advises about can no longer be baked into
   the view at construction. Add, in the same file, the two types below — they are a line-for-line
   transposition of `MethodChooserModel` / `MethodChooserWindowRoot`, which W4 landed this round in
   `Sources/Qnet/MethodChooserView.swift` and which the integrator can copy from:
   ```swift
    /// What the Network Model guide is currently describing. The window is
    /// built once and reused (rebuilding it loses the frame the user dragged
    /// it to), so the editor and settings it points at have to be swappable
    /// under the live view rather than captured at construction.
    @MainActor
    final class NetworkModelGuideModel: ObservableObject {
        static let shared = NetworkModelGuideModel()

        @Published fileprivate var editor: NetworkEditorModel?
        @Published fileprivate var settings: AppSettings?

        private init() {}

        fileprivate func update(editor: NetworkEditorModel, settings: AppSettings) {
            if self.editor !== editor { self.editor = editor }
            if self.settings !== settings { self.settings = settings }
        }
    }

    /// Root of the reused window: renders the guide for whichever editor the
    /// model currently points at.
    private struct NetworkModelGuideWindowRoot: View {
        @ObservedObject var model: NetworkModelGuideModel
        let close: () -> Void

        var body: some View {
            if let editor = model.editor, let settings = model.settings {
                NetworkModelGuideView(editor: editor, settings: settings, close: close)
            } else {
                // Only reachable if the window is shown before any editor has
                // claimed it; a live empty state beats a blank pane.
                DSEmptyState(
                    systemImage: DS.Symbol.network,
                    title: "No Active Network",
                    message: "Open or create a network to see how Qnet models it.")
                .frame(minWidth: DS.Layout.Window.auxMinWidth,
                       minHeight: DS.Layout.Window.auxMinHeight)
            }
        }
    }
   ```
   If `AppSettings` is not a class (`final class AppSettings: ObservableObject` at the time of
   writing), replace the `!==` identity checks with plain assignment; nothing else changes.
4. **New symbols it depends on** — `AuxiliaryWindow.make`'s `fullScreenAuxiliary:` and `frameKey:`
   (`Sources/Qnet/WindowSupport.swift`). The reference implementation to copy is
   `MethodChooserModel` + `MethodChooserWindowRoot` in `Sources/Qnet/MethodChooserView.swift`.
5. **Gate impact** — adds one `DSEmptyState` title, **"No Active Network"** — Title Case noun
   phrase, which is what `design_lint.sh`'s empty-state rule requires. No contract strings, no
   shortcuts, no menu paths.
6. **Verification** —
   ```sh
   grep -rn setFrameAutosaveName Sources/Qnet     # must print nothing
   ```
   Then: open the Network Model guide, drag it to a corner, close it, reopen it in the same
   session — it comes back where it was left, and does so again after quit + relaunch.
7. **Priority** — **P0**.

---

## W4-INT-3 — The Settings scene declares its resizability

1. **ID** — `W4-INT-3`, completes **W4-03**. W4-03 **is** shippable without it: W4 already attached
   `WindowFrameAutosave(name: "QnetSettingsWindow")` inside `SettingsView`, so the frame is
   remembered today. This makes the window's resizability deliberate instead of incidental.
2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, the `Settings` scene at the end of
   `var body: some Scene`. Anchor, verbatim at lines 1000–1003:
   ```swift
        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }
   ```
3. **Insert / replace** — after:
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
   Nothing else in the scene changes. Do **not** add `.defaultPosition(…)`: the frame autosaver
   inside `SettingsView` restores the user's own position, and a `defaultPosition` would fight it
   on the first display of every launch.
4. **New symbols it depends on** — none. `WindowFrameAutosave` (ContentView.swift) is already
   attached by `SettingsView.body`; no new symbol is referenced here.
5. **Gate impact** — none. `.windowResizability` is a scene modifier: no contract string, no
   shortcut for `QNET_MENU_AUDIT=1` to re-clear, nothing `design_lint.sh` inspects.
6. **Verification** — ⌘, then drag the Settings window's bottom-right corner inward: it stops at
   704 × 520 instead of collapsing the sidebar. Move and resize it, quit, relaunch, ⌘, — same frame.
7. **Priority** — **P1**.

---

## W4-INT-4 — Menu commands see a modal panel, not just a modal sheet

1. **ID** — `W4-INT-4`, completes **W4-01**. W4-01 **is** shippable without it: the one form
   converted this round (Canvas Export Options) is `.modeless` by design, and no `.documentModal`
   or `.appModal` panel exists yet. This must land before the first one does.
2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift`, the computed property
   `sheetPresented`. Anchor, verbatim at lines 174–182 (the property is quoted in full; match on the text, W5 is editing this file this round):
   ```swift
    private var sheetPresented: Bool {
        editor.isModalSheetPresented
            // Sheets presented from the App scene (Generate Random, Find
            // Node, Run Test Set, Spectral Convergence, run parameters):
            // a Stepper or Picker inside them is not NSText, so without
            // this the bare tool letters would switch the canvas tool
            // underneath the sheet.
            || menuContext.appSheetPresented
    }
   ```
3. **Insert / replace** — append one clause; the rest of the property is untouched:
   ```swift
    private var sheetPresented: Bool {
        editor.isModalSheetPresented
            // Sheets presented from the App scene (Generate Random, Find
            // Node, Run Test Set, Spectral Convergence, run parameters):
            // a Stepper or Picker inside them is not NSText, so without
            // this the bare tool letters would switch the canvas tool
            // underneath the sheet.
            || menuContext.appSheetPresented
            // A DSPanelWindow opened .documentModal or .appModal: a real,
            // movable window rather than a sheet, but one the user is
            // expected to answer. It is a SEPARATE flag on purpose —
            // appSheetPresented means "SwiftUI is showing the scene's one
            // sheet", and a panel clears itself from
            // NSWindow.willCloseNotification, so it cannot get stuck.
            || menuContext.modalPanelPresented
    }
   ```
   Do **not** rename `sheetPresented` or `appSheetPresented`: `QnetGUIApp.presentRunParameters`
   guards on `appSheetPresented` by that name, and the comment at `QnetGUIApp.swift:1621-1626`
   records why.
4. **New symbols it depends on** — `MenuContext.modalPanelPresented`
   (`Sources/Qnet/WindowSupport.swift`: `@Published var modalPanelPresented = false`, set and
   cleared only by `DSPanelWindow`).
5. **Gate impact** — none. `sheetPresented` is a private computed property; `gui_runtime_contracts.sh`
   does not grep `QnetCommands.swift`, no `.disabled(…)` predicate string is asserted anywhere, and
   no shortcut or DS surface changes.
6. **Verification** — `swift build`. Behaviourally, once a `.documentModal` panel exists: open it,
   press `S` (the Station tool letter) — the canvas tool must not change; close the panel and press
   `S` again — it must. Regression check for the stuck-flag bug: open the Canvas Export panel
   (`.modeless`), press `S` — the tool **must** still change, because a modeless panel sets nothing.
7. **Priority** — **P1**.

---

## W4-INT-5 — One implementation of "the frame this window was last left at"

1. **ID** — `W4-INT-5`, completes **W4-03**. W4-03 **is** shippable without it — this is a
   de-duplication, not a behaviour change.
2. **Target file and anchor** — `Sources/Qnet/ContentView.swift`, `struct WindowFrameAutosave` →
   `final class Coordinator`. Anchors, verbatim:
   ```swift
        private var defaultsKey: String { "WindowFrame.\(name)" }     // line 1814
   ```
   ```swift
        private func restore() {                                      // line 1824
   ```
3. **Insert / replace** — hoist the key and the clamp out of the coordinator onto the
   `WindowFrameAutosave` type itself, and have both `Coordinator.restore()` and the new caller use
   them:
   ```swift
    extension WindowFrameAutosave {
        /// UserDefaults key a frame is stored under.
        static func defaultsKey(for name: String) -> String { "WindowFrame.\(name)" }

        /// The frame saved under `name`, clamped onto the screens attached
        /// *now* so a frame remembered on a since-disconnected display still
        /// opens on-screen. `nil` when nothing usable is stored.
        @MainActor
        static func savedFrame(named name: String) -> NSRect? { … }   // body: today's restore(), minus the setFrame
    }
   ```
   Then, in `Sources/Qnet/WindowSupport.swift` (W4-owned — **W4 will make this edit itself once the
   symbol exists; do not edit WindowSupport.swift for this**), `AuxiliaryWindow.savedFrame(named:)`
   loses its body and becomes a one-line forward to `WindowFrameAutosave.savedFrame(named:)`, and
   the duplicate-implementation note in its doc comment is deleted.
   **Why the duplicate exists at all:** `AuxiliaryWindow.make` has to know the remembered frame
   *before* the window is ordered front, because `WindowFrameAutosave` only restores one run-loop
   tick after the first layout pass — by which point the window has already been centred and shown,
   which the user sees as a jump. The autosaver is still the authority for saving; only the read is
   needed early.
4. **New symbols it depends on** — none from W4; this request *creates* the symbol
   `WindowFrameAutosave.savedFrame(named:)` that `AuxiliaryWindow.savedFrame(named:)`
   (`Sources/Qnet/WindowSupport.swift`) will then delegate to.
5. **Gate impact** — none. `design_lint.sh` does not inspect `ContentView.swift` for this, no
   contract string moves, no UI changes.
6. **Verification** — `swift build`, then: move Qnet Help, quit, relaunch, reopen — it opens at the
   moved frame with **no visible jump from centre**. On a machine with a second display: park a
   window on it, quit, disconnect the display, relaunch, reopen — the window is on the built-in
   screen.
7. **Priority** — **P1**.

---

## W4-INT-6 — `DS.Layout.Window.dialogCompact / dialogStandard / dialogWide` contradict the sizes `DSPanelWindow` can use

1. **ID** — `W4-INT-6`, relates to **W4-01**. W4-01 shipped without them, so nothing is blocked;
   this is a request to resolve dead-and-misleading tokens before another workstream adopts them.
2. **Target file and anchor** — `Sources/Qnet/DesignSystem.swift` (frozen, integrator-owned),
   `enum DS.Layout.Window`. Anchor, verbatim at lines 1199–1212:
   ```swift
            /// Movable dialog panels (`DSPanelWindow`). A form the user
   ```
   ```swift
            static var dialogCompact: NSSize { NSSize(width: 440, height: 320) }
            static var dialogStandard: NSSize { NSSize(width: 616, height: 480) }
            static var dialogWide: NSSize { NSSize(width: 840, height: 592) }
   ```
3. **Insert / replace** — the finding, then the choice.
   `DSPanelWindow.present(id:title:size:…)` takes a `DSSheetSize`, exactly as the W4-01 spec
   directs, because the form it hosts is the *same body* a `.sheet` would show and that body already
   carries `.dsSheetFrame(size)`. The panel's opening size, minimum and maximum therefore come from
   the `DSSheetSize` band. The three `dialog*` sizes cannot be used alongside it, because they fall
   **outside** those bands:

   | token | size | contradicts |
   | --- | --- | --- |
   | `dialogCompact` | 440 × 320 | `.compact` band is 500…720 wide, 360…600 tall — a panel opened at 440 × 320 could not be resized *down* to the size it opened at |
   | `dialogStandard` | 616 × 480 | `.regular` band is 500…720 wide, 424…800 tall — width fits, but 480 is 64 pt shorter than `.regular`'s 544 ideal, so two panels of the same band would open at different heights |
   | `dialogWide` | 840 × 592 | `.wide` band is 640…820 wide — 840 exceeds the maximum |

   Pick one:
   * **(a) preferred** — delete the three `static var`s and their doc comment. The `DSSheetSize`
     band is the single source of dialog geometry, and there is then only one to keep consistent.
   * **(b)** — keep them and re-derive each from the band it means, e.g.
     `static var dialogCompact: NSSize { NSSize(width: sheetMinWidth, height: sheetMinHeightCompact) }`,
     so the two cannot drift. `DSPanelWindow` would still not read them; they would be documentation.

   Whichever is chosen, the doc comment must stop naming `DSPanelWindow` as their consumer, because
   it is not one.
4. **New symbols it depends on** — none. It refers to `DSPanelWindow`
   (`Sources/Qnet/DSPanelWindow.swift`) and `DSSheetSize` (`Sources/Qnet/DSSheet.swift`, unchanged).
5. **Gate impact** — none under option (a): `grep -rn 'dialogCompact\|dialogStandard\|dialogWide' Sources/Qnet`
   returns only the DesignSystem.swift declarations today, so deleting them cannot break a call
   site. `design_lint.sh` does not inspect DesignSystem.swift.
6. **Verification** —
   ```sh
   grep -rn 'dialogCompact\|dialogStandard\|dialogWide' Sources/Qnet   # only DesignSystem.swift, then nothing
   swift build
   ```
7. **Priority** — **P1**.

---

# Round-2 conversion recipes: the five `QnetGUIApp`-presented forms

W4-02 requires these to be published as ready-to-apply instructions. They are **not** requests to
apply in round 1 — each converts a `.sheet(` in `QnetGUIApp.swift`, which W6 owns this round, and
each is a behaviour change that wants its own round. They are written as one recipe plus five
per-form tables because the five conversions are the same edit five times.

## The recipe

Every one of the five follows this shape. Take Find Node as the worked example.

**Before** (`QnetGUIApp.swift:763`):
```swift
                .sheet(isPresented: $showFindNodeSheet) {
                    FindNodeSheet(
                        nodes: activeEditor.nodes,
                        onCancel: { showFindNodeSheet = false },
                        onFind: { query in
                            showFindNodeSheet = false
                            _ = activeEditor.findAndRevealNode(named: query)
                        }
                    )
                }
```

**After** — the `.sheet(` modifier is deleted outright and replaced by an `.onChange` that opens and
closes the panel from the same `@State` flag, so every existing call site that writes
`showFindNodeSheet = true` (menu action, shortcut, toolbar) is untouched:
```swift
                // Find Node is a panel, not a sheet: the user is looking for
                // a node ON the canvas the dialog would otherwise cover.
                // The @State flag stays the single switch — the panel is the
                // presentation, `showFindNodeSheet` is still the state — so
                // `appSheetPresented` and every command that sets the flag
                // keep working unchanged.
                .onChange(of: showFindNodeSheet) { _, presented in
                    guard presented else {
                        DSPanelWindow.close(id: "find-node")
                        return
                    }
                    DSPanelWindow.present(
                        id: "find-node",
                        title: "Find Node",
                        size: .compact,
                        escapeCloses: false,
                        onClose: { showFindNodeSheet = false }
                    ) { ref in
                        FindNodeSheet(
                            nodes: activeEditor.nodes,
                            onCancel: { ref.close() },
                            onFind: { query in
                                ref.close()
                                _ = activeEditor.findAndRevealNode(named: query)
                            }
                        )
                    }
                }
```

Five rules the recipe depends on, each learned from the Canvas Export conversion W4 shipped:

1. **`onClose:` is the one teardown path.** It runs however the panel goes away — the footer's
   Cancel, the title-bar close button, ⌘W, Escape, Quit — so the `@State` flag is cleared exactly
   once and cannot get stuck. A stuck flag disables the canvas tool letters and ⌫ until relaunch;
   that is the bug the comment at `QnetGUIApp.swift:1621-1626` records.
2. **`onClose` re-entrancy is safe but must be understood.** `ref.close()` → `willClose` →
   `onClose` → `showFindNodeSheet = false` → the `.onChange` above fires with `presented == false`
   → `DSPanelWindow.close(id:)`, which is a no-op because the registry entry is already gone.
   The mirror image is handled too: when the *caller* takes the panel away with
   `DSPanelWindow.close(id:)`, `onClose` deliberately does **not** run, so a `close` immediately
   followed by a `present` under the same id cannot have the old panel's teardown clear the flag
   the new one is standing on.
3. **`escapeCloses: false` for any body built on `DSSheet`.** Its `DSSheetFooter` already binds
   Cancel to `.cancelAction`; two cancel actions in one window is one too many. Pass `true` only
   for a root with no footer of its own.
4. **Anything app-modal that the confirm action opens (an `NSSavePanel`, an `NSAlert`) must be
   raised AFTER the panel is ordered out**, on the next run-loop turn:
   `ref.close(); DispatchQueue.main.async { … }`. Two windows fighting for key status leaves the
   form's fields half-alive behind the modal.
5. **`appSheetPresented` (`QnetGUIApp.swift:1586`) must keep listing the converted flag.** It is
   the mirror `QnetCommands.sheetPresented` reads, and the guard in `presentRunParameters`
   (`QnetGUIApp.swift:1627`) that refuses a second run dialog. Converting a sheet to a panel does not change
   whether a dialog is up. Leave that property exactly as it is.

## The five forms

| Form | Anchor | Panel id | `size:` | Notes specific to it |
| --- | --- | --- | --- | --- |
| **Find Node** | `.sheet(isPresented: $showFindNodeSheet) {` — `QnetGUIApp.swift:763` | `find-node` | `.compact` | The worked example above. The strongest case of the five: the dialog covers the canvas it is searching. |
| **Generate Random Network** | `.sheet(isPresented: $showGenerateRandomSheet) {` — `:745` | `generate-random` | `.regular` | `onGenerate` calls `createRandomNetworkTab(params:)`, which creates a tab and can change `activeEditor`. Close the panel **first** (`ref.close()`), then create the tab, so the new tab takes key status from a window that is already gone. |
| **Run Test Set** | `.sheet(isPresented: $showTestSetSheet) {` — `:710` | `test-set` | `.regular` | `onRun` spawns `Task.detached { await executeTestSet(…) }`. Keep the ordering `testSetParams = p; ref.close(); Task.detached { … }` — the sweep drives the shell, and the panel must not be up when it starts. |
| **Spectral Convergence** | `.sheet(isPresented: $showSpectralConvergenceSheet) {` — `:728` | `spectral-convergence` | `.tall` | Same shape as Run Test Set. `.tall` because the sweep form is the longest of the five. |
| **Run parameters** (7 solvers) | `.sheet(item: $runParameterRequest) { request in` — `:759` | `run-parameters` | `.regular` | The only `.sheet(item:)` of the five, so the `.onChange` observes `runParameterRequest != nil` and the `onClose:` sets `runParameterRequest = nil`. `RunParameterRequest.onCancel` **already** nils the request and then calls the caller's `onCancel`, so route `ref.close()` through the request's own `onCancel`, never around it. One panel id for all seven solvers is correct: `presentRunParameters` already refuses a second run dialog while one is up (`:1627`). |

**Gate impact of the five conversions, together** — `validation/gui_runtime_contracts.sh` greps
`QnetGUIApp.swift` for the awk formatters, the EXIT/INT/TERM trap pattern, the count of exactly 8
`commandWithCleanup` Python runners and `${PIPESTATUS[0]}`; none of those strings is inside a
`.sheet(` modifier, and no run action's shell command changes. No `.keyboardShortcut` is added or
moved, so `QNET_MENU_AUDIT=1` re-clears unchanged. No `DSEmptyState` title, `Divider()`, menu-path
arrow or ⌘-digit is introduced. Run the full round exit gate after the conversion regardless.

**Verification for the five, together** —
```sh
grep -c '\.sheet(' Sources/Qnet/QnetGUIApp.swift    # 6 today → 1 (the startup dependency check, which is
                                                     #   deliberately still a sheet: it blocks launch)
swift build
validation/gui_runtime_contracts.sh
```
Then, for each: open it from its menu item, drag it aside, confirm the canvas is visible and
scrollable behind it, complete the form, and confirm the result is identical to today's. Press `S`
on the canvas while each panel is up — the tool must **not** change, because the `@State` flag is
still set and `appSheetPresented` still mirrors it.
