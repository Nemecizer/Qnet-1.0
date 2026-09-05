import SwiftUI
import AppKit

/// The network drawing surface.
///
/// Coordinate model: node positions are stored in plain world points and
/// mapped to the viewport with `display = world · scale + pan`
/// (`CanvasTransform`).  Every layer — grid, links, nodes, marquee — and
/// every hit test reads from one `CanvasScene` built from that transform,
/// so what is drawn is exactly what is hit, at any zoom or pan.  The scene
/// is memoised (`SceneCache`) on its inputs, so a status-log append or a
/// hover change never re-routes a single link.
///
/// Programmatic zooms (menu, zoom cluster, fit) bump
/// `editor.canvasAnimationToken`; the content view is `Animatable` on the
/// transform, so the whole scene glides to the new view as one.  Wheel
/// and pinch zooms leave the token alone and track the pointer 1:1.
///
/// Link routes are planned once per edit (`editor.routePlan`, frozen for
/// the length of a node drag) and, when the plan changes, the link layer
/// eases every bow from the old plan to the new one over
/// `DS.Motion.quick` (`AnimatedLinkLayer`) instead of teleporting.
///
/// Selection model (Pointer / Multi-Select tools):
///   • plain click        → the node becomes the sole selection
///   • ⇧- or ⌘-click      → toggles the node in the selection group
///   • drag on empty      → marquee replaces the selection; ⇧-drag adds
///   • drag on a node     → moves the node, or the whole group it is in;
///                          alignment guides and Snap to Grid both pull,
///                          the nearer one winning per axis
///   • ⌃ held mid-drag    → free placement: no grid, no guides (⌃ is read
///                          live, and ⌃-mouse-down is a context click, so
///                          it can never start a drag or extend a selection)
///   • ⌥-drag on a node   → duplicates first, then moves the copies
///   • drag on a link     → moves both endpoints live, one undo step
///   • double-click empty → sticky pan (below)
///   • Space held / middle button → temporary pan in every tool
///   • Escape mid-drag    → puts the drag back and leaves no undo step
///                          (`cancelDragInFlight()`); an ⌥-drag is the one
///                          exception, and says why
///   • Escape / ⌥⌘A       → `editor.deselectAll()`, the one implementation
///
/// Link tool: press on a node and drag to a second one to connect them,
/// with a dashed preview following the pointer (`LinkPreviewCanvas`).
/// The release runs the two-click flow's own `handleNodeTap` calls, so
/// class selection, the refusal to repeat a pair and chain continuation
/// have one implementation.  Clicking the two nodes in turn still works
/// and now shows the same preview between the clicks.  Dragging out of a
/// node and back onto it is the self-loop gesture, and lands in that same
/// call — so a station gets its feedback arc and a source, buffer or sink
/// gets the sentence saying why it cannot have one, exactly as clicking
/// it twice does.  On a station the band draws that arc while the pointer
/// is back over the node, so the one gesture that ends where it began is
/// as visible as every other.  Releasing on empty canvas abandons the
/// drag silently, the Mac convention, leaving the network as it was found.
///
/// Sticky pan: a double-click on empty canvas in the Pointer or
/// Multi-Select tool hands the canvas to the hand (`enterStickyPan()`),
/// and the next single click gives the previous tool back
/// (`exitStickyPan()`, from `panEnded`, where a Pan-tool click lands).
/// It is the only gesture that changes the active tool — H, the palette
/// and the Space bar are the other ways to reach the Pan tool, and none
/// of them is undone by a click.
///
/// The canvas is the one pane with no header of its own, so its keyboard
/// focus rule is drawn by the tab bar directly above it (`TabBarView`,
/// via `dsFocusRule`) — one accent line for the pane, in the position
/// every other pane's `DSSectionHeader` puts it.
struct NetworkCanvasView: View {
    @EnvironmentObject private var editor: NetworkEditorModel

    var body: some View {
        GeometryReader { geometry in
            CanvasContentView(
                scale: editor.canvasScale,
                panX: editor.canvasPanOffset.width,
                panY: editor.canvasPanOffset.height,
                viewportSize: geometry.size
            )
            .dsAnimation(DS.Motion.canvasGlide, value: editor.canvasAnimationToken)
            // Publish the viewport size so fit / zoom routines and the
            // AppKit-side hit test share the renderer's transform.
            .onAppear {
                editor.canvasViewportSize = geometry.size
                consumePendingFit()
            }
            .onChange(of: geometry.size) { _, newSize in
                editor.canvasViewportSize = newSize
                consumePendingFit()
            }
            // A bulk insert (File ▸ New from Archetype…) can land a whole
            // sub-network clear to the right of everything the viewport
            // shows. The model raises the flag; only this side knows the
            // viewport size, so only this side can act on it.
            //
            // This is the fast path, NOT the guarantee: this view is the
            // root of the canvas's `NSHostingView`, and its `body` is not
            // re-evaluated on every editor publish (`CanvasContentView`
            // below it is), so the flip can arrive here late or not at
            // all. `NetworkCanvasScrollContainer.Coordinator` subscribes
            // to the same flag through Combine and consumes it there;
            // whichever side reaches it first clears it and the other is
            // a no-op.
            .onChange(of: editor.pendingFitOnAppear) { _, _ in consumePendingFit() }
        }
        .overlay(alignment: .bottomLeading) {
            if editor.numberOfCustomerClasses > 1 {
                CanvasClassLegend()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            CanvasZoomCluster()
        }
        // Empty-canvas hint: an overlay, not a replacement, so the canvas
        // keeps its frame and gestures.  There is no blanket
        // `.allowsHitTesting(false)` here: `DSEmptyState` opts its icon
        // and its two text blocks out individually (see its doc comment,
        // and `CanvasEmptyHint`'s), so a click through the middle of the
        // text still reaches the canvas gesture and places a node, while
        // the buttons stay live.
        .overlay {
            if editor.nodes.isEmpty {
                // Both buttons are offered unconditionally: File ▸ Open
                // Example… and File ▸ New from Archetype… are permanently
                // present in the File menu, and `MenuBarCommand` performs
                // those very items rather than keeping a second copy of
                // either command.  Their existence is deliberately NOT
                // decided by `MenuBarCommand.canPerform`: that reads
                // AppKit menu state from inside a SwiftUI `body`, so the
                // most prominent control on an empty canvas could blink
                // out on an unrelated re-render — and it read `false`
                // while the panel the button opens was up, which is
                // exactly when the user reaches for it again.
                CanvasEmptyHint(
                    onOpenExample: { MenuBarCommand.perform(MenuBarCommand.openExample) },
                    onStartArchetype: { MenuBarCommand.perform(MenuBarCommand.newFromArchetype) }
                )
            }
        }
        .dsAnimation(DS.Motion.quick, value: editor.nodes.isEmpty)
        .dsAnimation(DS.Motion.quick, value: editor.numberOfCustomerClasses > 1)
        .background(DS.Color.surfaceRaised)
    }

    /// One-shot "frame the content" request from the model
    /// (`NetworkEditorModel.pendingFitOnAppear`). Cleared BEFORE the fit so
    /// the re-layout the fit itself provokes cannot run it a second time,
    /// and skipped until the viewport has a real size — `zoomToFit()` is a
    /// no-op below 1 pt and would silently swallow the request.
    private func consumePendingFit() {
        guard editor.pendingFitOnAppear, editor.canvasViewportSize.width > 1 else { return }
        editor.pendingFitOnAppear = false
        editor.zoomToFit()
    }
}

// MARK: - Scene cache

/// Memoises the routed scene on its four inputs.  `CanvasContentView.body`
/// runs on every editor publish (status entries, hover, tool changes…);
/// only a change to the nodes, links, transform or class filter should pay
/// for re-routing every link.  Unchanged arrays compare by buffer identity,
/// so the check is O(1) on the frames that matter.
///
/// The routing half of the work lives one level down, in
/// `editor.routePlan`: which links have to step over which node depends
/// on the drawing alone, so it survives every pan and zoom, and the
/// renderer, the right-click hit test and the diagram export all read
/// the same plan.  What is cached here is the `CanvasScene` built on top
/// of it — plain trigonometry against the current transform.
@MainActor
private final class SceneCache {
    private var nodes: [NetworkNode] = []
    private var links: [NetworkLink] = []
    private var transform = CanvasTransform.identity
    private var classFilter: Int?
    private var routePlan = LinkRoutePlan.empty
    private var cached: CanvasScene?

