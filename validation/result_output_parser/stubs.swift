import Foundation

enum NodeKind {
    case station
    case buffer
}

struct NetworkNode {
    let id: UUID
    let kind: NodeKind
    let name: String
}

struct ResultNetworkSnapshot {
    let nodes: [NetworkNode]
}

struct ResultProvenance {
    let networkSnapshot: ResultNetworkSnapshot
    let exportStationIDs: [UUID]?
}

struct ResultMethodMetadata {
    let identifier: String

    static let monteCarlo = Self(identifier: "queue.des")
    static let regenerativeMonteCarlo = Self(identifier: "queue.regenerative-mc")
    static let srbmMLMC = Self(identifier: "srbm.mlmc")
    static let openProductForm = Self(identifier: "queue.open-bcmp-product-form")
    static let qbd = Self(identifier: "queue.matrix-analytic-qbd")
    static let truncatedCTMC = Self(identifier: "queue.infinite-truncated-ctmc")
    static let adaptiveLowRankBAR = Self(identifier: "srbm.adaptive-low-rank-bar")
    static let barMomentBounds = Self(identifier: "srbm.bar-moment-bounds")
    static let sbd = Self(identifier: "queue-approx.sbd")
    static let comparison = Self(identifier: "comparison.mixed")
}

struct ResultRunRecord {
    let method: ResultMethodMetadata
    let provenance: ResultProvenance
}

struct ResultUncertainty {
    var standardError: Double?
    var lowerBound: Double?
    var upperBound: Double?
    var confidenceLevel: Double?
    var sampleSize: Int?

    init(
        standardError: Double? = nil,
        lowerBound: Double? = nil,
        upperBound: Double? = nil,
        confidenceLevel: Double? = nil,
        sampleSize: Int? = nil
    ) {
        self.standardError = standardError
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.confidenceLevel = confidenceLevel
        self.sampleSize = sampleSize
    }

    var isEmpty: Bool {
        standardError == nil && lowerBound == nil && upperBound == nil
            && confidenceLevel == nil && sampleSize == nil
    }
}

struct ResultNumericalEvidence {
    var residual: Double?
    var discretization: String?
    var refinementDelta: Double?
    var convergenceNote: String?

    init(
        residual: Double? = nil,
        discretization: String? = nil,
        refinementDelta: Double? = nil,
        convergenceNote: String? = nil
    ) {
        self.residual = residual
        self.discretization = discretization
        self.refinementDelta = refinementDelta
        self.convergenceNote = convergenceNote
    }

    var isEmpty: Bool {
        residual == nil && discretization == nil
            && refinementDelta == nil && convergenceNote == nil
    }
}

struct ResultMeasurement {
    let id: UUID
    var stationID: UUID?
    var stationName: String
    var customerClass: Int?
    var metric: String
    var estimate: Double
    var unit: String
    var uncertainty: ResultUncertainty?
    var numericalEvidence: ResultNumericalEvidence?
    var note: String?

    init(
        id: UUID = UUID(),
        stationID: UUID? = nil,
        stationName: String,
        customerClass: Int? = nil,
        metric: String,
        estimate: Double,
        unit: String = "",
        uncertainty: ResultUncertainty? = nil,
        numericalEvidence: ResultNumericalEvidence? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.stationID = stationID
        self.stationName = stationName
        self.customerClass = customerClass
        self.metric = metric
        self.estimate = estimate
        self.unit = unit
        self.uncertainty = uncertainty?.isEmpty == true ? nil : uncertainty
        self.numericalEvidence = numericalEvidence?.isEmpty == true ? nil : numericalEvidence
        self.note = note
    }
}

enum DS {
    enum Number {
        static func format(_ value: Double, significantDigits: Int) -> String {
            String(format: "%.*g", significantDigits, value)
        }
    }
}
