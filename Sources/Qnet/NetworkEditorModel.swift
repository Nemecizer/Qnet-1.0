import Foundation
import CoreGraphics
import Combine
import AppKit

extension Notification.Name {
    /// Posted (with the editor as `object`) after any parameter edit that
    /// invalidates the silent primitives / tractability analysis — service
    /// rates, routing probabilities, class assignments, buffer mode.  The
    /// app re-runs the silent analysis so the flag bar never shows stale
    /// Analytical / Re-entrant / Warnings state.
    static let bnetNetworkParametersDidChange = Notification.Name("bnet.network.parameters.didChange")
}

@MainActor
final class NetworkEditorModel: ObservableObject {
    init() {
        // Utilisation badges follow the network content. Node moves
        // publish `nodes` on every drag frame, so the recompute is
        // debounced: it runs once the edit settles, never per frame.
        $nodes.combineLatest($links, $infiniteBuffers)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStationUtilisation() }
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    /// The active tool. `private(set)` on purpose: `setTool(_:)` is the
    /// single writer, because switching tools is never *only* a mode change
    /// — it also ends the sticky-pan session (`toolBeforeStickyPan`), the
    /// pending Link chain (`pendingLinkStartID` / `activeLinkSourceID` /
    /// `pendingLinkPoint`) and, for a non-selection tool, the marquee group.
    /// A bare assignment leaves those alive behind the new tool, which is
    /// how double-click-to-pan used to die silently for a whole session
    /// after one ⌘A. Let the compiler keep that from coming back.
    @Published private(set) var selectedTool: EditorTool = .select
    @Published var nodes: [NetworkNode] = []
    @Published var links: [NetworkLink] = []
    @Published var selectedNodeID: UUID?
    @Published var selectedLinkID: UUID?
    @Published var selectedNodeIDs: Set<UUID> = []
    @Published var multiSelectRect: CGRect?
    @Published var multiSelectOrigin: CGPoint?
    @Published var pendingLinkStartID: UUID?
    @Published var parameterEditorTarget: NodeParameterEditorTarget?
    @Published var linkParameterEditorTarget: LinkParameterEditorTarget?
    @Published var showSRBMExportSheet = false
    @Published var currentFileURL: URL?
    @Published var statusMessages: [StatusEntry] = [
        StatusEntry(text: "Ready. Choose a tool in the Tools pane to start building the network.")
    ]

    /// Signature of the document the last time it was saved, loaded or
    /// cleared. `nil` means "the empty document". Compared against the
    /// live signature to drive the window's edited dot and the tab
    /// bar's unsaved indicator.
    @Published private(set) var cleanDocumentSignature: Int?

    /// Order-sensitive hash of the persisted document content (nodes,
    /// links, buffer regime). Canvas zoom / pan are view state and are
    /// deliberately excluded.
    var documentSignature: Int {
        var h = Hasher()
        h.combine(nodes)
        h.combine(links)
        h.combine(infiniteBuffers)
        return h.finalize()
    }

    private static let emptyDocumentSignature: Int = {
        var h = Hasher()
        h.combine([NetworkNode]())
        h.combine([NetworkLink]())
        h.combine(false)
        return h.finalize()
    }()

    var hasUnsavedChanges: Bool {
        (cleanDocumentSignature ?? Self.emptyDocumentSignature) != documentSignature
    }

    /// Call after a successful save/load so the current content counts
    /// as clean.
    func markDocumentClean() {
        cleanDocumentSignature = documentSignature
    }

    @Published var infiniteBuffers: Bool = false
    /// Canvas zoom factor.  `display = world · canvasScale + canvasPanOffset`.
    @Published var canvasScale: CGFloat = 1.0
    /// When true, node moves and nudges snap their logical position to
    /// the canvas grid (28pt). Driven by the "Snap to Grid" View-menu
    /// item and the canvas zoom cluster.
    @Published var snapToGrid: Bool = false

    /// World-space grid step (pt at zoom 1).  The canvas grid is drawn
    /// through the same transform as the nodes, so a snapped position
    /// always lands on a drawn grid point at any zoom / pan.
    static let gridSpacing: CGFloat = 28

    /// Single source of truth for the zoom limits — the menu, the zoom
    /// cluster, the scroll-wheel / pinch handlers and every fit routine
    /// clamp to this range.
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4.0

    /// Node under the pointer (select / link tools).  Set from the
    /// canvas's single continuous-hover tracker; drives the hover ring
    /// and the AppKit cursor.
    @Published var hoveredNodeID: UUID?
    /// Visible link under the pointer.  Also the target of the canvas
    /// context menu's link section.
    @Published var hoveredLinkID: UUID?
    /// True while a Pan-tool drag (or middle/space drag) is in flight —
    /// the clip view shows the closed hand only then.
    @Published var isPanningCanvas: Bool = false
    /// True while a node drag is in flight.
    @Published var isDraggingNode: Bool = false
    /// True while the space bar is held over the canvas: every tool
    /// temporarily pans (open-hand cursor, drag pans, no tool change and
    /// no undo entry). Cleared on key-up or when the canvas loses focus.
    @Published var isSpacePanning: Bool = false
    /// Whether ⇧ or ⌘ was held at the most recent left mouse-down on the
    /// canvas, recorded by the clip view's event monitor before SwiftUI
    /// gestures run. Plain storage: read once when the click resolves.
    /// A ⇧/⌘-click toggles a node's membership in the selection; a
    /// ⇧-drag marquee adds to it instead of replacing it.
    var lastMouseDownExtendsSelection: Bool = false
    /// Whether ⌥ was held at the most recent left mouse-down on the
    /// canvas.  ⌥-dragging a node duplicates it and drags the copy, the
    /// convention in every Mac diagramming tool.  Plain storage, read
    /// once when the drag threshold is crossed.
    var lastMouseDownDuplicates: Bool = false
    /// Link under the most recent right-click / ⌃-click on the canvas,
    /// recorded by the clip view before the context menu is built.
    /// Plain storage (not published): it is read once when the menu
    /// opens and must not trigger a redraw.
    var contextMenuLinkID: UUID?
    /// Bumped by every programmatic zoom / fit so the canvas animates the
    /// transform change (wheel and pinch zooms leave it alone so they
    /// track the pointer 1:1).
    @Published var canvasAnimationToken: Int = 0
    /// Per-station utilisation ρ = α / (c · μ_eff) from the traffic
    /// equations — the same mapping `--dump-rho` prints.  Empty when the
    /// network is incomplete (no source / station / sink) or unstable to
    /// analyse.  Refreshed automatically whenever content changes.
    @Published var stationUtilisation: [UUID: Double] = [:]

    /// Selection an arrow-key nudge run is currently moving, and when it
    /// last moved — plain storage, never published: a redraw here would
    /// fight the very key repeat it is tracking.
    private var nudgeRunIDs: Set<UUID>?
    private var lastNudgeTime: Date = .distantPast

    /// Alignment guides to draw while a node drag is in flight — the
    /// world x / y the dragged node is currently lined up with.  Empty
    /// whenever nothing is aligned, so the layer costs nothing at rest.
    @Published var activeAlignGuides = SmartGuides.Match.none

    /// Set while ⌃ is held during a drag: Snap to Grid and the alignment
    /// guides both stand down so a node can be placed anywhere.
    /// Published so the Snap segment in the status bar and the zoom
    /// cluster's snap toggle can show the override while it is active.
    @Published var snapSuspended: Bool = false

    /// Snaps a logical point to the grid when `snapToGrid` is on.
    func snapIfNeeded(_ point: CGPoint) -> CGPoint {
        guard snapToGrid, !snapSuspended else { return point }
        let g = Self.gridSpacing
        return CGPoint(
            x: (point.x / g).rounded() * g,
            y: (point.y / g).rounded() * g
        )
    }
    /// Pan offset applied to the canvas in display coordinates. Driven by
    /// the external canvas scrollers. Zero means "no pan" (the default
    /// centered view). Positive `width` shifts content to the right
    /// (revealing content that extends off the left edge); positive
    /// `height` shifts content down.
    @Published var canvasPanOffset: CGSize = .zero
    /// True when the most recent Network Primitives analysis produced one or
    /// more `!! Warning:` messages. Drives the red banner overlay on the
    /// canvas. Set by `showNetworkPrimitives()` in QnetGUIApp; cleared when
    /// the canvas is cleared.
    @Published var networkHasWarnings: Bool = false
    /// Most-recent set of warning messages produced by the primitives /
    /// silent-analysis pipeline. Populated alongside `networkHasWarnings`;
    /// surfaced verbatim in the FlagBar's Warning popover.
    @Published var networkWarningList: [String] = []

    /// Class filter for the canvas legend. When non-nil, only links with
    /// `link.customerClass == classFilter` are drawn. Set by tapping an
    /// entry in the class legend at the bottom of the canvas; cleared by
    /// tapping empty canvas area (via `handleCanvasTap`) or when the
    /// network is cleared / reloaded.
    @Published var classFilter: Int? = nil
    /// True once the Network Primitives analysis has been run at least once for
    /// the currently-loaded network (either manually via the menu, auto-run on
    /// load, or silently when the tab is first activated). Reset whenever the
    /// network contents change (clear / loadNetwork).
    var hasBeenAnalyzed: Bool = false

    /// Green canvas banner state. Set by the tractability check that runs
    /// alongside the warnings analysis. `tractabilityMeansLabel` labels the
    /// analytical column in Run Comparison; `tractabilityMeans` carries the
    /// closed-form or asymptotic E[X] per station (empty when not tractable).
    @Published var isAnalyticallyTractable: Bool = false
    @Published var tractabilityTitle: String = ""
    @Published var tractabilityDetail: String = ""
    var tractabilityMeans: [Double] = []
    var tractabilityMeansLabel: String = ""
    var tractabilityExplanation: String = ""
    var tractabilityIsExact: Bool = false

    /// True when the routing graph (from the most recent SRBM export)
    /// contains a directed cycle — self-loop, immediate feedback (A → B → A),
    /// or any longer rework loop. Refreshed by the same pipeline that
    /// updates the tractability fields. Used to: (a) suppress the GCDG
    /// Cor. 3 fallback path with an explanation, (b) annotate the
    /// Run Comparison regime banner that QNA may degrade, and (c) drive
    /// a small "Feedback present" indicator in the canvas view.
    @Published var hasFeedback: Bool = false
    /// Human-readable description of the routing cycles found in the
    /// most recent analysis (self-loops, immediate feedbacks, longer
    /// rework loops). Used by the Re-entrant flag's popover. Empty
    /// when `hasFeedback` is false.
    @Published var feedbackDescription: String = ""

    /// Diffusion-friendliness assessment for re-entrant networks. The
    /// Re-entrant flag pill colors itself based on this enum:
    ///   .notReentrant → grey (pill is inactive)
    ///   .green        → all criteria met, diffusion approximations should be accurate
    ///   .yellow       → some criteria failed (likely accuracy degradation)
    ///   .red          → diffusion methods will systematically under-predict
    /// (see Re-entrant popover for the per-criterion breakdown). */
    enum FeedbackQuality { case notReentrant, green, yellow, red }
    @Published var feedbackQuality: FeedbackQuality = .notReentrant
    /// Per-criterion checklist evaluated against the diffusion-
    /// friendliness rule of thumb. Each entry is (label, passed?, detail).
    /// Drives the Re-entrant popover body. */
    @Published var feedbackCriteria: [(label: String, ok: Bool, detail: String)] = []
    /// Most-recent size of the canvas viewport (reported by NetworkCanvasView's
    /// GeometryReader). Used by `fitNetworkToWindow()` to size the layout.
    var canvasViewportSize: CGSize = .zero

    // Multi-class link chain state
    @Published var activeCustomerClass: Int = 0
    @Published var activeLinkSourceID: UUID?

    private var stationCount = 0
    private var bufferCount = 0
    private var sourceCount = 0
    private var sinkCount = 0

    // MARK: Clipboard (multi-element)

    /// Nodes currently on the clipboard. Captured from the current
    /// selection by `copySelection()` / `cutSelection()` and cloned with
    /// new IDs on paste.
    private var clipboardNodes: [NetworkNode] = []
    /// Links whose BOTH endpoints were in the copied selection. Linking
    /// out of the clipboard isn't meaningful because the target node
    /// doesn't exist in the paste.
    private var clipboardLinks: [NetworkLink] = []

    var canPaste: Bool { !clipboardNodes.isEmpty }

    // MARK: Undo / redo

    /// Per-tab undo history. Each mutation that calls
    /// `recordUndo(name:before:)` contributes one step. Drag operations
    /// use `beginMutation(_:)` / `endMutation()` to collapse many frame
    /// updates into a single entry.
    let undoManager = UndoManager()

    /// Snapshot captured at `beginMutation`. Nil outside an active
    /// mutation group.
    private var pendingMutationSnapshot: NetworkSnapshot?
    private var pendingMutationName: String?

    /// Per-tab parameter safety-net cache. Every parameter mutation
    /// (rename, buffer size, server count, distribution, picture, per-
    /// class service config) is recorded here, and `openParameterEditor`
    /// pulls the latest overlay back into `nodes` before presenting the
    /// sheet — so reopening the editor always reflects the most recent
    /// committed values, even if any upstream observer somehow holds a
    /// stale node copy.
    private let parameterCache = ParameterCache(editorID: UUID())

    /// Helper used by every parameter-mutation method below. Records the
    /// node's current parameter fields into the on-disk cache.
    private func recordToParameterCache(at index: Int) {
        guard nodes.indices.contains(index) else { return }
        parameterCache.record(nodes[index])
    }

    /// The total number of customer classes in the network. Equals the
    /// count of source nodes plus any derived classes introduced by
    /// Phase 1 class-transition links (toCustomerClass on a link) whose
    /// class index exceeds the source count.
    var numberOfCustomerClasses: Int {
        let srcCount = nodes.filter { $0.kind == .source }.count
        let maxLinkClass = links.reduce(-1) { acc, link in
            Swift.max(acc, link.customerClass, link.toCustomerClass ?? -1)
        }
        return Swift.max(srcCount, maxLinkClass + 1)
    }

    /// Returns the 0-based customer class index for a source node,
    /// ordering sources by their numeric name suffix.
    func customerClassIndex(for sourceID: UUID) -> Int {
        let sources = nodes.filter { $0.kind == .source }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
        return sources.firstIndex(where: { $0.id == sourceID }) ?? 0
    }

    /// The stations in the order every exporter numbers them: sorted by
    /// the numeric suffix of the name, exactly as `SRBMExporter` and
    /// `QNAExporter` do. Index-aligned solver output (ρ, Γ and
    /// `tractabilityMeans`) can therefore be labelled with the station's
    /// real name instead of "S1 … Sn", which is wrong the moment a user
    /// renames a station to CPU or Disk.
    var stationsInExportOrder: [NetworkNode] {
        nodes.filter { $0.kind == .station }
            .sorted { sourceIndex($0.name) < sourceIndex($1.name) }
    }

