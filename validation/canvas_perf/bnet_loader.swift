import Foundation
import CoreGraphics

// Minimal `.bnet` reader for the offline canvas harnesses.  The GUI
// decodes the file into `NetworkDocument`; here only the three fields the
// router reads (kind, position, endpoints) are needed, so the JSON is
// walked directly and no model code has to be linked in.
enum BnetLoader {
    struct Network {
        var name: String
        var nodes: [NetworkNode]
        var links: [NetworkLink]
        /// node id → name, so a failure can be reported in the user's terms.
        var nodeNames: [UUID: String]
    }

    static func load(_ url: URL) -> Network? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var nodes: [NetworkNode] = []
        var names: [UUID: String] = [:]
        var idMap: [String: UUID] = [:]
        for raw in (root["nodes"] as? [[String: Any]]) ?? [] {
            guard let key = raw["id"] as? String,
                  let kindName = raw["kind"] as? String,
                  let kind = NodeKind(rawValue: kindName),
                  let pos = raw["position"] as? [Double], pos.count == 2
            else { continue }
            let id = UUID()
            idMap[key] = id
            names[id] = (raw["name"] as? String) ?? kindName
            nodes.append(NetworkNode(id: id, kind: kind,
                                     position: CGPoint(x: pos[0], y: pos[1])))
        }

        var links: [NetworkLink] = []
        for raw in (root["links"] as? [[String: Any]]) ?? [] {
            guard let f = raw["fromNodeID"] as? String, let from = idMap[f],
                  let t = raw["toNodeID"] as? String, let to = idMap[t]
            else { continue }
            links.append(NetworkLink(fromNodeID: from, toNodeID: to,
                                     customerClass: (raw["customerClass"] as? Int) ?? 0))
        }
        return Network(name: url.lastPathComponent, nodes: nodes, links: links, nodeNames: names)
    }

    /// Every `.bnet` under `dir`, sorted by name.
    static func loadAll(in dir: URL) -> [Network] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "bnet" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(load)
    }
}
