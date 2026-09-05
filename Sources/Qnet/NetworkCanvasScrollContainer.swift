import SwiftUI
import AppKit
import Combine

/// Wraps `NetworkCanvasView` in the same AppKit frame the Interactive
/// Shell uses: an `NSView` container holding the canvas in a clip view,
/// a legacy-style vertical `NSScroller` on the right, a legacy-style
/// horizontal `NSScroller` on the bottom, and a small corner filler.
/// Every piece is laid out with AutoLayout — identical to
/// `SwiftTermView` — so the scrollers render exactly the same
/// always-visible / grayed-when-inactive legacy appearance.
struct NetworkCanvasScrollContainer: NSViewRepresentable {
    @EnvironmentObject private var editor: NetworkEditorModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)

        // ── Canvas (SwiftUI) inside a clip view ─────────────────────
        let clip = CanvasClipView(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.postsFrameChangedNotifications = true

        let hosting = NSHostingView(
            rootView: AnyView(NetworkCanvasView().environmentObject(editor))
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: clip.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])

        // ── Scrollers ───────────────────────────────────────────────
        let scrollerW = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

        let vScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: scrollerW, height: 100))
        vScroller.scrollerStyle = .legacy
        vScroller.knobProportion = 1.0
        vScroller.doubleValue = 0
        vScroller.isEnabled = false
        vScroller.target = context.coordinator
        vScroller.action = #selector(Coordinator.vScrollerChanged(_:))
        vScroller.setAccessibilityLabel("Canvas vertical scroller")

        let hScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: scrollerW))
        hScroller.scrollerStyle = .legacy
        hScroller.knobProportion = 1.0
        hScroller.doubleValue = 0
        hScroller.isEnabled = false
        hScroller.target = context.coordinator
        hScroller.action = #selector(Coordinator.hScrollerChanged(_:))
        hScroller.setAccessibilityLabel("Canvas horizontal scroller")

        let corner = NSView(frame: .zero)
        corner.wantsLayer = true
        corner.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        [clip, vScroller, hScroller, corner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            clip.topAnchor.constraint(equalTo: container.topAnchor),
            clip.trailingAnchor.constraint(equalTo: vScroller.leadingAnchor),
            clip.bottomAnchor.constraint(equalTo: hScroller.topAnchor),

            vScroller.topAnchor.constraint(equalTo: container.topAnchor),
            vScroller.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vScroller.bottomAnchor.constraint(equalTo: hScroller.topAnchor),
            vScroller.widthAnchor.constraint(equalToConstant: scrollerW),

            hScroller.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hScroller.trailingAnchor.constraint(equalTo: vScroller.leadingAnchor),
            hScroller.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hScroller.heightAnchor.constraint(equalToConstant: scrollerW),

            corner.leadingAnchor.constraint(equalTo: vScroller.leadingAnchor),
            corner.topAnchor.constraint(equalTo: hScroller.topAnchor),
            corner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            corner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.bind(
            editor: editor,
            clipView: clip,
            hostingView: hosting,
            vScroller: vScroller,
            hScroller: hScroller
        )

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // When the user switches tabs, the SwiftUI parent feeds us a
        // different NetworkEditorModel. Rebind the coordinator (which
        // swaps its Combine subscriptions) and replace the hosting
        // view's root so the canvas reflects the new tab.
        context.coordinator.rebindIfNeeded(to: editor)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var editor: NetworkEditorModel?
        weak var clipView: CanvasClipView?
        weak var hostingView: NSHostingView<AnyView>?
        weak var vScroller: NSScroller?
        weak var hScroller: NSScroller?
        private var cancellables: Set<AnyCancellable> = []
        private var frameObserver: NSObjectProtocol?

        func bind(
            editor: NetworkEditorModel,
            clipView: CanvasClipView,
            hostingView: NSHostingView<AnyView>,
            vScroller: NSScroller,
            hScroller: NSScroller
        ) {
            self.clipView = clipView
            self.hostingView = hostingView
            self.vScroller = vScroller
            self.hScroller = hScroller

            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

            rebindIfNeeded(to: editor)
        }

        /// Swaps the tracked editor (tab switch) and re-subscribes all
        /// Combine publishers to the new model. Also replaces the hosting
        /// view's root view so the embedded `NetworkCanvasView` sees the
        /// new editor as its `@EnvironmentObject`.
        func rebindIfNeeded(to newEditor: NetworkEditorModel) {
            if editor === newEditor { return }
            editor = newEditor

            cancellables.removeAll()

            // Scroller metrics depend on nodes + zoom + pan.  `nodes`
            // publishes on every drag frame, so the three streams are
            // merged and throttled to display-link cadence (~16 ms) —
            // one refresh per frame at most, never one per publish.
            let geometryChanged = Publishers.Merge3(
                newEditor.$nodes.map { _ in () },
                newEditor.$canvasScale.map { _ in () },
                newEditor.$canvasPanOffset.map { _ in () }
            )
            geometryChanged
                .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                .store(in: &cancellables)

            // Cursor state: tool, hovered element, and the pan / node-drag
            // flags.  The clip view is the sole owner of the cursor.
            let cursorChanged = Publishers.MergeMany([
                newEditor.$selectedTool.map { _ in () }.eraseToAnyPublisher(),
                newEditor.$hoveredNodeID.map { _ in () }.eraseToAnyPublisher(),
                newEditor.$hoveredLinkID.map { _ in () }.eraseToAnyPublisher(),
                newEditor.$isPanningCanvas.map { _ in () }.eraseToAnyPublisher(),
                newEditor.$isDraggingNode.map { _ in () }.eraseToAnyPublisher(),
                newEditor.$isSpacePanning.map { _ in () }.eraseToAnyPublisher(),
            ])
            cursorChanged
                .sink { [weak self] _ in
                    Task { @MainActor in self?.clipView?.refreshCursor() }
                }
                .store(in: &cancellables)

            // One-shot "frame what was just inserted" request.  A bulk
            // insert (File ▸ New from Archetype…) raises
            // `pendingFitOnAppear`; only this side knows the viewport, so
            // only this side can act on it.  It is consumed HERE rather
            // than from a `.onChange` in `NetworkCanvasView` because that
            // view is the root of `hostingView`, and its `body` is not
            // re-evaluated on every editor publish — the content view
            // below it is, which is why the inserted nodes appear while
            // the fit never runs.  A Combine sink sees the publish itself,
            // so it cannot be missed, and `@Published` re-publishes even
            // when the flag was already true.
            newEditor.$pendingFitOnAppear
                .filter { $0 }
                .sink { [weak self] _ in
                    // `@Published` fires from `willSet`, so the property
                    // itself is read one turn later, holding the new value.
                    Task { @MainActor in self?.consumePendingFit() }
                }
                .store(in: &cancellables)

            hostingView?.rootView = AnyView(
                NetworkCanvasView().environmentObject(newEditor)
            )
            clipView?.editor = newEditor
            clipView?.refreshCursor()

            refresh()
        }

        /// Consumes `NetworkEditorModel.pendingFitOnAppear`.  The flag is
        /// cleared BEFORE the fit so the re-layout the fit itself provokes
        /// cannot run it a second time, and the fit is skipped until the
        /// viewport has a real size — `zoomToFit()` is a no-op below 1 pt
        /// and would silently swallow the request.  Mirrors
        /// `NetworkCanvasView.consumePendingFit()`: whichever side reaches
        /// the flag first clears it and the other becomes a no-op.
        private func consumePendingFit() {
            guard let editor, editor.pendingFitOnAppear else { return }
            // The canvas publishes the viewport from its `GeometryReader`.
            // The clip view is that same rectangle (the hosting view is
            // pinned to its four edges), so it stands in when a fit is
            // asked for before the first report rather than dropping it.
            if editor.canvasViewportSize.width <= 1,
               let clip = clipView, clip.bounds.width > 1 {
                editor.canvasViewportSize = clip.bounds.size
            }
            guard editor.canvasViewportSize.width > 1 else { return }
            editor.pendingFitOnAppear = false
            editor.zoomToFit()
        }

        private func currentMetrics() -> CanvasScrollMetrics? {
            guard let editor, let clip = clipView else { return nil }
            var transform = editor.canvasTransform
            transform.viewportSize = clip.bounds.size
            return CanvasScrollMetrics.compute(nodes: editor.nodes, transform: transform)
        }

        func refresh() {
            guard let metrics = currentMetrics(),
                  let vs = vScroller, let hs = hScroller
            else { return }
            // Pan is not snapped back even when overflow disappears — the
            // user is allowed to drag the network off-frame with the Pan
            // tool and recover it manually. Scroll bars simply reflect
            // whatever overflow the current (pan + zoom) state produces.
            vs.isEnabled = metrics.vEnabled
            vs.knobProportion = CGFloat(metrics.vKnob)
            vs.doubleValue = metrics.vValue

            hs.isEnabled = metrics.hEnabled
            hs.knobProportion = CGFloat(metrics.hKnob)
            hs.doubleValue = metrics.hValue
        }

        // MARK: Scroller actions

        @objc func vScrollerChanged(_ sender: NSScroller) {
            guard let editor, let metrics = currentMetrics(), metrics.vEnabled else { return }
            let pageStep = max(0.05, metrics.vKnob * 0.9)
            var next = metrics.vValue
            switch sender.hitPart {
            case .decrementPage: next = max(0, next - pageStep)
            case .incrementPage: next = min(1, next + pageStep)
            case .decrementLine: next = max(0, next - 0.05)
            case .incrementLine: next = min(1, next + 0.05)
            case .knob, .knobSlot: next = sender.doubleValue
            default: return
            }
            editor.canvasPanOffset.height = metrics.offsetY(forNormalized: next)
        }

        @objc func hScrollerChanged(_ sender: NSScroller) {
            guard let editor, let metrics = currentMetrics(), metrics.hEnabled else { return }
            let pageStep = max(0.05, metrics.hKnob * 0.9)
            var next = metrics.hValue
            switch sender.hitPart {
            case .decrementPage: next = max(0, next - pageStep)
            case .incrementPage: next = min(1, next + pageStep)
            case .decrementLine: next = max(0, next - 0.05)
            case .incrementLine: next = min(1, next + 0.05)
            case .knob, .knobSlot: next = sender.doubleValue
            default: return
            }
            editor.canvasPanOffset.width = metrics.offsetX(forNormalized: next)
        }
    }
}

