import Foundation

enum NodeKind {
    case station
    case buffer
    case source
    case sink
}

struct NetworkNode {
    let id: UUID
    let kind: NodeKind
    let name: String
}

struct NetworkLink {
    let fromNodeID: UUID
    let toNodeID: UUID
    let routingProbability: Double
}

struct NetworkEditorModel {
    let infiniteBuffers: Bool
    let nodes: [NetworkNode]
    let links: [NetworkLink]
    let stationsInExportOrder: [NetworkNode]
    let strictJSON: String
}

struct RegenerativeExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum RegenerativeExporter {
    static func export(
        editor: NetworkEditorModel,
        name: String
    ) -> Result<String, RegenerativeExportError> {
        if editor.strictJSON == "UNSUPPORTED" {
            return .failure(RegenerativeExportError(
                message: "Regenerative simulation requires exponential FCFS service."
            ))
        }
        return .success(editor.strictJSON)
    }
}
