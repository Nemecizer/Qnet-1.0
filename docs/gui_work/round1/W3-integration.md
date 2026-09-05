# W3 — integration requests, round 1

Workstream: **W3 — Window layout, pane prominence and focus routing.**
Everything below is a change in a file W3 does not own. Seven requests, one of them P0.

New symbols this round, all in files W3 owns, so an integrator can confirm they exist before
applying anything:

| Symbol | File | Declaration |
| --- | --- | --- |
| `AppSettings.soloedPane` | `Sources/Qnet/AppSettings.swift` | `var soloedPane: FocusRouter.Pane? { get set }` |
| `AppSettings.toggleSolo(_:)` | `Sources/Qnet/AppSettings.swift` | `func toggleSolo(_ pane: FocusRouter.Pane)` |
| `AppSettings.isPaneEnabled(_:)` | `Sources/Qnet/AppSettings.swift` | `func isPaneEnabled(_ pane: FocusRouter.Pane) -> Bool` (the View ▸ Panes choice, ignoring any maximize) |
| `AppSettings.hasStoredSolo` | `Sources/Qnet/AppSettings.swift` | `var hasStoredSolo: Bool` |
| `AppSettings.resultsAutoShown` | `Sources/Qnet/AppSettings.swift` | `@AppStorage("results.autoShown") var resultsAutoShown: Bool` |
| `AppSettings.Defaults.soloedPane` / `.resultsAutoShown` | `Sources/Qnet/AppSettings.swift` | `static let soloedPane = ""` / `static let resultsAutoShown = false` |
| `PaneSoloButton` | `Sources/Qnet/PaneChrome.swift` | `struct PaneSoloButton: View { init(_ pane: FocusRouter.Pane) }` |
| `PaneHandlerOwner` | `Sources/Qnet/PaneChrome.swift` | `final class PaneHandlerOwner { var id: ObjectIdentifier }` |
| `FocusRouter.Pane.displayName` | `Sources/Qnet/PaneChrome.swift` | `var displayName: String` |
| `FocusRouter.Pane.canBeMaximized` | `Sources/Qnet/PaneChrome.swift` | `var canBeMaximized: Bool` (false only for `.palette`) |
| `WorkspacePresetItems` | `Sources/Qnet/WorkspaceCommands.swift` | `struct WorkspacePresetItems: View { @ObservedObject var appSettings: AppSettings }` |
| `WorkspaceCommands.toggleMaximizeFocusedPane(appSettings:)` | `Sources/Qnet/WorkspaceCommands.swift` | `@MainActor static func` |
| `WorkspaceCommands.maximizeTitle(_:)` / `.maximizeHelp(_:)` / `.maximizeTarget(_:)` | `Sources/Qnet/WorkspaceCommands.swift` | `@MainActor static func` |
| `WorkspaceCommands.applyWorkspacePreset(_:palette:status:inspector:results:shell:ai:)` | `Sources/Qnet/WorkspaceCommands.swift` | `@MainActor static func` (was a private instance method) |

W3 needs **no new `DesignSystem.swift` token**. `DS.Layout.shellRowIdealHeight`,
`DS.Symbol.paneMaximize` and `DS.Symbol.paneRestore` — the three seeded for this workstream — are
all adopted as seeded.

---

## W3-INT-1 — two `unindexedKeys` entries so the Settings audit still passes

1. **ID** — `W3-INT-1`. Completes **W3-01** and **W3-02**. Both tasks are shipped and working
   without it; what is broken without it is the DEBUG-only Settings audit. **This is the one P0.**

2. **Target file and anchor** — `Sources/Qnet/SettingsView.swift`, `SettingsRegistry.unindexedKeys`.
   Anchor, verbatim from today's source, line 601:

   ```swift
        "ai.paneVisible":        "View ▸ Panes, not a setting; edited by the Show AI Assistant pane row, whose entry lists no keys because Reset never shows or hides a pane",
   ```

3. **Insert / replace** — insert two entries immediately **after** that line:

   ```swift
        "panes.soloed":          "View ▸ Panes ▸ Maximize Pane, not a setting — which pane currently has the whole window, restored on the next launch the way a hidden pane is",
        "results.autoShown":     "one-shot bookkeeping: whether the first solver run has already revealed the Results workspace. Not user-facing and never reset by a Settings pane",
   ```