// MARK: - Scroll metrics

/// Pure-function computation of scroller state from the current network
/// and canvas transform. Only the node geometry feeds the calculation —
/// banners, legend overlays, and other decorations never contribute.
///
/// Overflow is measured against the on-screen bbox so that a network the
/// user has dragged off-frame stays scrollable. Scroll-bar drag targets
/// are expressed in pan space via `panAt0X` / `panAt1X` so the mapping is
/// independent of the current pan — the user can pan off anywhere and
/// the scroll bar still brings them back to a well-defined "left edge" /
/// "right edge" view.
struct CanvasScrollMetrics {
    let hEnabled: Bool
    let vEnabled: Bool
    let hKnob: Double
    let vKnob: Double
    let hValue: Double
    let vValue: Double
    let overflowLeft:   CGFloat
    let overflowRight:  CGFloat
    let overflowTop:    CGFloat
    let overflowBottom: CGFloat
    /// Pan values that make the scroll bar read 0 / 1 respectively.
    /// Derived from the raw (pan-independent) content bbox so the target
    /// stays stable while the user drags the knob.
    let panAt0X: CGFloat
    let panAt1X: CGFloat
    let panAt0Y: CGFloat
    let panAt1Y: CGFloat

    /// Half-node pad so an on-edge node is still fully visible when the
    /// scroller is pinned to its extreme, without falsely detecting
    /// overflow for every non-empty network.
    static let contentMargin: CGFloat = 16
    /// Sub-pixel floor; overflow below this is treated as zero.
    static let overflowEpsilon: CGFloat = 2

