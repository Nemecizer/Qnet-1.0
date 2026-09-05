import SwiftUI
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// Canvas layers
// ─────────────────────────────────────────────────────────────────────────────
//
// The canvas is composed of a small number of layers, bottom to top:
//
//   GridCanvas        world-space dot grid (one `Canvas`)
//   LinkLayerCanvas   every link, arrowhead and probability chip (one `Canvas`)
//   LinkPreviewCanvas the dashed elastic line while a link is being drawn
//   NetworkNodeView   one SwiftUI view per node (context menu, accessibility)
//   marquee           a single Rectangle while a rubber-band is active
//
// The two `Canvas` layers are `Equatable` and wrapped with `.equatable()`
// so SwiftUI skips them entirely on frames where their inputs did not
// change — during a node drag the grid never redraws.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Grid

/// World-space dot grid: minor dots every `gridSpacing` world points,
/// a hairline every four cells.  Both go through the canvas transform,
/// so a snapped node always sits on a dot regardless of zoom or pan.
struct GridCanvas: View, Equatable {
    let transform: CanvasTransform

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let t0 = CanvasProfiler.enabled ? CFAbsoluteTimeGetCurrent() : 0
            // One builder, shared with validation/canvas_perf, so the
            // bench can never drift from the grid that ships.
            let grid = GridPath.build(transform: transform, size: size,
                                      gridSpacing: NetworkEditorModel.gridSpacing)
            if let dots = grid.minorDots {
                context.fill(dots, with: .color(DS.Color.dimmed(DS.Color.gridDot, grid.minorAlpha)))
            }
            if let lines = grid.majorLines {
                context.stroke(lines,
                               with: .color(DS.Color.dimmed(DS.Color.gridLine, grid.majorAlpha)),
                               lineWidth: DS.Stroke.hairline)
            }
            if CanvasProfiler.enabled {
                CanvasProfiler.record(layer: .grid,
                                      drawSeconds: CFAbsoluteTimeGetCurrent() - t0,
                                      linkCount: 0, nodeCount: 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Alignment guides

/// The 1-pt accent guides shown while a dragged node lines up with a
/// neighbour.  An edge / centre guide runs *between* the dragged node
/// and the neighbour it locked onto, overshooting each by a few points
/// and ending in a short tick, so with three candidates in a column the
/// user can see which one it took.  An equal-spacing guide draws the two
/// gaps it equalised as bars with end ticks, the way Keynote and Figma
/// do.  Live only during a drag.
///
/// Reduce Motion: the guides still appear — the pull they explain still
/// happens — but they arrive and leave instantly: their fade is
/// `DS.Motion.quick`, which is nil under the switch, so nothing eases
/// under the pointer.
struct AlignmentGuideLayer: View, Equatable {
    let guides: SmartGuides.Match
    let transform: CanvasTransform

    /// Display points a guide runs past the two rects it joins.
    private static let overshoot: CGFloat = 8
    /// Half-length of the tick at each end of a guide or spacing bar.
    private static let tick: CGFloat = 4

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            guard let anchor = guides.anchor else { return }
            var path = Path()
            let a = transform.toDisplay(anchor)

            if let x = guides.x {
                let px = transform.toDisplay(CGPoint(x: x, y: 0)).x.rounded() + 0.5
                var y0 = a.minY, y1 = a.maxY
                if let partner = guides.xPartner {
                    let p = transform.toDisplay(partner)
                    y0 = min(y0, p.minY); y1 = max(y1, p.maxY)
                }
                y0 = (y0 - Self.overshoot).rounded() + 0.5
                y1 = (y1 + Self.overshoot).rounded() + 0.5
                path.move(to: CGPoint(x: px, y: y0))
                path.addLine(to: CGPoint(x: px, y: y1))
                for y in [y0, y1] {
                    path.move(to: CGPoint(x: px - Self.tick, y: y))
                    path.addLine(to: CGPoint(x: px + Self.tick, y: y))
                }
            }
            if let y = guides.y {
                let py = transform.toDisplay(CGPoint(x: 0, y: y)).y.rounded() + 0.5
                var x0 = a.minX, x1 = a.maxX
                if let partner = guides.yPartner {
                    let p = transform.toDisplay(partner)
                    x0 = min(x0, p.minX); x1 = max(x1, p.maxX)
                }
                x0 = (x0 - Self.overshoot).rounded() + 0.5
                x1 = (x1 + Self.overshoot).rounded() + 0.5
                path.move(to: CGPoint(x: x0, y: py))
                path.addLine(to: CGPoint(x: x1, y: py))
                for x in [x0, x1] {
                    path.move(to: CGPoint(x: x, y: py - Self.tick))
                    path.addLine(to: CGPoint(x: x, y: py + Self.tick))
                }
            }
            if let spacing = guides.xSpacing {
                for gap in [spacing.first, spacing.second] {
                    let g = transform.toDisplay(gap)
                    let py = g.midY.rounded() + 0.5
                    let x0 = g.minX.rounded() + 0.5, x1 = g.maxX.rounded() + 0.5
                    path.move(to: CGPoint(x: x0, y: py))
                    path.addLine(to: CGPoint(x: x1, y: py))
                    for x in [x0, x1] {
                        path.move(to: CGPoint(x: x, y: py - Self.tick))
                        path.addLine(to: CGPoint(x: x, y: py + Self.tick))
                    }
                }
            }
            if let spacing = guides.ySpacing {
                for gap in [spacing.first, spacing.second] {
                    let g = transform.toDisplay(gap)
                    let px = g.midX.rounded() + 0.5
                    let y0 = g.minY.rounded() + 0.5, y1 = g.maxY.rounded() + 0.5
                    path.move(to: CGPoint(x: px, y: y0))
                    path.addLine(to: CGPoint(x: px, y: y1))
                    for y in [y0, y1] {
                        path.move(to: CGPoint(x: px - Self.tick, y: y))
                        path.addLine(to: CGPoint(x: px + Self.tick, y: y))
                    }
                }
            }
            context.stroke(path, with: .color(DS.Color.accent),
                           lineWidth: DS.Stroke.hairlineAdaptive)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Link layer

/// Per-frame styling inputs for the link layer, separate from geometry so
/// hover / selection changes do not force the scene to be rebuilt.
struct LinkLayerState: Equatable {
    var selectedLinkID: UUID?
    var hoveredLinkID: UUID?
    /// While chain-building with the Link tool, links of other classes
    /// are dimmed.
    var emphasisedClass: Int?
    var scale: CGFloat
}

struct LinkLayerCanvas: View, Equatable {
    let scene: CanvasScene
    let state: LinkLayerState

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let t0 = CanvasProfiler.enabled ? CFAbsoluteTimeGetCurrent() : 0
            // Ordinary links first, then the hovered one, then the selected
            // one so emphasis always paints on top of neighbours.
            //
            // Declutter: below `DS.Canvas.linkLabelMinScale` no probability
            // chip is drawn at all; above it, a chip whose rect would
            // overlap one already placed this frame is skipped (the link
            // itself is still drawn).  The hovered and selected links'
            // chips are reserved before anything else is placed, so they
            // always win — hovering a link is how the dropped chip is
            // revealed.
            var deferred: [CanvasScene.LinkItem] = []
            var occupied: [CGRect] = []
            let chips = state.scale >= DS.Canvas.linkLabelMinScale
            if chips {
                for item in scene.links
                where item.id == state.selectedLinkID || item.id == state.hoveredLinkID {
                    if let chip = chipRect(for: item, in: context) { occupied.append(chip) }
                }
            }
            for item in scene.links {
                if item.id == state.selectedLinkID || item.id == state.hoveredLinkID {
                    deferred.append(item)
                } else {
                    draw(item, in: context, chip: chips ? .declutter : .never, occupied: &occupied)
                }
            }
            for item in deferred where item.id != state.selectedLinkID {
                draw(item, in: context, chip: chips ? .always : .never, occupied: &occupied)
            }
            for item in deferred where item.id == state.selectedLinkID {
                draw(item, in: context, chip: chips ? .always : .never, occupied: &occupied)
            }
            if CanvasProfiler.enabled {
                CanvasProfiler.record(layer: .links,
                                      drawSeconds: CFAbsoluteTimeGetCurrent() - t0,
                                      linkCount: scene.links.count,
                                      nodeCount: scene.nodes.count)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Whether a link's probability chip is drawn this frame.
    private enum ChipPolicy {
        case never
        /// Only if it does not overlap a chip already placed.
        case declutter
        /// Reserved in advance; always drawn.
        case always
    }

    /// The probability chip's text, resolved, and the rect it occupies.
    private func chipRect(for item: CanvasScene.LinkItem,
                          in context: GraphicsContext,
                          color: Color = DS.Color.textSecondary)
        -> (chip: CGRect, text: GraphicsContext.ResolvedText)? {
        let link = item.link
        guard link.routingProbability != 1.0 else { return nil }
        // Same rounding convention as the inspectors (DS.Number).
        let text = Text(DS.Number.format(link.routingProbability, significantDigits: 2))
            .font(DS.Canvas.linkLabelDisplayFont(scale: state.scale))
            .foregroundStyle(color)
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 120, height: 40))
        let anchor = item.geometry.labelAnchor
        let chip = CGRect(
            x: anchor.x - textSize.width / 2 - DS.Spacing.xs,
            y: anchor.y - textSize.height / 2 - 1,
            width: textSize.width + 2 * DS.Spacing.xs,
            height: textSize.height + 2
        )
        return (chip, resolved)
    }

    private func chipRect(for item: CanvasScene.LinkItem, in context: GraphicsContext) -> CGRect? {
        chipRect(for: item, in: context, color: DS.Color.textSecondary)?.chip
    }

    private func draw(_ item: CanvasScene.LinkItem, in context: GraphicsContext,
                      chip policy: ChipPolicy, occupied: inout [CGRect]) {
        let link = item.link
        let g = item.geometry
        let isSelected = state.selectedLinkID == link.id
        let isHovered = state.hoveredLinkID == link.id
        let dimmed = state.emphasisedClass.map { link.customerClass != $0 } ?? false

        let fromClass = link.customerClass
        let toClass = link.toCustomerClass ?? link.customerClass
        let fromColor = CustomerClass.color(for: fromClass)
        let toColor = CustomerClass.color(for: toClass)

        var lineWidth = LinkGeometry.lineWidth(scale: state.scale)
        if isHovered || isSelected { lineWidth = max(3, lineWidth * 1.5) }

        let shading: GraphicsContext.Shading
        if isSelected {
            shading = .color(DS.Color.accent)
        } else if fromClass != toClass {
            // Class transition: the stroke runs from the entry class colour
            // to the exit class colour, arrowhead included.
            shading = .linearGradient(
                Gradient(colors: [fromColor, toColor]),
                startPoint: g.start, endPoint: g.tip)
        } else {
            shading = .color(fromColor)
        }

        if isSelected {
            let halo = StrokeStyle(lineWidth: lineWidth + 6, lineCap: .round, lineJoin: .round)
            context.stroke(g.strokePath, with: .color(DS.Color.linkHalo), style: halo)
            context.stroke(g.arrowPath, with: .color(DS.Color.linkHalo), style: halo)
        }

        var ctx = context
        ctx.opacity = dimmed ? DS.Opacity.dim
            : ((isHovered || isSelected) ? 1 : DS.Opacity.linkStroke)
        ctx.stroke(g.strokePath, with: shading,
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round))
        ctx.fill(g.arrowPath, with: shading)

        if policy != .never, link.routingProbability != 1.0 {
            let labelColor: Color = isSelected ? DS.Color.accent
                : (isHovered ? fromColor : DS.Color.textSecondary)
            // The chip is drawn at full opacity (not the softened link
            // opacity) so it stays legible against the grid in dark mode.
            var chipCtx = context
            chipCtx.opacity = dimmed ? DS.Opacity.dim : 1
            guard let (chip, resolved) = chipRect(for: item, in: chipCtx, color: labelColor)
            else { return }
            if policy == .declutter {
                if occupied.contains(where: { $0.intersects(chip) }) { return }
                occupied.append(chip)
            }
            let chipPath = Path(roundedRect: chip, cornerRadius: DS.Radius.swatch + 1)
            chipCtx.fill(chipPath, with: .color(DS.Color.surfaceRaised))
            chipCtx.stroke(chipPath,
                           with: .color(isHovered || isSelected ? labelColor : DS.Color.separatorAdaptive),
                           lineWidth: DS.Stroke.hairlineAdaptive)
            chipCtx.draw(resolved, at: g.labelAnchor, anchor: .center)
        }
    }
}

// MARK: - Link preview

/// The elastic rubber-band drawn while a link is being pulled out of a
/// node — the drag-to-connect gesture, and the two-click flow's pending
/// start, which shows the same line following the pointer.
///
/// Dashed, in the chain's own class colour, so it reads as "not a link
/// yet".  With no node under the pointer it is a bare line to the free
/// end: there is no target, so there is nothing to point an arrowhead
/// at.  Over a node it becomes the exact geometry that release would
/// create — `LinkGeometry.between`, the same call the link layer makes —
/// so the user sees which boundary the arrow lands on before committing.
/// Back over the node it started from — the out-and-back gesture that
/// draws a self-loop — it becomes `LinkGeometry.selfLoop`, again the
/// link layer's own call, rather than a line running into its own start.
///
/// One `Canvas`, `Equatable` on its inputs, live only while a link is
/// being drawn: on every other frame the layer is absent from the tree.
struct LinkPreviewCanvas: View, Equatable {
    /// Display centre of the node the link is leaving.
    let startCentre: CGPoint
    let startKind: NodeKind
    /// The free end, in display points.
    let pointer: CGPoint
    /// The node under the pointer, when release would land on one.
    let targetCentre: CGPoint?
    let targetKind: NodeKind?
    /// Non-nil when release would draw a self-loop on the start node,
    /// carrying the radius that loop would nest at (the scene pushes each
    /// additional loop on a node one bundle spacing outward, so a preview
    /// drawn at zero would sit exactly on the loop already there).  It
    /// wins over `targetCentre`: the start node is its own target.
    let selfLoopRadius: CGFloat?
    let scale: CGFloat
    /// The chain's class colour, or the accent when no class is fixed
    /// yet — the same colour the pending-start ring is drawn in.
    let color: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            // The dash keeps its rhythm as the canvas zooms, and the
            // floor stops it dissolving into dots when zoomed out — the
            // spelling the pending-start ring already uses.
            let d = max(0.6, scale)
            // The weight a real link is drawn at, from the one function
            // that answers that — the preview promises exactly the line
            // release would leave behind.
            let style = StrokeStyle(lineWidth: LinkGeometry.lineWidth(scale: scale),
                                    lineCap: .round,
                                    dash: [6 * d, 4 * d])
            if let selfLoopRadius {
                let geometry = LinkGeometry.selfLoop(
                    centre: startCentre, kind: startKind,
                    scale: scale, extraRadius: selfLoopRadius)
                context.stroke(geometry.strokePath, with: .color(color), style: style)
                context.fill(geometry.arrowPath, with: .color(color))
            } else if let targetCentre, let targetKind {
                let geometry = LinkGeometry.between(
                    fromCentre: startCentre, fromKind: startKind,
                    toCentre: targetCentre, toKind: targetKind,
                    scale: scale)
                context.stroke(geometry.strokePath, with: .color(color), style: style)
                context.fill(geometry.arrowPath, with: .color(color))
            } else {
                var path = Path()
                path.move(to: boundaryPoint)
                path.addLine(to: pointer)
                context.stroke(path, with: .color(color), style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the line leaves the start node's outline, so it emerges
    /// from the shape rather than from a point buried inside it.
    /// `exitDistance` works in node-local world points, hence the scale.
    private var boundaryPoint: CGPoint {
        let u = CanvasMath.unit(from: startCentre, to: pointer)
        let d = NodeOutline.exitDistance(kind: startKind, from: .zero, direction: u) * scale
        return CGPoint(x: startCentre.x + u.x * d, y: startCentre.y + u.y * d)
    }
}

// MARK: - Node outline shape

/// Outline of a node kind drawn to fill `rect`.  Used for the body, the
/// hover / selection rings (with a larger rect) and the pending-link
/// indicator, so every ring hugs the actual shape.
struct NodeOutlineShape: Shape {
    let kind: NodeKind
    /// Corner radius for the sink, in display points.
    var cornerRadius: CGFloat = NodeOutline.sinkCornerRadius

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .station:
            return Path(ellipseIn: rect)
        case .source:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p
        case .buffer:
            return Path(rect)
        case .sink:
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        }
    }
}

/// Fill shape for infinite buffers: only the right 2/3 (two closed blocks).
private struct BufferFillShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x1 = rect.minX + rect.width / 3
        path.addRect(CGRect(x: x1, y: rect.minY, width: rect.width * 2 / 3, height: rect.height))
        return path
    }
}