4. **New symbols it depends on** — `AppSettings.Defaults.soloedPane` and
   `AppSettings.Defaults.resultsAutoShown`, and their rows in `AppSettings.defaultsByKey`
   (`"panes.soloed"`, `"results.autoShown"`). All in `Sources/Qnet/AppSettings.swift`, landed this
   round.

5. **Gate impact** — `validation/gui_runtime_contracts.sh`: none (it does not read this file).
   `QNET_MENU_AUDIT`: none. `design_lint.sh`: the two strings contain a `▸` menu path, which is the
   spelling the lint requires — do **not** rewrite them with `→`. What this *does* fix is
   `SettingsRegistry.audit()`'s assertion
   *"AppSettings stores \"…\" but no SettingsRegistry entry edits it"*, which fires in a DEBUG build
   the first time the Settings window is opened, because W3 added the two keys to
   `AppSettings.defaultsByKey` (as the backlog's W3-01 and W3-02 instructions require) while the
   excusal list lives in a W4-owned file.

6. **Verification** — build in debug and open Settings (⌘,). No assertion. Equivalently, before the
   change, `SettingsRegistry.audit()` trips on `panes.soloed`.

7. **Priority** — **P0.**

---

## W3-INT-2 — maximize control in the Status pane header

1. **ID** — `W3-INT-2`. Completes **W3-01** for the Status pane. W3-01 ships without it: the Status
   pane is still maximizable from View ▸ Panes ▸ Maximize Pane (⌃⌘↩) and from the toolbar's
   Workspace menu; only the header button is missing.

2. **Target file and anchor** — `Sources/Qnet/StatusLog.swift`, `StatusPanelView.body`, the
   `DSSectionHeader("Status", …) { … } trailing: { … }` slot. Anchor, verbatim, lines 267–273:

   ```swift
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Clear Status Log",
                    help: "Clear the status log. It is not restored on the next launch, but Undo Clear in the empty log brings it back until the next clear.",
                    isDestructive: true
                ) { clearLog() }
                .disabled(editor.statusMessages.isEmpty)
   ```

3. **Insert / replace** — insert immediately **after** the `.disabled(editor.statusMessages.isEmpty)`
   line, still inside the `trailing:` builder:

   ```swift
                // Last in the row, after the destructive control: this one
                // changes the window, not the log. Same position in every
                // pane header that has it.
                PaneSoloButton(.status)
   ```

   No `.disabled(…)`, no `.keyboardShortcut(…)`. `PaneSoloButton` carries its own label, tooltip and
   symbol, and flips between Maximize and Restore itself.

4. **New symbols it depends on** — `PaneSoloButton` (`Sources/Qnet/PaneChrome.swift`,
   `struct PaneSoloButton: View`, `init(_ pane: FocusRouter.Pane)`). It reads `AppSettings` from the
   environment, which `StatusPanelView` already has in scope; nothing needs to be passed in.

5. **Gate impact** — none. No contract string, no shortcut, no `DSEmptyState` title, no `Divider()`.
   `PaneSoloButton` composes `DSIconButton` and `DS.Symbol.paneMaximize` / `.paneRestore`, so the
   literal-SF-Symbol and borderless-button rules are satisfied at its own definition site.

6. **Verification** — click the new ⤢ button in the Status header: the Status pane fills the window
   and the glyph becomes the inward pair. Click it again: every divider returns to where it was.

7. **Priority** — P1.

---

## W3-INT-3 — maximize control in the Results workspace header

1. **ID** — `W3-INT-3`. Completes **W3-01** for the Results pane; same reachability caveat as
   W3-INT-2, so W3-01 ships without it.

2. **Target file and anchor** — `Sources/Qnet/ResultsWorkspace.swift`, `ResultsWorkspaceView.body`,
   the `DSSectionHeader("Results", …) trailing: { … }` slot. Anchor, verbatim, lines 974–980:

   ```swift
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Delete Result",
                    help: "Delete the selected run record",
                    isDestructive: true
                ) { showDeleteConfirmation = true }
                .disabled(selectedRun == nil)
   ```

3. **Insert / replace** — insert immediately **after** `.disabled(selectedRun == nil)`, still inside
   the `trailing:` builder:

   ```swift
                // Last in the row, after the destructive control: this one
                // changes the window, not the record.
                PaneSoloButton(.results)
   ```

   The Results workspace is the pane most likely to be maximized (a station table with more rows
   than a 248-pt row can show), so this one earns its place more than any other.

4. **New symbols it depends on** — `PaneSoloButton` (see W3-INT-2). `ResultsWorkspaceView` must have
   `AppSettings` in the environment; it is injected on the main window's root in `QnetGUIApp`, so it
   already does.

5. **Gate impact** — none.

6. **Verification** — with a run record selected, click the maximize button: the Results pane fills
   the window with the run table at full height; click restore and the canvas row, Results row and
   bottom row return to their previous heights.

7. **Priority** — P1.

---

## W3-INT-4 — maximize control in the AI Assistant header

1. **ID** — `W3-INT-4`. Completes **W3-01** for the AI pane; W3-01 ships without it.

2. **Target file and anchor** — `Sources/Qnet/AIPaneView.swift`, the
   `DSSectionHeader("AI Assistant", …) trailing: { … }` slot. Anchor, verbatim, lines 684–690:

   ```swift
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Clear Conversation",
                    help: ai.isBusyForActiveTab ? "Stop the request before clearing the conversation" : "Clear the conversation…",
                    isDestructive: true
                ) { confirmClear() }
                .disabled(ai.isBusyForActiveTab || ai.isEmptyTranscript)
   ```

3. **Insert / replace** — insert immediately **after**
   `.disabled(ai.isBusyForActiveTab || ai.isEmptyTranscript)`, still inside the `trailing:` builder:

   ```swift
                // Last in the row, after the destructive control: this one
                // changes the window, not the conversation.
                PaneSoloButton(.ai)
   ```

   Note it is deliberately **not** folded into `overflowMenu` at the condensed width: a maximize
   button is exactly what a user reaches for when the pane is too narrow.

4. **New symbols it depends on** — `PaneSoloButton` (see W3-INT-2). `AIPaneView` already holds
   `@EnvironmentObject … appSettings`.

5. **Gate impact** — none.

6. **Verification** — click it with the AI pane visible: the assistant fills the window; click again
   and the canvas row and the Shell come back at their previous sizes.

7. **Priority** — P1.

---

## W3-INT-5 — a `KeyboardShortcutReference` entry for ⌃⌘↩

1. **ID** — `W3-INT-5`. Supports **W3-01**. W3-01 ships without it: the binding works and the menu
   prints it. What is missing is the entry in the one table the tooltips read from, so
   `PaneSoloButton`'s tooltip currently names the menu path but not the key, and Help ▸ Keyboard
   Shortcuts does not list it.

2. **Target file and anchor** — `Sources/Qnet/KeyboardShortcutReference.swift`, `enum Command` and
   its `key` / `menuPath` / listing tables. Anchor, verbatim, line 33:

   ```swift
        case clearShell
   ```

3. **Insert / replace** — add a case, its key text and its menu path, following the file's existing
   shape exactly:

   * after `case clearShell`, add
     ```swift
        /// ⌃⌘↩ — View ▸ Panes ▸ Maximize Pane. The item's title flips to
        /// "Restore Pane Layout" while a pane is maximized, so the audited
        /// path is the maximize spelling only.
        case maximizePane
     ```
   * in `var key: String`, beside `case .clearShell:`, add
     ```swift
            case .maximizePane: return "⌃⌘↩"
     ```
   * in `var menuPath: String?` — **only if** the auditor can accept a title that changes with
     state. It cannot: `MenuShortcutAudit` matches on the printed title, and this item is titled
     "Restore Pane Layout" whenever a pane is maximized, which would report drift. So
     `menuPath` for `.maximizePane` **must be `nil`**, exactly as `.stop` and `.find` are (both are
     dynamic titles, and the file already documents that reason at `case stop`).
   * add it to whatever ordered list `KeyboardShortcutReference.text()` renders, in the View ▸ Panes
     group beside `showResultsPane`, with the description
     `"Give the focused pane the whole window, or restore the saved arrangement"`.

4. **New symbols it depends on** — none of W3's; the menu item itself is in
   `Sources/Qnet/WorkspaceCommands.swift` (W3-owned, landed) at
   `.keyboardShortcut(.return, modifiers: [.control, .command])`.

5. **Gate impact** — `MenuShortcutAudit` / `QNET_MENU_AUDIT=1`: adding a `Command` case **with a
   non-nil `menuPath`** makes `KeyboardShortcutReference.auditTable(against:)` require a live menu
   item at that exact path — which is why point 3 insists on `nil`. `design_lint.sh`: the string
   `"⌃⌘↩"` contains no digit, so the bare-⌘-digit rule does not apply; the modifier order ⌃⌘ is the
   canonical one the "shortcut modifiers are in canonical order" check wants.

6. **Verification** — `QNET_MENU_AUDIT=1 <binary>` exits 0 (no collision, no table drift), and
   Help ▸ Keyboard Shortcuts lists ⌃⌘↩ under the pane commands.

7. **Priority** — P1.

---

## W3-INT-6 — changelog bullets

1. **ID** — `W3-INT-6`. Housekeeping for **W3-01**, **W3-02** and **W3-04**. Nothing is broken
   without it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost entry, the one with
   `timestamp: nil`. Add to its bullet list; do **not** create a new release entry, and do not touch
   `AppVersion.swift` (still 0.90.34).

3. **Insert / replace** — add these four bullets:

   ```swift
                "Any pane can take the whole window: the maximize button in a pane header, or View ▸ Panes ▸ Maximize Pane (⌃⌘↩) on the focused pane. Nothing is hidden — restoring puts every divider back exactly where it was.",
                "The first solver run no longer forces the Results workspace open forever. It reveals it once, and only when the Shell is closed too, so a run that is already visible somewhere does not letterbox the canvas.",
                "A new install starts with five panes rather than six: the AI Assistant is off until you ask for it (⌥⌘4).",
                "A Shell workspace preset, and the preset list one click away in the toolbar's Workspace menu rather than three levels down a menu.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — `design_lint.sh` reads these strings: the menu path uses `▸` (required) and
   `⌥⌘4` is a modifier-plus-digit, not a bare `⌘4`, so the stray-⌘-digit rule does not fire. The
   canonical modifier order ⌃⌘ / ⌥⌘ is used.

6. **Verification** — `design_lint.sh` passes; Help ▸ Release Notes shows the four bullets under the
   in-development entry.

7. **Priority** — P1.

---

## W3-INT-7 — round 2: opt the three remaining `FocusRouter` registrants into owner tokens

1. **ID** — `W3-INT-7`. Completes **W3-03(b)** for the panes W3 does not own. **W3-03 ships without
   it**: the `owner:` parameter defaults to `nil`, so every registrant that has not opted in behaves
   exactly as it did before, and the Inspector (W3-owned) already demonstrates the fix. This request
   is queued for round 2 deliberately — applying it in round 1 would edit three files mid-round for
   no user-visible gain.

2. **Target files and anchors** — three registrations, each an `onAppear` / `onDisappear` pair:

   * `Sources/Qnet/StatusLog.swift`, line 300, verbatim:
     ```swift
            FocusRouter.shared.setFocusHandler(.status) { focusRequest += 1 }
     ```
   * `Sources/Qnet/AIPaneView.swift` — its `FocusRouter.shared.setFocusHandler(.ai, …)`,
     `setZoomHandler(.ai, …)`, `setFindHandler(.ai, …)` and `setFindStepHandler(.ai, …)` calls and
     their nil-ing counterparts.
   * `Sources/Qnet/ResultsWorkspace.swift` — its `setFocusHandler(.results, …)` and
     `setFindHandler(.results, …)` calls and their nil-ing counterparts.

3. **Insert / replace** — in each view, add one stored property

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
   (`setFocusHandler`, `setZoomHandler`, `setFindHandler`, `setFindStepHandler`). Passing it on the
   install but not the clear is worse than passing it on neither — the clear would then never match.

4. **New symbols it depends on** — `PaneHandlerOwner` (`Sources/Qnet/PaneChrome.swift`,
   `final class PaneHandlerOwner { init(); var id: ObjectIdentifier }`) and the `owner:` parameter
   on the four `FocusRouter.set…Handler` methods, all landed this round.

5. **Gate impact** — none. No contract string, no shortcut, no lint pattern.

6. **Verification** — toggle the pane off and on twice in quick succession (⌥⌘2 four times for
   Status), then press ⌘F and ⌥⌘=. Both must still act on that pane. Before the change the second
   toggle can leave both dead until the pane is toggled again.

7. **Priority** — P1.