    /// The plan is part of the key: it is frozen for the length of a
    /// drag, so the release is exactly the frame on which the nodes are
    /// unchanged and the plan is not.
    func scene(nodes: [NetworkNode], links: [NetworkLink],
               transform: CanvasTransform, classFilter: Int?,
               routePlan: LinkRoutePlan) -> CanvasScene {
        if let cached,
           transform == self.transform, classFilter == self.classFilter,
           nodes == self.nodes, links == self.links, routePlan == self.routePlan {
            return cached
        }
        let scene = CanvasScene(nodes: nodes, links: links, transform: transform,
                                classFilter: classFilter, routePlan: routePlan)
        self.nodes = nodes
        self.links = links
        self.transform = transform
        self.classFilter = classFilter
        self.routePlan = routePlan
        self.cached = scene
        return scene
    }
}

// MARK: - Content (animatable on the transform)

private struct CanvasContentView: View, Animatable {
    @EnvironmentObject private var editor: NetworkEditorModel
    @DSAccessibility private var a11y

    // The animatable inputs are plain Sendable values; marking them
    // `nonisolated` lets SwiftUI's animation system interpolate them
    // through the non-isolated `Animatable` conformance.
    nonisolated var scale: CGFloat
    nonisolated var panX: CGFloat
    nonisolated var panY: CGFloat
    let viewportSize: CGSize

