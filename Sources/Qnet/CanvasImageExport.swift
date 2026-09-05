import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// Diagram export
// ─────────────────────────────────────────────────────────────────────────────
//
// Qnet's users publish these networks in papers, and the canvas is the one
// picture the app can draw — so the picture has to be able to leave.  This
// file renders the shipping canvas layers (`GridCanvas`, `LinkLayerCanvas`,
// `NetworkNodeView`) offscreen at any scale and hands the result to a file,
// the pasteboard or the printer.
//
//   File ▸ Export ▸ Diagram as PDF…      vector; options sheet first
//   File ▸ Export ▸ Diagram as PNG…      raster; options sheet first
//   Edit ▸ Copy as Image (⌥⌘C)           PDF + TIFF on the pasteboard — the
//                                        selection when there is one, else
//                                        the whole diagram
//   File ▸ Print Diagram… (⌘P)           the PDF page, drawn vector through
//                                        the standard Print sheet, so paper
//                                        (and Save as PDF) get vector, not
//                                        a bitmap
//
// The options (`CanvasExportOptions`: scale, ground, grid, class legend)
// are asked for by the two Export commands and remembered; Print and Copy
// reuse the remembered answers so they stay one keystroke.
//
// Everything is drawn in the light appearance whatever the app is set to:
// a figure that lands in a paper or a slide sits on white, and a diagram
// exported at midnight must look the same as one exported at noon.
// ─────────────────────────────────────────────────────────────────────────────

/// A frozen copy of the canvas with no selection, no hover, no marquee and
/// no gestures — just the drawing, plus the class legend when asked for.
struct CanvasSnapshotView: View {
    let scene: CanvasScene
    let nodes: [NetworkNode]
    let infiniteBuffers: Bool
    let utilisation: [UUID: Double]
    let size: CGSize
    /// Opaque ground, or `nil` for a transparent one (PDF).
    let background: Color?
    let showsGrid: Bool
    /// Number of customer classes to key in the bottom-left corner; 0 or
    /// 1 draws no legend.
    let legendClassCount: Int

    var body: some View {
        ZStack {
            if let background {
                Rectangle().fill(background)
            }
            if showsGrid {
                GridCanvas(transform: scene.transform)
            }
            LinkLayerCanvas(
                scene: scene,
                state: LinkLayerState(selectedLinkID: nil, hoveredLinkID: nil,
                                      emphasisedClass: nil, scale: scene.transform.scale))
            ForEach(nodes) { node in
                NetworkNodeView(
                    node: node,
                    scale: scene.transform.scale,
                    isSelected: false,
                    isHovered: false,
                    isMarqueeCandidate: false,
                    isPendingLinkStart: false,
                    infiniteBuffers: infiniteBuffers,
                    utilisation: utilisation[node.id]
                )
                .position(scene.displayCentres[node.id] ?? .zero)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) {
            if legendClassCount > 1 {
                // The same chips the canvas legend uses, minus the buttons.
                HStack(spacing: DS.Spacing.s) {
                    ForEach(0..<legendClassCount, id: \.self) { classIdx in
                        DSBadge(text: CustomerClass.label(for: classIdx),
                                tint: CustomerClass.color(for: classIdx),
                                swatch: true)
                    }
                }
                .padding(CanvasImageExport.margin)
            }
        }
    }
}

@MainActor
enum CanvasImageExport {

    /// Display-point margin left around the drawing, so labels, ρ badges
    /// and bowed links are never clipped at the edge.
    static let margin: CGFloat = DS.Spacing.xl
    /// Height reserved under the drawing for the class legend.
    private static let legendBand: CGFloat = DS.Layout.controlHeight + DS.Spacing.s

    // MARK: - Geometry

    /// World rectangle that actually contains the drawing: every node
    /// body, every routed link and room for the label block that hangs
    /// below each node.
    ///
    /// Measured from a scene built at zoom 1 with no pan, where display
    /// coordinates *are* world coordinates — so the bows the router chose
    /// are included rather than guessed at.
    static func contentRect(nodes: [NetworkNode], links: [NetworkLink],
                            routePlan: LinkRoutePlan) -> CGRect? {
        guard !nodes.isEmpty else { return nil }
        let unit = CanvasTransform(scale: 1, pan: .zero, viewportSize: .zero)
        let scene = CanvasScene(nodes: nodes, links: links, transform: unit,
                                classFilter: nil, routePlan: routePlan)
        // Every body and the label block under it — the same rect the
        // router keeps links out of, so the export's idea of where text
        // sits is the canvas's.
        var rect = CanvasScene.nodeWorldRect(nodes[0])
        for n in nodes {
            rect = rect.union(CanvasScene.nodeWorldRect(n))
            rect = rect.union(CanvasScene.nodeLabelRect(n))
        }
        for item in scene.links {
            for p in item.geometry.polyline {
                rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
            }
        }
        // Room for the ρ badge, which sits above the body's top-right,
        // and for a self-loop's chip above its apex.
        return rect.insetBy(dx: -DS.Spacing.l, dy: -DS.Spacing.l)
    }

