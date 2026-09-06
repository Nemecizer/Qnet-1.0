import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Qnet design system — adoption guide
// ─────────────────────────────────────────────────────────────────────────────
//
// `DS` is the ONLY token namespace in the app, and this is the ONLY file it
// lives in. Every visual constant used by the SwiftUI layer is here; views
// compose tokens and DS components, they never invent literals. Former local
// namespaces (`EditorDesign`, `PaneDS`, `QnetSpacing` / `QnetRadius` /
// `QnetMeasure`) and the two files that extended `DS.Layout` from outside
// (`WorkspaceTokens.swift`, `EditingComponents.swift`) were folded in and
// deleted — do not resurrect them, and do not write `extension DS…` in
// another file. `validation/design_lint.sh` strips comments and string
// literals, then greps every other Swift file for the forbidden patterns
// below and runs `validation/ds_contrast.swift`; `test.sh` runs the lint as
// its first step and fails the run on a violation.
//
// See it, don't imagine it
// ------------------------
//   Qnet --ds-gallery      opens DSGallery.swift: every token and every DS
//                          component rendered side by side in light, dark,
//                          and light at Accessibility 1 text size, with the
//                          measured contrast ratio beside each colour. Open
//                          it after any token change — it is the eye test;
//                          `validation/ds_contrast.swift` is the gate.
//
// The five hard rules
// -------------------
//   1. No `.font(.system(size:))` and no bare `.font(.callout)` outside this
//      file. Use a `DS.Font` token so the scale stays one thing and Dynamic
//      Type / Accessibility text sizes keep working. The only sanctioned
//      point-size fonts are defined HERE: user-adjustable monospaced panes
//      (`DS.Font.userMono(size:)` and its caption / symbol derivatives, fed
//      by `AppSettings.statusFontSize`, `aiFontSize`, `TerminalModel.fontSize`),
//      canvas labels that scale with zoom (`DS.Canvas.*Font(scale:)`), glyphs
//      inscribed in a circle of a given size (`DS.Font.glyph(fitting:)`), and
//      the three glyph-only sizes below 10 pt (`chevron`, `glyphSmall`,
//      `keycap`).
//   2. No `Color.<name>.opacity(…)`, no `Color.accentColor`, no
//      `Color(nsColor:)`, no `.foregroundStyle(.secondary)`, no
//      `.background(.bar)` outside this file. Tinted fills come from
//      `DS.Color.tintFill(_:)`, hover / selection washes from
//      `DS.Color.hoverFill` / `.selectionFill`, dimming from
//      `DS.Color.dimmed(_:_:)` + `DS.Opacity.*`, the accent from
//      `DS.Color.accent` / `.accentStroke`, chrome bands from
//      `DS.Color.surface` (every header, footer and status band in the app
//      is one flat surface — there is no material anywhere). Exactly four
//      signal colours: `success` (green), `warning` (orange — every
//      "warning", nothing else is orange or yellow), `danger` (red — errors
//      and failed runs), `info` (blue). There is no `caution` and no yellow.
//      Text on a signal wash is `successText` / `warningText` / `dangerText`
//      / `infoText`, never the raw signal colour.
//   3. No private re-implementations of a DS component. If a component is
//      missing a feature, extend the DS component (keep one struct), never
//      copy it into a view file. The lint lists the retired duplicates.
//   4. No stroke, radius or frame literals: `DS.Stroke.*`, `DS.Radius.*`
//      (`DS.Radius.appIcon(for:)` for icon-shaped things), `DS.Layout.*`
//      (including `DS.Layout.Window.*` for every window minimum). A magic
//      box is a token nobody wrote down yet.
//   5. Honour the three accessibility switches — they are not optional
//      polish, they are HIG requirements — and honour them THROUGH THE
//      ENVIRONMENT, so a change in System Settings redraws a running app.
//      SwiftUI publishes all three as environment values and invalidates
//      every body that reads one; a static Bool read inside a body does
//      not, which is why `DS.A11y` alone was not enough (a view only
//      picked up the new setting when something unrelated rebuilt it).
//        • Reduce Motion — animate with `.dsAnimation(DS.Motion.quick,
//          value:)` rather than `.animation(_:value:)`. The modifier reads
//          `\.accessibilityReduceMotion` and drops the animation live.
//          For imperative animation (`withAnimation` inside an `onHover`
//          or a button action) `DS.Motion.quick` / `.standard` are still
//          correct: they are evaluated at event time, when the cached flag
//          is already current. Never build an `Animation` yourself, and use
//          `DS.Motion.standardSettleDelay` instead of `DS.Motion.normal`
//          when you schedule work after a transition.
//        • Increase Contrast — declare `@DSAccessibility private var a11y`
//          in the view and pass `a11y.contrast` to the adaptive tokens:
//          `DS.Stroke.hairline(c)`, `.hairlineFaint(c)`,
//          `DS.Color.hoverFill(c)`, `.selectionFill(c)`, `.separator(c)`,
//          `.controlBorder(c)`, `.textTertiary(c)`. Widths AND washes step
//          up together — a stronger border around a wash that stayed at
//          10 % only half-answers the request. Every structural stroke a
//          view draws (a bubble border, a table rule, a floating panel's
//          edge, a badge capsule) takes the adaptive form; the lint
//          rejects `.stroke(DS.Color.separator, lineWidth:
//          DS.Stroke.hairline)` spelt without the `(a11y.contrast)`.
//        • Differentiate Without Colour — anything whose meaning is a
//          colour needs a shape or glyph companion: `a11y.differentiate`.
//          `DSBadge(dot:)` takes a `dotSymbol:`; `ClassChip` swaps its
//          swatch for a per-class silhouette.
//      `@DSAccessibility` is ONE property wrapper (a `DynamicProperty`)
//      that reads the three environment switches AND the gallery's
//      `DSA11yOverride`, so a view never spells `override ?? system`
//      itself and cannot forget the `??`. It also exposes
//      `a11y.animation(DS.Motion.quick)` for the imperative
//      `withAnimation` in an `onHover` handler, so the gallery's Reduce
//      Motion toggle stills hover too. The lint rejects
//      `@Environment(\.colorSchemeContrast)` / `\.dsA11yOverride` /
//      `\.accessibilityReduceMotion` / `\.accessibilityDifferentiateWithoutColor`
//      outside this file — the wrapper is the only spelling.
//      `DS.A11y.*` remains for the call sites that are NOT view bodies
//      (AppKit code, the canvas' imperative `Canvas` draw closures); it is
//      the same three flags read from `NSWorkspace`.
//      `Qnet --ds-gallery` renders every specimen with each switch forced
//      on and off side by side, so both branches can be seen without
//      touching System Settings.
//
// Which token replaces which literal
// ----------------------------------
//   spacing 2 / 4 / 8 / 12 / 16 / 24 / 32           → DS.Spacing.xxs … .xxl
//   .padding(14) / .padding(18) / .padding(28)      → DS.Spacing.l / .l / .xl
//   cornerRadius 4 / 6 / 8 / 12                     → DS.Radius.keycap / .control / .panel / .sheet
//   lineWidth 0.5 / 1 / 1.5 / 2 / 3                 → DS.Stroke.hairlineFaint / .hairline / .hairlineBold (.selectionRing) / .selection / .focusRing
//   a border that must survive Increase Contrast    → DS.Stroke.hairline(a11y.contrast) with
//                                                     @DSAccessibility private var a11y
//                                                     (DS.Stroke.hairlineAdaptive outside a View)
//   .font(.system(size: 13, weight: .semibold))     → DS.Font.sectionTitle (pane / section / popover titles)
//   .font(.title.weight(.semibold))  (22 pt)        → DS.Font.pageTitle (About, help-topic titles)
//   .font(.title2.weight(.semibold)) (17 pt)        → DS.Font.sheetTitle
//   .font(.system(size: 12)) / .font(.callout)      → DS.Font.callout / .label
//   .font(.system(size: 11)) / .font(.subheadline)  → DS.Font.subheadline / .chrome (status bar, captions in chrome)
//   .font(.system(size: 10)) / .footnote / .caption2 → DS.Font.caption — the ONE 10-pt token; on
//                                                     macOS footnote = caption = caption2 = 10 pt (see
//                                                     the size table in `DS.Font`). There is no
//                                                     `DS.Font.footnote` — do not add one back
//   .font(.system(size: 13, design: .monospaced))   → DS.Font.mono (+ .monoCallout / .monoCaption …)
//   .font(.system(size: 18, weight: .semibold)) glyph in a sheet header → DS.Font.sheetGlyph
//   .font(.system(size: 48))                        → DS.Font.hero (About window only)
//   numbers that change while visible               → DS.Font.number / .numberSmall / .numberCaption
//   Color.accentColor                               → DS.Color.accent (rings: .accentStroke)
//   Color.accentColor.opacity(0.15)                 → DS.Color.selectionFill
//   Color.primary.opacity(0.05 … 0.08) hover        → DS.Color.hoverFill
//   Color.primary.opacity(0.12 … 0.35) hairlines    → DS.Color.separator / .controlBorder
//   Color(nsColor: .quaternaryLabelColor).opacity   → DS.Color.inactiveFill
//   Color(nsColor: .quaternarySystemFill)           → DS.Color.subtleFill
//   Color(nsColor: .textBackgroundColor) on a pane  → .dsContentWell()
//   .background(.bar) / any material                → DS.Color.surface
//   Color.white text on accent                      → never; use DSPaletteButtonStyle (selection wash)
//   text on a solid legibleTint capsule             → DS.Color.textOnTint
//   .foregroundStyle(.primary / .secondary)         → DS.Color.textPrimary / .textSecondary
//   .foregroundStyle(.tertiary)                     → DS.Color.textTertiary — ONLY for a
//                                                     placeholder, an em-dash empty or a
//                                                     decorative glyph. Content of any kind
//                                                     (a formula, a date, a kind label) is
//                                                     .textSecondary; see the token's note
//   .foregroundStyle(.red) error TEXT               → DS.Color.dangerText (the raw .danger is
//                                                     a fill: it measures 3.57 : 1 as ink)
//   .orange / .yellow "warning" TEXT                → DS.Color.warningText (raw .warning as
//                                                     ink is 2.31 : 1 — fills and big glyphs only)
//   Color.green / .red status dot                   → DS.Color.success / .danger
//   .black.opacity(…) shadow                        → DS.Shadow.card / .popover (appearance-aware)
//   canvas grid dots / lines                        → DS.Color.gridDot / .gridLine (× the zoom fade via dimmed)
//   rubber-band fill                                → DS.Color.marqueeFill
//   focus ring round a text area                    → DS.Color.focusRing at DS.Stroke.focusRing
//   magic 22 / 24 / 28 / 32 boxes                   → DS.Layout.controlHeight / .headerHeight / .tabBarHeight
//   Text(label).frame(width: 100, alignment: .trailing) → DSInspectorRow / DS.Layout.formLabelWidth
//   field .frame(width: 84 / 96 / 144 / 200)        → DS.Layout.compactFieldWidth / .narrowFieldWidth / .fieldWidth / .wideFieldWidth
//   split-pane .frame(minWidth: 150 / 225 / 500)    → DS.Layout.palettePaneMinWidth / .sidePaneMinWidth / .canvasPaneMinWidth
//   window .frame(minWidth: 700, minHeight: 520)    → DS.Layout.Window.* (main / settings / aux / auxWide)
//   NSSize(width: 1040, height: 700) for a window   → DS.Layout.Window.auxContent / .auxWideContent
//   sheet .frame(width: 560, height: …)             → DSSheet(size:) / .dsSheetFrame(_:); a sheet that
//                                                     grows with its rows uses DSSheetSize.height(forRows:)
//   a parameter editor of its own                   → NodeInspectorSections / LinkInspectorSections bound
//                                                     to NodeParameterDraft / LinkParameterDraft. The docked
//                                                     InspectorPaneView (commit on blur, follows the
//                                                     selection) is the CANONICAL inspector; the ⌘I sheets
//                                                     are the review-and-save host of the same sections.
//                                                     Neither may grow a field the other lacks.
//   popover .frame(maxWidth: 280 / 520×400)         → DSPopover(size: .compact | .regular | .wide)
//   ANY SF Symbol name in a view                    → DS.Symbol.* (the lint rejects a
//                                                     literal after systemImage: / systemName:)
//   Divider() that is not menu content               → DSRule() / DSRule(.vertical)
//   .animation(_:value:)                             → .dsAnimation(_:value:)
//   .easeInOut / .easeOut / .spring built inline     → DS.Motion.quick / .standard /
//                                                     .canvasGlide / .fadeOut(duration:)
//   String(format: "%.4g", x)                       → DS.Number.format(x, significantDigits: 4)
//   Double(text) / Int(text) from a field           → DS.Number.parse / .parseInt
//
// One command, one glyph
// ----------------------
//   `DS.Symbol` is the app's SF Symbol vocabulary. Iconography is a token
//   like colour: a command that appears in more than one place must wear
//   the same glyph in all of them (Zoom to Fit was two mirrored arrows in
//   two places at once, and "clear this pane" was `trash` in two pane
//   headers and `clear` in the third). Node-kind glyphs stay on
//   `NodeKind.systemImage`, which the model owns.
//
// Components that carry the tokens for you
// ----------------------------------------
//   DSSectionHeader     the one pane / section header: 32-pt row, title,
//                       accessory slot, trailing controls, focus rule, hairline
//   DSRule              THE separator: `DSRule()` as a row, `DSRule(.vertical)`
//                       between controls, `.dsHairline(edge)` as a container's
//                       own edge. `Divider()` is for menu content only
//   DSIconButton        the one icon-only button (headers, tab bar, floating
//                       clusters). `help` is mandatory and doubles as the
//                       accessibility label; `isDestructive:` tints it danger
//   DSIconToggle        the one icon-only toggle (snap to grid): selection wash + hairline when on
//   DSIconMenu          the one icon-only menu (export menu): DSIconButton look, hidden indicator
//   DSToolbarButtonStyle(isSelected:) / DSPaletteButtonStyle   hover / pressed /
//                       disabled / selected states with DS washes
//   FontSizeStepper, MonospaceFontMenu            pane text-size and font controls
//   DSPill              status pill (flag bar): on/off, symbol, count badge,
//                       hover / pressed / disabled, always a button whose
//                       popover content is a DSPopover
//   DSBadge             counts, class chips, status chips (`dot:` + `dotSymbol:`
//                       / `dotRing:`), 20-pt
//   ClassChip           customer-class swatch + label (also the rows of class menus)
//   ShortcutBadge       keycap for single-letter shortcuts
//   DSPopover           the one popover chrome: title row (symbol, title,
//                       trailing caption), `size: .compact | .regular | .wide`
//   DSSheet             the one sheet chrome: DSSheetHeader (44-pt glyph,
//                       title, subtitle), content, DSSheetFooter (problem
//                       caption + Cancel / confirm buttons), `size:` preset
//                       (`.compact | .regular | .tall | .wide | .table`)
//   DSNumericField      THE numeric field. `.roundedBorder` chrome, unit
//                       column, stepper (`.linear` / `.multiplicative`),
//                       `validation: .live | .onCommit`, `commit: .onEdit |
//                       .onCommit` (default: write once on Return / blur /
//                       stepper, clamped into range), `emptyFor:` sentinel,
//                       `overrideToggle:`, `caption:`, `errorReport:`
//   DSRangeFields       "min … max" pair with the lo ≤ hi rule
//   DSTextField         labelled text field (`isSecure`, `monospaced`,
//                       `accessory:` for trailing menus / buttons)
//   DSSearchField       the one search / filter field: recessed bezel,
//                       magnifier, hover lift, native 3-pt focus ring,
//                       clear button, Esc, optional `status:` ("3 of 5")
//   DSTextArea          the one multi-line text control (Settings ▸ AI ▸
//                       System prompt): label above a well sized in lines,
//                       `.roundedBorder` chrome and the same focus ring
//   DSInspectorRow      label (+ `caption:`) / control / message row in
//                       `.inspector | .form | .compact | .bare` layout;
//                       DSInspectorRowPlaceholder reserves one row's height
//   DSRowLabel          title + caption label (`SettingsLabel` is its alias)
//   DSGlossaryButton    the one "?" that opens a `DS.Glossary` popover.
//                       It OWNS the trailing column of every `.form` and
//                       `.inspector` row: DSGlossarySlot reserves
//                       `DS.Layout.glossaryColumnWidth` there whether or not
//                       the row has an entry, so a row with a "?" and the
//                       row above it without one end at the same x. A row
//                       whose control is not a DS field (a Settings toggle,
//                       a read-only value) places the same DSGlossarySlot
//                       after its control — never beside the label
//   DSLabelledSlider, DSSegmentedPicker, DSMenuPicker, DSRangeFields — all
//                       take `glossary:`
//   InlineFieldMessage  the one caption under a field / advisory row:
//                       `.error` (danger), `.warning` (orange triangle) or
//                       `.pending` (calm "still typing", secondary)
//   View.validatedFieldBorder(isInvalid:)
//   DSEmptyState        ContentUnavailableView with DS typography; the only
//                       empty state (canvas, status, AI, Help); `.search(query:)`
//                       is the one "no matches" state. Its `title:` is a
//                       Title Case noun phrase ("No Selection", "No Status
//                       Entries" — the HIG's "No Mail", "No Results") and
//                       its `message:` a sentence; the lint checks the title
//   View.dsTooltip(_:)  .help + .accessibilityLabel from ONE string — for a
//                       control whose tooltip and spoken name are the same
//                       sentence. Where they differ (a short spoken name and
//                       a longer tooltip naming the shortcut) write both, as
//                       DSIconButton does internally: that is not a violation
//   View.dsAnimation(_:value:)  `.animation(_:value:)` that honours Reduce
//                       Motion LIVE (reads the environment, so the setting
//                       takes effect without rebuilding the view)
//   View.dsFocusRing(_:radius:)  the AppKit-style soft ring OUTSIDE a bezel
//   @DSAccessibility    the one way a view reads Reduce Motion / Increase
//                       Contrast / Differentiate Without Colour (see rule 5)
//   View.dsA11yOverride(_:)  forces an accessibility switch for a subtree —
//                       DSGallery only, so both branches can be reviewed.
//                       Nested overrides MERGE (a child that pins one switch
//                       keeps the parent's other two)
//   View.dsContentWell() content-area background (`DS.Color.fieldBackground`)
//   View.dsChromeBar(_:) the one chrome for a bar attached to scrolling
//                       content — pane header, filter row, status band, the
//                       Settings Reset footer: flat `DS.Color.surface` plus a
//                       hairline on the content edge, padded vertically or
//                       pinned with `height:`. Never a material — the lint
//                       rejects `.background/.fill(.bar or any *Material)`.
//   DSGalleryWindow     the reference render of all of the above
//
//   Settings wrappers (SettingsComponents.swift) — SettingsNumberRow,
//   SettingsRangeRow, SettingsSliderRow — are thin façades over the DS
//   components above that only supply the Settings defaults.
//
//   There is no AppKit form exception any more: the run dialogs that used
//   `AlertFormBuilder` / `SteppedField` are now `RunParameterSheet` (a
//   DSSheet driven by a `RunParameterSpec`), so every form in the app is
//   built from the DS components above.
//
// What the lint enforces, so you do not have to remember it
// ---------------------------------------------------------
//   `validation/design_lint.sh` greps every Swift file but this one for the
//   patterns above and then runs `validation/ds_contrast.swift`, which
//   PARSES its constants out of this file (the blend fractions,
//   `DS.Opacity.tintFill`, `DS.Color.textTertiary`) rather than mirroring
//   them, so the gate cannot drift from the tokens it claims to measure.
//   Two rules are about this file itself: every `DS.Glossary` entry must be
//   referenced by at least one view, and no view may write an SF Symbol
//   name — neither as a `systemImage:` argument (any literal there fails)
//   nor as a plain string in a view-owned glyph table (the alternation
//   for that rule is generated from the `DS.Symbol` constants themselves,
//   so it grows with the vocabulary; `Models.swift` is the one exemption,
//   for the node-kind / distribution / picture tables the model owns).
//   Both `test.sh` (first step) and `build_app.sh` (after the version
//   bump, before any compiler runs) run the lint and abort on a violation.
//
// A word about jargon
// -------------------
//   A label that is only a symbol (μ, ρ, Γ, c², "Enter as") must carry a
//   `DS.Glossary` string — as `glossary:` on a DS row, which draws the "?"
//   button and its popover, or as `help:` on a table column heading. Adding
//   a glossary entry and not wiring it is worse than not adding it: the
//   guide's own rule is that a token nobody uses is deleted.
//
// How to add a token
// ------------------
//   • Add it to the matching `DS.*` namespace IN THIS FILE, with a one-line
//     comment saying what it is for and where it is used first. Never
//     `extension DS.Layout` from somewhere else — the lint rejects it.
//   • Colours must be defined for both appearances: either an NSColor system
//     semantic colour or `DS.Color.dynamic(light:dark:)`, and they must be
//     `static let`. A computed `static var` re-allocates an NSColor on every
//     read, which on a 200-node canvas drag is thousands per second and
//     defeats SwiftUI's `Equatable` short-circuits (each `Color` would wrap
//     a distinct instance). Dynamic NSColors resolve at draw time, so one
//     cached instance still switches with the appearance.
//   • Spacing stays on the 8-pt grid (2 and 4 are the only sub-grid values,
//     for hairline-adjacent nudges and icon/text gaps).
//   • Fonts are text styles, never point sizes (see rule 1 for exceptions).
//   • Run `validation/design_lint.sh` before committing, and open
//     `Qnet --ds-gallery` if you touched a colour, a font or a component.
//     Add a pattern to the lint when you retire a literal or a duplicate.
// ─────────────────────────────────────────────────────────────────────────────