    nonisolated var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(scale, AnimatablePair(panX, panY)) }
        set {
            scale = newValue.first
            panX = newValue.second.first
            panY = newValue.second.second
        }
    }

    // Gesture state -------------------------------------------------------
    /// What sat under the pointer when the current canvas drag began,
    /// resolved once on the first `onChanged` instead of hit-testing the
    /// start location on every frame.
    private enum DragOrigin: Equatable {
        case node
        case link(UUID)
        case empty
    }

    @State private var sceneCache = SceneCache()
    /// Node whose drag is in flight (nil for a plain click).
    @State private var dragNodeID: UUID?
    /// Link whose drag is in flight (both endpoints move).
    @State private var dragLinkID: UUID?
    /// World positions of every dragged node at mouse-down; the drag is
    /// anchored on these so a node never jumps to the cursor.
    @State private var dragStartPositions: [UUID: CGPoint] = [:]
    /// Did this drag duplicate before it started carrying (⌥-drag)?  A
    /// duplicating drag is the one drag Escape cannot undo — see
    /// `cancelDragInFlight()`.
    @State private var dragDuplicated = false
    /// Escape cancelled the drag that is still physically in flight: the
    /// mouse is down, so the gesture keeps delivering, and everything it
    /// delivers from here to the release is ignored.  One flag per
    /// gesture, because the node gesture and the canvas gesture both end
    /// on the same mouse-up in an unspecified order and neither may clear
    /// the other's memo before it has been read.
    @State private var nodeDragCancelled = false
    @State private var canvasDragCancelled = false
    /// The Escape monitor, alive only while a drag is cancellable.
    @State private var escapeMonitor: Any?
    @State private var dragOrigin: DragOrigin?
    /// `canvasPanOffset` at the start of a pan drag (Pan tool or Space).
    @State private var panStartOffset: CGSize?
    @State private var lastNodeTapID: UUID?
    @State private var lastNodeTapTime: Date = .distantPast
    @State private var lastLinkTapID: UUID?
    @State private var lastLinkTapTime: Date = .distantPast
    /// Empty-canvas click memo, for the double-click that enters sticky
    /// pan and for suppressing the second placement an add tool would
    /// otherwise make under the first.  The point is in display space:
    /// a double-click cannot pan or zoom between its two halves.
    @State private var lastCanvasTapTime: Date = .distantPast
    @State private var lastCanvasTapPoint: CGPoint?
    /// Node a drag-to-connect started from, for the length of the drag.
    /// Kept in the view (not the model) because it is gesture state: the
    /// model learns about the link only when the drag lands on a target.
    @State private var dragLinkFromID: UUID?
    /// Did that drag ever leave the node it started from?  It is what
    /// separates the self-loop gesture — out and back, the way a loop is
    /// drawn — from a shaky click that never crossed the node's outline.
    @State private var dragLinkLeftSource = false
    /// The same memo for the two-click flow: has the pointer been off the
    /// pending start node since the click that made it pending?  Without
    /// it the click itself would arm a self-loop under the very cursor it
    /// was made with.  Reset whenever the pending start changes.
    @State private var hoverLeftPendingStart = false
    /// Is the pointer back over the node the link is being drawn from,
    /// having once left it — the out-and-back self-loop gesture?  Set by
    /// whichever pointer stream owns the gesture (the drag, or the hover
    /// tracker for the two-click flow), and read by the rubber-band,
    /// which draws the loop arc instead of a line into its own start.
    @State private var pointerOverLinkStart = false
    /// Snapped world position of the pointer while an add-node tool is
    /// active — where the next click will place the node.
    @State private var ghostWorldPoint: CGPoint?
    /// Route-plan transition: the plan the links are easing away from,
    /// and a generation counter the link layer animates towards (see
    /// `AnimatedLinkLayer`).
    @State private var planFrom = LinkRoutePlan.empty
    @State private var planGeneration = 0

    /// The user's System Settings double-click speed.
    private static var doubleClickInterval: TimeInterval { NSEvent.doubleClickInterval }
    /// Escape, the same key code the scroll container reads it by.
    private static let escapeKeyCode: UInt16 = 53
    /// Movement below this (display pt) is a click, not a drag.
    private static let dragThreshold: CGFloat = 2
    /// A link needs a little more travel before it starts moving, so a
    /// slightly shaky click still selects (and cycles) instead of nudging.
    private static let linkDragThreshold: CGFloat = 3
    /// Empty-canvas travel before the Pointer tool shows a rubber-band.
    private static let marqueeThreshold: CGFloat = 5
    /// How far the second click of an empty-canvas double-click may land
    /// from the first (display pt).  Tighter than `marqueeThreshold`, so
    /// a click-and-a-half that was really the start of a marquee cannot
    /// be read as a double-click.
    private static let canvasDoubleClickSlop: CGFloat = 3

    var body: some View { buildBody() }

    /// The frame, built outside a `ViewBuilder` so `QNET_CANVAS_PROFILE=1`
    /// can time the whole thing — scene lookup, layer construction and
    /// the node `ForEach` — and print the end-to-end ms/frame next to the
    /// per-layer numbers.
    private func buildBody() -> some View {
        let t0 = CanvasProfiler.enabled ? CFAbsoluteTimeGetCurrent() : 0
        let transform = CanvasTransform(
            scale: scale,
            pan: CGSize(width: panX, height: panY),
            viewportSize: viewportSize
        )
        let plan = editor.routePlan
        let scene = sceneCache.scene(
            nodes: editor.nodes,
            links: editor.links,
            transform: transform,
            classFilter: editor.classFilter,
            routePlan: plan
        )
        let chainClass: Int? = (editor.selectedTool == .addLink && editor.activeLinkSourceID != nil)
            ? editor.activeCustomerClass : nil
        let linkState = LinkLayerState(
            selectedLinkID: editor.selectedLinkID,
            hoveredLinkID: editor.hoveredLinkID,
            emphasisedClass: chainClass,
            scale: scale
        )
        let marqueeRect = editor.multiSelectRect
        // In the Pan tool — or while Space is held — the whole surface
        // pans, nodes included.
        let isPanSurface = editor.selectedTool == .pan || editor.isSpacePanning
        // The two interactions that run at frame rate.
        let interacting = editor.isDraggingNode || editor.isPanningCanvas

        CanvasProfiler.flushNodeCost(linkCount: scene.links.count, nodeCount: editor.nodes.count)

        let content = ZStack {
            GridCanvas(transform: transform).equatable()
            AnimatedLinkLayer(
                progress: CGFloat(planGeneration),
                generation: planGeneration,
                fromPlan: planFrom,
                toPlan: plan,
                scene: scene,
                links: editor.links,
                classFilter: editor.classFilter,
                state: linkState)
                // Links are painted into one Canvas, which VoiceOver sees
                // as a single opaque image.  Publishing one accessibility
                // element per link — positioned on its own label anchor,
                // so the VoiceOver cursor lands on the arrow — makes them
                // reachable and editable without adding a view to the
                // render tree.  The list is rebuilt whenever this body
                // runs (it formats one description per link), so it is
                // dropped for the length of a node drag or a pan — the two
                // frame-rate interactions — and comes straight back on
                // release; assistive technology has nothing to do with a
                // link while the pointer is dragging it anyway.
                .accessibilityChildren {
                    if !interacting { linkAccessibilityElements(scene: scene) }
                }

            linkPreviewLayer(scene: scene)
            pendingLinkIndicator(scene: scene)
            ghostNode(transform: transform)

            ForEach(editor.nodes) { node in
                nodeView(node, scene: scene, marqueeRect: marqueeRect)
            }
            .allowsHitTesting(!isPanSurface)

            // The guide layer fades in its own container so the fade can
            // never leak onto the node positions that change on the same
            // frame a guide appears.
            ZStack {
                if !editor.activeAlignGuides.isEmpty {
                    AlignmentGuideLayer(guides: editor.activeAlignGuides, transform: transform)
                        .equatable()
                        .transition(.opacity)
                }
            }
            .dsAnimation(DS.Motion.quick, value: editor.activeAlignGuides.isEmpty)
            .allowsHitTesting(false)

            if let rect = marqueeRect {
                marquee(rect, transform: transform)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipped()
        .contentShape(Rectangle())
        .coordinateSpace(name: "canvas")
        .gesture(canvasDrag(scene: scene))
        .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
            updateHover(phase, scene: scene)
        }
        .contextMenu { canvasContextMenu }
        // A new plan (an edit, or the release at the end of a drag):
        // remember the old routes and start the layer easing towards the
        // new ones.  `DS.Motion.quick` is nil under Reduce Motion, so the
        // routes then change in one step like everything else.
        .onChange(of: plan) { old, _ in
            planFrom = old
            withAnimation(DS.Motion.quick) { planGeneration += 1 }
        }
        // A new (or cancelled) pending start begins a new gesture, and
        // the self-loop memo belongs to the old one: the pointer has not
        // yet left *this* node.  Covers Escape, a tool change and the
        // click that starts the next chain alike, because all three run
        // through `pendingLinkStartID`.
        .onChange(of: editor.pendingLinkStartID) { _, _ in
            hoverLeftPendingStart = false
            pointerOverLinkStart = false
        }
        // The Escape monitor lives exactly as long as a cancellable drag,
        // so no other keystroke in the app ever passes through it.
        .onChange(of: dragIsCancellable) { _, cancellable in
            if cancellable { installEscapeMonitor() } else { removeEscapeMonitor() }
        }
        .onDisappear { removeEscapeMonitor() }

        if CanvasProfiler.enabled {
            CanvasProfiler.record(layer: .frame,
                                  drawSeconds: CFAbsoluteTimeGetCurrent() - t0,
                                  linkCount: scene.links.count,
                                  nodeCount: editor.nodes.count)
        }
        return content
    }

    // MARK: Layers

    /// The node a link is currently being drawn from: the drag's own
    /// start while a drag is in flight, otherwise the chain's pending
    /// start from the two-click flow.  One answer for the ring, the
    /// elastic line and the node's own pending emphasis.
    private var linkPreviewStartID: UUID? {
        dragLinkFromID ?? editor.pendingLinkStartID
    }

    /// Colour of everything belonging to the link being drawn: the class
    /// being routed once a source has fixed one, the accent until then.
    private var pendingLinkColor: Color {
        editor.activeLinkSourceID != nil
            ? CustomerClass.color(for: editor.activeCustomerClass)
            : DS.Color.accent
    }

    /// The elastic rubber-band.  Present only while a link is being
    /// drawn and the pointer position is known, so it costs nothing on
    /// any other frame.
    @ViewBuilder
    private func linkPreviewLayer(scene: CanvasScene) -> some View {
        if editor.selectedTool == .addLink,
           let startID = linkPreviewStartID,
           let startNode = scene.nodeIndex[startID],
           let centre = scene.displayCentres[startID],
           let world = editor.pendingLinkPoint {
            // Back over the node the link came from: the release (or the
            // second click) draws a self-loop, so the band draws the arc
            // it would leave behind.  Only a station can have one —
            // `handleLinkSelection` answers a source, buffer or sink with
            // the sentence saying why not — so on those the band stays
            // the plain line into the node and promises nothing.
            let loopsBack = pointerOverLinkStart && startNode.kind == .station
            // The hovered node is the release target.  It is never the
            // start node: the pointer stream that owns the gesture keeps
            // the start node out of `hoveredNodeID` so it is not ringed
            // as a target on top of its own pending ring, and the
            // self-loop above is how it reports itself instead.
            let target = editor.hoveredNodeID
                .flatMap { $0 == startID ? nil : scene.nodeIndex[$0] }
            LinkPreviewCanvas(
                startCentre: centre,
                startKind: startNode.kind,
                pointer: scene.transform.toDisplay(world),
                targetCentre: target.flatMap { scene.displayCentres[$0.id] },
                targetKind: target?.kind,
                selfLoopRadius: loopsBack
                    ? selfLoopPreviewRadius(on: startID, scale: scene.transform.scale)
                    : nil,
                scale: scene.transform.scale,
                color: pendingLinkColor
            )
            .equatable()
        }
    }

    /// Radius offset the self-loop being previewed on `nodeID` would nest
    /// at.  `CanvasScene` pushes each additional loop on a node one bundle
    /// spacing outward (`LinkGeometry.selfLoop(extraRadius:)`), so a
    /// preview drawn at zero would land exactly on the loop already there
    /// and read as "nothing would happen".  Counting every loop on the
    /// node — not only the classes the filter is showing — is the domain
    /// `CanvasScene.bundleGroups` counts in, so the preview keeps its
    /// place when the filter changes.
    private func selfLoopPreviewRadius(on nodeID: UUID, scale: CGFloat) -> CGFloat {
        let existing = editor.links.reduce(into: 0) { count, link in
            if link.fromNodeID == nodeID && link.toNodeID == nodeID { count += 1 }
        }
        return CGFloat(existing) * CanvasScene.bundleSpacing * scale
    }

    @ViewBuilder
    private func pendingLinkIndicator(scene: CanvasScene) -> some View {
        if editor.selectedTool == .addLink,
           let startID = linkPreviewStartID,
           let startNode = scene.nodeIndex[startID],
           let centre = scene.displayCentres[startID] {
            let chainColor = pendingLinkColor
            let s = scene.transform.scale
            let size = NodeOutline.size(for: startNode.kind)
            NodeOutlineShape(kind: startNode.kind,
                             cornerRadius: NodeOutline.sinkCornerRadius * s + 8)
                .stroke(chainColor,
                        style: StrokeStyle(lineWidth: max(1.5, 2 * s),
                                           dash: [6 * max(0.6, s), 4 * max(0.6, s)]))
                .frame(width: size.width * s + 16, height: size.height * s + 16)
                .position(centre)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Faint outline of the node the active add tool would place, sitting
    /// on the snapped grid point under the pointer.
    @ViewBuilder
    private func ghostNode(transform: CanvasTransform) -> some View {
        if let kind = editor.selectedTool.placedNodeKind,
           let world = ghostWorldPoint,
           !editor.isSpacePanning {
            let s = transform.scale
            let size = NodeOutline.size(for: kind)
            let shape = NodeOutlineShape(kind: kind, cornerRadius: NodeOutline.sinkCornerRadius * s)
            shape
                .fill(DS.Color.nodeFill(for: kind))
                .overlay(
                    shape.stroke(DS.Color.nodeStroke,
                                 style: StrokeStyle(lineWidth: max(1, 1.5 * s),
                                                    dash: [4 * max(0.6, s), 3 * max(0.6, s)]))
                )
                .frame(width: size.width * s, height: size.height * s)
                .position(transform.toDisplay(world))
                .opacity(DS.Opacity.disabled)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// One zero-size accessibility element per visible link, carrying the
    /// same description the status bar and tooltips use, its selected
    /// state, and an Edit Parameters action.
    private func linkAccessibilityElements(scene: CanvasScene) -> some View {
        ForEach(scene.links) { item in
            Color.clear
                .frame(width: DS.Layout.accessibilityProbeSize, height: DS.Layout.accessibilityProbeSize)
                .position(item.geometry.labelAnchor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(editor.linkDescription(item.link))
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(editor.selectedLinkID == item.id ? .isSelected : [])
                .accessibilityAction { editor.handleLinkTap(linkID: item.id) }
                .accessibilityAction(named: "Edit Parameters") {
                    editor.openLinkParameterEditor(for: item.id)
                }
                .accessibilityAction(named: "Delete Link") {
                    editor.deleteLink(id: item.id)
                }
        }
    }

    private func nodeView(_ node: NetworkNode, scene: CanvasScene, marqueeRect: CGRect?) -> some View {
        let t0 = CanvasProfiler.enabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if CanvasProfiler.enabled {
                CanvasProfiler.addNodeCost(CFAbsoluteTimeGetCurrent() - t0)
            }
        }
        let isSelected = editor.selectedNodeID == node.id || editor.selectedNodeIDs.contains(node.id)
        let display = scene.displayCentres[node.id] ?? .zero
        return NetworkNodeView(
            node: node,
            scale: scene.transform.scale,
            isSelected: isSelected,
            isHovered: editor.hoveredNodeID == node.id,
            isMarqueeCandidate: marqueeRect.map { CanvasScene.marqueeSelects(node, rect: $0) } ?? false,
            isPendingLinkStart: linkPreviewStartID == node.id,
            infiniteBuffers: editor.infiniteBuffers,
            utilisation: editor.stationUtilisation[node.id],
            contrast: a11y.contrast
        )
        .equatable()
        .position(display)
        .contextMenu { nodeContextMenu(node) }
        .gesture(nodeDrag(node, scene: scene))
    }

    /// Rubber-band rectangle: 1-pt accent stroke over `DS.Color.marqueeFill`
    /// (accent at 8 %), the token defined for exactly this job.
    private func marquee(_ rect: CGRect, transform: CanvasTransform) -> some View {
        let disp = transform.toDisplay(rect)
        return Rectangle()
            .fill(DS.Color.marqueeFill)
            .overlay(Rectangle().stroke(DS.Color.accent, lineWidth: DS.Stroke.hairline(a11y.contrast)))
            .frame(width: max(disp.width, 1), height: max(disp.height, 1))
            .position(x: disp.midX, y: disp.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Hover

    /// Hover follows the tool's semantics: nodes light up only where a
    /// click would act on them (Pointer, Multi-Select, Link); links only
    /// in the Pointer tool; the add-node tools show a placement ghost
    /// instead.  The Link tool's pending start node keeps its dashed ring
    /// alone — no second ring on top of it.
    ///
    /// It is also where the elastic link preview gets its free end: the
    /// hover tracker is the one pointer stream the canvas already runs,
    /// so the two-click flow's preview costs no new event plumbing.  A
    /// drag-to-connect owns the pointer itself (`nodeDrag`), and this
    /// tracker stands down for its duration so the two never disagree
    /// about what is under the cursor.
    private func updateHover(_ phase: HoverPhase, scene: CanvasScene) {
        switch phase {
        case .active(let point):
            // Hover is frozen while a drag is in flight so the cursor and
            // rings do not flicker under the dragged element.
            guard !editor.isDraggingNode, !editor.isPanningCanvas,
                  dragLinkFromID == nil else { return }
            let tool = editor.selectedTool
            let panning = editor.isSpacePanning

            // Free end of the rubber-band, published only while a link
            // start is actually pending — the editor is otherwise idle in
            // that state, so this is the only per-frame publish it makes.
            if !panning, tool == .addLink, editor.pendingLinkStartID != nil {
                let world = CanvasMath.clampWorld(scene.transform.toLogical(point))
                if editor.pendingLinkPoint != world { editor.pendingLinkPoint = world }
            } else if editor.pendingLinkPoint != nil {
                editor.pendingLinkPoint = nil
            }

            if !panning, tool.placedNodeKind != nil {
                let world = editor.snapIfNeeded(CanvasMath.clampWorld(scene.transform.toLogical(point)))
                if ghostWorldPoint != world { ghostWorldPoint = world }
            } else if ghostWorldPoint != nil {
                ghostWorldPoint = nil
            }

            let hoversNodes = !panning && (tool == .select || tool == .multiSelect || tool == .addLink)
            var node = hoversNodes ? scene.hitNode(at: point) : nil
            // `!panning`: with Space held nothing was hit-tested, so the
            // pointer has not been anywhere as far as this memo knows.
            if !panning, tool == .addLink, let startID = editor.pendingLinkStartID {
                // The two-click flow's half of the self-loop gesture: the
                // pointer has to have been off the start node before
                // coming back to it, or the click that set the start
                // would arm a loop under the cursor that made it.  The
                // start node itself stays out of `hoveredNodeID` either
                // way — it already wears the pending ring, and a hover
                // ring on top of that says a second, different thing.
                if node?.id == startID {
                    if hoverLeftPendingStart, !pointerOverLinkStart {
                        pointerOverLinkStart = true
                    }
                    node = nil
                } else {
                    if !hoverLeftPendingStart { hoverLeftPendingStart = true }
                    if pointerOverLinkStart { pointerOverLinkStart = false }
                }
            }
            let link = (!panning && node == nil && tool == .select) ? scene.hitLink(at: point) : nil
            if editor.hoveredNodeID != node?.id { editor.hoveredNodeID = node?.id }
            if editor.hoveredLinkID != link?.id { editor.hoveredLinkID = link?.id }
        case .ended:
            // A drag owns the preview: the pointer leaving the tracker
            // mid-drag must not erase the line it is drawing.
            guard dragLinkFromID == nil else { return }
            if editor.hoveredNodeID != nil { editor.hoveredNodeID = nil }
            if editor.hoveredLinkID != nil { editor.hoveredLinkID = nil }
            if ghostWorldPoint != nil { ghostWorldPoint = nil }
            if editor.pendingLinkPoint != nil { editor.pendingLinkPoint = nil }
            if pointerOverLinkStart { pointerOverLinkStart = false }
        }
    }

    // MARK: Node drag / click

    private func nodeDrag(_ node: NetworkNode, scene: CanvasScene) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                resignTextFocusForCanvasGesture()
                // Escape already put this drag back: the mouse is still
                // down, so the gesture keeps talking and nothing it says
                // is listened to any more.
                if nodeDragCancelled { return }
                // Drag-to-connect: in the Link tool a drag off a node
                // pulls a link out of it, the way every diagram editor
                // draws an arc.  Nothing reaches the model until the
                // release lands on a target, so an abandoned drag leaves
                // the network exactly as it found it.
                if editor.selectedTool == .addLink {
                    if dragLinkFromID == nil {
                        guard CanvasMath.length(value.translation) > Self.dragThreshold else {
                            return
                        }
                        dragLinkFromID = node.id
                        dragLinkLeftSource = false
                        pointerOverLinkStart = false
                    }
                    editor.pendingLinkPoint =
                        CanvasMath.clampWorld(scene.transform.toLogical(value.location))
                    // The hover tracker has stood down for the drag, so
                    // the target ring is published from here — and the
                    // start node never rings itself.
                    let hit = scene.hitNode(at: value.location)
                    let target = hit?.id == node.id ? nil : hit?.id
                    if editor.hoveredNodeID != target { editor.hoveredNodeID = target }
                    if hit?.id != node.id { dragLinkLeftSource = true }
                    // Out and back: once the pointer has left the start
                    // node, returning to it is the self-loop gesture, and
                    // the rubber-band shows the arc rather than a line
                    // doubling back into the node it came from.
                    let overStart = hit?.id == node.id && dragLinkLeftSource
                    if pointerOverLinkStart != overStart { pointerOverLinkStart = overStart }
                    return
                }
                guard editor.selectedTool == .select || editor.selectedTool == .multiSelect else {
                    return
                }
                if dragNodeID == nil {
                    // A click stays a click until the pointer has really
                    // moved; only then does the undo group open.
                    guard CanvasMath.length(value.translation) > Self.dragThreshold else { return }
                    dragNodeID = node.id
                    var group = editor.selectionUnion
                    if !group.contains(node.id) {
                        // Dragging an unselected node makes it the selection
                        // (as mouse-down does in every diagram editor); with
                        // ⇧/⌘ held it joins the existing group instead.
                        if editor.lastMouseDownExtendsSelection {
                            group.insert(node.id)
                        } else {
                            group = [node.id]
                        }
                        editor.setNodeSelection(group)
                        editor.selectedLinkID = nil
                    }
                    // ⌥-drag duplicates, the Mac diagramming convention:
                    // the copies become the selection and are what the
                    // drag carries away — one undo step with the move.
                    let duplicating = editor.lastMouseDownDuplicates
                    editor.beginMutation(Self.dragUndoName(count: group.count,
                                                           duplicating: duplicating))
                    if duplicating {
                        let copies = editor.duplicateSelectionInPlaceForDrag()
                        if !copies.isEmpty {
                            group = copies
                            dragDuplicated = true
                        }
                    }
                    dragStartPositions = Dictionary(
                        uniqueKeysWithValues: editor.nodes
                            .filter { group.contains($0.id) }
                            .map { ($0.id, $0.position) }
                    )
                    editor.isDraggingNode = true
                }
                moveAnchoredNodes(by: value.translation, scale: scene.transform.scale)
            }
            .onEnded { value in
                // The release that ends a cancelled drag means nothing:
                // not a move to commit, not a link to create, and not the
                // click it would otherwise decay into.
                if nodeDragCancelled {
                    nodeDragCancelled = false
                    return
                }
                if dragNodeID != nil {
                    finishNodeMove()
                    return
                }
                if let fromID = dragLinkFromID {
                    let leftSource = dragLinkLeftSource
                    dragLinkFromID = nil
                    dragLinkLeftSource = false
                    pointerOverLinkStart = false
                    editor.pendingLinkPoint = nil
                    let target = scene.hitNode(at: value.location)
                    if editor.hoveredNodeID != target?.id { editor.hoveredNodeID = target?.id }
                    if let target {
                        if target.id != fromID || leftSource {
                            // Out and back onto the start node is how a
                            // self-loop is drawn, and the click path now
                            // creates one too (`handleLinkSelection`):
                            // both gestures go through the same call, so
                            // a station gets its feedback arc and a
                            // source, buffer or sink gets the sentence
                            // saying why it cannot have one.  Either way
                            // the drag is answered rather than ignored.
                            completeLinkDrag(from: fromID, to: target.id)
                        } else {
                            // Never left the node: a shaky click, not a
                            // gesture.  Honour it as the click it was —
                            // silently dropping it is what made a
                            // slightly unsteady hand feel like a dead
                            // canvas.
                            editor.handleNodeTap(nodeID: fromID)
                        }
                    }
                    // Released on empty canvas: the drag is abandoned,
                    // the Mac convention, and the pending chain (if any)
                    // is left exactly as it was.
                    return
                }
                // Plain click.  A double-click in the Select or
                // Multi-Select tool opens the parameter inspector, as in
                // every diagramming app; a modified click only toggles
                // membership.
                let extending = editor.lastMouseDownExtendsSelection
                let now = Date()
                if !extending,
                   editor.selectedTool == .select || editor.selectedTool == .multiSelect,
                   lastNodeTapID == node.id,
                   now.timeIntervalSince(lastNodeTapTime) < Self.doubleClickInterval {
                    lastNodeTapID = nil
                    editor.openParameterEditor(for: node.id)
                    return
                }
                lastNodeTapID = node.id
                lastNodeTapTime = now
                editor.handleNodeTap(nodeID: node.id, extendingSelection: extending)
            }
    }

    /// Lands a drag-to-connect by replaying the two-click flow: the same
    /// `handleNodeTap` calls, in the same order, so the candidate-class
    /// rules, the refusal to repeat a pair and the chain continuation are
    /// one implementation and the status log reads identically.
    ///
    /// A chain part-built from some other node is dropped first — the
    /// drag names its own start, and without the reset the tap on `from`
    /// would be read as the CLOSE of that chain and link the wrong pair.
    private func completeLinkDrag(from: UUID, to: UUID) {
        if editor.pendingLinkStartID != from {
            editor.pendingLinkStartID = nil
            editor.handleNodeTap(nodeID: from)
            // The start tap opens the chain on `from` or it does nothing
            // we can build on; either way, replaying the second tap after
            // a refusal would be read as a fresh FIRST click and leave the
            // target ringed with a "Link start:" line the drag never asked
            // for.  Today the first tap always takes, and this guard is
            // what keeps that an implementation detail of the model rather
            // than a promise the canvas silently depends on.
            guard editor.pendingLinkStartID == from else { return }
        }
        editor.handleNodeTap(nodeID: to)
    }

    /// Undo-step name for a node drag, so the Edit menu reads
    /// "Undo Duplicate and Move Nodes" after an ⌥-drag of a group.
    private static func dragUndoName(count: Int, duplicating: Bool) -> String {
        let noun = count > 1 ? "Nodes" : "Node"
        return duplicating ? "Duplicate and Move \(noun)" : "Move \(noun)"
    }

    /// Anchor on the mouse-down positions: world delta = display
    /// translation / scale, applied to every anchored node.  Shared by the
    /// node-group drag and the link drag.
    ///
    /// Before the delta is applied it is offered to `SmartGuides`, which
    /// pulls the dragged node into line with a neighbour's edge or centre
    /// (or into equal spacing with its two nearest neighbours) when it
    /// comes within 4 display points, and publishes the guides so
    /// `AlignmentGuideLayer` can draw them.  With Snap to Grid on, the
    /// grid is offered the same position and, axis by axis, the nearer of
    /// the two candidates wins — so a file whose nodes sit off the grid
    /// can still be lined up with them.  The group moves rigidly by the
    /// resolved delta (the dragged node lands on the guide or the grid;
    /// its companions keep their offsets), which is why the model's own
    /// per-node snap is bypassed here.
    ///
    /// ⌃ held during the drag is the "put it exactly here" override: no
    /// guides and no grid until it is released.
    private func moveAnchoredNodes(by translation: CGSize, scale s: CGFloat) {
        var delta = CGSize(width: translation.width / s, height: translation.height / s)
        let suspended = Self.snappingSuspended
        if editor.snapSuspended != suspended { editor.snapSuspended = suspended }

        var guides = SmartGuides.Match.none
        if !suspended,
           let anchorID = dragNodeID ?? dragStartPositions.keys.first,
           let anchorNode = editor.node(with: anchorID),
           let start = dragStartPositions[anchorID] {
            let size = NodeOutline.size(for: anchorNode.kind)
            let centre = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
            let candidate = CGRect(x: centre.x - size.width / 2,
                                   y: centre.y - size.height / 2,
                                   width: size.width, height: size.height)
            let others = editor.nodes
                .filter { dragStartPositions[$0.id] == nil }
                .map { CanvasScene.nodeWorldRect($0) }
            guides = SmartGuides.match(anchor: candidate, others: others,
                                       tolerance: SmartGuides.tolerance / max(s, 0.01))
            var adjust = guides.adjustment
            if editor.snapToGrid {
                let snapped = editor.snapIfNeeded(centre)
                let grid = CGSize(width: snapped.x - centre.x, height: snapped.y - centre.y)
                let guideX = guides.x != nil || guides.xSpacing != nil
                let guideY = guides.y != nil || guides.ySpacing != nil
                if !guideX || abs(grid.width) <= abs(adjust.width) {
                    adjust.width = grid.width
                    guides.dropX()
                }
                if !guideY || abs(grid.height) <= abs(adjust.height) {
                    adjust.height = grid.height
                    guides.dropY()
                }
            }
            if guides.isEmpty {
                guides = .none
            } else {
                guides.anchor = candidate.offsetBy(dx: adjust.width, dy: adjust.height)
            }
            delta.width += adjust.width
            delta.height += adjust.height
        }
        if editor.activeAlignGuides != guides { editor.activeAlignGuides = guides }

        for (id, start) in dragStartPositions {
            editor.moveNode(
                id: id,
                to: CanvasMath.clampWorld(CGPoint(x: start.x + delta.width,
                                                  y: start.y + delta.height)),
                snap: false
            )
        }
    }

    /// ⌃ held during a drag suspends Snap to Grid and the alignment
    /// guides.  Read live (not from mouse-down) so the user can press and
    /// release it mid-drag and watch the node come off the grid.  ⌃ and
    /// not ⌘: ⌘ at mouse-down extends the selection, and one key must
    /// not mean two things inside one drag; a ⌃-mouse-down is a context
    /// click, so it can never start a drag of its own.
    private static var snappingSuspended: Bool {
        NSEvent.modifierFlags.contains(.control)
    }

    /// Is there a drag Escape could put back right now?  Drives the
    /// lifetime of the Escape monitor, so it exists for the length of a
    /// drag and costs nothing — and intercepts nothing — the rest of the
    /// time.
    private var dragIsCancellable: Bool {
        dragLinkFromID != nil || dragLinkID != nil || (dragNodeID != nil && !dragDuplicated)
    }

    /// Escape during a drag puts the canvas back the way it was found.
    ///
    /// The start positions are restored BEFORE the undo group is closed,
    /// and that is what keeps the Edit menu clean: `endMutation` compares
    /// the network with the snapshot `beginMutation` took and registers
    /// nothing when they are equal, so a cancelled drag closes its group
    /// rather than committing it and leaves no "Undo Move Nodes" behind.
    ///
    /// An ⌥-drag is deliberately NOT cancellable.  It has already made the
    /// copies it is carrying, and putting those back where they came from
    /// would stack a second, invisible node on every original — the exact
    /// corruption a cancel exists to prevent.  Removing them again needs a
    /// model call that discards the pending snapshot, which
    /// `NetworkEditorModel` does not have (`deleteSelection` would open an
    /// undo entry of its own inside the group); until it does, Escape
    /// keeps its other meaning there and the drag is abandoned by
    /// releasing it where it started, or undone after the fact.
    ///
    /// Returns true when something was actually cancelled, which is also
    /// the monitor's answer to "swallow this Escape?".
    @MainActor
    @discardableResult
    private func cancelDragInFlight() -> Bool {
        // A link being drawn holds no model state at all: dropping the
        // gesture's own memo is the whole cancel, and the release then
        // finds no drag in flight and creates nothing.
        if dragLinkFromID != nil {
            dragLinkFromID = nil
            dragLinkLeftSource = false
            pointerOverLinkStart = false
            editor.pendingLinkPoint = nil
            if editor.hoveredNodeID != nil { editor.hoveredNodeID = nil }
            nodeDragCancelled = true
            return true
        }
        guard !dragStartPositions.isEmpty, !dragDuplicated else { return false }
        for (id, start) in dragStartPositions {
            editor.moveNode(id: id, to: start, snap: false)
        }
        editor.endMutation()
        editor.isDraggingNode = false
        if editor.snapSuspended { editor.snapSuspended = false }
        if !editor.activeAlignGuides.isEmpty { editor.activeAlignGuides = .none }
        // The gesture that owns the drag is the one that must ignore the
        // rest of it: a node drag is the node's own gesture, a link drag
        // the canvas-level one.
        if dragNodeID != nil { nodeDragCancelled = true } else { canvasDragCancelled = true }
        dragNodeID = nil
        dragLinkID = nil
        dragDuplicated = false
        dragStartPositions.removeAll()
        return true
    }

    /// Escape has to reach the canvas before the scroll container turns it
    /// into Deselect All (`NetworkCanvasScrollContainer`, key code 53), and
    /// a local monitor sees a key event before it is dispatched to the
    /// responder chain.  So this is the one place that can give Escape a
    /// second meaning without taking its first one away: it swallows the
    /// key only when a drag was really cancelled and passes it straight
    /// through on every other press.
    ///
    /// The handler is a non-Sendable closure formed in a @MainActor
    /// context, so it inherits main-actor isolation; local monitors always
    /// run on the main thread.
    @MainActor
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            // ⌘. and friends are not this gesture's business.
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
            guard mods.isEmpty else { return event }
            return cancelDragInFlight() ? nil : event
        }
    }

    @MainActor
    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func finishNodeMove() {
        editor.endMutation()
        editor.isDraggingNode = false
        if editor.snapSuspended { editor.snapSuspended = false }
        if !editor.activeAlignGuides.isEmpty { editor.activeAlignGuides = .none }
        dragNodeID = nil
        dragLinkID = nil
        dragDuplicated = false
        dragStartPositions.removeAll()
    }

    // MARK: Canvas drag (pan / marquee / link / tap)

    private func resolveDragOrigin(at start: CGPoint, scene: CanvasScene) -> DragOrigin {
        if scene.hitNode(at: start) != nil { return .node }
        if let link = scene.hitLink(at: start) { return .link(link.id) }
        return .empty
    }

    private var isPanGesture: Bool {
        editor.selectedTool == .pan || editor.isSpacePanning || panStartOffset != nil
    }

    /// A canvas gesture must take keyboard focus away from any text field
    /// that still owns it, or ⌘Z / ⌘X / ⌘C keep going to an invisible
    /// search box for the rest of the session (blocker R5, W5-INT-1).
    ///
    /// `CanvasClipView.mouseDown` carries the same three lines and cannot
    /// do the job on its own: the SwiftUI hosting view above it consumes
    /// the event, so that override never runs for a canvas click. This is
    /// where the click actually arrives. The `is NSText` guard makes the
    /// common case two property reads, so it is cheap enough to sit at the
    /// head of a drag handler; SwiftUI can hand the field editor straight
    /// back, which is why the responder is cleared explicitly afterwards.
    private func resignTextFocusForCanvasGesture() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
        window.endEditing(for: nil)
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
    }

    private func canvasDrag(scene: CanvasScene) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                resignTextFocusForCanvasGesture()
                // Escape put this drag back; the rest of it is noise.
                if canvasDragCancelled { return }
                if isPanGesture {
                    panChanged(value)
                    return
                }
                if dragOrigin == nil {
                    dragOrigin = resolveDragOrigin(at: value.startLocation, scene: scene)
                }
                let tool = editor.selectedTool
                let dragPx = CanvasMath.length(value.translation)

                switch dragOrigin {
                case .node, .none:
                    // The node's own gesture owns this drag.
                    return

                case .link(let linkID):
                    guard tool == .select else { return }
                    if dragLinkID == nil {
                        // Dragging a link moves both endpoints live, as one
                        // undoable step; it selects the link but never
                        // cycles its class the way a repeated click does.
                        guard dragPx > Self.linkDragThreshold,
                              let link = editor.link(with: linkID),
                              let from = editor.node(with: link.fromNodeID),
                              let to = editor.node(with: link.toNodeID)
                        else { return }
                        dragLinkID = linkID
                        dragStartPositions = [from.id: from.position, to.id: to.position]
                        if editor.selectedLinkID != linkID {
                            editor.selectedLinkID = linkID
                            editor.selectedNodeID = nil
                            editor.selectedNodeIDs = []
                        }
                        editor.beginMutation("Move Link")
                        editor.isDraggingNode = true
                    }
                    moveAnchoredNodes(by: value.translation, scale: scene.transform.scale)

                case .empty:
                    // A rubber-band appears for any empty-canvas drag in
                    // Select or Multi-Select.  Select needs a small
                    // threshold so a plain click (place node / clear
                    // selection) still fires cleanly; Multi-Select starts
                    // on press.
                    let canRubberBand = tool == .multiSelect
                        || (tool == .select && dragPx > Self.marqueeThreshold)
                    guard canRubberBand else { return }
                    if editor.multiSelectOrigin == nil {
                        editor.beginMultiSelect(at: scene.transform.toLogical(value.startLocation))
                    }
                    editor.updateMultiSelect(to: scene.transform.toLogical(value.location))
                }
            }
            .onEnded { value in
                defer { dragOrigin = nil }
                // A cancelled link drag ends on the same mouse-up it was
                // cancelled during: the release commits nothing and does
                // not decay into a click on the link either.
                if canvasDragCancelled {
                    canvasDragCancelled = false
                    return
                }
                if isPanGesture {
                    panEnded(value)
                    return
                }
                let origin = dragOrigin ?? resolveDragOrigin(at: value.startLocation, scene: scene)
                let tool = editor.selectedTool
                let extending = editor.lastMouseDownExtendsSelection

                if origin == .node { return }

                if case .link(let linkID) = origin {
                    if dragLinkID != nil {
                        finishNodeMove()
                        return
                    }
                    if tool == .select {
                        // Double-click opens the link inspector; a slow
                        // second click still cycles the class.
                        let now = Date()
                        if lastLinkTapID == linkID,
                           now.timeIntervalSince(lastLinkTapTime) < Self.doubleClickInterval {
                            lastLinkTapID = nil
                            lastLinkTapTime = .distantPast
                            editor.openLinkParameterEditor(for: linkID)
                            return
                        }
                        lastLinkTapID = linkID
                        lastLinkTapTime = now
                        editor.handleLinkTap(linkID: linkID)
                        return
                    }
                    // Other tools treat a link like empty canvas below.
                }

                // Multi-Select opens its rubber-band on press with no
                // threshold, so EVERY plain click in that tool arrives
                // here holding a zero-area rect.  Committing it would eat
                // the click before the double-click test below — which is
                // what put sticky pan out of reach in the one other tool
                // that is documented to offer it.  A band with no area is
                // a click: discard it and let the shared click path
                // below decide what the click meant, so Pointer and
                // Multi-Select answer a click the same way.
                if let rect = editor.multiSelectRect {
                    if rect.width > 0 || rect.height > 0 {
                        editor.finalizeMultiSelect(extending: extending)
                        return
                    }
                    // Cleared, not `clearMultiSelection()`: that also
                    // drops the selection, and a ⇧-click must leave the
                    // group the user is building alone.
                    editor.multiSelectRect = nil
                    editor.multiSelectOrigin = nil
                }

                // ⇧/⌘-click on empty canvas leaves the selection alone —
                // the user is building a group, not abandoning it.
                if extending, tool == .select || tool == .multiSelect { return }

                // Empty canvas.  Two gestures share this one click, so
                // the memo is kept here rather than in either of them.
                let location = value.location
                let world = editor.snapIfNeeded(
                    CanvasMath.clampWorld(scene.transform.toLogical(location)))
                let previous = lastCanvasTapPoint
                let now = Date()
                let inDoubleClickWindow =
                    now.timeIntervalSince(lastCanvasTapTime) < Self.doubleClickInterval
                // The two branches below ask different questions of the
                // same pair of clicks, so they get different tests.
                // Sticky pan asks "was that ONE double-click?", and only
                // a tight display-space cap answers it: a click and a
                // half that was really the start of a marquee must not
                // hand the canvas to the hand.  An add tool asks "would
                // the second node land under the first?", which is a
                // question about the placement point, not the pointer —
                // with Snap to Grid on, two clicks a whole cell apart in
                // display space resolve to one grid point, and with it
                // off, two clicks inside the cap overlap even though
                // their world points differ by a hair.  Sharing one test
                // left the original double-placement bug reachable from
                // any trackpad double-click that wandered 4 pt.
                let nearPreviousClick = previous.map {
                    CanvasMath.distance($0, location) <= Self.canvasDoubleClickSlop
                } ?? false
                // Refreshed on every empty-canvas click, suppressed ones
                // included, so a rapid triple-click is still one
                // placement rather than two.
                lastCanvasTapTime = now
                lastCanvasTapPoint = location

                if inDoubleClickWindow {
                    switch tool {
                    case .select, .multiSelect:
                        // Sticky pan.  The first click has already
                        // deselected and cleared the class filter — a
                        // double-click on empty canvas had nothing else
                        // to undo — and the next single click, wherever
                        // it lands, brings this tool back (`panEnded`).
                        guard nearPreviousClick else { break }
                        lastCanvasTapPoint = nil
                        editor.enterStickyPan()
                        return
                    case .addStation, .addBuffer, .addSource, .addSink:
                        // Without this the second click of a
                        // double-click places a second node on the same
                        // snapped point, invisible under the first.
                        // A second click that lands on a DIFFERENT
                        // placement point and outside the cap is a
                        // deliberate second node and is allowed through,
                        // however fast it came.
                        if let previous {
                            let previousWorld = editor.snapIfNeeded(
                                CanvasMath.clampWorld(scene.transform.toLogical(previous)))
                            if previousWorld == world || nearPreviousClick { return }
                        }
                    case .pan, .addLink:
                        // A Pan-tool click never reaches here (it is a
                        // pan gesture, and ends in `panEnded`), and the
                        // Link tool's empty-canvas click just cancels a
                        // pending chain — twice is once.
                        break
                    }
                }

                editor.handleCanvasTap(at: world)
            }
    }

    private func panChanged(_ value: DragGesture.Value) {
        if panStartOffset == nil {
            panStartOffset = editor.canvasPanOffset
            editor.isPanningCanvas = true
        }
        if let start = panStartOffset {
            // Deliberately unclamped: the user may drag the network out of
            // frame and bring it back; the scrollers track the overflow.
            editor.canvasPanOffset = CGSize(
                width: start.width + value.translation.width,
                height: start.height + value.translation.height
            )
        }
    }

    /// A pan *drag* only ever moves the view, so a user who is panning
    /// keeps the hand for as long as they keep dragging.
    ///
    /// A pan *click* is where sticky pan ends: every click in the Pan
    /// tool arrives here (`isPanGesture` is true from mouse-down, and
    /// the nodes stop taking hits while the whole surface pans), so this
    /// is the one place that can hear "a single click anywhere".  It
    /// restores the tool the double-click interrupted, and does nothing
    /// at all when the Pan tool was chosen deliberately —
    /// `exitStickyPan()` is a no-op unless `enterStickyPan()` armed it.
    private func panEnded(_ value: DragGesture.Value) {
        panStartOffset = nil
        editor.isPanningCanvas = false
        if CanvasMath.length(value.translation) <= Self.dragThreshold {
            editor.exitStickyPan()
        }
    }

    // MARK: Context menus

    /// Right-click on empty canvas or on a link.  The clip view records
    /// the link under the right-click (`contextMenuLinkID`); hover is the
    /// fallback for keyboard-driven menus.
    /// Right-click menus carry no `.keyboardShortcut`.  Every command
    /// here is also in the menu bar, which already owns and displays its
    /// key equivalent; repeating it in a contextual menu would register a
    /// second, competing equivalent that `MenuShortcutAudit` cannot see —
    /// and a menu that prints a key beside one row and a blank beside the
    /// next reads unfinished.  Titles are copied verbatim from the menu
    /// bar so the same command never wears two names.
    @ViewBuilder
    private var canvasContextMenu: some View {
        if let linkID = editor.contextMenuLinkID ?? editor.hoveredLinkID,
           let link = editor.link(with: linkID) {
            linkContextMenu(link)
        } else {
            Button("Paste") { editor.pasteSelection() }
                .disabled(!editor.canPaste)
            Button("Duplicate Selection") { editor.duplicateSelection() }
                .disabled(editor.selectionUnion.isEmpty)
            Divider()
            Button("Select All") { editor.selectAll() }
                .disabled(editor.nodes.isEmpty)
            Button("Deselect All") { editor.deselectAll() }
                .disabled(!editor.hasAnySelection)
            Divider()
            Button("Zoom to Fit") { editor.zoomToFit() }
                .disabled(editor.nodes.isEmpty)
            Button("Zoom to Selection") { editor.zoomToFitSelection() }
                .disabled(!editor.canZoomToSelection)
            Button("Actual Size") { editor.resetZoom() }
            Divider()
            Toggle("Snap to Grid", isOn: Binding(
                get: { editor.snapToGrid },
                set: { editor.snapToGrid = $0 }
            ))
        }
    }

    @ViewBuilder
    private func linkContextMenu(_ link: NetworkLink) -> some View {
        // Same command, same title and same key as Edit ▸ Edit Parameters…
        // (⌘I) — HIG asks a contextual menu to mirror the menu bar,
        // and the key equivalent is declared there.
        Button("Edit Parameters…") {
            editor.openLinkParameterEditor(for: link.id)
        }

        // Pickers inside a menu become submenus with native check marks;
        // rows are `ClassChip`s so the swatch matches every other place a
        // class is named.
        if editor.numberOfCustomerClasses > 1 {
            Picker("Customer Class", selection: Binding(
                get: { link.customerClass },
                set: { editor.updateLinkCustomerClass(linkID: link.id, customerClass: $0) }
            )) {
                ForEach(0..<editor.numberOfCustomerClasses, id: \.self) { classIdx in
                    ClassChip(classIndex: classIdx).tag(classIdx)
                }
            }
        }

        // Phase 1 feedback: jobs can change class as they traverse a
        // link. "Same as entry" clears the transition (nil). Existing
        // classes plus one "next" slot so the user can promote a link to a
        // brand-new derived class.
        let choiceMax = max(editor.numberOfCustomerClasses, 1) + 1
        Picker("Exit Class", selection: Binding<Int?>(
            get: { link.toCustomerClass },
            set: { editor.updateLinkExitClass(linkID: link.id, exitClass: $0) }
        )) {
            Text("Same as entry (\(CustomerClass.label(for: link.customerClass)))")
                .tag(Optional<Int>.none)
            Divider()
            ForEach(0..<choiceMax, id: \.self) { classIdx in
                ClassChip(classIndex: classIdx).tag(Optional(classIdx))
            }
        }

        Divider()

        Button("Delete Link", role: .destructive) {
            editor.deleteLink(id: link.id)
        }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: NetworkNode) -> some View {
        // Multi-selection actions: shown only when the right-clicked node
        // is part of a ≥2-node selection.  These operate on the group.
        if editor.selectedNodeIDs.count >= 2 && editor.selectedNodeIDs.contains(node.id) {
            Button("Align Top") { editor.alignSelectedNodesTop() }
            Button("Align Vertical Centres") { editor.alignSelectedNodesVerticalCentres() }
            Button("Align Bottom") { editor.alignSelectedNodesBottom() }
            Button("Align Left") { editor.alignSelectedNodesLeft() }
            Button("Align Horizontal Centres") { editor.alignSelectedNodesHorizontalCentres() }
            Button("Align Right") { editor.alignSelectedNodesRight() }
            Button("Distribute Horizontally") { editor.distributeSelectedNodesHorizontally() }
            Button("Distribute Vertically") { editor.distributeSelectedNodesVertically() }
            Divider()
        }

        // Clipboard actions — always available. When the right-clicked
        // node isn't already in the selection, make it the sole
        // selection first so the operation acts on it.
        Button(copyLabel(for: node.id)) {
            ensureInSelection(node.id)
            editor.copySelection()
        }
        Button(cutLabel(for: node.id)) {
            ensureInSelection(node.id)
            editor.cutSelection()
        }
        Button(duplicateLabel(for: node.id)) {
            ensureInSelection(node.id)
            editor.duplicateSelection()
        }
        Button("Paste") { editor.pasteSelection() }
            .disabled(!editor.canPaste)

        Divider()

        // Same command and same title as Edit ▸ Edit Parameters… (⌘I).
        Button("Edit Parameters…") {
            editor.openParameterEditor(for: node.id)
        }

        Divider()

        Button("Delete \(node.kind.displayName)", role: .destructive) {
            editor.deleteNode(id: node.id)
        }
    }

    /// If the right-clicked node isn't already in the current selection,
    /// switch the selection to just that node so Copy / Cut / Duplicate
    /// apply to it.  A node inside a multi-selection keeps the group.
    private func ensureInSelection(_ id: UUID) {
        if editor.selectedNodeIDs.contains(id) { return }
        if editor.selectedNodeID == id { return }
        editor.selectedNodeIDs = []
        editor.selectedNodeID = id
    }

    private func copyLabel(for id: UUID) -> String {
        let n = selectionSize(including: id)
        return n >= 2 ? "Copy (\(n) nodes)" : "Copy"
    }

    private func cutLabel(for id: UUID) -> String {
        let n = selectionSize(including: id)
        return n >= 2 ? "Cut (\(n) nodes)" : "Cut"
    }

    private func duplicateLabel(for id: UUID) -> String {
        let n = selectionSize(including: id)
        return n >= 2 ? "Duplicate (\(n) nodes)" : "Duplicate"
    }

    /// Count of the selection a right-click action would operate on —
    /// the existing multi-selection (when the clicked node is in it) or 1.
    private func selectionSize(including id: UUID) -> Int {
        if editor.selectedNodeIDs.contains(id) {
            return editor.selectedNodeIDs.count
        }
        return 1
    }
}

