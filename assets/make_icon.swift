// Renders the Qnet app icon at one pixel size and writes a PNG.
//
//     swift make_icon.swift <px> <out.png> [--appearance light|dark|tinted]
//
// `make_icon.sh` calls this once per iconset slot (16 … 1024 px) and packs
// the results with `iconutil`. Drawing per size — instead of rendering a
// 1024-px master and letting `sips` downscale — is what keeps the icon
// legible in the Dock, in Finder list view and in the menu bar: every tier
// below draws only what survives at that size.
//
// ONE identity at every size
// --------------------------
// The motif is always the same picture: a THREE-NODE TRIANGLE — source ◇
// bottom-left, station ○ top-centre, sink ▢ bottom-right, the flow rising
// through the station and coming back down. The tiers differ only in how
// much detail survives.
//
// Why a triangle and not the left-to-right chain this used to draw. A
// horizontal chain of three shapes cannot fill a small icon. At 16 px the
// safe area is 12.8 px across, so three shapes plus their gaps get about
// four pixels each — and four pixels of height inside a 12.8-px box is a
// 31 % fill, which is why the old 16-px tier measured 11 × 5 and read as a
// sliver, and the 32-px tier 23 × 9, a thin band on an empty plate. No
// system icon looks like that in a Finder list. Arranging the same three
// nodes as a triangle spends the height instead of leaving it empty: every
// tier now fills ≥ 55 % of the safe rectangle in BOTH axes (the small ones
// fill ~100 %), and every tier draws the same three shapes in the same
// three places, so the Dock icon and the Finder-list icon are one logo.
//
// It is also the honest picture of what Qnet models: the minimal open
// queueing network is one arrival stream, one station, one departure.
//
// Tiers
//   16 px      pixel art: ⌀5 green diamond bottom-left, ⌀5 blue disc
//              top-centre, 5×5 red square bottom-right, joined by 1-px
//              diagonal shafts. Odd diameters throughout so every shape is
//              pixel-centred and nothing smears.
//   32 px      the same three shapes at ⌀9 / ⌀11 / 9, with 1-px shafts and
//              a ring on the disc so it reads as an outlined node.
//   64–128 px  the drawn diagram: the same triangle with heavier strokes,
//              arrowheads, and no inner dot.
//   ≥ 256 px   full detail: lighter strokes, an inner "state" dot in the
//              station, and the buffer drawn the way a queueing diagram
//              draws it — the incoming shaft ends, three short orange bars
//              (waiting jobs) stand in a tight row, then the station rim:
//              "→ ||| ○". Not bars across the shaft, which read as hatch
//              marks. Every arrowhead and tail stops ONE gap (`arrowGap`)
//              from the node it meets, measured along the edge to the
//              node's outline — the diamond's and the square's outlines
//              are computed for the edge's direction, so the source→station
//              head and the station→sink head float the same distance.
//              Both the bar-to-rim distance and the two head gaps are
//              MEASURED back from the rendered pixels (see "Seeing it").
//
// Appearances (`--appearance`, default `light`)
//   light      the blue gradient plate with the Sonoma top highlight.
//   dark       the same motif on a deeper, flatter plate with the highlight
//              dropped — what macOS asks for as the dark variant.
//   tinted     the motif alone as a monochrome alpha mask on transparency,
//              which the system tints; no plate, no gradient, no colour.
//
// Palette mirrors DS.Color in Sources/Qnet/DesignSystem.swift so the icon
// matches the canvas: station blue, source green, sink red, buffer orange.
// The mask uses the documented 0.2237 × size corner radius
// (`DS.Radius.appIcon(for:)`), with the Sonoma-era top inner highlight
// (1 px white at 25 %) and a soft bottom vignette.
//
// Safe area. Apple asks for the motif to stay inside the central 80 % of
// the canvas. Every tier is budgeted to that rectangle — the small motifs
// by pixel count, the diagram by anchoring the source's outer-left edge
// (diamond corner + half the stroke, round join) to `safe.minX` and the
// sink's outer-right edge to `safe.maxX`, so the composition is centred —
// and the claim is VERIFIED, not asserted: after drawing, the bitmap is
// diffed against a background-only render, the motif's pixel bounding box
// is printed, and the process exits 5 if any motif pixel lies outside the
// safe rectangle (measured to whole pixels: a column is inside when its
// index is ≥ ⌊minX⌋ and < ⌈maxX⌉, since a fractional safe edge always
// splits one pixel).
//
// Fill. "Reads at 16 px" is checked the same way: after the safe-area test
// the motif's bounding box must cover at least `minimumFillFraction` (55 %)
// of the safe rectangle in each axis, and the process exits 6 if it does
// not. A motif can be inside the safe area and still be a sliver, which is
// exactly the failure this catches.
//
// Layout is measured like the fill is. At ≥ 256 px the self-check walks
// the rendered bitmap along each edge: from the station rim outward until
// it meets the first orange bar pixel (bar-to-rim distance), and from each
// node's outline along its incoming edge until it meets the first ink
// pixel (the arrowhead gap). It prints all three and exits 7 if the
// bar-to-rim distance or either head gap is more than two pixels off the
// layout's own `barSpacing` / `arrowGap`, or if the bars are missing.
// (The tinted mask has no hue to find, so only the light and dark renders
// measure; tinted prints the geometric values.)
//
// Seeing it. `--preview` prints an ASCII map of the rendered pixels
// (luminance-bucketed, background blank) next to the numbers, so the small
// tiers can be reviewed in a terminal without opening an image editor:
//
//     swiftc -O -o /tmp/make_icon assets/make_icon.swift
//     /tmp/make_icon 16 /tmp/i16.png --preview
//     /tmp/make_icon 256 /tmp/i256.png --preview     # + the queue / gap line

