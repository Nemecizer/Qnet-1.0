import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File ▸ Export ▸ SRBM Solver Input (.in)…
///
/// One sheet replaces the three former commands ("Export as SRBM…",
/// "Export as RBM…", "Export with Communication Blocking") that all wrote
/// byte-identical files. With the default blocking convention the output
/// is unchanged; for finite-buffer networks the user may additionally
/// pick the loss-mode or BAS-mode correction that `--export-cmp` exposes
/// on the command line.
struct SRBMExportSheet: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @Environment(\.dismiss) private var dismiss

    enum BlockingConvention: Int, CaseIterable, Identifiable {
        case manufacturing = 0
        case lossCorrection = 1
        case basCorrection = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .manufacturing:  return "Manufacturing blocking (SRBM default)"
            case .lossCorrection: return "Loss-network correction"
            case .basCorrection:  return "BAS + external-loss correction"
            }
        }

        var detail: String {
            switch self {
            case .manufacturing:
                return "The offered arrival rate α feeds every station; matches the spectral, finite-element and LP solvers."
            case .lossCorrection:
                return "Thins the arrival stream by the blocking probability, for comparison against a loss-network simulation (--loss-fix)."
            case .basCorrection:
                return "Adjusts drift for blocking-after-service with external loss (--bas-fix)."
            }
        }
    }

    @State private var convention: BlockingConvention = .manufacturing
    @State private var errorMessage: String?

    private var stationCount: Int { editor.nodes.filter { $0.kind == .station }.count }
    private var classCount: Int { Set(editor.links.map(\.customerClass)).count }

    private var documentName: String {
        editor.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        DSSheet {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                DSSheetHeader(
                    "Export SRBM Solver Input",
                    subtitle: "Writes the drift θ, covariance Γ, reflection matrix R and box dimensions read by srbm_solver and bnet."
                ) {
                    DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                       systemImage: DS.Symbol.export,
                                       tint: DS.Color.infoText)
                }
                // The Γ in this file is the SRBM's covariance MATRIX (see
                // `SRBMExporter.export`'s format comment), not the
                // throughput Γ the solvers print — the one letter names
                // two quantities, so the subtitle gets its own "?".
                DSGlossaryButton(label: "Covariance Γ", text: DS.Glossary.covariance)
                    .padding(.top, DS.Spacing.xxs)
            }
        } content: {
            Form {
                Section {
                    LabeledContent("Network") {
                        Text(documentName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Stations") {
                        Text("\(stationCount)").font(DS.Font.number)
                    }
                    LabeledContent("Customer classes") {
                        Text("\(classCount)").font(DS.Font.number)
                    }
                    LabeledContent("Buffers") {
                        Text(editor.infiniteBuffers ? "Infinite (orthant)" : "Finite (hypercube)")
                    }
                } header: {
                    // "Document", not "Network": the section sits directly
                    // above a row labelled Network.
                    Text("Document")
                }

                Section {
                    Picker("Blocking convention", selection: $convention) {
                        ForEach(BlockingConvention.allCases) { c in
                            Text(c.title).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(editor.infiniteBuffers)
                    .help(editor.infiniteBuffers
                          ? "Blocking corrections apply to finite-buffer networks only"
                          : "How finite buffers block upstream stations in the exported SRBM")
                    .accessibilityLabel("Blocking convention")
                } header: {
                    Text("Blocking")
                } footer: {
                    Text(editor.infiniteBuffers
                         ? "Infinite-buffer networks never block; the manufacturing convention is used."
                         : convention.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } footer: {
            DSSheetFooter(
                problem: editor.nodes.isEmpty ? "The network is empty; add nodes before exporting." : nil,
                helpTopic: .solverInputs,
                confirmTitle: "Export…",
                canConfirm: !editor.nodes.isEmpty,
                cancelHelp: "Close without exporting (Esc)",
                confirmHelp: "Choose a destination and write the .in file (Return)",
                blockedHelp: "Add at least one node to export",
                onCancel: { dismiss() },
                onConfirm: { performExport() }
            )
        }
        // Tall enough for the header's two-line subtitle, both grouped
        // sections and a two-line footer without an inner scrollbar.
        .dsSheetFrame(.regular)
        .alert("Export Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Actions

    private func performExport() {
        let finite = !editor.infiniteBuffers
        let result = SRBMExporter.export(
            nodes: editor.nodes,
            links: editor.links,
            infiniteBuffers: editor.infiniteBuffers,
            lossModeCorrection: finite && convention == .lossCorrection,
            basModeCorrection: finite && convention == .basCorrection
        )

        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
            editor.addStatus("SRBM export failed: \(error.localizedDescription)", severity: .error)

        case .success(let content):
            let panel = NSSavePanel()
            panel.title = "Export SRBM Solver Input"
            panel.prompt = "Export"
            panel.nameFieldStringValue = documentName + ".in"
            panel.allowedContentTypes = [UTType(filenameExtension: "in") ?? .plainText, .plainText]
            panel.allowsOtherFileTypes = true
            panel.canCreateDirectories = true
            if let dir = editor.currentFileURL?.deletingLastPathComponent() {
                panel.directoryURL = dir
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                editor.addStatus("Exported SRBM solver input to \(url.path).", severity: .success)
                dismiss()
            } catch {
                errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
                editor.addStatus("SRBM export write failed: \(error.localizedDescription)", severity: .error)
            }
        }
    }
}
