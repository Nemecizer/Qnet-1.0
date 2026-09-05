#!/usr/bin/env bash
#
# design_lint.sh — enforces the DesignSystem.swift adoption rules.
#
# Fails (exit 1) when any Swift file under Sources/Qnet other than
# DesignSystem.swift contains:
#   • a point-size font           .font(.system(size: …))            → DS.Font.*
#   • a raw text style            .font(.callout) / .font(.headline) → DS.Font.*
#   • a text-style + design font  .system(.caption, design: …)       → DS.Font.mono*
#   • a colour-opacity literal    Color.x.opacity(…) / .accentColor.opacity(…)
#                                 / .primary.opacity(…)              → DS.Color.*
#   • a raw label colour          .foregroundStyle(.secondary)       → DS.Color.text*
#   • a raw signal colour         .foregroundStyle(.red) / Color.green …
#                                 → DS.Color.success / .warning / .danger / .info
#   • the accent colour spelt out Color.accentColor / .accentColor   → DS.Color.accent
#   • a material chrome             .background/.fill/.foregroundStyle(.bar or
#                                 any *Material)                       → DS.Color.surface
#                                 (every band and floating panel in the app is flat)
#   • a hand-built animation      .easeInOut(duration: 0.12)          → DS.Motion.*
#                                 (a curve built at a call site cannot honour Reduce Motion)
#   • an AppKit animation group   NSAnimationContext / ctx.duration = → DS.Motion.animateAppKit
#                                 with DS.Motion.quickDuration / .standardDuration
#   • an AppKit colour literal    NSColor(srgbRed: …)                 → a DS.Color token
#   • a bare ⌘<digit> shortcut    "Zoom to Fit (⌘1)" (raw file, prose or comment)
#                                 → KeyboardShortcutReference.key(for:); ⌘1–⌘9 are the tabs
#   • a literal SF Symbol         systemImage: "trash"                → DS.Symbol.*
#   • a raw symbol string         return "sparkles" in a glyph table  → DS.Symbol.*
#                                 (alternation generated from DS.Symbol itself)
#   • a raw separator             Divider() outside a menu builder    → DSRule()
#                                 (menu scope is tracked by brace depth, and a
#                                 self-test with a negative fixture runs first)
#   • a non-adaptive stroke       .stroke(DS.Color.separator, lineWidth: DS.Stroke.hairline)
#                                 → DS.Color.separator(a11y.contrast) / DS.Stroke.hairline(a11y.contrast)
#                                 (Canvas draw closures use the *Adaptive spellings;
#                                 lines within two of a `with: .color(` are exempt)
#   • the copied a11y recipe      @Environment(\.colorSchemeContrast) / \.dsA11yOverride
#                                 / \.accessibilityReduceMotion / …DifferentiateWithoutColor
#                                 → @DSAccessibility private var a11y
#   • a sentence-case empty state DSEmptyState(title: "No status entries")
#                                 → "No Status Entries" (Title Case noun phrase;
#                                 raw file, articles and prepositions excepted)
#   • a signal colour used as INK foregroundStyle(DS.Color.danger)    → DS.Color.dangerText
#                                 (the raw signal is a FILL: it measures 3.57 : 1 as text
#                                 in light mode, and green / orange are worse)
#   • a stroke-width literal      lineWidth: 1.5                     → DS.Stroke.*
#   • a corner-radius literal     cornerRadius: 22                   → DS.Radius.*
#   • a frame literal             .frame(minWidth: 700, …)           → DS.Layout.*
#   • an AppKit colour            Color(nsColor: …)                  → DS.Color.* / .dsContentWell()
#   • a DS extension outside this file   extension DS.Layout { … }   → put it IN DesignSystem.swift
#   • a resurrected token namespace  PaneDS / EditorDesign / QnetSpacing / QnetRadius / QnetMeasure
#   • a menu path with an arrow   "Settings → Simulation"            → "Settings ▸ …"
#                                 (checked on the raw file: the text is prose)
#   • TeX superscript braces      "cost grows as n^{2d}"             → "n²ᵈ" (Unicode)
#                                 (raw file, comment lines skipped)
#   • a hand-rolled chrome bar    .padding(.vertical) + .background(DS.Color.surface)
#                                 → .dsChromeBar(edge)  (FlagBarView is the documented exception)
#   • a retired token             DS.Color.caution / DS.Font.caption2 / DS.Font.error
#                                 / DS.Font.footnote / DS.Font.monoFootnote
#   • a hand-rolled text area     TextEditor(…)                      → DSTextArea
#   • a borderless push button    .buttonStyle(.borderless)          → DSIconButton
#   • a duplicate component       PaneHeader / PaneIconButton / PaneBadge / FlagPill
#                                 / PressablePillStyle / PaletteButtonStyle (non-DS)
#                                 / SettingsNumericField / SettingsErrorCaption
#                                 / SettingsCautionRow / PopoverHeader / IntRangeFields
#                                 / InlinePendingNote / SteppedField / AlertFormBuilder…
#                                 (anything that re-draws a DS field, badge, icon
#                                 button, popover, search field or empty state)
#
# It also checks two things that are not greps over the sources:
#   • every `static let` in `DS.Glossary` is referenced by at least one view
#     ("adding a glossary entry and not wiring it is worse than not adding it"),
#     and `DS.Glossary.all` names every one of them (SettingsGlossaryAudit's
#     run-time membership check depends on it);
#   • `validation/ds_contrast.swift` still PARSES its constants out of
#     DesignSystem.swift rather than mirroring them, so the gate cannot drift
#     from the tokens it claims to measure.
#
# It then runs `validation/ds_contrast.swift`, which measures the contrast of
# every DS text-on-colour pair in both appearances and fails below WCAG AA.
# Set DS_SKIP_CONTRAST=1 to skip that step (it compiles a Swift script, so it
# costs a few seconds); the rest of the lint is pure grep and instant.
#
# Comment lines and string literals are stripped before matching, so help
# text that mentions "Color.red" cannot false-positive.
#
# Run it from anywhere: ./validation/design_lint.sh
# test.sh runs it as its first step and fails the run on a violation.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Sources/Qnet"
status=0