    /// True when the station names do not pin down the export order:
    /// some station has no numeric suffix ("CPU", "Disk") or two share
    /// one, so `stationsInExportOrder` is decided by whatever the sort
    /// happens to produce. Callers that label an index-aligned solver
    /// vector must say "S1 … Sn" instead of guessing a name.
    var stationOrderIsAmbiguous: Bool {
        NodeNaming.orderIsAmbiguous(nodes.filter { $0.kind == .station }.map(\.name))
    }

    /// Display name for the i-th station of an index-aligned result
    /// vector. Falls back to "S(i+1)" when the vector and the canvas
    /// disagree (a stale result from before a node was deleted) *and*
    /// when the naming is ambiguous — printing "Disk" beside a number
    /// that may belong to "CPU" is worse than printing the index.
    func stationName(atExportIndex index: Int) -> String {
        let stations = stationsInExportOrder
        guard stations.indices.contains(index), !stationOrderIsAmbiguous else {
            return "S\(index + 1)"
        }
        return stations[index].name
    }

    /// The nodes the node inspector's Previous / Next buttons walk for a
    /// node of `kind`: stations in the exporters' own order (so stepping
    /// through them matches every result vector the app prints), every
    /// other kind in reading order. Same kind only — stepping from a
    /// station into a sink would swap the whole form under the user.
    func inspectorNavigationOrder(forKind kind: NodeKind) -> [NetworkNode] {
        kind == .station ? stationsInExportOrder : nodesInReadingOrder.filter { $0.kind == kind }
    }

    /// Neighbour of `nodeID` in `inspectorNavigationOrder`, or nil at the
    /// ends (the inspector disables the button rather than wrapping —
    /// wrapping in a two-button pair reads as "nothing happened").
    func nodeAdjacentInInspectorOrder(to nodeID: UUID, offset: Int) -> NetworkNode? {
        guard let node = node(with: nodeID) else { return nil }
        let order = inspectorNavigationOrder(forKind: node.kind)
        guard let i = order.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let j = i + offset
        return order.indices.contains(j) ? order[j] : nil
    }

    /// Returns the sorted list of customer class indices that have links reaching
    /// the given station or its upstream buffer.
    func classesServedAtStation(nodeID: UUID) -> [Int] {
        guard let station = node(with: nodeID), station.kind == .station else { return [] }

        let upstreamBufferIDs: Set<UUID> = Set(
            nodes.filter { candidate in
                candidate.kind == .buffer &&
                links.contains { $0.fromNodeID == candidate.id && $0.toNodeID == nodeID }
            }.map(\.id)
        )

        let targetIDs = upstreamBufferIDs.union([nodeID])

        var classes = Set<Int>()
        for link in links where targetIDs.contains(link.toNodeID) {
            classes.insert(link.customerClass)
        }

        return classes.sorted()
    }

    // MARK: - Sticky pan and pending-link state
    //
    // Seeded for the canvas view layer (NetworkCanvasView /
    // NetworkCanvasScrollContainer), which owns every gesture but not the
    // editor state a gesture mutates. Behaviour-neutral until the canvas
    // calls in: nothing here runs unless a gesture drives it.

    /// Live pointer position, in world coordinates, while a link is being
    /// dragged out of a node — the elastic rubber-band's free end. Nil
    /// whenever no link drag is in flight. The canvas sets it on drag
    /// change and clears it on drag end; the link layer draws a preview
    /// from `pendingLinkStartID`'s anchor to this point.
    @Published var pendingLinkPoint: CGPoint?

    /// The tool that was active when sticky pan was entered, or nil when
    /// sticky pan is not active. Read-only to the view layer: it is set
    /// and cleared only through `enterStickyPan()` / `exitStickyPan()`, so
    /// the "am I in sticky pan?" question has exactly one answer.
    @Published private(set) var toolBeforeStickyPan: EditorTool?

    /// Enter sticky pan: remember the current tool and switch to `.pan`.
    ///
    /// No cursor work is needed anywhere — the clip view subscribes to
    /// `$selectedTool` and `cursorForCurrentState()` already returns the
    /// open hand for `.pan`, so the hand appears as a consequence of the
    /// tool change (NetworkCanvasScrollContainer.swift).
    ///
    /// Re-entering while already sticky is a no-op rather than an
    /// overwrite, so a second double-click cannot lose the original tool
    /// and strand the user in the hand.
    func enterStickyPan() {
        guard toolBeforeStickyPan == nil else { return }
        guard selectedTool != .pan else { return }
        toolBeforeStickyPan = selectedTool
        setTool(.pan)
    }

    /// Leave sticky pan, restoring the tool that was active when it was
    /// entered. A no-op when sticky pan is not active, so a plain click on
    /// the canvas can call this unconditionally.
    func exitStickyPan() {
        guard let previous = toolBeforeStickyPan else { return }
        toolBeforeStickyPan = nil
        setTool(previous)
    }

    /// One-shot request for the canvas to fit its content once it next
    /// appears or once its geometry is known — the canvas clears it after
    /// acting. Set after opening a document or inserting an archetype,
    /// where the content the user just loaded may be entirely off-screen.
    @Published var pendingFitOnAppear: Bool = false

    func setTool(_ tool: EditorTool) {
        selectedTool = tool

        // An explicit tool choice ends the sticky-pan session. Sticky pan is
        // a *temporary* borrow of the hand — double-click, drag, click to go
        // back — so the moment the user picks any other tool themselves, the
        // thing they would be sent "back" to is stale. Without this, pressing
        // V an hour ago and then deliberately choosing the Pan tool would see
        // the first click inside that deliberate pan session jump the tool
        // back to whatever was active at the double-click.
        // `.pan` is exempt because `enterStickyPan()` reaches this line
        // through `setTool(.pan)` after storing the memo.
        if tool != .pan {
            toolBeforeStickyPan = nil
        }

        if tool != .addLink {
            pendingLinkStartID = nil
            activeLinkSourceID = nil
            // The rubber-band's free end belongs to the same gesture
            // as its start: leaving the Link tool ends both.
            pendingLinkPoint = nil
        }

        if tool != .select && tool != .multiSelect {
            clearMultiSelection()
        }
        // No status line: the palette's selected state and the Tools menu
        // check mark already show the active tool, and the single-letter
        // hotkeys would otherwise flood the Status pane.
    }

    func handleCanvasTap(at location: CGPoint) {
        switch selectedTool {
        case .addStation:
            addNode(kind: .station, at: location)
        case .addBuffer:
            addNode(kind: .buffer, at: location)
        case .addSource:
            addNode(kind: .source, at: location)
        case .addSink:
            addNode(kind: .sink, at: location)
        case .select, .multiSelect, .pan:
            selectedNodeID = nil
            selectedLinkID = nil
            pendingLinkStartID = nil
            clearMultiSelection()
            // Tapping an empty area also clears a pinned class filter so
            // all routing links show again.
            classFilter = nil
        case .addLink:
            selectedNodeID = nil
            selectedLinkID = nil
            pendingLinkStartID = nil
            activeLinkSourceID = nil
        }
    }

    /// Resolves a click on a node.  In the Pointer / Multi-Select tools a
    /// plain click makes the node the sole selection (clearing any marquee
    /// group), while `extendingSelection` (⇧- or ⌘-click) toggles the
    /// node's membership in the group without disturbing the others.
    func handleNodeTap(nodeID: UUID, extendingSelection: Bool = false) {
        switch selectedTool {
        case .select, .multiSelect:
            selectedLinkID = nil
            pendingLinkStartID = nil
            if extendingSelection {
                toggleNodeInSelection(nodeID)
            } else {
                // Deliberately silent: selecting is not a document event,
                // and the canvas status bar already reports the selection
                // live, so a click is not worth a line in the status log.
                selectedNodeIDs = []
                selectedNodeID = nodeID
            }
        case .addLink:
            handleLinkSelection(nodeID)
        case .addStation, .addBuffer, .addSource, .addSink:
            selectedNodeIDs = []
            selectedNodeID = nodeID
            selectedLinkID = nil
        case .pan:
            // Pan mode treats every canvas region as the pan surface —
            // clicks on nodes are no-ops so the drag can keep going.
            break
        }
    }

    /// ⇧/⌘-click: add `nodeID` to the selection group, or remove it when
    /// it is already selected.  The single `selectedNodeID` is promoted
    /// into the group first so a plain-selected node and a marquee group
    /// combine into one set.  When the result is exactly one node it is
    /// re-expressed as the single selection so the inspector shortcuts
    /// (⌘I, Return) keep working.
    func toggleNodeInSelection(_ nodeID: UUID) {
        var group = selectedNodeIDs
        if let single = selectedNodeID { group.insert(single) }
        if group.contains(nodeID) {
            group.remove(nodeID)
        } else {
            group.insert(nodeID)
        }
        setNodeSelection(group)
    }

    /// Normalises a selection set: one node → `selectedNodeID`, several →
    /// `selectedNodeIDs`, none → both cleared.  The canvas uses it when a
    /// ⇧-drag starts on an unselected node (the node joins the group).
    func setNodeSelection(_ group: Set<UUID>) {
        // A new selection ends the arrow-key run that was moving the old
        // one, so its undo step covers exactly the nodes it moved.
        if group != currentSelectionIDs() { endNudgeRun() }
        if group.count == 1, let only = group.first {
            selectedNodeIDs = []
            selectedNodeID = only
        } else {
            selectedNodeIDs = group
            selectedNodeID = nil
        }
    }

    /// Every selected node id (single selection and group combined).
    var selectionUnion: Set<UUID> { currentSelectionIDs() }

    /// True when anything on the canvas is selected — nodes, a link, or
    /// both.  The single answer behind Edit ▸ Deselect All's enablement,
    /// the canvas context menu's Deselect All and the status bar's
    /// selection segment, so those three can never disagree about
    /// whether there is a selection.
    var hasAnySelection: Bool {
        !currentSelectionIDs().isEmpty || selectedLinkID != nil
    }

    /// Clears every kind of canvas selection in one call: the single and
    /// group node selections, the selected link, an in-progress marquee
    /// and a half-built link chain.  The one implementation behind
    /// Edit ▸ Deselect All (⌥⌘A), Escape on the canvas and the canvas
    /// context menu, so all three always mean the same thing.
    func deselectAll() {
        endNudgeRun()
        clearMultiSelection()
        pendingLinkStartID = nil
        activeLinkSourceID = nil
        pendingLinkPoint = nil
        selectedNodeIDs = []
        selectedNodeID = nil
        selectedLinkID = nil
    }

    /// True when there is something for Zoom to Selection to frame.  The
    /// menu bar, the zoom cluster, the canvas context menu and the
    /// two-finger smart zoom all gate on this one property, so the
    /// command never means two different things.
    var canZoomToSelection: Bool { !currentSelectionIDs().isEmpty }

    func handleLinkTap(linkID: UUID) {
        guard selectedTool == .select else {
            return
        }

        if selectedLinkID == linkID {
            // Already selected — cycle customer class
            cycleLinkCustomerClass(linkID: linkID)
        } else {
            selectedLinkID = linkID
            selectedNodeID = nil
            pendingLinkStartID = nil
        }
    }

