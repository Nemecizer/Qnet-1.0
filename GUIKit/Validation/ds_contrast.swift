// ds_contrast.swift — measures the Qnet design system's text/background
// contrast ratios and fails when one drops below its WCAG threshold.
//
//     swift validation/ds_contrast.swift            # print + gate
//     swift validation/ds_contrast.swift --verbose  # print the composites too
//
// Why this exists. `DS.Color.legibleTint(_:)` darkens a signal colour so a
// label stays readable on that colour's own 18 % wash. The blend fraction
// used to be a claim in a doc comment; it is now a measured property. At
// the old light-mode fraction of 0.42 the two most-visible pills in the app
// — the flag bar's green "Tractable" and orange "Warnings" — measured
// 4.35 : 1 and 4.48 : 1, i.e. they failed WCAG AA for 12-pt text. At 0.48
// every pair below passes.
//
// The numbers this prints are the real thing, not an approximation: each
// colour is resolved through a real NSAppearance in both aqua and darkAqua,
// the translucent wash is alpha-composited over the surface it actually
// sits on, and the ratio is WCAG 2.x relative luminance.
//
// NOTHING IS MIRRORED BY HAND. The three constants this measurement depends
// on — `DS.Color.legibleTintLightBlend`, `.legibleTintDarkBlend` and
// `DS.Opacity.tintFill` — plus the sRGB components of all FOUR
// `DS.Color.textTertiary` tuples (light, dark, and the two Increase
// Contrast pairs) are PARSED out of Sources/GUIKit/DesignSystem.swift at run
// time. The two Increase Contrast pairs are measured over the same light
// and dark grounds and gated at AA text (4.5 : 1), because that is the
// setting a low-vision user asked for. (AppKit vends the
// `accessibilityHighContrastAqua` appearances only while the System
// Settings switch is on — `NSAppearance(named:)` silently returns plain
// aqua otherwise, verified on a machine with the switch off — so the gate
// composites the high-contrast pair over the plain grounds, which is what
// the window background is under the switch anyway.) They used
// to be copied here under a "KEEP IN SYNC" comment, which meant the gate
// measured a copy: change the blend in the app and this script still
// reported a pass on the old value. If a constant cannot be found the
// script fails rather than falling back to a default, so a rename breaks
// the gate loudly instead of silently unhooking it.
//
// `design_lint.sh` runs this, `test.sh` runs that.

import AppKit
import Foundation

// MARK: - Tokens PARSED from DesignSystem.swift

let designSystemPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // validation/
    .deletingLastPathComponent()          // repo root
    .appendingPathComponent("Sources/GUIKit/DesignSystem.swift")

guard let designSystemSource = try? String(contentsOf: designSystemPath, encoding: .utf8) else {
    FileHandle.standardError.write(
        Data("ds_contrast: cannot read \(designSystemPath.path)\n".utf8))
    exit(2)
}

/// First capture group of `pattern` in DesignSystem.swift, as a CGFloat.
/// A miss is fatal: a gate that quietly falls back to a default is not a gate.
func token(_ name: String, _ pattern: String, group: Int = 1) -> CGFloat {
    let re = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(designSystemSource.startIndex..., in: designSystemSource)
    guard let m = re.firstMatch(in: designSystemSource, range: range),
          let r = Range(m.range(at: group), in: designSystemSource),
          let v = Double(designSystemSource[r]) else {
        FileHandle.standardError.write(
            Data("ds_contrast: cannot find \(name) in DesignSystem.swift — the gate is measuring nothing. Fix the pattern or the token.\n".utf8))
        exit(2)
    }
    return CGFloat(v)
}

/// DS.Color.legibleTintLightBlend / .legibleTintDarkBlend.
/// `--light-blend <f>` overrides the parsed value so the regression that
/// motivated this script can be re-measured (0.42 fails, 0.48 passes).
func blendArgument(_ flag: String, default d: CGFloat) -> CGFloat {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count,
          let v = Double(a[i + 1]) else { return d }
    return CGFloat(v)
}