# Emit "file:line:code" for every source line with string literals and
# line comments blanked out. Multi-line ("""…""") literals are not handled;
# none of the forbidden patterns occur inside them today.
stripped() {
    local skip_ds_components="$1" f base
    for f in "$SRC"/*.swift; do
        base="$(basename "$f")"
        [[ "$base" == "DesignSystem.swift" ]] && continue
        [[ "$skip_ds_components" == yes && "$base" == DS*.swift ]] && continue
        sed -E 's/"([^"\\]|\\.)*"/""/g; s|//.*$||' "$f" \
            | awk -v file="$f" '{ printf "%s:%d:%s\n", file, NR, $0 }'
    done
}

# Token rules apply to every file but DesignSystem.swift (DS components
# must use tokens too); component-duplication rules exempt the DS*.swift
# files, which are where the one implementation legitimately lives.
CORPUS="$(stripped no)"
CORPUS_VIEWS="$(stripped yes)"

check() {
    local label="$1" pattern="$2" corpus="${3:-$CORPUS}"
    local hits
    hits="$(grep -E "$pattern" <<<"$corpus" || true)"
    if [[ -n "$hits" ]]; then
        echo "✗ $label"
        echo "$hits" | sed "s|$SRC/|    |"
        status=1
    else
        echo "✓ $label"
    fi
}

check "no point-size fonts outside DesignSystem.swift" \
      '\.system\(size:'
# Every text style has a DS.Font token; a view naming one directly bypasses
# the scale (and the macOS size table documented in DS.Font).
check "no raw text styles (use DS.Font.*)" \
      '\.font\(\.(largeTitle|title[23]?|title|headline|body|callout|subheadline|footnote|caption2|caption)[.)]'
check "no text-style + design fonts outside DesignSystem.swift (use DS.Font.mono*)" \
      '\.system\(\.[a-zA-Z0-9]+, *design:'
check "no colour-opacity literals outside DesignSystem.swift" \
      '(Color\.[A-Za-z]+|\.accentColor|\.primary|\.secondary|\.quaternary|\.tertiary)\.opacity\('
check "no raw label colours (use DS.Color.textPrimary / .textSecondary / .textTertiary)" \
      '\.foregroundStyle\(\.(primary|secondary|tertiary|quaternary)\)'
# White or black ink is never right in both appearances: on a solid
# `legibleTint` capsule the answer is `DS.Color.textOnTint` (white in
# light, black in dark), and on anything else it is a text token.  The
# canvas ρ badge drew `.white` on an undarkened system tint — 2.0 : 1 in
# dark mode — for two rounds because this rule matched only the label
# hierarchy.  AboutQnetWindow's fallback icon is exempt: it is icon
# artwork (a white glyph on the accent gradient, as in the real app icon),
# not text on chrome.
check "no raw white / black ink (use DS.Color.textOnTint on a legibleTint capsule)" \
      '\.foregroundStyle\(\.(white|black)\)' \
      "$(grep -v '/AboutQnetWindow\.swift:' <<<"$CORPUS")"
check "no raw signal colours (use DS.Color.success/warning/danger/info)" \
      'foregroundStyle\(\.(red|green|orange|yellow)\)|Color\.(red|green|orange|yellow|white)\b'
check "no direct accent colour (use DS.Color.accent / .accentStroke)" \
      'Color\.accentColor|[^A-Za-z.]\.accentColor\b'
# Every header, footer and status band in Qnet is a flat DS.Color.surface.
# One `.bar` footer among them read as a different app.
# `.fill(.ultraThinMaterial)` inside a Shape slipped past the old rule,
# which only looked at `.background(...)` — and that is exactly where the
# canvas's two floating panels hid.
check "no material chrome (use DS.Color.surface)" \
      '\.(background|fill|foregroundStyle)\(\.(bar|[a-zA-Z]*[Mm]aterial)\)'
check "no stroke-width literals (use DS.Stroke.*)" \
      'lineWidth: *[0-9]'
check "no corner-radius literals (use DS.Radius.*)" \
      'cornerRadius: *[0-9]'
# Window, pane and control geometry is a token like any other; before this
# rule, 24 magic boxes survived the colour and font sweeps.
# The optional (min|max|ideal) prefix meant the BARE form still had to be
# capitalised, so `.frame(minWidth: 120)` was caught and `.frame(width: 120)`
# was not — eight survivors, five of them in DSGallery, the file a reader
# copies from.
check "no frame literals (use DS.Layout.*)" \
      '\.frame\((min|max|ideal)?[WwHh](idth|eight): *[0-9]|navigationSplitViewColumnWidth\(min: *[0-9]'
check "no AppKit colours outside DesignSystem.swift (use DS.Color.* / .dsContentWell())" \
      'Color\(nsColor:'
# DS.Layout lived in three files for a round because two builders extended
# it from their own. One namespace means one file.
# (`extension DSSomeComponent where …` is fine — that is a component's own
# convenience initialiser. What is forbidden is extending the token
# namespace itself: `extension DS {` or `extension DS.Layout {`.)
check "no DS extensions outside DesignSystem.swift" \
      'extension DS(\.[A-Za-z0-9]+)+ *\{|extension DS *\{'
check "no competing token namespaces" \
      '\b(PaneDS|EditorDesign|QnetSpacing|QnetRadius|QnetMeasure)\.'
check "no retired tokens (caution → warning, footnote/caption2 → caption)" \
      'DS\.Color\.caution\b|DS\.Font\.(caption2|monoCaption2|error|footnote|monoFootnote)\b'
check "no duplicate components" \
      '\b(PaneHeader|PaneIconButton|PaneBadge|FlagPill|PressablePillStyle|PaneRule|SettingsNumericField|SettingsErrorCaption|SettingsCautionRow|PopoverHeader|ContentUnavailableView|InlinePendingNote|SteppedField|AlertFormBuilder)\b|[^S]PaletteButtonStyle' \
      "$CORPUS_VIEWS"
check "no hand-rolled fields (TextField(value:format:) / .roundedBorder outside DS*.swift)" \
      'TextField\([^)]*value:[^)]*format:|textFieldStyle\(\.roundedBorder\)' \
      "$CORPUS_VIEWS"
# The AI-settings system prompt was the app's only TextEditor, drawing its
# own background, border and height literals — the one field chrome not
# produced by DSFields. DSTextArea is that control now.
check "no hand-rolled text areas (use DSTextArea)" \
      'TextEditor\(' \
      "$CORPUS_VIEWS"
# A borderless push button has no hover, pressed or disabled wash, so it
# looked dead next to the DSIconButtons in every pane header.
check "no borderless push buttons outside DS*.swift (use DSIconButton / DSIconToggle)" \
      'buttonStyle\(\.borderless\)' \
      "$CORPUS_VIEWS"

# One glyph per command. `DS.Symbol` is the vocabulary; a view that types
# the string itself is how "warning" ended up as a filled triangle in three
# places and an unfilled one in two others. The corpus has string literals
# blanked, so this matches `systemImage: ""` — i.e. a literal in the
# argument, in either the plain or the ternary form — and never a symbol
# name mentioned in prose. Model-owned glyph tables (NodeKind.symbol,
# QueueDistribution.symbol, StationPicture.systemImageName) return a String
# and are not written as `systemImage:`, so they are unaffected.
check "no literal SF Symbols (use DS.Symbol.*)" \
      '(systemImage|systemName):[^,)]*""'

# The rule above catches the argument form; this one catches a symbol name
# typed as a plain string anywhere else — a view-owned glyph table
# (`var systemImage: String { switch self … return "sparkles" }`) that
# re-spells a token DS.Symbol already names. The alternation is GENERATED
# from the DS.Symbol constants, so it cannot go stale as the vocabulary
# grows. Names that are also ordinary words (`"function"` is a JSON key,
# `"terminal"` a pane id) are dropped from the alternation, and
# Models.swift is exempt: NodeKind / QueueDistribution / StationPicture
# own their glyph tables (see DS.Symbol's doc comment).
symbol_block="$(sed -n '/enum Symbol {/,/^    }/p' "$SRC/DesignSystem.swift")"
symbol_alt="$(grep -oE 'static let [A-Za-z0-9_]+ = "[^"]+"' <<<"$symbol_block" \
    | sed -E 's/.*= "([^"]+)"/\1/' \
    | grep -vxE 'function|terminal|plus|list|seal|eye|textformat' \
    | sed 's/\./\\./g' | sort -u | paste -sd'|' -)"
symbol_hits="$(grep -nE "\"($symbol_alt)\"" "$SRC"/*.swift \
    | grep -vE "/(DesignSystem|Models)\.swift:" || true)"
if [[ -n "$symbol_hits" ]]; then
    echo "✗ no raw SF Symbol strings that DS.Symbol already names"
    echo "$symbol_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ no raw SF Symbol strings that DS.Symbol already names"
fi

# A signal colour is a FILL. As ink on a plain ground it measures 2.22 : 1
# (green) to 3.57 : 1 (red) in light mode — below AA for the 10-pt captions
# it was being used for. `validation/ds_contrast.swift` gates the *Text
# variants on both grounds; this stops the raw token coming back as text.
check "no signal colour as ink (use DS.Color.successText / .warningText / .dangerText / .infoText)" \
      'foregroundStyle\([^)]*DS\.Color\.(success|warning|danger|info)[^A-Za-z]'

# Every animation comes from DS.Motion, which returns nil under Reduce
# Motion. A curve built at the call site cannot: the canvas kept easing
# while the rest of the window went still. `.linear(…)` is excluded — it is
# also the name of a DSNumericField stepper mode.
check "no hand-built animations (use DS.Motion.*)" \
      '\.(easeInOut|easeIn|easeOut|spring|timingCurve|interpolatingSpring)\('
# The AppKit spelling of the same mistake. The Shell's overlay scrollers
# faded with `NSAnimationContext` at 0.12 s and 0.35 s for two rounds while
# this rule matched SwiftUI curves only. `DS.Motion.animateAppKit(_:_:)`
# with `DS.Motion.quickDuration` / `.standardDuration` is the one form.
check "no NSAnimationContext / ctx.duration outside DesignSystem.swift (use DS.Motion.animateAppKit with DS.Motion.*Duration)" \
      'NSAnimationContext|ctx\.duration *='
# An NSColor built from components at a call site is a colour token that
# escaped the DS: the Shell's classic green lived in TerminalConsoleView as
# `NSColor(srgbRed:…)` while every SwiftUI colour was a token. The `Color(nsColor:`
# rule below catches the SwiftUI wrapper; this catches the AppKit one.
# DS*.swift files are exempt: DSGallery blends two NSColors to *measure* them.
check "no NSColor(srgbRed:…) outside DesignSystem.swift (add the token to DS.Color)" \
      'NSColor\(srgbRed:' \
      "$CORPUS_VIEWS"

# ── Increase Contrast reaches every structural stroke ────────────────────
# The DS components step their borders and washes up with the switch; the
# views around them drew `DS.Color.separator` at `DS.Stroke.hairline` and
# stayed put — a dozen seams (message bubbles, table rules, the canvas
# legend, the ρ badge). A stroke in a view body takes the adaptive form,
# `DS.Color.separator(a11y.contrast)` / `DS.Stroke.hairline(a11y.contrast)`.
# `Canvas` draw closures have no environment: they use the `*Adaptive`
# spellings, and a `lineWidth:` within two lines of a `with: .color(`
# (the GraphicsContext signature) is exempt from the width rule.
seam_hits="$(
    awk -F: '
        {
            file = $1; line = $2; code = substr($0, length($1) + length($2) + 3)
            if (code ~ /with: *\.color\(/) lastWith[file] = line
            if (code ~ /\.stroke(Border)?\([^)]*DS\.Color\.(separator|controlBorder)([^A-Za-z(]|$)/) print $0
            else if (code ~ /lineWidth: *DS\.Stroke\.hairline(Faint)?([^A-Za-z(]|$)/ \
                     && !(file in lastWith && line - lastWith[file] <= 2)) print $0
        }' <<<"$CORPUS"
)"
if [[ -n "$seam_hits" ]]; then
    echo "✗ non-adaptive structural stroke — use DS.Color.separator(a11y.contrast) / DS.Stroke.hairline(a11y.contrast) (Canvas: the *Adaptive spellings)"
    echo "$seam_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ structural strokes step up under Increase Contrast"
fi

# ── One accessibility read: @DSAccessibility ─────────────────────────────
# Twenty views carried the same three lines (`@Environment(\.colorSchemeContrast)`,
# `@Environment(\.dsA11yOverride)`, `override ?? system`), and one that
# forgot the `??` silently lost the gallery's forced switch. The wrapper is
# the only spelling outside DesignSystem.swift.
check "no hand-rolled accessibility reads (use @DSAccessibility private var a11y)" \
      '@Environment\(\\\.(colorSchemeContrast|dsA11yOverride|accessibilityReduceMotion|accessibilityDifferentiateWithoutColor)\)'

# ── One separator: DSRule, never Divider ─────────────────────────────────
# `Divider()` renders at the system's own thickness and colour, so a rule
# inside a popover did not match the rule under a pane header. It stays
# legal in menu content, where AppKit draws the real menu separator.
#
# "In menu content" is decided by BRACE DEPTH, not by proximity: when a
# line opens a `Menu { … }`, `.contextMenu { … }`, `Picker(…) { … }`,
# `CommandMenu` / `CommandGroup` or `.commands { … }` — or declares a
# `func` / `var` whose name says it builds menu content
# (`canvasContextMenu`, `endpointMenuItems`), the way the context menus
# and the Settings pop-up rows assemble their items outside the builder —
# the depth at which it opened is recorded and the scope ends when the
# depth drops back to it. The previous heuristic set a sticky flag on any
# `Picker(` and only cleared it at the next declaration, so a Picker
# followed by a `VStack { Text; Divider(); Text }` let the Divider
# through; that exact body is now a negative fixture in
# `divider_self_test`, which runs before the sources are scanned.
divider_scan() {
    local f="$1"
    sed -E 's/"([^"\\]|\\.)*"/""/g; s|//.*$||' "$f" | awk -v file="$f" '
        function count(s, ch,   n, i) {
            n = 0
            for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
            return n
        }
        BEGIN { depth = 0; inMenu = 0 }
        {
            before = depth
            isDecl = ($0 ~ /^[[:space:]]*(@ViewBuilder[[:space:]]+)?(private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+|static[[:space:]]+)*(func|var)[[:space:]]/)
            if (!inMenu && ($0 ~ /Menu[[:space:]]*\{|Menu\(|\.contextMenu|Picker\(|CommandMenu|CommandGroup|\.commands[[:space:]]*\{/ \
                            || (isDecl && $0 ~ /[Mm]enu|[Cc]ommands|[Pp]icker/))) {
                inMenu = 1; menuDepth = before; menuBody = 0; parens = 0
            }
            depth += count($0, "{") - count($0, "}")
            if (inMenu) {
                parens += count($0, "(") - count($0, ")")
                if (depth > menuDepth) menuBody = 1
                # The body closed on this line, or the call ended without one.
                if (menuBody && depth <= menuDepth) inMenu = 0
                else if (!menuBody && parens <= 0 && depth <= menuDepth && $0 !~ /\{[[:space:]]*$/) inMenu = 0
            } else if ($0 ~ /Divider\(\)/) {
                printf "%s:%d:%s\n", file, NR, $0
            }
        }'
}

divider_self_test() {
    local dir; dir="$(mktemp -d)"
    local ok=0
    # Negative fixture: the probe that slipped past the sticky flag. The
    # Divider is structural (inside a VStack after the Picker closed).
    cat > "$dir/negative.swift" <<'SWIFT'
struct Probe: View {
    @State private var choice = 0
    var body: some View {
        VStack {
            Picker("Choice", selection: $choice) {
                Text("A").tag(0)
                Text("B").tag(1)
            }
            VStack { Text("above"); Divider(); Text("below") }
        }
    }
}
SWIFT
    # Negative fixture 2: a Divider after a Menu body has closed, and one
    # after a menu-building declaration's body has closed.
    cat > "$dir/negative2.swift" <<'SWIFT'
struct Probe2: View {
    var body: some View {
        Menu("Actions") {
            Button("One") {}
            Divider()
            Button("Two") {}
        }
        Divider()
        Text("after the menu")
    }
}
struct Probe3: View {
    @ViewBuilder private var pickerRow: some View {
        Picker("Choice", selection: .constant(0)) { Text("A").tag(0) }
    }
    var body: some View {
        VStack { pickerRow; Divider(); Text("below") }
    }
}
SWIFT
    # Positive fixture: every legal placement, including a multi-line
    # Picker call whose builder brace opens on a later line.
    cat > "$dir/positive.swift" <<'SWIFT'
struct Legal: View {
    @State private var choice = 0
    var body: some View {
        Menu("Actions") {
            Button("One") {}
            Divider()
            Button("Two") {}
        }
        Picker("Choice",
               selection: $choice) {
            Text("A").tag(0)
            Divider()
            Text("B").tag(1)
        }
        Text("x").contextMenu {
            Button("Copy") {}
            Divider()
            Button("Paste") {}
        }
    }
    /// Items assembled outside the builder, as the context menus do.
    @ViewBuilder
    private var canvasContextMenu: some View {
        Button("Paste") {}
        Divider()
        Button("Select All") {}
    }
}
SWIFT
    local n1 n2 p
    n1="$(divider_scan "$dir/negative.swift" | wc -l | tr -d ' ')"
    n2="$(divider_scan "$dir/negative2.swift" | wc -l | tr -d ' ')"
    p="$(divider_scan "$dir/positive.swift" | wc -l | tr -d ' ')"
    rm -rf "$dir"
    [[ "$n1" == "1" && "$n2" == "2" && "$p" == "0" ]] && ok=1
    if [[ $ok -eq 1 ]]; then
        echo "✓ Divider rule self-test (negative fixtures flagged, positive fixture clean)"
        return 0
    fi
    echo "✗ Divider rule self-test failed (negative: $n1, $n2 hits — expected 1, 2; positive: $p hits — expected 0)"
    return 1
}

divider_self_test || status=1
divider_hits="$(
    for f in "$SRC"/*.swift; do
        [[ "$(basename "$f")" == "DesignSystem.swift" ]] && continue
        divider_scan "$f"
    done
)"
if [[ -n "$divider_hits" ]]; then
    echo "✗ no Divider() outside menu content (use DSRule() / DSRule(.vertical))"
    echo "$divider_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ separators are DSRule outside menus"
fi

# ── Empty-state titles are Title Case ─────────────────────────────────────
# DSEmptyState is the one empty state, and its title is a Title Case noun
# phrase — the HIG's "No Mail" / "No Results" — over a sentence-case
# message. "No Selection" sat beside "No status entries" and "No network
# yet" for a round. Raw files (the text is a string literal), the `title:`
# argument of every `DSEmptyState(` call; articles, conjunctions and short
# prepositions may be lower-case, interpolations are skipped.
empty_title_hits="$(
    for f in "$SRC"/*.swift; do
        awk -v file="$f" '
            /DSEmptyState\(/ { start = NR }
            start && NR - start <= 10 && /title:/ {
                s = $0
                while (match(s, /"[^"]*"/)) {
                    str = substr(s, RSTART + 1, RLENGTH - 2)
                    s = substr(s, RSTART + RLENGTH)
                    n = split(str, words, " ")
                    for (i = 1; i <= n; i++) {
                        w = words[i]
                        gsub(/[“”"?,.!:;()]/, "", w)
                        if (w == "" || w ~ /\\/) continue
                        if (w ~ /^(a|an|the|and|or|but|nor|for|of|in|on|at|to|by|with|yet|from|as|into|per|vs)$/) continue
                        if (substr(w, 1, 1) ~ /[a-z]/) { printf "%s:%d:%s\n", file, NR, $0; break }
                    }
                }
                start = 0
            }
        ' "$f"
    done
)"
if [[ -n "$empty_title_hits" ]]; then
    echo "✗ DSEmptyState titles are Title Case noun phrases (\"No Status Entries\", not \"No status entries\")"
    echo "$empty_title_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ empty-state titles are Title Case"
fi

# ── Every DS.Glossary entry is wired to a control ─────────────────────────
# The guide's own rule: "adding a glossary entry and not wiring it is worse
# than not adding it — a token nobody uses is deleted". λ, Γ and
# "customer class" sat defined and unreferenced for two rounds.
glossary_block="$(sed -n '/enum Glossary {/,/^    }/p' "$SRC/DesignSystem.swift")"
unused_glossary=""
while read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qE "Glossary\.$name\b" <<<"$CORPUS"; then
        unused_glossary+="    DS.Glossary.$name"$'\n'
    fi
done < <(grep -oE 'static let [A-Za-z0-9_]+' <<<"$glossary_block" | awk '{print $3}')
if [[ -n "$unused_glossary" ]]; then
    echo "✗ DS.Glossary entries that no control uses — wire them or delete them"
    printf "%s" "$unused_glossary"
    status=1
else
    echo "✓ every DS.Glossary entry is wired"
fi

# ── The contrast gate measures the tokens, not a copy of them ────────────
# ds_contrast.swift used to duplicate legibleTintLightBlend / DarkBlend and
# DS.Opacity.tintFill under a "KEEP IN SYNC" comment, so changing the blend
# in DesignSystem.swift left the gate happily measuring the old value. It
# now parses them out of the source; this makes that a checked property.
if grep -qE '^(let|var) *(legibleTintLightBlend|legibleTintDarkBlend|tintFillOpacity)[^=]*= *[0-9]' \
        "$ROOT/validation/ds_contrast.swift"; then
    echo "✗ ds_contrast.swift hard-codes a token instead of parsing DesignSystem.swift"
    status=1
elif ! grep -q 'designSystemSource' "$ROOT/validation/ds_contrast.swift"; then
    echo "✗ ds_contrast.swift no longer reads DesignSystem.swift — the gate would measure nothing"
    status=1
else
    echo "✓ ds_contrast.swift parses its constants from DesignSystem.swift"
fi

# ── Menu paths use ▸, never → ─────────────────────────────────────────────
# The Status and Shell panes print AlgorithmHelp text verbatim, so a
# "Settings → Simulation" there lands inches from the AI pane's
# "Settings ▸ AI Assistant". Unlike every rule above, this one reads the
# RAW files: the offending text is user-visible prose inside string
# literals, which `stripped` blanks out.
menu_arrows="$(grep -nE '(File|Edit|View|Network|Tools|Run|Test|Window|Help|Settings) → [A-Z]' "$SRC"/*.swift || true)"
if [[ -n "$menu_arrows" ]]; then
    echo "✗ menu paths must use ▸ (Settings ▸ Simulation), not →"
    echo "$menu_arrows" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ menu paths use ▸"
fi

# ── Shortcut glyphs in canonical order: ⌃ ⌥ ⇧ ⌘ ────────────────────────
# macOS prints modifiers control · option · shift · command, so ⌘ is
# always LAST. "⌘⇧W" in a comment is how the reversed form gets copied
# into the next tooltip and the Release Notes; like the ▸ rule this reads
# the raw files, because the offenders are prose.
modifier_order="$(grep -nE '⌘[⌃⌥⇧]' "$SRC"/*.swift || true)"
if [[ -n "$modifier_order" ]]; then
    echo "✗ shortcut modifiers must be written ⌃⌥⇧⌘ (⇧⌘W, not ⌘⇧W)"
    echo "$modifier_order" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ shortcut modifiers are in canonical order"
fi

# ── ⌘ + digit belongs to the document tabs ────────────────────────────────
# ⌘1–⌘9 show tabs (WorkspaceCommands). Zoom to Fit used to be ⌘1, and two
# tooltips kept teaching it for a round after the rebinding, so a user who
# followed the tooltip switched tabs instead of zooming. A tooltip that
# cites a key reads it from `KeyboardShortcutReference.key(for:)`, a table
# the debug-build menu audit checks against the live menus; a bare
# "⌘<digit>" typed anywhere else — prose or comment, since either is copied
# into the next tooltip — fails here. ⌥⌘ / ⌃⌘ / ⇧⌘ digits are the pane
# toggles, pane focus and Keynote's zoom keys and are allowed. Exempt: the
# two files that define the tab keys, the shortcut table, and the Changelog
# (which records the history, including the old bindings).
cmd_digit="$(grep -nE '(^|[^⌃⌥⇧])⌘[1-9]' "$SRC"/*.swift \
    | grep -vE '/(WorkspaceCommands|KeyboardShortcutReference|Changelog)\.swift:' \
    | grep -v '⌘1–⌘9' || true)"
if [[ -n "$cmd_digit" ]]; then
    echo "✗ ⌘<digit> cited outside the tab commands — use KeyboardShortcutReference.key(for:) (⌘1–⌘9 are the document tabs)"
    echo "$cmd_digit" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ no stray ⌘<digit> shortcuts outside the tab commands"
fi

# ── DS.Glossary.all names every entry ─────────────────────────────────────
# `SettingsGlossaryAudit` asserts at run time that a glossary string reaching
# a Settings row is a DS.Glossary entry, by membership in `DS.Glossary.all`.
# That set is hand-kept, so this checks it names every `static let` in the
# namespace — otherwise a new entry would trap as "not an entry".
all_block="$(sed -n '/static let all: Set<String> = \[/,/^        \]/p' "$SRC/DesignSystem.swift")"
missing_from_all=""
while read -r name; do
    [[ -z "$name" || "$name" == "all" ]] && continue
    if ! grep -qE "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|$)" <<<"$all_block"; then
        missing_from_all+="    DS.Glossary.$name"$'\n'
    fi
done < <(grep -oE 'static let [A-Za-z0-9_]+' <<<"$glossary_block" | awk '{print $3}')
if [[ -n "$missing_from_all" ]]; then
    echo "✗ DS.Glossary.all is missing entries (SettingsGlossaryAudit would reject them)"
    printf "%s" "$missing_from_all"
    status=1
else
    echo "✓ DS.Glossary.all names every glossary entry"
fi

# ── No TeX superscript braces in user-facing text ─────────────────────────
# The Settings window sets ρ, ε, γ, ≤ and × as real glyphs; "n^{2d}" next to
# them read as an unfinished string. Superscripts are Unicode (n²ᵈ, nᵈ,
# grid_nᵈ). Like the menu-arrow rule this reads the RAW files, because the
# text is prose inside string literals; comment lines are skipped (the
# exporters document their algebra in comments, which nobody renders).
tex_hits="$(grep -nE '\^\{' "$SRC"/*.swift | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$tex_hits" ]]; then
    echo "✗ TeX superscript braces in user-facing text — write n²ᵈ / nᵈ (Unicode superscripts)"
    echo "$tex_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ no TeX superscript braces in user-facing text"
fi

# ── One chrome bar: dsChromeBar ───────────────────────────────────────────
# A bar attached to scrolling content is `.dsChromeBar(edge)` — the only
# producer of "vertical padding + DS.Color.surface (+ hairline)". Three
# windows once drew the recipe by hand with two different padding pairs
# and two separator treatments. `FlagBarView` is the one exception (the
# same recipe with a hairline on BOTH edges, documented in DesignSystem).
chrome_hits="$(
    for f in "$SRC"/*.swift; do
        base="$(basename "$f")"
        [[ "$base" == "DesignSystem.swift" || "$base" == DS*.swift || "$base" == "FlagBarView.swift" ]] && continue
        awk -v file="$f" '
            /\.padding\(\.vertical/ { pv = NR }
            /\.background\(DS\.Color\.surface\)/ { if (pv && NR - pv <= 4) printf "%s:%d:%s\n", file, NR, $0 }
        ' "$f"
    done
)"
if [[ -n "$chrome_hits" ]]; then
    echo "✗ hand-rolled chrome bar (padding(.vertical) + background(DS.Color.surface)) — use .dsChromeBar(edge)"
    echo "$chrome_hits" | sed "s|$SRC/|    |"
    status=1
else
    echo "✓ chrome bars come from dsChromeBar"
fi

# ── Measured contrast, not asserted contrast ──────────────────────────────
if [[ "${DS_SKIP_CONTRAST:-0}" != "1" ]] && command -v swift >/dev/null 2>&1; then
    echo
    echo "── ds_contrast.swift (WCAG AA on every DS text-on-colour pair) ──"
    if swift "$ROOT/validation/ds_contrast.swift"; then
        echo "✓ contrast ratios pass"
    else
        echo "✗ contrast ratios below threshold"
        status=1
    fi
fi

if [[ $status -ne 0 ]]; then
    echo
    echo "design_lint: violations found — see the adoption guide at the top of Sources/Qnet/DesignSystem.swift"
fi
exit $status