import AppKit
import CoreGraphics
import Foundation

// MARK: - Arguments

enum Appearance: String {
    case light, dark, tinted
    /// The tinted variant is an alpha mask: no plate, no colour.
    var drawsPlate: Bool { self != .tinted }
    var isMonochrome: Bool { self == .tinted }
}

// Parse by position, not by value: `--appearance` consumes exactly the one
// argument after it, so an output path that happens to be named "dark.png"
// is still an output path.
var appearance = Appearance.light
var wantsPreview = false
var positional: [String] = []
do {
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        if args[i] == "--preview" {
            wantsPreview = true
            i += 1
        } else if args[i] == "--appearance" {
            guard i + 1 < args.count, let a = Appearance(rawValue: args[i + 1]) else {
                fputs("make_icon: --appearance takes light, dark or tinted\n", stderr)
                exit(64)
            }
            appearance = a
            i += 2
        } else {
            positional.append(args[i])
            i += 1
        }
    }
}
guard positional.count == 2, let px = Int(positional[0]), px >= 8 else {
    fputs("usage: swift make_icon.swift <px> <out.png> [--appearance light|dark|tinted] [--preview]\n", stderr)
    exit(64)
}
let outputPath = positional[1]
let size = CGFloat(px)

// MARK: - Palette (sRGB)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [r, g, b, a])!
}

// The dark plate is deeper and flatter than the light one — on a dark Dock
// the light gradient's top end reads as a glow rather than a surface.
let bgTop     = appearance == .dark ? rgb(0.10, 0.19, 0.38) : rgb(0.17, 0.32, 0.62)
let bgBottom  = appearance == .dark ? rgb(0.03, 0.06, 0.16) : rgb(0.06, 0.11, 0.28)

/// In the tinted variant every element becomes white at a fixed alpha and
/// the system applies the user's tint, so the motif has to carry its
/// structure with *value* alone: the nodes step down from the shafts, and
/// the outlines vanish (an outline at the same alpha as its fill is
/// invisible once both are one colour).
func maskWhite(_ alpha: CGFloat) -> CGColor { rgb(1, 1, 1, alpha) }

let ink         = appearance.isMonochrome ? maskWhite(1.00) : rgb(1, 1, 1, 0.95)
let stationFill = appearance.isMonochrome ? maskWhite(0.80) : rgb(0.80, 0.87, 0.98)
let sourceFill  = appearance.isMonochrome ? maskWhite(0.62) : rgb(0.75, 0.93, 0.78)
let sinkFill    = appearance.isMonochrome ? maskWhite(0.62) : rgb(0.98, 0.80, 0.80)
let bufferFill  = appearance.isMonochrome ? maskWhite(0.45) : rgb(0.99, 0.86, 0.66)
let dotInk      = appearance.isMonochrome ? maskWhite(0.30) : rgb(0.10, 0.30, 0.70, 0.85)

// MARK: - Bitmap contexts

func makeContext() -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("could not create bitmap context\n", stderr)
        exit(1)
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

let ctx = makeContext()

// MARK: - Background: mask, gradient, highlight, vignette

let cornerRadius = size * 0.2237
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius, transform: nil)

