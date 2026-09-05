# W3 — integration requests, round 3

Workstream: **W3 — Window layout, pane prominence and focus routing.**
Two requests, both in files W3 does not own. No round-1 or round-2 request is outstanding: a check
of today's source confirms W3-INT-1 (`SettingsRegistry.unindexedKeys`), W3-INT-8 (`owner:` tokens
in `StatusLog.swift`, `AIPaneView.swift`, `ResultsWorkspace.swift`) and W3-INT-9
(`CornerResizeOverlay.intersections`) all landed.

Round 3 shipped the workstream's last unbuilt mission item — **a pane can be torn out into a window
of its own** — so the new symbols below are what an integrator should expect to see referenced.

| Symbol | File | Declaration |
| --- | --- | --- |
| `FocusRouter.Pane.canBeDetached` | `Sources/Qnet/PaneChrome.swift` | `var canBeDetached: Bool` — false for `.canvas` and `.palette` only |
| `AppSettings.detachedPanes` | `Sources/Qnet/AppSettings.swift` | `var detachedPanes: Set<FocusRouter.Pane> { get set }`, backed by `@AppStorage("panes.detached")` |
| `AppSettings.isDetached(_:)` / `.setDetached(_:_:)` / `.toggleDetached(_:)` / `.hasDetachedPane` / `.reattachAllPanes()` | `Sources/Qnet/AppSettings.swift` | the sanitized read/write API for that set |
| `AppSettings.setPaneEnabled(_:_:)` | `Sources/Qnet/AppSettings.swift` | the write half of the existing `isPaneEnabled(_:)` |
| `AppSettings.Defaults.detachedPanes` | `Sources/Qnet/AppSettings.swift` | `static let detachedPanes = ""`, with its row in `defaultsByKey` |
| `PaneWindowController` | `Sources/Qnet/PaneDetachment.swift` (new) | `@MainActor enum` — `reconcile(…)`, `present(_:)` |
| `PaneWindowHost` | `Sources/Qnet/PaneDetachment.swift` (new) | invisible `View`, installed in `ContentView`'s background |
| `DetachedPaneContext` | `Sources/Qnet/PaneDetachment.swift` (new) | `@MainActor final class … : ObservableObject` |
| `PaneWindowItems` | `Sources/Qnet/WorkspaceCommands.swift` | `struct PaneWindowItems: View { @ObservedObject var appSettings: AppSettings }` |
| `WorkspaceCommands.reveal(_:appSettings:then:)` | `Sources/Qnet/WorkspaceCommands.swift` | `@MainActor static func`, `then` defaulted to `{}` — generalises the old `revealShell` |
| `TerminalPaneView` | `Sources/Qnet/ContentView.swift` | was `private struct`, now internal (the detached Shell builds the same view) |

`WorkspaceCommands.revealShell(appSettings:then:)` and `.focusShell(appSettings:)` keep their exact
signatures — `QnetGUIApp.swift:829` and `MenuKeyAliases` are unaffected — and `revealShell` is now a
one-line forward to `reveal(.shell, …)`.

**No new `DesignSystem.swift` token is needed.** `DS.Layout.Window.detachedPaneDefault` /
`.detachedPaneMin` and `DS.Symbol.detach` / `.reattach`, seeded before round 1 for exactly this, are
adopted as seeded. **No new keyboard shortcut** is added, so `QNET_MENU_AUDIT=1` has nothing new to
clear.

One thing to *not* undo: `SettingsRegistry.unindexedKeys` in `SettingsView.swift` already carries a
`"panes.detached"` line. It is now load-bearing — `AppSettings.defaultsByKey` gained that key this
round, and `SettingsRegistry.audit()` asserts in DEBUG on any stored key with neither a registry
row nor an excusal.

---

## W3-INT-11 — `reportBlocked` must reveal the Status pane the way everything else does

