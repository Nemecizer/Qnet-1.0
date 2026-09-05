import Foundation

enum NodeKind: String, Codable {
    case station
    case buffer
    case source
    case sink
}

enum QueueDistribution: String, Codable {
    case exponential
    case gamma
    case uniform
    case constant
    case weibull
    case erlang
    case lognormal
    case pareto
    case poisson
}

struct ServiceDistributionConfig: Codable {
    let distribution: QueueDistribution
    let distributionParameters: String
}

struct NetworkNode: Codable {
    let id: UUID
    let kind: NodeKind
    let name: String
    let distribution: QueueDistribution
    let distributionParameters: String
    let numberOfServers: Int
    let serviceDistributions: [Int: ServiceDistributionConfig]
}

struct NetworkLink: Codable {
    let fromNodeID: UUID
    let toNodeID: UUID
    let routingProbability: Double
    let customerClass: Int
    let toCustomerClass: Int?

    private enum CodingKeys: String, CodingKey {
        case fromNodeID, toNodeID, routingProbability, customerClass
        case toCustomerClass
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fromNodeID = try values.decode(UUID.self, forKey: .fromNodeID)
        toNodeID = try values.decode(UUID.self, forKey: .toNodeID)
        routingProbability = try values.decode(Double.self, forKey: .routingProbability)
        customerClass = try values.decodeIfPresent(Int.self, forKey: .customerClass) ?? 0
        toCustomerClass = try values.decodeIfPresent(Int.self, forKey: .toCustomerClass)
    }
}

struct NetworkDocument: Codable {
    let nodes: [NetworkNode]
    let links: [NetworkLink]
    let infiniteBuffers: Bool
}

enum CustomerClass {
    static func label(for index: Int) -> String { "class \(index + 1)" }
}

enum NodeNaming {
    static func sortIndex(_ name: String) -> Int {
        let suffix = name.reversed().prefix(while: { $0.isNumber }).reversed()
        return Int(String(suffix)) ?? Int.max
    }
}