func drawBackground(in ctx: CGContext) {
    // The tinted variant is a transparent alpha mask: no plate at all.
    guard appearance.drawsPlate else { return }
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Soft radial lift in the upper-left for depth.
    let lift = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(lift,
                           startCenter: CGPoint(x: size * 0.30, y: size * 0.80), startRadius: 0,
                           endCenter: CGPoint(x: size * 0.30, y: size * 0.80), endRadius: size * 0.60,
                           options: [])

    // Bottom vignette so the icon sits on the Dock shelf like system icons.
    // Softer at the small sizes: at 16–32 px a 22 % vignette turns the lower
    // 40 % near-black in Finder list view and kills the blue identity.
    let vignetteAlpha: CGFloat = px <= 32 ? 0.10 : 0.22
    let vignette = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, vignetteAlpha)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(vignette,
                           start: CGPoint(x: 0, y: size * 0.35),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Top inner highlight: 1 device px of white at 25 %, clipped to the mask.
    // Dropped in the dark variant — a bright rim on a dark plate reads as a
    // seam, which is why the system's own dark icons do not carry one.
    guard appearance != .dark else { ctx.restoreGState(); return }
    let highlightWidth: CGFloat = max(1, (size / 512).rounded())
    ctx.setStrokeColor(rgb(1, 1, 1, 0.25))
    ctx.setLineWidth(highlightWidth * 2) // half is clipped away by the mask
    ctx.addPath(bgPath)
    ctx.strokePath()
    ctx.restoreGState()
}

drawBackground(in: ctx)

// MARK: - Drawing helpers

/// Safe-area frame: Apple's 80 % rule.
let safe = bgRect.insetBy(dx: size * 0.10, dy: size * 0.10)

/// Device-pixel-aware stroke: never thinner than `minPx` pixels.
func stroke(_ fraction: CGFloat, minPx: CGFloat) -> CGFloat {
    max(minPx, size * fraction)
}

func strokeCircle(at c: CGPoint, radius: CGFloat, fill: CGColor, line: CGColor, width: CGFloat) {
    let r = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
    ctx.setFillColor(fill)
    ctx.fillEllipse(in: r)
    ctx.setStrokeColor(line)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: r)
}

func strokeRoundedSquare(at c: CGPoint, half: CGFloat, fill: CGColor, line: CGColor, width: CGFloat) {
    let r = CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)
    let p = CGPath(roundedRect: r, cornerWidth: half * 0.22, cornerHeight: half * 0.22, transform: nil)
    ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(p); ctx.setStrokeColor(line); ctx.setLineWidth(width); ctx.strokePath()
}

func diamondPath(at c: CGPoint, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + radius))
    p.addLine(to: CGPoint(x: c.x + radius, y: c.y))
    p.addLine(to: CGPoint(x: c.x, y: c.y - radius))
    p.addLine(to: CGPoint(x: c.x - radius, y: c.y))
    p.closeSubpath()
    return p
}

func strokeDiamond(at c: CGPoint, radius: CGFloat, fill: CGColor, line: CGColor, width: CGFloat) {
    let p = diamondPath(at: c, radius: radius)
    ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
    ctx.setLineJoin(.round)
    ctx.addPath(p); ctx.setStrokeColor(line); ctx.setLineWidth(width); ctx.strokePath()
}

/// Straight arrow with a chevron head. `inset` pulls both ends back so the
/// shaft stops at a node's edge rather than its centre.
func arrow(from a: CGPoint, to b: CGPoint, insetStart: CGFloat, insetEnd: CGFloat,
           width: CGFloat, head: CGFloat, color: CGColor) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let start = CGPoint(x: a.x + ux * insetStart, y: a.y + uy * insetStart)
    let end   = CGPoint(x: b.x - ux * insetEnd,   y: b.y - uy * insetEnd)

    // Shaft stops where the head begins, so the round cap does not poke out
    // of the triangle's back edge.
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let shaftEnd = CGPoint(x: end.x - ux * head * 0.85, y: end.y - uy * head * 0.85)
    ctx.move(to: start); ctx.addLine(to: shaftEnd); ctx.strokePath()

    // A FILLED triangle, not two stroked arms: at icon sizes the round caps
    // of a stroked chevron read as a hook rather than an arrowhead.
    let nx = -uy, ny = ux
    let back = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
    let p1 = CGPoint(x: back.x + nx * head * 0.52, y: back.y + ny * head * 0.52)
    let p2 = CGPoint(x: back.x - nx * head * 0.52, y: back.y - ny * head * 0.52)
    ctx.setFillColor(color)
    ctx.move(to: end); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
    ctx.fillPath()
}