    static func compute(nodes: [NetworkNode], transform: CanvasTransform) -> CanvasScrollMetrics {
        let viewport = transform.viewportSize
        let pan = transform.pan
        guard viewport.width > 0, viewport.height > 0,
              let worldBounds = CanvasScene.bounds(of: nodes) else {
            return CanvasScrollMetrics(
                hEnabled: false, vEnabled: false,
                hKnob: 1, vKnob: 1,
                hValue: 0, vValue: 0,
                overflowLeft: 0, overflowRight: 0,
                overflowTop: 0, overflowBottom: 0,
                panAt0X: 0, panAt1X: 0,
                panAt0Y: 0, panAt1Y: 0
            )
        }
        // Raw (pan-independent) display bbox: zoom only.  The current pan
        // is re-applied below to get the on-screen bbox used for overflow.
        let scale = transform.scale
        let rawMinX = worldBounds.minX * scale - contentMargin
        let rawMaxX = worldBounds.maxX * scale + contentMargin
        let rawMinY = worldBounds.minY * scale - contentMargin
        let rawMaxY = worldBounds.maxY * scale + contentMargin

        let minX = rawMinX + pan.width
        let maxX = rawMaxX + pan.width
        let minY = rawMinY + pan.height
        let maxY = rawMaxY + pan.height

        var oLeft   = max(0, -minX)
        var oRight  = max(0, maxX - viewport.width)
        var oTop    = max(0, -minY)
        var oBottom = max(0, maxY - viewport.height)
        if oLeft   < overflowEpsilon { oLeft   = 0 }
        if oRight  < overflowEpsilon { oRight  = 0 }
        if oTop    < overflowEpsilon { oTop    = 0 }
        if oBottom < overflowEpsilon { oBottom = 0 }

        let totalH = oLeft + oRight
        let totalV = oTop  + oBottom

        let hEnabled = totalH > overflowEpsilon
        let vEnabled = totalV > overflowEpsilon

        let hKnob = hEnabled ? Double(viewport.width  / (viewport.width  + totalH)) : 1.0
        let vKnob = vEnabled ? Double(viewport.height / (viewport.height + totalV)) : 1.0

        // panAt0X brings the content's left edge to display x = 0; at
        // panAt1X the content's right edge sits at x = viewport.width.
        let panAt0X = -rawMinX
        let panAt1X = viewport.width - rawMaxX
        let panAt0Y = -rawMinY
        let panAt1Y = viewport.height - rawMaxY

        let rangeX = panAt1X - panAt0X
        let rangeY = panAt1Y - panAt0Y
        let hValue: Double = hEnabled
            ? (abs(rangeX) > overflowEpsilon
               ? min(1, max(0, Double((pan.width  - panAt0X) / rangeX)))
               : 0)
            : 0
        let vValue: Double = vEnabled
            ? (abs(rangeY) > overflowEpsilon
               ? min(1, max(0, Double((pan.height - panAt0Y) / rangeY)))
               : 0)
            : 0

        return CanvasScrollMetrics(
            hEnabled: hEnabled, vEnabled: vEnabled,
            hKnob: hKnob, vKnob: vKnob,
            hValue: hValue, vValue: vValue,
            overflowLeft: oLeft, overflowRight: oRight,
            overflowTop: oTop, overflowBottom: oBottom,
            panAt0X: panAt0X, panAt1X: panAt1X,
            panAt0Y: panAt0Y, panAt1Y: panAt1Y
        )
    }

