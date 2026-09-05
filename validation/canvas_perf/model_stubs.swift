import Foundation
import CoreGraphics

// Minimal stand-ins for the model types CanvasGeometry.swift reads, so the
// real routing code can be timed outside the app.
enum NodeKind: String { case station, buffer, source, sink }

struct NetworkNode: Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: NodeKind
    var position: CGPoint
}

struct NetworkLink: Identifiable, Equatable {
    var id: UUID = UUID()
    var fromNodeID: UUID
    var toNodeID: UUID
    var customerClass: Int = 0
}

enum NetworkEditorModel { static let gridSpacing: CGFloat = 28 }