enum DS {

    // MARK: - Colour

    enum Color {
        // Every token below is a `static let`, not a computed `var`.
        // `dynamic(light:dark:)` and `.init(nsColor:)` each allocate an
        // NSColor (plus, for the dynamic ones, a resolver closure); a
        // computed token re-allocated one on *every read*, so a 200-node
        // canvas drag allocated thousands of NSColors per second and —
        // because each `Color` then wrapped a distinct instance —
        // defeated SwiftUI's `Equatable` short-circuits on the canvas
        // layers. Dynamic NSColors are appearance-resolved at draw time,
        // so caching one instance is correct and is the whole point of
        // the API: light / dark still switch, the allocation does not repeat.

        // Surfaces --------------------------------------------------------
        /// Window / pane chrome background (headers, tab bar, status bar,
        /// Settings footer). Every flat chrome band in the app is this.
        static let surface = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Raised content areas: active tab, cards, text views, canvas ground.
        static let surfaceRaised = SwiftUI.Color(nsColor: .controlBackgroundColor)
        /// Text-entry and content-well background (fields, transcript, log).
        static let fieldBackground = SwiftUI.Color(nsColor: .textBackgroundColor)
        /// Very light fill for zebra rows and info cards.
        static let subtleFill = SwiftUI.Color(nsColor: .quaternarySystemFill)
        /// Hairline separators and control borders.
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        /// Slightly stronger border for standalone controls (tabs, fields).
        static let controlBorder = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        /// Fill for inactive pills / badges / keycaps.
        static let inactiveFill = SwiftUI.Color(nsColor: .quaternaryLabelColor)

        // Text ------------------------------------------------------------
        static let textPrimary = SwiftUI.Color(nsColor: .labelColor)
        static let textSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// The faintest step of the label hierarchy — **placeholders,
        /// em-dash empties and decorative glyphs only**. Never content.
        ///
        /// This is deliberately NOT `tertiaryLabelColor`. Apple's tertiary
        /// measures 1.88 : 1 on a light ground and 2.26 : 1 on a dark one,
        /// which is correct for the disabled controls and placeholders
        /// AppKit uses it for and wrong for anything a user has to read —
        /// and Qnet was drawing a distribution's mean / SCV formula, the
        /// node kind in Find Node, the About copyright and the AI
        /// timestamps in it. Those all moved to `textSecondary` (3.95 : 1
        /// light / 5.89 : 1 dark, gated), and the token itself is now a
        /// dynamic grey measured at 3.24 : 1 light / 4.19 : 1 dark against
        /// both `surface` and `fieldBackground` — still visibly the third
        /// step below `textSecondary`, but above the 3 : 1 floor, and
        /// gated there by `validation/ds_contrast.swift`.
        ///
        /// Under Increase Contrast the system label colours all step
        /// darker, and so must this one — a hand-rolled grey that ignored
        /// the switch was the DS's one label colour that did. The second
        /// pair is what `dynamic` resolves under the
        /// `accessibilityHighContrast*` appearances a window takes while
        /// the switch is on: 0.40 grey measures 5.74 : 1 in light and 0.64
        /// grey 6.62 : 1 in dark, on both `surface` and `fieldBackground`
        /// (beside the plain pair's 3.24 / 4.19) — AA text, not just the
        /// non-text floor, and gated at 4.5 : 1 by `ds_contrast.swift`,
        /// which composites the pair over the same grounds (AppKit only
        /// vends the high-contrast appearance while the setting is on, so
        /// the gate cannot instantiate it by name). A view body that must
        /// honour the gallery's forced switch (which cannot change the
        /// appearance either) uses `textTertiary(_:)`.
        static let textTertiary = dynamic(light: (0.56, 0.56, 0.56),
                                          dark: (0.50, 0.50, 0.50),
                                          lightHighContrast: (0.40, 0.40, 0.40),
                                          darkHighContrast: (0.64, 0.64, 0.64))
        /// The Increase Contrast branch of `textTertiary` regardless of the
        /// appearance the view is actually drawn in — what `textTertiary(_:)`
        /// returns for `.increased`, so the gallery can force it.
        static let textTertiaryIncreased = dynamic(light: (0.40, 0.40, 0.40),
                                                   dark: (0.64, 0.64, 0.64))

        // Signal ----------------------------------------------------------
        // Exactly four signal colours, one meaning each:
        //   success  green   tractable, passed, shell running
        //   warning  orange  every "warning": degraded accuracy, partial
        //                    pass, non-blocking field advice, unbalanced
        //                    totals, ∞ readouts, solver WARNING lines
        //   danger   red     errors, failed runs, blocking validation
        //   info     blue    informational, station tint
        // There is deliberately no yellow and no separate "caution": a user
        // must see the same colour wherever the word "warning" appears.
        /// Green: tractable, passed, shell running.
        static let success = SwiftUI.Color(nsColor: .systemGreen)
        /// Orange: the one warning colour (flag-bar Warnings pill, status
        /// log, inline field advice, re-entrant "partial" quality, ∞).
        /// FILL only — see "Signal text" below. Text and caption-sized
        /// glyphs use `warningText` on every ground.
        static let warning = SwiftUI.Color(nsColor: .systemOrange)
        /// Red: errors, failed runs, blocking validation.
        static let danger = SwiftUI.Color(nsColor: .systemRed)
        /// Blue: informational, station tint.
        static let info = SwiftUI.Color(nsColor: .systemBlue)
        /// Orange used as a *node-kind* colour (buffer icon and header
        /// tint), not as a signal. Kept apart from `warning` so a future
        /// re-colouring of buffers does not change what a warning looks like.
        static let bufferTint = SwiftUI.Color(nsColor: .systemOrange)

