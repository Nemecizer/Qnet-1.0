# W4 — round 5 integration requests

Workstream: **W4 — Movable windows, dialogs, settings**.
Assigned issue this round: **R9 residual** — the Settings window is resizable on the FIRST
open of a launch and fixed-size on every open after it.

## No integration requests this round

The residual is closed entirely inside W4-owned files:

- `Sources/Qnet/SettingsComponents.swift` — new
  `SettingsWindowTagger.keepResizable(_:)` plus the `resizeWatched` table; called from the
  existing `restoreFrameOnce(_:)`. Two stale doc comments corrected.
- `Sources/Qnet/SettingsView.swift` — one stale doc comment corrected (comment only, no code).

Nothing in `Sources/Qnet/QnetGUIApp.swift` (W6-owned) needs to change. In particular the
Settings scene's existing `.windowResizability(.contentMinSize)` at `QnetGUIApp.swift:1275`
is correct and should be left alone: measured on this OS it already leaves `contentMaxSize`
unbounded, and it is **not** what was dropping the resize behaviour.

## What the round-4 fix missed, for the record

`makeResizable` was reached only through `restoreFrameOnce`, which runs only from the
`NSViewRepresentable`'s attach hooks. Logging the style mask from every `NSWindow`
notification showed:

1. SwiftUI clears `.resizable` one run-loop pass after the window is first ordered front.
   `updateNSView` happens to fire just after and put it back — which is why the first open of
   a launch looked fixed.
2. SwiftUI clears it again as the window closes.
3. ⌘, does **not** build a new window. It re-shows the same `NSWindow` (identical
   `windowNumber`, 5879 across a close/reopen in the instrumented run), so the view never
   leaves that window, neither `viewDidMoveToWindow` nor `updateNSView` runs again, and
   nothing re-asserts the flag.

The fix observes `didBecomeKey` and `didUpdate` on the Settings window itself and re-asserts
the flag from there. The insert is guarded by a `styleMask.contains` test, so the steady-state
cost is one bit test per event-loop pass and it cannot ping-pong with SwiftUI.
