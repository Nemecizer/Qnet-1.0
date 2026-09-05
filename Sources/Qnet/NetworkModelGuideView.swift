import SwiftUI
import AppKit

/// A non-spatial representation of the canvas plus an explicit explanation
/// of capacity/blocking semantics. It gives keyboard and VoiceOver users a
/// complete route inventory without requiring them to infer topology from
/// node coordinates.
struct NetworkModelGuideView: View {
    @ObservedObject var editor: NetworkEditorModel
    @ObservedObject var settings: AppSettings
    let close: () -> Void

    private enum Page: String, CaseIterable, Identifiable {
        case outline = "Network Outline"
        case capacity = "Capacity & Blocking"
        var id: String { rawValue }
    }

    @State private var page: Page = .outline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: DS.Symbol.network)
                    .font(DS.Font.sheetGlyph)
                    .foregroundStyle(DS.Color.infoText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Network Model")
                        .font(DS.Font.sheetTitle)
                    Text("Structure and queue-capacity semantics")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: DS.Layout.popoverMaxWidth)
            }
            .padding(DS.Spacing.l)
            .background(DS.Color.surface)

            DSRule()

            Group {
                switch page {
                case .outline:
                    NetworkOutlineView(editor: editor)
                case .capacity:
                    BufferSemanticsView(editor: editor, settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DSRule()
            HStack {
                Text("Changes to the network-wide buffer model are undoable on the canvas.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.m)
            .background(DS.Color.surface)
        }
        .frame(minWidth: DS.Layout.Window.auxWideMin.width,
               minHeight: DS.Layout.Window.auxWideMin.height)
    }
}

private struct NetworkOutlineView: View {
    @ObservedObject var editor: NetworkEditorModel

    private var nodeByID: [UUID: NetworkNode] {
        Dictionary(uniqueKeysWithValues: editor.nodes.map { ($0.id, $0) })
    }

    var body: some View {
        if editor.nodes.isEmpty {
            DSEmptyState(
                systemImage: DS.Symbol.network,
                title: "No Network Yet",
                message: "Add sources, stations, buffers and sinks to build a structural outline."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                List {
                    Section("Nodes in document order") {
                        ForEach(editor.nodes) { node in
                            Button { select(node) } label: {
                                nodeRow(node)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Selects this node on the canvas")
                        }
                    }
                }
                .frame(minWidth: DS.Layout.sidePaneMinWidth,
                       idealWidth: DS.Layout.rightColumnIdealWidth)
                .accessibilityLabel("Network nodes")

                VStack(spacing: 0) {
                    HStack(spacing: DS.Spacing.s) {
                        Text("Routes")
                            .font(DS.Font.sectionTitle)
                        DSBadge(text: "\(editor.links.count)")
                        Spacer()
                    }
                    .padding(DS.Spacing.s)
                    .background(DS.Color.surface)

                    DSRule()

                    if editor.links.isEmpty {
                        DSEmptyState(
                            systemImage: DS.Symbol.link,
                            title: "No Routes Yet",
                            message: "Connect the nodes to describe customer flow."
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(editor.links) { link in
                            Button { select(link) } label: {
                                routeRow(link)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Selects this route on the canvas")
                        }
                        .accessibilityLabel("Customer routes")
                    }
                }
                .frame(minWidth: DS.Layout.canvasPaneMinWidth)
            }
        }
    }

    private func nodeRow(_ node: NetworkNode) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(DS.Color.nodeTint(for: node.kind))
                .frame(width: DS.Layout.iconButtonWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(node.name)
                        .font(DS.Font.labelEmphasis)
                    Text(node.kind.displayName)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Text(nodeDescription(node))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if editor.selectedNodeID == node.id || editor.selectedNodeIDs.contains(node.id) {
                Image(systemName: DS.Symbol.checkmark)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func routeRow(_ link: NetworkLink) -> some View {
        let from = nodeByID[link.fromNodeID]?.name ?? "Missing node"
        let to = nodeByID[link.toNodeID]?.name ?? "Missing node"
        return HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: DS.Symbol.link)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Layout.iconButtonWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("\(from) → \(to)")
                    .font(DS.Font.labelEmphasis)
                HStack(spacing: DS.Spacing.s) {
                    Text(classDescription(link))
                    Text("p = \(DS.Number.format(link.routingProbability, significantDigits: 5))")
                }
                .font(DS.Font.monoCaption)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            if editor.selectedLinkID == link.id {
                Image(systemName: DS.Symbol.checkmark)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func nodeDescription(_ node: NetworkNode) -> String {
        switch node.kind {
        case .station:
            let classCount = max(node.serviceDistributions.count, 1)
            return "\(node.numberOfServers) server\(node.numberOfServers == 1 ? "" : "s") · \(classCount) service class\(classCount == 1 ? "" : "es")"
        case .buffer:
            return editor.infiniteBuffers
                ? "Unbounded in the active network model; saved finite capacity \(node.bufferSize)"
                : "Finite waiting capacity \(node.bufferSize)"
        case .source:
            return "\(node.distribution.pickerName) · \(node.distributionParameters)"
        case .sink:
            return "Customers leave the network"
        }
    }

    private func classDescription(_ link: NetworkLink) -> String {
        let incoming = CustomerClass.label(for: link.customerClass)
        guard link.hasClassTransition else { return incoming }
        return "\(incoming) → \(CustomerClass.label(for: link.exitClass))"
    }

    private func select(_ node: NetworkNode) {
        editor.selectedLinkID = nil
        editor.selectedNodeIDs = []
        editor.selectedNodeID = node.id
    }

    private func select(_ link: NetworkLink) {
        editor.selectedNodeID = nil
        editor.selectedNodeIDs = []
        editor.selectedLinkID = link.id
    }
}

private struct BufferSemanticsView: View {
    @ObservedObject var editor: NetworkEditorModel
    @ObservedObject var settings: AppSettings

    private struct BlockingRow: Identifiable {
        let id: Int
        let name: String
        let fullDestination: String
        let upstream: String
        let interpretation: String
    }

    private let rows = [
        BlockingRow(
            id: 0, name: "Loss",
            fullDestination: "The arriving customer is discarded.",
            upstream: "A completing server is released immediately.",
            interpretation: "Communication, admission-control and other loss systems."
        ),
        BlockingRow(
            id: 1, name: "BAS",
            fullDestination: "The customer is retained after service.",
            upstream: "The completed customer blocks its server until space opens; external arrivals wait outside.",
            interpretation: "Manufacturing or transfer systems with back-pressure."
        ),
        BlockingRow(
            id: 2, name: "BAS + external loss",
            fullDestination: "Internal customers are retained; external arrivals are discarded.",
            upstream: "Internal completions block their server until space opens.",
            interpretation: "Back-pressure inside the network with admission loss at its boundary."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("Network-Wide Capacity")
                        .font(DS.Font.sectionTitle)
                    Picker("Buffer model", selection: Binding(
                        get: { editor.infiniteBuffers },
                        set: { editor.setInfiniteBuffers($0) }
                    )) {
                        Text("Finite buffers — capacities apply").tag(false)
                        Text("Infinite buffers — capacities are ignored").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Text(editor.infiniteBuffers
                         ? "Every queue may grow without a capacity rejection or blocking event. Stability is required for a steady state."
                         : "Each buffer's saved capacity applies. A run must also specify what happens when a destination is full.")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                }

                DSRule()

                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Finite-Buffer Blocking Rule")
                            .font(DS.Font.sectionTitle)
                        Spacer()
                        DSBadge(
                            text: rows.first { $0.id == settings.simBlocking }?.name ?? "Unknown",
                            tint: DS.Color.info,
                            emphasis: .tinted
                        )
                    }
                    Picker("Monte Carlo default", selection: $settings.simBlocking) {
                        ForEach(rows) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(editor.infiniteBuffers)

                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            tableHeader("Rule")
                            tableHeader("When a destination is full")
                            tableHeader("Effect upstream")
                            tableHeader("Typical interpretation")
                        }
                        ForEach(rows) { row in
                            GridRow {
                                tableCell(row.name, emphasized: true)
                                tableCell(row.fullDestination)
                                tableCell(row.upstream)
                                tableCell(row.interpretation)
                            }
                        }
                    }
                    .accessibilityLabel("Comparison of finite-buffer blocking rules")

                    Label(
                        "A bounded, continuously reflected SRBM is a diffusion approximation. It is not identical to discrete Loss or BAS dynamics; matching its numerics across solvers does not establish queue-model accuracy.",
                        systemImage: DS.Symbol.info
                    )
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.infoText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Spacing.l)
        }
    }

    private func tableHeader(_ value: String) -> some View {
        Text(value)
            .font(DS.Font.tableHeader)
            .foregroundStyle(DS.Color.textSecondary)
            .frame(minWidth: DS.Layout.tableCellMinWidth * 3,
                   maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.s)
            .background(DS.Color.surface)
    }

    private func tableCell(_ value: String, emphasized: Bool = false) -> some View {
        Text(value)
            .font(emphasized ? DS.Font.labelEmphasis : DS.Font.body)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: DS.Layout.tableCellMinWidth * 3,
                   maxWidth: .infinity, alignment: .topLeading)
            .padding(DS.Spacing.s)
            .overlay(alignment: .bottom) { DSRule() }
    }
}

@MainActor
enum NetworkModelGuideWindow {
    private static var retained: NSWindow?

    /// Opens the guide, or brings the open one forward re-pointed at
    /// `editor`. It is deliberately NOT closed and rebuilt: rebuilding
    /// throws away the frame the user dragged it to, within one session.
    static func show(editor: NetworkEditorModel, settings: AppSettings) {
        let model = NetworkModelGuideModel.shared
        model.update(editor: editor, settings: settings)

        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }

        let window = AuxiliaryWindow.make(
            id: "network-model",
            title: "Network Model",
            contentSize: DS.Layout.Window.auxWideContent,
            minSize: DS.Layout.Window.auxWideMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetNetworkModelWindow"
        ) { ref in
            NetworkModelGuideWindowRoot(model: model, close: { ref.close() })
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
}

/// What the Network Model guide is currently describing. The window is
/// built once and reused (rebuilding it loses the frame the user dragged
/// it to), so the editor and settings it points at have to be swappable
/// under the live view rather than captured at construction.
@MainActor
final class NetworkModelGuideModel: ObservableObject {
    static let shared = NetworkModelGuideModel()

    @Published fileprivate var editor: NetworkEditorModel?
    @Published fileprivate var settings: AppSettings?

    private init() {}

    fileprivate func update(editor: NetworkEditorModel, settings: AppSettings) {
        if self.editor !== editor { self.editor = editor }
        if self.settings !== settings { self.settings = settings }
    }
}

/// Root of the reused window: renders the guide for whichever editor the
/// model currently points at.
private struct NetworkModelGuideWindowRoot: View {
    @ObservedObject var model: NetworkModelGuideModel
    let close: () -> Void

    var body: some View {
        if let editor = model.editor, let settings = model.settings {
            NetworkModelGuideView(editor: editor, settings: settings, close: close)
        } else {
            // Only reachable if the window is shown before any editor has
            // claimed it; a live empty state beats a blank pane.
            DSEmptyState(
                systemImage: DS.Symbol.network,
                title: "No Active Network",
                message: "Open or create a network to see how Qnet models it.")
            .frame(minWidth: DS.Layout.Window.auxMinWidth,
                   minHeight: DS.Layout.Window.auxMinHeight)
        }
    }
}
