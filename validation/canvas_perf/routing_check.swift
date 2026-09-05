import Foundation
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────
// Canvas link-routing check
// ─────────────────────────────────────────────────────────────────────────
//
// Loads every input/examples/*.bnet, builds the shipping `CanvasScene` at
// zoom 1, and tests every routed link polyline — the stroke that is
// actually drawn and hit-tested — against every node it is not attached
// to.  Two tallies:
//
//   * BODY crossings: the stroke enters a third node's body
//     (`CanvasScene.nodeWorldRect`).  Always a failure.
//   * LABEL crossings: the stroke enters the name / distribution / μ·SCV
//     block under a third node (`CanvasScene.nodeLabelRect`).  The router
//     treats labels as soft obstacles — it avoids them whenever that does
//     not mean crossing a body — so this count is a tracked BUDGET rather
//     than a hard zero: the check fails if it grows past
//     `labelCrossingBudget`, and the budget is lowered as the router
//     improves.  (Before labels were obstacles at all, the shipped
//     examples had 83 label crossings.)
//
// Run through validation/canvas_perf/run_routing_check.sh.
// Exit status 0 = every link clears every body and the label budget
// holds; 1 = at least one link is skewered or the budget is blown.

@main
struct RoutingCheck {
    /// Label crossings the shipped examples are allowed, in total.  Drive
    /// this down; never up.  Measured on the day the soft obstacles
    /// landed: 83 before, the number below after.
    static let labelCrossingBudget = 11

    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
                       ? CommandLine.arguments[1]
                       : FileManager.default.currentDirectoryPath)
        let examples = root.appendingPathComponent("input/examples")

        let networks = BnetLoader.loadAll(in: examples)
        guard !networks.isEmpty else {
            FileHandle.standardError.write(Data("no .bnet files found under \(examples.path)\n".utf8))
            exit(2)
        }

        var totalLinks = 0
        var totalBodyCrossings = 0
        var totalLabelCrossings = 0
        var filesWithBodyCrossings = 0
        var filesWithLabelCrossings = 0

        func crosses(_ poly: [CGPoint], _ rect: CGRect) -> Bool {
            for i in 1..<poly.count
            where CanvasMath.segmentIntersectsRect(poly[i - 1], poly[i], rect) {
                return true
            }
            return false
        }

        for net in networks {
            let transform = CanvasTransform(scale: 1, pan: .zero,
                                            viewportSize: CGSize(width: 4000, height: 3000))
            let scene = CanvasScene(nodes: net.nodes, links: net.links,
                                    transform: transform, classFilter: nil)
            var bodyCrossings: [String] = []
            var labelCrossings: [String] = []
            for item in scene.links {
                totalLinks += 1
                let poly = item.geometry.polyline
                guard poly.count > 1 else { continue }
                for node in net.nodes {
                    if node.id == item.link.fromNodeID || node.id == item.link.toNodeID { continue }
                    let a = net.nodeNames[item.link.fromNodeID] ?? "?"
                    let b = net.nodeNames[item.link.toNodeID] ?? "?"
                    let c = net.nodeNames[node.id] ?? "?"
                    // World body of the node, with no routing slack: the strict
                    // "does the arrow cross the picture of the node" question.
                    if crosses(poly, CanvasScene.nodeWorldRect(node)) {
                        bodyCrossings.append("\(a) -> \(b) crosses \(c)")
                    }
                    if crosses(poly, CanvasScene.nodeLabelRect(node)) {
                        labelCrossings.append("\(a) -> \(b) crosses the label of \(c)")
                    }
                }
            }
            totalBodyCrossings += bodyCrossings.count
            totalLabelCrossings += labelCrossings.count
            if !bodyCrossings.isEmpty {
                filesWithBodyCrossings += 1
                print("FAIL  \(net.name): \(bodyCrossings.count) link(s) drawn through a third node")
                for c in bodyCrossings.prefix(6) { print("        \(c)") }
                if bodyCrossings.count > 6 { print("        ... and \(bodyCrossings.count - 6) more") }
            }
            if !labelCrossings.isEmpty {
                filesWithLabelCrossings += 1
                print("label \(net.name): \(labelCrossings.count) link(s) through a third node's label")
                for c in labelCrossings.prefix(4) { print("        \(c)") }
                if labelCrossings.count > 4 { print("        ... and \(labelCrossings.count - 4) more") }
            }
        }

        print("")
        print("\(networks.count) networks, \(totalLinks) routed links")
        print("  body crossings:  \(totalBodyCrossings) in \(filesWithBodyCrossings) file(s)   (must be 0)")
        print("  label crossings: \(totalLabelCrossings) in \(filesWithLabelCrossings) file(s)   (budget \(labelCrossingBudget))")
        var failed = false
        if totalBodyCrossings == 0 {
            print("PASS  no link is drawn through a node it is not attached to")
        } else {
            failed = true
        }
        if totalLabelCrossings > labelCrossingBudget {
            print("FAIL  label crossings exceed the tracked budget (\(totalLabelCrossings) > \(labelCrossingBudget))")
            failed = true
        } else {
            print("PASS  label crossings within budget")
        }
        exit(failed ? 1 : 0)
    }
}