/// Queue bars: `count` short bars perpendicular to `direction`, the first
/// `spacing` before `rim` (the point where the edge meets the station's
/// outline) and each further one another `spacing` back — the row of
/// waiting jobs a queueing diagram draws in front of the server.
func queueBars(rim: CGPoint, direction: CGPoint, count: Int,
               spacing: CGFloat, barHeight: CGFloat, width: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    let px = -direction.y, py = direction.x
    for i in 0..<count {
        let d = spacing * CGFloat(i + 1)
        let c = CGPoint(x: rim.x - direction.x * d, y: rim.y - direction.y * d)
        ctx.move(to: CGPoint(x: c.x + px * barHeight / 2, y: c.y + py * barHeight / 2))
        ctx.addLine(to: CGPoint(x: c.x - px * barHeight / 2, y: c.y - py * barHeight / 2))
        ctx.strokePath()
    }
}

/// Distance from a node's centre to the OUTER edge of its outline stroke
/// along the unit direction `u` — so an edge can stop the same distance
/// short of a disc, a diamond and a square. The stroke is folded in
/// before dividing by the direction: it thickens the shape perpendicular
/// to the shape's own edge, not along the ray (a square's outer edge is
/// `half + line/2` from the centre measured straight out, and a ray that
/// meets it at an angle reaches it at that over the ray's cosine — the
/// naive `t + line/2` was 1.5 px short at 1024 px, which the pixel
/// self-check caught). A diamond's edges lie at 45°, so its L1 offset is
/// `line/2 · √2`.
func discOutline(radius: CGFloat, line: CGFloat) -> CGFloat { radius + line / 2 }
func diamondOutline(radius: CGFloat, line: CGFloat, along u: CGPoint) -> CGFloat {
    (radius + line / 2 * 2.0.squareRoot()) / (abs(u.x) + abs(u.y))
}
func squareOutline(half: CGFloat, line: CGFloat, along u: CGPoint) -> CGFloat {
    (half + line / 2) / max(abs(u.x), abs(u.y))
}

/// Unit vector from `a` to `b`.
func direction(from a: CGPoint, to b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
    return CGPoint(x: dx / len, y: dy / len)
}

/// What the diagram tiers lay out, kept so the self-check can measure
/// the render against the same numbers it was drawn from.
struct DiagramLayout {
    var source = CGPoint.zero, station = CGPoint.zero, sink = CGPoint.zero
    /// One gap between every arrowhead / tail and the outline it meets.
    var arrowGap: CGFloat = 0
    /// Where the source→station edge meets the station's outline (rim).
    var stationRimIn = CGPoint.zero
    /// Where the station→sink edge meets the sink's outline.
    var sinkOutline = CGPoint.zero
    /// Queue bars (full-detail tier only): count, pitch, bar height.
    var barCount = 0
    var barSpacing: CGFloat = 0
    var barHeight: CGFloat = 0
    /// Unit directions of the two edges.
    var dirIn = CGPoint.zero, dirOut = CGPoint.zero
}

/// One device pixel, filled (pixel art for the two smallest tiers).
func pixel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1) {
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}

// MARK: - Tier 1: ≤ 32 px — the triangle reduced to pixel art

/// One device-pixel line between two pixel centres (Bresenham), used for
/// the shafts in the pixel-art tiers. `CGContext.strokePath` at these sizes
/// antialiases a diagonal into a grey smear; stepping pixel by pixel keeps
/// every shaft one hard pixel wide.
func pixelLine(from a: (Int, Int), to b: (Int, Int), colour: CGColor) {
    ctx.setFillColor(colour)
    var (x0, y0) = a
    let (x1, y1) = b
    let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
    let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while true {
        pixel(CGFloat(x0), CGFloat(y0))
        if x0 == x1 && y0 == y1 { break }
        let e2 = 2 * err
        if e2 >= dy { err += dy; x0 += sx }
        if e2 <= dx { err += dx; y0 += sy }
    }
}

