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
@MainActor
private struct RQNAExporterHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CheckError.failed("expected an input .bnet and output .qna path")
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let document = try JSONDecoder().decode(
            NetworkDocument.self,
            from: Data(contentsOf: inputURL)
        )
        try require(document.infiniteBuffers, "fixture is not an infinite-buffer network")

        let content: String
        switch QNAExporter.export(nodes: document.nodes, links: document.links) {
        case .failure(let error):
            throw CheckError.failed(error.localizedDescription)
        case .success(let value):
            content = value
        }

        let requiredSections = [
            "customer_classes 3",
            "# Per-class throughput alpha[k][i] (K rows x d cols)",
            "# Per-class service rate mu[k][i] (K rows x d cols)",
            "# Per-class service SCV cs[k][i] (K rows x d cols)",
            "# Per-class external arrival rate at station lambda_ext[k][i] (K rows x d cols)",
            "# Per-(class, station) routing P_ex[k*d+i][k'*d+j] ((K*d) x (K*d))",
            "# Per-class external SCV ca0_pc[k][i] (K rows x d cols)",
        ]
        for section in requiredSections {
            try require(content.contains(section), "export omitted section: \(section)")
        }

        try Data(content.utf8).write(to: outputURL)
        print("QNAExporter produced the complete three-class RQNA input contract.")
    }
}