private struct BufferShape: Shape {
    var isInfinite: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isInfinite {
            // Open on the left side: top, right, bottom only
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            // Full closed rectangle
            path.addRect(rect)
        }
        // Two vertical dividers at 1/3 and 2/3
        let x1 = rect.minX + rect.width / 3
        let x2 = rect.minX + 2 * rect.width / 3
        path.move(to: CGPoint(x: x1, y: rect.minY))
        path.addLine(to: CGPoint(x: x1, y: rect.maxY))
        path.move(to: CGPoint(x: x2, y: rect.minY))
        path.addLine(to: CGPoint(x: x2, y: rect.maxY))
        return path
    }
}

// MARK: - Node view

/// One node on the canvas.  The body is drawn through the zoom (its frame
/// is the world size × scale) while the label block below it is laid out
/// in display space with a clamped point size, so text stays crisp and
/// readable at every zoom instead of being rasterised by `scaleEffect`.
struct NetworkNodeView: View, Equatable {
    let node: NetworkNode
    let scale: CGFloat
    let isSelected: Bool
    let isHovered: Bool
    /// Inside an in-progress marquee — previewed like a hover.
    let isMarqueeCandidate: Bool
    let isPendingLinkStart: Bool
    let infiniteBuffers: Bool
    let utilisation: Double?
    /// Increase Contrast, handed in by the canvas (which reads it through
    /// `@DSAccessibility`) rather than read here: this view is `Equatable`
    /// on its inputs, and the switch is one of them. The image exporter
    /// leaves it at `.standard` — a file should not depend on the
    /// exporting Mac's accessibility settings.
    var contrast: ColorSchemeContrast = .standard