    /// The part of the network to draw: everything, or the selected nodes
    /// and the links between them.
    @MainActor private struct Subject {
        let nodes: [NetworkNode]
        let links: [NetworkLink]
        let isSelection: Bool

        init(editor: NetworkEditorModel, only ids: Set<UUID>?) {
            if let ids, !ids.isEmpty {
                nodes = editor.nodes.filter { ids.contains($0.id) }
                links = editor.links.filter { ids.contains($0.fromNodeID) && ids.contains($0.toNodeID) }
                isSelection = true
            } else {
                nodes = editor.nodes
                links = editor.links
                isSelection = false
            }
        }
    }

    /// The snapshot to render, plus its point size.
    ///
    /// - zoom: world-to-point scale of the drawing itself.
    /// - options: ground, grid and legend; `pixelScale` is the raster
    ///   renderer's business, not the snapshot's.
    /// - opaqueFallback: what a transparent ground becomes when the
    ///   output cannot carry alpha (PNG, TIFF, paper).
    private static func snapshot(
        editor: NetworkEditorModel,
        subject: Subject,
        zoom: CGFloat,
        options: CanvasExportOptions,
        opaqueFallback: Bool
    ) -> (view: CanvasSnapshotView, size: CGSize)? {
        // The routes the canvas shows, so a selection keeps the bows it
        // has on screen rather than being re-planned in isolation.
        let plan = editor.routePlan
        guard let content = contentRect(nodes: subject.nodes, links: subject.links,
                                        routePlan: plan) else { return nil }
        let classCount = options.includesLegend ? editor.numberOfCustomerClasses : 0
        let band: CGFloat = classCount > 1 ? legendBand : 0
        let size = CGSize(width: content.width * zoom + 2 * margin,
                          height: content.height * zoom + 2 * margin + band)
        let transform = CanvasTransform(
            scale: zoom,
            pan: CGSize(width: margin - content.minX * zoom,
                        height: margin - content.minY * zoom),
            viewportSize: size)
        let scene = CanvasScene(nodes: subject.nodes, links: subject.links,
                                transform: transform, classFilter: editor.classFilter,
                                routePlan: plan)
        let background: Color?
        switch options.background {
        case .canvas: background = DS.Color.surfaceRaised
        case .white: background = paperWhite
        case .transparent: background = opaqueFallback ? paperWhite : nil
        }
        let view = CanvasSnapshotView(
            scene: scene,
            nodes: subject.nodes,
            infiniteBuffers: editor.infiniteBuffers,
            utilisation: editor.stationUtilisation,
            size: size,
            background: background,
            showsGrid: options.includesGrid,
            legendClassCount: classCount)
        return (view, size)
    }

    /// Paper: the one place in the app a literal white is right — every
    /// export is rendered in the light appearance for a page, and a
    /// figure's ground is not chrome.
    private static let paperWhite = Color(white: 1)

    // MARK: - Renderers

    /// Runs `body` with the light appearance current, so a diagram
    /// exported from a dark-mode session still lands on white paper.
    private static func inLightAppearance<T>(_ body: () -> T) -> T {
        guard let aqua = NSAppearance(named: .aqua) else { return body() }
        var result: T?
        aqua.performAsCurrentDrawingAppearance { result = body() }
        // `performAsCurrentDrawingAppearance` runs its block synchronously.
        return result ?? body()
    }

    static func image(editor: NetworkEditorModel,
                      options: CanvasExportOptions = .load(),
                      only ids: Set<UUID>? = nil,
                      zoom: CGFloat = 1) -> NSImage? {
        guard let snap = snapshot(editor: editor, subject: Subject(editor: editor, only: ids),
                                  zoom: zoom, options: options, opaqueFallback: true)
        else { return nil }
        return inLightAppearance {
            let renderer = ImageRenderer(content: snap.view)
            renderer.proposedSize = ProposedViewSize(snap.size)
            renderer.scale = CGFloat(options.pixelScale)
            renderer.isOpaque = true
            return renderer.nsImage
        }
    }

    static func pngData(editor: NetworkEditorModel,
                        options: CanvasExportOptions = .load(),
                        only ids: Set<UUID>? = nil) -> Data? {
        guard let image = image(editor: editor, options: options, only: ids),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func pdfData(editor: NetworkEditorModel,
                        options: CanvasExportOptions = .load(),
                        only ids: Set<UUID>? = nil,
                        zoom: CGFloat = 1) -> Data? {
        guard let snap = snapshot(editor: editor, subject: Subject(editor: editor, only: ids),
                                  zoom: zoom, options: options, opaqueFallback: false)
        else { return nil }
        return inLightAppearance {
            let renderer = ImageRenderer(content: snap.view)
            renderer.proposedSize = ProposedViewSize(snap.size)
            let data = NSMutableData()
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
                else { return }
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
                pdf.closePDF()
            }
            return data.isEmpty ? nil : (data as Data)
        }
    }

    // MARK: - Commands

    /// Suggested file name: the document's own name, or the network shape.
    private static func suggestedName(editor: NetworkEditorModel) -> String {
        if let url = editor.currentFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Network Diagram"
    }