        // Signal text ------------------------------------------------------
        // THE RULE: a signal colour is for FILLS and for large glyphs.
        // Text — and any glyph at caption size — uses the `*Text` variant,
        // on every ground, including a plain one.
        //
        // Measured on `surface` / `fieldBackground` in aqua, which is
        // where the app's inline field errors, advisory triangles and
        // sheet-footer problem lines are actually drawn:
        //
        //             raw signal        *Text variant
        //   success       2.22 : 1         5.82 : 1
        //   warning       2.31 : 1         6.01 : 1
        //   danger        3.57 : 1         8.38 : 1
        //   info          3.52 : 1         8.30 : 1
        //
        // Every raw value is below the 4.5 : 1 that `DS.Font.caption`
        // needs, and success / warning are below even the 3 : 1 non-text
        // floor — so the app's most important error surfaces were its
        // least legible ones. In darkAqua the raw colours pass (green
        // 8.25, orange 7.47, red 4.86, blue 5.16) and the `*Text`
        // variants pass by more, so one rule works in both appearances.
        // `validation/ds_contrast.swift` gates each `*Text` token on its
        // own wash AND on both plain grounds, and `design_lint.sh` rejects
        // `foregroundStyle(DS.Color.<signal>)` outside this file.
        static let successText = legibleTint(success)
        static let warningText = legibleTint(warning)
        static let dangerText = legibleTint(danger)
        static let infoText = legibleTint(info)

        // Accent -----------------------------------------------------------
        /// The user's accent colour. The only sanctioned spelling — never
        /// write `Color.accentColor` in a view, so a high-contrast or
        /// graphite treatment is one edit here.
        static let accent = SwiftUI.Color.accentColor
        /// Accent used for selection rings and focused-field borders.
        static let accentStroke = SwiftUI.Color.accentColor
        /// Text or glyph drawn on a solid `legibleTint(_:)` capsule: white
        /// on the darkened light-mode tint, black on the lightened dark-mode
        /// tint. Never `surface` — a background colour is not a text colour.
        static let textOnTint = dynamic(light: (1.0, 1.0, 1.0), dark: (0.0, 0.0, 0.0))

        // Interaction washes ---------------------------------------------
        /// Accent at 10 % — hover state for borderless controls, tabs, tiles.
        static let hoverFill = accent.opacity(Opacity.hoverFill)
        /// Accent at 15 % — selected / pressed state.
        static let selectionFill = accent.opacity(Opacity.selectionFill)
        /// Accent at 35 % — strong selection wash (pending link start on canvas).
        static let selectionFillStrong = accent.opacity(Opacity.selectionFillStrong)
        /// Accent at 8 % — marquee / rubber-band fill (NetworkCanvasView).
        static let marqueeFill = accent.opacity(Opacity.marqueeFill)
        /// Accent at 35 % — focus ring around a focused composer / search
        /// field (AI composer, DSSearchField).
        static let focusRing = accent.opacity(Opacity.selectionFillStrong)

        // Increase Contrast ------------------------------------------------
        // Stepping only the stroke WIDTHS up left a heavier border around a
        // wash that stayed at 10 % — half an answer. These four take the
        // view's `@Environment(\.colorSchemeContrast)` and step the wash
        // and the line colour up with it. Reading the environment value is
        // also what makes SwiftUI re-run the body when the switch flips.
        static let hoverFillIncreased = accent.opacity(Opacity.hoverFillIncreased)
        static let selectionFillIncreased = accent.opacity(Opacity.selectionFillIncreased)

        /// Hover wash, stronger under Increase Contrast.
        static func hoverFill(_ contrast: ColorSchemeContrast) -> SwiftUI.Color {
            contrast == .increased ? hoverFillIncreased : hoverFill
        }
        /// Selection / pressed wash, stronger under Increase Contrast.
        static func selectionFill(_ contrast: ColorSchemeContrast) -> SwiftUI.Color {
            contrast == .increased ? selectionFillIncreased : selectionFill
        }
        /// Hairline separator colour; under Increase Contrast the system's
        /// `separatorColor` is barely darker, so structure lines step to
        /// the (system-adapted) control border instead.
        static func separator(_ contrast: ColorSchemeContrast) -> SwiftUI.Color {
            contrast == .increased ? controlBorder : separator
        }
        /// Standalone-control border; steps to the full label hierarchy's
        /// secondary colour under Increase Contrast.
        static func controlBorder(_ contrast: ColorSchemeContrast) -> SwiftUI.Color {
            contrast == .increased ? textSecondary : controlBorder
        }
        /// The faintest label step, stepped darker under Increase Contrast
        /// — the view-body spelling, so the gallery's forced switch is
        /// honoured (the plain token only follows the real appearance).
        static func textTertiary(_ contrast: ColorSchemeContrast) -> SwiftUI.Color {
            contrast == .increased ? textTertiaryIncreased : textTertiary
        }

        /// Non-view spellings of `separator(_:)` / `controlBorder(_:)` for
        /// `Canvas` draw closures, which are handed a `GraphicsContext`
        /// rather than an environment (the link-label chips). Pair them
        /// with `DS.Stroke.hairlineAdaptive`.
        static var separatorAdaptive: SwiftUI.Color {
            separator(A11y.increaseContrast ? .increased : .standard)
        }
        static var controlBorderAdaptive: SwiftUI.Color {
            controlBorder(A11y.increaseContrast ? .increased : .standard)
        }

        // Canvas ----------------------------------------------------------
        /// Halo behind a selected node / link.
        static let selectionGlow = accent.opacity(Opacity.selectionFillStrong)
        /// Ring around a hovered node.
        static let hoverRing = accent.opacity(Opacity.selectionFillStrong)
        /// Translucent band under a selected link.
        static let linkHalo = accent.opacity(Opacity.linkHalo)

        // Canvas node kinds ------------------------------------------------
        // Distinct light and dark values: the light fills are pastel tints
        // that keep a black label legible; the dark fills are deep, saturated
        // tones so the coloured node still reads against the dark grid
        // without going muddy.
        static let stationFill = dynamic(light: (0.80, 0.87, 0.98), dark: (0.16, 0.27, 0.46))
        static let bufferFill = dynamic(light: (0.99, 0.90, 0.76), dark: (0.47, 0.31, 0.12))
        static let sourceFill = dynamic(light: (0.82, 0.94, 0.83), dark: (0.14, 0.38, 0.22))
        static let sinkFill = dynamic(light: (0.98, 0.83, 0.83), dark: (0.48, 0.17, 0.18))
        /// Node outline. Near-black on light, near-white on dark.
        static let nodeStroke = dynamic(light: (0.22, 0.22, 0.24), dark: (0.86, 0.86, 0.88))
        /// Glyph inside a station circle (resource picture).
        static let nodeGlyph = dynamic(light: (0.15, 0.15, 0.17), dark: (0.92, 0.92, 0.94))

        // Canvas grid ------------------------------------------------------
        // `GridCanvas` fades each layer in with the zoom; it multiplies the
        // token's own alpha by that fade factor through `dimmed(_:_:)`
        // rather than inventing a second colour at the call site.
        /// Minor grid dots at full strength.
        static let gridDot = dynamic(light: (0.0, 0.0, 0.0, 0.26), dark: (1.0, 1.0, 1.0, 0.30))
        /// Major grid lines at full strength.
        static let gridLine = dynamic(light: (0.0, 0.0, 0.0, 0.12), dark: (1.0, 1.0, 1.0, 0.14))