    /// `snap: false` bypasses Snap to Grid for this one move — the canvas
    /// drag decides per axis whether the grid or an alignment guide wins
    /// and passes the already-resolved position.
    func moveNode(id: UUID, to location: CGPoint, snap: Bool = true) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            return
        }
        nodes[index].position = snap ? snapIfNeeded(location) : location
    }

    func moveLink(id: UUID, by translation: CGSize) {
        guard let link = link(with: id),
              let fromIndex = nodes.firstIndex(where: { $0.id == link.fromNodeID }),
              let toIndex = nodes.firstIndex(where: { $0.id == link.toNodeID }) else {
            return
        }

        performMutation("Move Link") {
            nodes[fromIndex].position.x += translation.width
            nodes[fromIndex].position.y += translation.height
            nodes[toIndex].position.x += translation.width
            nodes[toIndex].position.y += translation.height
        }

        addStatus("Moved link \(linkLabel(link)).")
    }

    func deleteNode(id: UUID) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        performMutation("Delete Node") {
            guard let nodeIndex = nodes.firstIndex(where: { $0.id == id }) else { return }
            let removedNode = nodes.remove(at: nodeIndex)
            let linksBefore = links.count
            links.removeAll(where: { $0.fromNodeID == id || $0.toNodeID == id })
            let removedLinks = linksBefore - links.count

            if selectedNodeID == id { selectedNodeID = nil }
            selectedNodeIDs.remove(id)
            if pendingLinkStartID == id { pendingLinkStartID = nil }
            if activeLinkSourceID == id { activeLinkSourceID = nil }
            if parameterEditorTarget?.id == id { parameterEditorTarget = nil }

            if removedLinks > 0 {
                addStatus("Deleted \(removedNode.name) and \(removedLinks) connected link(s).")
            } else {
                addStatus("Deleted \(removedNode.name).")
            }
        }
    }

    func deleteLink(id: UUID) {
        guard links.contains(where: { $0.id == id }) else { return }
        performMutation("Delete Link") {
            guard let index = links.firstIndex(where: { $0.id == id }) else { return }
            let link = links.remove(at: index)
            if selectedLinkID == id { selectedLinkID = nil }
            addStatus("Deleted link \(linkLabel(link)).")
        }
    }

    /// Copies the current selection (multi-selection takes precedence
    /// over single-selection) to the clipboard. Links are included only
    /// when both endpoints are in the selection.
    func copySelection() {
        let ids = currentSelectionIDs()
        guard !ids.isEmpty else {
            addStatus("Nothing selected to copy. Use the Multi-Select tool to drag a rectangle around nodes, or ⌘A to Select All.")
            return
        }
        clipboardNodes = nodes.filter { ids.contains($0.id) }
        clipboardLinks = links.filter { ids.contains($0.fromNodeID) && ids.contains($0.toNodeID) }
        let n = clipboardNodes.count
        let l = clipboardLinks.count
        addStatus("Copied \(n) node\(n == 1 ? "" : "s")\(l > 0 ? " and \(l) link\(l == 1 ? "" : "s")" : "").")
    }

    func cutSelection() {
        let ids = currentSelectionIDs()
        guard !ids.isEmpty else {
            // A link-only selection lands here: Cut is copy-then-delete and
            // the clipboard holds nodes, so there is nothing to cut. Delete
            // removes a selected link; Cut must not, or ⌘X would destroy
            // something ⌘V cannot bring back.
            addStatus("Nothing selected to cut. Select nodes to cut, or press Delete to remove a selected link.")
            return
        }
        // Same rule for a MIXED selection (nodes from a marquee plus a link
        // clicked afterwards): `copySelection` takes only the links whose two
        // endpoints are both in the node selection, so a separately selected
        // link is not on the clipboard. Drop it from the selection before the
        // delete rather than cutting what cannot be pasted back.
        if let linkID = selectedLinkID,
           let selectedLink = link(with: linkID),
           !(ids.contains(selectedLink.fromNodeID) && ids.contains(selectedLink.toNodeID)) {
            selectedLinkID = nil
        }
        copySelection()
        deleteSelection()
    }

    /// Pastes the clipboard contents as new nodes + links with fresh
    /// IDs, offset from their source positions. Pasted nodes become
    /// the new selection so the user can immediately drag them to
    /// their final position.
    func pasteSelection() {
        guard !clipboardNodes.isEmpty else {
            addStatus("Clipboard is empty — copy a selection first.")
            return
        }
        performMutation("Paste") {
            pasteClipboardContents()
        }
    }

    /// Copy-and-paste in one gesture. Useful for quickly replicating
    /// a sub-chain (⌘D in most editors).
    func duplicateSelection() {
        let ids = currentSelectionIDs()
        guard !ids.isEmpty else { return }
        let dupNodes = nodes.filter { ids.contains($0.id) }
        let dupLinks = links.filter { ids.contains($0.fromNodeID) && ids.contains($0.toNodeID) }
        performMutation("Duplicate") {
            // Temporarily stash the clipboard so we don't clobber it.
            let savedNodes = clipboardNodes
            let savedLinks = clipboardLinks
            clipboardNodes = dupNodes
            clipboardLinks = dupLinks
            pasteClipboardContents()
            clipboardNodes = savedNodes
            clipboardLinks = savedLinks
        }
    }

    /// ⌥-drag: copy the current selection in place (no offset — the drag
    /// supplies the displacement) and make the copies the selection, so
    /// the drag that triggered this carries them away from the originals.
    /// Must be called inside an open `beginMutation` scope; returns the
    /// new ids so the caller can re-anchor its drag on them.
    @discardableResult
    func duplicateSelectionInPlaceForDrag() -> Set<UUID> {
        let ids = currentSelectionIDs()
        guard !ids.isEmpty else { return [] }
        let dupNodes = nodes.filter { ids.contains($0.id) }
        let dupLinks = links.filter { ids.contains($0.fromNodeID) && ids.contains($0.toNodeID) }
        let savedNodes = clipboardNodes
        let savedLinks = clipboardLinks
        clipboardNodes = dupNodes
        clipboardLinks = dupLinks
        pasteClipboardContents(offset: 0, announce: false)
        clipboardNodes = savedNodes
        clipboardLinks = savedLinks
        return currentSelectionIDs()
    }

    /// Edit ▸ Delete, the ⌦ / ⌫ key and the canvas context menu.
    /// Removes every selected node with its attached links AND a selected
    /// link — a routing graph's links are first-class selectable objects, so
    /// a link-only selection is a real selection and Delete has to honour it.
    /// (It used to return early on one, leaving an enabled menu item that did
    /// nothing.)
    func deleteSelection() {
        let ids = currentSelectionIDs()
        let linkID = selectedLinkID
        guard !ids.isEmpty || linkID != nil else { return }

        // Read the link's label while both its endpoints still exist.
        let linkLabelText = linkID.flatMap { link(with: $0) }.map { linkLabel($0) }

        // Name the undo step after what is actually being removed, so the
        // Edit menu reads "Undo Delete Link" and not "Undo Delete".
        let actionName: String
        if ids.isEmpty {
            actionName = "Delete Link"
        } else if ids.count == 1 && linkID == nil {
            actionName = "Delete Node"
        } else {
            actionName = "Delete Selection"
        }

        var removedNodes = 0
        var removedLinks = 0
        performMutation(actionName) {
            let linksBefore = links.count
            // The selected link goes first: a node removal below would take
            // it with it if it happens to be attached, and then the count
            // would report it twice.
            if let linkID { links.removeAll { $0.id == linkID } }
            let nodesBefore = nodes.count
            nodes.removeAll { ids.contains($0.id) }
            links.removeAll { ids.contains($0.fromNodeID) || ids.contains($0.toNodeID) }
            removedNodes = nodesBefore - nodes.count
            removedLinks = linksBefore - links.count

            selectedNodeID = nil
            selectedNodeIDs.removeAll()
            selectedLinkID = nil
            pendingLinkStartID = nil
            activeLinkSourceID = nil
            parameterEditorTarget = nil
        }

        // Say what went, in `deleteLink`'s wording, so the two paths to the
        // same removal read the same in the status log.
        if removedNodes == 0, let linkLabelText {
            addStatus("Deleted link \(linkLabelText).")
        } else {
            addStatus(
                "Deleted \(removedNodes) node\(removedNodes == 1 ? "" : "s")"
                + (removedLinks > 0
                   ? " and \(removedLinks) link\(removedLinks == 1 ? "" : "s")"
                   : "")
                + "."
            )
        }
    }

    /// Union of single and multi-select.
    private func currentSelectionIDs() -> Set<UUID> {
        var ids = selectedNodeIDs
        if let s = selectedNodeID { ids.insert(s) }
        return ids
    }

    /// Actual paste implementation shared by `pasteSelection` and
    /// `duplicateSelection`. Must be called inside an undoable scope.
    ///
    /// `offset` is the world-space displacement given to the copies
    /// (60 pt ≈ two grid cells, so a paste is visibly separate from its
    /// original); an ⌥-drag passes 0 because the drag itself supplies the
    /// displacement.  `announce` is false for that same case — the copies
    /// are about to move under the pointer, so a "Pasted 3 nodes" line
    /// would be noise.
    private func pasteClipboardContents(offset: CGFloat = 60, announce: Bool = true) {
        let added = appendRenamedCopies(
            of: clipboardNodes,
            links: clipboardLinks,
            translation: CGSize(width: offset, height: offset)
        )

        selectedNodeIDs = Set(added.nodes.map(\.id))
        selectedNodeID = added.nodes.count == 1 ? added.nodes.first?.id : nil
        selectedLinkID = nil

        guard announce else { return }
        let n = added.nodes.count
        let l = added.links.count
        addStatus("Pasted \(n) node\(n == 1 ? "" : "s")" +
                  (l > 0 ? " and \(l) link\(l == 1 ? "" : "s")" : "") + ".")
    }

    /// Appends a detached (nodes, links) pair to the document under fresh
    /// names and fresh ids, displaced by `translation`. The one implementation
    /// behind Paste, Duplicate, ⌥-drag and `insertSubnetwork` — three call
    /// sites that must agree about naming and id remapping or the document
    /// grows two nodes called "S3".
    ///
    /// Must be called inside an undoable scope; it does not open one itself
    /// and it does not touch the selection (each caller says what should be
    /// selected afterwards).
    @discardableResult
    private func appendRenamedCopies(
        of incomingNodes: [NetworkNode],
        links incomingLinks: [NetworkLink],
        translation: CGSize
    ) -> (nodes: [NetworkNode], links: [NetworkLink]) {
        // Re-sync the name counters against whatever is actually on the
        // canvas right now — fresh tabs, file loads, and clears can
        // leave the counters out of step with the real max, which would
        // lead to duplicate names ("S3" pasted while "S3" already
        // exists). Using `max(counter, observedMax)` keeps monotonicity
        // for within-session pastes.
        stationCount = max(stationCount, maxNameIndex(kind: .station, prefix: "S"))
        bufferCount  = max(bufferCount,  maxNameIndex(kind: .buffer,  prefix: "B"))
        sourceCount  = max(sourceCount,  maxNameIndex(kind: .source,  prefix: "Src"))
        sinkCount    = max(sinkCount,    maxNameIndex(kind: .sink,    prefix: "Sink"))

        var idMap: [UUID: UUID] = [:]
        var newNodes: [NetworkNode] = []

        for source in incomingNodes {
            let name: String
            switch source.kind {
            case .station:
                stationCount += 1
                name = "S\(stationCount)"
            case .buffer:
                bufferCount += 1
                name = "B\(bufferCount)"
            case .source:
                sourceCount += 1
                name = "Src\(sourceCount)"
            case .sink:
                sinkCount += 1
                name = "Sink\(sinkCount)"
            }
            let newNode = NetworkNode(
                kind: source.kind,
                name: name,
                position: CGPoint(x: source.position.x + translation.width,
                                  y: source.position.y + translation.height),
                bufferSize: source.bufferSize,
                numberOfServers: source.numberOfServers,
                distribution: source.distribution,
                distributionParameters: source.distributionParameters,
                serviceDistributions: source.serviceDistributions,
                picture: source.picture
            )
            idMap[source.id] = newNode.id
            newNodes.append(newNode)
        }

        let newLinks: [NetworkLink] = incomingLinks.compactMap { source in
            guard let newFrom = idMap[source.fromNodeID],
                  let newTo   = idMap[source.toNodeID] else { return nil }
            return NetworkLink(
                fromNodeID: newFrom,
                toNodeID:   newTo,
                routingProbability: source.routingProbability,
                customerClass: source.customerClass,
                toCustomerClass: source.toCustomerClass
            )
        }

        nodes.append(contentsOf: newNodes)
        links.append(contentsOf: newLinks)
        return (newNodes, newLinks)
    }

    /// Inserts a whole sub-network — an archetype from the gallery, or any
    /// other programmatically built (nodes, links) pair — as ONE undo step.
    ///
    /// Everything the paste path does for names and ids happens here too, and
    /// through the same helper: the four counters are re-primed against what
    /// is on the canvas, every incoming node is renamed through them and given
    /// a fresh id, and the links are rebuilt against that id map. So an insert
    /// into a canvas that already holds S1–S3 lands as S4–S6 and cannot
    /// collide with what is already there.
    ///
    /// `origin` is where the block's top-left corner goes on an EMPTY canvas.
    /// When the canvas already has content the block is moved clear to the
    /// right of it instead, keeping its own internal layout — an insert never
    /// lands on top of the network the user is already building.
    ///
    /// Deliberately NOT a loop over `addNode` / `addLink`: those call
    /// `performMutation` themselves and it does not fold into an enclosing
    /// group, so an eight-node archetype would cost eight ⌘Z presses.
    ///
    /// `actionName` is both the undo-step name shown in the Edit menu
    /// ("Insert Tandem Line") and the opening of the status line; `detail`
    /// is appended to that line, so the parameters the network was built at
    /// are taught rather than merely applied.
    ///
    /// Returns the ids of the inserted nodes, which are also left selected.
    @discardableResult
    func insertSubnetwork(
        nodes incomingNodes: [NetworkNode],
        links incomingLinks: [NetworkLink],
        infiniteBuffers newInfiniteBuffers: Bool,
        at origin: CGPoint,
        actionName: String,
        detail: String? = nil
    ) -> Set<UUID> {
        guard !incomingNodes.isEmpty else { return [] }

        // The buffer regime is network-WIDE: flipping it reinterprets the
        // capacity of every station already on the canvas, greys out half of
        // the Run menu, and changes what the document means. An insert is not
        // allowed to do that silently, so it only sets the regime when there
        // is nothing to reinterpret (an empty canvas) or when the incoming
        // block already agrees. Otherwise the document keeps its own regime
        // and the status line says so, naming the command that does change it
        // deliberately.
        let canvasWasEmpty = nodes.isEmpty
        let regimeAdopted = canvasWasEmpty || newInfiniteBuffers == infiniteBuffers
        let keptRegimeIsInfinite = infiniteBuffers
        // Class count as the document reads it BEFORE the insert — the
        // remapper needs it to park any derived class of the incoming block
        // clear of every class already in use here.
        let priorClassCount = numberOfCustomerClasses
        var insertedNodes: [NetworkNode] = []
        var insertedLinks: [NetworkLink] = []
        var insertedClasses: [Int] = []

        performMutation(actionName) {
            let added = appendRenamedCopies(
                of: incomingNodes,
                links: incomingLinks,
                translation: insertionTranslation(for: incomingNodes, at: origin)
            )
            insertedNodes = added.nodes
            insertedLinks = added.links
            if regimeAdopted {
                infiniteBuffers = newInfiniteBuffers
            }
            // The renamed sources have new class indices (a second source is
            // class 1), so the links that came with them must be moved onto
            // those classes or the inserted half of the network would route
            // class 0 traffic that its own source never emits.
            insertedClasses = remapInsertedCustomerClasses(
                incoming: incomingNodes,
                inserted: added.nodes,
                linkIDs: Set(added.links.map(\.id)),
                priorClassCount: priorClassCount
            )
            setNodeSelection(Set(added.nodes.map(\.id)))
            selectedLinkID = nil
        }

        // The flag bar is invalidated by `performMutation` above — the insert
        // changes nodes and links, so `analysisWouldRead` is true and the
        // Analytical pill lights on an inserted archetype without the user
        // reaching for Network ▸ Analyze Network.
        //
        // The block may have landed clear to the right of everything the
        // viewport shows; ask the canvas to fit once it next has geometry.
        pendingFitOnAppear = true

        let n = insertedNodes.count
        let l = insertedLinks.count
        addStatus(
            "\(actionName): added \(n) node\(n == 1 ? "" : "s") and "
            + "\(l) link\(l == 1 ? "" : "s")"
            + (regimeAdopted && canvasWasEmpty && !newInfiniteBuffers
               ? ", with finite buffers"
               : "")
            + "."
            + (detail.map { " \($0)." } ?? "")
            + (regimeAdopted
               ? ""
               : " The network stays on "
                 + (keptRegimeIsInfinite ? "infinite" : "finite")
                 + " buffers — an insert never re-interprets the stations already on the canvas."
                 + " Use Network ▸ Buffer Model to change the whole network.")
            + (insertedClasses.contains { $0 != 0 }
               ? " Its traffic is "
                 + insertedClasses.sorted().map { CustomerClass.label(for: $0) }.joined(separator: ", ")
                 + ", because the canvas already had a source."
               : "")
        )
        return Set(insertedNodes.map(\.id))
    }

    /// Moves the links that arrived with an inserted sub-network onto the
    /// customer classes its sources actually own in THIS document.
    ///
    /// A sub-network is authored against its own source list: its single
    /// source is class 0 and every link it brings says `customerClass: 0`.
    /// But `customerClassIndex(for:)` derives a source's class from its rank
    /// in the document's name-sorted source list, so inserting into a canvas
    /// that already has Src1 makes the incoming Src2 class 1 — and its links,
    /// left as authored, would route class 0. That is a document state the
    /// Link tool itself cannot produce (`handleLinkSelection` starts from
    /// `customerClassIndex(for:)` for a source), and it would show a two-class
    /// legend over a network whose second class has no routing at all.
    ///
    /// Returns the classes the inserted links ended up on, so the caller can
    /// tell the user about a class it did not ask for.
    ///
    /// Must be called inside the same undoable scope as the append.
    @discardableResult
    private func remapInsertedCustomerClasses(
        incoming incomingNodes: [NetworkNode],
        inserted insertedNodes: [NetworkNode],
        linkIDs insertedLinkIDs: Set<UUID>,
        priorClassCount: Int
    ) -> [Int] {
        // `appendRenamedCopies` preserves order, so incoming index i and
        // inserted index i are the same node.
        let incomingSources = incomingNodes.enumerated().filter { $0.element.kind == .source }
        guard !incomingSources.isEmpty,
              insertedNodes.count == incomingNodes.count else { return [] }

        // The class the sub-network itself gave each of its sources: its rank
        // in its OWN name-sorted source list — the same rule this document
        // applies, so the mapping is old rank → new rank.
        var classMap: [Int: Int] = [:]
        let ownOrder = incomingSources.sorted {
            sourceIndex($0.element.name) < sourceIndex($1.element.name)
        }
        for (ownClass, entry) in ownOrder.enumerated() {
            classMap[ownClass] = customerClassIndex(for: insertedNodes[entry.offset].id)
        }

        // A class above the block's own source count is a DERIVED class — one
        // its links introduced with `toCustomerClass`. Nothing the archetype
        // library builds has one, but a caller could hand one over, and it
        // must not land on a derived class this document is already using, so
        // park the whole derived range above everything in play.
        let derivedBase = Swift.max(priorClassCount, (classMap.values.max() ?? -1) + 1)
        func mapped(_ cls: Int) -> Int {
            if let moved = classMap[cls] { return moved }
            guard cls >= incomingSources.count else { return cls }
            return derivedBase + (cls - incomingSources.count)
        }

        var landed = Set<Int>()
        for index in links.indices where insertedLinkIDs.contains(links[index].id) {
            links[index].customerClass = mapped(links[index].customerClass)
            if let exit = links[index].toCustomerClass {
                links[index].toCustomerClass = mapped(exit)
            }
            landed.insert(links[index].customerClass)
        }
        return landed.sorted()
    }

    /// Displacement that puts an incoming block at `origin` on an empty
    /// canvas, and clear of the existing content on a canvas that has some.
    /// The block keeps its own internal layout either way — only the whole
    /// group moves.
    private func insertionTranslation(for incoming: [NetworkNode], at origin: CGPoint) -> CGSize {
        guard let incomingMinX = incoming.map(\.position.x).min(),
              let incomingMinY = incoming.map(\.position.y).min() else { return .zero }

        guard let existingMaxX = nodes.map(\.position.x).max(),
              let existingMinY = nodes.map(\.position.y).min() else {
            // Empty canvas: land exactly where the block was authored.
            return CGSize(width: origin.x - incomingMinX, height: origin.y - incomingMinY)
        }
        // Occupied canvas: one station column of clear air between the two,
        // tops aligned, so the insert reads as a second network rather than
        // as an edit to the first.
        let gap = CGFloat(RandomNetworkGenerator.Layout.xStep)
        return CGSize(width: existingMaxX + gap - incomingMinX,
                      height: existingMinY - incomingMinY)
    }

    // Kept for backwards compat with older menu-bar wiring. New call
    // sites should use the Selection-oriented versions above.
    func copySelectedNode()  { copySelection() }
    func cutSelectedNode()   { cutSelection() }
    func pasteNode()         { pasteSelection() }

    /// Safety net: paste the most-recently-recorded parameters from the
    /// on-disk cache back over the in-memory node. The inspector reads
    /// from `nodes` via `node(with:)` and a stale snapshot would
    /// otherwise make a second edit appear to revert to the original
    /// values. Called before presenting the sheet AND before the
    /// inspector steps to a sibling node in place.
    func applyParameterCacheOverlay(to nodeID: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
              let overlay = parameterCache.overlay(for: nodeID),
              !overlay.matches(nodes[index]) else { return }
        overlay.apply(to: &nodes[index])
    }

    func openParameterEditor(for nodeID: UUID) {
        guard nodes.contains(where: { $0.id == nodeID }) else { return }

        applyParameterCacheOverlay(to: nodeID)

        selectedNodeID = nodeID
        selectedLinkID = nil
        parameterEditorTarget = NodeParameterEditorTarget(id: nodeID)
    }

    func closeParameterEditor() {
        parameterEditorTarget = nil
    }

    func openLinkParameterEditor(for linkID: UUID) {
        guard link(with: linkID) != nil else { return }
        selectedLinkID = linkID
        selectedNodeID = nil
        linkParameterEditorTarget = LinkParameterEditorTarget(id: linkID)
    }

    func closeLinkParameterEditor() {
        linkParameterEditorTarget = nil
    }

    /// Opens the parameter inspector for whatever is currently selected:
    /// the single selected node, the selected link, or (for a one-node
    /// multi-selection) that node.  Used by ⌘I / Return on the canvas.
    func openParameterEditorForSelection() {
        if let id = selectedNodeID {
            openParameterEditor(for: id)
        } else if let id = selectedLinkID {
            openLinkParameterEditor(for: id)
        } else if selectedNodeIDs.count == 1, let id = selectedNodeIDs.first {
            openParameterEditor(for: id)
        } else {
            // Nothing to open (empty canvas or a 2+ node multi-selection):
            // a quiet beep, not a status line on every Return press. The
            // Edit menu item is gated on `canOpenParameterEditor`.
            NSSound.beep()
        }
    }

    /// True when ⌘I / Return has something to open.
    var canOpenParameterEditor: Bool {
        selectedNodeID != nil || selectedLinkID != nil || selectedNodeIDs.count == 1
    }

    /// True while a modal sheet (node / link inspector, SRBM export) is
    /// presented. The Tools menu disables its bare-letter hotkeys while
    /// this is true so typing S / B / O / X into a sheet control can never
    /// switch the canvas tool underneath the sheet.
    var isModalSheetPresented: Bool {
        parameterEditorTarget != nil || linkParameterEditorTarget != nil || showSRBMExportSheet
    }

    // MARK: - Parameter mutations
    //
    // Every method below is a single undo step when called on its own
    // (AI tools, context menus) and folds into the enclosing group when
    // called from `performParameterEdit` (the inspector's Save button),
    // so one Save = one entry in the Edit menu.  Each one is a no-op when
    // the value is unchanged, sets `hasBeenAnalyzed = false`, and posts
    // `.bnetNetworkParametersDidChange` so the flag bar refreshes.

    func updateLinkProbability(linkID: UUID, probability: Double) {
        guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }
        let clamped = min(max(probability, 0), 1)
        guard links[index].routingProbability != clamped else { return }
        performParameterMutation("Change Routing Probability") {
            links[index].routingProbability = clamped
            noteParametersChanged()
        }
        parameterStatus("Updated \(linkLabel(links[index])) routing probability to \(DS.Number.format(clamped, significantDigits: 4)).")
    }

    func updateLinkCustomerClass(linkID: UUID, customerClass: Int) {
        guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }
        guard links[index].customerClass != customerClass else { return }
        performParameterMutation("Change Link Class") {
            links[index].customerClass = customerClass
            noteParametersChanged()
        }
        parameterStatus("Updated \(linkLabel(links[index])) to \(CustomerClass.label(for: customerClass)).")
    }

    /// Sets the link's exit class. Pass `nil` to clear any class
    /// transition (link keeps jobs in the same class). Pass the same
    /// class as `customerClass` for equivalent "no transition" behavior.
    func updateLinkExitClass(linkID: UUID, exitClass: Int?) {
        guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }
        guard links[index].toCustomerClass != exitClass else { return }
        performParameterMutation("Change Exit Class") {
            links[index].toCustomerClass = exitClass
            noteParametersChanged()   // force re-analysis since K may change
        }
        if let k = exitClass, k != links[index].customerClass {
            parameterStatus("\(linkLabel(links[index])) now transitions to \(CustomerClass.label(for: k)) on exit.")
        } else {
            parameterStatus("\(linkLabel(links[index])) exit class cleared (no transition).")
        }
    }

    func renameNode(nodeID: UUID, name: String) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let oldName = nodes[index].name
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        performParameterMutation("Rename Node") {
            nodes[index].name = trimmed
            recordToParameterCache(at: index)
            noteParametersChanged()
        }
        parameterStatus("Renamed \(oldName) to \(trimmed).")
    }

    func updateBufferSize(nodeID: UUID, size: Int) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID && $0.kind == .buffer }) else {
            return
        }
        let clamped = max(1, size)
        guard nodes[index].bufferSize != clamped else { return }
        performParameterMutation("Change Buffer Size") {
            nodes[index].bufferSize = clamped
            recordToParameterCache(at: index)
            noteParametersChanged()
        }
        parameterStatus("Updated \(nodes[index].name) buffer size to \(clamped).")
    }

    /// Network-wide buffer mode.  Undoable; applies to every buffer node.
    func setInfiniteBuffers(_ infinite: Bool) {
        guard infiniteBuffers != infinite else { return }
        performParameterMutation("Change Buffer Mode") {
            infiniteBuffers = infinite
            noteParametersChanged()
        }
        parameterStatus(infinite
            ? "Network buffers set to infinite (capacity limits ignored)."
            : "Network buffers set to finite (per-buffer sizes apply).")
    }

    func updateNumberOfServers(nodeID: UUID, count: Int) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID && $0.kind == .station }) else {
            return
        }
        let clamped = max(1, count)
        guard nodes[index].numberOfServers != clamped else { return }
        performParameterMutation("Change Number of Servers") {
            nodes[index].numberOfServers = clamped
            recordToParameterCache(at: index)
            noteParametersChanged()
        }
        parameterStatus("Updated \(nodes[index].name) to \(clamped) server\(clamped == 1 ? "" : "s").")
    }

    /// Change the resource icon drawn inside a station circle.  `.none`
    /// returns the station to a plain circle.  Silently no-ops for other
    /// node kinds so the parameter editor can call this unconditionally.
    func updateStationPicture(nodeID: UUID, picture: StationPicture) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        guard nodes[index].kind == .station else { return }
        guard nodes[index].picture != picture else { return }
        performParameterMutation("Change Station Picture") {
            nodes[index].picture = picture
            recordToParameterCache(at: index)
        }
        if picture == .none {
            parameterStatus("Cleared picture on \(nodes[index].name).")
        } else {
            parameterStatus("Set \(nodes[index].name) picture to \"\(picture.displayName)\".")
        }
    }

    func updateNodeDistribution(
        nodeID: UUID,
        distribution: QueueDistribution,
        parameters: String
    ) {
        guard let index = nodes.firstIndex(where: {
            $0.id == nodeID && ($0.kind == .station || $0.kind == .source)
        }) else {
            return
        }

        let trimmed = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? distribution.defaultParameters : trimmed
        guard nodes[index].distribution != distribution
                || nodes[index].distributionParameters != resolved else { return }

        performParameterMutation("Change Distribution") {
            nodes[index].distribution = distribution
            nodes[index].distributionParameters = resolved
            recordToParameterCache(at: index)
            noteParametersChanged()
        }

        let processName = nodes[index].kind == .station ? "service" : "interarrival"
        parameterStatus(
            "Updated \(nodes[index].name) \(processName) distribution to \(distribution.displayName) (\(resolved))."
        )
    }

    func updateServiceDistribution(
        nodeID: UUID,
        customerClass: Int,
        distribution: QueueDistribution,
        parameters: String
    ) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID && $0.kind == .station }) else {
            return
        }
        let trimmed = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = trimmed.isEmpty ? distribution.defaultParameters : trimmed
        let config = ServiceDistributionConfig(
            distribution: distribution,
            distributionParameters: params
        )
        guard nodes[index].serviceDistributions[customerClass] != config else { return }
        performParameterMutation("Change Service Distribution") {
            nodes[index].serviceDistributions[customerClass] = config
            recordToParameterCache(at: index)
            noteParametersChanged()
        }
        parameterStatus(
            "Updated \(nodes[index].name) service distribution for \(CustomerClass.label(for: customerClass)) to \(distribution.displayName) (\(params))."
        )
    }

    // MARK: Parameter-edit grouping

    /// Set while `performParameterEdit` runs so the individual mutation
    /// methods stay quiet and the caller can emit one summary line.
    private var suppressParameterStatus = false
    /// Set when a parameter mutation happens inside an open
    /// begin/endMutation group; the notification is posted once at the end.
    private var pendingGroupTouchedParameters = false

    private func parameterStatus(_ message: String) {
        guard !suppressParameterStatus else { return }
        addStatus(message)
    }

    /// Marks the analysis stale and notifies the app (immediately, or when
    /// the enclosing mutation group ends).
    private func noteParametersChanged() {
        hasBeenAnalyzed = false
        if pendingMutationSnapshot != nil {
            pendingGroupTouchedParameters = true
        } else {
            NotificationCenter.default.post(name: .bnetNetworkParametersDidChange, object: self)
        }
    }

    /// One undo step on its own; folds into an open begin/endMutation
    /// group otherwise.
    private func performParameterMutation(_ name: String, _ block: () -> Void) {
        if pendingMutationSnapshot != nil {
            block()
        } else {
            performMutation(name, block)
        }
    }

    /// Runs every parameter mutation in `block` as ONE undo step named
    /// `name` (shown in the Edit menu), silences the per-field status
    /// lines, and emits `summary` once if anything actually changed.
    /// Returns true when the document changed.
    @discardableResult
    func performParameterEdit(_ name: String, summary: String? = nil, _ block: () -> Void) -> Bool {
        let ownsGroup = pendingMutationSnapshot == nil
        if ownsGroup { beginMutation(name) }
        let before = snapshot()
        suppressParameterStatus = true
        block()
        suppressParameterStatus = false
        let changed = before.nodes != nodes
            || before.links != links
            || before.infiniteBuffers != infiniteBuffers
        if ownsGroup { endMutation() }
        if changed, let summary { addStatus(summary) }
        return changed
    }

    // MARK: Coalesced parameter edits (docked inspector)

    /// Identity of the last field the docked inspector committed, so a
    /// run of commits to the SAME field of the SAME node folds into one
    /// undo step — the parameter-field counterpart of `nudgeSelection`,
    /// which coalesces a run of arrow presses into one "Move Node".
    private var parameterRunKey: String?
    private var lastParameterRunTime: Date = .distantPast
    /// A pause longer than this ends a field run, so two deliberate
    /// edits to the same field are two undo steps while a stepper held
    /// down (or a value retyped and re-blurred at once) is one.
    private static let parameterRunTimeout: TimeInterval = 2.0

    /// `performParameterEdit` for a commit-on-blur inspector. `key` names
    /// the field ("<nodeID>.servers"); consecutive commits with the same
    /// key inside `parameterRunTimeout` register NO new undo entry, so the
    /// entry registered by the first commit of the run restores the value
    /// from before the whole run — exactly one ⌘Z for one field, however
    /// many times the stepper was pressed. Any other mutation (a drag, a
    /// menu command, a commit to a different field) ends the run.
    /// Returns true when the document changed.
    @discardableResult
    func performCoalescedParameterEdit(key: String, name: String, summary: String? = nil,
                                       _ block: () -> Void) -> Bool {
        let now = Date()
        let continues = parameterRunKey == key
            && now.timeIntervalSince(lastParameterRunTime) < Self.parameterRunTimeout
            && pendingMutationSnapshot == nil
        parameterRunKey = key
        lastParameterRunTime = now
        guard continues else {
            return performParameterEdit(name, summary: summary, block)
        }
        // Same field, same run: apply without a new reversal. The first
        // commit's registration already restores the pre-run state. The
        // mutations run inside a throwaway group (never ended with
        // `endMutation`) so none of them registers an entry of its own.
        let before = snapshot()
        suppressParameterStatus = true
        pendingMutationSnapshot = before
        pendingMutationName = name
        block()
        pendingMutationSnapshot = nil
        pendingMutationName = nil
        suppressParameterStatus = false
        let touched = pendingGroupTouchedParameters
        pendingGroupTouchedParameters = false
        if touched {
            NotificationCenter.default.post(name: .bnetNetworkParametersDidChange, object: self)
        }
        let changed = before.nodes != nodes || before.links != links
            || before.infiniteBuffers != infiniteBuffers
        if changed, let summary { addStatus(summary) }
        return changed
    }

    /// Ends the current field run so the next commit registers its own
    /// undo entry. Called when the inspector moves to another node or link.
    func endParameterRun() {
        parameterRunKey = nil
        lastParameterRunTime = .distantPast
    }

    // MARK: Draft stability readout (inspector)

    /// Traffic-equation readout for one station under a DRAFT copy of the
    /// nodes — the inspector's "λ / c·μ / ρ" row. `draftNodes` is `nodes`
    /// with the edited node replaced by the draft's values, so the number
    /// reacts to a service rate the user has typed but not yet committed.
    /// Nil when the network has no source or no station, or the traffic
    /// equations cannot be solved (an unreachable station, say).
    static func stabilityReadout(
        for stationID: UUID, draftNodes: [NetworkNode], links: [NetworkLink], infiniteBuffers: Bool
    ) -> StationStabilityReadout? {
        guard draftNodes.contains(where: { $0.kind == .source }),
              let station = draftNodes.first(where: { $0.id == stationID && $0.kind == .station })
        else { return nil }
        guard case .success(let data) = SRBMExporter.computeData(
            nodes: draftNodes, links: links, infiniteBuffers: infiniteBuffers) else { return nil }
        let stations = draftNodes.filter { $0.kind == .station }
            .sorted { NodeNaming.sortIndex($0.name) < NodeNaming.sortIndex($1.name) }
        guard let k = stations.firstIndex(where: { $0.id == station.id }), k < data.d else { return nil }
        let capacity = data.capacity[k]
        let arrival = data.alpha[k]
        guard capacity.isFinite, arrival.isFinite else { return nil }
        var perClass: [Int: Double] = [:]
        for c in 0..<data.K where c < data.alphaPerClass.count && k < data.alphaPerClass[c].count {
            let v = data.alphaPerClass[c][k]
            if v.isFinite, v > 0 { perClass[c] = v }
        }
        return StationStabilityReadout(
            arrivalRate: arrival,
            capacity: capacity,
            servers: station.numberOfServers,
            arrivalRatePerClass: perClass)
    }

    // MARK: Link inspector helpers

    /// Other links leaving the same node with the same entry class as
    /// `linkID` — the routing "siblings" whose probabilities should sum
    /// to one together with this link.
    func siblingLinks(of linkID: UUID) -> [NetworkLink] {
        guard let link = link(with: linkID) else { return [] }
        return links.filter {
            $0.id != linkID
            && $0.fromNodeID == link.fromNodeID
            && $0.customerClass == link.customerClass
        }
    }

    /// Entry classes already used by *other* links on the same
    /// (from, to) pair — the inspector disables these so it can never
    /// create the duplicate that `cycleLinkCustomerClass` prevents.
    func entryClassesUsedByOtherLinks(onPairOf linkID: UUID) -> Set<Int> {
        guard let link = link(with: linkID) else { return [] }
        return Set(links.filter {
            $0.id != linkID
            && $0.fromNodeID == link.fromNodeID
            && $0.toNodeID == link.toNodeID
        }.map(\.customerClass))
    }

    /// "S1 → S2" style label for status lines and inspector headers.
    func displayLabel(for link: NetworkLink) -> String {
        let fromName = node(with: link.fromNodeID)?.name ?? "?"
        let toName = node(with: link.toNodeID)?.name ?? "?"
        return "\(fromName) → \(toName)"
    }

    func straightenNetwork() {
        guard !nodes.isEmpty else {
            addStatus("Nothing to straighten.")
            return
        }
        performMutation("Straighten Network") {
            straightenNodesInPlace()
            addStatus("Straightened network layout.")
        }
    }

    /// Aligns nodes along a horizontal line (sorted left-to-right by current x)
    /// at the average y, with uniform spacing. Does not emit a status message.
    private func straightenNodesInPlace() {
        let sortedByX = nodes.sorted { lhs, rhs in
            if lhs.position.x == rhs.position.x {
                return lhs.name < rhs.name
            }
            return lhs.position.x < rhs.position.x
        }

        let targetY = nodes.reduce(CGFloat.zero) { partial, node in
            partial + node.position.y
        } / CGFloat(nodes.count)

        let minX = sortedByX.first?.position.x ?? 80
        let spacing: CGFloat = 88

        var newPositions: [UUID: CGPoint] = [:]
        for (index, node) in sortedByX.enumerated() {
            let x = minX + CGFloat(index) * spacing
            newPositions[node.id] = CGPoint(x: x, y: targetY)
        }

        for index in nodes.indices {
            if let newPoint = newPositions[nodes[index].id] {
                nodes[index].position = newPoint
            }
        }
    }

    /// Network ▸ Straighten and Fit to Window: straightens the network into
    /// a horizontal row, then centers it on the canvas and rescales
    /// positions so the full row fits within the viewport with a
    /// comfortable margin. This *rewrites node positions* (undoable as one
    /// step) — unlike `zoomToFit()`, which only changes the view.
    func fitNetworkToWindow() {
        guard !nodes.isEmpty else {
            addStatus("Nothing to fit.")
            return
        }
        let size = canvasViewportSize
        guard size.width > 1, size.height > 1 else {
            addStatus("Canvas size not yet known; try again after the window finishes laying out.")
            return
        }

        // The relayout rewrites every node position, so it is one undoable
        // step ("Undo Straighten and Fit").
        performMutation("Straighten and Fit") {
            fitNetworkToWindowInPlace(viewport: size)
        }
        // Positions were laid out for the identity view, so show it
        // (animated) — at zoom 1 with no pan, world == display.
        canvasAnimationToken &+= 1
        canvasScale = 1.0
        canvasPanOffset = .zero
        addStatus("Straightened and fit the network to the window.")
    }

    private func fitNetworkToWindowInPlace(viewport size: CGSize) {
        // Straighten first so the fit always starts from a predictable layout,
        // regardless of where the user had dragged the nodes.
        straightenNodesInPlace()

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity
        for node in nodes {
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x)
            maxY = max(maxY, node.position.y)
        }

        let bboxW = max(maxX - minX, 1)
        let bboxH = max(maxY - minY, 1)
        let bboxCX = (minX + maxX) / 2
        let bboxCY = (minY + maxY) / 2

        // Margin accounts for node radius (~30pt), labels, and visual breathing room.
        let margin: CGFloat = 80
        let availW = max(size.width  - 2 * margin, 100)
        let availH = max(size.height - 2 * margin, 100)

        // Uniform scale so the network fills as much of the viewport as possible
        // while preserving aspect ratio.
        let scale = min(availW / bboxW, availH / bboxH)

        let targetCX = size.width  / 2
        let targetCY = size.height / 2

        for i in nodes.indices {
            let dx = nodes[i].position.x - bboxCX
            let dy = nodes[i].position.y - bboxCY
            nodes[i].position = CGPoint(
                x: targetCX + dx * scale,
                y: targetCY + dy * scale
            )
        }
    }

    /// Edit ▸ Clear Canvas… — empties the document in ONE undoable step.
    ///
    /// The confirmation alert promises "This can be undone with Edit ▸ Undo",
    /// so the document-mutating part goes through `performMutation`: the
    /// snapshot carries nodes, links, the buffer regime AND all four name
    /// counters, so one ⌘Z brings the network back with its numbering intact
    /// (the next station placed after an undone clear continues the sequence
    /// instead of restarting at S1).
    ///
    /// Everything else here is view state — selection, hover, the flag bar's
    /// analysis fields — and is deliberately reset OUTSIDE the block: undo
    /// restores documents, not what was hovered when the user cleared.
    /// `markDocumentClean()` is gone with the same reasoning: a cleared
    /// document differs from the file on disk, and the tab's edited dot has
    /// to say so, or a clear-then-quit loses the file silently.
    func clear() {
        // The parameter cache is a safety-net overlay keyed by node UUID and
        // is not part of the document. Wiping it is harmless under undo:
        // `openParameterEditor` simply finds no overlay and reads the node's
        // own restored values.
        parameterCache.clear()

        performMutation("Clear Canvas") {
            nodes.removeAll()
            links.removeAll()
            infiniteBuffers = false
            stationCount = 0
            bufferCount = 0
            sourceCount = 0
            sinkCount = 0
        }

        selectedNodeID = nil
        selectedNodeIDs.removeAll()
        multiSelectRect = nil
        multiSelectOrigin = nil
        selectedLinkID = nil
        pendingLinkStartID = nil
        activeLinkSourceID = nil
        parameterEditorTarget = nil
        linkParameterEditorTarget = nil
        showSRBMExportSheet = false
        currentFileURL = nil
        hoveredNodeID = nil
        hoveredLinkID = nil
        stationUtilisation = [:]
        networkHasWarnings = false
        networkWarningList = []
        hasBeenAnalyzed = false
        classFilter = nil
        isAnalyticallyTractable = false
        tractabilityTitle = ""
        tractabilityDetail = ""
        tractabilityMeans = []
        tractabilityMeansLabel = ""
        tractabilityExplanation = ""
        tractabilityIsExact = false
        hasFeedback = false
        feedbackDescription = ""
        feedbackQuality = .notReentrant
        feedbackCriteria = []
        addStatus("Canvas cleared. Edit ▸ Undo brings the network back.")
    }

    func loadNetwork(document: NetworkDocument) {
        // The on-disk parameter cache belongs to the previous document,
        // so wipe it before swapping content. Otherwise, opening the
        // parameter editor on a node whose UUID happens to collide with
        // a cached entry from a prior tab life would paste stale values
        // over fresh document contents.
        parameterCache.clear()

        nodes = document.nodes
        links = document.links
        infiniteBuffers = document.infiniteBuffers
        canvasScale = document.canvasScale
        canvasPanOffset = document.canvasPanOffset
        selectedNodeID = nil
        selectedNodeIDs.removeAll()
        multiSelectRect = nil
        multiSelectOrigin = nil
        selectedLinkID = nil
        pendingLinkStartID = nil
        activeLinkSourceID = nil
        parameterEditorTarget = nil
        linkParameterEditorTarget = nil
        showSRBMExportSheet = false
        hoveredNodeID = nil
        hoveredLinkID = nil
        // Force a fresh analysis for the new network contents. The caller
        // decides whether to run the full primitives report (loadNetworkFile)
        // or a silent background analysis (tab activation).
        networkHasWarnings = false
        networkWarningList = []
        hasBeenAnalyzed = false
        classFilter = nil
        isAnalyticallyTractable = false
        tractabilityTitle = ""
        tractabilityDetail = ""
        tractabilityMeans = []
        tractabilityMeansLabel = ""
        tractabilityExplanation = ""
        tractabilityIsExact = false
        hasFeedback = false
        feedbackDescription = ""
        feedbackQuality = .notReentrant
        feedbackCriteria = []

        // Restore counters by scanning loaded node names
        stationCount = maxNameIndex(kind: .station, prefix: "S")
        bufferCount  = maxNameIndex(kind: .buffer, prefix: "B")
        sourceCount  = maxNameIndex(kind: .source, prefix: "Src")
        sinkCount    = maxNameIndex(kind: .sink, prefix: "Sink")

        addStatus("Loaded network with \(nodes.count) nodes and \(links.count) links.")
        markDocumentClean()
    }

    // MARK: - Multi-Selection

    func beginMultiSelect(at point: CGPoint) {
        multiSelectOrigin = point
        multiSelectRect = CGRect(origin: point, size: .zero)
    }

    func updateMultiSelect(to point: CGPoint) {
        guard let origin = multiSelectOrigin else { return }
        let x = min(origin.x, point.x)
        let y = min(origin.y, point.y)
        let w = abs(point.x - origin.x)
        let h = abs(point.y - origin.y)
        multiSelectRect = CGRect(x: x, y: y, width: w, height: h)
    }

    /// Commits the rubber-band.  A plain marquee replaces the selection;
    /// `extending` (⇧-drag) unions the enclosed nodes with what was
    /// already selected.
    func finalizeMultiSelect(extending: Bool = false) {
        guard let rect = multiSelectRect else { return }
        // Intersection, not centre containment: a node the band touches
        // is selected (the OmniGraffle / Figma rule).  The live preview
        // highlight and `marqueeNodeCount` use the same predicate, so
        // what lights up is exactly what is committed.
        let enclosed = Set(nodes.filter { CanvasScene.marqueeSelects($0, rect: rect) }.map(\.id))
        var group = enclosed
        if extending {
            group.formUnion(selectedNodeIDs)
            if let single = selectedNodeID { group.insert(single) }
        }
        multiSelectRect = nil
        multiSelectOrigin = nil
        if group.isEmpty {
            if !extending {
                selectedNodeIDs = []
                selectedNodeID = nil
            }
            return
        }
        // Marquee results stay a group even when one node is enclosed, so
        // the alignment commands and the status bar count agree with what
        // the user just drew.  Silent by design: the canvas status bar
        // counts the selection live, so the status log stays a record of
        // solver output and document changes.
        selectedNodeIDs = group
        selectedNodeID = nil
        // Through `setTool`, never a bare assignment: the marquee is a
        // borrowed mode, and returning to the Pointer has to end the
        // sticky-pan memo and any pending link chain with it. `.select`
        // is exempt from `setTool`'s multi-selection clear, so the group
        // just committed survives the call.
        setTool(.select)
    }

    func clearMultiSelection() {
        selectedNodeIDs.removeAll()
        multiSelectRect = nil
        multiSelectOrigin = nil
    }

    /// Case-insensitive substring search through node names. Returns
    /// the first match's ID (or nil). Selects the match and zooms the
    /// canvas to centre it — handy for large networks.
    @discardableResult
    func findAndRevealNode(named query: String) -> UUID? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        guard let match = nodes.first(where: { $0.name.lowercased().contains(q) })
        else {
            addStatus("No node matches \"\(query)\".")
            return nil
        }
        selectedNodeIDs = [match.id]
        selectedNodeID = match.id
        selectedLinkID = nil
        zoomToFitSelection()
        addStatus("Found \(match.name).")
        return match.id
    }

    func selectAll() {
        selectedNodeIDs = Set(nodes.map(\.id))
        selectedNodeID = nil
        selectedLinkID = nil
        if !selectedNodeIDs.isEmpty {
            // `setTool`, not a bare assignment — see `selectedTool`.
            setTool(.select)
        }
    }

    // MARK: - Zoom / pan

    /// Current zoom / pan / viewport triple.
    var canvasTransform: CanvasTransform {
        CanvasTransform(scale: canvasScale, pan: canvasPanOffset, viewportSize: canvasViewportSize)
    }

    /// Geometric zoom step used by the menu, the zoom cluster and ⌘+/⌘−.
    static let zoomStep: CGFloat = 1.25

    /// Zoom in one step about the viewport centre (animated).
    func zoomIn() {
        zoom(by: Self.zoomStep, about: canvasTransform.viewportCentre, animated: true)
    }

    /// Zoom out one step about the viewport centre (animated).
    func zoomOut() {
        zoom(by: 1 / Self.zoomStep, about: canvasTransform.viewportCentre, animated: true)
    }

    /// Multiply the zoom by `factor`, keeping the world point under
    /// `displayAnchor` fixed.  Used by the wheel and pinch handlers.
    func zoom(by factor: CGFloat, about displayAnchor: CGPoint, animated: Bool = false) {
        zoom(to: canvasScale * factor, about: displayAnchor, animated: animated)
    }

    /// Set the zoom to `newScale` (clamped to `zoomRange`), keeping the
    /// world point under `displayAnchor` fixed.
    func zoom(to newScale: CGFloat, about displayAnchor: CGPoint, animated: Bool = false) {
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newScale))
        guard clamped != canvasScale else { return }
        let t = canvasTransform.zoomed(to: clamped, about: displayAnchor)
        apply(t, animated: animated)
    }

    /// Set the zoom to an absolute value about the viewport centre
    /// (animated) — the zoom-cluster percentage menu.
    func setZoom(_ newScale: CGFloat) {
        zoom(to: newScale, about: canvasTransform.viewportCentre, animated: true)
    }

    /// Shift the view by `delta` display points (two-finger scroll).
    func pan(by delta: CGSize) {
        canvasPanOffset = CGSize(width: canvasPanOffset.width + delta.width,
                                 height: canvasPanOffset.height + delta.height)
    }

    /// Actual Size (⌘0): zoom 100 % with the world origin in the top-left
    /// corner — the view every pre-zoom document was authored in.
    func resetZoom() {
        apply(CanvasTransform(scale: 1, pan: .zero, viewportSize: canvasViewportSize), animated: true)
    }

    /// Zoom to Fit (⇧⌘0): frame the whole network.
    func zoomToFit() {
        fit(nodes: nodes)
    }

    /// Zoom to Selection (⌥⇧⌘0): frame the selection, or the whole
    /// network when nothing is selected. No-op until the canvas has
    /// reported its size.
    func zoomToFitSelection() {
        let ids = currentSelectionIDs()
        fit(nodes: ids.isEmpty ? nodes : nodes.filter { ids.contains($0.id) })
    }

    private func fit(nodes targets: [NetworkNode]) {
        guard let bounds = CanvasScene.bounds(of: targets) else { return }
        let size = canvasViewportSize
        guard size.width > 1, size.height > 1 else { return }
        // Margin covers the node body, its label block and breathing room.
        let t = CanvasTransform.fitting(worldRect: bounds, in: size,
                                        margin: 88, zoomRange: Self.zoomRange)
        apply(t, animated: true)
    }

    private func apply(_ t: CanvasTransform, animated: Bool) {
        if animated { canvasAnimationToken &+= 1 }
        canvasScale = t.scale
        canvasPanOffset = t.pan
    }

    /// Number of nodes the in-progress marquee currently encloses, or nil
    /// when no marquee is active.  Shown live in the status bar.
    var marqueeNodeCount: Int? {
        guard let rect = multiSelectRect else { return nil }
        return nodes.reduce(0) { CanvasScene.marqueeSelects($1, rect: rect) ? $0 + 1 : $0 }
    }

    /// The detours every link takes around the nodes it is not attached
    /// to, memoised on the layout.
    ///
    /// Routing depends on where the nodes are and nothing else, so this
    /// survives every pan, zoom, hover and selection change and is
    /// rebuilt only when a node or a link actually moves.  One plan for
    /// the whole app: the renderer, the right-click hit test and the
    /// diagram export all read it, so all three see the same arrows.
    ///
    /// Frozen for the length of a node drag: while `isDraggingNode` is
    /// set the last plan is handed out unchanged, however far the nodes
    /// have moved, and the first read after the release re-plans once.
    /// Re-planning every drag frame cost the full build (≈ 4 ms at 200
    /// nodes) sixty times a second and, worse, made links snap between
    /// rungs of the bulge ladder as the dragged node grazed a chord.  The
    /// canvas eases the routes into place when the plan changes.
    var routePlan: LinkRoutePlan {
        if let cachedRoutePlan, cachedRoutePlanNodes == nodes, cachedRoutePlanLinks == links {
            return cachedRoutePlan
        }
        if isDraggingNode, let cachedRoutePlan, cachedRoutePlanLinks == links {
            return cachedRoutePlan
        }
        let plan = LinkRoutePlan.build(nodes: nodes, links: links)
        cachedRoutePlan = plan
        cachedRoutePlanNodes = nodes
        cachedRoutePlanLinks = links
        return plan
    }
    private var cachedRoutePlan: LinkRoutePlan?
    private var cachedRoutePlanNodes: [NetworkNode] = []
    private var cachedRoutePlanLinks: [NetworkLink] = []

    /// Resolved geometry for the current state — the same builder the
    /// canvas renders from, so AppKit-side hit tests (right-click) agree
    /// with what is on screen.
    func makeScene() -> CanvasScene {
        CanvasScene(nodes: nodes, links: links, transform: canvasTransform,
                    classFilter: classFilter, routePlan: routePlan)
    }

    /// Recompute `stationUtilisation` from the traffic equations.  Cheap
    /// (one small linear solve) and side-effect free; a network that
    /// cannot be analysed simply yields no badges.
    func refreshStationUtilisation() {
        guard nodes.contains(where: { $0.kind == .station }),
              nodes.contains(where: { $0.kind == .source }) else {
            if !stationUtilisation.isEmpty { stationUtilisation = [:] }
            return
        }
        switch SRBMExporter.computeData(nodes: nodes, links: links, infiniteBuffers: infiniteBuffers) {
        case .success(let data):
            // computeData orders stations by the numeric suffix of their
            // name (S1, S2, …) — mirror that ordering to map k → node.
            let stations = nodes.filter { $0.kind == .station }
                .sorted { Self.nameIndex($0.name) < Self.nameIndex($1.name) }
            var result: [UUID: Double] = [:]
            for (k, station) in stations.enumerated() where k < data.d {
                guard data.capacity[k] > 1e-12 else { continue }
                let rho = data.alpha[k] / data.capacity[k]
                if rho.isFinite { result[station.id] = rho }
            }
            if result != stationUtilisation { stationUtilisation = result }
        case .failure:
            if !stationUtilisation.isEmpty { stationUtilisation = [:] }
        }
    }

    private static func nameIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    func moveSelectedNodes(by delta: CGSize) {
        for index in nodes.indices where selectedNodeIDs.contains(nodes[index].id) {
            nodes[index].position.x += delta.width
            nodes[index].position.y += delta.height
        }
    }

    // MARK: - Alignment / distribution of the multi-selected group
    //
    // The eight helpers are the set every diagramming tool ships — four
    // edges, two centres, two distributions.  All are no-ops unless at least
    // two nodes are selected.  Distribution is further guarded at three
    // nodes (with only two, the end-points are already "distributed" — there
    // is nothing between them to space out).  Positions are in
    // logical-canvas coordinates; the renderer applies the zoom transform at
    // draw time.
    //
    // `NetworkNode.position` is the node's CENTRE, so "Align Left" snapping
    // every node to the smallest x is an edge alignment only because every
    // node kind is drawn at the same width; the two centre helpers below are
    // the axis-midpoint of the selection's own extent, which is what
    // OmniGraffle, Visio and Figma all call "align centres".

    /// Snap every selected node to the Y of the topmost selected node.
    func alignSelectedNodesTop() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Top") {
            let ys = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.y }
            guard let minY = ys.min() else { return }
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.y = minY
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to top.")
        }
    }

    /// Snap every selected node to the Y of the bottommost selected node.
    func alignSelectedNodesBottom() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Bottom") {
            let ys = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.y }
            guard let maxY = ys.max() else { return }
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.y = maxY
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to bottom.")
        }
    }

    /// Snap every selected node to the X of the leftmost selected node.
    func alignSelectedNodesLeft() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Left") {
            let xs = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.x }
            guard let minX = xs.min() else { return }
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.x = minX
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to left.")
        }
    }

    /// Snap every selected node to the X of the rightmost selected node.
    func alignSelectedNodesRight() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Right") {
            let xs = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.x }
            guard let maxX = xs.max() else { return }
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.x = maxX
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to right.")
        }
    }

    /// Snap every selected node onto the vertical line halfway between the
    /// leftmost and rightmost of them, preserving each node's Y.
    func alignSelectedNodesHorizontalCentres() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Horizontal Centres") {
            let xs = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.x }
            guard let minX = xs.min(), let maxX = xs.max() else { return }
            let centre = (minX + maxX) / 2
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.x = centre
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to their horizontal centre.")
        }
    }

    /// Snap every selected node onto the horizontal line halfway between the
    /// topmost and bottommost of them, preserving each node's X.
    func alignSelectedNodesVerticalCentres() {
        guard selectedNodeIDs.count >= 2 else { return }
        performMutation("Align Vertical Centres") {
            let ys = nodes.filter { selectedNodeIDs.contains($0.id) }
                          .map { $0.position.y }
            guard let minY = ys.min(), let maxY = ys.max() else { return }
            let centre = (minY + maxY) / 2
            for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
                nodes[i].position.y = centre
            }
            addStatus("Aligned \(selectedNodeIDs.count) nodes to their vertical centre.")
        }
    }

    /// Keep the leftmost and rightmost selected nodes in place; evenly space
    /// the intermediate ones along X, preserving each node's Y.
    func distributeSelectedNodesHorizontally() {
        guard selectedNodeIDs.count >= 3 else { return }
        performMutation("Distribute Horizontally") {
            let sorted = nodes.indices
                .filter { selectedNodeIDs.contains(nodes[$0].id) }
                .sorted { nodes[$0].position.x < nodes[$1].position.x }
            guard let firstIdx = sorted.first, let lastIdx = sorted.last else { return }
            let xMin = nodes[firstIdx].position.x
            let xMax = nodes[lastIdx].position.x
            let n = sorted.count
            guard xMax > xMin else { return }
            let step = (xMax - xMin) / CGFloat(n - 1)
            for (rank, idx) in sorted.enumerated() {
                nodes[idx].position.x = xMin + step * CGFloat(rank)
            }
            addStatus("Distributed \(n) nodes horizontally.")
        }
    }

    /// Keep the topmost and bottommost selected nodes in place; evenly space
    /// the intermediate ones along Y, preserving each node's X.
    func distributeSelectedNodesVertically() {
        guard selectedNodeIDs.count >= 3 else { return }
        performMutation("Distribute Vertically") {
            let sorted = nodes.indices
                .filter { selectedNodeIDs.contains(nodes[$0].id) }
                .sorted { nodes[$0].position.y < nodes[$1].position.y }
            guard let firstIdx = sorted.first, let lastIdx = sorted.last else { return }
            let yMin = nodes[firstIdx].position.y
            let yMax = nodes[lastIdx].position.y
            let n = sorted.count
            guard yMax > yMin else { return }
            let step = (yMax - yMin) / CGFloat(n - 1)
            for (rank, idx) in sorted.enumerated() {
                nodes[idx].position.y = yMin + step * CGFloat(rank)
            }
            addStatus("Distributed \(n) nodes vertically.")
        }
    }

    /// Shifts every selected node by `delta` world pt as one undoable
    /// step, coalescing a run of arrow presses.
    ///
    /// Holding an arrow key fires ~15 times a second; registering an undo
    /// per press would bury the Edit menu under "Undo Move Nodes"
    /// fifteen deep for one second of travel, which no diagramming app
    /// does.  Instead the first press of a run opens one undo group and
    /// every press inside `nudgeRunTimeout` of the last one — on the same
    /// selection — mutates inside it.  The group closes on key-up
    /// (`endNudgeRun`), on a change of selection, when another mutation
    /// begins, or when the run simply goes quiet.
    ///
    /// Snapping is applied to the *anchor* node only and the resulting
    /// delta is given to the whole group.  Re-snapping each node
    /// independently would collapse a group whose members sit at
    /// different sub-grid offsets (x = 10 and x = 15 both landing on 28),
    /// silently destroying a layout the user arranged by hand.
    func nudgeSelection(by delta: CGSize) {
        let ids = currentSelectionIDs()
        guard !ids.isEmpty else { return }

        let now = Date()
        let continues = nudgeRunIDs == ids
            && now.timeIntervalSince(lastNudgeTime) < Self.nudgeRunTimeout
        if !continues {
            endNudgeRun()
            beginMutation(ids.count > 1 ? "Move Nodes" : "Move Node")
            nudgeRunIDs = ids
        }
        lastNudgeTime = now

        // Anchor: the single selected node, else the first in reading
        // order, so the same node leads the group every press.
        let anchorID = selectedNodeID
            ?? nodesInReadingOrder.first(where: { ids.contains($0.id) })?.id
        var applied = delta
        if snapToGrid, let anchorID,
           let anchor = nodes.first(where: { $0.id == anchorID }) {
            let target = snapIfNeeded(CGPoint(x: anchor.position.x + delta.width,
                                              y: anchor.position.y + delta.height))
            applied = CGSize(width: target.x - anchor.position.x,
                             height: target.y - anchor.position.y)
            // A whole-cell nudge on an already-snapped anchor rounds to
            // zero movement only if the step is degenerate; never let an
            // arrow press do nothing at all.
            if applied.width == 0 && applied.height == 0 { applied = delta }
        }
        for i in nodes.indices where ids.contains(nodes[i].id) {
            nodes[i].position.x += applied.width
            nodes[i].position.y += applied.height
        }
    }

    /// Closes an open arrow-key nudge run, committing its single undo
    /// step.  Called on arrow key-up, when the selection changes and
    /// before any other mutation opens its own group.
    func endNudgeRun() {
        guard nudgeRunIDs != nil else { return }
        nudgeRunIDs = nil
        lastNudgeTime = .distantPast
        endMutation()
    }

    /// A pause longer than this ends a nudge run, so two deliberate
    /// presses are two undo steps while auto-repeat is one.
    private static let nudgeRunTimeout: TimeInterval = 1.2

    /// One arrow-key step, in world points.  Snap to Grid makes the step
    /// a whole grid cell (⇧ = four cells) so a snapped node can never be
    /// knocked off the grid by an arrow press; without snapping it stays
    /// the fine 1 pt / 10 pt nudge.
    func nudgeStep(coarse: Bool) -> CGFloat {
        if snapToGrid { return Self.gridSpacing * (coarse ? 4 : 1) }
        return coarse ? 10 : 1
    }

    /// Nodes in reading order (top-to-bottom, then left-to-right) — the
    /// order Tab / ⇧Tab walk on the canvas.
    var nodesInReadingOrder: [NetworkNode] {
        nodes.sorted {
            $0.position.y == $1.position.y
                ? $0.position.x < $1.position.x
                : $0.position.y < $1.position.y
        }
    }

    /// Moves the selection to the next (or previous) node in reading
    /// order and returns it, so keyboard-only users can reach every node.
    /// With nothing selected it starts at the first / last node.
    @discardableResult
    func selectAdjacentNode(reverse: Bool) -> NetworkNode? {
        let ordered = nodesInReadingOrder
        guard !ordered.isEmpty else { return nil }
        let current = selectedNodeID ?? (selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil)
        var index: Int
        if let current, let at = ordered.firstIndex(where: { $0.id == current }) {
            index = reverse ? at - 1 : at + 1
            if index < 0 { index = ordered.count - 1 }
            if index >= ordered.count { index = 0 }
        } else {
            index = reverse ? ordered.count - 1 : 0
        }
        let target = ordered[index]
        setNodeSelection([target.id])
        selectedLinkID = nil
        return target
    }

    func primitiveSummary() -> String {
        let stations = nodes.filter { $0.kind == .station }.count
        let buffers = nodes.filter { $0.kind == .buffer }.count
        let sources = nodes.filter { $0.kind == .source }.count
        let sinks = nodes.filter { $0.kind == .sink }.count

        return "Sources: \(sources) | Stations: \(stations) | Buffers: \(buffers) | Sinks: \(sinks) | Links: \(links.count)"
    }

    // MARK: - Status log

    /// The entries the last Clear Status Log removed, kept until the next
    /// clear so the empty log can offer one Undo. Lives on the editor —
    /// not in the Status pane's view state — so hiding the pane (⌥⌘2)
    /// no longer silently discards the undo the user was just offered.
    @Published private(set) var clearedStatusBacklog: [StatusEntry] = []

    /// The one Clear Status Log. The pane's trash button, the list's
    /// context menu and Edit ▸ Clear Status Log all call this, so the
    /// command confirms, keeps an undo backlog and leaves the log truly
    /// empty (no injected "cleared" line, which would hide the Undo Clear
    /// empty state) wherever it is invoked from. Returns true when the log
    /// was actually cleared.
    /// Number of entries above which Clear Status Log asks first.
    static let clearConfirmThreshold = 20

    @discardableResult
    func clearStatusLog(confirmWhenLong: Bool = true) -> Bool {
        let entries = statusMessages
        guard !entries.isEmpty else { return false }
        if confirmWhenLong, entries.count > Self.clearConfirmThreshold {
            guard ConfirmAlert.destructive(
                title: "Clear the status log?",
                message: "All \(entries.count) entries will be removed and will not be restored on the next launch. Copy All keeps a copy first; Undo Clear in the empty log brings them back until the next clear.",
                confirmTitle: "Clear Status Log"
            ) else { return false }
        }
        clearedStatusBacklog = entries
        statusMessages.removeAll(keepingCapacity: true)
        return true
    }

    /// Puts the last cleared backlog back at the top of the log.
    func undoClearStatusLog() {
        guard !clearedStatusBacklog.isEmpty else { return }
        statusMessages = clearedStatusBacklog + statusMessages
        clearedStatusBacklog = []
    }

    /// Appends an entry whose severity is inferred from the wording
    /// (see `StatusEntry.inferSeverity`).
    func addStatus(_ message: String) {
        addStatus(message, severity: StatusEntry.inferSeverity(message))
    }

    func addStatus(_ message: String, severity: StatusSeverity) {
        statusMessages.append(StatusEntry(text: message, severity: severity))
    }

    func node(with id: UUID) -> NetworkNode? {
        nodes.first(where: { $0.id == id })
    }

    func link(with id: UUID) -> NetworkLink? {
        links.first(where: { $0.id == id })
    }

    // MARK: - Link Chain Creation (Multi-Class)

    private func handleLinkSelection(_ nodeID: UUID) {
        guard let tappedNode = node(with: nodeID) else { return }

        // ── First click: set the start of the link ──
        guard let startID = pendingLinkStartID else {
            // A sink is terminal, and every exporter drops a link that
            // leaves one (SRBMExporter and friends walk source → buffer →
            // station → sink only), so arming a sink as a chain start can
            // only ever end in a refusal or — worse — in a link that is
            // drawn, counted and then silently not solved. Say so now,
            // before the invitation to "click target node" is issued.
            if tappedNode.kind == .sink {
                addStatus("Cannot link out of \(tappedNode.name): a sink is where jobs leave the network.")
                return
            }
            if tappedNode.kind == .source {
                let classIndex = customerClassIndex(for: nodeID)
                activeCustomerClass = classIndex
                activeLinkSourceID = nodeID
            } else {
                activeLinkSourceID = nil
            }
            pendingLinkStartID = nodeID
            selectedNodeID = nodeID
            selectedLinkID = nil
            addStatus("Link start: \(tappedNode.name). Click target node.")
            return
        }

        // ── Second click: create the link ──
        // A second click on the SAME node is how a user draws a self-loop —
        // the feedback arc P[i][i] > 0 that the solvers, the routing
        // diagnostics (Network ▸ Analyze Network lists self-loop stations)
        // and the renderer (LinkGeometry.selfLoop, nested by extraRadius for
        // multi-class loops) all already speak about. It is only meaningless
        // at the two ends of the network, so those are the only refusals, and
        // each says why.
        if startID == nodeID {
            switch tappedNode.kind {
            case .source:
                addStatus("Cannot link \(tappedNode.name) to itself: a source has no service to repeat.")
                pendingLinkStartID = nil
                return
            case .sink:
                addStatus("Cannot link \(tappedNode.name) to itself: a sink is where jobs leave the network.")
                pendingLinkStartID = nil
                return
            case .buffer:
                // A buffer holds jobs; it does not serve them, so a job
                // leaving B_i for B_i is a no-op the exporters would have to
                // read as a routing probability out of a node with no service.
                addStatus("Cannot link \(tappedNode.name) to itself: a buffer has no service to repeat — put the loop on the station it feeds.")
                pendingLinkStartID = nil
                return
            case .station:
                break   // falls through to the ordinary class-selection path
            }
        }

        guard let startNode = node(with: startID) else {
            pendingLinkStartID = nil
            return
        }

        // Determine candidate customer classes for a link from startNode.
        let candidateClasses: [Int]
        if startNode.kind == .source {
            candidateClasses = [customerClassIndex(for: startID)]
        } else if startNode.kind == .buffer || startNode.kind == .station {
            let incoming = Set(links.filter { $0.toNodeID == startID }.map(\.customerClass))
            if incoming.isEmpty {
                addStatus("Cannot add link: \(startNode.name) has no incoming links.")
                pendingLinkStartID = nil
                return
            }
            candidateClasses = incoming.sorted()
        } else {
            // A sink, reached as a chain start by any route: refuse. The
            // exporters ignore a link out of a sink, so accepting one here
            // would draw and count an arc that the solvers never see —
            // exactly the drawn-versus-solved divergence this app's
            // result-claim vocabulary exists to prevent.
            addStatus("Cannot link out of \(startNode.name): a sink is where jobs leave the network.")
            pendingLinkStartID = nil
            return
        }

        // Find classes already used between start and target.
        let usedClasses = Set(
            links.filter { $0.fromNodeID == startID && $0.toNodeID == nodeID }
                .map(\.customerClass)
        )

        // Available = candidates not yet used for this pair.
        let available = candidateClasses.filter { !usedClasses.contains($0) }
        if available.isEmpty {
            addStatus("All available classes already linked from \(startNode.name) to \(tappedNode.name).")
            return
        }

        // Pick default: class 0 (Class 1) if available, otherwise lowest available.
        let chosenClass = available.contains(0) ? 0 : available.first!

        performMutation("Add Link") {
            let link = NetworkLink(
                fromNodeID: startID,
                toNodeID: nodeID,
                customerClass: chosenClass
            )
            links.append(link)
            selectedLinkID = link.id
            activeCustomerClass = chosenClass

            // A chain that has reached the sink is finished: the sink is
            // terminal, so inviting the next click to "continue chain"
            // would only walk into the refusal above.
            let chainEnds = (tappedNode.kind == .sink)
            addStatus(
                "Linked \(linkLabel(link)) [\(CustomerClass.label(for: chosenClass))]."
                + (chainEnds
                   ? " Chain complete at \(tappedNode.name) — click a node to start another."
                   : " Click next node to continue chain.")
            )

            // A new link is born at p = 1.0, so the moment a node has a
            // SECOND outgoing link on the same class its routing sums past 1
            // and the network stops exporting — `--dump-rho` fails with
            // `routingProbabilityExceedsOne`. The self-loop hits this every
            // single time (a station in a finished chain already has its one
            // forward link at 1.0), which would make the feedback gesture
            // always leave the document unrunnable with nothing said. The
            // Inspector carries the fix ("Balance to 1"), and the new link is
            // already selected, so all that is missing is being told.
            let outgoingTotal = links
                .filter { $0.fromNodeID == startID && $0.customerClass == chosenClass }
                .reduce(0.0) { $0 + $1.routingProbability }
            if outgoingTotal > 1.0 + 1e-6 {
                addStatus(
                    "Routing from \(startNode.name) for \(CustomerClass.label(for: chosenClass)) now sums to "
                    + "\(DS.Number.format(outgoingTotal, significantDigits: DS.Number.readoutDigits))"
                    + " — set the probabilities in the Inspector."
                )
            }

            // Continue the chain: the clicked node becomes the new start —
            // unless it is the sink, which nothing may leave.
            pendingLinkStartID = chainEnds ? nil : nodeID
            selectedNodeID = nodeID
        }
    }

    private func cycleLinkCustomerClass(linkID: UUID) {
        guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }
        let link = links[index]
        let totalClasses = max(numberOfCustomerClasses, 1)

        // Classes already used by OTHER links between the same pair
        let usedClasses = Set(
            links.filter {
                $0.fromNodeID == link.fromNodeID
                && $0.toNodeID == link.toNodeID
                && $0.id != linkID
            }.map(\.customerClass)
        )

        // Find the next available class (cycling from current)
        for offset in 1...totalClasses {
            let nextClass = (link.customerClass + offset) % totalClasses
            if !usedClasses.contains(nextClass) {
                performMutation("Change Link Class") {
                    links[index].customerClass = nextClass
                    noteParametersChanged()
                }
                addStatus("Changed \(linkLabel(links[index])) to \(CustomerClass.label(for: nextClass)).")
                return
            }
        }
        addStatus("All customer classes are already used for this link pair.")
    }

    // MARK: - Public Mutation API

    /// The load a freshly placed node is born at: λ = 1 into a station
    /// served at μ = λ / ρ, i.e. ρ = 0.9. The same regime every bundled
    /// example uses (`validation/example_contracts.py` asserts λ = 1,
    /// μ = 1.1111111, ρ = 0.9) and the same default `RandomNetworkGenerator`
    /// and the archetype gallery build to, so a network is a network however
    /// it got onto the canvas.
    ///
    /// The three constants are one statement in three spellings — λ, ρ, and
    /// μ = λ / ρ as the string the parameter sheet shows. `defaultArrivalRate`
    /// mirrors `QueueDistribution.poisson.defaultParameters` ("lambda=1.0"),
    /// which is what a placed source actually carries; change one and change
    /// all three.
    private static let defaultArrivalRate = 1.0
    private static let defaultTargetRho = 0.9
    /// μ as a parameter string, spelled exactly as the bundled examples
    /// spell it so a hand-built chain and a loaded one read identically in
    /// the Inspector.
    private static let defaultServiceRateLiteral = "1.1111111"

    /// Add a node to the canvas. Shared by the click-to-place palette
    /// path (which leaves `name` nil so the auto-namer picks "S1", "B3",
    /// etc.) and the AI Assistant's `add_node` tool (which can pass an
    /// explicit name). Returns the created node so callers can refer to
    /// it for follow-up edits in the same turn.
    @discardableResult
    func addNode(kind: NodeKind, at location: CGPoint, name: String? = nil) -> NetworkNode {
        var created: NetworkNode!
        performMutation("Add \(kind.displayName)") {
            let resolvedName: String
            if let custom = name?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
                resolvedName = custom
            } else {
                switch kind {
                case .station:
                    stationCount += 1
                    resolvedName = "S\(stationCount)"
                case .buffer:
                    bufferCount += 1
                    resolvedName = "B\(bufferCount)"
                case .source:
                    sourceCount += 1
                    resolvedName = "Src\(sourceCount)"
                case .sink:
                    sinkCount += 1
                    resolvedName = "Sink\(sinkCount)"
                }
            }

            // Born at a useful load, not at the boundary of instability.
            // `NetworkNode.init`'s own defaults are exponential at rate 1.0
            // for EVERY kind, so before this a hand-placed source offered
            // λ = 1 and a hand-placed station served at c·μ = 1 — the first
            // network anyone built by hand sat at ρ = 1.000 exactly, where
            // AnalyticalTractability short-circuits to unstable(), the
            // warnings say "overloaded" and the Inspector paints ρ in danger
            // ink. The bundled examples all use λ = 1 with μ = 1.1111111 and
            // RandomNetworkGenerator defaults to ρ = 0.9 for the same reason.
            //
            // Only this call site changes: `NetworkNode.init`'s defaults are
            // what an old .bnet decodes against, so touching them would alter
            // the meaning of saved documents.
            let node: NetworkNode
            switch kind {
            case .source:
                // Poisson rather than exponential: it is how every bundled
                // example spells an arrival process, it is what
                // `MethodAdvisor`'s sources-are-Poisson test looks for, and
                // AnalyticalTractability's Jackson branch accepts it.
                node = NetworkNode(kind: kind, name: resolvedName, position: location,
                                   distribution: .poisson,
                                   distributionParameters: QueueDistribution.poisson.defaultParameters)
            case .station:
                node = NetworkNode(kind: kind, name: resolvedName, position: location,
                                   distributionParameters: "rate=" + Self.defaultServiceRateLiteral)
            case .buffer, .sink:
                node = NetworkNode(kind: kind, name: resolvedName, position: location)
            }
            nodes.append(node)
            created = node
            selectedNodeID = node.id
            selectedLinkID = nil
            // Teach the number rather than merely defaulting it: a user who
            // never opens the parameter sheet should still know what load
            // the station they just placed is carrying.
            let note: String
            switch kind {
            case .station:
                note = " — μ = \(Self.defaultServiceRateLiteral), so ρ = "
                     + "\(DS.Number.display(Self.defaultTargetRho, decimals: 3)) against the default source rate."
            case .source:
                note = " — Poisson arrivals at λ = "
                     + "\(DS.Number.display(Self.defaultArrivalRate, decimals: 3))."
            case .buffer, .sink:
                note = "."
            }
            addStatus("Added \(kind.displayName.lowercased()) \(resolvedName)" + note)
        }
        return created
    }

    /// Append a routing link with explicit endpoints, class, and routing
    /// weight. Used by the AI Assistant's `add_link` tool. Validation is
    /// the caller's responsibility (existence of endpoints, kind
    /// compatibility, duplicate detection) — this method is a thin
    /// editor-mutation primitive that goes through `performMutation` so
    /// undo, parameter cache, persistence, and analysis-invalidation all
    /// pick up the change.
    @discardableResult
    func addLink(
        fromID: UUID,
        toID: UUID,
        customerClass: Int = 0,
        toCustomerClass: Int? = nil,
        routingProbability: Double = 1.0
    ) -> NetworkLink {
        var created: NetworkLink!
        performMutation("Add Link") {
            let link = NetworkLink(
                fromNodeID: fromID,
                toNodeID: toID,
                routingProbability: routingProbability,
                customerClass: customerClass,
                toCustomerClass: toCustomerClass
            )
            links.append(link)
            created = link
            selectedLinkID = link.id
            addStatus(
                "Added link \(linkLabel(link)) [\(CustomerClass.label(for: customerClass))]."
            )
        }
        return created
    }

    // MARK: - Private Helpers

    private func maxNameIndex(kind: NodeKind, prefix: String) -> Int {
        nodes.filter { $0.kind == kind }
            .compactMap { Int($0.name.dropFirst(prefix.count)) }
            .max() ?? 0
    }

    private func sourceIndex(_ name: String) -> Int {
        NodeNaming.sortIndex(name)
    }

    private func linkExists(from startID: UUID, to endID: UUID, customerClass: Int? = nil) -> Bool {
        links.contains(where: {
            $0.fromNodeID == startID && $0.toNodeID == endID
            && (customerClass == nil || $0.customerClass == customerClass)
        })
    }

    /// Full spoken description of a link, for VoiceOver and tooltips:
    /// class, endpoints, routing probability and any class transition.
    /// Links are selectable, editable objects, so they have to be
    /// reachable and readable, not just paintable.
    func linkDescription(_ link: NetworkLink) -> String {
        let fromName = node(with: link.fromNodeID)?.name ?? "?"
        let toName = node(with: link.toNodeID)?.name ?? "?"
        var parts: [String] = []
        if numberOfCustomerClasses > 1 {
            parts.append("\(CustomerClass.label(for: link.customerClass)) link")
        } else {
            parts.append("Link")
        }
        parts.append("\(fromName) to \(toName)")
        if link.routingProbability != 1.0 {
            parts.append("routing probability \(DS.Number.format(link.routingProbability, significantDigits: 3))")
        }
        if let exit = link.toCustomerClass, exit != link.customerClass {
            parts.append("exits as \(CustomerClass.label(for: exit))")
        }
        return parts.joined(separator: ", ")
    }

    /// Links attached to `nodeID`, in a stable order (outgoing first,
    /// then incoming, each by customer class) so ⌥Tab walks them the same
    /// way every time.
    func linksAttached(to nodeID: UUID) -> [NetworkLink] {
        let out = links.filter { $0.fromNodeID == nodeID }
            .sorted { $0.customerClass < $1.customerClass }
        let incoming = links.filter { $0.toNodeID == nodeID && $0.fromNodeID != nodeID }
            .sorted { $0.customerClass < $1.customerClass }
        return out + incoming
    }

    /// Moves the selection to the next (or previous) link attached to the
    /// currently selected node — the keyboard counterpart of clicking an
    /// arrow.  With a link already selected it walks that link's own
    /// node's attachments, so ⌥Tab cycles round the star of links at a
    /// station.  Returns the link now selected.
    @discardableResult
    func selectAdjacentLink(reverse: Bool) -> NetworkLink? {
        let hubID: UUID?
        if let current = selectedLinkID, let link = link(with: current) {
            hubID = link.fromNodeID
        } else {
            hubID = selectedNodeID ?? (selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil)
        }
        guard let hubID else { return nil }
        let attached = linksAttached(to: hubID)
        guard !attached.isEmpty else { return nil }
        var index = 0
        if let current = selectedLinkID, let at = attached.firstIndex(where: { $0.id == current }) {
            index = reverse ? at - 1 : at + 1
            if index < 0 { index = attached.count - 1 }
            if index >= attached.count { index = 0 }
        } else if reverse {
            index = attached.count - 1
        }
        let target = attached[index]
        endNudgeRun()
        selectedNodeIDs = []
        selectedNodeID = nil
        selectedLinkID = target.id
        return target
    }

    private func linkLabel(_ link: NetworkLink) -> String {
        let fromName = node(with: link.fromNodeID)?.name ?? "?"
        let toName = node(with: link.toNodeID)?.name ?? "?"
        return "\(fromName) -> \(toName)"
    }

    // MARK: - Undo / redo plumbing

    /// Records every piece of editor state that mutation-undo needs to
    /// restore. Only structural data — selection, tool, zoom, overlays
    /// stay as-is under undo since they're UI state, not document state.
    struct NetworkSnapshot {
        let nodes: [NetworkNode]
        let links: [NetworkLink]
        let infiniteBuffers: Bool
        let stationCount: Int
        let bufferCount: Int
        let sourceCount: Int
        let sinkCount: Int
    }

    private func snapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            nodes: nodes,
            links: links,
            infiniteBuffers: infiniteBuffers,
            stationCount: stationCount,
            bufferCount: bufferCount,
            sourceCount: sourceCount,
            sinkCount: sinkCount
        )
    }

    private func restore(from snap: NetworkSnapshot) {
        nodes = snap.nodes
        links = snap.links
        infiniteBuffers = snap.infiniteBuffers
        stationCount = snap.stationCount
        bufferCount  = snap.bufferCount
        sourceCount  = snap.sourceCount
        sinkCount    = snap.sinkCount
        // Keep the selection through undo / redo (MATLAB's property
        // inspector and OmniGraffle do): the docked Inspector follows it,
        // and a user who presses ⌘Z after a pane commit must SEE the value
        // come back, not an empty "No Selection" pane. Only ids the
        // restored snapshot no longer contains are dropped.
        if let id = selectedNodeID, !nodes.contains(where: { $0.id == id }) { selectedNodeID = nil }
        if let id = selectedLinkID, !links.contains(where: { $0.id == id }) { selectedLinkID = nil }
        selectedNodeIDs = selectedNodeIDs.filter { id in nodes.contains(where: { $0.id == id }) }
        multiSelectRect = nil
        multiSelectOrigin = nil
        pendingLinkStartID = nil
        activeLinkSourceID = nil
        parameterEditorTarget = nil
        linkParameterEditorTarget = nil
        hasBeenAnalyzed = false
        // Undo / redo changed the document under the flag bar's feet —
        // ask the app to refresh the silent analysis.
        NotificationCenter.default.post(name: .bnetNetworkParametersDidChange, object: self)
    }

    /// Wraps a single-step mutation with an undoable snapshot pair.
    /// Safe to call from anywhere. Captures state before running the
    /// block, then registers an undo that restores it and re-registers
    /// redo as the reverse transition.
    func performMutation(_ name: String, _ block: () -> Void) {
        if nudgeRunIDs != nil { endNudgeRun() }
        let before = snapshot()
        block()
        registerReversal(to: before, name: name)
        // Adding a node, drawing a link, deleting a selection and clearing
        // the canvas all come through here, and until this line none of them
        // told the flag bar anything: only the nine parameter mutations
        // posted, so once the silent analysis had run once, the entire
        // structural build left the Analytical, Re-entrant and Warnings pills
        // describing a network that no longer existed.
        invalidateAnalysisIfItWouldRead(before)
    }

    /// Begins a long-running mutation (e.g. a drag). Pairs with
    /// `endMutation()` to commit a single undo entry.
    func beginMutation(_ name: String) {
        // An arrow-key run holds an open group; commit it first so the
        // new mutation is not silently swallowed by it.
        if nudgeRunIDs != nil { endNudgeRun() }
        // Ignore nested begins — the outer scope owns the snapshot.
        guard pendingMutationSnapshot == nil else { return }
        pendingMutationSnapshot = snapshot()
        pendingMutationName = name
    }

    func endMutation() {
        guard let before = pendingMutationSnapshot,
              let name = pendingMutationName else { return }
        pendingMutationSnapshot = nil
        pendingMutationName = nil
        let touchedParameters = pendingGroupTouchedParameters
        pendingGroupTouchedParameters = false
        defer {
            // A parameter edit says so for itself (`noteParametersChanged`
            // already cleared `hasBeenAnalyzed`); anything else is decided by
            // the same read-blind comparison `performMutation` uses, so a
            // group that only moved nodes stays silent.
            if touchedParameters {
                NotificationCenter.default.post(name: .bnetNetworkParametersDidChange, object: self)
            } else {
                invalidateAnalysisIfItWouldRead(before)
            }
        }
        // Skip if no structural change.
        if before.nodes == nodes && before.links == links
            && before.infiniteBuffers == infiniteBuffers {
            return
        }
        registerReversal(to: before, name: name)
    }

    /// Marks the silent analysis stale and asks the app to re-run it, but
    /// only when the mutation changed something the analysis actually reads.
    ///
    /// The test is deliberately POSITION-BLIND. `endMutation`'s existing
    /// undo test is `before.nodes == nodes`, and a node drag changes `nodes`,
    /// so reusing it here would re-run `SRBMExporter.computeData` on every
    /// drag commit — and dragging is the one editing gesture that cannot
    /// afford it. Layout is not an input to any pill.
    ///
    /// The receiving side is debounced by 150 ms (QnetGUIApp's
    /// `.bnetNetworkParametersDidChange` subscription), so drawing a chain of
    /// links costs one re-analysis rather than one per link.
    private func invalidateAnalysisIfItWouldRead(_ before: NetworkSnapshot) {
        guard analysisWouldRead(before) else { return }
        hasBeenAnalyzed = false
        NotificationCenter.default.post(name: .bnetNetworkParametersDidChange, object: self)
    }

    /// True when something the flag bar's analysis reads differs between
    /// `before` and now: the buffer regime, any link, or any node field that
    /// `SRBMExporter.computeData` / `AnalyticalTractability` look at.
    /// Position and picture are excluded — they are the two node fields no
    /// analysis has ever read.
    private func analysisWouldRead(_ before: NetworkSnapshot) -> Bool {
        if before.infiniteBuffers != infiniteBuffers { return true }
        if before.links != links { return true }
        if before.nodes.count != nodes.count { return true }
        for (was, now) in zip(before.nodes, nodes) where !Self.sameForAnalysis(was, now) {
            return true
        }
        return false
    }

    /// Node comparison over exactly the fields an exporter or the
    /// tractability test reads. `name` is in it because every exporter
    /// numbers stations by the numeric suffix of the name, so a rename
    /// reorders the ρ vector.
    private static func sameForAnalysis(_ a: NetworkNode, _ b: NetworkNode) -> Bool {
        a.id == b.id
            && a.kind == b.kind
            && a.name == b.name
            && a.bufferSize == b.bufferSize
            && a.numberOfServers == b.numberOfServers
            && a.distribution == b.distribution
            && a.distributionParameters == b.distributionParameters
            && a.serviceDistributions == b.serviceDistributions
    }

    /// Registers an undo that restores the editor to `state`. When the
    /// undo fires, it captures the current state as the new "before"
    /// and re-registers — so hitting ⌘Z→⇧⌘Z roundtrips.
    private func registerReversal(to state: NetworkSnapshot, name: String) {
        // The handler is `@Sendable` and this model is `@MainActor`, so every
        // call in it is a main-actor call from a nonisolated context — thirty
        // warnings in a clean build. `assumeIsolated` is the honest fix rather
        // than a suppression: an undo handler runs on whichever thread called
        // `undo()`, and every caller here is the Edit menu or ⌘Z on the main
        // thread. Stating that turns a silent data race, if one is ever
        // introduced, into a trap at the moment it happens.
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // `isUndoing` is true only while the UNDO stack is running; the
                // same closure is re-registered onto the redo stack below, so
                // this is what tells the two apart. Read it BEFORE the restore
                // and the re-registration, while the manager is still inside
                // the invocation it is running.
                let verb = self.undoManager.isUndoing ? "Undid" : "Redid"
                let current = self.snapshot()
                self.restore(from: state)
                self.registerReversal(to: current, name: name)
                // An undone field run never continues: the next blur in the
                // docked Inspector registers its own entry instead of folding
                // into the one that was just reversed.
                self.endParameterRun()
                self.addStatus("\(verb): \(name).")
            }
        }
        undoManager.setActionName(name)
    }
}

/// The one number a queueing tool owes the user: whether a station is
/// stable at the parameters being typed. Built by
/// `NetworkEditorModel.stabilityReadout(for:draftNodes:links:infiniteBuffers:)`
/// from a draft copy of the nodes, so it reacts before Save.
struct StationStabilityReadout: Equatable {
    /// Total arrival rate λ into the station (all classes), jobs / time.
    let arrivalRate: Double
    /// Service capacity c·μ (servers × effective per-server rate), jobs / time.
    let capacity: Double
    let servers: Int
    /// λ per customer class index, for the per-class table's λ column.
    let arrivalRatePerClass: [Int: Double]

    /// ρ = λ / (c·μ); nil when the station has no capacity.
    var utilisation: Double? {
        guard capacity > 1e-12 else { return nil }
        let rho = arrivalRate / capacity
        return rho.isFinite ? rho : nil
    }

    /// Unstable at ρ ≥ 1 — the queue grows without bound.
    var isUnstable: Bool { (utilisation ?? 0) >= 1 }
    /// Heavy traffic: the advisory threshold the inspector warns at.
    var isHeavy: Bool { (utilisation ?? 0) >= 0.95 }
}