func drawSmallMotif() {
    // The SAME picture as every larger tier — source diamond bottom-left,
    // station disc top-centre, sink square bottom-right — drawn as device
    // pixels so nothing smears. Odd diameters throughout, so every shape is
    // pixel-centred.
    //
    //   16 px: ⌀5 / ⌀5 / 5, safe columns 1…14 → motif fills 14 × 14   ✓
    //   32 px: ⌀9 / ⌀11 / 9, safe columns 3…28 → motif fills 26 × 26  ✓
    let tiny = px <= 16
    let diamondD: CGFloat = tiny ? 5 : 9       // corner-to-corner, odd
    let discD: CGFloat = tiny ? 5 : 11         // odd → pixel-centred
    let squareD: CGFloat = tiny ? 5 : 9        // odd
    let ringW: CGFloat = tiny ? 0 : 1

    // Work in whole pixels against the safe rectangle the self-check uses,
    // so the layout and the assertion cannot disagree.
    let lo = CGFloat(Int(safe.minX.rounded(.down)))          // first allowed index
    let hi = CGFloat(Int(safe.maxX.rounded(.up)) - 1)        // last allowed index
    let span = hi - lo + 1

    // Bottom row: the diamond hugs the left edge, the square the right.
    let diamondCX = lo + (diamondD - 1) / 2
    let squareCX  = hi - (squareD - 1) / 2
    let bottomCY  = lo + (max(diamondD, squareD) - 1) / 2
    // Top row: the disc is centred horizontally and hugs the top edge.
    let discCX = lo + ((span - 1) / 2).rounded()
    let discCY = hi - (discD - 1) / 2

    // Shafts first, so the nodes overdraw their endpoints.
    let intD = { (v: CGFloat) in Int(v.rounded()) }
    pixelLine(from: (intD(diamondCX + (diamondD - 1) / 2), intD(bottomCY)),
              to: (intD(discCX), intD(discCY - (discD - 1) / 2)), colour: ink)
    pixelLine(from: (intD(discCX), intD(discCY - (discD - 1) / 2)),
              to: (intD(squareCX - (squareD - 1) / 2), intD(bottomCY)), colour: ink)

    // Source: a filled diamond, drawn row by row so the tips are one pixel.
    ctx.setFillColor(sourceFill)
    let dR = (diamondD - 1) / 2
    for row in stride(from: -dR, through: dR, by: 1) {
        let halfWidth = dR - abs(row)          // 0 at the tips
        pixel(diamondCX - halfWidth, bottomCY + row, halfWidth * 2 + 1, 1)
    }

    // Station: the disc, drawn row by row rather than with `fillEllipse`.
    // A 5-px antialiased circle spends two of its five rows on grey, which
    // at 16 px reads as a smudge; a hand-stepped disc is hard-edged and
    // still unmistakably round. At 32 px a 1-px ring makes it an outlined
    // node like the larger tiers.
    ctx.setFillColor(stationFill)
    let cR = (discD - 1) / 2
    for row in stride(from: -cR, through: cR, by: 1) {
        // Widest row through the centre, tapering by the circle equation.
        let half = ((cR + 0.45) * (cR + 0.45) - row * row).squareRoot().rounded(.down)
        pixel(discCX - half, discCY + row, half * 2 + 1, 1)
    }
    if ringW > 0 {
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(ringW)
        ctx.strokeEllipse(in: CGRect(x: discCX + 0.5 - CGFloat(cR) - 0.5 + ringW / 2,
                                     y: discCY + 0.5 - CGFloat(cR) - 0.5 + ringW / 2,
                                     width: discD - ringW, height: discD - ringW))
    }

    // Sink: a square. Above 16 px the four corner pixels are knocked out so
    // it reads as the rounded square the large tiers draw.
    ctx.setFillColor(sinkFill)
    let sR = (squareD - 1) / 2
    if tiny {
        pixel(squareCX - sR, bottomCY - sR, squareD, squareD)
    } else {
        pixel(squareCX - sR, bottomCY - sR + 1, squareD, squareD - 2)   // middle band
        pixel(squareCX - sR + 1, bottomCY - sR, squareD - 2, 1)         // bottom row
        pixel(squareCX - sR + 1, bottomCY + sR, squareD - 2, 1)         // top row
    }
}

// MARK: - Tier 2 / 3: network diagram