        // Shell -----------------------------------------------------------
        // SwiftTerm takes NSColors, so these are the app's only NSColor
        // tokens. The pane's default text and ground are the system
        // `textColor` / `textBackgroundColor` (appearance-resolved by
        // TerminalHostView); what lives here is the 16-colour ANSI palette
        // — one tuned for each ground, the way Terminal.app's Basic profile
        // keeps a light and a dark set — and the classic green-on-black
        // look behind Settings ▸ Shell.
        //
        // Light: every colour measures at least 3 : 1 on white, so the
        // bright yellow / green / cyan that `ls` (CLICOLOR) and the solver
        // banners print stop vanishing into the ground. Dark: the palette
        // VS Code ships for its dark ground, which is legible on
        // `textBackgroundColor` (≈ #1E1E1E) at every index.
        /// Classic Shell theme: the phosphor green, and black.
        static let classicShellForeground = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.40, alpha: 1)
        static let classicShellBackground = NSColor.black
        /// ANSI 0–15 for the light ground (black … white, then the brights).
        static let shellPaletteLight: [NSColor] = shellPalette([
            (0, 0, 0), (178, 0, 0), (0, 128, 0), (153, 102, 0),
            (0, 0, 204), (153, 0, 153), (0, 128, 153), (153, 153, 153),
            (102, 102, 102), (204, 0, 0), (0, 153, 0), (178, 134, 0),
            (51, 51, 255), (204, 0, 204), (0, 153, 178), (178, 178, 178),
        ])
        /// ANSI 0–15 for the dark ground and the classic theme.
        static let shellPaletteDark: [NSColor] = shellPalette([
            (96, 96, 96), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (128, 128, 128), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
        ])
        private static func shellPalette(_ rgb: [(Int, Int, Int)]) -> [NSColor] {
            rgb.map { NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255,
                              blue: CGFloat($0.2) / 255, alpha: 1) }
        }

        /// Fill colour of a node kind — the same value the canvas draws, so
        /// previews (picture picker, inspector header) match exactly.
        static func nodeFill(for kind: NodeKind) -> SwiftUI.Color {
            switch kind {
            case .station: return stationFill
            case .buffer:  return bufferFill
            case .source:  return sourceFill
            case .sink:    return sinkFill
            }
        }

        /// Solid signal colour associated with a node kind (icons, headers).
        static func nodeTint(for kind: NodeKind) -> SwiftUI.Color {
            switch kind {
            case .station: return info
            case .buffer:  return bufferTint
            case .source:  return success
            case .sink:    return danger
            }
        }

        /// Shadow ink: black in light mode; in dark mode a black shadow
        /// vanishes against the dark canvas, so the alpha is raised.
        static func shadowInk(light: Double, dark: Double) -> SwiftUI.Color {
            dynamic(light: (0, 0, 0, light), dark: (0, 0, 0, dark))
        }

        // Helpers ---------------------------------------------------------
        /// Translucent fill of a tint for badges, pills and chips.
        static func tintFill(_ tint: SwiftUI.Color) -> SwiftUI.Color {
            tint.opacity(Opacity.tintFill)
        }

        /// Stronger translucent fill of a tint (hovered pill, sheet glyph disc).
        static func tintFillStrong(_ tint: SwiftUI.Color) -> SwiftUI.Color {
            tint.opacity(Opacity.tintFillStrong)
        }

        /// Dimmed variant of a tint (links of a non-active class, etc.).
        static func dimmed(_ tint: SwiftUI.Color, _ opacity: Double = Opacity.dim) -> SwiftUI.Color {
            tint.opacity(opacity)
        }

        /// Blend fractions `legibleTint(_:)` applies: light mode darkens
        /// toward black, dark mode lightens toward white.
        ///
        /// The light value is 0.48, not the 0.42 it used to be. At 0.42 the
        /// two most-visible pills in the app — the flag bar's green
        /// "Tractable" and orange "Warnings", drawn at `DS.Font.label`
        /// (12 pt regular, so the 4.5 : 1 rule applies, not the large-text
        /// 3 : 1 one) — measured 4.35 : 1 and 4.48 : 1 against their own
        /// wash composited over `surface`, i.e. they failed WCAG AA. At
        /// 0.48 every signal colour passes in both appearances.
        /// `validation/ds_contrast.swift` prints the measured ratios and
        /// exits non-zero below the threshold; `design_lint.sh` runs it, so
        /// this is a checked property rather than a claim.
        static let legibleTintLightBlend: CGFloat = 0.48
        static let legibleTintDarkBlend: CGFloat = 0.30

        /// A label colour derived from `tint` that stays legible on
        /// `tintFill(tint)`: darkened in light mode, lightened in dark mode.
        ///
        /// Memoised. DSBadge and DSPill call this two or three times per
        /// label render and each call would otherwise allocate a dynamic
        /// NSColor. The four signal results are also available directly as
        /// `successText` / `warningText` / `dangerText` / `infoText` —
        /// prefer those; the function stays for the customer-class palette,
        /// whose tint is not known at compile time.
        static func legibleTint(_ tint: SwiftUI.Color) -> SwiftUI.Color {
            legibleTintCache.color(for: tint) { base in
                let ns = NSColor(base)
                let dynamicColor = NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [
                        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                    ])
                    let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                    let srgb = ns.usingColorSpace(.sRGB) ?? ns
                    if isDark {
                        return srgb.blended(withFraction: legibleTintDarkBlend, of: .white) ?? srgb
                    } else {
                        return srgb.blended(withFraction: legibleTintLightBlend, of: .black) ?? srgb
                    }
                }
                return SwiftUI.Color(nsColor: dynamicColor)
            }
        }

        private static let legibleTintCache = ColorMemo()

        /// Build an appearance-aware colour from sRGB components. Alpha is
        /// optional (defaults to 1).
        ///
        /// Resolves against all FOUR appearances, not just aqua / darkAqua:
        /// under System Settings ▸ Increase Contrast the window's
        /// effective appearance is `accessibilityHighContrastAqua` (or its
        /// dark twin), and a token matched only against the two plain
        /// appearances would sit still while every system colour around
        /// it stepped up. `lightHighContrast` / `darkHighContrast` are the
        /// values for those two; when a caller gives neither, the plain
        /// pair is stepped for it — light darkened, dark lightened — by
        /// `highContrastStep` (0.30 of the way to black / white), which
        /// takes a 3 : 1 grey to about 4.6 : 1 and leaves a saturated fill
        /// recognisably itself. Alpha is kept.
        static func dynamic(
            light: (Double, Double, Double, Double?),
            dark: (Double, Double, Double, Double?),
            lightHighContrast: (Double, Double, Double, Double?)? = nil,
            darkHighContrast: (Double, Double, Double, Double?)? = nil
        ) -> SwiftUI.Color {
            let lightHC = lightHighContrast ?? stepped(light, toward: 0)
            let darkHC = darkHighContrast ?? stepped(dark, toward: 1)
            let ns = NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [
                    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                ])
                let c: (Double, Double, Double, Double?)
                switch match {
                case .darkAqua: c = dark
                case .accessibilityHighContrastAqua: c = lightHC
                case .accessibilityHighContrastDarkAqua: c = darkHC
                default: c = light
                }
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3 ?? 1)
            }
            return .init(nsColor: ns)
        }

        static func dynamic(
            light: (Double, Double, Double),
            dark: (Double, Double, Double),
            lightHighContrast: (Double, Double, Double)? = nil,
            darkHighContrast: (Double, Double, Double)? = nil
        ) -> SwiftUI.Color {
            dynamic(light: (light.0, light.1, light.2, nil),
                    dark: (dark.0, dark.1, dark.2, nil),
                    lightHighContrast: lightHighContrast.map { ($0.0, $0.1, $0.2, nil) },
                    darkHighContrast: darkHighContrast.map { ($0.0, $0.1, $0.2, nil) })
        }

        /// Fraction of the way toward black (light) or white (dark) a
        /// `dynamic` colour moves under Increase Contrast when the caller
        /// gave no explicit high-contrast pair.
        static let highContrastStep: Double = 0.30

        private static func stepped(_ c: (Double, Double, Double, Double?),
                                    toward target: Double) -> (Double, Double, Double, Double?) {
            let t = highContrastStep
            return (c.0 + (target - c.0) * t, c.1 + (target - c.1) * t, c.2 + (target - c.2) * t, c.3)
        }
    }

    // MARK: - Opacity

    enum Opacity {
        static let hoverFill: Double = 0.10
        static let selectionFill: Double = 0.15
        static let selectionFillStrong: Double = 0.35
        /// The same two washes under Increase Contrast — a hover the user
        /// asked to be able to see.
        static let hoverFillIncreased: Double = 0.20
        static let selectionFillIncreased: Double = 0.30
        static let marqueeFill: Double = 0.08
        static let tintFill: Double = 0.18
        static let tintFillStrong: Double = 0.28
        /// Disabled controls.
        static let disabled: Double = 0.40
        /// Content dimmed because it is out of the current filter / focus.
        static let dim: Double = 0.20
        /// Steady wash on a row that matches a live search query (Settings
        /// rows while a query stands). Weaker than a selection so the one
        /// row the user jumped to still stands out among its siblings.
        static let matchTint: Double = 0.45
        /// Secondary emphasis (unsaved-changes dot, muted glyphs).
        static let muted: Double = 0.70
        /// Link stroke opacity so class colours stay soft against the grid.
        static let linkStroke: Double = 0.75
        static let arrowHead: Double = 0.85
        /// Translucent band under a selected link.
        static let linkHalo: Double = 0.25
        /// Border of a tinted pill / badge: the tint at 60 %, so the edge
        /// reads without becoming a second solid colour.
        static let borderTint: Double = 0.60
    }

    // MARK: - Accessibility

    /// The three system accessibility switches the design system honours,
    /// read from `NSWorkspace` and cached in a lock-guarded box that an
    /// `accessibilityDisplayOptionsDidChangeNotification` observer refreshes.
    ///
    /// **This is the non-view path.** A SwiftUI body that reads one of
    /// these gets the right answer at the moment it runs, but SwiftUI has
    /// no reason to re-run it when the setting changes, so the app kept
    /// drawing the old branch until something unrelated invalidated the
    /// view. Views therefore read the switches from the ENVIRONMENT —
    /// `\.accessibilityReduceMotion`, `\.colorSchemeContrast`,
    /// `\.accessibilityDifferentiateWithoutColor` — which SwiftUI updates
    /// and invalidates for us, and pass the value to the adaptive tokens
    /// (`DS.Stroke.hairline(_:)`, `DS.Color.hoverFill(_:)`, …) or to
    /// `.dsAnimation(_:value:)`.
    ///
    /// Use `DS.A11y` only where there is no environment to read from:
    /// AppKit code, `Canvas` draw closures that are handed values rather
    /// than an `EnvironmentValues`, and the imperative `withAnimation`
    /// calls inside event handlers (evaluated at event time, when the
    /// cached flag is current).
    enum A11y {
        /// "Reduce motion" — animations must not move, scale or bounce.
        static var reduceMotion: Bool { AccessibilityFlags.shared.reduceMotion }
        /// "Increase contrast" — borders and washes step up.
        static var increaseContrast: Bool { AccessibilityFlags.shared.increaseContrast }
        /// "Differentiate without colour" — a colour-only signal needs a
        /// shape or glyph companion (DSBadge `dot:`, ClassChip swatch).
        static var differentiateWithoutColor: Bool {
            AccessibilityFlags.shared.differentiateWithoutColor
        }

        /// Call once at launch so the flags track System Settings changes.
        @MainActor
        static func startObserving() { AccessibilityFlags.shared.start() }
    }

    // MARK: - Spacing (8-pt grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radii

    enum Radius {
        /// Keycaps and tiny badges.
        static let keycap: CGFloat = 4
        /// Buttons, tabs, fields, chips, pills.
        static let control: CGFloat = 6
        /// Panels, floating legends, cards, popover content.
        static let panel: CGFloat = 8
        /// Sheets and large containers.
        static let sheet: CGFloat = 12
        /// Tiny swatches inside chips.
        static let swatch: CGFloat = 2
        /// Apple's documented app-icon mask: 0.2237 × the icon's side.
        /// The same constant `assets/make_icon.swift` uses, so an in-app
        /// icon placeholder (About window) matches the real icon's corners.
        static func appIcon(for side: CGFloat) -> CGFloat { side * 0.2237 }
    }

    // MARK: - Strokes

    enum Stroke {
        static let hairline: CGFloat = 1
        /// Half-hairline: the inner ring of a swatch or keycap, where a
        /// full hairline would read as a second border. Written as a token
        /// rather than `hairline / 2` at the call site.
        static let hairlineFaint: CGFloat = 0.5
        /// Emphasised hairline: invalid-field border, node-preview ring.
        static let hairlineBold: CGFloat = 1.5
        /// Selection ring around a selected canvas node.
        static let selectionRing: CGFloat = 1.5
        static let selection: CGFloat = 2
        static let focusRing: CGFloat = 3

        /// `hairline`, or `hairlineBold` under Increase Contrast — the
        /// border of a pill, badge, chip or field bezel, where a 1-pt line
        /// is the whole separation from the ground.
        ///
        /// Pass the view's `@Environment(\.colorSchemeContrast)`: that is
        /// the live value, and reading it is what makes SwiftUI re-run the
        /// body when the user flips the switch.
        static func hairline(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? hairlineBold : hairline
        }
        /// `hairlineFaint`, stepped to a full hairline under Increase Contrast.
        static func hairlineFaint(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? hairline : hairlineFaint
        }

        /// Non-view spelling of `hairline(_:)` (AppKit, `Canvas` draw
        /// closures). Prefer the environment form inside a `View`.
        static var hairlineAdaptive: CGFloat {
            hairline(A11y.increaseContrast ? .increased : .standard)
        }
        /// Non-view spelling of `hairlineFaint(_:)`.
        static var hairlineFaintAdaptive: CGFloat {
            hairlineFaint(A11y.increaseContrast ? .increased : .standard)
        }
    }

    // MARK: - Shadows

    struct Shadow {
        let color: SwiftUI.Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        /// Floating legends, chips over the canvas. Appearance-aware: 12 %
        /// black in light mode, 45 % in dark mode where a faint black
        /// shadow would disappear against the dark canvas.
        static var card: Shadow {
            Shadow(color: Color.shadowInk(light: 0.12, dark: 0.45), radius: 6, x: 0, y: 2)
        }
        /// Popover-like floating panels.
        static var popover: Shadow {
            Shadow(color: Color.shadowInk(light: 0.18, dark: 0.55), radius: 12, x: 0, y: 6)
        }
    }

    // MARK: - Layout

    enum Layout {
        /// Fixed height of every DSSectionHeader row (pane headers).
        static let headerHeight: CGFloat = 32
        /// Height of compact toolbar controls inside a header.
        static let controlHeight: CGFloat = 24
        /// Width of an icon-only button (DSIconButton): square 24-pt target.
        static let iconButtonWidth: CGFloat = 24
        /// Filter / search row under a pane header.
        static let filterRowHeight: CGFloat = 32
        /// Tab bar strip height.
        static let tabBarHeight: CGFloat = 32
        /// Application status bar height.
        static let statusBarHeight: CGFloat = 24
        /// Height of badges and chips (DSBadge, provider chip).
        static let chipHeight: CGFloat = 20
        /// Small status indicator dot (shell running, backend state).
        static let indicatorDotSize: CGFloat = 8
        /// Trailing-aligned label column in inspector / sheet rows.
        static let formLabelWidth: CGFloat = 100
        /// Standard editable field width in sheets.
        static let fieldWidth: CGFloat = 144
        /// Wide text field (names, paths).
        static let wideFieldWidth: CGFloat = 200
        /// Wide pop-up menu whose rows carry a subtitle (distribution picker).
        static let wideMenuWidth: CGFloat = 300
        /// Narrow field (counts, small integers, probabilities).
        static let narrowFieldWidth: CGFloat = 96
        /// Compact field inside a per-class table row and in every
        /// "min … max" range pair (DSRangeFields).
        static let compactFieldWidth: CGFloat = 84
        /// Unit column beside a field so rows line up ("time units" fits).
        static let unitColumnWidth: CGFloat = 72
        /// The "?" (glossary) column at the trailing edge of every
        /// `.form` / `.inspector` row. Reserved whether or not the row has a
        /// glossary entry, so a row with a "?" and the row above it without
        /// one end at the same x — the button is `iconButtonWidth` wide.
        static let glossaryColumnWidth: CGFloat = iconButtonWidth
        /// Longest pop-up title a Settings menu row may carry: what fits in
        /// the detail column at `Window.settingsMinWidth` beside a label,
        /// the "?" column and the pop-up's own chrome. `SettingsMenuTitleAudit`
        /// measures every title against it in debug builds.
        static let settingsMenuTitleMaxWidth: CGFloat = 200
        /// Fixed-width live readout next to sliders / status values.
        static let readoutWidth: CGFloat = 56
        /// Zoom percentage readout in the status bar and zoom cluster.
        static let zoomReadoutWidth: CGFloat = 40
        /// Zero-height marker row a scroll view watches to know it is
        /// pinned to the bottom (status log, AI transcript). One point,
        /// because a true zero-height row never reports `onAppear`.
        static let scrollSentinelHeight: CGFloat = 1
        /// A view that exists only to be measured or to host an AppKit
        /// probe, and must not be seen: the persistence probe, the
        /// window-accessor NSView.
        static let hiddenProbeSize: CGFloat = 0
        /// An invisible view that must still be a target — the per-link
        /// accessibility elements laid over the canvas. One point, because
        /// a zero-sized element is not exposed to VoiceOver.
        static let accessibilityProbeSize: CGFloat = 1
        /// Fixed widths a `DSGallery` specimen pins its controls to, so
        /// pills and chips with different label lengths line up down the
        /// page and the three appearance columns agree row for row.
        static let gallerySpecimenWidth: CGFloat = 120
        static let gallerySpecimenWideWidth: CGFloat = 140
        /// Height of a boxed specimen (an empty state, a stack of chips).
        static let gallerySpecimenHeight: CGFloat = 180
        static let gallerySpecimenShortHeight: CGFloat = 150
        /// Minimum width of a titled push button whose label changes width
        /// while visible ("Copy" ⇄ "Copied"), so the button does not jump.
        static let buttonMinWidth: CGFloat = 72
        /// Width reserved for a 3-digit count in the status bar.
        static let counterWidth: CGFloat = 24
        /// Glyph disc in a sheet header.
        static let sheetGlyphSize: CGFloat = 44
        /// Icon column width inside palette buttons.
        static let paletteIconWidth: CGFloat = 20
        /// Coloured dot of a `ClassChip`.
        static let classDotSize: CGFloat = 10
        /// Short colour bar inside a swatch `DSBadge` (canvas class legend).
        static let swatchBarWidth: CGFloat = 20
        static let swatchBarHeight: CGFloat = 3
        /// Slider track in a labelled-slider row.
        static let sliderMinWidth: CGFloat = 140
        static let sliderIdealWidth: CGFloat = 200
        /// Pop-up font menu in pane headers.
        static let fontMenuMaxWidth: CGFloat = 140
        /// Height of one DS field row without its message slot — what a
        /// `DSInspectorRowPlaceholder` reserves.
        static let fieldRowHeight: CGFloat = 24
        /// Readable measure for running text (~72 characters at body size).
        static let readingMeasure: CGFloat = 640
        /// Popover content width band (flag-bar details, help popovers).
        static let popoverMinWidth: CGFloat = 320
        static let popoverIdealWidth: CGFloat = 380
        static let popoverMaxWidth: CGFloat = 460
        /// Compact popover (glossary "?" explanations).
        static let popoverCompactWidth: CGFloat = 280
        /// Wide, scrollable reference popover (preformatted solver help).
        static let popoverWideWidth: CGFloat = 520
        static let popoverWideHeight: CGFloat = 400
        /// Sheet widths: every modal sheet opens at one of these three.
        static let sheetWidth: CGFloat = 560
        static let sheetWidthWide: CGFloat = 640
        /// Resizable sheet band around `sheetWidth` (see `DSSheetSize`).
        static let sheetMinWidth: CGFloat = 500
        static let sheetMaxWidth: CGFloat = 720
        static let sheetMaxWidthWide: CGFloat = 820
        /// Width band for a sheet whose content is a wide data table —
        /// today only the node inspector's per-class service table (class
        /// chip, distribution menu, two parameter fields with captions,
        /// three readouts and a row menu need ≈660 pt of form content).
        /// `DSSheetSize.table`.
        static let sheetMinWidthTable: CGFloat = 760
        static let sheetWidthTable: CGFloat = 800
        static let sheetMaxWidthTable: CGFloat = 1000
        /// Sheet height bands (see `DSSheetSize`). Every sheet in the app
        /// opens at one of four heights and resizes inside one of three
        /// bands; nothing writes a height literal of its own.
        static let sheetMinHeightCompact: CGFloat = 360
        static let sheetMinHeight: CGFloat = 424
        static let sheetMinHeightWide: CGFloat = 480
        static let sheetHeightCompact: CGFloat = 400
        static let sheetHeightRegular: CGFloat = 544
        static let sheetHeightTall: CGFloat = 600
        static let sheetHeightWide: CGFloat = 624
        static let sheetMaxHeightCompact: CGFloat = 600
        static let sheetMaxHeightRegular: CGFloat = 800
        static let sheetMaxHeight: CGFloat = 904
        /// Height one repeated row adds to a sheet that grows with its
        /// content (`DSSheetSize.height(forRows:)`): a per-class table row
        /// is a `fieldRowHeight` control plus its caption and row gap.
        static let tableRowHeight: CGFloat = 40

        // Panes and wells --------------------------------------------------
        /// Station-picture tile in the picture picker: the preview circle a
        /// grid cell draws (the sheet-header glyph is `sheetGlyphSize`).
        static let pictureTileSize: CGFloat = 56
        /// Height cap on a fenced code block in the AI transcript. Longer
        /// blocks scroll inside the cap (both axes) instead of pushing the
        /// composer off-screen.
        static let codeWellMaxHeight: CGFloat = 320
        /// Height cap on a tool-call input / result well before it scrolls.
        static let toolWellMaxHeight: CGFloat = 220
        /// Line count above which a code / tool well offers "Show all N lines".
        static let wellExpandLineCount: Int = 12
        /// Longest a document tab's title grows before it truncates.
        static let tabMaxTitleWidth: CGFloat = 220
        /// Status / provider chip in a pane header (AI backend chip).
        static let chipMaxWidth: CGFloat = 220
        /// Leading info area of a pane header (Shell directory + state dot).
        static let paneHeaderInfoMaxWidth: CGFloat = 360
        /// Minimum width of one cell in a rendered Markdown table.
        static let tableCellMinWidth: CGFloat = 44
        /// Slot a pane header reserves for a control that comes and goes
        /// while the pane is on screen (the AI pane's Stop button). The
        /// slot is always laid out and only its content changes, so
        /// sending a message never shifts the controls beside it.
        static let headerTransientSlotWidth: CGFloat = 72
        /// Pane widths below which a header folds its font menu and A± into
        /// one overflow menu instead of squeezing its title. Measured, not
        /// guessed: the AI header keeps title + provider chip + Stop slot +
        /// four icon buttons at 380 pt; the Shell header keeps title +
        /// state dot + directory + six icon buttons at 560 pt. A control
        /// added to either header must be re-measured against its number.
        static let headerCondenseWidthNarrow: CGFloat = 380
        static let headerCondenseWidthWide: CGFloat = 560
        /// Filter-row width from which a search field can carry its "k of
        /// n" match readout without squeezing the field itself (segmented
        /// filter ≈ 165 pt + a usable field ≈ 90 pt + the readout).
        static let matchCountMinRowWidth: CGFloat = 320
        /// Determinate solver-progress bar in the application status bar.
        static let runProgressWidth: CGFloat = 72
        /// Fixed slot for the status bar's "47% · 1:12" run readout, so
        /// the percentage and the clock do not jitter the bar as they tick.
        static let runReadoutWidth: CGFloat = 88
        /// One line of a `DSTextArea` (the multi-line well in a settings
        /// row), so a caller sizes it in lines — "five lines, growing to
        /// ten" — instead of in the two point literals this replaced.
        static let textAreaLineHeight: CGFloat = 16
        /// Scrolling detail list inside a flag-bar popover.
        static let popoverListMaxHeight: CGFloat = 264
        /// Exact height of the reserved message row under a per-class
        /// table row (the `.bare` layout's stand-in for the form message
        /// slot): one `DS.Font.caption` line plus its bottom gap, so an
        /// empty slot and a settled error are the SAME height to the point.
        static let tableMessageHeight: CGFloat = 20
        /// Docked Inspector pane (right column, above the Status pane):
        /// tall enough for a station's Identity + Capacity + Service
        /// sections before the form scrolls.
        static let inspectorPaneMinHeight: CGFloat = 200
        static let inspectorPaneIdealHeight: CGFloat = 360
        /// Width the right column needs while the Inspector is shown: a
        /// grouped form row (label, 144-pt field, "?" button) plus the
        /// form's own insets. Wider than the Status pane's minimum.
        static let inspectorPaneMinWidth: CGFloat = 288
        static let inspectorPaneIdealWidth: CGFloat = 320
        /// The right column (Inspector above Status) has ONE width whichever
        /// of its two panes is showing — the larger of the two panes'
        /// needs — so toggling the Inspector never widens the column (and,
        /// through the coupled-width mirror, the AI pane under it) under
        /// the pointer. The column's size is saved under
        /// `SplitPane.TopHSplit.right`.
        static let rightColumnMinWidth: CGFloat = inspectorPaneMinWidth
        static let rightColumnIdealWidth: CGFloat = inspectorPaneIdealWidth
        /// Status pane (right column, below the Inspector): header, filter
        /// row and a few log lines before the list scrolls.
        static let statusPaneMinHeight: CGFloat = 200

        // About / Release Notes chrome ---------------------------------------
        /// App-icon plate in the About window.
        static let aboutIconSize: CGFloat = 96
        /// Measure of the About window's centred prose column.
        static let aboutColumnWidth: CGFloat = 336
        /// Label column of the About window's build-info grid, and the
        /// matching value column of the Release Notes version list.
        static let aboutLabelWidth: CGFloat = 96
        static let aboutDetailWidth: CGFloat = 320
        /// Bullet gutter in Release Notes prose.
        static let bulletWidth: CGFloat = 12

        // Split-view panes (main window) --------------------------------------
        // All on the 8-pt grid so a dragged divider lands on it too.
        static let palettePaneMinWidth: CGFloat = 152
        static let palettePaneIdealWidth: CGFloat = 176
        static let palettePaneMaxWidth: CGFloat = 240
        static let canvasPaneMinWidth: CGFloat = 496
        static let sidePaneMinWidth: CGFloat = 224
        static let sidePaneIdealWidth: CGFloat = 256
        static let canvasRowMinHeight: CGFloat = 320
        static let canvasRowIdealHeight: CGFloat = 520
        static let bottomRowMinHeight: CGFloat = 192
        static let bottomRowIdealHeight: CGFloat = 248
        /// Ideal height of the bottom row under the Shell-dominant workspace
        /// preset, where the interactive shell is the centrepiece rather
        /// than a footer: enough for a Run Comparison table's ~28 rows plus
        /// its banner without scrolling, at the default monospace size.
        static let shellRowIdealHeight: CGFloat = 424
        /// Clearance under the terminal's last text row.
        ///
        /// macOS rounds the window's bottom corners, and the Shell sits on the
        /// bottom edge, so a terminal laid out flush to y = 0 has its final
        /// line — usually the live prompt — sliced by the corner arc. The
        /// terminal draws its own background, so the inset is invisible except
        /// that the last row is now whole. Sized to clear the system corner
        /// radius at the bottom-left, where the prompt begins.
        static let terminalBottomInset: CGFloat = 10
        /// Settings sidebar (NavigationSplitView column band).
        static let settingsSidebarMinWidth: CGFloat = 208
        static let settingsSidebarIdealWidth: CGFloat = 232
        static let settingsSidebarMaxWidth: CGFloat = 280
        /// Help sidebar (NavigationSplitView column band).
        static let helpSidebarMinWidth: CGFloat = 224
        static let helpSidebarIdealWidth: CGFloat = 248
        static let helpSidebarMaxWidth: CGFloat = 320

        /// Window minimum and ideal sizes. Five auxiliary windows used to
        /// carry five unrelated numbers; there are now two bands — `aux`
        /// for the reference windows (Help, Release Notes, plain help text)
        /// and `settings` — plus the main document window.
        enum Window {
            static let mainMinWidth: CGFloat = 1000
            static let mainMinHeight: CGFloat = 720
            static let settingsMinWidth: CGFloat = 704
            static let settingsIdealWidth: CGFloat = 760
            static let settingsMinHeight: CGFloat = 520
            static let settingsIdealHeight: CGFloat = 600
            /// Reference windows that host a sidebar + a reading column.
            static let auxMinWidth: CGFloat = 720
            static let auxMinHeight: CGFloat = 560
            /// The widest of them (Qnet Help) needs its sidebar plus a full
            /// reading measure before the split view starts collapsing.
            static let auxWideMinWidth: CGFloat = 896
            static let auxWideMinHeight: CGFloat = 616

            /// Opening size of a reference window, and of the wide one.
            /// `AuxiliaryWindow.make(contentSize:minSize:)` takes these,
            /// so all four auxiliary windows open at one of two sizes.
            static var auxContent: NSSize { NSSize(width: 816, height: 640) }
            static var auxMin: NSSize { NSSize(width: auxMinWidth, height: auxMinHeight) }
            static var auxWideContent: NSSize { NSSize(width: 1040, height: 704) }
            static var auxWideMin: NSSize {
                NSSize(width: auxWideMinWidth, height: auxWideMinHeight)
            }
            /// The About panel is the one fixed-size window: its content
            /// size and the SwiftUI view's outer frame must be identical
            /// (see AboutQnetWindow.swift) so AppKit never renegotiates.
            static var aboutPanel: NSSize { NSSize(width: 400, height: 392) }

            // No `dialog*` sizes live here. A movable dialog panel
            // (`DSPanelWindow`) hosts the *same body* a sheet would, and
            // that body already carries `.dsSheetFrame(size)`, so the
            // panel's opening size, minimum and maximum all come from the
            // `DSSheetSize` band it is presented at. A second, parallel set
            // of dialog sizes here contradicted those bands (440 × 320 was
            // below `.compact`'s minimum; 840 exceeded `.wide`'s maximum)
            // and had no call site; it was removed rather than re-derived.

            /// A pane torn out of the main window into its own window.
            /// Wide enough that a Run Comparison table (~110 columns at the
            /// terminal's monospace metrics) does not wrap in a detached
            /// Shell, which is the pane most likely to be torn out first.
            static var detachedPaneDefault: NSSize { NSSize(width: 880, height: 560) }
            static var detachedPaneMin: NSSize { NSSize(width: 480, height: 280) }
        }
    }

    // MARK: - Motion

    /// Every animation in the app comes from here, and every one of them
    /// is `nil` — i.e. an instant state change with no interpolation —
    /// while the system's Reduce Motion switch is on. `Animation?` is what
    /// both `withAnimation(_:_:)`, `.animation(_:value:)` and
    /// `Binding.animation(_:)` already take, so call sites are unchanged.
    enum Motion {
        static let fast: Double = 0.15
        static let normal: Double = 0.25
        /// Hover, press, selection, border and caption changes.
        static var quick: Animation? {
            A11y.reduceMotion ? nil : .easeInOut(duration: fast)
        }
        /// Layout changes: a pane appearing, a section swapping, a sheet
        /// growing a row.
        static var standard: Animation? {
            A11y.reduceMotion ? nil : .easeInOut(duration: normal)
        }
        /// Seconds a caller should wait for `standard` to finish before
        /// acting on the settled layout — zero under Reduce Motion.
        static var standardSettleDelay: Double { A11y.reduceMotion ? 0 : normal }

        /// The `TimeInterval`s behind `quick` / `standard`, for AppKit call
        /// sites (`NSAnimationContext`) that cannot take an `Animation?`.
        /// Zero under Reduce Motion, so the change lands instantly — the
        /// same contract the SwiftUI tokens keep by returning `nil`.
        static var quickDuration: TimeInterval { A11y.reduceMotion ? 0 : fast }
        static var standardDuration: TimeInterval { A11y.reduceMotion ? 0 : normal }

        /// The one AppKit animation group in the app. `changes` sets
        /// properties through `.animator()` proxies; the duration is one of
        /// the tokens above (the Shell's overlay scrollers fade with
        /// `quickDuration` in and `standardDuration` out). Building an
        /// `NSAnimationContext` at a call site with its own literal is what
        /// `design_lint.sh` forbids, because that literal cannot honour
        /// Reduce Motion.
        @MainActor
        static func animateAppKit(_ duration: TimeInterval, _ changes: () -> Void) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                changes()
            }
        }

        /// The camera glide when the canvas zooms or recentres itself
        /// (Zoom to Fit, Actual Size, Zoom to Selection). Eased out only:
        /// a viewport moving under the pointer has to decelerate into
        /// place, and ease-in reads as lag on a gesture the user has
        /// already committed to. This is the ONLY curve in the app that is
        /// not `quick` or `standard`, and it is a token so the canvas
        /// stops building its own — it was `.easeOut(duration: 0.18)`
        /// written inline, which also meant the canvas kept animating
        /// under Reduce Motion while the rest of the window went still.
        static let glide: Double = 0.20
        static var canvasGlide: Animation? {
            A11y.reduceMotion ? nil : .easeOut(duration: glide)
        }

        /// A fade-out whose duration the caller owns (the Settings pane's
        /// "here is the row you searched for" flash, which fades with the
        /// highlight timeout). Returns `nil` under Reduce Motion like the rest.
        static func fadeOut(duration: Double) -> Animation? {
            A11y.reduceMotion ? nil : .easeOut(duration: duration)
        }
    }

    // MARK: - Typography

    enum Font {
        // Text styles (SF Pro) -------------------------------------------
        // Real macOS point sizes (NSFont text styles, default content size):
        //   largeTitle 26   title 22   title2 17   title3 15
        //   headline   13 bold        body 13     callout 12
        //   subheadline 11             footnote 10  caption 10  caption2 10
        // footnote, caption and caption2 are the SAME 10-pt font on macOS,
        // so there is ONE 10-pt text token here, and it is `caption`. The
        // `footnote` / `monoFootnote` aliases were deleted: five files
        // wrote one and thirteen wrote the other for the identical font,
        // which is the one thing a scale must not allow. Glyph-only
        // tokens that need to be smaller than 10 pt (`chevron`,
        // `glyphSmall`, `keycap`) are the sanctioned point-size exception
        // below — a chevron is not text and does not follow Dynamic Type.
        static var caption: SwiftUI.Font { .caption }
        static var subheadline: SwiftUI.Font { .subheadline }
        static var callout: SwiftUI.Font { .callout }
        static var body: SwiftUI.Font { .body }
        /// 13-pt bold on macOS (NSFont headline). For a 13-pt *semibold*
        /// title use `sectionTitle`.
        static var headline: SwiftUI.Font { .headline }
        static var title3: SwiftUI.Font { .title3 }
        static var title2: SwiftUI.Font { .title2 }
        /// 22-pt semibold: the app name in About, help-topic titles.
        static var pageTitle: SwiftUI.Font { .title.weight(.semibold) }
        static var largeTitle: SwiftUI.Font { .largeTitle.weight(.bold) }

        /// Pane, section and popover titles (DSSectionHeader): 13-pt semibold.
        static var sectionTitle: SwiftUI.Font { .body.weight(.semibold) }
        /// Sheet titles (DSSheetHeader) and version headings: 17-pt semibold.
        static var sheetTitle: SwiftUI.Font { .title2.weight(.semibold) }
        /// Glyph inside a 44-pt sheet-header disc.
        static var sheetGlyph: SwiftUI.Font { .title2.weight(.semibold) }
        /// Labels and icons inside toolbar-style controls.
        static var control: SwiftUI.Font { .body.weight(.medium) }
        /// Icon inside a 24-pt icon button.
        static var iconButton: SwiftUI.Font { .callout.weight(.medium) }
        /// Small emphasised text (tab titles, pill labels).
        static var label: SwiftUI.Font { .callout }
        static var labelEmphasis: SwiftUI.Font { .callout.weight(.semibold) }
        /// Captions in chrome (status bar, header subtitles, chips).
        static var chrome: SwiftUI.Font { .subheadline }
        static var chromeEmphasis: SwiftUI.Font { .subheadline.weight(.semibold) }
        /// Column headers in tables.
        static var tableHeader: SwiftUI.Font { .caption.weight(.semibold) }

        // Glyph-only sizes (sanctioned point-size exception; not text) -----
        /// Tiny bold glyph (tab close ×): 9 pt.
        static var glyphSmall: SwiftUI.Font { .system(size: 9, weight: .bold) }
        /// Menu chevron next to a control label: 8 pt.
        static var chevron: SwiftUI.Font { .system(size: 8, weight: .semibold) }
        /// Keycap text (ShortcutBadge): 9-pt monospaced.
        static var keycap: SwiftUI.Font { .system(size: 9, weight: .medium, design: .monospaced) }
        /// Hero text — the app name in the About window only.
        static var hero: SwiftUI.Font { .system(size: 48, weight: .medium) }

        /// A font-family menu item drawn in its own face, at the body size,
        /// so the user can see what they are choosing (Settings font rows).
        static func familyPreview(_ family: String) -> SwiftUI.Font {
            .custom(family, size: NSFont.systemFontSize, relativeTo: .body)
        }

        // Numbers (monospaced digits, proportional letters) --------------
        static var number: SwiftUI.Font { .body.monospacedDigit() }
        static var numberEmphasis: SwiftUI.Font { .body.weight(.semibold).monospacedDigit() }
        static var numberSmall: SwiftUI.Font { .subheadline.monospacedDigit() }
        static var numberSmallEmphasis: SwiftUI.Font { .subheadline.weight(.semibold).monospacedDigit() }
        static var numberCaption: SwiftUI.Font { .caption.monospacedDigit() }

        // Monospaced (SF Mono) — formulas, code, paths ---------------------
        static var mono: SwiftUI.Font { .system(.body, design: .monospaced) }
        static var monoEmphasis: SwiftUI.Font { .system(.body, design: .monospaced).weight(.semibold) }
        static var monoCallout: SwiftUI.Font { .system(.callout, design: .monospaced) }
        static var monoCalloutEmphasis: SwiftUI.Font { .system(.callout, design: .monospaced).weight(.semibold) }
        static var monoSubheadline: SwiftUI.Font { .system(.subheadline, design: .monospaced) }
        /// 10-pt monospaced (footnote = caption on macOS).
        static var monoCaption: SwiftUI.Font { .system(.caption, design: .monospaced) }

        /// Sanctioned exception: user-adjustable monospaced panes
        /// (Status log, AI transcript, terminal) whose point size is an
        /// `@AppStorage` value the user changes with the A+/A- buttons.
        static func userMono(size: Double) -> SwiftUI.Font {
            .system(size: CGFloat(size), design: .monospaced)
        }
        /// One step smaller than `userMono` — timestamps beside a log line.
        static func userMonoCaption(size: Double) -> SwiftUI.Font {
            .system(size: CGFloat(max(9, size - 1)), design: .monospaced).monospacedDigit()
        }
        /// Two steps smaller, medium weight — the severity symbol of a log line.
        static func userMonoSymbol(size: Double) -> SwiftUI.Font {
            .system(size: CGFloat(max(9, size - 2)), weight: .medium)
        }

        /// Sanctioned exception: proportional prose in the AI transcript.
        /// `AppSettings.aiFontSize` governs prose (SF Pro) and code (the
        /// chosen monospaced family) alike, so the two read at one size.
        static func userProse(size: Double) -> SwiftUI.Font {
            .system(size: CGFloat(size))
        }
        /// Markdown heading in the transcript: h1 / h2 / h3+ step up from
        /// the prose size at 1.45 / 1.25 / 1.1.
        static func userProseHeading(size: Double, level: Int) -> SwiftUI.Font {
            let scale: CGFloat = level <= 1 ? 1.45 : (level == 2 ? 1.25 : 1.1)
            return .system(size: CGFloat(size) * scale, weight: .semibold)
        }
        /// Two steps smaller — the hover timestamp beside a transcript row.
        static func userProseCaption(size: Double) -> SwiftUI.Font {
            .system(size: CGFloat(max(9, size - 2))).monospacedDigit()
        }

        /// Sanctioned exception: an SF Symbol inscribed in a disc of
        /// `diameter` points (station picture previews).
        static func glyph(fitting diameter: CGFloat, weight: SwiftUI.Font.Weight = .light) -> SwiftUI.Font {
            .system(size: diameter * 0.45, weight: weight)
        }
    }

    // MARK: - Canvas (zoom-scaled labels)

    /// Canvas labels are laid out in display space with a point size
    /// clamped for legibility rather than scaled linearly with the zoom.
    /// One family everywhere on the canvas: SF Pro with monospaced digits,
    /// which reads better than SF Mono for mixed text like "μ=2.5".
    enum Canvas {
        /// Base point size of node names on the canvas at zoom 1.0. Every
        /// other canvas label derives from this one constant.
        static let labelSize: CGFloat = 10
        /// Routing-probability labels on links.
        static var linkLabelSize: CGFloat { labelSize - 1 }

        /// Display-space point size of a node name at `scale`.
        static func nameSize(scale: CGFloat) -> CGFloat {
            max(9, min(13, labelSize * scale))
        }

        /// Node name.
        static func nameDisplayFont(scale: CGFloat) -> SwiftUI.Font {
            .system(size: nameSize(scale: scale), weight: .semibold).monospacedDigit()
        }

        /// Detail lines under a node (distribution, μ, SCV).
        static func detailDisplayFont(scale: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: max(8, nameSize(scale: scale) - 2), weight: weight).monospacedDigit()
        }

        /// Routing-probability chip on a link.
        static func linkLabelDisplayFont(scale: CGFloat) -> SwiftUI.Font {
            .system(size: max(9, min(12, linkLabelSize * scale)), weight: .medium).monospacedDigit()
        }

        /// Utilisation badge text — never scales below the caption size.
        static var badgeFont: SwiftUI.Font { DS.Font.numberCaption.weight(.semibold) }

        /// Below this zoom the distribution row is hidden.
        static let detailRowMinScale: CGFloat = 0.45
        /// Below this zoom the μ / SCV row is hidden.
        static let rateRowMinScale: CGFloat = 0.6
        /// Below this zoom the node name is hidden too (a hovered or
        /// selected node keeps it).  `nameSize` stops shrinking at 9 pt,
        /// so under ~35 % a 200-node network was a pile of overlapping
        /// 9-pt names inside 17-pt bodies; the full text stays in the
        /// tooltip.
        static let nameRowMinScale: CGFloat = 0.35
        /// Below this zoom routing-probability chips are dropped from
        /// links; above it `LinkLayerCanvas` still skips a chip whose
        /// rect would overlap one already drawn this frame.
        static let linkLabelMinScale: CGFloat = 0.5
    }

    // MARK: - Numbers (formatting and parsing shared by every field)

    enum Number {
        /// Precision of a *read-only* number the app derives and shows
        /// back to the user: the inspectors' mean / SCV / μ readouts and
        /// table cells, the routing-probability column and its total, the
        /// flag-bar popover's predicted means. One rule for one quantity —
        /// the per-class table used to say 0.6667 while the distribution
        /// card two inches below said 0.66667 for the same number.
        /// Values the user typed are never reformatted; see `fieldText`.
        static let readoutDigits = 5

        /// Format a double for display in derived-value rows and previews
        /// (up to `significantDigits` significant digits, no trailing noise).
        static func format(_ value: Double, significantDigits: Int = 6) -> String {
            guard value.isFinite else { return value.isNaN ? "—" : "∞" }
            return value.formatted(.number.precision(.significantDigits(1...significantDigits)))
        }

        /// Format a *solver result* for display at exactly `decimals`
        /// fraction digits — the one authority behind Settings ▸ Output
        /// Format ▸ Output decimals.
        ///
        /// This is deliberately a DIFFERENT rule from `format(_:significantDigits:)`
        /// above: a readout the app derives from what the user typed keeps
        /// significant-digit precision, while every number a solver reports
        /// is pinned to one fraction length so two methods printed side by
        /// side line up digit for digit. Set the pref to 3 and every
        /// algorithm's E[X] shows three decimals, whatever the solver printed.
        ///
        /// Semantics match the `fmt7` awk function that formats the
        /// comparison tables (QnetGUIApp.swift), so the awk-rendered tables
        /// and the Swift-rendered surfaces can never disagree:
        ///   * empty text and the em-dash placeholder pass through unchanged
        ///     (callers hand those through as "not applicable", not as zero);
        ///   * NaN prints "—" and an infinity prints "∞";
        ///   * everything else is `%.<decimals>f`, except that a magnitude at or
        ///     above 1e9 falls back to scientific for the same reason a magnitude
        ///     below 10^-decimals does, and a signed zero loses its sign.
        ///
        /// The one addition is the small-magnitude fallback: a non-zero value
        /// below the smallest representable step would otherwise print as a
        /// flat "0.000" and read as an exact zero, which for a blocking
        /// probability or a residual is the difference between "negligible"
        /// and "none". Those fall back to scientific notation instead.
        /// `decimals` is clamped to the pref's own 0...9 range.
        static func display(_ value: Double, decimals: Int) -> String {
            guard !value.isNaN else { return "—" }
            guard value.isFinite else { return value < 0 ? "-∞" : "∞" }
            let d = max(0, min(9, decimals))
            // Symmetric magnitude guards. Below 10^-d a fixed rendering prints a
            // flat zero for a value that is not zero; at or above 1e9 it prints
            // up to twenty digits of floating-point noise the solver never
            // computed, in a cell sized for eight characters. The same two
            // thresholds are spelled in `fmt7` (buildComparisonAwk) and in the
            // terminal's display-precision filter, and the three must agree or
            // the Shell and the Results pane show different numbers.
            let small = d > 0 && abs(value) < pow(10.0, Double(-d))
            let large = abs(value) >= 1e9
            let text = (value != 0 && (small || large))
                ? String(format: "%.\(max(1, d - 1))e", value)
                : String(format: "%.\(d)f", value)
            // A displayed "-0.000" reads as a sign error rather than as a small
            // negative. Both other formatters strip it; this one used to not,
            // so the same value showed as "0" in the Shell and "-0" here.
            if text.hasPrefix("-"), Double(text.dropFirst()) == 0 {
                return String(text.dropFirst())
            }
            return text
        }

        /// `display(_:decimals:)` for text that may not be a number at all:
        /// empty strings and the em-dash placeholder pass through untouched,
        /// anything unparseable is returned verbatim. Use this when
        /// normalizing a field lifted out of solver output, where a column
        /// can legitimately hold "—" or a label.
        static func display(text: String, decimals: Int) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "—" else { return text }
            guard let v = Double(trimmed) else { return text }
            return display(v, decimals: decimals)
        }

        /// Format a value for a text field (plain digits, locale-neutral so
        /// the value round-trips through `parse`).
        static func fieldText(_ value: Double) -> String {
            guard value.isFinite else { return "" }
            return String(format: "%.10g", value)
        }

        /// Parse user input from a numeric text field. Accepts the locale
        /// format ("1,000.5"), plain decimal and scientific notation ("1e-3"),
        /// and a comma typed as the decimal separator ("0,5" = 0.5).
        static func parse(_ text: String) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Canonical form first (what `fieldText` writes, plus "1e-3"), so
            // round-trips are locale-independent.
            if let v = Double(trimmed), v.isFinite { return v }
            // A comma the locale parser would read as a grouping mark but
            // that cannot be one ("0,5", "1,25") is the decimal separator the
            // user typed; decide that before the locale parse, which would
            // silently turn "0,5" into 5.
            if commaIsDecimalSeparator(trimmed),
               let v = Double(trimmed.replacingOccurrences(of: ",", with: ".")), v.isFinite { return v }
            if let v = try? Double(trimmed, format: .number), v.isFinite { return v }
            // Last resort: a comma decimal separator alongside other punctuation.
            if let v = Double(trimmed.replacingOccurrences(of: ",", with: ".")), v.isFinite { return v }
            return nil
        }

        /// True when the single comma in `text` cannot be a grouping mark on
        /// this locale — one comma, no period, and a fraction that is not the
        /// three digits a grouped thousand would have ("1,000" stays 1000).
        private static func commaIsDecimalSeparator(_ text: String) -> Bool {
            guard Locale.current.decimalSeparator == ".", !text.contains(".") else { return false }
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return false }
            return parts[1].count != 3
        }

        static func parseInt(_ text: String) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let v = try? Int(trimmed, format: .number) { return v }
            return Int(trimmed)
        }

        /// True for text that is an incomplete but plausible number
        /// ("-", ".", "1e", "1e-", "1,") — used by `.live` validation so a
        /// field does not flash the danger border mid-keystroke.
        static func isPartialNumber(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return true }
            if t == "-" || t == "+" || t == "." || t == "," || t == "-." || t == "-," { return true }
            let lower = t.lowercased()
            if lower.hasSuffix("e") || lower.hasSuffix("e-") || lower.hasSuffix("e+") {
                return parse(String(lower.prefix(while: { $0 != "e" }))) != nil
            }
            return false
        }
    }

    // MARK: - Glossary (help strings for jargon-only labels)

    enum Glossary {
        static let lambda = "λ — arrival rate: mean number of jobs entering per unit time (1 / mean interarrival time)."
        static let mu = "μ — service rate: mean number of jobs a single server completes per unit time (1 / mean service time)."
        static let rho = "ρ — utilisation: fraction of time the station is busy (λ / (c·μ)). Must be below 1 for stability."
        static let gamma = "Γ — throughput: long-run rate of jobs leaving the station. In steady state what enters leaves, so for a stable station with unbounded buffers it equals its effective arrival rate from the traffic equations. Solvers print it as the Gamma_N line of their compact output."
        static let covariance = "Γ — covariance matrix of the Brownian motion driving the SRBM: a d × d matrix (d stations) built from the arrival and service variability and the routing, written row by row after the drift θ. Not the throughput Γ of the solver output — the same letter, a different quantity."
        static let scv = "SCV (c²) — squared coefficient of variation: variance divided by the square of the mean. 1 for exponential, 0 for deterministic, above 1 for bursty."
        static let servers = "c — number of parallel servers at this station (c ≥ 1)."
        static let bas = "BAS — blocking after service: a finished job waits at its server until the downstream buffer has room."
        static let mean = "Mean of the interarrival or service time, in the model's time unit."
        static let entryMode = "Native enters the distribution's own parameters; Mean & SCV enters the first two moments and Qnet solves for the parameters."
        static let distribution = "Probability distribution of the interarrival or service time."
        static let routingProbability = "Probability that a job leaving the source node follows this link (0–1). Outgoing probabilities of one node should sum to 1."
        static let customerClass = "Customer class carried by this link. Classes may have different routes and service distributions."
        static let bufferSize = "Maximum number of jobs the buffer can hold. Arrivals that find it full are blocked or lost."
        // Solver terms shared by the Settings panes and the run dialogs.
        // One definition per quantity: Settings ▸ Linear Program and the
        // Run Linear Program sheet show the SAME text for grid_n, and the
        // Finite Element pane and its run sheet the same text for the mesh.
        static let meshSize = "Number of finite elements along each axis of the hypercube. The mesh has nᵈ cells for d stations, and assembling it costs about n²ᵈ, so a mesh that is comfortable at two stations is impossible at five."
        static let gridN = "grid_n — points per axis of the discretisation grid. The linear program has roughly grid_nᵈ variables for d stations, so the usable grid shrinks quickly as the network grows."
        static let basisM = "basis_m — number of polynomial (monomial) basis functions used per boundary block. More terms fit the boundary density better but make the linear program larger and worse conditioned."
        static let smoothness = "Weight on a penalty that discourages curvature in the fitted density. Zero disables the penalty; larger values give a smoother, less peaked fit and break a degenerate LP toward one solution."
        static let warmup = "Simulated time discarded before statistics start, so the estimate is not biased by the empty initial state. Measured in the model's time unit, not wall-clock seconds."
        static let replications = "Number of independent simulation runs averaged into the reported estimate. The 95 % half-width shrinks roughly as one over the square root of this."
        static let simulationTime = "Simulated time over which statistics are collected in each replication, in the model's time unit. Wall-clock cost scales with this × replications ÷ cores."
        // Settings terms for the solver back ends.
        static let epsilon = "ε — target root-mean-square error of the estimated stationary moments. Multilevel Monte Carlo keeps sampling until it expects to be this close, and the cost scales as 1/ε²: halving ε costs about four times the runtime."
        static let stepFactor = "γ — ratio between the time-step sizes of two consecutive MLMC levels. Smaller γ means less discretisation bias per level but more work per path; 1/γ must be a whole number."
        static let polynomialDegree = "Maximum total degree of the polynomials in the Galerkin trial space. Higher degree converges faster on a smooth density, but the linear system grows combinatorially with the number of stations."
        static let antithetic = "Antithetic variates — each sample is simulated together with its sign-flipped noise twin and the pair is averaged. The two are negatively correlated, so the variance roughly halves for about 1.5–2× the runtime, with no bias."
        static let batchSize = "Samples drawn between successive standard-error checks in adaptive mode. Larger batches check less often and may overshoot the target; smaller ones add bookkeeping."
        static let minSamples = "Adaptive sampling never stops before this many samples, however small the standard error looks — an early estimate can be optimistic."
        static let maxSamples = "Hard cap on samples in adaptive mode, so a run whose standard error never reaches the target still terminates."
        static let quadrature = "Quadrature is the numerical integration rule used to build the finite-element matrices. Gauss–Legendre places a small number of exactly-weighted points per element and is the accurate choice at low dimension; CBC quasi-Monte Carlo uses a lattice rule whose cost grows far more slowly with the number of stations."
        static let gridTypeOrthant = "How the grid_n points are spread along each axis. Exponential clusters them near the origin, where the stationary density has most of its mass; dyadic halves the spacing at each step; the randomised variant jitters the exponential grid to break ties in a degenerate LP."
        static let gridTypeRectangle = "How the grid_n points are spread along each axis of the rectangle. Uniform spaces them evenly; Chebyshev nodes cluster toward the two buffer boundaries, where a finite-buffer density changes fastest."
        static let lpBackend = "The linear-programming library that solves the relaxation. CPLEX is fastest on small networks (d ≤ 3), HiGHS scales better at d ≥ 4 and ships with the app, GLPK is the universal fallback. Auto picks the first one that is installed."
        static let mlmcBackend = "Threading library rbm_mlmc uses to run paths in parallel. OpenMP is fastest when the binary was built with it; Apple GCD uses Accelerate; Serial runs on one thread, which is useful for reproducing a run exactly."
        static let topology = "Feed-forward networks route every job strictly downstream. Jackson + feedback adds random return arcs; General P-matrix draws an arbitrary routing matrix; Re-entrant sends a class back to a station it has already visited, the case QNA-style decompositions find hardest."
        static let aiProvider = "Which chat-completion service the assistant talks to. Each provider keeps its own base URL, model name and API key, so switching back restores what was set for it."

        /// Every entry above, so a debug build can assert that a glossary
        /// string reaching a Settings row IS one of these and not a literal
        /// typed at the call site (`SettingsGlossaryAudit`). The lint checks
        /// that this list names every `static let` in the namespace.
        static let all: Set<String> = [
            lambda, mu, rho, gamma, covariance, scv, servers, bas, mean, entryMode, distribution,
            routingProbability, customerClass, bufferSize,
            meshSize, gridN, basisM, smoothness, warmup, replications, simulationTime,
            epsilon, stepFactor, polynomialDegree, antithetic, batchSize, minSamples, maxSamples,
            quadrature, gridTypeOrthant, gridTypeRectangle, lpBackend, mlmcBackend, topology, aiProvider,
        ]

        /// True when `text` is one of the entries above.
        static func isEntry(_ text: String) -> Bool { all.contains(text) }
    }

    // MARK: - Symbols (the app's SF Symbol vocabulary)

    /// One glyph per command, named once. Iconography is a design token
    /// like colour and spacing: before this existed, Zoom to Fit was
    /// `arrow.up.left.and.arrow.down.right` in the window toolbar and the
    /// mirrored `arrow.down.left.and.arrow.up.right` in the canvas zoom
    /// cluster (both on screen at the same time), and "clear this pane"
    /// was `trash` in two pane headers and `clear` in the third.
    ///
    /// Rules: a command that appears in more than one place uses the same
    /// constant in all of them; node-kind glyphs stay on `NodeKind.symbol`
    /// (the model owns them, and the canvas, palette and inspector already
    /// share that one source); and — since round 5 — **no view writes an
    /// SF Symbol name at all**. `design_lint.sh` rejects a literal after
    /// `systemImage:` / `systemName:` anywhere but this file, because
    /// "used exactly once" is how the vocabulary frayed the first time:
    /// thirty literals re-spelt tokens that already existed, and "warning"
    /// ended up drawn as a filled triangle in three places and an unfilled
    /// one in two others.
    enum Symbol {
        // View / zoom -------------------------------------------------------
        static let zoomIn = "plus.magnifyingglass"
        static let zoomOut = "minus.magnifyingglass"
        /// Zoom to Fit — "gather the drawing into the window". The inward
        /// arrows, not the outward pair (which reads as "expand").
        static let zoomToFit = "arrow.down.left.and.arrow.up.right"
        static let actualSize = "1.magnifyingglass"
        static let snapToGrid = "squareshape.split.3x3"
        static let grid = "square.grid.3x3"

        // Panes and windows ---------------------------------------------------
        /// Empty a pane's contents (Status log, AI transcript, Shell
        /// scrollback). One glyph for one action in all three headers.
        static let clearPane = "trash"
        static let paneLeft = "sidebar.left"
        static let paneRight = "sidebar.right"
        /// The docked Inspector pane (View ▸ Panes ▸ Inspector, the
        /// toolbar toggle, the Edit ▸ Edit Parameters… sheet's glyph).
        static let inspector = "slider.horizontal.3"
        static let paneSplit = "square.split.2x1"
        /// Tear a pane out of the main window into a window of its own, and
        /// put it back. One opposed pair, so the two actions read as one
        /// reversible thing in a header, a menu and a tooltip alike.
        static let detach = "rectangle.portrait.and.arrow.right"
        static let reattach = "rectangle.portrait.and.arrow.forward"
        /// Give one pane the whole window, and restore the split. Distinct
        /// from detach/reattach: the pane stays in this window.
        static let paneMaximize = "arrow.up.left.and.arrow.down.right"
        static let paneRestore = "arrow.down.right.and.arrow.up.left"
        /// Sort direction on a results-table column header. The chevron
        /// pair, not the arrow pair: the arrows already mean detach and
        /// maximize two lines above, and one glyph means one thing.
        static let sortAscending = "chevron.up"
        static let sortDescending = "chevron.down"
        static let terminal = "terminal"
        static let statusLog = "text.alignleft"
        static let assistant = "sparkles"
        /// Send the composer's message to the assistant.
        static let send = "paperplane.fill"
        /// Pane text-size stepper and monospaced-family menu.
        static let textSizeSmaller = "textformat.size.smaller"
        static let textSizeLarger = "textformat.size.larger"
        static let fontFamily = "textformat"

        // Editing ------------------------------------------------------------
        static let add = "plus"
        static let remove = "xmark"
        static let copy = "doc.on.doc"
        static let find = "magnifyingglass"
        static let clearField = "xmark.circle.fill"
        /// Show / hide a secret (the API-key field's eye button).
        static let reveal = "eye"
        static let conceal = "eye.slash"
        static let more = "ellipsis.circle"
        static let disclosure = "chevron.right"
        static let previous = "chevron.left"
        static let next = "chevron.right"
        /// Expand / collapse a section or a truncated well. The pair is
        /// down-to-open, up-to-close, everywhere in the app.
        static let expand = "chevron.down"
        static let collapse = "chevron.up"
        /// Step through a VERTICAL order: the inspectors' Previous / Next
        /// sibling buttons and Find Previous / Find Next. (`previous` /
        /// `next` are the horizontal pair, for a list laid out sideways.)
        static let stepPrevious = "chevron.up"
        static let stepNext = "chevron.down"
        /// Pull-down indicator drawn beside a control's own label.
        static let menuChevron = "chevron.down"
        /// A list of saved things (presets, model list).
        static let list = "list.bullet"

        // Runs and files -------------------------------------------------------
        static let run = "play.fill"
        /// Run, drawn at sheet-header size (`RunParameterSheet`'s glyph).
        static let runCircle = "play.circle"
        static let stop = "stop.fill"
        static let restart = "arrow.triangle.2.circlepath"
        static let refresh = "arrow.clockwise"
        static let undoHistory = "clock.arrow.circlepath"
        /// Release history (the Release Notes window's list glyph).
        static let versionHistory = "clock.arrow.circlepath"
        static let export = "square.and.arrow.up"
        static let download = "arrow.down.to.line"
        static let newFolder = "folder.badge.plus"
        static let randomNetwork = "dice"
        /// Monte Carlo / discrete-event simulation (the two Run Monte Carlo
        /// sheets, the Settings ▸ Monte Carlo tab). The same die as
        /// `randomNetwork` — both are "throw the dice" — named apart so
        /// re-glyphing one command never silently re-glyphs the other.
        static let simulation = "dice"
        static let testSet = "checklist"
        static let network = "point.3.connected.trianglepath.dotted"

        // Settings and Help navigation ---------------------------------------
        // A solver's Settings pane, its Help topic group and its run sheet
        // share one glyph (`simulation`, `formula`, `grid`, `increasing`,
        // `testSet` above); the tokens here are the panes and groups that
        // have no run sheet to borrow from.
        /// The Settings window itself (the General pane).
        static let settings = "gearshape"
        /// Choice of solver engine (Settings ▸ Solver Engine): the same
        /// computation, at two speeds.
        static let solverEngine = "speedometer"
        /// SRBM MLMC: one square per discretisation level.
        static let multilevel = "square.stack.3d.up"
        /// The finite-buffer LP — a rectangle domain split into cells,
        /// against `increasing` for the orthant LP.
        static let lpRectangle = "rectangle.split.3x3"
        /// Result-table number formatting (Settings ▸ Output Format).
        static let numberFormat = "textformat.123"
        /// Type and colours of the text panes (Settings ▸ Panes).
        static let textAppearance = "textformat.size"
        /// Help window groups: Concepts, Infinite-Buffer Methods, Workflows.
        static let concepts = "lightbulb"
        static let infiniteBuffers = "infinity"
        static let workflows = "list.bullet.clipboard"
        /// A link / flow from one node to the next (link counter, the link
        /// inspector's "S1 → S2" rows, the Link tool).
        static let link = "arrow.right"
        /// Re-entrant routing. The same glyph as `restart` today, named
        /// apart so the flag-bar pill and its popover can never drift and
        /// so re-colouring one does not silently re-colour the other.
        static let reentrant = "arrow.triangle.2.circlepath"
        /// Reach a network service (the AI backend connection test).
        static let connection = "antenna.radiowaves.left.and.right"

        // Status ----------------------------------------------------------------
        static let help = "questionmark.circle"
        static let info = "info.circle"
        static let success = "checkmark.circle.fill"
        static let warning = "exclamationmark.triangle.fill"
        static let error = "exclamationmark.circle.fill"
        static let failure = "xmark.octagon.fill"
        static let pending = "ellipsis.circle"
        static let verified = "checkmark.seal.fill"
        /// The off state of `verified` (flag-bar "Tractable" pill).
        static let unverified = "seal"
        /// "Nothing to report" — the off state of the Warnings pill.
        static let noIssues = "checkmark.circle"
        static let checkmark = "checkmark"
        static let blocked = "circle.slash"

        // Analysis ---------------------------------------------------------------
        static let formula = "function"
        static let increasing = "chart.line.uptrend.xyaxis"
        static let decreasing = "chart.line.downtrend.xyaxis"
        static let experiment = "flask"
        /// An assistant tool call in flight.
        static let toolCall = "wrench.and.screwdriver"

        // Canvas readouts ---------------------------------------------------
        /// Horizontal extent (the canvas width readout in the status bar).
        static let extentHorizontal = "arrow.left.and.right"
        /// Pan offset readout.
        static let pan = "arrow.up.and.down.and.arrow.left.and.right"
    }
}