let parsedLightBlend = token("legibleTintLightBlend",
                             #"legibleTintLightBlend: *CGFloat *= *([0-9.]+)"#)
let parsedDarkBlend = token("legibleTintDarkBlend",
                            #"legibleTintDarkBlend: *CGFloat *= *([0-9.]+)"#)
let legibleTintLightBlend = blendArgument("--light-blend", default: parsedLightBlend)
let legibleTintDarkBlend = blendArgument("--dark-blend", default: parsedDarkBlend)

/// DS.Opacity.tintFill — the wash a pill / badge draws behind its label.
let tintFillOpacity = token("DS.Opacity.tintFill",
                            #"static let tintFill: *Double *= *([0-9.]+)"#)

/// DS.Color.textTertiary — a dynamic grey, not `tertiaryLabelColor`; all
/// twelve components (light, dark, lightHighContrast, darkHighContrast)
/// are parsed so a change to the token is measured here.
let tertiaryPattern =
    #"static let textTertiary = dynamic\(light: \(([0-9.]+), *([0-9.]+), *([0-9.]+)\),\s*dark: \(([0-9.]+), *([0-9.]+), *([0-9.]+)\),\s*lightHighContrast: \(([0-9.]+), *([0-9.]+), *([0-9.]+)\),\s*darkHighContrast: \(([0-9.]+), *([0-9.]+), *([0-9.]+)\)\)"#
func tertiaryTuple(_ name: String, firstGroup g: Int) -> NSColor {
    NSColor(srgbRed: token("textTertiary \(name)", tertiaryPattern, group: g),
            green: token("textTertiary \(name)", tertiaryPattern, group: g + 1),
            blue: token("textTertiary \(name)", tertiaryPattern, group: g + 2), alpha: 1)
}
let textTertiaryLight = tertiaryTuple("light", firstGroup: 1)
let textTertiaryDark = tertiaryTuple("dark", firstGroup: 4)
let textTertiaryLightHC = tertiaryTuple("lightHighContrast", firstGroup: 7)
let textTertiaryDarkHC = tertiaryTuple("darkHighContrast", firstGroup: 10)

/// The four DS signal colours, in the order the adoption guide lists them.
let signals: [(String, NSColor)] = [
    ("success (green)", .systemGreen),
    ("warning (orange)", .systemOrange),
    ("danger  (red)", .systemRed),
    ("info    (blue)", .systemBlue),
]

// MARK: - Colour maths

func srgb(_ c: NSColor, _ appearance: NSAppearance) -> NSColor {
    var out = c
    appearance.performAsCurrentDrawingAppearance {
        out = c.usingColorSpace(.sRGB) ?? c
    }
    return rgb(out)
}

/// DS.Color.legibleTint(_:) for one appearance.
func legibleTint(_ base: NSColor, dark: Bool, _ appearance: NSAppearance) -> NSColor {
    let s = srgb(base, appearance)
    let blended = dark
        ? s.blended(withFraction: legibleTintDarkBlend,
                    of: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        : s.blended(withFraction: legibleTintLightBlend,
                    of: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    return rgb(blended ?? s)
}

/// Any NSColor as concrete sRGB components. System colours and the
/// tagged-pointer black / white raise on `.redComponent` unless converted.
func rgb(_ c: NSColor) -> NSColor {
    c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
}

/// Alpha-composite `top` (with `alpha`) over the opaque `bottom`.
func composite(_ top: NSColor, alpha: CGFloat, over bottom: NSColor) -> NSColor {
    let t = rgb(top), b = rgb(bottom)
    return NSColor(srgbRed: t.redComponent * alpha + b.redComponent * (1 - alpha),
                   green: t.greenComponent * alpha + b.greenComponent * (1 - alpha),
                   blue: t.blueComponent * alpha + b.blueComponent * (1 - alpha),
                   alpha: 1)
}

/// WCAG 2.x relative luminance.
func luminance(_ colour: NSColor) -> CGFloat {
    let c = rgb(colour)
    func lin(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.redComponent)
         + 0.7152 * lin(c.greenComponent)
         + 0.0722 * lin(c.blueComponent)
}

/// WCAG contrast ratio. `ink` may be translucent; it is composited first.
func ratio(ink: NSColor, on ground: NSColor) -> CGFloat {
    let inkRGB = rgb(ink)
    let a = inkRGB.alphaComponent < 1
        ? composite(inkRGB, alpha: inkRGB.alphaComponent, over: ground)
        : inkRGB
    let l1 = luminance(a), l2 = luminance(ground)
    let hi = max(l1, l2), lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}

// MARK: - Report

let verbose = CommandLine.arguments.contains("--verbose")
var failures: [String] = []

func check(_ label: String, _ measured: CGFloat, min threshold: CGFloat) {
    let ok = measured + 0.005 >= threshold      // print to 2 dp, gate to 2 dp
    let mark = ok ? "  ok " : "FAIL "
    print(String(format: "  %@ %-46@ %5.2f : 1   (needs %.1f)",
                 mark, label as NSString, Double(measured), Double(threshold)))
    if !ok { failures.append(label) }
}

/// Measured and printed, but not gated — see the note beside each caller.
func report(_ label: String, _ measured: CGFloat, _ why: String) {
    print(String(format: "  info  %-46@ %5.2f : 1   (%@)",
                 label as NSString, Double(measured), why as NSString))
}

/// AA for normal text — DS.Font.label is 12 pt regular, which is not
/// "large text", so 4.5 applies to every pill and badge label.
let aaText: CGFloat = 4.5
/// AA for non-text / incidental contrast (a decorative border, a
/// placeholder, an em-dash empty).
let aaNonText: CGFloat = 3.0

print("ds_contrast: tokens parsed from Sources/GUIKit/DesignSystem.swift")
print(String(format: "  legibleTintLightBlend %.2f   legibleTintDarkBlend %.2f   tintFill %.2f",
             Double(legibleTintLightBlend), Double(legibleTintDarkBlend), Double(tintFillOpacity)))

for (name, appearance) in [("LIGHT (aqua)", NSAppearance(named: .aqua)!),
                           ("DARK  (darkAqua)", NSAppearance(named: .darkAqua)!)] {
    let dark = appearance.name == .darkAqua
    print("")
    print("\(name)")

    let surface = srgb(.windowBackgroundColor, appearance)
    let field = srgb(.textBackgroundColor, appearance)
    if verbose {
        print(String(format: "  surface  #%02X%02X%02X   field #%02X%02X%02X",
                     Int(surface.redComponent * 255), Int(surface.greenComponent * 255),
                     Int(surface.blueComponent * 255),
                     Int(field.redComponent * 255), Int(field.greenComponent * 255),
                     Int(field.blueComponent * 255)))
    }

    // 1. Pill / badge label: legibleTint(t) on tintFill(t) over the surface.
    for (label, base) in signals {
        let tint = srgb(base, appearance)
        let wash = composite(tint, alpha: tintFillOpacity, over: surface)
        let ink = legibleTint(base, dark: dark, appearance)
        check("pill label   \(label) on its own wash", ratio(ink: ink, on: wash), min: aaText)
    }

    // 2. DSBadge count capsule: textOnTint on a SOLID legibleTint capsule.
    let onTint = dark
        ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    for (label, base) in signals {
        let capsule = legibleTint(base, dark: dark, appearance)
        check("count capsule \(label) textOnTint", ratio(ink: onTint, on: capsule), min: aaText)
    }

    // 2b. The canvas ρ badge: textOnTint on a SOLID legibleTint capsule of
    // success / warning / danger, at `DS.Canvas.badgeFont` (a caption, so
    // 4.5 : 1 applies).  The same pair as the count capsule above, gated
    // under its own name because it is the one number a solver run puts
    // on the canvas — and it shipped for two rounds as white on the raw
    // tint (2.22 / 2.31 / 3.57 light, 2.02 / 2.23 / 3.43 dark).
    for (label, base) in signals where !label.hasPrefix("info") {
        let capsule = legibleTint(base, dark: dark, appearance)
        check("ρ badge      \(label) textOnTint", ratio(ink: onTint, on: capsule), min: aaText)
    }

    // 3. A signal colour used as INK on a PLAIN ground.
    //
    // This is the pair the gate used to miss, and it is where the app's
    // most important text lives: every inline field error, every advisory
    // triangle, the sheet footer's problem line. The raw signal colours
    // fail badly in light mode (green 2.22, orange 2.31 — below even the
    // 3 : 1 non-text floor), which is why the DS rule is now "a signal
    // colour is a FILL; text and caption-sized glyphs use the *Text
    // variant". The raw values are printed so the reason stays visible;
    // the *Text tokens are gated on BOTH grounds.
    for (label, base) in signals {
        let raw = srgb(base, appearance)
        report("raw \(label) as ink on surface", ratio(ink: raw, on: surface),
               "FILL ONLY — never text; use the *Text token")
    }
    for (label, base) in signals {
        let ink = legibleTint(base, dark: dark, appearance)
        check("*Text \(label) on surface", ratio(ink: ink, on: surface), min: aaText)
        check("*Text \(label) on fieldBackground", ratio(ink: ink, on: field), min: aaText)
    }

    // 4. The label hierarchy on both grounds.
    //
    // textPrimary / textSecondary are Apple's labelColor /
    // secondaryLabelColor — deliberately, because a Qnet caption must match
    // a System Settings caption and must follow the system's own Increase
    // Contrast treatment:
    //   • textPrimary is gated at AA text: it is the app's body colour and
    //     nothing may quietly redefine it below that.
    //   • textSecondary is gated at 3 : 1. Apple ships it at 3.95 : 1 on a
    //     light window, so gating it at 4.5 would fail every native macOS
    //     app on day one; 3 : 1 still catches a redefinition that makes it
    //     materially worse.
    //   • textTertiary IS gated, at 3 : 1, on both grounds. It used to be
    //     `tertiaryLabelColor` (1.88 : 1 light) and merely reported as
    //     "incidental" — while the app drew a distribution's mean / SCV
    //     formula, the Find Node kind labels and the AI timestamps in it.
    //     Those moved to textSecondary and the token became a dynamic grey
    //     that clears the floor, so "placeholders only" is now a rule with
    //     a measurement behind it rather than an aspiration.
    check("textPrimary on surface",
          ratio(ink: srgb(.labelColor, appearance), on: surface), min: aaText)
    check("textSecondary on surface",
          ratio(ink: srgb(.secondaryLabelColor, appearance), on: surface), min: aaNonText)
    check("textSecondary on fieldBackground",
          ratio(ink: srgb(.secondaryLabelColor, appearance), on: field), min: aaNonText)
    //   • Under Increase Contrast `DS.Color.dynamic` resolves the token's
    //     high-contrast pair (the window's effective appearance becomes
    //     `accessibilityHighContrastAqua` while the switch is on). That
    //     pair is gated at AA TEXT (4.5 : 1) over the same grounds: a
    //     placeholder a low-vision user asked to see better must clear
    //     the text threshold, not the incidental one.
    let tertiary = dark ? textTertiaryDark : textTertiaryLight
    check("textTertiary on surface", ratio(ink: tertiary, on: surface), min: aaNonText)
    check("textTertiary on fieldBackground", ratio(ink: tertiary, on: field), min: aaNonText)
    let tertiaryHC = dark ? textTertiaryDarkHC : textTertiaryLightHC
    check("textTertiary (Increase Contrast) on surface", ratio(ink: tertiaryHC, on: surface), min: aaText)
    check("textTertiary (Increase Contrast) on fieldBackground", ratio(ink: tertiaryHC, on: field), min: aaText)
    // It must still read as the third step: fainter than textSecondary.
    let secondaryRatio = ratio(ink: srgb(.secondaryLabelColor, appearance), on: surface)
    let tertiaryRatio = ratio(ink: tertiary, on: surface)
    if tertiaryRatio >= secondaryRatio {
        print("  FAIL  textTertiary is not fainter than textSecondary")
        failures.append("textTertiary hierarchy")
    } else {
        print(String(format: "    ok  %-46@ %5.2f < %.2f",
                     "textTertiary fainter than textSecondary" as NSString,
                     Double(tertiaryRatio), Double(secondaryRatio)))
    }
}

print("")
if failures.isEmpty {
    print("ds_contrast: all pairs pass")
    exit(0)
} else {
    print("ds_contrast: \(failures.count) pair(s) below threshold:")
    for f in failures { print("  • \(f)") }
    print("Raise DS.Color.legibleTintLightBlend / .legibleTintDarkBlend, or the")
    print("failing token itself, in Sources/GUIKit/DesignSystem.swift — this script")
    print("reads them from there, so there is nothing to mirror.")
    exit(1)
}