1. **ID** — `W3-INT-11`. Not attached to a numbered W3 task; it is the last caller in the app that
   still answers only one of the three questions `WorkspaceCommands.reveal` answers. Nothing W3
   shipped is broken without it. What is broken without it is W6's own promise, quoted in the
   comment two lines above the anchor: *"A report nobody can see is worse than the modal it
   replaced."* With another pane maximized (⌃⌘↩, shipped in round 1) the Status pane is not drawn,
   so setting `statusPaneVisible` changes nothing on screen and the report is silent — which is
   exactly the failure the helper was written for.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, `private func reportBlocked(_:detail:severity:on:)`.
   Anchor, verbatim from today's source, lines 8116–8118:

   ```swift
        if !appSettings.statusPaneVisible {
            withAnimation(DS.Motion.standard) { appSettings.statusPaneVisible = true }
        }
   ```

3. **Insert / replace** — replace those three lines with:

   ```swift
        WorkspaceCommands.reveal(.status, appSettings: appSettings)
   ```

   Leave the comment above them as it is; it still describes exactly what the line does. `reveal`
   animates the same way (`DS.Motion.standard`), is a no-op when the pane is already on screen, and
   additionally restores the layout when another pane has the whole window and brings the Status
   pane's own window forward when the user has torn it out. Its `then:` parameter is defaulted, so
   no trailing closure is needed.

4. **New symbols it depends on** — `WorkspaceCommands.reveal(_:appSettings:then:)`
   (`Sources/Qnet/WorkspaceCommands.swift`, `@MainActor static func reveal(_ pane: FocusRouter.Pane, appSettings: AppSettings, then action: @escaping @MainActor () -> Void = {})`),
   landed this round. Nothing else.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` does not grep this function (it
   asserts on the shell wrappers, the `commandWithCleanup` count and `${PIPESTATUS[0]}`); no
   shortcut; no `design_lint.sh` pattern — the replacement line contains no `Divider()`, no menu
   path and no ⌘-digit.

6. **Verification** — maximize the Results pane (click in it, then ⌃⌘↩), then run a method the
   current network is out of the domain of (e.g. a product-form method on a network with a
   re-entrant loop). Before the change nothing appears; after it the layout is restored and the
   refusal is in the Status log. Repeat with View ▸ Panes ▸ Separate Windows ▸ Status: the Status
   window comes forward.

7. **Priority** — P1.

---

## W3-INT-12 — changelog bullets for round 3

1. **ID** — `W3-INT-12`. Housekeeping. Nothing is broken without it, except that the feature adds
   two windows a user can lose a pane into, and the release notes are where the rule for getting it
   back is written down.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost entry, the one with
   `timestamp: nil` (line 43, `version: "0.90.02"`). Add to its `notes` list; do **not** create a
   new release entry, and do not touch `AppVersion.swift` (still 0.90.34). Round 1's and round 2's
   W3 bullets stay; these are additional. A natural place is immediately after the existing
   `"Any pane can take the whole window: …"` bullet, which is the same subject.

3. **Insert / replace** — add these two bullets:

   ```swift
                "Any pane can also leave the window entirely. View ▸ Panes ▸ Separate Windows — or the toolbar's Workspace menu — gives the Status, Inspector, Results, Shell or AI Assistant pane a window of its own, at its own size and position, remembered for the next launch. The main window's layout closes over the gap, and the pane keeps working exactly as it did: the Shell keeps its process and its scrollback, the Results workspace still follows the front tab, and ⌘F, ⌥⌘= and Window ▸ Focus still act on it. Closing the window puts the pane back, and so does the button at the end of its header; Return All Panes to the Main Window, in the same menu, brings back every one.",
                "Window ▸ Focus (⌃⌘0–6) now shows the pane it focuses in every case. With another pane maximized it used to switch a pane on that nothing was drawing, and move focus nowhere.",
   ```

4. **New symbols it depends on** — none.

5. **Gate impact** — `design_lint.sh` reads these strings: the menu paths use `▸` (required), and
   `⌃⌘0–6` / `⌥⌘=` are modifier-plus-key, so the stray-⌘-digit rule does not fire; the modifier
   orders ⌃⌘ and ⌥⌘ are the canonical ones. No TeX braces.

6. **Verification** — `validation/design_lint.sh` passes; Help ▸ Release Notes shows the two
   bullets under the in-development entry.

7. **Priority** — P1.
