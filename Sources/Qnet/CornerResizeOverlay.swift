import SwiftUI
import AppKit

/// Weak-references the three NSSplitViews in ContentView keyed by their
/// autosaveName so CornerResizeOverlay can read divider positions and
/// move dividers from outside their respective subtrees. SplitView-
/// Configurator's Coordinator populates it on attach and pumps `tick`
/// on every resize notification so SwiftUI re-runs the overlay's body.
@MainActor
final class SplitRegistry: ObservableObject {
    static let shared = SplitRegistry()

    @Published private(set) var tick: Int = 0

    private final class Box { weak var view: NSSplitView? }
    private var splits: [String: Box] = [:]
    private var pendingBump = false

    func register(_ sv: NSSplitView, name: String) {
        let box = splits[name] ?? Box()
        box.view = sv
        splits[name] = box
        bump()
    }

    func split(_ name: String) -> NSSplitView? { splits[name]?.view }

    /// Coalesce: NSSplitView posts didResizeSubviews multiple times in
    /// one drag tick; we only need to redraw once per runloop cycle.
    func bump() {
        if pendingBump { return }
        pendingBump = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBump = false
            self.tick &+= 1
        }
    }
}

/// Width/height of the hit area at each intersection. Wide enough
/// that the cursor can sit clearly inside one of the four quadrants
/// without straddling the centre line. File-scope constant so the
/// nonisolated Quadrant helpers can read it without main-actor hops.
fileprivate let cornerHitSize: CGFloat = 24
fileprivate let cornerArmLength: CGFloat = cornerHitSize / 2

/// Hit regions placed at every T-junction where the outer horizontal
/// divider crosses an inner vertical divider. Drag any grip to move
/// both dividers at once. While hovered, an L-shaped icon appears,
/// oriented to hug the inside corner of whichever pane the cursor is
/// currently in (UL → ┘, UR → └, LL → ┐, LR → ┌).
struct CornerResizeOverlay: View {
    @ObservedObject private var registry = SplitRegistry.shared
    let aiPaneVisible: Bool

    var body: some View {
        // Read tick so SwiftUI invalidates this body on every divider
        // resize. Do NOT apply .id(tick) — that would destroy the grip
        // subviews mid-drag and lose their @State (drag start positions).
        _ = registry.tick

        return ZStack(alignment: .topLeading) {
            // Without this filler the ZStack's frame collapses to the
            // union of its `.position`-placed children, which sits well
            // away from the corners — and SwiftUI clips hit testing to
            // the parent's frame. Color.clear expands the ZStack to fill
            // the overlay without absorbing hits itself, so clicks
            // outside the grips still pass through to the splitter.
            Color.clear
            ForEach(intersections, id: \.id) { spot in
                CornerGrip(spot: spot)
                    .frame(width: cornerHitSize, height: cornerHitSize)
                    .position(x: spot.center.x, y: spot.center.y)
            }
        }
        .allowsHitTesting(true)
    }

