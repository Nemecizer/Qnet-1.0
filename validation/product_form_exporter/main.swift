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
struct ProductFormExporterCheck {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CheckError.failed("expected primary and disjoint output paths")
        }
        let station1 = NetworkNode(id: UUID(), kind: .station, name: "Intake")
        let station2 = NetworkNode(id: UUID(), kind: .station, name: "Service")
        let strictJSON = #"""
        {
          "nodes": [
            {"id": "s1", "servers": 2, "service_rate": 2.0, "capacity": null},
            {"id": "s2", "servers": 1, "service_rate": 4.0, "capacity": null}
          ],
          "classes": [
            {
              "id": "c1",
              "external_arrival_rates": {"s1": 0.8},
              "routing": {"s1": {"s2": 0.5}, "s2": {}}
            },
            {
              "id": "c2",
              "external_arrival_rates": {"s1": 0.2},
              "routing": {"s1": {"s2": 0.5}, "s2": {}}
            }
          ]
        }
        """#
        let editor = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [station1, station2],
            links: [],
            stationsInExportOrder: [station1, station2],
            strictJSON: strictJSON
        )

        let output: String
        switch ProductFormExporter.export(editor: editor, name: "Exporter check") {
        case .failure(let error):
            throw CheckError.failed(error.localizedDescription)
        case .success(let value):
            output = value
        }
        let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        try require(root?["schema_version"] as? Int == 1, "schema version mismatch")
        try require(root?["model_type"] as? String == "open_bcmp", "model type mismatch")
        let stations = root?["stations"] as? [[String: Any]]
        try require(stations?.count == 2, "station count mismatch")
        try require(stations?[0]["servers"] as? Int == 2, "M/M/c server count was lost")
        let firstTimes = stations?[0]["service_times"] as? [String: Double]
        try require(firstTimes?["c1"] == 0.5, "service rate was not inverted")
        try require(firstTimes?["c2"] == 0.5, "class-independent mean was not emitted")
        let classes = root?["classes"] as? [[String: Any]]
        let rows = classes?[0]["routing"] as? [[String: Any]]
        try require(rows?[0]["exit_probability"] as? Double == 0.5, "implicit exit probability mismatch")
        try require(rows?[1]["exit_probability"] as? Double == 1.0, "terminal exit probability mismatch")
        try Data(output.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        let disjointJSON = #"""
        {
          "nodes": [
            {"id": "s1", "servers": 2, "service_rate": 2.0, "capacity": null},
            {"id": "s2", "servers": 1, "service_rate": 4.0, "capacity": null}
          ],
          "classes": [
            {
              "id": "c1",
              "external_arrival_rates": {"s1": 0.8},
              "routing": {"s1": {}, "s2": {}}
            },
            {
              "id": "c2",
              "external_arrival_rates": {"s2": 0.2},
              "routing": {"s1": {}, "s2": {}}
            }
          ]
        }
        """#
        let disjointEditor = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [station1, station2],
            links: [],
            stationsInExportOrder: [station1, station2],
            strictJSON: disjointJSON
        )
        let disjointOutput: String
        switch ProductFormExporter.export(editor: disjointEditor, name: "Disjoint") {
        case .failure(let error):
            throw CheckError.failed(error.localizedDescription)
        case .success(let value):
            disjointOutput = value
        }
        let disjointRoot = try JSONSerialization.jsonObject(
            with: Data(disjointOutput.utf8)
        ) as? [String: Any]
        let disjointStations = disjointRoot?["stations"] as? [[String: Any]]
        let s1Times = disjointStations?[0]["service_times"] as? [String: Double]
        let s2Times = disjointStations?[1]["service_times"] as? [String: Double]
        try require(s1Times?.keys.sorted() == ["c1"], "s1 service map was not pruned")
        try require(s2Times?.keys.sorted() == ["c2"], "s2 service map was not pruned")
        let disjointClasses = disjointRoot?["classes"] as? [[String: Any]]
        let c1Rows = disjointClasses?[0]["routing"] as? [[String: Any]]
        let c2Rows = disjointClasses?[1]["routing"] as? [[String: Any]]
        try require(c1Rows?.count == 1, "unreachable c1 routing row was emitted")
        try require(c2Rows?.count == 1, "unreachable c2 routing row was emitted")
        try Data(disjointOutput.utf8).write(
            to: URL(fileURLWithPath: CommandLine.arguments[2])
        )

        let finite = NetworkEditorModel(
            infiniteBuffers: false,
            nodes: [station1], links: [], stationsInExportOrder: [station1],
            strictJSON: strictJSON
        )
        if case .success = ProductFormExporter.export(editor: finite, name: "finite") {
            throw CheckError.failed("finite-buffer model was accepted")
        }

        if case .success = ProductFormExporter.export(
            editor: editor, name: "limit", maximumServers: 1
        ) {
            throw CheckError.failed("server safety limit was not enforced")
        }

        let sink = NetworkNode(id: UUID(), kind: .sink, name: "Exit")
        let badTopology = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [station1, sink],
            links: [NetworkLink(
                fromNodeID: sink.id,
                toNodeID: station1.id,
                routingProbability: 0.1
            )],
            stationsInExportOrder: [station1],
            strictJSON: strictJSON
        )
        if case .success = ProductFormExporter.export(editor: badTopology, name: "bad") {
            throw CheckError.failed("outgoing sink route was silently discarded")
        }

        let unsupported = NetworkEditorModel(
            infiniteBuffers: true,
            nodes: [station1], links: [], stationsInExportOrder: [station1],
            strictJSON: "UNSUPPORTED"
        )
        switch ProductFormExporter.export(editor: unsupported, name: "unsupported") {
        case .success:
            throw CheckError.failed("unsupported shared model was accepted")
        case .failure(let error):
            try require(
                error.localizedDescription.contains("Exact open product form requires"),
                "shared error was not reworded for product form"
            )
        }

        print("ProductFormExporter Swift checks passed.")
    }
}
