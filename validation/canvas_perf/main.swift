import Foundation
import CoreGraphics
import SwiftUI

// Offline timing of the two canvas layers' per-frame work on a large
// network, using the shipping CanvasGeometry.swift code unmodified.
//
// Run through validation/canvas_perf/run_canvas_bench.sh.  The reference
// table this produces is recorded in the CanvasProfiler doc comment in
// Sources/Qnet/CanvasGeometry.swift; if a change to link routing, the
// grid or the hit tester pushes a column materially above it, the canvas
// is no longer inside its 60 fps budget.

func makeNetwork(nodeCount: Int, linkCount: Int) -> ([NetworkNode], [NetworkLink]) {
    var rng = SystemRandomNumberGenerator()
    var nodes: [NetworkNode] = []
    let cols = Int(Double(nodeCount).squareRoot().rounded(.up))
    for i in 0..<nodeCount {
        let kind: NodeKind
        switch i % 8 {
        case 0: kind = .source
        case 7: kind = .sink
        case 3: kind = .buffer
        default: kind = .station
        }
        nodes.append(NetworkNode(
            kind: kind,
            position: CGPoint(x: CGFloat(i % cols) * 140 + 60,
                              y: CGFloat(i / cols) * 120 + 60)))
    }
    var links: [NetworkLink] = []
    for k in 0..<linkCount {
        let a = Int.random(in: 0..<nodeCount, using: &rng)
        var b = (a + 1 + (k % 5)) % nodeCount
        if b == a { b = (a + 1) % nodeCount }
        links.append(NetworkLink(fromNodeID: nodes[a].id,
                                 toNodeID: nodes[b].id,
                                 customerClass: k % 2))
    }
    return (nodes, links)
}

func time(_ reps: Int, _ body: () -> Void) -> Double {
    body()  // warm
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<reps { body() }
    return (CFAbsoluteTimeGetCurrent() - t0) / Double(reps) * 1000
}

/// The per-frame work `CanvasContentView` does for the node layer before
/// SwiftUI ever sees a view: one display centre lookup, one marquee
/// intersection test and one `NetworkNodeView` equality check per node.
///
/// This is NOT the node layer's rendering cost.  The 200 `NetworkNodeView`
/// bodies — each a shape, a ring, a label block and a `.shadow` — are
/// SwiftUI views and can only be timed inside the app, with
/// QNET_CANVAS_PROFILE=1 (see the CanvasProfiler doc comment).  The
/// column is labelled accordingly so the table does not imply coverage
/// it lacks.
func nodeLayerMillis(scene: CanvasScene, nodes: [NetworkNode], marquee: CGRect, reps: Int) -> Double {
    time(reps) {
        var acc = 0
        for n in nodes {
            let centre = scene.displayCentres[n.id] ?? .zero
            if CanvasScene.marqueeSelects(n, rect: marquee) { acc += 1 }
            if centre.x > 0 { acc += 1 }
        }
        precondition(acc >= 0)
    }
}

let (nodes, links) = makeNetwork(nodeCount: 200, linkCount: 400)
let viewport = CGSize(width: 1600, height: 1000)
let marquee = CGRect(x: 200, y: 200, width: 600, height: 400)
// Routing is planned in world space and reused across pan / zoom, so a
// camera move pays only the "scene build" column; an edit pays "plan"
// once on top of it.
let planMs = time(20) { _ = LinkRoutePlan.build(nodes: nodes, links: links) }
let plan = LinkRoutePlan.build(nodes: nodes, links: links)
print("200 nodes / 400 links, viewport 1600x1000")
print(String(format: "  route plan (once per layout change): %.3f ms", planMs))

// What live re-planning during a drag WOULD cost per frame: move one node
// a little and plan again, sixty times.  The app does not pay this — the
// plan is frozen for the length of a drag and rebuilt once on release —
// but the number is here so the decision stays measured rather than
// assumed.  The interpolation row is what a frame of the release
// animation costs instead.
do {
    var moving = nodes
    var frame = 0
    let dragMs = time(60) {
        frame += 1
        moving[10].position.x += 2
        moving[10].position.y += CGFloat(frame % 3) - 1
        _ = LinkRoutePlan.build(nodes: moving, links: links)
    }
    moving[10].position.x += 180
    let after = LinkRoutePlan.build(nodes: moving, links: links)
    let lerpMs = time(200) {
        _ = LinkRoutePlan.interpolated(from: plan, to: after, t: 0.4)
    }
    print(String(format: "  drag re-plan (per frame, if it were live): %.3f ms   plan interpolation (per animation frame): %.3f ms",
                 dragMs, lerpMs))
}

for scale in [0.5, 0.86, 1.0, 2.0, 4.0] as [CGFloat] {
    let t = CanvasTransform(scale: scale, pan: CGSize(width: 37, height: -21), viewportSize: viewport)
    let sceneMs = time(60) {
        _ = CanvasScene(nodes: nodes, links: links, transform: t, classFilter: nil, routePlan: plan)
    }
    // The shipping grid builder itself, not a copy of it.
    let gridMs = time(200) {
        _ = GridPath.build(transform: t, size: viewport,
                           gridSpacing: NetworkEditorModel.gridSpacing)
    }
    // Hit tests run once per hover / mouse-down frame.
    let scene = CanvasScene(nodes: nodes, links: links, transform: t, classFilter: nil, routePlan: plan)
    let hitMs = time(500) {
        _ = scene.hitNode(at: CGPoint(x: 803, y: 517))
        _ = scene.hitLink(at: CGPoint(x: 803, y: 517))
    }
    let nodeMs = nodeLayerMillis(scene: scene, nodes: nodes, marquee: marquee, reps: 500)
    print(String(format: "  scale %.0f%%: scene build %.3f ms | grid path %.3f ms | node inputs (not the view bodies) %.3f ms | hit test %.3f ms",
                 Double(scale) * 100, sceneMs, gridMs, nodeMs, hitMs))
}

// Routing cost: how much of the scene build is the obstacle search?  A
// dense random network is the worst case (every chord crosses something).
do {
    let t = CanvasTransform(scale: 1, pan: .zero, viewportSize: viewport)
    let scene = CanvasScene(nodes: nodes, links: links, transform: t, classFilter: nil, routePlan: plan)
    var bowed = 0
    for item in scene.links {
        if case .straight = item.geometry.route { continue }
        bowed += 1
    }
    print(String(format: "  routing: %d of %d links bowed around a third node or its label",
                 bowed, scene.links.count))
}

// The synthetic network above is deliberately adversarial (a dense grid
// where four out of five chords cross somebody).  This is what the route
// planner costs on the networks the app actually ships with.
let exampleRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1
                      ? CommandLine.arguments[1]
                      : FileManager.default.currentDirectoryPath)
let examples = BnetLoader.loadAll(in: exampleRoot.appendingPathComponent("input/examples"))
if let biggest = examples.max(by: { $0.links.count < $1.links.count }) {
    let ms = time(200) { _ = LinkRoutePlan.build(nodes: biggest.nodes, links: biggest.links) }
    print(String(format: "\n  largest shipped example (%@, %d nodes / %d links): route plan %.3f ms",
                 biggest.name, biggest.nodes.count, biggest.links.count, ms))
}