    /// Pan value corresponding to a normalized scroll position. Linear
    /// interpolation between `panAt0X` (scroll = 0) and `panAt1X`
    /// (scroll = 1).
    func offsetX(forNormalized n: Double) -> CGFloat {
        panAt0X + CGFloat(n) * (panAt1X - panAt0X)
    }

    func offsetY(forNormalized n: Double) -> CGFloat {
        panAt0Y + CGFloat(n) * (panAt1Y - panAt0Y)
    }
}

// MARK: - Clip view: wheel / pinch zoom, keyboard, cursor

/// Hosts the SwiftUI canvas and owns three AppKit-level behaviours:
///
///  * **Scroll wheel and pinch.**  Plain two-finger scroll pans in every
///    tool; ⌥ / ⌘ + wheel and the pinch gesture zoom geometrically about
///    the pointer.  Smart-zoom (two-finger double-tap) fits the selection,
///    or the whole network when nothing is selected.
///  * **Keyboard.**  Delete, Escape (`deselectAll`), Return, Tab / ⇧Tab
///    to walk the nodes in reading order, arrow nudges (whole grid cells
///    while Snap to Grid is on) — or, with nothing selected, arrow
///    scrolls of one wheel line (⇧ = four) — single-letter tool hotkeys,
///    and the Space bar for a temporary pan in every tool.
///  * **Middle button.**  Drags with the middle mouse button pan the view
///    without changing the tool.
///  * **Mouse-down modifiers.**  ⇧ / ⌘ / ⌥ at mouse-down are recorded on
///    the editor before SwiftUI's gestures run, so a click can extend the
///    selection instead of replacing it and an ⌥-drag can duplicate.
///  * **Cursor.**  The one and only cursor owner for the canvas: a cursor
///    rect keyed on tool + hovered element + drag flags, re-evaluated via
///    `refreshCursor()` whenever that state changes.  No push / pop pairs
///    anywhere, so a tool switch while the pointer is elsewhere can never
///    leave a stale cursor behind.  One meaning per cursor: the hand is
///    panning, the arrow is "movable object", the copy cursor previews an
///    ⌥-drag.
final class CanvasClipView: NSView {
    weak var editor: NetworkEditorModel?

