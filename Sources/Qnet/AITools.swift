import Foundation

// MARK: - Tool catalog

/// A single tool the model can invoke. `inputSchema` is a JSON-Schema
/// dictionary describing the tool's arguments. `handler` executes the tool
/// with the decoded input and returns a plain-text result that gets fed
/// back into the conversation as a tool_result.
struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let handler: @MainActor ([String: Any]) async throws -> String

    /// Wire metadata the LLM client sends to the provider — stripped of
    /// the Swift-side handler so it's safely Sendable across the async
    /// boundary to the non-isolated client.
    var schema: LLMTool {
        LLMTool(name: name, description: description, inputSchema: inputSchema)
    }
}

enum ToolError: LocalizedError {
    case unknown(String)
    case invalidInput(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknown(let name):       return "Unknown tool: \(name)"
        case .invalidInput(let msg):   return "Invalid tool input: \(msg)"
        case .executionFailed(let msg): return "Tool execution failed: \(msg)"
        }
    }
}

/// Registry populated at app start-up. `AIModel` reads the catalog and
/// forwards tool calls into `execute`. Tools capture references to the
/// live editor / app state via closures.
@MainActor
final class ToolRegistry: ObservableObject {
    private var tools: [String: ToolDefinition] = [:]

    func register(_ tool: ToolDefinition) {
        tools[tool.name] = tool
    }

    func allDefinitions() -> [ToolDefinition] {
        Array(tools.values).sorted { $0.name < $1.name }
    }

    /// Convenience: just the wire schemas, ready to hand to an LLM client.
    func allSchemas() -> [LLMTool] {
        allDefinitions().map(\.schema)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let tool = tools[name] else {
            throw ToolError.unknown(name)
        }
        return try await tool.handler(input)
    }
}

// MARK: - Cross-cutting notification for menu-command dispatch

extension Notification.Name {
    /// Posted by the `run_command` tool (or anything else) to ask
    /// `QnetGUIApp` to execute a named menu command. `userInfo["command"]`
    /// holds the string identifier from `AICommand`.
    static let bnetExecuteCommand = Notification.Name("bnet.execute.command")
}

/// The enumerated set of menu commands the AI is allowed to drive. Kept
/// as an enum so the JSON schema and the dispatcher can share the same
/// source of truth.
enum AICommand: String, CaseIterable {
    case runComparison         = "RunComparison"
    case runMonteCarlo         = "RunMonteCarlo"
    case runSpectralMethod     = "RunSpectralMethod"
    case runFiniteElement      = "RunFiniteElement"
    case runQNA                = "RunQNA"
    case runSBD                = "RunSBD"
    case runMultiClassSRBM     = "RunMultiClassSRBM"
    case runExactSimulation    = "RunExactSimulation"
    case runLinearProgram      = "RunLinearProgram"
    case runFiniteLP           = "RunFiniteLP"
    case showNetworkPrimitives = "ShowNetworkPrimitives"
    case analyzeNetwork        = "AnalyzeNetwork"

    /// User-facing description for the tool-catalog description string.
    var humanLabel: String {
        switch self {
        case .runComparison:         return "Run Comparison"
        case .runMonteCarlo:         return "Run Monte Carlo"
        case .runSpectralMethod:     return "Run Spectral Method"
        case .runFiniteElement:      return "Run Finite Element (finite buffers only)"
        case .runQNA:                return "Run Whitt QNA (infinite buffers only)"
        case .runSBD:                return "Run SBD (infinite buffers only)"
        case .runMultiClassSRBM:     return "Run Multi-Class SRBM (experimental)"
        case .runExactSimulation:    return "Run SRBM MLMC (infinite buffers only)"
        case .runLinearProgram:      return "Run Linear Program (infinite buffers only)"
        case .runFiniteLP:           return "Run Finite-Buffer LP (finite buffers only)"
        case .showNetworkPrimitives: return "Show Network Primitives report"
        case .analyzeNetwork:        return "Analyze the active network"
        }
    }
}

// MARK: - Built-in tool factory