// MARK: - Design-system internals

/// Small memo table for derived colours. `DS.Color.legibleTint(_:)` is
/// called two or three times per badge / pill render and would otherwise
/// allocate a dynamic `NSColor` (plus its resolver closure) every time.
/// Guarded by a lock and marked `@unchecked Sendable`, matching the
/// app's other cross-thread caches; `SwiftUI.Color` is `Hashable`, and the
/// keys are the `static let` tokens, so lookups hit.
final class ColorMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SwiftUI.Color: SwiftUI.Color] = [:]

    func color(for key: SwiftUI.Color, make: (SwiftUI.Color) -> SwiftUI.Color) -> SwiftUI.Color {
        lock.lock()
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let made = make(key)
        lock.lock()
        storage[key] = made
        lock.unlock()
        return made
    }
}

/// Cached mirror of the three `NSWorkspace` accessibility display flags
/// `DS` honours. Reading `NSWorkspace.shared` properties from a view body
/// on every frame is an IPC round-trip; this reads them once and refreshes
/// on `accessibilityDisplayOptionsDidChangeNotification`, which is exactly
/// when they can change.
final class AccessibilityFlags: @unchecked Sendable {
    static let shared = AccessibilityFlags()

    private let lock = NSLock()
    private var _reduceMotion = false
    private var _increaseContrast = false
    private var _differentiateWithoutColor = false
    private var started = false

