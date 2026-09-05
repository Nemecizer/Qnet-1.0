import SwiftUI
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// Canvas geometry
// ─────────────────────────────────────────────────────────────────────────────
//
// Everything the canvas needs to map between the document ("world") space
// that node positions are stored in and the viewport ("display") space
// that mouse events and drawing happen in, plus the link routing that both
// the renderer and the hit-tester share.  Keeping these pure value types
// in one place guarantees that what is drawn is exactly what is hit.
//
//   display = world · scale + pan
//
// World coordinates are plain: at zoom 1 with no pan, world == display,
// so every `.bnet` written by earlier versions still opens in place.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Transform

/// The zoom / pan / viewport triple that maps world points to display
/// points.  Value type so that a scene can be built once per frame from a
/// consistent snapshot.
struct CanvasTransform: Equatable {
    var scale: CGFloat
    var pan: CGSize
    var viewportSize: CGSize

    static let identity = CanvasTransform(scale: 1, pan: .zero, viewportSize: .zero)

    func toDisplay(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + pan.width, y: p.y * scale + pan.height)
    }

    func toLogical(_ p: CGPoint) -> CGPoint {
        guard scale > 0 else { return p }
        return CGPoint(x: (p.x - pan.width) / scale, y: (p.y - pan.height) / scale)
    }

    func toDisplay(_ r: CGRect) -> CGRect {
        let o = toDisplay(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    /// World rectangle currently visible in the viewport.
    var visibleWorldRect: CGRect {
        let a = toLogical(.zero)
        let b = toLogical(CGPoint(x: viewportSize.width, y: viewportSize.height))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    var viewportCentre: CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    /// A copy zoomed to `newScale` such that the world point under
    /// `displayAnchor` stays exactly under it.
    func zoomed(to newScale: CGFloat, about displayAnchor: CGPoint) -> CanvasTransform {
        let world = toLogical(displayAnchor)
        var t = self
        t.scale = newScale
        t.pan = CGSize(width: displayAnchor.x - world.x * newScale,
                       height: displayAnchor.y - world.y * newScale)
        return t
    }

    /// Transform that shows `worldRect` centred in `viewport` with
    /// `margin` display points on every side, clamped to `zoomRange`.
    static func fitting(
        worldRect: CGRect,
        in viewport: CGSize,
        margin: CGFloat,
        zoomRange: ClosedRange<CGFloat>
    ) -> CanvasTransform {
        let availW = max(viewport.width - 2 * margin, 1)
        let availH = max(viewport.height - 2 * margin, 1)
        let w = max(worldRect.width, 1)
        let h = max(worldRect.height, 1)
        let raw = min(availW / w, availH / h)
        let scale = min(zoomRange.upperBound, max(zoomRange.lowerBound, raw))
        let centre = CGPoint(x: worldRect.midX, y: worldRect.midY)
        let pan = CGSize(width: viewport.width / 2 - centre.x * scale,
                         height: viewport.height / 2 - centre.y * scale)
        return CanvasTransform(scale: scale, pan: pan, viewportSize: viewport)
    }
}

// MARK: - Node outlines

/// Shape metrics for every node kind, in world units at zoom 1.  Both the
/// SwiftUI node view and the link router read from here so a link always
/// ends exactly on the drawn outline.
enum NodeOutline {
    static func size(for kind: NodeKind) -> CGSize {
        switch kind {
        case .station: return CGSize(width: 48, height: 48)
        case .buffer:  return CGSize(width: 52, height: 44)
        case .source:  return CGSize(width: 46, height: 46)
        case .sink:    return CGSize(width: 48, height: 48)
        }
    }

    /// Corner radius of the sink's rounded square.
    static let sinkCornerRadius: CGFloat = 8

    /// Width of the name / distribution / rate block `NetworkNodeView`
    /// hangs under every node, in world points at zoom 1, and the gap
    /// between the body's bottom edge and the block's first row.  The
    /// node view lays the block out from these, the link router treats
    /// the block as a soft obstacle and the diagram export pads for it —
    /// one definition, so an arrow cannot be routed clear of a label the
    /// canvas then draws somewhere else.
    static let labelBlockWidth: CGFloat = 76
    static let labelBlockGap: CGFloat = 4

    /// Height of the label block at zoom 1: a 10-pt name row plus an 8-pt
    /// distribution row and an 8-pt μ · SCV row for stations and sources,
    /// the name and a buffer-size row for buffers, the name alone for a
    /// sink.  Sized to the rows the view really draws, so a sink's label
    /// does not block the space under it for three rows it never shows.
    static func labelBlockHeight(for kind: NodeKind) -> CGFloat {
        switch kind {
        case .station, .source: return 36
        case .buffer: return 24
        case .sink: return 13
        }
    }

    /// Bounding radius used for coarse culling and the pending-link ring.
    static func boundingRadius(for kind: NodeKind) -> CGFloat {
        let s = size(for: kind)
        return max(s.width, s.height) / 2 + 2
    }

    /// Exact containment test in node-local world coordinates (origin at
    /// the node centre, y down).  `slop` widens the outline uniformly so
    /// clicks a couple of points outside the stroke still count.
    static func contains(kind: NodeKind, localPoint p: CGPoint, slop: CGFloat = 0) -> Bool {
        let s = size(for: kind)
        let hw = s.width / 2 + slop
        let hh = s.height / 2 + slop
        switch kind {
        case .station:
            return p.x * p.x + p.y * p.y <= hw * hw
        case .source:
            // Diamond with half-diagonals hw / hh: |x|/hw + |y|/hh <= 1
            return abs(p.x) / hw + abs(p.y) / hh <= 1
        case .buffer:
            return abs(p.x) <= hw && abs(p.y) <= hh
        case .sink:
            guard abs(p.x) <= hw, abs(p.y) <= hh else { return false }
            let cr = sinkCornerRadius + slop
            let ix = abs(p.x) - (hw - cr)
            let iy = abs(p.y) - (hh - cr)
            if ix > 0 && iy > 0 {
                return ix * ix + iy * iy <= cr * cr
            }
            return true
        }
    }

    /// Distance from `origin` (node-local, must be inside the outline)
    /// along unit vector `direction` to the outline.  A short bisection
    /// against `contains` keeps one code path for every shape, including
    /// offset (parallel) rays for multi-class link bundles.
    static func exitDistance(kind: NodeKind, from origin: CGPoint, direction u: CGPoint) -> CGFloat {
        guard contains(kind: kind, localPoint: origin) else { return 0 }
        var lo: CGFloat = 0
        var hi: CGFloat = boundingRadius(for: kind) * 1.5
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            let p = CGPoint(x: origin.x + u.x * mid, y: origin.y + u.y * mid)
            if contains(kind: kind, localPoint: p) { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

// MARK: - Link geometry

/// Fully resolved display-space geometry of one link: where the stroke
/// starts and ends, the arrowhead triangle, the label anchor and a
/// flattened polyline for distance queries.
struct LinkGeometry: Equatable {
    enum Route: Equatable {
        case straight
        case quad(control: CGPoint)
        case cubic(c1: CGPoint, c2: CGPoint)
    }

    /// Stroke start (on the source outline).
    let start: CGPoint
    /// Stroke end — the arrowhead base, never the tip.
    let base: CGPoint
    /// Arrowhead tip (on the target outline).
    let tip: CGPoint
    let wingLeft: CGPoint
    let wingRight: CGPoint
    let route: Route
    /// Where a routing-probability label should be centred.
    let labelAnchor: CGPoint
    /// Flattened stroke (plus tip) for hit testing.
    let polyline: [CGPoint]

    /// Arrowhead length in display points.
    static func arrowLength(scale: CGFloat) -> CGFloat { max(6, 10 * scale) }
    /// Half-angle of the arrowhead (~28°).
    static let arrowHalfAngle: CGFloat = 28 * .pi / 180
    /// Line width in display points.
    static func lineWidth(scale: CGFloat) -> CGFloat { max(1, 2 * scale) }
    /// Half-width of the hit slab (10pt total).
    static let hitTolerance: CGFloat = 5

    var strokePath: Path {
        var p = Path()
        p.move(to: start)
        switch route {
        case .straight:
            p.addLine(to: base)
        case .quad(let c):
            p.addQuadCurve(to: base, control: c)
        case .cubic(let c1, let c2):
            p.addCurve(to: base, control1: c1, control2: c2)
        }
        return p
    }

    var arrowPath: Path {
        var p = Path()
        p.move(to: tip)
        p.addLine(to: wingLeft)
        p.addLine(to: wingRight)
        p.closeSubpath()
        return p
    }

    /// Minimum distance from `point` to the stroke or arrowhead.
    func distance(to point: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        if polyline.count == 1 {
            return CanvasMath.distance(point, polyline[0])
        }
        for i in 1..<polyline.count {
            let d = CanvasMath.pointToSegmentDistance(point, polyline[i - 1], polyline[i])
            if d < best { best = d }
        }
        return best
    }

    // MARK: Construction

    /// Straight or gently curved link between two distinct nodes.
    ///
    /// - parallelOffset: display-space perpendicular shift for links that
    ///   share the same directed node pair (multi-class bundles).
    /// - bulge: display-space sideways bow of a quadratic curve; zero
    ///   draws a straight segment.  Positive bows to the right of the
    ///   travel direction, so an opposite-direction partner given the
    ///   same positive bulge lands on the other side.
    static func between(
        fromCentre: CGPoint, fromKind: NodeKind,
        toCentre: CGPoint, toKind: NodeKind,
        scale: CGFloat,
        parallelOffset: CGFloat = 0,
        bulge: CGFloat = 0
    ) -> LinkGeometry {
        let gap: CGFloat = 1.5
        let dx = toCentre.x - fromCentre.x
        let dy = toCentre.y - fromCentre.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let u = CGPoint(x: dx / len, y: dy / len)
        let perp = CGPoint(x: -u.y, y: u.x)

        // Shifted centres for a parallel bundle member.
        let fromC = CGPoint(x: fromCentre.x + perp.x * parallelOffset,
                            y: fromCentre.y + perp.y * parallelOffset)
        let toC = CGPoint(x: toCentre.x + perp.x * parallelOffset,
                          y: toCentre.y + perp.y * parallelOffset)
        // Local (world-unit) offset of the shifted ray from each centre.
        let localOffset = CGPoint(x: perp.x * parallelOffset / scale,
                                  y: perp.y * parallelOffset / scale)

        let arrowLen = arrowLength(scale: scale)
        let wingSpread = arrowLen * tan(arrowHalfAngle)

        if bulge == 0 {
            let tFrom = NodeOutline.exitDistance(kind: fromKind, from: localOffset, direction: u) * scale + gap
            let tTo = NodeOutline.exitDistance(kind: toKind, from: localOffset,
                                               direction: CGPoint(x: -u.x, y: -u.y)) * scale + gap
            let start = CGPoint(x: fromC.x + u.x * tFrom, y: fromC.y + u.y * tFrom)
            let tip = CGPoint(x: toC.x - u.x * tTo, y: toC.y - u.y * tTo)
            let base = CGPoint(x: tip.x - u.x * arrowLen, y: tip.y - u.y * arrowLen)
            let wl = CGPoint(x: base.x + perp.x * wingSpread, y: base.y + perp.y * wingSpread)
            let wr = CGPoint(x: base.x - perp.x * wingSpread, y: base.y - perp.y * wingSpread)
            let mid = CGPoint(x: (start.x + base.x) / 2, y: (start.y + base.y) / 2)
            // Label side: outward of the bundle for a parallel member (so
            // two chips never sit on the same side of a two-class pair),
            // otherwise "above" the segment.
            var n = perp
            if parallelOffset != 0 {
                if parallelOffset < 0 { n = CGPoint(x: -n.x, y: -n.y) }
            } else if n.y > 0 {
                n = CGPoint(x: -n.x, y: -n.y)
            }
            let labelGap = 9 + lineWidth(scale: scale)
            let label = CGPoint(x: mid.x + n.x * labelGap, y: mid.y + n.y * labelGap)
            return LinkGeometry(start: start, base: base, tip: tip,
                                wingLeft: wl, wingRight: wr,
                                route: .straight, labelAnchor: label,
                                polyline: [start, base, tip])
        }

        // Curved: aim the end tangents at the control point so the stroke
        // leaves and enters the outlines along the curve, not the chord.
        let mid = CGPoint(x: (fromC.x + toC.x) / 2, y: (fromC.y + toC.y) / 2)
        let control = CGPoint(x: mid.x + perp.x * bulge, y: mid.y + perp.y * bulge)
        let dirStart = CanvasMath.unit(from: fromC, to: control)
        let dirEnd = CanvasMath.unit(from: control, to: toC)
        let tFrom = NodeOutline.exitDistance(kind: fromKind, from: localOffset, direction: dirStart) * scale + gap
        let tTo = NodeOutline.exitDistance(kind: toKind, from: localOffset,
                                           direction: CGPoint(x: -dirEnd.x, y: -dirEnd.y)) * scale + gap
        let start = CGPoint(x: fromC.x + dirStart.x * tFrom, y: fromC.y + dirStart.y * tFrom)
        let tip = CGPoint(x: toC.x - dirEnd.x * tTo, y: toC.y - dirEnd.y * tTo)
        let base = CGPoint(x: tip.x - dirEnd.x * arrowLen, y: tip.y - dirEnd.y * arrowLen)
        let endPerp = CGPoint(x: -dirEnd.y, y: dirEnd.x)
        let wl = CGPoint(x: base.x + endPerp.x * wingSpread, y: base.y + endPerp.y * wingSpread)
        let wr = CGPoint(x: base.x - endPerp.x * wingSpread, y: base.y - endPerp.y * wingSpread)
        var poly = CanvasMath.flattenQuad(from: start, control: control, to: base, segments: 12)
        poly.append(tip)
        // Label on the outer (convex) side of the bow.
        let apex = CanvasMath.quadPoint(start, control, base, t: 0.5)
        let side: CGFloat = bulge > 0 ? 1 : -1
        let labelGap = 9 + lineWidth(scale: scale)
        let label = CGPoint(x: apex.x + perp.x * side * labelGap,
                            y: apex.y + perp.y * side * labelGap)
        return LinkGeometry(start: start, base: base, tip: tip,
                            wingLeft: wl, wingRight: wr,
                            route: .quad(control: control), labelAnchor: label,
                            polyline: poly)
    }

    /// Self-loop drawn as an arc above the node.  `extraRadius` pushes
    /// additional loops (multi-class) outward so they nest.
    static func selfLoop(
        centre: CGPoint, kind: NodeKind,
        scale: CGFloat,
        extraRadius: CGFloat = 0
    ) -> LinkGeometry {
        let gap: CGFloat = 1.5
        let a1: CGFloat = -55 * .pi / 180    // upper-right (y is down)
        let a2: CGFloat = -125 * .pi / 180   // upper-left
        let d1 = CGPoint(x: cos(a1), y: sin(a1))
        let d2 = CGPoint(x: cos(a2), y: sin(a2))
        let r1 = NodeOutline.exitDistance(kind: kind, from: .zero, direction: d1) * scale + gap
        let r2 = NodeOutline.exitDistance(kind: kind, from: .zero, direction: d2) * scale + gap
        let loop = 40 * scale + extraRadius
        let arrowLen = arrowLength(scale: scale)
        let wingSpread = arrowLen * tan(arrowHalfAngle)

        let start = CGPoint(x: centre.x + d1.x * r1, y: centre.y + d1.y * r1)
        let tip = CGPoint(x: centre.x + d2.x * r2, y: centre.y + d2.y * r2)
        let c1 = CGPoint(x: centre.x + d1.x * (r1 + loop) + 4 * scale,
                         y: centre.y + d1.y * (r1 + loop))
        let c2 = CGPoint(x: centre.x + d2.x * (r2 + loop) - 4 * scale,
                         y: centre.y + d2.y * (r2 + loop))
        let dirEnd = CanvasMath.unit(from: c2, to: tip)
        let base = CGPoint(x: tip.x - dirEnd.x * arrowLen, y: tip.y - dirEnd.y * arrowLen)
        let endPerp = CGPoint(x: -dirEnd.y, y: dirEnd.x)
        let wl = CGPoint(x: base.x + endPerp.x * wingSpread, y: base.y + endPerp.y * wingSpread)
        let wr = CGPoint(x: base.x - endPerp.x * wingSpread, y: base.y - endPerp.y * wingSpread)
        var poly = CanvasMath.flattenCubic(from: start, c1: c1, c2: c2, to: base, segments: 16)
        poly.append(tip)
        let apex = CanvasMath.cubicPoint(start, c1, c2, base, t: 0.5)
        let label = CGPoint(x: apex.x, y: apex.y - 9 - lineWidth(scale: scale))
        return LinkGeometry(start: start, base: base, tip: tip,
                            wingLeft: wl, wingRight: wr,
                            route: .cubic(c1: c1, c2: c2), labelAnchor: label,
                            polyline: poly)
    }
}


// MARK: - Grid path

/// The world-space dot / line grid, built once in one place.
///
/// `GridCanvas` fills and strokes the result; `validation/canvas_perf`
/// times the same builder.  Keeping the construction here (rather than
/// letting the bench keep a copy) means the measured grid is literally
/// the shipping grid.
enum GridPath {
    /// Side of one minor dot in display points.
    static let dotSize: CGFloat = 1.5
    /// Cell size (display pt) at and below which minor dots are hidden.
    static let minorFadeStart: CGFloat = 16
    /// Cell-size band over which the minor dots fade in.
    static let minorFadeWidth: CGFloat = 8

    /// One frame's grid: the two paths plus the alpha each is drawn at.
    /// A `nil` path means "nothing to draw at this zoom".
    struct Result {
        var minorDots: Path?
        var minorAlpha: CGFloat
        var majorLines: Path?
        var majorAlpha: CGFloat
    }

    /// First grid line at or after display 0 for a world grid shifted by
    /// `offset` display points.
    static func firstLine(offset: CGFloat, step: CGFloat) -> CGFloat {
        var v = offset.truncatingRemainder(dividingBy: step)
        if v < 0 { v += step }
        return v
    }

    /// `gridSpacing` is `NetworkEditorModel.gridSpacing`, passed in
    /// rather than read here so this builder stays free of actor
    /// isolation and the offline bench can call it directly.
    static func build(transform: CanvasTransform, size: CGSize, gridSpacing: CGFloat) -> Result {
        var result = Result(minorDots: nil, minorAlpha: 0, majorLines: nil, majorAlpha: 0)
        let cell = gridSpacing * transform.scale
        guard cell > 0.5 else { return result }
        let major = cell * 4

        // Minor dots fade in between 16pt and 24pt cells and are gone at
        // or below 16pt.  That bounds the per-frame work: on a
        // 1600 x 1000 viewport the worst case is ~6k dots at 16pt
        // (near-invisible) and ~2.8k at full opacity — one Path of 1.5pt
        // squares (rects, not ellipses: four points each and
        // pixel-aligned on Retina), filled once.
        let minorAlpha = min(1, max(0, (cell - minorFadeStart) / minorFadeWidth))
        result.minorAlpha = minorAlpha
        if minorAlpha > 0.02 {
            var dots = Path()
            let x0 = firstLine(offset: transform.pan.width, step: cell)
            let y0 = firstLine(offset: transform.pan.height, step: cell)
            let d = dotSize
            let h = d / 2
            var x = x0
            while x <= size.width {
                var y = y0
                while y <= size.height {
                    dots.addRect(CGRect(x: x - h, y: y - h, width: d, height: d))
                    y += cell
                }
                x += cell
            }
            result.minorDots = dots
        }

        let majorAlpha = min(1, max(0, (major - 4) / 8))
        result.majorAlpha = majorAlpha
        if majorAlpha > 0 {
            var lines = Path()
            var x = firstLine(offset: transform.pan.width, step: major)
            while x <= size.width {
                let px = x.rounded() + 0.5
                lines.move(to: CGPoint(x: px, y: 0))
                lines.addLine(to: CGPoint(x: px, y: size.height))
                x += major
            }
            var y = firstLine(offset: transform.pan.height, step: major)
            while y <= size.height {
                let py = y.rounded() + 0.5
                lines.move(to: CGPoint(x: 0, y: py))
                lines.addLine(to: CGPoint(x: size.width, y: py))
                y += major
            }
            result.majorLines = lines
        }
        return result
    }
}

// MARK: - Routing obstacles

/// Display-space bodies of every node — and the label block under each
/// one — bucketed into a coarse uniform grid, so deciding whether one
/// link crosses somebody else's body costs a handful of rectangle tests
/// instead of a sweep over the network.
///
/// Two kinds of obstacle.  A *body* is hard: an arrow through a station
/// is wrong, full stop.  A *label* (the name / distribution / μ·SCV rows
/// `NetworkNodeView` hangs under the body, `CanvasScene.nodeLabelRect`)
/// is soft: an arrow through "S2 μ=1.25" is nearly as bad, so the router
/// avoids it when it can, but never at the price of crossing a body.
/// The two are tallied separately (`Hits`) so the router can rank a
/// candidate on that order.
///
/// Built once per `CanvasScene` and asked, per link, "which obstacles
/// does this candidate route enter that are not my endpoints'?".  A
/// reference type on purpose: it owns a scratch visit-stamp array so a
/// query allocates nothing, which matters because a dense network asks
/// the question a few thousand times per plan.
final class CanvasObstacles {
    /// World-space slack added around every node body, so a link that
    /// grazes an outline still counts as blocked and is routed around.
    static let padding: CGFloat = 6
    /// Slack around a label block — smaller than the body's, because
    /// text has no ring or halo the stroke has to keep clear of.
    static let labelPadding: CGFloat = 2

    /// One rectangle a route may have to avoid.
    struct Obstacle {
        let rect: CGRect
        /// A label block (soft) rather than a node body (hard).
        let isLabel: Bool
    }

    /// Separate tallies for the two kinds of obstacle a route enters.
    struct Hits: Equatable {
        var bodies = 0
        var labels = 0

        static let none = Hits()
        var isClear: Bool { bodies == 0 && labels == 0 }

        /// Ranking: any body crossing is worse than any number of label
        /// crossings; among equals, fewer labels wins.
        static func < (a: Hits, b: Hits) -> Bool {
            a.bodies != b.bodies ? a.bodies < b.bodies : a.labels < b.labels
        }

        mutating func add(_ obstacle: Obstacle) {
            if obstacle.isLabel { labels += 1 } else { bodies += 1 }
        }
    }

    private struct Body {
        let id: UUID
        let rect: CGRect
        let isLabel: Bool
    }

    private var bodies: [Body] = []
    private var buckets: [Int64: [Int32]] = [:]
    private let cell: CGFloat
    /// Per-body "last query that visited you" token; avoids a Set.
    private var stamp: [Int32] = []
    private var token: Int32 = 0

    var isEmpty: Bool { bodies.isEmpty }

    init(nodes: [NetworkNode], transform: CanvasTransform) {
        // Buckets a few node-widths across: big enough that a short link
        // touches one or two, small enough that a big network does not
        // put everything in one list.
        cell = max(48, 200 * max(transform.scale, 0.05))
        guard nodes.count > 2 else { return }
        let pad = Self.padding * transform.scale
        let labelPad = Self.labelPadding * transform.scale
        bodies.reserveCapacity(nodes.count * 2)
        for n in nodes {
            let r = transform.toDisplay(CanvasScene.nodeWorldRect(n))
                .insetBy(dx: -pad, dy: -pad)
            bodies.append(Body(id: n.id, rect: r, isLabel: false))
            let l = transform.toDisplay(CanvasScene.nodeLabelRect(n))
                .insetBy(dx: -labelPad, dy: -labelPad)
            bodies.append(Body(id: n.id, rect: l, isLabel: true))
        }
        stamp = [Int32](repeating: 0, count: bodies.count)
        for (i, b) in bodies.enumerated() {
            let x0 = Int((b.rect.minX / cell).rounded(.down)), x1 = Int((b.rect.maxX / cell).rounded(.down))
            let y0 = Int((b.rect.minY / cell).rounded(.down)), y1 = Int((b.rect.maxY / cell).rounded(.down))
            for gx in x0...x1 {
                for gy in y0...y1 {
                    buckets[Self.key(gx, gy), default: []].append(Int32(i))
                }
            }
        }
    }

    private static func key(_ x: Int, _ y: Int) -> Int64 {
        (Int64(Int32(truncatingIfNeeded: x)) << 32)
            | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
    }

    /// How many third-party bodies and labels `polyline` enters.  `a` and
    /// `b` are the link's own endpoints; neither their bodies nor their
    /// labels are ever counted.  With `stopAtFirstBody` the walk ends at
    /// the first body crossing — the question the router asks most often
    /// is "is this route body-clear at all?".
    func hits(_ polyline: [CGPoint], excluding a: UUID, _ b: UUID,
              stopAtFirstBody: Bool = false) -> Hits {
        guard !bodies.isEmpty, polyline.count > 1 else { return .none }
        var minX = polyline[0].x, maxX = polyline[0].x
        var minY = polyline[0].y, maxY = polyline[0].y
        for i in 1..<polyline.count {
            let p = polyline[i]
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return visit(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                     excluding: a, b, stopAtFirstBody: stopAtFirstBody, collect: nil) { rect in
            for i in 1..<polyline.count
            where CanvasMath.segmentIntersectsRect(polyline[i - 1], polyline[i], rect) {
                return true
            }
            return false
        }
    }

    /// The obstacles a link between `a` and `b` could possibly meet,
    /// given that the router will bow the stroke by at most `reach`
    /// display points either side of the chord.  Gathered once per link,
    /// so the bulge search that follows is a plain loop over a short
    /// array with no hashing, no dedupe and no allocation per candidate.
    func obstacles(near a: CGPoint, to b: CGPoint, reach: CGFloat,
                   excluding x: UUID, _ y: UUID) -> [Obstacle] {
        guard !bodies.isEmpty else { return [] }
        let minX = min(a.x, b.x) - reach, maxX = max(a.x, b.x) + reach
        let minY = min(a.y, b.y) - reach, maxY = max(a.y, b.y) + reach
        var found: [Obstacle] = []
        _ = visit(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                  excluding: x, y, stopAtFirstBody: false,
                  collect: { found.append($0) }) { rect in
            // A bow reaches at most `reach` from the chord, so anything
            // further away than that plus the obstacle's own half-diagonal
            // can never be crossed however hard the router bends.
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let halfDiagonal = CanvasMath.length(CGSize(width: rect.width, height: rect.height)) / 2
            return CanvasMath.pointToSegmentDistance(c, a, b) <= reach + halfDiagonal
        }
        return found
    }

    /// Walks every obstacle whose bucket overlaps the query box exactly
    /// once, tallying the ones `test` reports as crossed and handing each
    /// of those to `collect`.
    private func visit(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat,
                       excluding a: UUID, _ b: UUID, stopAtFirstBody: Bool,
                       collect: ((Obstacle) -> Void)?,
                       _ test: (CGRect) -> Bool) -> Hits {
        let gx0 = Int((minX / cell).rounded(.down)), gx1 = Int((maxX / cell).rounded(.down))
        let gy0 = Int((minY / cell).rounded(.down)), gy1 = Int((maxY / cell).rounded(.down))
        // A wildly off-screen link would sweep a huge bucket range; world
        // coordinates are clamped to +/-100k, but guard anyway.
        guard gx1 >= gx0, gy1 >= gy0, (gx1 - gx0) < 512, (gy1 - gy0) < 512 else { return .none }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        token &+= 1
        if token == 0 {
            // Wrapped after 2 billion queries: reset rather than mis-skip.
            for i in stamp.indices { stamp[i] = 0 }
            token = 1
        }
        var hits = Hits()
        for gx in gx0...gx1 {
            for gy in gy0...gy1 {
                guard let list = buckets[Self.key(gx, gy)] else { continue }
                for idx in list {
                    let i = Int(idx)
                    if stamp[i] == token { continue }
                    stamp[i] = token
                    let body = bodies[i]
                    if body.id == a || body.id == b { continue }
                    if !body.rect.intersects(box) { continue }
                    if test(body.rect) {
                        let obstacle = Obstacle(rect: body.rect, isLabel: body.isLabel)
                        hits.add(obstacle)
                        collect?(obstacle)
                        if stopAtFirstBody, !body.isLabel { return hits }
                    }
                }
            }
        }
        return hits
    }
}

// MARK: - Route plan

/// The detour every link takes, in world points, decided once per layout.
///
/// Routing is a property of the drawing, not of the viewport: moving the
/// camera cannot change which node an arrow has to step over.  So the
/// plan is computed in world space from the nodes and links alone and
/// reused verbatim across every pan and zoom — a scroll costs nothing but
/// the plain trigonometry of `LinkGeometry.between`, and only an actual
/// edit re-plans.
///
/// Nor does a node *drag* re-plan: `NetworkEditorModel.routePlan` hands
/// out the last plan for the whole of a drag and plans once more when
/// the pointer is released, and the canvas eases the links from the old
/// routes to the new ones (`interpolated(from:to:t:)`).  Re-planning per
/// frame made links snap between rungs of the bulge ladder as the
/// dragged node grazed a chord, and cost the full build sixty times a
/// second for nothing anyone could read.
struct LinkRoutePlan: Equatable {
    /// World-space bow per link id.  Absent means "straight" — the common
    /// case, so a tandem chain stores nothing at all.
    private var bulges: [UUID: CGFloat] = [:]

    static let empty = LinkRoutePlan()

    func bulge(for id: UUID) -> CGFloat { bulges[id] ?? 0 }

    /// Number of links this plan bows (diagnostics and the bench).
    var bowedCount: Int { bulges.count }

    /// The plan `t` of the way from `a` to `b` (0 = `a`, 1 = `b`), bow by
    /// bow, so a route can ease from where it was to where it must go
    /// instead of teleporting.  A link that is straight in one plan and
    /// bowed in the other eases from or to zero.
    static func interpolated(from a: LinkRoutePlan, to b: LinkRoutePlan, t: CGFloat) -> LinkRoutePlan {
        if t <= 0 { return a }
        if t >= 1 || a == b { return b }
        var out = LinkRoutePlan()
        out.bulges.reserveCapacity(max(a.bulges.count, b.bulges.count))
        for (id, target) in b.bulges {
            let from = a.bulges[id] ?? 0
            let v = from + (target - from) * t
            if v != 0 { out.bulges[id] = v }
        }
        for (id, from) in a.bulges where b.bulges[id] == nil {
            let v = from * (1 - t)
            if v != 0 { out.bulges[id] = v }
        }
        return out
    }

    static func build(nodes: [NetworkNode], links: [NetworkLink]) -> LinkRoutePlan {
        var plan = LinkRoutePlan()
        guard !links.isEmpty else { return plan }
        let world = CanvasTransform(scale: 1, pan: .zero, viewportSize: .zero)
        var index: [UUID: NetworkNode] = [:]
        index.reserveCapacity(nodes.count)
        var centroid = CGPoint.zero
        for n in nodes {
            index[n.id] = n
            centroid.x += n.position.x
            centroid.y += n.position.y
        }
        if !nodes.isEmpty {
            centroid.x /= CGFloat(nodes.count)
            centroid.y /= CGFloat(nodes.count)
        }
        // Bodies every link must steer around, and the drawing's centre of
        // mass — the tie-break that sends a detour outward, away from the
        // crowd, rather than deeper into it.
        let obstacles = CanvasObstacles(nodes: nodes, transform: world)
        let groups = CanvasScene.bundleGroups(links)

        for link in links {
            guard link.fromNodeID != link.toNodeID,
                  let from = index[link.fromNodeID], let to = index[link.toNodeID]
            else { continue }
            let key = CanvasScene.PairKey(from: link.fromNodeID, to: link.toNodeID)
            let siblings = groups[key] ?? [link]
            let myIndex = siblings.firstIndex(where: { $0.id == link.id }) ?? 0
            let count = CGFloat(siblings.count)
            let offsetWorld = (CGFloat(myIndex) - (count - 1) / 2) * CanvasScene.bundleSpacing
            let hasOpposite = groups[CanvasScene.PairKey(from: link.toNodeID,
                                                         to: link.fromNodeID)] != nil
            let bulge = solve(
                fromCentre: from.position, fromKind: from.kind, fromID: link.fromNodeID,
                toCentre: to.position, toKind: to.kind, toID: link.toNodeID,
                parallelOffset: offsetWorld,
                baseBulge: hasOpposite ? CanvasScene.pairBulge : 0,
                lockSide: hasOpposite,
                obstacles: obstacles,
                centroid: centroid)
            if bulge != 0 { plan.bulges[link.id] = bulge }
        }
        return plan
    }

    /// The world-space bow one link needs so that it does not pass
    /// through a node it is not attached to — nor, where that can be had,
    /// through the label under one.  Everything here is in world points
    /// at zoom 1; the scene multiplies the answer by the current scale.
    ///
    /// Three tiers, in order of preference:
    ///   (a) the gentlest route that clears every body *and* every label;
    ///   (b) failing that, the gentlest route that clears every body;
    ///   (c) failing that, the route that crosses the fewest bodies, and
    ///       among those the fewest labels — still strictly better than
    ///       the chord.
    /// A chord is kept whenever it is already clear — a tandem chain must
    /// stay dead straight — so the search below is paid for only by the
    /// links that actually need it.  The search walks `bulgeLadder` from
    /// the gentlest bow upward and returns at the first tier-(a) rung; a
    /// tier-(b) rung is remembered but the walk goes on, because a wider
    /// bow that also clears the label is the better drawing.  If no rung
    /// clears, it *solves* for the exact bow (see `solvedBulge`), first
    /// against everything and then against bodies alone.  Both stages try
    /// the side facing away from the drawing's centroid first, so a
    /// detour bows out of the diagram rather than into it.
    ///
    /// `lockSide` is set for a link that has an opposite-direction
    /// partner: those two must stay on opposite sides of the chord, so
    /// only the sign they were given is searched.
    ///
    /// Candidates are probed as bare quadratics through the (bundle-
    /// shifted) node centres rather than as fully built `LinkGeometry` —
    /// a probe is a conservative superset of the trimmed stroke, costs no
    /// allocation and no outline bisection, and only a candidate whose
    /// probe is body-clear is built for real.
    /// `validation/canvas_perf/run_routing_check.sh` verifies the *built*
    /// polyline of every link in every shipped example, so the shortcut
    /// cannot quietly stop being conservative.
    static func solve(
        fromCentre: CGPoint, fromKind: NodeKind, fromID: UUID,
        toCentre: CGPoint, toKind: NodeKind, toID: UUID,
        parallelOffset: CGFloat,
        baseBulge: CGFloat,
        lockSide: Bool,
        obstacles: CanvasObstacles,
        centroid: CGPoint
    ) -> CGFloat {
        func geometry(_ bulge: CGFloat) -> LinkGeometry {
            LinkGeometry.between(
                fromCentre: fromCentre, fromKind: fromKind,
                toCentre: toCentre, toKind: toKind,
                scale: 1,
                parallelOffset: parallelOffset,
                bulge: bulge)
        }
        if obstacles.isEmpty { return baseBulge }

        // Probe geometry: the bundle-shifted chord and its perpendicular.
        let u = CanvasMath.unit(from: fromCentre, to: toCentre)
        let perp = CGPoint(x: -u.y, y: u.x)
        let a = CGPoint(x: fromCentre.x + perp.x * parallelOffset,
                        y: fromCentre.y + perp.y * parallelOffset)
        let b = CGPoint(x: toCentre.x + perp.x * parallelOffset,
                        y: toCentre.y + perp.y * parallelOffset)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

        // Everything this link could possibly meet, gathered once.
        let reach = CanvasScene.bulgeLadder.last ?? 0
        let nearby = obstacles.obstacles(near: a, to: b, reach: reach,
                                         excluding: fromID, toID)
        if nearby.isEmpty { return baseBulge }

        /// Tally of `nearby` obstacles a bow of `bulge` enters, walked as
        /// a bare quadratic so no `LinkGeometry` has to be built to ask.
        var probe = [CGPoint](repeating: .zero, count: CanvasScene.probeSegments + 1)
        func probeHits(_ bulge: CGFloat) -> CanvasObstacles.Hits {
            let control = CGPoint(x: mid.x + perp.x * bulge, y: mid.y + perp.y * bulge)
            for i in 0...CanvasScene.probeSegments {
                probe[i] = CanvasMath.quadPoint(a, control, b,
                                                t: CGFloat(i) / CGFloat(CanvasScene.probeSegments))
            }
            // A quadratic lies inside the hull of its three points, so
            // one rectangle test rejects most of `nearby` before any
            // segment arithmetic happens.
            let hull = CGRect(x: min(a.x, min(control.x, b.x)),
                              y: min(a.y, min(control.y, b.y)),
                              width: abs(max(a.x, max(control.x, b.x)) - min(a.x, min(control.x, b.x))),
                              height: abs(max(a.y, max(control.y, b.y)) - min(a.y, min(control.y, b.y))))
            var hits = CanvasObstacles.Hits()
            for obstacle in nearby {
                guard obstacle.rect.intersects(hull) else { continue }
                for i in 1...CanvasScene.probeSegments
                where CanvasMath.segmentIntersectsRect(probe[i - 1], probe[i], obstacle.rect) {
                    hits.add(obstacle)
                    break
                }
            }
            return hits
        }

        /// The tally of the stroke that will really be drawn — the probe
        /// is a superset of the trimmed curve almost everywhere, but the
        /// trimmed curve leaves the outline along the tangent to the
        /// control point and can sit a hair outside the probe near the
        /// ends, so acceptance is always decided on the built polyline.
        func builtHits(_ bulge: CGFloat) -> CanvasObstacles.Hits {
            obstacles.hits(geometry(bulge).polyline, excluding: fromID, toID)
        }

        // Tier (b): the gentlest candidate whose built stroke clears every
        // body.  Tier (c): the least-bad candidate by probe tally.
        var bodyClear: CGFloat?
        var best = baseBulge
        var bestHits = probeHits(baseBulge)

        /// Ranks `candidate`; true means it is tier (a) and the search
        /// can stop.
        func consider(_ candidate: CGFloat) -> Bool {
            let p = probeHits(candidate)
            if p < bestHits { bestHits = p; best = candidate }
            guard p.bodies == 0 else { return false }
            let built = builtHits(candidate)
            if built.isClear { return true }
            if built.bodies == 0, bodyClear == nil { bodyClear = candidate }
            return false
        }

        if consider(baseBulge) { return baseBulge }

        // Which side of the chord points away from the rest of the
        // drawing?  Try that one first.
        let outward = perp.x * (mid.x - centroid.x) + perp.y * (mid.y - centroid.y)
        let firstSign: CGFloat = outward >= 0 ? 1 : -1
        let signs: [CGFloat] = lockSide
            ? [baseBulge >= 0 ? 1 : -1]
            : [firstSign, -firstSign]

        // Smallest bow first.  A link should bend only as far as it must:
        // a 24 pt nudge that clears is a better drawing than a 240 pt arc
        // that also clears, so the ladder is walked in ascending order and
        // the first fully clearing rung wins.
        let floorMagnitude = abs(baseBulge) + 0.001
        for magnitude in CanvasScene.bulgeLadder {
            guard magnitude > floorMagnitude else { continue }
            for sign in signs where consider(sign * magnitude) {
                return sign * magnitude
            }
        }

        // No rung cleared everything.  Solve for the bow instead of
        // guessing: a quadratic of control offset B displaces its own
        // curve by 2·t·(1−t)·B at chord parameter t, so for each obstacle
        // in the way the smallest B that steps the curve past its far
        // edge is
        //     B = (offset needed at t) / (2·t·(1−t)),
        // and the bow that clears them all is the largest of those.  An
        // obstacle very close to an endpoint is skipped: the curve is
        // pinned to the node it leaves, so clearing it symmetrically
        // would need an absurd arc, and a slightly-crossed short link
        // reads better than a loop across the whole diagram.  Solved
        // first against bodies and labels together, then against bodies
        // alone.
        let chordLength = max(CanvasMath.distance(a, b), 0.001)
        func solvedBulge(sign: CGFloat, includingLabels: Bool) -> CGFloat? {
            var need: CGFloat = 0
            for obstacle in nearby where includingLabels || !obstacle.isLabel {
                let rect = obstacle.rect
                let c = CGPoint(x: rect.midX, y: rect.midY)
                let d = CGPoint(x: c.x - a.x, y: c.y - a.y)
                let t = (d.x * u.x + d.y * u.y) / chordLength
                guard t > CanvasScene.solveWindow, t < 1 - CanvasScene.solveWindow else { continue }
                let along = d.x * perp.x + d.y * perp.y
                let half = (abs(perp.x) * rect.width + abs(perp.y) * rect.height) / 2
                let target = sign * (along + sign * (half + CanvasScene.clearanceMargin))
                guard target > 0 else { continue }   // already clear on this side
                need = max(need, target / (2 * t * (1 - t)))
            }
            guard need > 0, need <= CanvasScene.maxBulge else { return nil }
            return sign * max(need, abs(baseBulge))
        }

        for includingLabels in [true, false] {
            for sign in signs {
                guard let candidate = solvedBulge(sign: sign, includingLabels: includingLabels)
                else { continue }
                if consider(candidate) { return candidate }
            }
        }

        return bodyClear ?? best
    }

}

// MARK: - Scene

/// One frame's worth of resolved canvas geometry: an id → node index, the
/// display centre of every node, and the routed geometry of every visible
/// link.  Built once per body evaluation and shared by the link renderer,
/// the hover tracker and every gesture's hit test — so O(L) work happens
/// once per frame instead of O(L²) per mouse event.
struct CanvasScene: Equatable {
    struct LinkItem: Identifiable, Equatable {
        let id: UUID
        let link: NetworkLink
        let geometry: LinkGeometry
    }

    let transform: CanvasTransform
    let nodes: [NetworkNode]
    let nodeIndex: [UUID: NetworkNode]
    let displayCentres: [UUID: CGPoint]
    /// Visible links in draw order (lower classes first, so the
    /// highest class is on top when bundles overlap).
    let links: [LinkItem]

    /// Directed node-pair key used to bundle sibling links.
    struct PairKey: Hashable {
        let from: UUID
        let to: UUID
    }

    /// Perpendicular spacing between bundled sibling links (world pt).
    static let bundleSpacing: CGFloat = 8
    /// Sideways bow of an opposite-direction pair (world pt).
    static let pairBulge: CGFloat = 24
    /// Bow magnitudes (world pt) the router tries, in order, when the
    /// straight route crosses somebody else's body.  It stops at the
    /// first value that clears everything, so a link only bends as far
    /// as it must.
    ///
    /// A quadratic bow displaces its own midpoint by half the control
    /// offset, so a rung of `2h` is what it takes to step the apex clear
    /// of a body of half-height `h`: 14 pt for a link that merely grazes
    /// a corner, 96 pt to step over one station, 240 pt for a chord that
    /// runs down a whole column of them.  `LinkRoutePlan.solve` walks
    /// these in ascending order and stops at the first that clears, so a
    /// link never bends further than it must.
    static let bulgeLadder: [CGFloat] = [14, pairBulge, 48, 96, 160, 240]
    /// Flattening of a candidate bow while it is being probed.  Eight
    /// chords is finer than a node is wide at every zoom the canvas
    /// allows, so a body cannot slip between two of them.
    static let probeSegments = 8
    /// Clear air (world pt) the solved bow leaves between the stroke and
    /// the body it steps over — enough that the 2 pt stroke, its halo and
    /// the node's own ring never touch.
    static let clearanceMargin: CGFloat = 10
    /// Hard ceiling on a detour (world pt).  Beyond this the bow would be
    /// a bigger distraction than the crossing it avoids, so the router
    /// stops and keeps the least-bad route.
    static let maxBulge: CGFloat = 260
    /// Fraction of the chord at each end within which the closed-form
    /// solve declines to act.  The curve is pinned to the outline it
    /// leaves, so a body sitting right beside an endpoint can only be
    /// cleared by an arc out of all proportion to the link.
    static let solveWindow: CGFloat = 0.2

    /// - routePlan: the world-space detours computed by
    ///   `LinkRoutePlan.build`.  Routing depends only on where the nodes
    ///   are, never on the viewport, so a pan or a zoom reuses the plan
    ///   the last layout produced and pays nothing for it.  Passing `nil`
    ///   plans on the spot, which is what the offline checkers do.
    init(nodes: [NetworkNode], links: [NetworkLink], transform: CanvasTransform,
         classFilter: Int?, routePlan: LinkRoutePlan? = nil) {
        self.transform = transform
        self.nodes = nodes
        var index: [UUID: NetworkNode] = [:]
        index.reserveCapacity(nodes.count)
        var centres: [UUID: CGPoint] = [:]
        centres.reserveCapacity(nodes.count)
        for n in nodes {
            index[n.id] = n
            centres[n.id] = transform.toDisplay(n.position)
        }
        self.nodeIndex = index
        self.displayCentres = centres

        let groups = Self.bundleGroups(links)
        let plan = routePlan ?? LinkRoutePlan.build(nodes: nodes, links: links)
        let scale = transform.scale
        var items: [LinkItem] = []
        items.reserveCapacity(links.count)
        let ordered = links.sorted { $0.customerClass < $1.customerClass }
        for link in ordered {
            if let filter = classFilter, link.customerClass != filter { continue }
            guard let from = index[link.fromNodeID], let to = index[link.toNodeID],
                  let fromC = centres[link.fromNodeID], let toC = centres[link.toNodeID]
            else { continue }
            let key = PairKey(from: link.fromNodeID, to: link.toNodeID)
            let siblings = groups[key] ?? [link]
            let myIndex = siblings.firstIndex(where: { $0.id == link.id }) ?? 0
            let count = CGFloat(siblings.count)
            let offsetWorld = (CGFloat(myIndex) - (count - 1) / 2) * Self.bundleSpacing

            let geometry: LinkGeometry
            if link.fromNodeID == link.toNodeID {
                geometry = LinkGeometry.selfLoop(
                    centre: fromC, kind: from.kind, scale: scale,
                    extraRadius: CGFloat(myIndex) * Self.bundleSpacing * scale)
            } else {
                geometry = LinkGeometry.between(
                    fromCentre: fromC, fromKind: from.kind,
                    toCentre: toC, toKind: to.kind,
                    scale: scale,
                    parallelOffset: offsetWorld * scale,
                    bulge: plan.bulge(for: link.id) * scale)
            }
            items.append(LinkItem(id: link.id, link: link, geometry: geometry))
        }
        self.links = items
    }

    /// Links grouped by directed node pair — all links, not just visible
    /// ones, so the bundle layout does not jump when a class filter is
    /// toggled.  Shared by the scene and the route planner so both see
    /// the same sibling order.
    static func bundleGroups(_ links: [NetworkLink]) -> [PairKey: [NetworkLink]] {
        var groups: [PairKey: [NetworkLink]] = [:]
        for l in links {
            groups[PairKey(from: l.fromNodeID, to: l.toNodeID), default: []].append(l)
        }
        for key in groups.keys {
            groups[key]?.sort { $0.customerClass < $1.customerClass }
        }
        return groups
    }

    // MARK: Hit testing (display space)

    /// Topmost node under `point`; later nodes in the array draw on top.
    func hitNode(at point: CGPoint) -> NetworkNode? {
        let scale = transform.scale
        for node in nodes.reversed() {
            guard let c = displayCentres[node.id] else { continue }
            let local = CGPoint(x: (point.x - c.x) / scale, y: (point.y - c.y) / scale)
            if NodeOutline.contains(kind: node.kind, localPoint: local, slop: 3 / scale) {
                return node
            }
        }
        return nil
    }

    /// Nearest visible link within the hit slab, topmost first on ties.
    func hitLink(at point: CGPoint, tolerance: CGFloat = LinkGeometry.hitTolerance) -> NetworkLink? {
        var best: (NetworkLink, CGFloat)? = nil
        for item in links.reversed() {
            let d = item.geometry.distance(to: point)
            if d <= tolerance, best == nil || d < best!.1 {
                best = (item.link, d)
            }
        }
        return best?.0
    }

    /// World-space rectangle actually occupied by a node's body (centre
    /// ± half its outline).  The rubber-band selects by intersection with
    /// this rect — the OmniGraffle / Figma rule — so a node whose body the
    /// band touches is selected even when its centre is outside.  Preview
    /// highlight, live count and commit all read this one helper, so what
    /// lights up is exactly what gets selected.
    static func nodeWorldRect(_ node: NetworkNode) -> CGRect {
        let s = NodeOutline.size(for: node.kind)
        return CGRect(x: node.position.x - s.width / 2,
                      y: node.position.y - s.height / 2,
                      width: s.width, height: s.height)
    }

    /// World-space rectangle of the label block drawn under a node's
    /// body (see `NodeOutline.labelBlockWidth`).  The router keeps links
    /// out of it where it can, and the export leaves room for it.
    static func nodeLabelRect(_ node: NetworkNode) -> CGRect {
        let body = nodeWorldRect(node)
        let w = NodeOutline.labelBlockWidth
        return CGRect(x: node.position.x - w / 2,
                      y: body.maxY + NodeOutline.labelBlockGap,
                      width: w,
                      height: NodeOutline.labelBlockHeight(for: node.kind))
    }

    /// True when `rect` (world space) touches the node's body.  A
    /// zero-area band still selects what it crosses.
    static func marqueeSelects(_ node: NetworkNode, rect: CGRect) -> Bool {
        nodeWorldRect(node).intersects(rect.insetBy(dx: -0.01, dy: -0.01))
    }

    /// World-space bounding rectangle of node centres (nil when empty).
    static func bounds(of nodes: [NetworkNode]) -> CGRect? {
        guard let first = nodes.first else { return nil }
        var minX = first.position.x, maxX = first.position.x
        var minY = first.position.y, maxY = first.position.y
        for n in nodes.dropFirst() {
            minX = min(minX, n.position.x); maxX = max(maxX, n.position.x)
            minY = min(minY, n.position.y); maxY = max(maxY, n.position.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Smart guides

/// Alignment feedback while a node is dragged: the 1-pt guides every
/// diagramming tool (OmniGraffle, Keynote, Figma) shows when the dragged
/// shape lines up with a neighbour, and the small pull that makes the
/// alignment stick.
///
/// Two kinds of guide per axis:
///   * **Edge / centre alignment** — the leading edge, the centre or the
///     trailing edge of the dragged node coincides with a neighbour's.
///     The neighbour it locked onto is returned (`xPartner` / `yPartner`)
///     so the layer can draw the guide *between* the two, not across the
///     whole viewport — with three candidates in a column, the user sees
///     which one it took.
///   * **Equal spacing** — the gap to the nearest neighbour on one side
///     matches the gap on the other side (or the gap between the two
///     nearest neighbours on the same side, which is the case when a
///     chain is being extended).  The dragged node is pulled to equalise
///     the gaps and the two gaps are returned so the layer can draw the
///     pair of spacing bars.
/// On each axis the alignment guide is tried first and spacing only when
/// no edge matched, so a node never receives two competing pulls.
enum SmartGuides {
    /// The two gaps an equal-spacing guide equalised, as world rects
    /// spanning each gap along the guide's axis (zero thickness).
    struct SpacingGuide: Equatable {
        var first: CGRect
        var second: CGRect
    }

    /// World-space guide lines to draw, and the correction to add to the
    /// drag delta so the node actually lands on them.
    struct Match: Equatable {
        var adjustment = CGSize.zero
        /// World x of the vertical guide (nil = no edge match on this axis).
        var x: CGFloat?
        /// World y of the horizontal guide.
        var y: CGFloat?
        /// World rect of the dragged node *after* the adjustment — the
        /// end the guides are drawn from.
        var anchor: CGRect?
        /// The neighbour the vertical / horizontal guide locked onto.
        var xPartner: CGRect?
        var yPartner: CGRect?
        /// Equal-spacing guides, when an axis matched by spacing rather
        /// than by edge.
        var xSpacing: SpacingGuide?
        var ySpacing: SpacingGuide?

        var isEmpty: Bool { x == nil && y == nil && xSpacing == nil && ySpacing == nil }
        static let none = Match()

        /// Forget the horizontal match — the grid won that axis.
        mutating func dropX() {
            x = nil; xPartner = nil; xSpacing = nil; adjustment.width = 0
        }
        /// Forget the vertical match.
        mutating func dropY() {
            y = nil; yPartner = nil; ySpacing = nil; adjustment.height = 0
        }
    }

    /// Display-space distance at which a drag snaps to a neighbour.
    static let tolerance: CGFloat = 4

    /// The axis a spacing search runs along.
    enum SpacingAxis { case horizontal, vertical }

    private static func guides(_ r: CGRect) -> (x: [CGFloat], y: [CGFloat]) {
        ([r.minX, r.midX, r.maxX], [r.minY, r.midY, r.maxY])
    }

    /// Best alignment of `anchor` (the dragged node's candidate world
    /// rect) against `others`, within `tolerance` world points.
    static func match(anchor: CGRect, others: [CGRect], tolerance: CGFloat) -> Match {
        guard tolerance > 0, !others.isEmpty else { return .none }
        let a = guides(anchor)
        var best = Match()
        var bestDX = tolerance
        var bestDY = tolerance
        for other in others {
            let o = guides(other)
            for av in a.x {
                for ov in o.x where abs(ov - av) < bestDX {
                    bestDX = abs(ov - av)
                    best.adjustment.width = ov - av
                    best.x = ov
                    best.xPartner = other
                }
            }
            for av in a.y {
                for ov in o.y where abs(ov - av) < bestDY {
                    bestDY = abs(ov - av)
                    best.adjustment.height = ov - av
                    best.y = ov
                    best.yPartner = other
                }
            }
        }
        if best.x == nil, let s = spacing(anchor: anchor, others: others,
                                          tolerance: tolerance, axis: .horizontal) {
            best.adjustment.width = s.adjustment
            best.xSpacing = s.guide
        }
        if best.y == nil, let s = spacing(anchor: anchor, others: others,
                                          tolerance: tolerance, axis: .vertical) {
            best.adjustment.height = s.adjustment
            best.ySpacing = s.guide
        }
        if !best.isEmpty {
            best.anchor = anchor.offsetBy(dx: best.adjustment.width, dy: best.adjustment.height)
        }
        return best
    }

    /// Equal-spacing match on one axis.  Neighbours are the rects whose
    /// extent on the *other* axis overlaps the dragged node's row (or
    /// column) — a node two rows up is not a spacing partner.  The two
    /// nearest on each side are considered: the dragged node between a
    /// left and a right neighbour, or beyond two neighbours on one side.
    private static func spacing(anchor: CGRect, others: [CGRect],
                                tolerance: CGFloat, axis: SpacingAxis)
        -> (adjustment: CGFloat, guide: SpacingGuide)? {
        // Project onto the axis: lo / hi are the near and far edges along
        // it; `cross` is the position on the other axis used for the row
        // test and for placing the bars.
        func lo(_ r: CGRect) -> CGFloat { axis == .horizontal ? r.minX : r.minY }
        func hi(_ r: CGRect) -> CGFloat { axis == .horizontal ? r.maxX : r.maxY }
        func crossMid(_ r: CGRect) -> CGFloat { axis == .horizontal ? r.midY : r.midX }
        func crossExtent(_ r: CGRect) -> CGFloat { axis == .horizontal ? r.height : r.width }

        let band = crossExtent(anchor)
        let row = others.filter { abs(crossMid($0) - crossMid(anchor)) <= band }
        guard row.count >= 2 else { return nil }
        let before = row.filter { hi($0) <= lo(anchor) + tolerance }
            .sorted { hi($0) > hi($1) }
        let after = row.filter { lo($0) >= hi(anchor) - tolerance }
            .sorted { lo($0) < lo($1) }

        /// A gap rect along the axis at the dragged node's cross position.
        func gapRect(from: CGFloat, to: CGFloat) -> CGRect {
            let c = crossMid(anchor)
            return axis == .horizontal
                ? CGRect(x: from, y: c, width: to - from, height: 0)
                : CGRect(x: c, y: from, width: 0, height: to - from)
        }

        var bestAdjust = tolerance
        var result: (CGFloat, SpacingGuide)?

        // Between a neighbour on each side: equalise the two gaps.
        if let l = before.first, let r = after.first {
            let gapL = lo(anchor) - hi(l)
            let gapR = lo(r) - hi(anchor)
            let adjust = (gapR - gapL) / 2
            if gapL >= 0, gapR >= 0, abs(adjust) < bestAdjust {
                bestAdjust = abs(adjust)
                result = (adjust, SpacingGuide(
                    first: gapRect(from: hi(l), to: lo(anchor) + adjust),
                    second: gapRect(from: hi(anchor) + adjust, to: lo(r))))
            }
        }
        // Beyond two neighbours on the near side: repeat their gap.
        if before.count >= 2 {
            let l1 = before[0], l2 = before[1]
            let gapPrev = lo(l1) - hi(l2)
            let gapNew = lo(anchor) - hi(l1)
            let adjust = gapPrev - gapNew
            if gapPrev > 0, gapNew >= 0, abs(adjust) < bestAdjust {
                bestAdjust = abs(adjust)
                result = (adjust, SpacingGuide(
                    first: gapRect(from: hi(l2), to: lo(l1)),
                    second: gapRect(from: hi(l1), to: lo(anchor) + adjust)))
            }
        }
        if after.count >= 2 {
            let r1 = after[0], r2 = after[1]
            let gapPrev = lo(r2) - hi(r1)
            let gapNew = lo(r1) - hi(anchor)
            let adjust = gapNew - gapPrev
            if gapPrev > 0, gapNew >= 0, abs(adjust) < bestAdjust {
                bestAdjust = abs(adjust)
                result = (adjust, SpacingGuide(
                    first: gapRect(from: hi(anchor) + adjust, to: lo(r1)),
                    second: gapRect(from: hi(r1), to: lo(r2))))
            }
        }
        return result.map { (adjustment: $0.0, guide: $0.1) }
    }
}

// MARK: - Math helpers

enum CanvasMath {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    static func length(_ s: CGSize) -> CGFloat {
        sqrt(s.width * s.width + s.height * s.height)
    }

    static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        return CGPoint(x: dx / len, y: dy / len)
    }

    /// True when the closed segment `p0`-`p1` touches `r` (Liang–Barsky
    /// clip: no allocation, no trig, four comparisons per edge).  Used by
    /// the link router to ask whether a candidate route enters a node
    /// body it is meant to pass by.
    static func segmentIntersectsRect(_ p0: CGPoint, _ p1: CGPoint, _ r: CGRect) -> Bool {
        var t0: CGFloat = 0
        var t1: CGFloat = 1
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        for edge in 0..<4 {
            let p: CGFloat
            let q: CGFloat
            switch edge {
            case 0:  p = -dx; q = p0.x - r.minX
            case 1:  p =  dx; q = r.maxX - p0.x
            case 2:  p = -dy; q = p0.y - r.minY
            default: p =  dy; q = r.maxY - p0.y
            }
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 {
                    if t > t1 { return false }
                    if t > t0 { t0 = t }
                } else {
                    if t < t0 { return false }
                    if t < t1 { t1 = t }
                }
            }
        }
        return true
    }

    static func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x,
            y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y
        )
    }

    static func cubicPoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt
        let b = 3 * mt * mt * t
        let c = 3 * mt * t * t
        let d = t * t * t
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p1.y
        )
    }

    static func flattenQuad(from p0: CGPoint, control c: CGPoint, to p1: CGPoint, segments: Int) -> [CGPoint] {
        (0...segments).map { i in quadPoint(p0, c, p1, t: CGFloat(i) / CGFloat(segments)) }
    }

    static func flattenCubic(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p1: CGPoint, segments: Int) -> [CGPoint] {
        (0...segments).map { i in cubicPoint(p0, c1, c2, p1, t: CGFloat(i) / CGFloat(segments)) }
    }

    /// Loose sanity clamp on world coordinates so Fit / persistence stay
    /// numerically well-behaved; the canvas is otherwise unbounded.
    static func clampWorld(_ p: CGPoint) -> CGPoint {
        let bound: CGFloat = 100_000
        return CGPoint(x: min(max(p.x, -bound), bound), y: min(max(p.y, -bound), bound))
    }
}

// MARK: - Frame profiler (QNET_CANVAS_PROFILE=1)

/// Prints per-layer timings of the canvas when the environment variable
/// `QNET_CANVAS_PROFILE` is set, so a reviewer can verify the 60 fps
/// drag / pan target on a large network without instrumenting the app.
/// Four layers are reported, each on its own line every 60 frames:
///
///   * `frame` — the whole `CanvasContentView` body: scene lookup, layer
///     construction and the node `ForEach`.  This is the end-to-end
///     number; the gap between frames on the same line is the real frame
///     rate the user is getting.
///   * `nodes` — just the node `ForEach`: 1 `NetworkNodeView` per node,
///     each with its selection ring, label block and ρ badge.
///   * `links` — the link `Canvas` draw.
///   * `grid` — the grid `Canvas` draw.
///
/// Synthetic budget, measured on Apple silicon with `swiftc -O`, a
/// 1600 × 1000 pt viewport and 200 nodes / 400 links — the shipping
/// `LinkRoutePlan`, `CanvasScene`, `GridPath` and node-layer inputs
/// driven from `validation/canvas_perf`, so the numbers are the layers'
/// own work, not SwiftUI's compositing:
///
/// ```
///   route plan (once per layout change)              4.2 ms
///   drag re-plan, per frame, if it were live         4.1 ms   (it is not — see below)
///   plan interpolation, per animation frame          0.03 ms
///
///   zoom     scene build     grid path    node inputs*  hit test
///    50 %      0.28 ms        0.002 ms      0.007 ms     0.017 ms
///    86 %      0.28 ms        0.055 ms      0.007 ms     0.017 ms   ← densest grid
///   100 %      0.29 ms        0.040 ms      0.007 ms     0.015 ms
///   200 %      0.28 ms        0.011 ms      0.007 ms     0.017 ms
///   400 %      0.29 ms        0.003 ms      0.006 ms     0.016 ms
///
///   * "node inputs" is the per-node centre lookup, marquee test and
///     equality check — NOT the 200 `NetworkNodeView` bodies, which are
///     SwiftUI views and can only be timed in the app (below).
/// ```
///
/// The plan is deliberately outside the per-frame table: routing depends
/// on where the nodes are, not on the camera, so a pan, a zoom, a hover
/// or a selection change reuses it and pays only the "scene build"
/// column.  Only an edit re-plans, and that 4.2 ms is the adversarial
/// case — a dense grid where four chords in five cross somebody or
/// somebody's label (it was 2.2 ms before labels became obstacles and
/// the ladder walk stopped settling for a body-clear rung).  The largest
/// network Qnet ships (12 nodes / 54 links) plans in 0.14 ms.
///
/// A node *drag* does not re-plan at all: `NetworkEditorModel.routePlan`
/// is frozen while `isDraggingNode` is set and rebuilt once on release,
/// with the link layer easing from the old routes to the new over
/// `DS.Motion.quick` (`AnimatedLinkLayer`).  The "drag re-plan" row is
/// what a live re-plan would cost per frame — kept in the table so the
/// freeze stays a measured decision — and "plan interpolation" is what
/// each of the ~9 animation frames pays instead.
///
/// A worst-case camera frame therefore costs ≈ 0.35 ms of layer work,
/// about 2 % of a 60 fps frame; a worst-case *edit* frame on a 200-node
/// network costs ≈ 4.5 ms, about 27 %, once.
///
/// **End-to-end.**  The table above is deliberately only the geometry.
/// For the number that decides whether a drag holds 60 fps — SwiftUI's
/// own diffing and rasterisation included — build a large network and
/// read the `frame` line:
///
/// ```
///   .build/debug/Qnet --gen-random 200 2 0.7 gp 1 /tmp/big
///   QNET_CANVAS_PROFILE=1 swift run Qnet /tmp/big/*.bnet
///   # then, in the app: drag a node, Space-pan, ⌥-wheel zoom,
///   # at 50 %, 100 % and 200 % zoom
/// ```
///
/// The `frame` line's "ms between frames" is the honest measurement:
/// under 16.7 ms is 60 fps.  Those numbers are per-machine and per-window
/// and are not pasted here — one Mac's figure recorded in a comment reads
/// as a guarantee it is not — but the recipe takes a minute and prints
/// the current machine's truth.  Two things the recipe no longer pays
/// for during a drag: the route plan (frozen, above) and the per-link
/// accessibility elements, which `CanvasContentView` drops while a node
/// drag or a pan is in flight and restores on release.
///
/// Reproduce the synthetic table with
/// `validation/canvas_perf/run_canvas_bench.sh`; it is the acceptance
/// floor for this area.  `validation/canvas_perf/run_routing_check.sh`
/// is the matching correctness gate: it fails if any link in any shipped
/// example is drawn through a node it is not attached to.
@MainActor
enum CanvasProfiler {
    enum Layer: String {
        case grid, links, nodes, frame
    }

    static let enabled: Bool = ProcessInfo.processInfo.environment["QNET_CANVAS_PROFILE"] != nil

    private struct Accumulator {
        var lastFrame: CFAbsoluteTime = 0
        var frameCount = 0
        var draw: Double = 0
        var gap: Double = 0
    }
    private static var accumulators: [Layer: Accumulator] = [:]

    /// Call once per layer draw with the time the draw took.
    static func record(layer: Layer, drawSeconds: Double, linkCount: Int, nodeCount: Int) {
        guard enabled else { return }
        var acc = accumulators[layer] ?? Accumulator()
        let now = CFAbsoluteTimeGetCurrent()
        if acc.lastFrame > 0 { acc.gap += now - acc.lastFrame }
        acc.lastFrame = now
        acc.draw += drawSeconds
        acc.frameCount += 1
        if acc.frameCount >= 60 {
            let avgDraw = acc.draw / Double(acc.frameCount) * 1000
            let avgGap = acc.gap / Double(max(acc.frameCount - 1, 1)) * 1000
            let fps = avgGap > 0 ? 1000 / avgGap : 0
            switch layer {
            case .links, .nodes, .frame:
                let tag = layer.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
                print(String(format: "[canvas] \(tag) %d nodes / %d links — %.2f ms/frame, %.1f ms between frames (~%.0f fps)",
                             nodeCount, linkCount, avgDraw, avgGap, fps))
            case .grid:
                print(String(format: "[canvas] grid  %.2f ms/frame, %.1f ms between frames (~%.0f fps)",
                             avgDraw, avgGap, fps))
            }
            acc = Accumulator(lastFrame: now)
        }
        accumulators[layer] = acc
    }

    /// Node-layer cost accumulates across one frame's `ForEach` bodies
    /// and is flushed at the start of the next frame, so the reported
    /// number is the whole node layer rather than one node.
    private static var nodeAccumulator: Double = 0

    static func addNodeCost(_ seconds: Double) {
        guard enabled else { return }
        nodeAccumulator += seconds
    }

    static func flushNodeCost(linkCount: Int, nodeCount: Int) {
        guard enabled, nodeAccumulator > 0 else { return }
        let total = nodeAccumulator
        nodeAccumulator = 0
        record(layer: .nodes, drawSeconds: total, linkCount: linkCount, nodeCount: nodeCount)
    }

    /// Times `body` and reports it as `layer`.  Returns whatever the
    /// body returns, so it can wrap an expression in place.
    @inline(__always)
    static func measure<T>(layer: Layer, linkCount: Int, nodeCount: Int, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let value = body()
        record(layer: layer, drawSeconds: CFAbsoluteTimeGetCurrent() - t0,
               linkCount: linkCount, nodeCount: nodeCount)
        return value
    }
}