/// Builds the default set of tools. Tools hold closures that capture the
/// editor / settings lazily so a tab switch is reflected automatically.
enum AIToolFactory {
    /// `runCommandRefusal` is asked right before `run_command` posts its
    /// notification; a non-nil string is returned to the model as the
    /// tool result instead (the menu handlers act on the front tab, so the
    /// app refuses while the conversation's tab is not the one in front).
    static func makeDefaultTools(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel,
        runCommandRefusal: @escaping @MainActor () -> String? = { nil }
    ) -> [ToolDefinition] {
        [
            makeGetNetworkSummary(activeEditor: activeEditor),
            makeAddNode(activeEditor: activeEditor),
            makeDeleteNode(activeEditor: activeEditor),
            makeAddLink(activeEditor: activeEditor),
            makeDeleteLink(activeEditor: activeEditor),
            makeUpdateNode(activeEditor: activeEditor),
            makeUpdateLink(activeEditor: activeEditor),
            makeRunCommand(activeEditor: activeEditor, refusal: runCommandRefusal),
            makeReadStatus(activeEditor: activeEditor)
        ]
    }

    // MARK: read-only

    private static func makeGetNetworkSummary(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "get_network_summary",
            description: """
            Return a JSON snapshot of the currently-active BNET network: \
            global flags (infinite_buffers, customer_class_count), every \
            node (with the parameters that update_node can edit) and every \
            link (with the parameters update_link can edit). Call this \
            BEFORE update_node / update_link so you know which names exist \
            and what their current values are.
            """,
            inputSchema: [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ],
            handler: { _ in
                let editor = activeEditor()
                let nodeIDName = Dictionary(
                    uniqueKeysWithValues: editor.nodes.map { ($0.id, $0.name) }
                )

                var summary: [String: Any] = [
                    "infinite_buffers":     editor.infiniteBuffers,
                    "has_been_analyzed":    editor.hasBeenAnalyzed,
                    "node_count":           editor.nodes.count,
                    "station_count":        editor.nodes.filter { $0.kind == .station }.count,
                    "link_count":           editor.links.count,
                    "customer_class_count": max(1, editor.activeCustomerClass + 1)
                ]
                summary["nodes"] = editor.nodes.map { node -> [String: Any] in
                    var entry: [String: Any] = [
                        "name": node.name,
                        "kind": node.kind.rawValue
                    ]
                    switch node.kind {
                    case .station:
                        entry["number_of_servers"]      = node.numberOfServers
                        entry["distribution"]           = node.distribution.rawValue
                        entry["distribution_parameters"] = node.distributionParameters
                    case .source:
                        entry["distribution"]           = node.distribution.rawValue
                        entry["distribution_parameters"] = node.distributionParameters
                    case .buffer:
                        entry["buffer_size"] = node.bufferSize
                    case .sink:
                        break
                    }
                    return entry
                }
                summary["links"] = editor.links.map { link -> [String: Any] in
                    var entry: [String: Any] = [
                        "from":                nodeIDName[link.fromNodeID] ?? "?",
                        "to":                  nodeIDName[link.toNodeID]   ?? "?",
                        "routing_probability": link.routingProbability,
                        "customer_class":      link.customerClass
                    ]
                    if let toClass = link.toCustomerClass {
                        entry["to_customer_class"] = toClass
                    }
                    return entry
                }
                let data = try JSONSerialization.data(
                    withJSONObject: summary,
                    options: [.prettyPrinted, .sortedKeys]
                )
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        )
    }

    // MARK: mutations

    /// Helper: locate a node by name. Names are unique within a tab.
    @MainActor
    private static func findNode(
        named name: String, in editor: NetworkEditorModel
    ) throws -> NetworkNode {
        guard let node = editor.nodes.first(where: { $0.name == name }) else {
            let available = editor.nodes.map(\.name).sorted().joined(separator: ", ")
            throw ToolError.invalidInput(
                "No node named \"\(name)\". Existing nodes: \(available.isEmpty ? "(none)" : available)."
            )
        }
        return node
    }