    private init() { refresh() }

    var reduceMotion: Bool { lock.lock(); defer { lock.unlock() }; return _reduceMotion }
    var increaseContrast: Bool { lock.lock(); defer { lock.unlock() }; return _increaseContrast }
    var differentiateWithoutColor: Bool {
        lock.lock(); defer { lock.unlock() }; return _differentiateWithoutColor
    }

    /// Idempotent — safe to call from every window that wants the flags live.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        // Posted on the workspace's own centre, not `NotificationCenter.default`.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let ws = NSWorkspace.shared
        let motion = ws.accessibilityDisplayShouldReduceMotion
        let contrast = ws.accessibilityDisplayShouldIncreaseContrast
        let colour = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        lock.lock()
        _reduceMotion = motion
        _increaseContrast = contrast
        _differentiateWithoutColor = colour
        lock.unlock()
    }
}

// MARK: - Accessibility overrides (the gallery's only privilege)

/// A forced value for one or more of the three accessibility switches,
/// applied to a subtree.
///
/// SwiftUI's own `\.accessibilityReduceMotion`, `\.colorSchemeContrast`
/// and `\.accessibilityDifferentiateWithoutColor` are read-only — you
/// cannot write them with `.environment(_:_:)` — so `DSGallery` could not
/// render the "on" branch of a switch without the reviewer changing
/// System Settings and relaunching, which is exactly the round trip the
/// gallery exists to remove. Every DS component therefore resolves each
/// switch as `override ?? system`, and `.dsA11yOverride(_:)` sets the
/// override for a subtree. `nil` (the default everywhere but the gallery)
/// means "use the system value", so shipping surfaces are unaffected.
///
/// Overrides MERGE down the tree: `.dsA11yOverride(_:)` combines the
/// new value with the one already in the environment, a pinned field
/// winning and a `nil` field inheriting. The gallery's pinned
/// "Differentiate off / on" specimens therefore keep the toolbar's
/// Increase Contrast setting instead of silently dropping it.
struct DSA11yOverride: Equatable {
    var reduceMotion: Bool?
    var contrast: ColorSchemeContrast?
    var differentiateWithoutColor: Bool?