    /// Centre of every active grip in the overlay's local coord space
    /// (top-left origin, matches the outer VSplit's frame).
    ///
    /// The outer split's rows are [top, results?, bottom?] — Results is
    /// a full-width row of its own (`ContentView.outerPanes`), so the
    /// top row's height is the y of the FIRST horizontal divider and
    /// nothing more. The grips at the top of the bottom row therefore
    /// anchor to the LAST divider, not to divider 0: with Results shown
    /// the two are a whole results pane apart, and a grip drawn at
    /// divider 0 dragged two unrelated dividers at once.
    private var intersections: [CornerSpot] {
        guard let outer = registry.split("OuterVSplit"),
              outer.arrangedSubviews.count >= 2
        else { return [] }

        var out: [CornerSpot] = []

        // The top row's own T-junctions exist only while the top split
        // really has three arranged subviews — palette | canvas | right
        // column. Hiding the Tools pane or the whole right column (one
        // click in View ▸ Panes, and what the Shell and Canvas Only
        // presets do) leaves two, and there is no interior T-junction to
        // draw. That must not take the bottom row's grip with it, which
        // is what a single shared guard used to do.
        if let top = registry.split("TopHSplit"), top.arrangedSubviews.count >= 3 {
            // The top row's own T-junctions sit on the first divider.
            let topRowDividerY = outerDividerY(in: outer, at: 0)
            let topDivider0X = top.arrangedSubviews[0].frame.width
            let topDivider1X = topDivider0X
                + top.dividerThickness
                + top.arrangedSubviews[1].frame.width

            out.append(CornerSpot(
                id: "top.palette.canvas",
                center: CGPoint(x: topDivider0X, y: topRowDividerY),
                hSplitName: "TopHSplit",
                hSplitDividerIndex: 0,
                outerDividerIndex: 0
            ))
            out.append(CornerSpot(
                id: "top.canvas.status",
                center: CGPoint(x: topDivider1X, y: topRowDividerY),
                hSplitName: "TopHSplit",
                hSplitDividerIndex: 1,
                outerDividerIndex: 0
            ))
        }

        if aiPaneVisible,
           let bot = registry.split("BottomHSplit"),
           bot.arrangedSubviews.count >= 2 {
            // The bottom row is the outer split's last child, so the
            // divider above it is the last one: index count - 2. With
            // Results hidden that is divider 0 and the grip lands exactly
            // where it always did.
            let bottomRowDividerIndex = outer.arrangedSubviews.count - 2
            let botDividerX = bot.arrangedSubviews[0].frame.width
            out.append(CornerSpot(
                id: "bottom.terminal.ai",
                center: CGPoint(x: botDividerX,
                                y: outerDividerY(in: outer, at: bottomRowDividerIndex)),
                hSplitName: "BottomHSplit",
                hSplitDividerIndex: 0,
                outerDividerIndex: bottomRowDividerIndex
            ))
        }

        return out
    }
}

/// Y of divider `index` in a vertical split view: the rows above it plus
/// the dividers between them — the same quantity `setPosition(_:ofDividerAt:)`
/// takes, so reading and writing a divider use one definition. Shaped like
/// `CornerGrip.currentHX` for the horizontal case.
@MainActor
private func outerDividerY(in sv: NSSplitView, at index: Int) -> CGFloat {
    guard index >= 0, index < sv.arrangedSubviews.count - 1 else { return 0 }
    var y: CGFloat = 0
    for i in 0...index {
        y += sv.arrangedSubviews[i].frame.height
        if i < index { y += sv.dividerThickness }
    }
    return y
}

/// One corner grip. Detects which quadrant the cursor is in via
/// onContinuousHover, draws an L oriented to hug that pane's interior
/// corner, and forwards drag deltas to both dividers using positions
/// captured at drag-start so AppKit's snap/clamp at min-widths still
/// applies on each move.
private struct CornerGrip: View {
    let spot: CornerSpot

    @State private var quadrant: Quadrant?
    @State private var startHX: CGFloat?
    @State private var startOuterY: CGFloat?