    static func exportPDF(editor: NetworkEditorModel) {
        guard !editor.nodes.isEmpty else {
            editor.addStatus("Nothing to export: the canvas is empty.", severity: .warning)
            return
        }
        CanvasExportOptionsPresenter.present(format: .pdf,
                                             classCount: editor.numberOfCustomerClasses) { options in
            save(editor: editor, type: .pdf, suffix: "pdf") {
                pdfData(editor: editor, options: options)
            }
        }
    }

    static func exportPNG(editor: NetworkEditorModel) {
        guard !editor.nodes.isEmpty else {
            editor.addStatus("Nothing to export: the canvas is empty.", severity: .warning)
            return
        }
        CanvasExportOptionsPresenter.present(format: .png,
                                             classCount: editor.numberOfCustomerClasses) { options in
            save(editor: editor, type: .png, suffix: "png") {
                pngData(editor: editor, options: options)
            }
        }
    }

    private static func save(editor: NetworkEditorModel,
                             type: UTType, suffix: String,
                             make: @escaping () -> Data?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(suggestedName(editor: editor)).\(suffix)"
        panel.canCreateDirectories = true
        panel.title = "Export Diagram"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = make() else {
            editor.addStatus("!! Could not render the diagram for export.", severity: .error)
            return
        }
        do {
            try data.write(to: url)
            editor.addStatus("Exported diagram to \(url.lastPathComponent).")
        } catch {
            editor.addStatus("!! Could not write \(url.lastPathComponent): \(error.localizedDescription)",
                             severity: .error)
        }
    }

    /// Both a PDF (vector, transparent — pastes crisply into Keynote and
    /// Pages) and a TIFF (opaque — for apps that take bitmaps only), so
    /// the receiving app picks whichever it prefers.  With a selection on
    /// the canvas, only the selected nodes and the links between them are
    /// copied; with none, the whole diagram.
    static func copyToPasteboard(editor: NetworkEditorModel) {
        guard !editor.nodes.isEmpty else {
            editor.addStatus("Nothing to copy: the canvas is empty.", severity: .warning)
            return
        }
        let selection = editor.selectionUnion
        let only: Set<UUID>? = selection.isEmpty ? nil : selection
        let options = CanvasExportOptions.load()
        let board = NSPasteboard.general
        board.clearContents()
        var wrote = false
        if let pdf = pdfData(editor: editor, options: options, only: only) {
            board.setData(pdf, forType: .pdf)
            wrote = true
        }
        if let image = image(editor: editor, options: options, only: only),
           let tiff = image.tiffRepresentation {
            board.setData(tiff, forType: .tiff)
            wrote = true
        }
        let what = only.map { "\($0.count) selected node\($0.count == 1 ? "" : "s") and the links between them" }
            ?? "the diagram"
        editor.addStatus(wrote
                         ? "Copied \(what) to the clipboard as PDF and TIFF."
                         : "!! Could not render the diagram for the clipboard.",
                         severity: wrote ? .info : .error)
    }

    /// Prints the vector render, scaled to the page.  Restores the
    /// standard macOS Print sheet — and with it the Save as PDF escape
    /// hatch every Mac user expects to find under ⌘P.
    ///
    /// The page is the same PDF `exportPDF` writes, drawn through a
    /// `CGPDFPage` inside a custom view's `draw(_:)`, so lines and labels
    /// stay resolution-independent on paper and "Save as PDF" from the
    /// print panel yields vector art rather than a 4× raster. Paper size,
    /// orientation and margins come from `NSPrintInfo.shared`, which is
    /// what File ▸ Page Setup… edits.
    static func print(editor: NetworkEditorModel) {
        guard !editor.nodes.isEmpty else {
            editor.addStatus("Nothing to print: the canvas is empty.", severity: .warning)
            return
        }
        var options = CanvasExportOptions.load()
        // Paper has its own ground.
        if options.background == .canvas { options.background = .transparent }
        guard let data = pdfData(editor: editor, options: options),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else {
            editor.addStatus("!! Could not render the diagram for printing.", severity: .error)
            return
        }
        let info = NSPrintInfo.shared
        let paper = CGSize(
            width: info.paperSize.width - info.leftMargin - info.rightMargin,
            height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let box = page.getBoxRect(.mediaBox)
        let fit = min(paper.width / max(box.width, 1),
                      paper.height / max(box.height, 1), 1)
        let frame = CGRect(x: 0, y: 0,
                           width: box.width * fit,
                           height: box.height * fit)
        let view = DiagramPrintView(page: page, frame: frame)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = suggestedName(editor: editor)
        operation.run()
    }
}

/// Draws one PDF page into whatever context asks for it — the print
/// spool, a preview, or the print panel's Save as PDF — so the diagram
/// stays vector all the way to paper.
private final class DiagramPrintView: NSView {
    private let page: CGPDFPage

    init(page: CGPDFPage, frame: CGRect) {
        self.page = page
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        // NSView and PDF share a bottom-left origin, so the page only has
        // to be scaled to the frame and centred; no flip.
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - box.width * scale) / 2,
                        y: (bounds.height - box.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