    static let system = DSA11yOverride()

    /// `self` with every field `child` pins replaced by the child's value.
    func merging(_ child: DSA11yOverride) -> DSA11yOverride {
        DSA11yOverride(
            reduceMotion: child.reduceMotion ?? reduceMotion,
            contrast: child.contrast ?? contrast,
            differentiateWithoutColor: child.differentiateWithoutColor ?? differentiateWithoutColor)
    }
}

private struct DSA11yOverrideKey: EnvironmentKey {
    static let defaultValue = DSA11yOverride.system
}

extension EnvironmentValues {
    var dsA11yOverride: DSA11yOverride {
        get { self[DSA11yOverrideKey.self] }
        set { self[DSA11yOverrideKey.self] = newValue }
    }
}

// MARK: - The one accessibility read: @DSAccessibility

/// The three accessibility switches a view honours, resolved once.
///
/// Every DS component and every view that draws its own hover wash or
/// structural stroke used to carry the same three lines —
/// `@Environment(\.colorSchemeContrast)`, `@Environment(\.dsA11yOverride)`,
/// `override.contrast ?? system` — twenty copies of a recipe, and a
/// builder who dropped the `??` silently lost the gallery's forced
/// switch. This wrapper IS that recipe. Declare
///
///     @DSAccessibility private var a11y
///
/// and read `a11y.contrast`, `a11y.reduceMotion`, `a11y.differentiate`.
/// It is a `DynamicProperty` built on four `@Environment` reads, so
/// SwiftUI invalidates the body when System Settings changes exactly as
/// it would for the raw environment values — and it also folds in
/// `DSA11yOverride`, which is how `Qnet --ds-gallery` shows both branches
/// of each switch without touching System Settings.
///
/// `a11y.animation(DS.Motion.quick)` is for the imperative
/// `withAnimation` inside an `onHover` or a button action: `DS.Motion.*`
/// already returns `nil` under the SYSTEM Reduce Motion switch, but only
/// the environment (and the gallery override) can be read here.
@propertyWrapper
struct DSAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiate
    @Environment(\.dsA11yOverride) private var override

    init() {}

    var wrappedValue: DSAccessibilityState {
        DSAccessibilityState(
            reduceMotion: override.reduceMotion ?? systemReduceMotion,
            contrast: override.contrast ?? systemContrast,
            differentiate: override.differentiateWithoutColor ?? systemDifferentiate)
    }
}