    var body: some View {
        ZStack {
            // Transparent fill plus an explicit content shape makes the
            // whole square hit-testable without a visible tint.
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())

            // AppKit cursor rect (no push / pop) so the pointer becomes
            // a crosshair while it is over the grip.
            CursorRectView(cursor: .crosshair)

            if let q = quadrant {
                LShape(quadrant: q)
                    .stroke(DS.Color.textSecondary,
                            style: StrokeStyle(lineWidth: DS.Stroke.selection,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .frame(width: cornerArmLength, height: cornerArmLength)
                    .position(x: q.lCenterX, y: q.lCenterY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .dsAnimation(DS.Motion.quick, value: quadrant != nil)
        .help("Drag to resize both panes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pane corner resize handle")
        .accessibilityHint("Drag to move the horizontal and vertical dividers together")
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let mid = cornerHitSize / 2
                quadrant = Quadrant(dx: location.x - mid,
                                    dy: location.y - mid)
            case .ended:
                quadrant = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in moveDividers(by: value.translation) }
                .onEnded { _ in
                    startHX = nil
                    startOuterY = nil
                }
        )
    }

    private func moveDividers(by translation: CGSize) {
        let registry = SplitRegistry.shared
        guard let outer = registry.split("OuterVSplit"),
              let h = registry.split(spot.hSplitName) else { return }

        if startHX == nil { startHX = currentHX(in: h) }
        if startOuterY == nil { startOuterY = currentOuterY(in: outer) }

        let newX = (startHX ?? 0) + translation.width
        let newY = (startOuterY ?? 0) + translation.height

        h.setPosition(newX, ofDividerAt: spot.hSplitDividerIndex)
        outer.setPosition(newY, ofDividerAt: spot.outerDividerIndex)
    }

    private func currentHX(in sv: NSSplitView) -> CGFloat {
        var x: CGFloat = 0
        for i in 0...spot.hSplitDividerIndex {
            x += sv.arrangedSubviews[i].frame.width
            if i < spot.hSplitDividerIndex { x += sv.dividerThickness }
        }
        return x
    }

    private func currentOuterY(in sv: NSSplitView) -> CGFloat {
        outerDividerY(in: sv, at: spot.outerDividerIndex)
    }
}

/// An invisible AppKit view that registers a cursor rect over its bounds.
/// It refuses hit-testing so SwiftUI gestures above it keep working; the
/// cursor still changes because cursor rects are tracked by the window,
/// not by event dispatch.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let v = CursorRectNSView(frame: .zero)
        v.cursor = cursor
        return v
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class CursorRectNSView: NSView {
    var cursor: NSCursor = .arrow

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }
}

private struct CornerSpot: Identifiable {
    let id: String
    let center: CGPoint
    let hSplitName: String
    let hSplitDividerIndex: Int
    /// Which of the outer vertical split's dividers this junction sits
    /// on. Stored rather than assumed: the outer split gains a row when
    /// the Results pane is shown, and the bottom row's junction then
    /// moves to a different divider.
    let outerDividerIndex: Int
}

/// Which of the four quadrants of a corner-grip hit area the cursor
/// is in, relative to the intersection point at the centre.
private enum Quadrant {
    case upperLeft, upperRight, lowerLeft, lowerRight

    init(dx: CGFloat, dy: CGFloat) {
        let left = dx < 0
        let above = dy < 0
        switch (above, left) {
        case (true,  true):  self = .upperLeft
        case (true,  false): self = .upperRight
        case (false, true):  self = .lowerLeft
        case (false, false): self = .lowerRight
        }
    }

    /// Centre of the L glyph within the hit area, placed so the L's
    /// inside corner (where the two legs meet) lands on the intersection
    /// point at the centre of the hit rect.
    var lCenterX: CGFloat {
        switch self {
        case .upperLeft, .lowerLeft:   return cornerArmLength / 2
        case .upperRight, .lowerRight: return cornerArmLength + cornerArmLength / 2
        }
    }
    var lCenterY: CGFloat {
        switch self {
        case .upperLeft, .upperRight: return cornerArmLength / 2
        case .lowerLeft, .lowerRight: return cornerArmLength + cornerArmLength / 2
        }
    }
}

/// L-shaped path drawn inside a square. The "inside corner" — where the
/// two legs meet — is positioned to point at the intersection between
/// panes (i.e. the corner of the rect closest to the center of the hit
/// area). The other two endpoints trace the inside walls of the pane
/// the cursor is in.
///
///   .upperLeft  →  ┘  (corner at maxX,maxY; legs up + left)
///   .upperRight →  └  (corner at minX,maxY; legs up + right)
///   .lowerLeft  →  ┐  (corner at maxX,minY; legs down + left)
///   .lowerRight →  ┌  (corner at minX,minY; legs down + right)
private struct LShape: Shape {
    let quadrant: Quadrant

    func path(in rect: CGRect) -> Path {
        let cornerX, cornerY, legEndX, legEndY: CGFloat
        switch quadrant {
        case .upperLeft:
            cornerX = rect.maxX; cornerY = rect.maxY
            legEndX = rect.minX; legEndY = rect.minY
        case .upperRight:
            cornerX = rect.minX; cornerY = rect.maxY
            legEndX = rect.maxX; legEndY = rect.minY
        case .lowerLeft:
            cornerX = rect.maxX; cornerY = rect.minY
            legEndX = rect.minX; legEndY = rect.maxY
        case .lowerRight:
            cornerX = rect.minX; cornerY = rect.minY
            legEndX = rect.maxX; legEndY = rect.maxY
        }
        var p = Path()
        // Vertical leg, then horizontal leg, sharing the corner vertex.
        p.move(to: CGPoint(x: cornerX, y: legEndY))
        p.addLine(to: CGPoint(x: cornerX, y: cornerY))
        p.addLine(to: CGPoint(x: legEndX, y: cornerY))
        return p
    }
}