@discardableResult
func drawDiagram(detailed: Bool) -> DiagramLayout {
    // Strokes: heavier in the mid tier, refined at ≥ 256 px.
    let nodeLine  = detailed ? stroke(0.025, minPx: 2) : stroke(0.035, minPx: 2)
    let arrowLine = detailed ? stroke(0.030, minPx: 2) : stroke(0.048, minPx: 2)
    let head      = detailed ? size * 0.042 : max(4, size * 0.060)
    let nodeRadius = size * 0.115

    // Diamond radius is corner-to-centre and the square's half-side is
    // edge-to-centre, so the diamond is scaled up a little to read as the
    // same visual weight as the circle.
    let sourceRadius = nodeRadius * 1.25
    let sinkHalf     = nodeRadius

    // The triangle, anchored to the safe rectangle so the motif fills it in
    // both axes: the diamond's left corner (round join → half the stroke
    // beyond the corner) touches safe.minX and its bottom corner touches
    // safe.minY; the square's right edge touches safe.maxX; the disc's top
    // touches safe.maxY.
    let bottomY = safe.minY + sourceRadius + nodeLine / 2
    let source  = CGPoint(x: safe.minX + sourceRadius + nodeLine / 2, y: bottomY)
    let sink    = CGPoint(x: safe.maxX - sinkHalf - nodeLine / 2,     y: bottomY)
    let station = CGPoint(x: safe.midX, y: safe.maxY - nodeRadius - nodeLine / 2)

    var layout = DiagramLayout()
    layout.source = source; layout.station = station; layout.sink = sink
    layout.dirIn = direction(from: source, to: station)
    layout.dirOut = direction(from: station, to: sink)

    // ONE gap between every arrowhead / tail and the outline it meets.
    // The outline distances are computed for each edge's direction, so
    // the head that meets the disc and the head that meets the square
    // float the same distance from their nodes — the second used to sit
    // `sinkHalf * 1.60` from the square's CENTRE, a visibly larger gap.
    let gap = nodeLine * 1.25
    layout.arrowGap = gap
    let inTail  = diamondOutline(radius: sourceRadius, line: nodeLine, along: layout.dirIn) + gap
    let inRim   = discOutline(radius: nodeRadius, line: nodeLine)
    let outTail = inRim + gap
    let outHead = squareOutline(half: sinkHalf, line: nodeLine, along: layout.dirOut) + gap
    layout.stationRimIn = CGPoint(x: station.x - layout.dirIn.x * inRim,
                                  y: station.y - layout.dirIn.y * inRim)
    layout.sinkOutline = CGPoint(x: sink.x - layout.dirOut.x * (outHead - gap),
                                 y: sink.y - layout.dirOut.y * (outHead - gap))

    // Full-detail tier: the buffer. The incoming shaft stops, three short
    // bars stand in a tight row (pitch `barSpacing`, no taller than three
    // node strokes), then the station rim: "→ ||| ○". The arrowhead stops
    // one pitch before the first bar, so the head-to-bar gap, the bar
    // pitch and the bar-to-rim gap are all the same number.
    let barSpacing = size * 0.030
    let barCount = detailed ? 3 : 0
    let inHead = inRim + gap + (detailed ? barSpacing * CGFloat(barCount + 1) - gap : 0)

    // Arrows first so nodes overdraw their endpoints cleanly.
    arrow(from: source, to: station, insetStart: inTail,
          insetEnd: inHead, width: arrowLine, head: head, color: ink)
    arrow(from: station, to: sink, insetStart: outTail,
          insetEnd: outHead, width: arrowLine, head: head, color: ink)

    if detailed {
        layout.barCount = barCount
        layout.barSpacing = barSpacing
        layout.barHeight = nodeLine * 2.5
        queueBars(rim: layout.stationRimIn, direction: layout.dirIn, count: barCount,
                  spacing: barSpacing, barHeight: layout.barHeight,
                  width: stroke(0.014, minPx: 2), color: bufferFill)
    }

    strokeDiamond(at: source, radius: sourceRadius,
                  fill: sourceFill, line: ink, width: nodeLine)
    strokeCircle(at: station, radius: nodeRadius,
                 fill: stationFill, line: ink, width: nodeLine)
    strokeRoundedSquare(at: sink, half: sinkHalf,
                        fill: sinkFill, line: ink, width: nodeLine)

    // Inner "state" dot reinforces the Brownian / diffusion reading, but
    // only where it has room to be a separate shape.
    if detailed {
        ctx.setFillColor(dotInk)
        let innerR = nodeRadius * 0.30
        ctx.fillEllipse(in: CGRect(x: station.x - innerR, y: station.y - innerR,
                                   width: innerR * 2, height: innerR * 2))
    }
    return layout
}

var diagramLayout: DiagramLayout? = nil
if px <= 32 {
    drawSmallMotif()
} else if px < 256 {
    drawDiagram(detailed: false)
} else {
    diagramLayout = drawDiagram(detailed: true)
}

// MARK: - Self-check: the motif must stay inside the safe area