    private static func makeUpdateNode(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        let distNames = QueueDistribution.allCases.map(\.rawValue)
        return ToolDefinition(
            name: "update_node",
            description: """
            Edit one or more parameters of an existing node (station, \
            source, buffer, or sink) on the active canvas. Identify the \
            node by its current `name` (e.g. "S1", "Src1", "B2"). Pass \
            only the fields you want to change.

            Per-kind editable fields:
              station: new_name, number_of_servers, distribution, \
                       distribution_parameters
              source : new_name, distribution, distribution_parameters
              buffer : new_name, buffer_size
              sink   : new_name

            `distribution` is one of: \(distNames.joined(separator: ", ")).
            `distribution_parameters` uses the editor's "key=value,..." \
            format — examples: "rate=1.0" (exponential / poisson), \
            "shape=2.0,scale=1.0" (gamma / weibull / pareto), \
            "k=2,rate=1.0" (erlang), "min=0.5,max=1.5" (uniform), \
            "value=1.0" (constant), "mu=0.0,sigma=0.25" (lognormal). \
            If you change `distribution` but omit `distribution_parameters`, \
            the editor seeds the default parameters for the new \
            distribution.

            Multi-class per-class service distributions are NOT settable \
            from this tool yet; this updates the node's default \
            distribution only. Position (xy) is also not settable — the \
            user moves icons themselves.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type":        "string",
                        "description": "Current display name of the node to edit."
                    ] as [String: Any],
                    "new_name": [
                        "type":        "string",
                        "description": "Rename the node. Must be unique among existing nodes."
                    ] as [String: Any],
                    "number_of_servers": [
                        "type":        "integer",
                        "minimum":     1,
                        "description": "Server count (station only)."
                    ] as [String: Any],
                    "buffer_size": [
                        "type":        "integer",
                        "minimum":     1,
                        "description": "Buffer capacity (buffer-kind nodes only)."
                    ] as [String: Any],
                    "distribution": [
                        "type":        "string",
                        "enum":        distNames,
                        "description": "Service (station) or interarrival (source) distribution family."
                    ] as [String: Any],
                    "distribution_parameters": [
                        "type":        "string",
                        "description": "Parameter string in \"key=value,...\" form. See tool description for per-distribution examples."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["name"]
            ],
            handler: { input in
                guard let name = input["name"] as? String, !name.isEmpty else {
                    throw ToolError.invalidInput("`name` is required and must be non-empty.")
                }
                let editor = activeEditor()
                let node = try findNode(named: name, in: editor)

                // Decode optional fields up-front and validate against the
                // node's kind so we never half-apply a multi-field update.
                let newName  = (input["new_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let servers  = input["number_of_servers"] as? Int
                let bufSize  = input["buffer_size"] as? Int
                let distRaw  = input["distribution"] as? String
                let distPars = input["distribution_parameters"] as? String

                if let newName, newName != node.name,
                   editor.nodes.contains(where: { $0.name == newName }) {
                    throw ToolError.invalidInput(
                        "Cannot rename to \"\(newName)\": another node already has that name."
                    )
                }
                if servers != nil, node.kind != .station {
                    throw ToolError.invalidInput(
                        "`number_of_servers` only applies to station nodes (got kind=\(node.kind.rawValue))."
                    )
                }
                if bufSize != nil, node.kind != .buffer {
                    throw ToolError.invalidInput(
                        "`buffer_size` only applies to buffer-kind nodes (got kind=\(node.kind.rawValue))."
                    )
                }
                if (distRaw != nil || distPars != nil),
                   node.kind != .station, node.kind != .source {
                    throw ToolError.invalidInput(
                        "`distribution` / `distribution_parameters` only apply to station and source nodes (got kind=\(node.kind.rawValue))."
                    )
                }
                let dist: QueueDistribution? = try distRaw.map {
                    guard let d = QueueDistribution(rawValue: $0) else {
                        throw ToolError.invalidInput(
                            "`distribution` must be one of: \(distNames.joined(separator: ", "))."
                        )
                    }
                    return d
                }

                // Snapshot every requested change so the result string can
                // describe what actually happened.
                var changes: [String] = []

                if let newName, newName != node.name {
                    editor.renameNode(nodeID: node.id, name: newName)
                    changes.append("name: \"\(node.name)\" → \"\(newName)\"")
                }
                if let servers {
                    let old = node.numberOfServers
                    editor.updateNumberOfServers(nodeID: node.id, count: servers)
                    changes.append("number_of_servers: \(old) → \(servers)")
                }
                if let bufSize {
                    let old = node.bufferSize
                    editor.updateBufferSize(nodeID: node.id, size: bufSize)
                    changes.append("buffer_size: \(old) → \(bufSize)")
                }
                if dist != nil || distPars != nil {
                    let oldDist = node.distribution
                    let oldPars = node.distributionParameters
                    let newDist = dist ?? oldDist
                    let newPars = distPars ?? oldPars
                    editor.updateNodeDistribution(
                        nodeID: node.id,
                        distribution: newDist,
                        parameters: newPars
                    )
                    if newDist != oldDist {
                        changes.append("distribution: \(oldDist.rawValue) → \(newDist.rawValue)")
                    }
                    if newPars != oldPars {
                        changes.append("distribution_parameters: \"\(oldPars)\" → \"\(newPars)\"")
                    }
                }

                if changes.isEmpty {
                    return "No changes — every requested value already matched the node's current state."
                }
                return "Updated \(node.kind.rawValue) \"\(node.name)\":\n  - " +
                    changes.joined(separator: "\n  - ")
            }
        )
    }

    private static func makeUpdateLink(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "update_link",
            description: """
            Edit a routing link between two existing nodes on the active \
            canvas. Identify the link by `from_node_name` + `to_node_name` \
            (the display names visible in the network). When several \
            parallel links connect the same pair (e.g. one per customer \
            class), pass `customer_class` to disambiguate; otherwise the \
            tool refuses ambiguous matches and lists the candidates.

            Editable fields:
              new_routing_probability — outgoing routing weight (0…1).
              new_customer_class      — class index a job has when it \
                                        ENTERS the link.
              new_to_customer_class   — class index a job has when it \
                                        EXITS the link (omit / pass null \
                                        for no class transition; pass an \
                                        Int for a class change). Setting \
                                        this re-triggers analysis.

            Pass only the fields you want to change.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "from_node_name": [
                        "type":        "string",
                        "description": "Source node's display name."
                    ] as [String: Any],
                    "to_node_name": [
                        "type":        "string",
                        "description": "Destination node's display name."
                    ] as [String: Any],
                    "customer_class": [
                        "type":        "integer",
                        "minimum":     0,
                        "description": "Disambiguator for parallel links — the link's CURRENT customer_class."
                    ] as [String: Any],
                    "new_routing_probability": [
                        "type":        "number",
                        "minimum":     0,
                        "maximum":     1,
                        "description": "New outgoing routing probability."
                    ] as [String: Any],
                    "new_customer_class": [
                        "type":        "integer",
                        "minimum":     0,
                        "description": "Set the link's entering customer-class index."
                    ] as [String: Any],
                    "new_to_customer_class": [
                        "type":        ["integer", "null"],
                        "minimum":     0,
                        "description": "Set the link's exit customer-class index (null clears any class transition)."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["from_node_name", "to_node_name"]
            ],
            handler: { input in
                guard let fromName = input["from_node_name"] as? String, !fromName.isEmpty else {
                    throw ToolError.invalidInput("`from_node_name` is required.")
                }
                guard let toName = input["to_node_name"] as? String, !toName.isEmpty else {
                    throw ToolError.invalidInput("`to_node_name` is required.")
                }
                let editor = activeEditor()
                let from = try findNode(named: fromName, in: editor)
                let to   = try findNode(named: toName,   in: editor)

                let candidates = editor.links.filter {
                    $0.fromNodeID == from.id && $0.toNodeID == to.id
                }
                if candidates.isEmpty {
                    throw ToolError.invalidInput(
                        "No link from \"\(fromName)\" to \"\(toName)\"."
                    )
                }

                let classFilter = input["customer_class"] as? Int
                let matches: [NetworkLink]
                if let classFilter {
                    matches = candidates.filter { $0.customerClass == classFilter }
                    if matches.isEmpty {
                        let classes = candidates.map { $0.customerClass }.sorted()
                        throw ToolError.invalidInput(
                            "No link from \"\(fromName)\" to \"\(toName)\" with customer_class=\(classFilter). Available classes on this pair: \(classes.map(String.init).joined(separator: ", "))."
                        )
                    }
                } else {
                    matches = candidates
                }
                guard matches.count == 1 else {
                    let classes = matches.map { $0.customerClass }.sorted()
                    throw ToolError.invalidInput(
                        "Multiple parallel links from \"\(fromName)\" to \"\(toName)\" (customer_class values: \(classes.map(String.init).joined(separator: ", "))). Pass `customer_class` to disambiguate."
                    )
                }
                let link = matches[0]

                // Decode and apply.
                let newProb  = input["new_routing_probability"] as? Double
                let newClass = input["new_customer_class"] as? Int
                // `new_to_customer_class` is tri-state: missing (untouched),
                // explicit null (clear transition), or integer (set). The
                // dictionary lookup distinguishes "key absent" from "key
                // present with NSNull" so the model can clear the field.
                let toClassKey = "new_to_customer_class"
                let toClassPresent = input.keys.contains(toClassKey)
                let toClassValue: Int? = (input[toClassKey] as? Int)

                if let newProb, !(0...1).contains(newProb) {
                    throw ToolError.invalidInput(
                        "`new_routing_probability` must be between 0 and 1 (got \(newProb))."
                    )
                }

                var changes: [String] = []
                if let newProb, abs(newProb - link.routingProbability) > 1e-12 {
                    let old = link.routingProbability
                    editor.updateLinkProbability(linkID: link.id, probability: newProb)
                    changes.append("routing_probability: \(old) → \(newProb)")
                }
                if let newClass, newClass != link.customerClass {
                    let old = link.customerClass
                    editor.updateLinkCustomerClass(linkID: link.id, customerClass: newClass)
                    changes.append("customer_class: \(old) → \(newClass)")
                }
                if toClassPresent {
                    let old = link.toCustomerClass
                    if old != toClassValue {
                        editor.updateLinkExitClass(linkID: link.id, exitClass: toClassValue)
                        changes.append(
                            "to_customer_class: \(old.map(String.init) ?? "null") → \(toClassValue.map(String.init) ?? "null")"
                        )
                    }
                }

                let label = "\(from.name) → \(to.name) (class \(link.customerClass))"
                if changes.isEmpty {
                    return "No changes — every requested value already matched the link's current state on \(label)."
                }
                return "Updated link \(label):\n  - " + changes.joined(separator: "\n  - ")
            }
        )
    }

