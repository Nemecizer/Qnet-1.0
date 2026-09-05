# W5 — integration requests, round 3

Workstream: **W5 — The interactive shell as the centrepiece**.
Files W5 changed this round: `Sources/Qnet/TerminalConsoleView.swift`,
`Sources/Qnet/TerminalModel.swift`.

Round 3 drew no blocking issues against W5's files. Both polish items were
addressed inside the two files above:

* the find bar is re-anchored to the pane's visible rectangle, inset
  `DS.Spacing.s`, wearing `DS.Radius.panel`;
* the line meter's double-width-glyph limitation is recorded at the site, with
  the shape of the fix, per the critic's own instruction not to reach for a
  width table.

Round 2's two requests (`W5-INT-4`, `W5-INT-5`) were both applied by the
integrator and verified present in today's source
(`WorkspaceCommands.revealShell` clears a soloed sibling;
`Changelog.swift:63` carries the amended clause). Nothing to re-raise.

One request follows, P1.

---

## W5-INT-6 — one changelog clause for the find bar's chrome

1. **ID** — `W5-INT-6`. Documents the round-3 polish fix
   *"SwiftTerm's find bar is flush against the right edge of the Shell pane
   and reads as clipped"*. No task depends on it; the fix itself is shipped
   and needs nothing from another file.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift`, the topmost
   (`timestamp: nil`) entry. Anchor line, verbatim from today's source
   (line 61):

   ```swift
                   "The Shell behaves like a terminal. ⌘F opens its own find bar over the scrollback instead of the canvas’s Find Node prompt, ⌘G and ⇧⌘G walk the matches, ⌘C copies the shell selection — SwiftTerm’s view is not a text field, so Edit ▸ Copy could not see a selection there at all — and a right-click offers Copy, Paste, Select All, Find in Shell…, Scroll to Bottom and Clear Shell, with the same titles those commands carry in the pane header and in Window ▸ Shell.",
   ```

3. **Insert / replace** — replace that one string with:

   ```swift
                   "The Shell behaves like a terminal. ⌘F opens its own find bar over the scrollback instead of the canvas’s Find Node prompt, ⌘G and ⇧⌘G walk the matches, ⌘C copies the shell selection — SwiftTerm’s view is not a text field, so Edit ▸ Copy could not see a selection there at all — and a right-click offers Copy, Paste, Select All, Find in Shell…, Scroll to Bottom and Clear Shell, with the same titles those commands carry in the pane header and in Window ▸ Shell. The find bar sits inside the pane rather than against its edge: it used to be pinned to the terminal, which runs off to the right once wide output has made the Shell scrollable, so its close button and its Aa / .* / Word toggles were the first things the pane clipped away.",
   ```

   The only change is the appended final sentence. Curly quotes and the ▸
   separator match the surrounding entries; no ⌘-digit is introduced.

4. **New symbols it depends on** — none. The behaviour it describes is
   `TerminalHostView.adoptFindBar()` / `positionFindBar()`
   (`Sources/Qnet/TerminalConsoleView.swift`, `func adoptFindBar()`), called
   from `TerminalModel.showFind()`; both are W5-owned and already in the tree.

5. **Gate impact** — none. `validation/gui_runtime_contracts.sh` reads only
   `QnetGUIApp.swift`, `SRBMExporter.swift` and `ctmc_dtandem.py`. No
   `.keyboardShortcut` is added, so `QNET_MENU_AUDIT=1` has nothing new to
   clear. No `DSEmptyState` title, no `Divider()`, no `→`, no bare ⌘-digit,
   no TeX braces — `validation/design_lint.sh` passes with this applied.
   (`Aa`, `.*` and `Word` are the vendored toggles' own labels, quoted as
   prose; the lint's symbol and namespace rules do not match them.)

6. **Verification** — `swift build && DS_SKIP_CONTRAST=1 ./validation/design_lint.sh`,
   then Help ▸ Release Notes shows the amended bullet under the
   in-development entry.

7. **Priority** — **P1**.

---

## Not requested, deliberately

- **No `Vendor/SwiftTerm` change.** The critic's evidence also noted that the
  find bar shows no match count. There is none to show: the vendored
  `TerminalFindBarView` has a search field, prev/next, three option toggles
  and a close button, and `MacTerminalView.findNext(_:options:)` reports a
  hit as a `Bool` — a count would mean a new search API in the vendored
  copy, which is not W5's to fork and is out of proportion to the gain. The
  close button and the toggles the critic could not see are visible now that
  the bar is no longer clipped. Recorded here so a later round does not
  re-derive it.
- **No new DS token.** `DS.Spacing.s` and `DS.Radius.panel` already say
  exactly what the fix needed; `DesignSystem.swift` is untouched.
- **No `ContentView.swift` change.** The find bar is created and positioned
  entirely inside `TerminalHostView`, which W5 owns; the pane header's
  "Find in Shell" button and the `FocusRouter` find handler already route
  through `TerminalModel.showFind()`, which is where the re-anchor is
  triggered. Nothing in W3's file needs to know.