// MARK: - Animated link layer

/// The link layer with its route plan eased between generations.
///
/// `progress` is the animatable input: the parent bumps `generation` (an
/// `Int`, applied at once) inside `withAnimation`, and SwiftUI carries
/// `progress` from the old generation to the new over the animation, so
/// `t = progress − (generation − 1)` runs 0 → 1.  Between 0 and 1 the
/// layer draws a scene built on `LinkRoutePlan.interpolated`; at 1 it
/// hands straight through to the memoised scene the parent already built,
/// so a frame with no transition in flight costs nothing extra and the
/// `Equatable` link canvas still skips its redraw.  A transition costs a
/// plan interpolation (0.03 ms at 400 links) and a scene build (0.3 ms)
/// per frame for the 150 ms it lasts.
private struct AnimatedLinkLayer: View, Animatable {
    nonisolated var progress: CGFloat
    let generation: Int
    let fromPlan: LinkRoutePlan
    let toPlan: LinkRoutePlan
    /// The scene the parent built on `toPlan`.
    let scene: CanvasScene
    /// Every link (not just the visible ones) so a blended scene bundles
    /// siblings exactly as the real one does.
    let links: [NetworkLink]
    let classFilter: Int?
    let state: LinkLayerState

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(max(progress - CGFloat(generation - 1), 0), 1)
        if t >= 1 || fromPlan == toPlan {
            LinkLayerCanvas(scene: scene, state: state).equatable()
        } else {
            let blended = LinkRoutePlan.interpolated(from: fromPlan, to: toPlan, t: t)
            LinkLayerCanvas(
                scene: CanvasScene(nodes: scene.nodes, links: links,
                                   transform: scene.transform, classFilter: classFilter,
                                   routePlan: blended),
                state: state)
                .equatable()
        }
    }
}

// MARK: - Tool helpers

private extension EditorTool {
    /// The node kind an add tool places, nil for every other tool.
    var placedNodeKind: NodeKind? {
        switch self {
        case .addStation: return .station
        case .addBuffer:  return .buffer
        case .addSource:  return .source
        case .addSink:    return .sink
        case .select, .multiSelect, .pan, .addLink: return nil
        }
    }
}