/// Pixel bounding box of everything that differs from a background-only
/// render (any channel off by more than 2/255). Returns nil when nothing
/// was drawn.
func motifBounds() -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    let bgCtx = makeContext()
    drawBackground(in: bgCtx)
    guard let a = ctx.data, let b = bgCtx.data else { return nil }
    let pa = a.assumingMemoryBound(to: UInt8.self)
    let pb = b.assumingMemoryBound(to: UInt8.self)
    let stride = ctx.bytesPerRow
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<px {
        for x in 0..<px {
            let i = y * stride + x * 4
            var differs = false
            for c in 0..<4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > 2 { differs = true }
            if differs {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return maxX < 0 ? nil : (minX, maxX, minY, maxY)
}

guard let bounds = motifBounds() else {
    fputs("\(px) px: nothing drawn\n", stderr); exit(5)
}
// Bitmap rows count from the top; the safe rect is symmetric so the test
// is the same either way.
let allowedMin = Int(floor(safe.minX))          // first allowed column / row
let allowedMax = Int(ceil(safe.maxX)) - 1       // last allowed column / row
let inside = bounds.minX >= allowedMin && bounds.maxX <= allowedMax
          && bounds.minY >= allowedMin && bounds.maxY <= allowedMax
/// A motif can sit inside the safe area and still be a sliver — the old
/// 16-px tier filled 39 % of the safe height and read as a blob. The
/// silhouette must occupy at least this much of the safe rectangle in each
/// axis, and the check runs on every slot of every appearance.
let minimumFillFraction: CGFloat = 0.55
let safeSpan = safe.width
let fillX = CGFloat(bounds.maxX - bounds.minX + 1) / safeSpan
let fillY = CGFloat(bounds.maxY - bounds.minY + 1) / safeSpan
let fills = fillX >= minimumFillFraction && fillY >= minimumFillFraction

let report = String(
    format: "%4d px: motif x[%d…%d] y[%d…%d]  (%d × %d)  safe %.1f…%.1f → columns %d…%d  fill %.0f%% × %.0f%%  %@",
    px, bounds.minX, bounds.maxX, bounds.minY, bounds.maxY,
    bounds.maxX - bounds.minX + 1, bounds.maxY - bounds.minY + 1,
    safe.minX, safe.maxX, allowedMin, allowedMax,
    Double(fillX * 100), Double(fillY * 100),
    !inside ? "OUTSIDE SAFE AREA" : (fills ? "OK" : "UNDERFILLED"))
print(report)

if wantsPreview {
    // Luminance buckets against the background-only render, so the plate
    // prints blank and only the motif shows. Two characters per pixel
    // because a terminal cell is about half as wide as it is tall.
    let bgCtx = makeContext()
    drawBackground(in: bgCtx)
    if let a = ctx.data, let b = bgCtx.data {
        let pa = a.assumingMemoryBound(to: UInt8.self)
        let pb = b.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow
        let ramp: [Character] = [".", ":", "+", "*", "#", "@"]
        for y in 0..<px {                       // bitmap row 0 is the TOP row
            var line = ""
            for x in 0..<px {
                let i = y * stride + x * 4
                var d = 0
                for c in 0..<3 { d = max(d, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
                if d <= 2 {
                    line += "  "
                } else {
                    let bucket = min(ramp.count - 1, d * ramp.count / 256)
                    line += String(ramp[bucket]) + String(ramp[bucket])
                }
            }
            print("      |\(line)|")
        }
    }
}

if !inside {
    fputs("make_icon: motif leaves the 80 % safe area at \(px) px\n", stderr)
    exit(5)
}
if !fills {
    fputs(String(format: "make_icon: motif fills only %.0f%% × %.0f%% of the safe area at %d px (needs %.0f%% in each axis — it would read as a sliver in a Finder list)\n",
                 Double(fillX * 100), Double(fillY * 100), px,
                 Double(minimumFillFraction * 100)), stderr)
    exit(6)
}

// MARK: - Self-check: the queue bars and the arrowhead gaps, measured

/// sRGB components (un-premultiplied) of the rendered pixel under a
/// CoreGraphics point; nil off the bitmap.
func pixelColour(at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
    let x = Int(p.x.rounded(.down)), yUp = Int(p.y.rounded(.down))
    guard x >= 0, x < px, yUp >= 0, yUp < px, let data = ctx.data else { return nil }
    let row = px - 1 - yUp                        // bitmap row 0 is the TOP row
    let base = data.assumingMemoryBound(to: UInt8.self) + row * ctx.bytesPerRow + x * 4
    let a = CGFloat(base[3]) / 255
    guard a > 0 else { return (0, 0, 0, 0) }
    return (CGFloat(base[0]) / 255 / a, CGFloat(base[1]) / 255 / a, CGFloat(base[2]) / 255 / a, a)
}

/// Distance along `direction` from `origin` to the first pixel `matches`
/// accepts, sampled every quarter pixel up to `limit`; nil if none.
func firstPixel(from origin: CGPoint, along direction: CGPoint, limit: CGFloat,
                where matches: ((r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> Bool) -> CGFloat? {
    var d: CGFloat = 0
    while d <= limit {
        let p = CGPoint(x: origin.x + direction.x * d, y: origin.y + direction.y * d)
        if let c = pixelColour(at: p), c.a > 0.5, matches(c) { return d }
        d += 0.25
    }
    return nil
}

if let layout = diagramLayout {
    // Orange (the buffer bars) against the blue plate and the white ink;
    // white (the ink) against everything else. Anti-aliased edge pixels
    // blend toward the plate and match neither, which is what makes the
    // first match the bar's / head's real edge to a quarter pixel.
    let isOrange: ((r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> Bool = {
        $0.r > 0.85 && $0.g > 0.65 && $0.b < 0.80 && $0.r - $0.b > 0.15
    }
    let isInk: ((r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> Bool = {
        $0.r > 0.85 && $0.g > 0.85 && $0.b > 0.85
    }
    let limit = size * 0.35
    let back = CGPoint(x: -layout.dirIn.x, y: -layout.dirIn.y)      // station → source
    // A filled arrowhead comes to a point, so the centre-line sample
    // crosses the 85 % ink threshold a pixel or so behind the tip.
    let tolerance = max(2.5, size * 0.006)

    var lines: [String] = []
    var problems: [String] = []
    lines.append(String(format: "%4d px: layout  bars %d × pitch %.1f px (height %.1f px), first bar %.1f px from the station rim; arrowhead gap %.1f px at both the station and the sink",
                        px, layout.barCount, Double(layout.barSpacing), Double(layout.barHeight),
                        Double(layout.barSpacing), Double(layout.arrowGap)))

    if appearance.isMonochrome {
        lines.append("         measured: skipped for the tinted mask (no hue to find)")
    } else {
        // Bar-to-rim: walk from the rim outward until the first orange pixel.
        if let d = firstPixel(from: layout.stationRimIn, along: back, limit: limit, where: isOrange) {
            let expected = layout.barSpacing - stroke(0.014, minPx: 2) / 2   // to the bar's near edge
            lines.append(String(format: "         measured  first bar %.2f px from the rim (expected %.2f)", Double(d), Double(expected)))
            if abs(d - expected) > tolerance { problems.append("bar-to-rim distance off by \(Double(abs(d - expected)))") }
        } else {
            problems.append("no queue bar found in front of the station")
        }
        // Head gap at the station: past the bars, the first ink pixel.
        let pastBars = layout.barSpacing * CGFloat(layout.barCount) + stroke(0.014, minPx: 2)
        let pastOrigin = CGPoint(x: layout.stationRimIn.x + back.x * pastBars,
                                 y: layout.stationRimIn.y + back.y * pastBars)
        if let d = firstPixel(from: pastOrigin, along: back, limit: limit, where: isInk) {
            let gapAtStation = d + pastBars - layout.barSpacing * CGFloat(layout.barCount)
            lines.append(String(format: "         measured  arrowhead %.2f px behind the last bar (expected %.2f)", Double(gapAtStation), Double(layout.barSpacing)))
            if abs(gapAtStation - layout.barSpacing) > tolerance { problems.append("station arrowhead gap off by \(Double(abs(gapAtStation - layout.barSpacing)))") }
        } else {
            problems.append("no arrowhead found behind the queue bars")
        }
        // Head gap at the sink: from the square's outline back along the
        // edge. The walk starts one pixel out, because the outline's own
        // outer pixel is ink too.
        let backOut = CGPoint(x: -layout.dirOut.x, y: -layout.dirOut.y)
        let outStart = CGPoint(x: layout.sinkOutline.x + backOut.x, y: layout.sinkOutline.y + backOut.y)
        if let d = firstPixel(from: outStart, along: backOut, limit: limit, where: isInk) {
            let gapAtSink = d + 1
            lines.append(String(format: "         measured  arrowhead %.2f px from the sink outline (expected %.2f)", Double(gapAtSink), Double(layout.arrowGap)))
            if abs(gapAtSink - layout.arrowGap) > tolerance { problems.append("sink arrowhead gap off by \(Double(abs(gapAtSink - layout.arrowGap)))") }
        } else {
            problems.append("no arrowhead found in front of the sink")
        }
    }
    for l in lines { print(l) }
    if !problems.isEmpty {
        fputs("make_icon: queue / arrowhead layout does not match the render at \(px) px: \(problems.joined(separator: "; "))\n", stderr)
        exit(7)
    }
}

// MARK: - Write PNG

guard let cgImage = ctx.makeImage() else {
    fputs("failed to make image\n", stderr); exit(2)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: px, height: px)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode png\n", stderr); exit(3)
}
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("failed to write \(outputPath): \(error)\n", stderr); exit(4)
}
print("      wrote \(outputPath) (\(px)x\(px), \(data.count) bytes)")