/// What `@DSAccessibility` resolves to: the three switches, override
/// applied, plus the one helper an event handler needs.
struct DSAccessibilityState: Equatable {
    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    let reduceMotion: Bool
    /// System Settings ▸ Accessibility ▸ Display ▸ Increase contrast.
    let contrast: ColorSchemeContrast
    /// System Settings ▸ Accessibility ▸ Display ▸ Differentiate without colour.
    let differentiate: Bool

    /// `animation`, or `nil` (an instant state change) under Reduce Motion.
    /// Use it wherever a view calls `withAnimation` itself:
    /// `withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = h }`.
    func animation(_ animation: Animation?) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - View helpers

/// Backing modifier for `View.dsAnimation(_:value:)`.
private struct DSAnimationModifier<V: Equatable>: ViewModifier {
    @DSAccessibility private var a11y
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(a11y.animation(animation), value: value)
    }
}

extension View {
    /// Tooltip and accessibility label in one call. Every icon-only control
    /// must go through this (DS components do it for you).
    func dsTooltip(_ text: String) -> some View {
        self.help(text).accessibilityLabel(text)
    }

    /// Apply a DS shadow preset.
    func dsShadow(_ shadow: DS.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// 1-pt hairline separator on one edge (the overlay spelling of
    /// `DSRule`; steps up under Increase Contrast the same way).
    func dsHairline(_ edge: Alignment) -> some View {
        overlay(alignment: edge) {
            DSRule((edge == .leading || edge == .trailing) ? .vertical : .horizontal)
        }
    }

    /// `.animation(_:value:)` that honours Reduce Motion **live**.
    ///
    /// `.dsAnimation(DS.Motion.quick, value:)` resolves the flag when the
    /// body runs, and SwiftUI has no reason to re-run that body when the
    /// user flips the switch in System Settings. This modifier reads
    /// `\.accessibilityReduceMotion` from the environment, so SwiftUI
    /// invalidates it for us and the very next frame is unanimated.
    func dsAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(DSAnimationModifier(animation: animation, value: value))
    }

    /// Force one or more accessibility switches for a subtree — see
    /// `DSA11yOverride`. Used by `DSGallery` and nowhere else. Merges
    /// with any override already in force above this view, so pinning
    /// one switch never resets the other two.
    func dsA11yOverride(_ override: DSA11yOverride) -> some View {
        transformEnvironment(\.dsA11yOverride) { $0 = $0.merging(override) }
    }

    /// Content-well treatment for the scrolling area of a pane
    /// (`DS.Color.fieldBackground`).
    func dsContentWell() -> some View {
        background(DS.Color.fieldBackground)
    }

    /// The app's focus ring: a soft `DS.Stroke.focusRing` halo lying
    /// entirely OUTSIDE the control's bezel, the way AppKit draws it.
    ///
    /// The obvious spelling — `.overlay(shape.stroke(ring, lineWidth: 3))`
    /// — is wrong twice over: a stroke is centred on its path, so half the
    /// ring lands inside the control and paints over the text ground, and
    /// it shares a rect with the 1-pt bezel so the two blend into one fat
    /// edge. Here the ring is drawn with `strokeBorder` on a rect grown by
    /// its own width, so it starts where the bezel ends.
    ///
    /// `radius` is the bezel's corner radius; the ring's is expanded to
    /// stay concentric with it.
    func dsFocusRing(_ isFocused: Bool, radius: CGFloat = DS.Radius.control) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius + DS.Stroke.focusRing, style: .continuous)
                .strokeBorder(isFocused ? DS.Color.focusRing : .clear,
                              lineWidth: DS.Stroke.focusRing)
                .blur(radius: DS.Stroke.hairline)
                .padding(-DS.Stroke.focusRing)
                .allowsHitTesting(false)
        )
    }

    /// A bar attached to scrolling content — a pane header, a status band,
    /// the Settings pane's "Reset to Defaults" footer. There is exactly one
    /// chrome for these in Qnet and it is flat: `DS.Color.surface` with a
    /// hairline on the edge that faces the content. (The Settings footer
    /// was the app's only `.background(.bar)` material; the lint now
    /// forbids materials outright, and this modifier is what a new bar
    /// should reach for. `FlagBarView` is the same recipe, drawn under the
    /// Status header with a hairline on its bottom edge only.)
    /// `height` pins the bar instead of padding it vertically — a filter
    /// row is `DS.Layout.filterRowHeight` tall whatever its content is,
    /// so the pane below never shifts as a match readout comes and goes.
    func dsChromeBar(_ edge: Alignment = .top,
                     horizontal: CGFloat = DS.Spacing.l,
                     vertical: CGFloat = DS.Spacing.m,
                     height: CGFloat? = nil) -> some View {
        self.padding(.horizontal, horizontal)
            .padding(.vertical, height == nil ? vertical : 0)
            .frame(height: height)
            .background(DS.Color.surface)
            .dsHairline(edge)
    }
}

/// The one separator in the app: a 1-pt rule in `DS.Color.separator`,
/// stepping to `DS.Color.controlBorder` under Increase Contrast.
///
/// Use it as a standalone row in a `VStack` (`DSRule()`) or as a divider
/// between controls in an `HStack` (`DSRule(.vertical)`, which sizes
/// itself to the tallest sibling unless given a `length`). Use
/// `.dsHairline(edge)` when the line belongs to a container's edge rather
/// than to the stack.
///
/// SwiftUI's own `Divider()` is reserved for `Menu` / `contextMenu`
/// content, where AppKit draws the real menu separator. Everywhere else a
/// `Divider()` renders at the system's thickness and colour, so a rule
/// inside a popover did not match the rule under a pane header two inches
/// away; `design_lint.sh` now rejects it outside menu builders.
struct DSRule: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// Explicit length across the stack's main axis. `nil` lets the rule
    /// stretch (the `HStack` case usually wants `DS.Layout.controlHeight`
    /// minus a little, so the line does not touch the chrome edges).
    let length: CGFloat?

    init(_ axis: Axis = .horizontal, length: CGFloat? = nil) {
        self.axis = axis
        self.length = length
    }

    @DSAccessibility private var a11y

    var body: some View {
        Rectangle()
            .fill(DS.Color.separator(a11y.contrast))
            .frame(width: axis == .vertical ? DS.Stroke.hairline : length,
                   height: axis == .vertical ? length : DS.Stroke.hairline)
            .accessibilityHidden(true)
    }
}
