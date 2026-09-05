# GUIKit — a macOS SwiftUI GUI framework

This directory is the GUI layer of **Qnet**, extracted so a new macOS SwiftUI app can inherit its
look, feel, components, window behaviour, accessibility contract, and — most importantly — the
**lint that keeps all of it true**.

It is 8,300 lines across 21 files. It compiles on its own (`swift build` here), and its own design
lint passes on it (`./Validation/design_lint.sh`, 40 checks including a computed WCAG contrast
gate). Both facts are load-bearing: a framework that has never been built apart from its parent app
is a claim, not a component.

**Drop it in a new project and you start with a mature design system on day one instead of month
six.** What you do not get is Qnet's domain — no canvas, no solvers, no queueing theory. Those were
deliberately left behind.

---

## Table of contents

1. [Quick start](#1-quick-start)
2. [What you get, file by file](#2-what-you-get-file-by-file)
3. [The five hard rules](#3-the-five-hard-rules)
4. [The token system](#4-the-token-system)
5. [Component catalogue](#5-component-catalogue)
6. [Windows, panels and panes](#6-windows-panels-and-panes)
7. [The accessibility contract](#7-the-accessibility-contract)
8. [The lint — your most valuable inheritance](#8-the-lint--your-most-valuable-inheritance)
9. [Host hooks: adapting the kit to your domain](#9-host-hooks-adapting-the-kit-to-your-domain)
10. [Patterns documented but not shipped as code](#10-patterns-documented-but-not-shipped-as-code)
11. [Using GUIKit as a package dependency](#11-using-guikit-as-a-package-dependency)
12. [Hard-won lessons](#12-hard-won-lessons)

---

## 1. Quick start

### The intended path: copy the sources in

```sh
cp -R GUIKit/Sources/GUIKit/*.swift  MyApp/Sources/MyApp/DesignSystem/
mkdir -p MyApp/Validation
cp -R GUIKit/Validation/*            MyApp/Validation/
```

Everything is `internal`, which is exactly right inside one module: no `public` annotations, no
re-exports, no access-control churn. This is the "minimal rework" path.

Then, in your `App`:

```swift
import SwiftUI

@main
struct MyApp: App {
    init() {
        // 1. Name the app. This namespaces window autosave keys and AppKit
        //    window identifiers. Set it BEFORE any window exists — the value
        //    lands in UserDefaults keys, and changing it later orphans every
        //    frame your users have positioned.
        GUIKitConfig.applicationName = "Cartograph"

        // 2. Optional: wire help, so `helpTopic:` on any sheet grows a ? button.
        HelpPresenter.show = { topic in MyHelpWindow.show(topic) }

        // 3. Optional: your own categorical palette and naming.
        SeriesPalette.labelProvider = { "Layer \($0 + 1)" }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Point the lint at your sources (one line in `Validation/design_lint.sh`):

```sh
SRC="$ROOT/Sources/MyApp/DesignSystem"
```

and run it. It should pass immediately on the kit's own files; from then on it fails the moment a
view invents a literal.

### See everything before you write anything

`DSGalleryView` renders every token and every component side by side — light, dark, and light at
Accessibility text size — with the measured contrast ratio beside each colour. Wire it to a debug
flag and open it once:

```swift
if CommandLine.arguments.contains("--ds-gallery") {
    DSGalleryWindow.show()
}
```

This is the fastest way to learn the system, and the eye-check after any token change. The lint is
the gate; the gallery is the eye.

---

## 2. What you get, file by file

| File | Lines | What it is |
|---|---:|---|
| `DesignSystem.swift` | 2,138 | **The one token namespace.** Colour, type, spacing, radius, stroke, motion, layout, symbols, number formatting, glossary. The only file allowed to define visual constants. |
| `DSFields.swift` | 1,381 | Text, numeric and range fields with validation, units, reserved message slots, glossary buttons. |
| `WindowSupport.swift` | 613 | Auxiliary windows, main-window registry, menu context, shortcut audit, build stamp. |
| `DSControls.swift` | 460 | Inspector rows, labelled sliders, segmented and menu pickers, glossary slots. |
| `DSButtons.swift` | 447 | Icon buttons, toggles, menus, toolbar and palette button styles. |
| `DSPanelWindow.swift` | 413 | **Movable, resizable dialog panels** hosting SwiftUI in a real `NSWindow`. |
| `DSGallery.swift` | 770 | The living specimen sheet for every token and component. |
| `DSSheet.swift` | 371 | Sheet scaffold: header, glyph, footer, validation, help linkage. |
| `DSBadge.swift` | 353 | Pills, badges, series chips, shortcut keycaps. |
| `KeyboardShortcutReference.swift` | 278 | One source of truth for shortcuts; generates a printable reference. |
| `SettingsWindowTagger.swift` | 205 | Recovers the `NSWindow` SwiftUI builds for the Settings scene. |
| `WindowFrameAutosave.swift` | 191 | Frame persistence that clamps to currently-visible screens. |
| `DSEmptyState.swift` | 159 | Empty states with an optional primary action. |
| `DSSectionHeader.swift` | 132 | Section headers with accessory slots. |
| `DSPopover.swift` | 128 | Sized popovers. |
| `ConfirmAlert.swift` | 103 | Confirmation alerts with a consistent voice. |
| `GUIKitConfig.swift` | 62 | Host configuration: app name, identifier namespace, frame keys. |
| `HelpTopic.swift` | 62 | Generic help linkage seam. |
| `SeriesPalette.swift` | 59 | Categorical colour + naming for peer series. |
| `DSHelpButton.swift` | 52 | The `?` button, AppKit-backed for correct focus behaviour. |
| `SearchHighlight.swift` | 28 | Match highlighting for search results. |

Plus `Validation/design_lint.sh` (40 checks) and `Validation/ds_contrast.swift` (computed WCAG
contrast gate).

---

## 3. The five hard rules

These are the whole point. A design system is not a folder of components — it is a set of things
you have agreed **not** to do, plus a machine that checks.

### Rule 1 — No font literals outside `DesignSystem.swift`

```swift
.font(.system(size: 13))     // ✗ lint failure
.font(.callout)              // ✗ lint failure
.font(DS.Font.body)          // ✓
```

Why: a point size does not scale with Dynamic Type, so a hard-coded `13` is an accessibility bug
that looks fine on your Mac. The sanctioned exceptions live in `DesignSystem.swift` itself:
user-adjustable monospace panes, canvas labels that scale with zoom, and glyphs inscribed in a
circle of a known size.

### Rule 2 — No colour literals, no `.opacity()` on a named colour

```swift
Color.blue.opacity(0.1)             // ✗
.foregroundStyle(.secondary)        // ✗
.background(.bar)                   // ✗ (no materials anywhere)
Color.accentColor                   // ✗
DS.Color.tintFill(DS.Color.info)    // ✓
DS.Color.textSecondary              // ✓
DS.Color.surface                    // ✓
```

There are exactly **four** signal colours: `success` (green), `warning` (orange — and nothing else
in the app is orange), `danger` (red), `info` (blue). Text on a signal wash uses the `*Text`
variant — `DS.Color.dangerText`, never raw `danger`, because the raw signal measures 3.57:1 as text
in light mode and fails WCAG AA. The lint enforces this specific mistake because it was made
repeatedly.

### Rule 3 — Never re-implement a DS component

If a component is missing a feature, extend the component. Do not copy it into a view file and
tweak. The lint carries a list of retired duplicate names and fails if one reappears; that list
exists because in this codebase's history, `PaneHeader`, `PaneIconButton`, `PaneBadge`, `FlagPill`,
`SettingsNumericField` and a dozen others were each a private re-draw of something that already
existed.

### Rule 4 — No stroke, radius or frame literals

```swift
.cornerRadius(8)                          // ✗
RoundedRectangle(cornerRadius: DS.Radius.panel)   // ✓
.stroke(lineWidth: 1)                     // ✗
.stroke(lineWidth: DS.Stroke.hairline)    // ✓
.frame(minWidth: 700)                     // ✗
.frame(minWidth: DS.Layout.Window.mainMinWidth)   // ✓
```

> A magic number is a token nobody wrote down yet.

### Rule 5 — Honour the accessibility switches through the environment

Not as static flags. See [§7](#7-the-accessibility-contract) — this is the rule most often got
wrong, and the reason is subtle enough to deserve its own section.

---

## 4. The token system

Everything lives under `DS`. One namespace, one file.

### Spacing — an 8-point grid with two half-steps

```
DS.Spacing.xxs = 2    xs = 4    s = 8    m = 12    l = 16    xl = 24    xxl = 32
```

Use `gap`-style layout (`VStack(spacing:)`, `HStack(spacing:)`, `Grid`) rather than per-element
margins, which collapse and double unpredictably.

### Radius — four, by role

```
DS.Radius.keycap = 4    control = 6    panel = 8    sheet = 12    swatch = 2
```

Radius encodes *what kind of object this is*, not decoration. A control and a panel differ because
they are different things, not because a designer liked the curve.

### Stroke — including contrast-adaptive spellings

```
DS.Stroke.hairline = 1        hairlineFaint = 0.5     hairlineBold = 1.5
DS.Stroke.selectionRing = 1.5 selection = 2           focusRing = 3

DS.Stroke.hairline(a11y.contrast)       // steps up under Increase Contrast
DS.Stroke.hairlineFaint(a11y.contrast)
```

Structural strokes must use the **adaptive** form. A 0.5pt hairline vanishes for a user who has
turned Increase Contrast on precisely because they cannot see 0.5pt hairlines. The lint checks this.

### Motion — never build an `Animation` yourself

```
DS.Motion.fast = 0.15    normal = 0.25    glide = 0.20
DS.Motion.quick          // Animation?, nil under Reduce Motion
DS.Motion.standard
DS.Motion.standardSettleDelay   // 0 under Reduce Motion
DS.Motion.animateAppKit(_:_:)   // NSAnimationContext, Reduce-Motion aware
```

```swift
.dsAnimation(DS.Motion.quick, value: isExpanded)   // ✓ reads the environment
.animation(.easeInOut(duration: 0.12), value: x)   // ✗ cannot honour Reduce Motion
```

A curve built at a call site cannot honour Reduce Motion; `.dsAnimation` reads
`\.accessibilityReduceMotion` and drops the animation live, without a relaunch.

### Colour

Semantic roles, not names: `surface`, `contentWell`, `separator`, `textPrimary`, `textSecondary`,
`textTertiary`, `accent`, `accentStroke`, `hoverFill`, `selectionFill`, plus the four signals and
their `*Text` variants. Helpers: `tintFill(_:)`, `dimmed(_:_:)`, `controlBorder(_:)`.

### Number formatting

```swift
DS.Number.format(value, significantDigits: 5)   // derived readouts
DS.Number.display(value, decimals: 3)           // fixed fraction length
DS.Number.fieldText(value)                      // round-trips through parse()
DS.Number.parse(text)                           // locale-tolerant, accepts "0,5" and "1e-3"
```

Two different rules on purpose: a value the user typed keeps significant-digit precision; a computed
result shown beside other results is pinned to one fraction length so columns line up digit for
digit. Conflating them is why "one number, four precisions, one screen" was a real bug here.

### Glossary

A `?` button that defines a jargon-only label, in a **reserved trailing column** so fields with and
without a definition keep the same trailing edge:

```swift
DSNumericField(label: "Tolerance", value: $tol,
               range: 0...1, glossary: DS.Glossary.tolerance)
```

The kit ships four illustrative entries. **Replace them with your own.** The lint requires every
entry to be referenced by at least one control — an orphaned definition reads as coverage that
isn't there.

---

## 5. Component catalogue

### Fields

```swift
DSTextField(label: "Name", text: $name, help: "Shown in the sidebar")

DSNumericField(label: "Sample rate", value: $rate, unit: "Hz",
               range: 1...48_000, help: "Measurements per second",
               glossary: DS.Glossary.sampleRate)

DSRangeFields(label: "Bounds", lower: $lo, upper: $hi, range: 0...100)

DSTextArea(label: "Notes", text: $notes, minLines: 3, maxLines: 8, monospaced: true)

DSSearchField(text: $query, prompt: "Search")
```

Fields validate live (`DSValidationMode`), reserve a message slot so the form does not reflow when
an error appears, and keep units in their own column so a stack of fields aligns.

### Buttons

```swift
DSIconButton(systemImage: DS.Symbol.clearPane, help: "Clear") { clear() }
DSIconToggle(systemImage: DS.Symbol.inspector, isOn: $showInspector, help: "Inspector")
DSIconMenu(systemImage: DS.Symbol.paneSplit, help: "Layout") { /* menu items */ }
.buttonStyle(DSToolbarButtonStyle())
```

### Structure

```swift
DSSectionHeader("Appearance") { DSHelpButton(...) }
DSRule()                                   // never a bare Divider() outside a menu
DSInspectorRow(label: "Servers") { ... }
DSEmptyState(systemImage: DS.Symbol.grid,
             title: "No Documents Yet",        // Title Case — the lint checks
             message: "Create one to get started.",
             actionTitle: "New Document") { create() }
```

### Sheets and panels

```swift
DSSheet(title: "Export Options",
        helpTopic: .exportOptions,
        confirmTitle: "Export",
        canConfirm: isValid,
        onCancel: dismiss, onConfirm: run) {
    // your form
}
```

### Badges

```swift
DSBadge(text: "Beta", tint: DS.Color.infoText, emphasis: .tinted)
DSPill(title: "Warnings", systemImage: DS.Symbol.statusLog, isOn: true,
       tint: DS.Color.warningText, badge: 3,
       help: "Show warnings", inactiveHelp: "No warnings") { EmptyView() }
SeriesChip(classIndex: i)      // colour + distinct SHAPE under Differentiate Without Color
ShortcutBadge(key: "V")
```

---

## 6. Windows, panels and panes

This is the part hardest to rebuild from scratch, because SwiftUI does not expose it.

### Movable dialog panels

SwiftUI's `.sheet` is pinned to its parent window: the user cannot move it, cannot see what is
behind it, and cannot work with it open. For a form whose values the user wants to check against the
document, that is the wrong container.

```swift
DSPanelWindow.present(
    id: "export-options",
    title: "Export Options",
    size: .regular,            // .compact | .regular | .tall | .wide
    modality: .modeless,       // or .documentModal
    escapeCloses: true,
    remembersFrame: true
) {
    ExportOptionsView()
}
```

You get a real `NSWindow`: movable, resizable, Escape-closing, frame remembered per id, and calling
`present` twice raises the existing window rather than spawning a duplicate. `DSPanelCloseGuard`
prevents the stuck "a dialog is up" flag that otherwise disables your whole menu bar if a panel
closes by an unexpected path.

### Frame persistence that actually restores

```swift
ContentView().background(WindowFrameAutosave(name: "Main"))
```

`setFrameAutosaveName` alone does **not** restore — you must also call `setFrameUsingName`, and if
anything calls `center()` afterwards it silently undoes the restore. Both mistakes were live in this
codebase. `WindowFrameAutosave` does it correctly and additionally **clamps a restored frame to the
union of currently visible screens**, so a window saved on a monitor you have since unplugged comes
back somewhere reachable instead of 3,000 points off-screen.

### Auxiliary windows

```swift
AuxiliaryWindow.make(id: "help", title: "Help",
                     contentSize: DS.Layout.Window.auxContent,
                     minSize: DS.Layout.Window.auxMin) { HelpView() }
```

Each carries an identifier prefixed `<app>.aux.` so File ▸ Close Window can tell an auxiliary window
from a document window.

### The Settings window

SwiftUI hands you no reference to the `NSWindow` it builds for the `Settings` scene, so anything
window-scoped there has nothing to hold. `SettingsWindowTagger` recovers it by identity when the
pane appears:

```swift
Settings { SettingsView().background(SettingsWindowTagger()) }
```

Then `MenuContext.settingsWindowIsKey()` works, and the Settings frame persists like every
other window.

---

## 7. The accessibility contract

macOS has four switches that change how a view must draw. Honour them **through the environment**,
not through cached flags:

```swift
struct MyView: View {
    @DSAccessibility private var a11y      // ← the one correct way

    var body: some View {
        Text("Ready")
            .foregroundStyle(a11y.differentiate ? DS.Color.textPrimary : DS.Color.successText)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .stroke(DS.Color.separator(a11y.contrast),
                        lineWidth: DS.Stroke.hairline(a11y.contrast)))
            .dsAnimation(DS.Motion.quick, value: isReady)
    }
}
```

`@DSAccessibility` bundles `colorSchemeContrast`, `accessibilityReduceMotion`,
`accessibilityDifferentiateWithoutColor` and the kit's own override into one property wrapper.

**Why the environment and not a static `Bool`:** SwiftUI invalidates every `body` that reads an
environment value when that value changes. A static flag read inside `body` creates no dependency,
so the view only picks up the new setting when something unrelated happens to rebuild it. A running
app must respond to a change in System Settings *immediately*. This distinction cost this codebase a
round to discover, which is why the lint bans the hand-rolled reads outright.

- **Reduce Motion** — `.dsAnimation(DS.Motion.quick, value:)`, `DS.Motion.standardSettleDelay`.
- **Increase Contrast** — pass `a11y.contrast` to `DS.Stroke.hairline(_:)`, `DS.Color.separator(_:)`.
- **Differentiate Without Color** — never let colour be the *only* signal. `SeriesChip` switches
  from a filled circle to a distinct per-series **shape**; do the same for any status indicator.
- **Dynamic Type** — never a point size. Check your sheets at Accessibility sizes; fixed-height
  containers clip there, which is invisible at default size.

---

## 8. The lint — your most valuable inheritance

```sh
./Validation/design_lint.sh          # 40 checks + computed WCAG contrast
DS_SKIP_CONTRAST=1 ./Validation/design_lint.sh   # skip the compiled contrast step
```

It strips comments and string literals first — so help text mentioning `Color.red` cannot
false-positive — then greps every file except `DesignSystem.swift` for the forbidden patterns, and
finally compiles `ds_contrast.swift`, which **parses the colour constants out of `DesignSystem.swift`
rather than mirroring them** and measures every text-on-colour pair against WCAG AA in both
appearances. A gate that mirrors its constants drifts; one that parses them cannot.

Wire it into your build so it cannot be skipped:

```sh
# at the top of your build script, before any compiler runs
./Validation/design_lint.sh || exit 1
```

A sampling of what it catches, each of which was a real bug here:

- a signal colour used as text (`.foregroundStyle(DS.Color.danger)` → `dangerText`)
- a sentence-case empty-state title (`"No status entries"` → `"No Status Entries"`)
- a bare `Divider()` outside a menu builder (→ `DSRule()`); menu scope is tracked by brace depth
- a menu path written with `→` instead of `▸`
- non-adaptive strokes in a `Canvas` draw closure
- a hand-rolled `NSAnimationContext` block
- a resurrected token namespace (`PaneDS`, `QnetSpacing`, …)
- a `DS.Glossary` entry no control uses
- TeX braces in user-facing text (`n^{2d}` → `n²ᵈ`)

**Never weaken it to make a change pass.** The one legitimate edit is *tightening* an assertion when
you deliberately rewrite the line it pins.

---

## 9. Host hooks: adapting the kit to your domain

Four seams, all optional, all set once at launch:

```swift
GUIKitConfig.applicationName = "Cartograph"     // window keys and identifiers
HelpPresenter.show = { topic in ... }           // makes every helpTopic: live
SeriesPalette.colorProvider = { myHues[$0] }    // your categorical palette
SeriesPalette.labelProvider = { "Layer \($0+1)" }
```

Then replace the four illustrative `DS.Glossary` entries with your own vocabulary, and add your
domain's symbols to `DS.Symbol`. Both live in `DesignSystem.swift` — which remains the only file
that defines tokens, including yours.

If a help presenter is not installed, sheets with a `helpTopic:` simply omit the `?` button rather
than showing one that does nothing. A control that visibly does nothing is worse than an absent one.

---

## 10. Patterns documented but not shipped as code

These were too entangled with Qnet's domain to lift honestly, but the *patterns* are the valuable
part and they are cheap to rebuild once you know the shape.

### Embedded terminal

Qnet embeds [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and runs subprocesses in it. The
three things that were hard:

1. **Cache the host `NSView` and re-parent it.** If the SwiftUI wrapper recreates the terminal view
   on layout change, the shell process dies every time the user drags a splitter. Hold one AppKit
   view in the model; the SwiftUI representable only re-parents it.
2. **Cancel the process *group*, and escalate.** `SIGINT` → wait 1.5s → `SIGTERM` → wait 1.5s →
   `SIGKILL`, sent to the wrapper's process group (never your own). Re-read the pid for a second
   after launch, because the shell may not have forked yet.
3. **Write the completion file from an `EXIT` trap**, not as the last line of the script, and read
   the status as `${PIPESTATUS[0]}` — otherwise a cancelled or crashed run leaves no record and the
   UI waits forever.

And one product lesson: **a run the user stopped is not a failure.** Key the verdict off "did the
user press Stop for this run", not off an exit-code whitelist — which signal wins the escalation
race is nondeterministic, and reporting a deliberate Stop as `failed (exit 129)` reads as a crash.

### Pane detachment

Panes that tear out into their own window and re-dock. The workable approach: keep one *stable*
split tree where optional panes are conditionally present rather than re-parented, and give the
detached window the same view bound to the same model object. Re-parenting the split tree is what
loses scroll position, focus and — if a terminal is involved — the child process.

### Status log

An append-only, severity-tagged, searchable, exportable event log beside the main content. Cheap to
build, and it is the difference between "it didn't work" and a bug report you can act on.

### Menu context and focus routing

`MenuContext` / `MenuContextRegistry` (shipped) track which pane has focus so `⌘F` and `⌘C` route to the right
place. The trap: `NSApp.sendAction(...)` returns `true` whenever *anything* in the responder chain
claims the selector — including when a text input context is merely live with no field focused. Use
your own focus state as the test, not `sendAction`'s return value. Getting this wrong silently broke
`⌘Z` here: the menu item was enabled, and did nothing.

---

## 11. Using GUIKit as a package dependency

Copying the sources is the intended path. If you would rather depend on the package:

```swift
dependencies: [.package(path: "../GUIKit")],
targets: [.target(name: "MyApp", dependencies: ["GUIKit"])]
```

Then every symbol your app touches needs `public`, and the property wrappers and view modifiers need
`public` initialisers. Budget an hour of mechanical annotation. The kit is deliberately shipped
`internal` because for a single-app GUI layer, the module boundary buys you nothing and costs you
that hour plus every future symbol.

---

## 12. Hard-won lessons

Things this GUI learned the expensive way. They are worth more than the code.

1. **One token namespace, one file, enforced by a machine.** Not a convention — a gate wired into
   the build. Conventions decay silently; a failing build does not.

2. **The gate must not mirror what it checks.** `ds_contrast.swift` parses its constants out of
   `DesignSystem.swift`. A gate holding its own copy drifts from the thing it claims to measure, and
   then reports success about a file it is no longer reading.

3. **Source-text contracts are worth writing.** Pinning exact strings and counts in critical code
   ("exactly 8 runners use the cancellation-safe wrapper") catches the deletion a type checker
   cannot see. Rewording a pinned line then becomes a deliberate act.

4. **A control that visibly does nothing is worse than an absent one.** An enabled menu item whose
   handler returns early is the worst UI state there is: it teaches the user their action worked.

5. **Escape hatches from a mode must be exhaustive.** A sticky mode needs every exit enumerated —
   Escape, tool change, window deactivation, tab switch, undo. One missed path strands the user.

6. **Automate the accessibility check you will otherwise skip.** Nobody re-checks 40 colour pairs at
   Accessibility text size by hand on a Friday. The computed contrast gate does it every build.

7. **Test the artifact the user receives.** Verify the signature *after* archiving and re-expanding,
   not just after building. The build output and the download are different artifacts.

8. **Beware `cmd | grep -q` under `set -o pipefail`.** `grep -q` exits on first match, the producer
   takes `SIGPIPE`, and the pipeline reports failure. It is a race on the pipe buffer, so it passes
   in isolation and fails in the script — and it silently inverted a "is this safely signed?" check
   here. Capture first, match second.

9. **Only a real click proves a GUI fix.** Six review rounds found defects invisible to any
   source-text grep or headless unit check: a menu naming the wrong action, `⌘Z` doing nothing, a
   Stop that announced itself as a crash. If you build on this kit, budget for a scripted UI harness
   early; the return is obvious in hindsight.

10. **The residue is texture, and texture is the whole difference.** None of the last round's fixes
    were algorithmic — four stray spaces in a timing line, a mislabelled menu, a cancel reported as
    a failure. Individually trivial; collectively the exact difference between a research tool and a
    product.