    /// Zoom factor per wheel notch (geometric).
    private static let wheelZoomFactor: CGFloat = 1.1
    /// Display points per line for non-precise (mouse-wheel) panning.
    private static let linePanStep: CGFloat = 20

    private var eventMonitor: Any?

    /// SwiftUI lays out top-left-origin; flipping the container makes
    /// AppKit event locations line up with SwiftUI's coordinate space.
    override var isFlipped: Bool { true }

    /// The monitor is installed when the view joins a window and removed
    /// when it leaves one (AppKit clears `window` before deallocation).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, eventMonitor == nil {
            // Record the link under a right-click / ⌃-click *before* the
            // SwiftUI context menu is built, so the menu can offer that
            // link's actions.  A local monitor sees the event regardless
            // of which subview finally handles it.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.noteMouseDown(event)
                }
                return event
            }
        } else if window == nil, let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    /// Runs before SwiftUI sees the click.  Records (a) the link under a
    /// right-click / ⌃-click for the context menu and (b) whether ⇧ or ⌘
    /// was held at a left mouse-down, which turns the click into a
    /// selection toggle and a marquee into an additive one.
    private func noteMouseDown(_ event: NSEvent) {
        guard let editor, event.window === window else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && mods.contains(.control))
        if isContextClick {
            editor.contextMenuLinkID = editor.makeScene().hitLink(at: p)?.id
            return
        }
        if event.type == .leftMouseDown {
            editor.lastMouseDownExtendsSelection = mods.contains(.shift) || mods.contains(.command)
            // ⌥ at mouse-down turns the drag that follows into a
            // duplicate-and-move (read once, when the drag threshold is
            // crossed).
            editor.lastMouseDownDuplicates = mods.contains(.option)
            // Own the keyboard from the first click so Delete, arrows and
            // the Space-bar pan work without a second click.
            if let window, window.firstResponder !== self,
               !(window.firstResponder is NSText) {
                window.makeFirstResponder(self)
            }
        }
    }

    // MARK: Middle-button pan

    private var otherMouseLastPoint: CGPoint?

    override func otherMouseDown(with event: NSEvent) {
        guard let editor else { super.otherMouseDown(with: event); return }
        otherMouseLastPoint = convert(event.locationInWindow, from: nil)
        editor.isPanningCanvas = true
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let editor, let last = otherMouseLastPoint else {
            super.otherMouseDragged(with: event)
            return
        }
        // Deltas from view-space locations: sign-safe in the flipped view.
        let p = convert(event.locationInWindow, from: nil)
        editor.pan(by: CGSize(width: p.x - last.x, height: p.y - last.y))
        otherMouseLastPoint = p
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let editor else { super.otherMouseUp(with: event); return }
        otherMouseLastPoint = nil
        editor.isPanningCanvas = false
    }

    // MARK: Wheel / pinch

    override func scrollWheel(with event: NSEvent) {
        guard let editor else {
            super.scrollWheel(with: event)
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.option) || mods.contains(.command) {
            // Zoom about the pointer, one geometric step per notch.
            let precise = event.hasPreciseScrollingDeltas
            let delta = precise ? event.scrollingDeltaY / 10 : event.deltaY
            guard delta != 0 else { return }
            let factor = pow(Self.wheelZoomFactor, delta)
            editor.zoom(by: factor, about: convert(event.locationInWindow, from: nil))
            return
        }
        // Plain scroll pans, in every tool.
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * Self.linePanStep
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * Self.linePanStep
        guard dx != 0 || dy != 0 else { return }
        editor.pan(by: CGSize(width: dx, height: dy))
    }

    override func magnify(with event: NSEvent) {
        guard let editor else {
            super.magnify(with: event)
            return
        }
        guard event.magnification != 0 else { return }
        editor.zoom(by: 1 + event.magnification, about: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double-tap: frame the selection when there is one,
    /// otherwise frame the whole network.  Same rule as the menu item,
    /// which is simply disabled when there is nothing to frame.
    override func smartMagnify(with event: NSEvent) {
        guard let editor else {
            super.smartMagnify(with: event)
            return
        }
        if editor.canZoomToSelection {
            editor.zoomToFitSelection()
        } else {
            editor.zoomToFit()
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Make sure we own keyDown events so Delete / Arrow-keys / tool
        // hotkeys work the moment the user clicks the canvas.
        //
        // A SwiftUI text field's editor does not resign on its own when a
        // click lands on a non-focusable view, so ⌘Z, ⌘X and ⌘C keep going
        // to an invisible search box for the rest of the session. Commit
        // and end that edit first, then take the responder; check again,
        // because SwiftUI can hand the field editor straight back.
        if let window, window.firstResponder is NSText {
            window.endEditing(for: nil)
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
        }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// Delete / Backspace remove the current selection. Escape cancels
    /// in-progress operations. Arrow keys nudge the selection — 1pt by
    /// default, 10pt with Shift, coalesced into one undo step per run.
    /// Tab / ⇧Tab walk the nodes, ⌥Tab / ⌥⇧Tab the links attached to the
    /// selected node. Single-letter keys switch palette tools
    /// (industry-standard shortcut set). Other keys bubble up to the next
    /// responder so SwiftUI gestures still work.
    override func keyDown(with event: NSEvent) {
        guard let editor else {
            super.keyDown(with: event)
            return
        }

        // Never hijack keys when any modifier is pressed (⌘/Ctrl/Option
        // shortcuts go through the menu) except Shift, which scales the
        // arrow-key nudge amount.
        let shift = event.modifierFlags.contains(.shift)
        let hasOtherMods = !event.modifierFlags
            .intersection([.command, .control, .option])
            .isEmpty
        if hasOtherMods {
            // One exception: ⌥Tab / ⌥⇧Tab walk the links attached to the
            // selected node.  Links are selectable, editable objects, so
            // a keyboard-only user has to be able to reach them; plain
            // Tab keeps walking nodes.
            if event.keyCode == Self.tabKeyCode,
               event.modifierFlags.intersection([.command, .control]).isEmpty,
               event.modifierFlags.contains(.option),
               let link = editor.selectAdjacentLink(reverse: shift) {
                revealLinkIfOffscreen(link, editor: editor)
                return
            }
            super.keyDown(with: event)
            return
        }

        // One arrow press = one grid cell while Snap to Grid is on (⇧ =
        // four), so an arrow can never knock a snapped node off the grid;
        // 1 pt / 10 pt when snapping is off.
        let step: CGFloat = editor.nudgeStep(coarse: shift)

        switch event.keyCode {
        case Self.spaceKeyCode:
            // Temporary pan while held (auto-repeat events are ignored so
            // the flag is set exactly once per press).
            if !event.isARepeat, !editor.isSpacePanning {
                editor.isSpacePanning = true
            }
        case 51, 117:
            editor.deleteSelection()
        case 53:
            // Escape: cancel in-progress operations and deselect
            // everything — the same one implementation as
            // Edit ▸ Deselect All (⌥⌘A) and the context menu.
            //
            // While a drag is in flight the key never gets this far:
            // `CanvasContentView`'s Escape monitor sees it before the
            // responder chain does and spends it on putting the drag back
            // (`cancelDragInFlight()`).  Escape therefore has exactly one
            // meaning per situation, and this is the meaning it has
            // whenever nothing is being dragged.
            editor.deselectAll()
        case 36, 76:
            // Return / keypad Enter open the inspector for the selection.
            editor.openParameterEditorForSelection()
        case Self.tabKeyCode:
            // Tab / ⇧Tab walk the nodes in reading order so a
            // keyboard-only user can reach every one of them, scrolling
            // the target into view when it is off-screen.  ⌥Tab walks
            // the links attached to the node Tab landed on.
            if let target = editor.selectAdjacentNode(reverse: shift) {
                revealIfOffscreen(target, editor: editor)
            } else {
                // Nothing to walk — let Tab do its usual focus job.
                super.keyDown(with: event)
            }
        // Arrow keys.  With something selected they nudge it: a held key
        // auto-repeats, `nudgeSelection` coalesces the run into one undo
        // step and `keyUp` closes it, so a second of travel is one
        // "Undo Move Nodes", not fifteen.
        //
        // With NOTHING selected they scroll the view instead, which is
        // what an arrow key means in every scrolling surface on the
        // platform.  `nudgeSelection` returns early on an empty
        // selection and this branch never called `super`, so before this
        // the arrow keys were simply inert on an unselected canvas —
        // dead keys that did not even fall through the responder chain.
        case Self.arrowLeftKeyCode:  arrow(dx: -1, dy:  0, step: step, editor: editor, coarse: shift)
        case Self.arrowRightKeyCode: arrow(dx:  1, dy:  0, step: step, editor: editor, coarse: shift)
        case Self.arrowDownKeyCode:  arrow(dx:  0, dy:  1, step: step, editor: editor, coarse: shift)
        case Self.arrowUpKeyCode:    arrow(dx:  0, dy: -1, step: step, editor: editor, coarse: shift)
        default:
            // Tool-switch hotkeys from single letters. Parse the
            // character first so we pick up the layout-correct key.
            if let tool = Self.toolShortcut(for: event.charactersIgnoringModifiers) {
                editor.setTool(tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// One arrow press: nudge the selection, or scroll the view when
    /// there is nothing to nudge.
    ///
    /// `dx` / `dy` are the direction in screen terms — ⌄ is +y — and the
    /// pan is the negative of that, because moving the *view* down the
    /// network moves the network up the viewport.
    ///
    /// The nudge step is in world points (a whole grid cell under Snap to
    /// Grid) so a node cannot be knocked off the grid; the pan step is in
    /// display points and is the wheel's own line step, so a keyboard
    /// scroll covers the same distance on screen at every zoom — which is
    /// what a scroll is, and what a nudge deliberately is not.
    private func arrow(dx: CGFloat, dy: CGFloat, step: CGFloat,
                       editor: NetworkEditorModel, coarse: Bool) {
        guard editor.selectionUnion.isEmpty, editor.selectedLinkID == nil else {
            editor.nudgeSelection(by: CGSize(width: dx * step, height: dy * step))
            return
        }
        let panStep = Self.linePanStep * (coarse ? 4 : 1)
        editor.pan(by: CGSize(width: -dx * panStep, height: -dy * panStep))
    }

    /// Maps palette-tool letter shortcuts to the corresponding
    /// `EditorTool`. Matches Figma/OmniGraffle conventions where
    /// possible.
    /// Single source of truth for the letter → tool map is
    /// `EditorTool(shortcutCharacter:)` (also used by the Tools menu and
    /// `ToolShortcutGuard`), so a new tool cannot get out of sync here.
    private static func toolShortcut(for chars: String?) -> EditorTool? {
        guard let chars, chars.count == 1, let ch = chars.first else { return nil }
        return EditorTool(shortcutCharacter: ch)
    }

    private static let spaceKeyCode: UInt16 = 49
    private static let tabKeyCode: UInt16 = 48
    private static let arrowLeftKeyCode: UInt16 = 123
    private static let arrowRightKeyCode: UInt16 = 124
    private static let arrowDownKeyCode: UInt16 = 125
    private static let arrowUpKeyCode: UInt16 = 126
    private static let arrowKeyCodes: Set<UInt16> = [
        arrowLeftKeyCode, arrowRightKeyCode, arrowDownKeyCode, arrowUpKeyCode
    ]

    /// Pans just enough to bring `node` inside the viewport with a
    /// comfortable margin.  A node already on screen is left alone, so
    /// tabbing through a visible row never jitters the view.
    private func revealIfOffscreen(_ node: NetworkNode, editor: NetworkEditorModel) {
        var transform = editor.canvasTransform
        transform.viewportSize = bounds.size
        let viewport = transform.viewportSize
        guard viewport.width > 1, viewport.height > 1 else { return }
        let margin = Self.revealMargin
        let p = transform.toDisplay(node.position)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if p.x < margin { dx = margin - p.x }
        else if p.x > viewport.width - margin { dx = viewport.width - margin - p.x }
        if p.y < margin { dy = margin - p.y }
        else if p.y > viewport.height - margin { dy = viewport.height - margin - p.y }
        guard dx != 0 || dy != 0 else { return }
        editor.pan(by: CGSize(width: dx, height: dy))
    }

    /// Display-point margin kept around a node revealed by Tab — wide
    /// enough to clear the node body and its label block.
    private static let revealMargin: CGFloat = 88

    /// Brings both ends of a link into view, so ⌥Tab never selects an
    /// arrow the user cannot see.
    private func revealLinkIfOffscreen(_ link: NetworkLink, editor: NetworkEditorModel) {
        for id in [link.fromNodeID, link.toNodeID] {
            if let node = editor.node(with: id) { revealIfOffscreen(node, editor: editor) }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == Self.spaceKeyCode, let editor {
            if editor.isSpacePanning { editor.isSpacePanning = false }
            return
        }
        // Letting go of an arrow closes the coalesced nudge, so the run
        // lands on the undo stack as exactly one "Move Nodes".
        if Self.arrowKeyCodes.contains(event.keyCode), let editor {
            editor.endNudgeRun()
            return
        }
        super.keyUp(with: event)
    }

    /// Losing the keyboard (a text field, another window) ends a Space
    /// pan — the key-up would otherwise never reach this view.
    override func resignFirstResponder() -> Bool {
        if let editor {
            if editor.isSpacePanning { editor.isSpacePanning = false }
            // The arrow key-up would otherwise never arrive, leaving the
            // nudge group open across the user's next edit.
            editor.endNudgeRun()
        }
        return super.resignFirstResponder()
    }

    // MARK: - Cursor

    /// The cursor the canvas should show for the editor's current state.
    ///
    /// One meaning per cursor: the hand is panning and nothing else
    /// (HIG, OmniGraffle, Keynote, Figma all keep the plain arrow over a
    /// movable object).  A hovered node in the Pointer tool therefore
    /// shows the arrow — or the copy cursor while ⌥ is held, previewing
    /// the duplicate an ⌥-drag would make.
    func cursorForCurrentState() -> NSCursor {
        guard let editor else { return .arrow }
        if editor.isPanningCanvas || editor.isDraggingNode { return .closedHand }
        if editor.isSpacePanning { return .openHand }
        switch editor.selectedTool {
        case .pan:
            return .openHand
        case .multiSelect, .addStation, .addBuffer, .addSource, .addSink:
            return .crosshair
        case .addLink:
            return editor.hoveredNodeID != nil ? .pointingHand : .arrow
        case .select:
            if editor.hoveredNodeID != nil {
                return Self.optionIsHeld ? .dragCopy : .arrow
            }
            // Links are click-to-act (the click cycles the class), so
            // they keep the pointing hand.
            if editor.hoveredLinkID != nil { return .pointingHand }
            return .arrow
        }
    }

    private static var optionIsHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// ⌥ down / up while the pointer sits over a node flips between the
    /// arrow and the copy cursor, so the duplicate affordance is visible
    /// before the drag starts.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if editor?.selectedTool == .select, editor?.hoveredNodeID != nil {
            refreshCursor()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursorForCurrentState())
    }

    /// Re-evaluate the cursor rect and, if the pointer is already inside
    /// the canvas, flip the cursor right now instead of waiting for the
    /// next mouse move.
    func refreshCursor() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) {
            cursorForCurrentState().set()
        }
    }
}
