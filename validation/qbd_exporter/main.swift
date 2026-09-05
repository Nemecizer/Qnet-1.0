import Foundation

private enum CheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}

@main
struct QBDExporterCheck {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckError.failed("expected output path")
        }
        let station = NetworkNode(
            id: UUID(), kind: .station, name: "Server", numberOfServers: 1
        )
        let source = NetworkNode(
            id: UUID(), kind: .source, name: "Arrivals", numberOfServers: 1
        )
        let strictJSON = #"""
        {
          "nodes": [
            {"id": "s1", "servers": 1, "service_rate": 4.0, "capacity": null}
          ],
          "classes": [
            {
              "id": "c1",
              "external_arrival_rates": {"s1": 1.0},
              "routing": {"s1": {"s1": 0.5}}
            }
          ]
        }
        """#
        let editor = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [source, station],
            links: [],
            stationsInExportOrder: [station],
            strictJSON: strictJSON
        )
        let output: String
        switch QBDExporter.export(editor: editor, name: "Feedback M/M/1") {
        case .failure(let error):
            throw CheckError.failed(error.localizedDescription)
        case .success(let value):
            output = value
        }
        let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        try require(root?["schema_version"] as? Int == 1, "schema version mismatch")
        try require(root?["process"] as? String == "continuous_time_qbd", "process mismatch")
        let boundary = root?["boundary"] as? [String: [[Double]]]
        let interior = root?["interior"] as? [String: [[Double]]]
        try require(boundary?["level_0_up"] == [[1.0]], "external upward rate mismatch")
        try require(boundary?["level_1_down"] == [[2.0]], "feedback-adjusted downward rate mismatch")
        try require(interior?["same"] == [[-3.0]], "holding-rate diagonal mismatch")
        try Data(output.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        let finite = NetworkEditorModel(
            infiniteBuffers: false,
            nodes: [source, station], links: [], stationsInExportOrder: [station],
            strictJSON: strictJSON
        )
        if case .success = QBDExporter.export(editor: finite, name: "finite") {
            throw CheckError.failed("finite queue was accepted")
        }

        let multiserver = NetworkNode(
            id: UUID(), kind: .station, name: "Pool", numberOfServers: 2
        )
        let multiserverEditor = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [source, multiserver], links: [],
            stationsInExportOrder: [multiserver], strictJSON: strictJSON
        )
        if case .success = QBDExporter.export(editor: multiserverEditor, name: "M/M/2") {
            throw CheckError.failed("M/M/2 was accepted by scalar M/M/1 adapter")
        }

        let secondStation = NetworkNode(
            id: UUID(), kind: .station, name: "Second", numberOfServers: 1
        )
        let network = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [source, station, secondStation], links: [],
            stationsInExportOrder: [station, secondStation], strictJSON: strictJSON
        )
        if case .success = QBDExporter.export(editor: network, name: "network") {
            throw CheckError.failed("multi-station network was accepted")
        }

        print("QBDExporter Swift checks passed.")
    }
}
