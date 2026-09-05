# W3 — Window layout and panes · round 5 integration requests

**None.**

Round 5 handed W3 no open blockers and no new verifier findings. Every
`IMPROVEMENTS.json` entry carrying a W3 token was already implemented in
round 4; this round was verification only, and no W3-owned file was
changed. There is therefore nothing for the integrator to apply on W3's
behalf.

## What was verified (built binary, driven through the AX API)

Build: `swift build --scratch-path /tmp/qnet-build-W3` — clean.
Lint: `DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` — passes.

1. **Detached-pane window title carries the document.** With the Shell
   torn out, the window is titled `Untitled — Shell`, and its first line
   inside the window is the pane's own `DSSectionHeader`, reading
   `Current directory /Users/nemecj/Dropbox/0_CODE/0_CLAUDE/2_QNET`. The
   two lines say different things (`PaneWindowController.windowTitle`).
2. **No two Window-menu items called "Shell".** With the Shell detached
   the Window menu reads `… Focus Results, Shell, ———, Untitled — Shell,
   Untitled (Unsaved network)` — the actions submenu and the window entry
   are now distinguishable. The `Menu("Shell")` submenu in
   `WorkspaceCommands.swift:258` was deliberately left named "Shell":
   the improvement offered rename-or-retitle, and retitling the window is
   the branch that shipped.
3. **Focus routing reaches a detached pane.** Window ▸ Focus Shell
   (⌃⌘3) with the Shell in its own window makes `Untitled — Shell` the
   main window (`AXMain` flips from the canvas window to it).
   *Caution for future verifiers:* the Focus items are correctly
   `.disabled(menuContext.anySheetPresented)`, so any `.documentModal`
   `DSPanelWindow` left open makes them dead. An early pass of this
   verification wrongly read that as a routing bug.
4. **`AppSettings.detachedPanes` is memoized** against its raw string
   (AppSettings.swift:618-627), not rebuilt per call, and the memo is a
   plain stored property — not `@Published` — so reading it inside a body
   evaluation cannot re-publish.
5. **`WindowFrameAutosave.savedFrame` clamps to one screen**, the one of
   largest intersection, falling back to `NSScreen.main`
   (ContentView.swift:2161-2184). No union rectangle remains.
6. **The Tools-palette detach exclusion is documented in its own right**
   (`PaneChrome.swift`, the `canBeDetached` comment), separately from the
   canvas's reason.
7. **The node and link parameter editors are panels, not sheets.**
   `grep -rn '\.sheet(' Sources/Qnet/*.swift` leaves exactly two live
   presentations — the SRBM export sheet (ContentView.swift:543) and the
   startup dependency check (QnetGUIApp.swift:731) — both deliberate.

## Note for whoever drives the app next

Five agents' Qnet builds were running at once during this round, and
`tell application "System Events" to tell process "Qnet"` binds to an
arbitrary one of them. Target the PID instead:

    tell application "System Events"
      tell (first application process whose unix id is <PID>) …

Reading `AXEnabled` on a menu item **without opening its menu first**
returns a stale value; open the menu bar item, delay, then read.
