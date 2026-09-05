# Round 6 — W4 integration notes

W4's round-6 defect was fixed entirely inside a W4-owned file
(`Sources/Qnet/WindowSupport.swift`, listed first in W4's `owned_files`). Nothing is
requested of another workstream. This note exists so the integrator knows what moved, why the
change lives in `MenuContext` rather than in `QnetCommands`, and what could tighten it later.

---

## What was wrong — Edit ▸ Undo lied while a Settings field was being typed into

`QnetCommands.undoRouting(redo:)` resolves the item's **title**, its **enablement** and its
**action** from live AppKit state: `NSApp.keyWindow?.firstResponder`, and that field editor's
`UndoManager` (`canUndo` / `undoActionName`). None of that is observable. A SwiftUI `Commands`
body is re-evaluated only when one of the things it observes publishes, so the resolved answer was
only ever as fresh as the last change to `editor`, `AppSettings`, `SettingsSearchModel`,
`FocusRouter`, `HelpWindowModel`, `TerminalModel` or `MenuContext.textInputHasFocus`.

That is *invisible* wherever a text field writes straight through to an observed model — a node
name, the Status pane's search box, and (by luck) the Settings **search** field, which publishes
`SettingsSearchModel.shared` on every keystroke. It fails wherever a field keeps a local `@State`
draft and commits on Return or focus loss, which is **every `DSNumericField`** — hence every
numeric row in Settings — and the AI pane's API-key field.

Measured on the round-6 tree before the fix (debug build, Settings ▸ Discrete-Event Simulation ▸
Replications, read through System Events AX):

| step | Edit ▸ Undo read | what ⌘Z actually did |
| --- | --- | --- |
| canvas stack holds "Change Buffer Mode", field focused, nothing typed | `Undo Change Buffer Mode`, enabled | undoes the buffer mode — correct |
| type `9` (field shows `950 runs`) | **still `Undo Change Buffer Mode`, enabled** | **undid the typing** (`950` → `50`); buffer mode untouched |
| canvas stack empty, type `9` | **`Undo`, disabled** | **nothing — the first ⌘Z after typing was swallowed**; the item only woke up afterwards, so the *second* ⌘Z worked |

So both halves of the contract were broken in the Settings window: the item named a canvas step
while the keystroke edited text, and with an empty canvas stack it was greyed out while the
focused field had a whole word to take back.

## The fix

`MenuContext` now also fingerprints the focused text control's own undo stack and republishes when
it changes:

* new `@Published private(set) var textUndoState` — **nothing reads the string; publishing it is
  the entire point.** It must not be deleted as dead state, and the doc comment on it says so.
* `refreshFocus()` computes it from `focusedTextUndoState()`, which uses the *same* predicate and
  the *same* undo manager `QnetCommands` routes ⌘Z through (`firstResponder as? NSText`, then
  `NSResponder.undoManager`), so a change it notices is exactly a change that would alter what the
  menu says or does.

`refreshFocus()` already ran after every key event (the deferred local event monitor), so no new
observer, notification or timer was added. The fingerprint changes on the first character typed
and on each undo/redo, and *not* on the second, third or hundredth character — one string compare
per key event, and no extra menu rebuilds.

Verified after the fix, same build, same steps: typing `9` → `Undo Typing`, enabled; ⌘Z takes the
typing back on the **first** press; the item then falls back to `Undo Change Buffer Mode` /
`Redo Typing`. Retyping after an undo behaves the same. Regression check in the main window: a
canvas step still reads `Undo Change Buffer Mode`, and typing in the Status pane's search field
still reads `Undo Typing`.

## Why not in `QnetCommands.swift`

`QnetCommands.swift` is W5's file, and W4 did not touch it. The change is also better placed where
it landed: `MenuContext` is already the app's "published state the menu bar needs that does not
live on a model", and this is one more such fact. It fixes the staleness for *every* menu item that
reads the focused field editor, not only Edit ▸ Undo.

**A stricter fix, for a later round, belongs to W5**: have `undoRouting(redo:)` read the routing
from `menuContext` explicitly rather than from free-standing AppKit calls, so the compiler ties the
title to something observed. That is a `QnetCommands.swift` change and was deliberately not made
here.

## Suggested contract (NOT added — `validation/` untouched)

`validation/gui_runtime_contracts.sh` greps only `QnetGUIApp.swift`, `SRBMExporter.swift` and
`ctmc_dtandem.py`, and contains no occurrence of `textUndoState`, `focusedTextUndoState` or
`undoRouting`. A one-line source-text contract asserting that `MenuContext.refreshFocus()` still
publishes `textUndoState` would stop the property being deleted as unused. W4 did not add it: the
file is not W4's, and this is the close-out round.

---

## Second item — off-screen restored frames: **already correct, no change made**

Asked to confirm that a Settings window (and a `DSPanelWindow` panel) restored from a frame saved
on a now-disconnected display still comes back reachable. It does, and by the same code the main
window uses: `SettingsWindowTagger.restoreFrameOnce` (SettingsComponents.swift:310) and
`AuxiliaryWindow.make` (WindowSupport.swift:223) both read through
`WindowFrameAutosave.savedFrame(named:)`, which clamps onto the screen the saved rect overlaps most
and onto `NSScreen.main` when it overlaps none.

Simulated by writing absurd frames into the scratch defaults domain and relaunching. Screen
`visibleFrame = (0, 52, 1512, 896)`, `frame = (0, 0, 1512, 982)`:

| key | saved (Cocoa) | restored (Cocoa) | clamp prediction |
| --- | --- | --- | --- |
| `WindowFrame.BNETMainWindow` | `{{6000, 4000}, {1500, 895}}` | `{{12, 53}, …}` | `{{12, 53}}` ✓ |
| `WindowFrame.QnetSettingsWindow` | `{{4000, 3000}, {900, 608}}` | `{{612, 340}, …}` | `{{612, 340}}` ✓ |
| `WindowFrame.QnetSettingsWindow` | `{{9000, -9000}, {900, 608}}` | `{{612, 52}, …}` | `{{612, 52}}` ✓ |
| `WindowFrame.QnetPanel.archetype-gallery` | `{{-4000, -3000}, {640, 656}}` | `{{0, 53}, …}` | `{{0, 52}}` ✓ |

Every window came back fully on screen with its title bar draggable. One observation worth
recording rather than acting on: in the one run where the *parent* canvas window had itself just
been clamped from an absurd frame, the document-modal panel added to it as a child landed at
`{{296, 136}}` instead of the clamped `{{0, 52}}` — still fully on screen, and AppKit's own
child-window constraining, not the app's restore. Reproduced with a sane parent frame it lands
exactly on the prediction. No fix warranted.