    /// Pick an on-canvas position for a freshly-added node. The AI has
    /// no concept of canvas coordinates, so we stack new nodes to the
    /// right of the rightmost existing node (or seed at (300, 200) on
    /// an empty canvas). Users almost always reposition manually after
    /// — this just guarantees the node appears somewhere visible
    /// rather than landing on top of an existing one.
    @MainActor
    private static func nextNodePosition(in editor: NetworkEditorModel) -> CGPoint {
        guard let rightmost = editor.nodes.map(\.position).max(by: { $0.x < $1.x }) else {
            return CGPoint(x: 300, y: 200)
        }
        return CGPoint(x: rightmost.x + 120, y: rightmost.y)
    }

    private static func makeAddNode(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        let kindNames = NodeKind.allCases.map(\.rawValue)
        let distNames = QueueDistribution.allCases.map(\.rawValue)
        return ToolDefinition(
            name: "add_node",
            description: """
            Create a new node on the active canvas. Nodes are auto-named \
            unless you pass `name` (e.g. "S1", "Src1"); names must be \
            unique among existing nodes. Position is auto-assigned just \
            to the right of the rightmost existing node — the user can \
            drag it later, you don't get to set xy.

            Per-kind optional initial parameters (any others are silently \
            ignored if they don't apply):
              station: number_of_servers, distribution, distribution_parameters
              source : distribution, distribution_parameters
              buffer : buffer_size
              sink   : (no parameters)

            `distribution` is one of: \(distNames.joined(separator: ", ")).
            `distribution_parameters` uses the editor's "key=value,..." \
            format — see update_node's description for examples per \
            distribution family.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": [
                        "type":        "string",
                        "enum":        kindNames,
                        "description": "Node kind to create."
                    ] as [String: Any],
                    "name": [
                        "type":        "string",
                        "description": "Optional explicit name. Auto-named if omitted."
                    ] as [String: Any],
                    "number_of_servers": [
                        "type":        "integer",
                        "minimum":     1,
                        "description": "Initial server count (station only)."
                    ] as [String: Any],
                    "buffer_size": [
                        "type":        "integer",
                        "minimum":     1,
                        "description": "Initial buffer capacity (buffer-kind only)."
                    ] as [String: Any],
                    "distribution": [
                        "type":        "string",
                        "enum":        distNames,
                        "description": "Initial service / interarrival distribution (station or source)."
                    ] as [String: Any],
                    "distribution_parameters": [
                        "type":        "string",
                        "description": "Initial parameter string for the distribution."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["kind"]
            ],
            handler: { input in
                guard let rawKind = input["kind"] as? String,
                      let kind = NodeKind(rawValue: rawKind) else {
                    throw ToolError.invalidInput(
                        "`kind` must be one of: \(kindNames.joined(separator: ", "))."
                    )
                }
                let editor = activeEditor()

                let requestedName = (input["name"] as? String)?
                    .trimmingCharacters(in: .whitespaces)
                if let n = requestedName, !n.isEmpty,
                   editor.nodes.contains(where: { $0.name == n }) {
                    throw ToolError.invalidInput(
                        "A node named \"\(n)\" already exists."
                    )
                }

                // Per-kind parameter validation — same rules as update_node
                // so the AI can't seed a node with fields that don't apply.
                let servers  = input["number_of_servers"] as? Int
                let bufSize  = input["buffer_size"] as? Int
                let distRaw  = input["distribution"] as? String
                let distPars = input["distribution_parameters"] as? String

                if servers != nil, kind != .station {
                    throw ToolError.invalidInput(
                        "`number_of_servers` only applies to station nodes."
                    )
                }
                if bufSize != nil, kind != .buffer {
                    throw ToolError.invalidInput(
                        "`buffer_size` only applies to buffer-kind nodes."
                    )
                }
                if (distRaw != nil || distPars != nil),
                   kind != .station, kind != .source {
                    throw ToolError.invalidInput(
                        "`distribution` / `distribution_parameters` only apply to station and source nodes."
                    )
                }
                let dist: QueueDistribution? = try distRaw.map {
                    guard let d = QueueDistribution(rawValue: $0) else {
                        throw ToolError.invalidInput(
                            "`distribution` must be one of: \(distNames.joined(separator: ", "))."
                        )
                    }
                    return d
                }

                let position = nextNodePosition(in: editor)
                let node = editor.addNode(kind: kind, at: position, name: requestedName)

                // Apply optional initial parameters via the same paths the
                // update_node tool uses, so the parameter cache, status log,
                // and analysis dirty-bit all stay consistent.
                var initApplied: [String] = []
                if let servers {
                    editor.updateNumberOfServers(nodeID: node.id, count: servers)
                    initApplied.append("number_of_servers=\(servers)")
                }
                if let bufSize {
                    editor.updateBufferSize(nodeID: node.id, size: bufSize)
                    initApplied.append("buffer_size=\(bufSize)")
                }
                if dist != nil || distPars != nil {
                    let resolvedDist = dist ?? node.distribution
                    let resolvedPars = distPars ?? node.distributionParameters
                    editor.updateNodeDistribution(
                        nodeID: node.id,
                        distribution: resolvedDist,
                        parameters: resolvedPars
                    )
                    initApplied.append("distribution=\(resolvedDist.rawValue)")
                    if distPars != nil {
                        initApplied.append("distribution_parameters=\"\(resolvedPars)\"")
                    }
                }

                let suffix = initApplied.isEmpty ? "" : " with " + initApplied.joined(separator: ", ")
                return "Added \(kind.rawValue) \"\(node.name)\"\(suffix)."
            }
        )
    }

    private static func makeDeleteNode(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "delete_node",
            description: """
            Delete a node from the active canvas, identified by its \
            current `name`. Any links touching the node (incoming OR \
            outgoing, any class) are removed in the same operation — \
            the result string reports how many. Irreversible from the \
            AI side; the user can ⌘Z to undo.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type":        "string",
                        "description": "Display name of the node to delete."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["name"]
            ],
            handler: { input in
                guard let name = input["name"] as? String, !name.isEmpty else {
                    throw ToolError.invalidInput("`name` is required.")
                }
                let editor = activeEditor()
                let node = try findNode(named: name, in: editor)
                let touchingLinks = editor.links.filter {
                    $0.fromNodeID == node.id || $0.toNodeID == node.id
                }.count
                editor.deleteNode(id: node.id)
                if touchingLinks > 0 {
                    return "Deleted \(node.kind.rawValue) \"\(node.name)\" and \(touchingLinks) connected link(s)."
                }
                return "Deleted \(node.kind.rawValue) \"\(node.name)\"."
            }
        )
    }

    private static func makeAddLink(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "add_link",
            description: """
            Create a routing link between two existing nodes on the \
            active canvas. Endpoints are identified by display name. \
            Defaults: routing_probability=1.0, customer_class=0 \
            (Class 1), no class transition.

            Validation enforced:
              • from_node_name must not be a sink (sinks absorb jobs, \
                they don't route).
              • to_node_name must not be a source (sources emit jobs, \
                they don't receive).
              • A link with the same (from, to, customer_class) tuple \
                must not already exist — use update_link to edit it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "from_node_name": [
                        "type":        "string",
                        "description": "Source node's display name."
                    ] as [String: Any],
                    "to_node_name": [
                        "type":        "string",
                        "description": "Destination node's display name."
                    ] as [String: Any],
                    "routing_probability": [
                        "type":        "number",
                        "minimum":     0,
                        "maximum":     1,
                        "description": "Outgoing routing probability (default 1.0)."
                    ] as [String: Any],
                    "customer_class": [
                        "type":        "integer",
                        "minimum":     0,
                        "description": "Customer-class index a job has when entering the link (default 0)."
                    ] as [String: Any],
                    "to_customer_class": [
                        "type":        "integer",
                        "minimum":     0,
                        "description": "Customer-class index when exiting the link (omit for no class transition)."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["from_node_name", "to_node_name"]
            ],
            handler: { input in
                guard let fromName = input["from_node_name"] as? String, !fromName.isEmpty else {
                    throw ToolError.invalidInput("`from_node_name` is required.")
                }
                guard let toName = input["to_node_name"] as? String, !toName.isEmpty else {
                    throw ToolError.invalidInput("`to_node_name` is required.")
                }
                let editor = activeEditor()
                let from = try findNode(named: fromName, in: editor)
                let to   = try findNode(named: toName,   in: editor)

                if from.kind == .sink {
                    throw ToolError.invalidInput(
                        "\"\(fromName)\" is a sink and cannot be the source of a link."
                    )
                }
                if to.kind == .source {
                    throw ToolError.invalidInput(
                        "\"\(toName)\" is a source and cannot be the destination of a link."
                    )
                }

                let prob     = (input["routing_probability"] as? Double) ?? 1.0
                let cls      = (input["customer_class"] as? Int) ?? 0
                let toCls    = input["to_customer_class"] as? Int

                if !(0...1).contains(prob) {
                    throw ToolError.invalidInput(
                        "`routing_probability` must be between 0 and 1 (got \(prob))."
                    )
                }
                if cls < 0 {
                    throw ToolError.invalidInput("`customer_class` must be ≥ 0.")
                }
                if let toCls, toCls < 0 {
                    throw ToolError.invalidInput("`to_customer_class` must be ≥ 0.")
                }

                if editor.links.contains(where: {
                    $0.fromNodeID == from.id && $0.toNodeID == to.id && $0.customerClass == cls
                }) {
                    throw ToolError.invalidInput(
                        "A link from \"\(fromName)\" to \"\(toName)\" with customer_class=\(cls) already exists. Use update_link to edit it."
                    )
                }

                let link = editor.addLink(
                    fromID: from.id,
                    toID: to.id,
                    customerClass: cls,
                    toCustomerClass: toCls,
                    routingProbability: prob
                )
                var desc = "Added link \(from.name) → \(to.name) (class \(link.customerClass), routing_probability=\(link.routingProbability)"
                if let toCls = link.toCustomerClass {
                    desc += ", to_customer_class=\(toCls)"
                }
                desc += ")."
                return desc
            }
        )
    }

    private static func makeDeleteLink(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "delete_link",
            description: """
            Delete a routing link between two existing nodes. Identify \
            it by `from_node_name` + `to_node_name` (+ optional \
            `customer_class` to disambiguate parallel links between the \
            same pair). Refuses ambiguous matches and lists candidate \
            classes so you can re-call with the right disambiguator. \
            User can ⌘Z to undo.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "from_node_name": [
                        "type":        "string",
                        "description": "Source node's display name."
                    ] as [String: Any],
                    "to_node_name": [
                        "type":        "string",
                        "description": "Destination node's display name."
                    ] as [String: Any],
                    "customer_class": [
                        "type":        "integer",
                        "minimum":     0,
                        "description": "Disambiguator for parallel links — the link's customer_class."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["from_node_name", "to_node_name"]
            ],
            handler: { input in
                guard let fromName = input["from_node_name"] as? String, !fromName.isEmpty else {
                    throw ToolError.invalidInput("`from_node_name` is required.")
                }
                guard let toName = input["to_node_name"] as? String, !toName.isEmpty else {
                    throw ToolError.invalidInput("`to_node_name` is required.")
                }
                let editor = activeEditor()
                let from = try findNode(named: fromName, in: editor)
                let to   = try findNode(named: toName,   in: editor)

                let candidates = editor.links.filter {
                    $0.fromNodeID == from.id && $0.toNodeID == to.id
                }
                if candidates.isEmpty {
                    throw ToolError.invalidInput(
                        "No link from \"\(fromName)\" to \"\(toName)\"."
                    )
                }
                let classFilter = input["customer_class"] as? Int
                let matches: [NetworkLink]
                if let classFilter {
                    matches = candidates.filter { $0.customerClass == classFilter }
                    if matches.isEmpty {
                        let classes = candidates.map { $0.customerClass }.sorted()
                        throw ToolError.invalidInput(
                            "No link from \"\(fromName)\" to \"\(toName)\" with customer_class=\(classFilter). Available classes on this pair: \(classes.map(String.init).joined(separator: ", "))."
                        )
                    }
                } else {
                    matches = candidates
                }
                guard matches.count == 1 else {
                    let classes = matches.map { $0.customerClass }.sorted()
                    throw ToolError.invalidInput(
                        "Multiple parallel links from \"\(fromName)\" to \"\(toName)\" (customer_class values: \(classes.map(String.init).joined(separator: ", "))). Pass `customer_class` to disambiguate."
                    )
                }
                let link = matches[0]
                editor.deleteLink(id: link.id)
                return "Deleted link \(from.name) → \(to.name) (class \(link.customerClass))."
            }
        )
    }

    // MARK: actions

    private static func makeRunCommand(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel,
        refusal: @escaping @MainActor () -> String?
    ) -> ToolDefinition {
        let names = AICommand.allCases.map(\.rawValue)
        let labels = AICommand.allCases
            .map { "- \($0.rawValue): \($0.humanLabel)" }
            .joined(separator: "\n")
        return ToolDefinition(
            name: "run_command",
            description: """
            Execute a BNET menu command on the currently-active network and \
            return the resulting Status-pane output as text. The tool waits \
            up to `timeout_seconds` for the run to settle (no new status \
            messages for ~2 s) and then returns whatever was appended to \
            the Status pane during that window. Available commands:

            \(labels)

            Call get_network_summary first if you're unsure which command \
            is appropriate — some only work with finite buffers and some \
            only with infinite buffers. For very long Monte Carlo runs, \
            increase `timeout_seconds` (max 600). If the timeout fires \
            before the run finishes, call `read_status` again later to \
            collect the rest.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type":        "string",
                        "description": "The command to execute.",
                        "enum":        names
                    ] as [String: Any],
                    "timeout_seconds": [
                        "type":        "number",
                        "description": "Max seconds to wait for the run to settle (default 60, max 600).",
                        "minimum":     1,
                        "maximum":     600
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["name"]
            ],
            handler: { input in
                guard let raw = input["name"] as? String else {
                    throw ToolError.invalidInput("Missing 'name' argument.")
                }
                guard let cmd = AICommand(rawValue: raw) else {
                    throw ToolError.invalidInput(
                        "'\(raw)' is not a valid command. Valid: \(names.joined(separator: ", "))"
                    )
                }
                let timeout = min(
                    600.0,
                    max(1.0, (input["timeout_seconds"] as? Double) ?? 60.0)
                )

                // Menu commands act on the tab in front; refuse, naming
                // both tabs, rather than analyse the wrong network.
                if let reason = refusal() {
                    return reason
                }

                let editor = activeEditor()
                let baseline = editor.statusMessages.count

                NotificationCenter.default.post(
                    name: .bnetExecuteCommand,
                    object: nil,
                    userInfo: ["command": cmd.rawValue]
                )

                // Poll the status buffer. Settle when no new lines appear
                // for `quietWindow` seconds, or fall through after `timeout`.
                let pollInterval: UInt64 = 250_000_000   // 0.25 s
                let quietWindow:  Double = 2.0
                let started = Date()
                var lastCount = baseline
                var lastChange = Date()

                while Date().timeIntervalSince(started) < timeout {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    let now = await MainActor.run { editor.statusMessages.count }
                    if now != lastCount {
                        lastCount = now
                        lastChange = Date()
                    } else if now > baseline,
                              Date().timeIntervalSince(lastChange) >= quietWindow {
                        break
                    }
                }

                let snapshot = await MainActor.run { editor.statusMessages }
                let newLines = Array(snapshot.dropFirst(baseline)).map(\.formattedLine)
                let timedOut = Date().timeIntervalSince(started) >= timeout
                let header = timedOut
                    ? "(\(cmd.humanLabel) — timed out after \(Int(timeout))s; partial output:)"
                    : "(\(cmd.humanLabel) — settled with \(newLines.count) new line(s):)"
                if newLines.isEmpty {
                    return "\(header)\n(no status output captured)"
                }
                return "\(header)\n" + newLines.joined(separator: "\n")
            }
        )
    }

    private static func makeReadStatus(
        activeEditor: @escaping @MainActor () -> NetworkEditorModel
    ) -> ToolDefinition {
        ToolDefinition(
            name: "read_status",
            description: """
            Return the most recent N entries from the Status pane (the same \
            log that shows algorithm output, warnings, and run results). \
            Useful after `run_command` if you suspect the run was still \
            producing output when the tool returned, or any time you want \
            to inspect what the user has been seeing.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "tail": [
                        "type":        "integer",
                        "description": "Number of most-recent lines to return (default 50, max 500).",
                        "minimum":     1,
                        "maximum":     500
                    ] as [String: Any]
                ] as [String: Any],
                "required": [String]()
            ],
            handler: { input in
                let n = min(500, max(1, (input["tail"] as? Int) ?? 50))
                let lines = activeEditor().statusMessages.suffix(n)
                if lines.isEmpty {
                    return "(Status pane is empty.)"
                }
                return lines.map(\.formattedLine).joined(separator: "\n")
            }
        )
    }
}