    private var bodySize: CGSize {
        let s = NodeOutline.size(for: node.kind)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private var strokeWidth: CGFloat { max(1, 2 * scale) }

    var body: some View {
        let size = bodySize
        let showsHoverRing = (isHovered || isMarqueeCandidate) && !isSelected

        ZStack {
            // Hover ring: 1pt accent at 35 %, 3pt outside the outline.
            NodeOutlineShape(kind: node.kind, cornerRadius: NodeOutline.sinkCornerRadius * scale + 3)
                .stroke(DS.Color.hoverRing, lineWidth: DS.Stroke.hairline(contrast))
                .frame(width: size.width + 6, height: size.height + 6)
                .opacity(showsHoverRing ? 1 : 0)

            // Selection ring: 1.5pt accent, 4pt outside, with a soft glow.
            // Nodes have a fixed size, so there are deliberately no corner
            // handles — they would promise a resize that does not exist.
            NodeOutlineShape(kind: node.kind, cornerRadius: NodeOutline.sinkCornerRadius * scale + 4)
                .stroke(DS.Color.accentStroke, lineWidth: DS.Stroke.selectionRing)
                .frame(width: size.width + 8, height: size.height + 8)
                .shadow(color: DS.Color.selectionGlow, radius: 6)
                .opacity(isSelected ? 1 : 0)

            nodeIcon
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            labelBlock
                .offset(y: size.height + NodeOutline.labelBlockGap)
        }
        .overlay(alignment: .topTrailing) {
            if let rho = utilisation {
                utilisationBadge(rho)
                    .offset(x: DS.Spacing.s, y: -DS.Spacing.s)
                    .transition(.opacity)
            }
        }
        .dsAnimation(DS.Motion.quick, value: isHovered)
        .dsAnimation(DS.Motion.quick, value: isMarqueeCandidate)
        .dsAnimation(DS.Motion.quick, value: isSelected)
        .dsAnimation(DS.Motion.quick, value: utilisation != nil)
        // Full name (never truncated), the parameters in words, and the
        // glossary line for each symbol as the tooltip.
        .help(tooltipDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Body

    @ViewBuilder
    private var nodeIcon: some View {
        switch node.kind {
        case .station:
            ZStack {
                Circle()
                    .fill(fillColor)
                    .overlay(Circle().stroke(borderColor, lineWidth: strokeWidth))
                if let sys = node.picture.systemImageName {
                    // Inscribe the icon in a square that fits inside the
                    // circle with a small margin so it never touches the
                    // stroke.
                    Image(systemName: sys)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(DS.Color.nodeGlyph)
                        .padding(bodySize.width * 0.18)
                }
            }
        case .buffer:
            if infiniteBuffers {
                BufferFillShape()
                    .fill(fillColor)
                    .overlay(BufferShape(isInfinite: true).stroke(borderColor, lineWidth: strokeWidth))
            } else {
                BufferShape(isInfinite: false)
                    .fill(fillColor)
                    .overlay(BufferShape(isInfinite: false).stroke(borderColor, lineWidth: strokeWidth))
            }
        case .source:
            NodeOutlineShape(kind: .source)
                .fill(fillColor)
                .overlay(NodeOutlineShape(kind: .source).stroke(borderColor, lineWidth: strokeWidth))
        case .sink:
            let r = NodeOutline.sinkCornerRadius * scale
            NodeOutlineShape(kind: .sink, cornerRadius: r)
                .fill(fillColor)
                .overlay(NodeOutlineShape(kind: .sink, cornerRadius: r).stroke(borderColor, lineWidth: strokeWidth))
        }
    }

    // MARK: Labels

    /// Name / distribution / rate rows.  Each row has a zoom below which
    /// it is dropped (`DS.Canvas.*MinScale`) so a large network at low
    /// zoom is bodies and arrows, not a pile of 9-pt text; a hovered or
    /// selected node keeps its name at any zoom, and the tooltip always
    /// carries the whole block.  The block's width and the gap above it
    /// are `NodeOutline`'s, the same numbers the link router keeps
    /// arrows out of.
    private var labelBlock: some View {
        VStack(spacing: 1) {
            if scale >= DS.Canvas.nameRowMinScale || isHovered || isSelected {
                Text(node.name)
                    .font(DS.Canvas.nameDisplayFont(scale: scale))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if scale >= DS.Canvas.detailRowMinScale, let detail = detailText {
                Text(detail)
                    .font(DS.Canvas.detailDisplayFont(scale: scale))
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if scale >= DS.Canvas.rateRowMinScale, let rates = rateText {
                Text(rates)
                    .font(DS.Canvas.detailDisplayFont(scale: scale, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: max(56, NodeOutline.labelBlockWidth * min(scale, 1.4)))
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }

    /// The ρ capsule: `DS.Color.legibleTint` of the signal colour with
    /// `DS.Color.textOnTint` on it — the pair the DS certifies (5.8 : 1
    /// and better in both appearances, `validation/ds_contrast.swift`
    /// gates it under "ρ badge").  White on the raw system tint, which is
    /// what this used to be, measured 2.0 : 1 in dark mode.  The number
    /// is formatted by `DS.Number` so the badge, its tooltip and the
    /// spoken description round the same way.
    private func utilisationBadge(_ rho: Double) -> some View {
        let tint: Color = rho >= 0.9 ? DS.Color.danger : (rho >= 0.7 ? DS.Color.warning : DS.Color.success)
        let load = rho >= 1 ? "Unstable: ρ ≥ 1." : (rho >= 0.9 ? "Heavy traffic." : (rho >= 0.7 ? "Moderate load." : "Light load."))
        return Text("ρ \(DS.Number.format(rho, significantDigits: 2))")
            .font(DS.Canvas.badgeFont)
            .foregroundStyle(DS.Color.textOnTint)
            .padding(.horizontal, DS.Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.Color.legibleTint(tint)))
            .overlay(Capsule().stroke(DS.Color.separator(contrast), lineWidth: DS.Stroke.hairline(contrast)))
            .fixedSize()
            .help("Utilisation ρ = \(DS.Number.format(rho, significantDigits: 3)) from the traffic equations (α / c·μ); updates as you edit. \(load)")
            .accessibilityHidden(true)
    }

    private var detailText: String? {
        switch node.kind {
        case .buffer:
            return infiniteBuffers ? nil : "b=\(node.bufferSize)"
        case .station:
            let serverStr = node.numberOfServers > 1 ? " c=\(node.numberOfServers)" : ""
            if node.serviceDistributions.count > 1 {
                return "Multi-class\(serverStr)"
            }
            return node.distribution.displayName + serverStr
        case .source:
            return node.distribution.displayName
        case .sink:
            return nil
        }
    }

    /// "μ=2.5 · SCV=1" — rate and squared coefficient of variation on one
    /// row so the label block stays compact.
    private var rateText: String? {
        let label: String
        switch node.kind {
        case .station: label = "μ"
        case .source:  label = "λ"
        default: return nil
        }
        var parts: [String] = []
        if let mean = node.distribution.meanFromParameterString(node.distributionParameters), mean > 0 {
            parts.append("\(label)=\(DS.Number.format(1.0 / mean, significantDigits: 4))")
        }
        if let scv = node.distribution.scvFromParameterString(node.distributionParameters) {
            parts.append("SCV=\(DS.Number.format(scv, significantDigits: 3))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The bare "μ=2.5 · SCV=1" under a node, said in words for the
    /// tooltip and VoiceOver: "service rate μ = 2.5 jobs per time unit,
    /// SCV 1 (exponential)". `DS.Glossary.lambda` / `.mu` supply the
    /// definitions, so the canvas is not the one place a MATLAB user
    /// meets undefined notation with no way to ask.
    private var rateDescription: String? {
        let isSource = node.kind == .source
        guard isSource || node.kind == .station else { return nil }
        var parts: [String] = []
        if let mean = node.distribution.meanFromParameterString(node.distributionParameters), mean > 0 {
            let rate = DS.Number.format(1.0 / mean, significantDigits: 4)
            parts.append(isSource
                         ? "arrival rate λ = \(rate) jobs per time unit"
                         : "service rate μ = \(rate) jobs per time unit per server")
        }
        if let scv = node.distribution.scvFromParameterString(node.distributionParameters) {
            let s = DS.Number.format(scv, significantDigits: 3)
            let kind = scv == 1 ? " (exponential)" : (scv == 0 ? " (deterministic)" : (scv > 1 ? " (burstier than exponential)" : " (steadier than exponential)"))
            parts.append("SCV \(s)\(kind)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var accessibilityDescription: String {
        var parts = ["\(node.kind.displayName) \(node.name)"]
        if let d = detailText { parts.append(d) }
        if let r = rateDescription { parts.append(r) }
        if let rho = utilisation { parts.append("utilisation ρ \(DS.Number.format(rho, significantDigits: 2))") }
        return parts.joined(separator: ", ")
    }

    /// Tooltip: the spoken description plus the glossary line for each
    /// symbol drawn under the node, so hovering explains λ, μ and SCV.
    private var tooltipDescription: String {
        var lines = [accessibilityDescription]
        switch node.kind {
        case .source:  lines.append(DS.Glossary.lambda)
        case .station: lines.append(DS.Glossary.mu)
        default: break
        }
        if rateText?.contains("SCV") == true { lines.append(DS.Glossary.scv) }
        return lines.joined(separator: "\n")
    }

    // MARK: Colours

    private var fillColor: Color {
        if isPendingLinkStart {
            return DS.Color.selectionFillStrong
        }
        switch node.kind {
        case .station: return DS.Color.stationFill
        case .buffer:  return DS.Color.bufferFill
        case .source:  return DS.Color.sourceFill
        case .sink:    return DS.Color.sinkFill
        }
    }

    private var borderColor: Color {
        isSelected ? DS.Color.accent : DS.Color.nodeStroke
    }
}
