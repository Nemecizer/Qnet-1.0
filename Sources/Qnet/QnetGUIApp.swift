import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

final class QnetGUIApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Closures installed by `QnetGUIApp` so this delegate — which lives
    /// outside the SwiftUI state graph — can flush and/or clear the tab
    /// snapshot at quit time without having to reach into SwiftUI
    /// internals.  See `QnetGUIApp.body`, the `.task` block.
    @MainActor static var saveTabsForRestore: (() -> Void)?
    @MainActor static var clearTabsForRestore: (() -> Void)?
    /// Returns true when at least one tab has any content (nodes or links)
    /// that's worth asking the user about.  An empty initial session
    /// shouldn't trigger the restore-tabs dialog.
    @MainActor static var hasRestorableContent: (() -> Bool)?
    /// Snapshot the Interactive Shell scrollback to UserDefaults at
    /// quit time. `QnetGUIApp` installs this; we invoke it from
    /// `applicationShouldTerminate` so the next launch can replay the
    /// previous session's output.
    @MainActor static var saveShellTranscript: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Track Reduce Motion / Increase Contrast / Differentiate Without
        // Colour so DS.Motion and DS.Stroke follow System Settings live.
        DS.A11y.startObserving()

        if DSGalleryWindow.requestedAtLaunch {
            DispatchQueue.main.async { DSGalleryWindow.show() }
        }

        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Run all main-actor work inline.  `applicationShouldTerminate` is
        // already invoked on the main thread.
        MainActor.assumeIsolated {
            // ALWAYS persist the shell transcript on quit — independent
            // of canvas state and independent of the user's "Restore
            // Tabs?" choice. The dialog text says "Restore Tabs", so
            // Don't-Restore should drop tabs, not the shell scrollback.
            // The trash button on the Status pane and Clear-Shell-History
            // are the explicit ways to wipe each persisted blob.
            Self.saveShellTranscript?()

            let nothingToRestore = !(Self.hasRestorableContent?() ?? false)
            if nothingToRestore {
                // No canvas state — just clear *tab* persistence and quit.
                // Shell transcript was already saved above.
                Self.clearTabsForRestore?()
                return
            }

            let behavior = UserDefaults.standard.integer(forKey: "tabs.restoreBehavior")

            switch behavior {
            case 1: // Always restore — flush current state
                Self.saveTabsForRestore?()
            case 2: // Never restore — drop saved state
                Self.clearTabsForRestore?()
            default: // Ask
                let answer = ConfirmAlert.ask(
                    title: "Restore tabs on next launch?",
                    message: "Your current tabs can be reopened the next time Qnet starts. Change this later in Settings ▸ General.",
                    confirmTitle: "Restore Tabs",
                    cancelTitle: "Don't Restore",
                    suppressionTitle: "Do not ask again"
                )

                if answer.confirmed {
                    Self.saveTabsForRestore?()
                    if answer.suppress {
                        UserDefaults.standard.set(1, forKey: "tabs.restoreBehavior")
                    }
                } else {
                    Self.clearTabsForRestore?()
                    if answer.suppress {
                        UserDefaults.standard.set(2, forKey: "tabs.restoreBehavior")
                    }
                }
            }
        }
        return .terminateNow
    }
}

/// CLI entry point — bypasses SwiftUI when the first arg is a recognized flag.
///   `Qnet --dump-rho <bnet>`            — prints (α, μ_eff, c, ρ) per station.
///   `Qnet --export-cmp <bnet> <outdir>` — writes the Run-Comparison input
///                                         files into <outdir> so each solver
///                                         can be invoked from a shell.
///   `Qnet --export-product-form <bnet> <json>` — exports the exact open
///                                                BCMP/Jackson subclass.
///   `Qnet --export-qbd <bnet> <json>` — exports the strict scalar M/M/1 QBD.
///   `Qnet --audit-settings`             — checks the settings registry and
///                                         exits non-zero on a stored key
///                                         with no registry row or excusal.
@MainActor
fileprivate func handleCLIIfNeeded() -> Bool {
    let args = CommandLine.arguments
    guard args.count >= 2 else { return false }

    if args[1] == "--version" {
        print("Qnet \(AppVersion.version)")
        exit(0)
    }

    // `Qnet --audit-settings` — the settings registry checked without a
    // GUI, for the release gate. Every stored key must be edited by a
    // SettingsRegistry row or listed in `unindexedKeys` with a reason, and
    // every numeric key must be bounded by exactly one import table; a key
    // added to `AppSettings.defaultsByKey` without its registry line is
    // invisible to Settings search and to Reset to Defaults. That mistake
    // shipped twice and was found both times by a person pressing ⌘,, so
    // it is checked here instead, where a script can fail on it. Prints
    // nothing and exits 0 when the registry is sound.
    if args[1] == "--audit-settings" {
        let problems = SettingsRegistry.auditProblems()
        for problem in problems {
            FileHandle.standardError.write(Data("Qnet settings-registry audit: \(problem)\n".utf8))
        }
        exit(problems.isEmpty ? 0 : 1)
    }

    func loadDoc(_ path: String) -> NetworkDocument {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("ERROR: could not read \(path)"); exit(1)
        }
        guard let doc = try? JSONDecoder().decode(NetworkDocument.self, from: data) else {
            print("ERROR: could not decode \(path)"); exit(1)
        }
        return doc
    }

    // `--ds-gallery` does not take over the process: it flags the gallery
    // window to open once the app is up, beside the normal main window.
    if args.contains("--ds-gallery") {
        DSGalleryWindow.requestedAtLaunch = true
        if args[1] == "--ds-gallery" { return false }
    }

    if args[1] == "--dump-rho" {
        guard args.count >= 3 else { return false }
        let doc = loadDoc(args[2])
        switch SRBMExporter.computeData(
            nodes: doc.nodes, links: doc.links,
            infiniteBuffers: doc.infiniteBuffers
        ) {
        case .success(let d):
            print("d=\(d.d), K=\(d.K), infiniteBuffers=\(doc.infiniteBuffers)")
            for i in 0..<d.d {
                let rho = d.capacity[i] > 1e-12 ? d.alpha[i] / d.capacity[i] : Double.nan
                print(String(format: "S%d: α=%.6f  μ_eff=%.6f  c=%.6f  ρ=%.6f",
                             i + 1, d.alpha[i], d.serviceRates[i], d.capacity[i], rho))
            }
            for k in 0..<d.K {
                var line = "class \(k + 1): α=["
                for i in 0..<d.d { line += String(format: "%.4f ", d.alphaPerClass[k][i]) }
                line += "]  μ=["
                for i in 0..<d.d { line += String(format: "%.4f ", d.classServiceRates[k][i]) }
                line += String(format: "]  λ_ext=%.4f", d.classExternalArrivals[k])
                print(line)
            }
            print("aggregatedP (\(d.d)×\(d.d)):")
            for i in 0..<d.d {
                var row = "  S\(i + 1): "
                for j in 0..<d.d {
                    row += String(format: "%.4f ", d.aggregatedP[i][j])
                }
                print(row)
            }
            print("hasRoutingCycles = \(AnalyticalTractability.hasRoutingCycles(d.aggregatedP))")
            // Use the public assess() to mirror the GUI's tractability path.
            let assessGCDG = AnalyticalTractability.assess(
                data: d,
                nodes: doc.nodes,
                infiniteBuffers: doc.infiniteBuffers,
                allowGCDG: true)
            print("AnalyticalTractability.assess(allowGCDG=true)  → kind=\(assessGCDG.kind), isTractable=\(assessGCDG.isTractable), detail='\(assessGCDG.detail)'")
            if !assessGCDG.means.isEmpty {
                let m = assessGCDG.means.enumerated().map { String(format: "S%d=%.4f", $0.offset + 1, $0.element) }.joined(separator: " ")
                print("  means(\(assessGCDG.meansLabel)): \(m)")
            }
            let assessNoGCDG = AnalyticalTractability.assess(
                data: d,
                nodes: doc.nodes,
                infiniteBuffers: doc.infiniteBuffers,
                allowGCDG: false)
            print("AnalyticalTractability.assess(allowGCDG=false) → kind=\(assessNoGCDG.kind), isTractable=\(assessNoGCDG.isTractable), detail='\(assessNoGCDG.detail)'")
        case .failure(let e):
            // The sentence the GUI would show, not the enum case: this dump
            // is how a failure is diagnosed without a screen.
            print("computeData failed: \(e.localizedDescription)")
        }
        exit(0)
    }

    if args[1] == "--dump-help" {
        // Usage: Qnet --dump-help <topic-id>  — prints how the Qnet Help
        // window typesets a topic (block kinds + text), for checking the
        // plain-text → block converter without launching the GUI.
        guard args.count >= 3, let topic = HelpTopic(rawValue: args[2]) else {
            print("Usage: Qnet --dump-help <topic>; topics: "
                  + HelpTopic.allCases.map(\.rawValue).joined(separator: " "))
            exit(1)
        }
        for block in HelpMarkup.parse(topic.text) {
            switch block {
            case .title(let t):               print("TITLE     | \(t)")
            case .headline(let t):            print("HEADLINE  | \(t)")
            case .paragraph(let t):           print("PARA      | \(t)")
            case .bullet(let m, let t, let l): print("BULLET\(l)   | \(m) \(t)")
            case .code(let lines):
                print("CODE      |")
                for l in lines { print("          |   \(l)") }
            }
        }
        exit(0)
    }

    if args[1] == "--gen-random" {
        // Usage: Qnet --gen-random <d> <K> <rho> <topology> <seed> <outdir>
        // topology: ff | jfb | gp | reent
        guard args.count >= 8 else {
            print("Usage: Qnet --gen-random <d> <K> <rho> <ff|jfb|gp|reent> <seed> <outdir>")
            exit(1)
        }
        guard let d = Int(args[2]), let K = Int(args[3]),
              let rho = Double(args[4]), let seed = UInt64(args[6]) else {
            print("ERROR: bad numeric arg"); exit(1)
        }
        let topo: RandomNetworkGenerator.Topology
        switch args[5] {
        case "ff":    topo = .feedForward
        case "jfb":   topo = .jacksonFeedback
        case "gp":    topo = .generalPMatrix
        case "reent": topo = .reentrantFeedback
        default: print("ERROR: bad topology"); exit(1)
        }
        let outdir = URL(fileURLWithPath: args[7])
        try? FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let net = RandomNetworkGenerator.generate(.init(
            stations: d, classes: K, infiniteBuffers: true,
            targetRho: rho, topology: topo, seed: seed))
        func write(_ name: String, _ s: String) {
            let url = outdir.appendingPathComponent(name)
            try? s.write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(url.path)")
        }
        if case .success(let s) = QNAExporter.export(nodes: net.nodes, links: net.links) {
            write("case.qna", s)
        }
        if case .success(let s) = BNASRBMExporter.exportForSpectral(
            nodes: net.nodes, links: net.links, degree: 8) {
            write("case.smin", s)
        }
        if case .success(let s) = BNANetworkExporter.export(nodes: net.nodes, links: net.links) {
            write("case.sim", s)
        }
        exit(0)
    }

    if args[1] == "--export-cmp" {
        guard args.count >= 4 else {
            print("Usage: Qnet --export-cmp <bnet> <outdir> [--loss-fix|--bas-fix]"); exit(1)
        }
        let doc = loadDoc(args[2])
        let outdir = URL(fileURLWithPath: args[3])
        let lossFix = args.contains("--loss-fix")
        let basFix  = args.contains("--bas-fix")
        try? FileManager.default.createDirectory(at: outdir,
                                                 withIntermediateDirectories: true)
        func write(_ name: String, _ s: String) {
            let url = outdir.appendingPathComponent(name)
            try? s.write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(url.path)")
        }
        let inf = doc.infiniteBuffers
        if case .success(let s) = SRBMExporter.exportForSpectral(
            nodes: doc.nodes, links: doc.links, infiniteBuffers: inf,
            degree: 8, lossModeCorrection: lossFix && !inf,
            basModeCorrection: basFix && !inf) {
            write("sm.in", s)
        }
        if case .success(let s) = SRBMExporter.exportForFiniteElement(
            nodes: doc.nodes, links: doc.links, infiniteBuffers: inf,
            meshSize: 12, lossModeCorrection: lossFix && !inf,
            basModeCorrection: basFix && !inf) {
            write("fm.in", s)
        }
        if case .success(let s) = SRBMExporter.exportForFiniteLP(
            nodes: doc.nodes, links: doc.links,
            lossModeCorrection: lossFix && !inf,
            basModeCorrection: basFix && !inf) {
            write("lp.in", s)
        }
        if case .success(let s) = NetworkExporter.export(
            nodes: doc.nodes, links: doc.links) {
            write("sim.txt", s)
        }
        // Run-Comparison-equivalent exports: QNA/SBD share .qna; simulator
        // uses BNANetworkExporter (the .sim format the GUI's runComparison
        // hands to jackson_sim).
        if case .success(let s) = QNAExporter.export(
            nodes: doc.nodes, links: doc.links) {
            write("qna.qna", s)
        }
        if case .success(let s) = BNASRBMExporter.exportForSpectral(
            nodes: doc.nodes, links: doc.links, degree: 8) {
            write("cmp_sm.in", s)
        }
        if case .success(let s) = BNANetworkExporter.export(
            nodes: doc.nodes, links: doc.links) {
            write("cmp_sim.sim", s)
        }
        exit(0)
    }

    if args[1] == "--export-finite-markov" {
        guard args.count >= 5 else {
            print("Usage: Qnet --export-finite-markov <bnet> <ctmc|decomp-loss|decomp-bas|decomp-bas-extloss> <output.json>")
            exit(1)
        }
        let doc = loadDoc(args[2])
        let editor = NetworkEditorModel()
        editor.nodes = doc.nodes
        editor.links = doc.links
        editor.infiniteBuffers = doc.infiniteBuffers
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        let result: Result<String, FiniteMarkovExportError>
        switch args[3] {
        case "ctmc":
            result = FiniteMarkovExporter.genericCTMC(editor: editor, name: name)
        case "decomp-loss":
            result = FiniteMarkovExporter.decomposition(
                editor: editor, name: name, blocking: "loss"
            )
        case "decomp-bas":
            result = FiniteMarkovExporter.decomposition(
                editor: editor, name: name, blocking: "bas"
            )
        case "decomp-bas-extloss":
            result = FiniteMarkovExporter.decomposition(
                editor: editor, name: name, blocking: "bas_external_loss"
            )
        default:
            print("ERROR: unknown finite Markov format '\(args[3])'")
            exit(1)
        }
        switch result {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[4]),
                    atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[4])")
                exit(0)
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    if args[1] == "--export-truncated-ctmc" {
        guard args.count >= 4 else {
            print("Usage: Qnet --export-truncated-ctmc <bnet> <output.json>")
            exit(1)
        }
        let doc = loadDoc(args[2])
        let editor = NetworkEditorModel()
        editor.nodes = doc.nodes
        editor.links = doc.links
        editor.infiniteBuffers = doc.infiniteBuffers
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        switch FiniteMarkovExporter.truncatedInfiniteCTMC(editor: editor, name: name) {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[3]),
                    atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[3])")
                exit(0)
            } catch {
                print("ERROR: could not write \(args[3]): \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    if args[1] == "--export-srbm-json" {
        guard args.count >= 5 else {
            print("Usage: Qnet --export-srbm-json <bnet> <adaptive-bar|bar-bounds> <output.json>")
            exit(1)
        }
        let doc = loadDoc(args[2])
        guard doc.infiniteBuffers else {
            print("ERROR: adaptive BAR and BAR bounds use the infinite-buffer orthant SRBM; switch the document to infinite buffers first")
            exit(1)
        }
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        let result: Result<String, BNASRBMExportError>
        switch args[3] {
        case "adaptive-bar":
            result = BNASRBMExporter.exportForAdaptiveBAR(
                nodes: doc.nodes, links: doc.links, name: name
            )
        case "bar-bounds":
            result = BNASRBMExporter.exportForBARBounds(
                nodes: doc.nodes, links: doc.links, name: name
            )
        default:
            print("ERROR: unknown SRBM JSON format '\(args[3])'")
            exit(1)
        }
        switch result {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[4]), atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[4])")
                exit(0)
            } catch {
                print("ERROR: could not write \(args[4]): \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    if args[1] == "--export-regenerative" {
        guard args.count >= 4 else {
            print("Usage: Qnet --export-regenerative <bnet> <output.json> [base-seed] [stream]")
            exit(1)
        }
        let doc = loadDoc(args[2])
        let editor = NetworkEditorModel()
        editor.nodes = doc.nodes
        editor.links = doc.links
        editor.infiniteBuffers = doc.infiniteBuffers
        let seed = args.count > 4 ? UInt64(args[4]) : nil
        let stream = args.count > 5 ? UInt64(args[5]) : nil
        guard args.count <= 4 || seed != nil,
              args.count <= 5 || stream != nil else {
            print("ERROR: base-seed and stream must be unsigned 64-bit integers")
            exit(1)
        }
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        switch RegenerativeExporter.export(
            editor: editor,
            name: name,
            baseSeed: seed ?? 20_260_904,
            stream: stream ?? 0
        ) {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[3]), atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[3])")
                exit(0)
            } catch {
                print("ERROR: could not write \(args[3]): \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    if args[1] == "--export-product-form" {
        guard args.count == 4 else {
            print("Usage: Qnet --export-product-form <bnet> <output.json>")
            exit(1)
        }
        let doc = loadDoc(args[2])
        let editor = NetworkEditorModel()
        editor.nodes = doc.nodes
        editor.links = doc.links
        editor.infiniteBuffers = doc.infiniteBuffers
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        switch ProductFormExporter.export(editor: editor, name: name) {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[3]), atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[3])")
                exit(0)
            } catch {
                print("ERROR: could not write \(args[3]): \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    if args[1] == "--export-qbd" {
        guard args.count == 4 else {
            print("Usage: Qnet --export-qbd <bnet> <output.json>")
            exit(1)
        }
        let doc = loadDoc(args[2])
        let editor = NetworkEditorModel()
        editor.nodes = doc.nodes
        editor.links = doc.links
        editor.infiniteBuffers = doc.infiniteBuffers
        let name = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
        switch QBDExporter.export(editor: editor, name: name) {
        case .success(let text):
            do {
                try text.write(
                    to: URL(fileURLWithPath: args[3]), atomically: true,
                    encoding: .utf8
                )
                print("wrote \(args[3])")
                exit(0)
            } catch {
                print("ERROR: could not write \(args[3]): \(error.localizedDescription)")
                exit(1)
            }
        case .failure(let error):
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    return false
}

@main
struct QnetGUIApp: App {
    @NSApplicationDelegateAdaptor(QnetGUIApplicationDelegate.self) private var appDelegate
    @State private var tabs: [NetworkTab]
    @State private var activeTabID: UUID
    @StateObject private var terminalModel = TerminalModel()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var tabPersistence = TabPersistence()
    @StateObject private var aiModel = AIModel()
    @StateObject private var toolRegistry = ToolRegistry()
    @StateObject private var startupDependencyChecker = StartupDependencyChecker()
    /// Menu-bar state that is not on the editor: text-field focus (for
    /// Cut/Copy enablement) and the Open Recent list.
    @StateObject private var menuContext = MenuContext()
    /// The tabs closed this session, for Window ▸ Reopen Closed Tab (⇧⌘T).
    @StateObject private var closedTabs = ClosedTabHistory()

    // Sheets driven from the menu bar.
    ///
    /// Shown at launch ONLY when running from the source tree. A packaged
    /// application carries its native libraries inside `Contents/Frameworks`
    /// with their load paths rewritten, so there is nothing about them for a
    /// user to fix and nothing for this sheet to tell them: `build_app.sh`
    /// already relocates and ad-hoc signs them, `validation/solver_bundle_audit.sh`
    /// refuses to finish a release whose inventory is incomplete, and
    /// `make_pkg.sh` re-verifies the payload before it ships. Interrogating
    /// Homebrew on someone else's Mac at every launch asks a question whose
    /// answer cannot matter, and blocks the menu bar behind a modal sheet
    /// while it does (`appSheetPresented`, below, includes this flag).
    ///
    /// A developer running `swift run` is the opposite case: the solvers are
    /// loose binaries linked against the local Homebrew cellar, so a missing
    /// formula is exactly what they need told.
    ///
    /// The check itself is unchanged and still reachable on demand from
    /// Help ▸ Check Dependencies…, which is also how a packaged user
    /// diagnoses a Python-backed method that will not run — Python stays an
    /// external prerequisite in both builds.
    @State private var showStartupDependencyCheck = !StartupDependencyCatalog.isPackagedApplication
    @State private var showGenerateRandomSheet = false
    @State private var showArchetypeSheet = false
    @State private var showFindNodeSheet = false

    // The one run-parameter sheet (Run ▸ …, File ▸ Export ▸ All Solver
    // Inputs). Set by `presentRunParameters`; non-nil while a solver is
    // asking for its parameters. See RunParameterSheet.swift.
    @State private var runParameterRequest: RunParameterRequest?

    // Test-set runner state — sheet presentation + parameters.
    @State private var showTestSetSheet = false
    @State private var testSetIsInfinite = true
    @State private var testSetParams = TestSetParameters()
    @State private var testSetRunning = false

    // Spectral-convergence runner state — separate sheet because the
    // ρ row collects start/finish/step instead of a min/max range.
    @State private var showSpectralConvergenceSheet = false
    @State private var spectralConvergenceParams = SpectralConvergenceParameters()

    @MainActor init() {
        _ = handleCLIIfNeeded()

        // Qnet has its own document tabs; native window tabbing would add
        // "Show Next Tab" etc. to the Window menu with the same ⌃⇥ keys
        // our tab commands use, and let ⌘T merge the About / Help windows
        // into the canvas window.
        NSWindow.allowsAutomaticWindowTabbing = false

        // One-time migration: earlier builds had a bug where the bottom
        // HSplit's SplitViewConfigurator attached to the outer VSplit, so
        // `SplitSizes.BottomHSplit` holds garbage (the VSplit's heights
        // instead of the bottom HSplit's widths). Clear it once so the new
        // configurator starts fresh.
        let migrationKey = "migration.bottomHSplit.2026-04-24"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.removeObject(forKey: "SplitSizes.BottomHSplit")
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        // Restore priority:
        //   1. Full state snapshot written by TabPersistence (positions,
        //      zoom, infinite-buffers — everything).
        //   2. Legacy `tabs.currentURLs` list pointing at saved .bnet
        //      files (older versions of the app only stored the file
        //      URLs, so state added in the session was lost).
        //   3. A single empty "Untitled" tab.
        var restoredTabs: [NetworkTab] = []
        var activeID: UUID?

        if let snapshot = TabPersistence.restore(), !snapshot.entries.isEmpty {
            for entry in snapshot.entries {
                let tab = NetworkTab(id: entry.id, title: entry.title)
                tab.editor.loadNetwork(document: entry.document)
                if let urlStr = entry.userFileURL, let url = URL(string: urlStr) {
                    tab.editor.currentFileURL = url
                }
                // Restore the Status pane scrollback. `loadNetwork`
                // above seeded it with the default greeting + a "Loaded
                // network with N nodes" line; replace those with the
                // saved history and append a session-boundary marker so
                // the user can clearly see what's old and what's new.
                let savedLog: [StatusEntry] = entry.statusLog
                    ?? entry.statusMessages?.map { StatusEntry(legacy: $0) }
                    ?? []
                if !savedLog.isEmpty {
                    let now = DateFormatter.localizedString(
                        from: Date(),
                        dateStyle: .short,
                        timeStyle: .short
                    )
                    tab.editor.statusMessages = savedLog
                        + [StatusEntry(text: "──── New session — \(now) ────")]
                }
                tab.editor.markDocumentClean()
                restoredTabs.append(tab)
            }
            activeID = snapshot.activeTabID
                ?? restoredTabs.first?.id
        } else {
            let savedURLStrings = UserDefaults.standard.stringArray(forKey: "tabs.currentURLs") ?? []
            for urlString in savedURLStrings {
                guard let url = URL(string: urlString),
                      let data = try? Data(contentsOf: url),
                      let document = try? JSONDecoder().decode(NetworkDocument.self, from: data) else {
                    continue
                }
                let tab = NetworkTab(title: url.lastPathComponent)
                tab.editor.loadNetwork(document: document)
                tab.editor.currentFileURL = url
                restoredTabs.append(tab)
            }
        }

        if restoredTabs.isEmpty {
            let firstTab = NetworkTab()
            _tabs = State(initialValue: [firstTab])
            _activeTabID = State(initialValue: firstTab.id)
        } else {
            _tabs = State(initialValue: restoredTabs)
            _activeTabID = State(initialValue: activeID ?? restoredTabs[0].id)
        }
    }

    private var activeEditor: NetworkEditorModel {
        tabs.first(where: { $0.id == activeTabID })?.editor ?? tabs[0].editor
    }

    private var activeTab: NetworkTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    /// Points the AI pane at the active tab's conversation and network
    /// name. Called on tab switch, tab add / close, and whenever a tab is
    /// renamed by Save As / Open.
    private func bindAIConversation() {
        aiModel.bind(tabID: activeTabID, title: activeTab?.title ?? "Untitled")
    }

    /// Workspace menu commands (View ▸ Panes, Window ▸ tabs / focus).
    private var workspaceCommands: some Commands {
        WorkspaceCommands(
            tabs: $tabs,
            activeTabID: $activeTabID,
            appSettings: appSettings,
            terminal: terminalModel,
            menuContext: menuContext,
            closedTabs: closedTabs
        )
    }

    /// What the tab bar calls to close tabs: one closure onto the guarded
    /// owner below, so the close button, middle-click and the context
    /// menu ask to save exactly as ⌘W does.
    private var tabActions: TabActions {
        TabActions(close: { ids in closeTabs(ids: ids) })
    }

    /// The scene's dialog layer, split off from `mainContent` for one
    /// unglamorous reason: `mainContent` is a single expression and the
    /// Swift type-checker's budget for one expression is finite. The full
    /// chain — every sheet, every `.task`, every `.onChange` — went over
    /// it the moment the archetype gallery became a panel (an `.onChange`
    /// closure joins the parent expression's constraint system, where a
    /// `@ViewBuilder` sheet closure was type-checked on its own). Split
    /// here, at the boundary between "present the dialogs" and "wire the
    /// scene up", so each half is well inside the budget.
    private var mainContentDialogs: some View {
            ContentView(tabs: $tabs, activeTabID: $activeTabID, tabActions: tabActions)
                .environmentObject(activeEditor)
                .environmentObject(terminalModel)
                .environmentObject(appSettings)
                .environmentObject(aiModel)
                // Every launch performs a visible, sequential dependency
                // check.  The checker only observes the machine: installs
                // remain an explicit Terminal action chosen by the user.
                .sheet(isPresented: $showStartupDependencyCheck) {
                    StartupDependencyCheckView(
                        checker: startupDependencyChecker,
                        onContinue: { showStartupDependencyCheck = false }
                    )
                }
                // Test-set parameter form — collects (ρ range, stations
                // range, classes range, # cases) then kicks off the batch
                // sweep. A movable PANEL rather than a sheet: the sweep it
                // is about is reported into the Shell and the Status pane,
                // and a sheet covers both while you set it up. The `@State`
                // flag stays the single switch — the panel is only the
                // presentation — so every menu item, `appSheetPresented`
                // and the run guards are unchanged. Body in
                // `syncTestSetPanel(presented:)`, not inline, for the
                // type-checker reason recorded above `mainContentDialogs`.
                .onChange(of: showTestSetSheet) { _, presented in
                    syncTestSetPanel(presented: presented)
                }
                // Spectral-convergence form — same layout as the test-set
                // form except ρ is start/finish/step instead of a min/max
                // range. Each case generates one network and runs Spectral
                // / QNA / Sim across the swept ρ values. A panel, for the
                // same reason the test set is one.
                .onChange(of: showSpectralConvergenceSheet) { _, presented in
                    syncSpectralConvergencePanel(presented: presented)
                }
                // Generate Random Network — grouped form replacing the old
                // NSAlert accessory view. Everything after the dialog
                // (clamping, tab creation, status lines) is unchanged in
                // `createRandomNetworkTab(params:)`.
                // Archetype gallery — builds one of the five starting
                // networks (tandem, M/M/c, fork, rework loop, re-entrant
                // pair) at a chosen size and ρ and inserts it into the
                // CURRENT canvas as ONE undoable step. The insert itself
                // is `NetworkEditorModel.insertSubnetwork`, which owns
                // naming, id remapping and the undo entry; this closure
                // only builds and hands over.
                // …and it is a movable PANEL, not a sheet: the form's own
                // footer promises the archetype lands clear to the right of
                // what is already on the canvas, which is a promise the user
                // cannot check while a sheet covers the canvas.
                // `showArchetypeSheet` stays the single switch — the flag is
                // still the state, the panel is only the presentation — so
                // `insertArchetype()`, `appSheetPresented` and both menu
                // items are unchanged.
                // The body of this is `syncArchetypePanel(presented:)` below,
                // not an inline closure: `mainContent` is one expression and
                // the Swift type-checker's budget for it is finite — an
                // inline multi-argument call with two trailing closures here
                // pushed the whole property over it.
                .onChange(of: showArchetypeSheet) { _, presented in
                    syncArchetypePanel(presented: presented)
                }
                .onChange(of: showGenerateRandomSheet) { _, presented in
                    syncGenerateRandomPanel(presented: presented)
                }
                // Run-parameter forms (Monte Carlo, Spectral, Finite
                // Element, Multi-Class SRBM, Linear Program, Run
                // Comparison, Export All Solver Inputs). One form type
                // drives all of them; the run logic lives in the closure
                // each caller hands to `presentRunParameters`. A panel, so
                // the network the parameters are for stays visible while
                // they are chosen. Observed by `id` because
                // `RunParameterRequest` is Identifiable, not Equatable —
                // and one id per presentation is exactly the granularity
                // `.onChange` needs.
                .onChange(of: runParameterRequest?.id) { _, _ in
                    syncRunParameterPanel()
                }
                // Find Node — live-filtering search field, and the
                // strongest case of the five for being a panel: the dialog
                // was covering the canvas it is searching.
                .onChange(of: showFindNodeSheet) { _, presented in
                    syncFindNodePanel(presented: presented)
                }
    }

    /// The main window's content with all of its scene-level wiring.
    /// Kept out of `body` so the scene expression stays within the
    /// type-checker's budget, and built on `mainContentDialogs` so that
    /// this half stays within it too.
    private var mainContent: some View {
        mainContentDialogs
                // Tell the menu bar when one of this scene's sheets is up so
                // canvas key equivalents (tool letters, ⌫) stay disabled
                // underneath it — the editor-owned sheets are visible to
                // QnetCommands, these are not.
                .onChange(of: appSheetPresented, initial: true) { _, presented in
                    menuContext.appSheetPresented = presented
                }
                // Same mirror for the editor-owned sheets, so the command
                // groups that do not observe the editor (WorkspaceCommands)
                // can also refuse to act underneath one.
                .onChange(of: activeEditor.isModalSheetPresented, initial: true) { _, presented in
                    menuContext.editorSheetPresented = presented
                }
                // ⌃` keeps focusing the Shell now that the menu item shows
                // ⌃⌘3; see MenuKeyAliases for why this needs a monitor.
                .task {
                    MenuKeyAliases.install {
                        WorkspaceCommands.focusShell(appSettings: appSettings)
                    }
                }
                // Remember which NSWindow hosts the canvas so ⌘W can tell
                // "close this tab" from "close the About window".
                .background(MainWindowTagger())
                // Shortcut-collision audit. In DEBUG it runs once after the
                // menu bar is built and asserts on duplicates; with
                // QNET_MENU_AUDIT=1 it prints the full map and exits so the
                // smoke test can gate on it.
                .task {
                    let forced = ProcessInfo.processInfo.environment["QNET_MENU_AUDIT"] == "1"
                    #if !DEBUG
                    guard forced else { return }
                    #endif
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    MenuShortcutAudit.runAndReport(verbose: forced)
                }
                // Wire the AI model to the live AppSettings so each send uses
                // the user's current provider / key / model. Also install
                // the default tool catalog so the model can inspect the
                // active network and run menu commands via natural language.
                .task {
                    aiModel.configProvider = { [appSettings] in
                        appSettings.currentAIConfig()
                    }
                    aiModel.toolRegistry = toolRegistry
                    registerDefaultAITools()
                }
                // Dispatch tool-invoked menu commands. The `run_command`
                // tool posts this notification; we route it to the same
                // handlers the menu bar uses. Guarded so a given
                // notification only fires once per action.
                .onReceive(
                    NotificationCenter.default.publisher(for: .bnetExecuteCommand)
                ) { notification in
                    guard
                        let raw = notification.userInfo?["command"] as? String,
                        let cmd = AICommand(rawValue: raw)
                    else { return }
                    dispatch(aiCommand: cmd)
                }
                // Silently analyze a preloaded tab the first time it's
                // activated (includes the initial tab on launch). Warning
                // banner is set if needed; no terminal output.
                .task {
                    // Tools-menu letter shortcuts must never reach text
                    // fields / the shell, even with the Palette pane hidden.
                    ToolShortcutGuard.installIfNeeded()
                    analyzeActiveTabIfNeeded()
                }
                // Parameter edits (inspector Save, context menus, undo)
                // invalidate the silent analysis; re-run it quietly so the
                // flag bar reflects the new service rates / routing.
                .onReceive(
                    // Coalesce bursts: once the STRUCTURAL mutations post this
                    // too (W2-06), a fast sequence of edits — dragging out a
                    // chain of links, deleting a multi-selection — would
                    // otherwise re-run SRBMExporter.computeData once per step.
                    // 150 ms is the same window the utilisation badges already
                    // settle on (NetworkEditorModel.init, lines 21–26), so the
                    // two silent recomputes stay in step.
                    NotificationCenter.default.publisher(for: .bnetNetworkParametersDidChange)
                        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
                ) { notification in
                    guard let changed = notification.object as? NetworkEditorModel,
                          changed === activeEditor else { return }
                    analyzeActiveTabIfNeeded(quiet: true)
                }
                // Snapshot the Interactive Shell scrollback every 10 s.
                // Backstop for crash / force-quit / SIGKILL where
                // applicationShouldTerminate doesn't run; on a clean
                // ⌘Q the unconditional save in
                // applicationShouldTerminate captures the latest state.
                // 10 s is short enough that worst-case loss is minor
                // and long enough that the writes don't show up as
                // overhead in any practical workload.
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        terminalModel.saveTranscript()
                    }
                }
                .onChange(of: activeTabID) { _, _ in
                    analyzeActiveTabIfNeeded()
                }
                // Settings quotes grid / mesh recommendations for the front
                // network; AppSettings follows the active editor's nodes.
                // The AI pane follows it too: each tab keeps its own
                // conversation (AIModel stores one transcript per tab id),
                // so binding the active tab swaps the visible transcript
                // and names the network in the AI pane's header.
                .onChange(of: activeTabID, initial: true) { _, _ in
                    appSettings.trackActiveEditor(activeEditor)
                    bindAIConversation()
                }
                // Keep the terminal's font settings in sync with AppSettings.
                // Settings ▸ Model: applies changes from SettingsView.
                // Model → Settings: persists A+/A- and font-picker choices.
                .task {
                    terminalModel.setFontSize(CGFloat(appSettings.shellFontSize))
                    terminalModel.setFontName(appSettings.shellFontName)
                }
                .onChange(of: appSettings.shellFontSize) { _, newValue in
                    terminalModel.setFontSize(CGFloat(newValue))
                }
                .onChange(of: appSettings.shellFontName) { _, newValue in
                    terminalModel.setFontName(newValue)
                }
                .onChange(of: terminalModel.fontSize) { _, newValue in
                    if abs(appSettings.shellFontSize - Double(newValue)) > 0.001 {
                        appSettings.shellFontSize = Double(newValue)
                    }
                }
                .onChange(of: terminalModel.fontName) { _, newValue in
                    if appSettings.shellFontName != newValue {
                        appSettings.shellFontName = newValue
                    }
                }
                // Close the structured result that was registered at launch.
                // The UUID prevents a late completion from being attached to
                // whichever network tab is currently visible.
                .onChange(of: terminalModel.lastRunSummary) { _, summary in
                    guard let summary else { return }
                    finalizeStructuredResult(summary)
                }
                // Auto-save tab state on every change in any tab.
                // TabPersistenceObserver is an invisible helper view that
                // fires when its editor's nodes / links / zoom / infinite-
                // buffers flag change; it covers every tab, not just the
                // active one.  Saves are debounced inside TabPersistence.
                .background {
                    ForEach(tabs) { tab in
                        TabPersistenceObserver(editor: tab.editor) {
                            tabPersistence.scheduleSave(tabs: tabs, activeID: activeTabID)
                        }
                    }
                }
                // Save once when the list of tabs or the active tab changes
                // (add / remove / switch / import).  These transitions
                // aren't always caught by the per-editor observer above.
                .onChange(of: tabs.map(\.id))   { _, ids in
                    tabPersistence.scheduleSave(tabs: tabs, activeID: activeTabID)
                    // A closed tab's AI conversation goes with it.
                    aiModel.pruneConversations(keeping: Set(ids))
                    bindAIConversation()
                }
                .onChange(of: activeTabID) { _, _ in
                    tabPersistence.scheduleSave(tabs: tabs, activeID: activeTabID)
                }
                // The Settings > Linear Program pane posts this notification
                // when the user clicks "Performance Hints".  Route it to the
                // existing terminal-printing helper.
                .onReceive(
                    NotificationCenter.default.publisher(for: .bnetPrintToTerminal)
                ) { notification in
                    guard
                        let text  = notification.userInfo?["text"]  as? String,
                        let label = notification.userInfo?["label"] as? String
                    else { return }
                    printHelpToTerminal(text, label: label)
                }
                // Install the static handlers the AppDelegate calls from
                // `applicationShouldTerminate`.  These run on the main
                // actor, so they can safely read @State `tabs`.
                .task {
                    QnetGUIApplicationDelegate.saveTabsForRestore = {
                        tabPersistence.saveImmediately(tabs: tabs, activeID: activeTabID)
                        // Status pane scrollback rides along inside
                        // PersistedTabState.Entry. Shell transcript is
                        // saved unconditionally by saveShellTranscript
                        // (also wired below) — calling it here is
                        // redundant but harmless; the unconditional
                        // path runs first in applicationShouldTerminate.
                    }
                    QnetGUIApplicationDelegate.clearTabsForRestore = {
                        tabPersistence.cancelPendingSave()
                        TabPersistence.clearPersistence()
                        // Also remove the legacy URL list so older
                        // launch paths don't resurrect anything.
                        UserDefaults.standard.removeObject(forKey: "tabs.currentURLs")
                        // NOTE: shell transcript is intentionally NOT
                        // cleared here. "Don't Restore" in the dialog
                        // refers to *tabs*; clearing shell history was
                        // a hidden side effect that surprised users
                        // who hadn't explicitly asked for it.
                    }
                    QnetGUIApplicationDelegate.saveShellTranscript = {
                        terminalModel.saveTranscript()
                    }
                    QnetGUIApplicationDelegate.hasRestorableContent = {
                        tabs.contains {
                            !$0.editor.nodes.isEmpty || !$0.editor.links.isEmpty
                        }
                    }
                }
    }

    /// Mirrors `showArchetypeSheet` onto the archetype gallery PANEL.
    ///
    /// The flag stays the single switch every menu item and shortcut writes
    /// (`insertArchetype()`, `appSheetPresented`, File ▸ New from Archetype…
    /// and Network ▸ Insert Archetype…); this is only the presentation.
    /// `onDismiss` is the one teardown path — Cancel, Insert, the title-bar
    /// button, ⌘W, Escape and Quit all reach it — so the flag is cleared
    /// exactly once and cannot stick, which is what would otherwise disable
    /// the canvas tool letters and ⌫ until relaunch.
    @MainActor
    private func syncArchetypePanel(presented: Bool) {
        ArchetypeGalleryPanel.sync(
            presented: presented,
            canvasNodeCount: activeEditor.nodes.count,
            canvasSourceCount: activeEditor.nodes.filter { $0.kind == .source }.count,
            // The Buffers control opens on the DOCUMENT's regime: an insert
            // never re-interprets the stations already on the canvas, so a
            // finite-buffer document must not be offered a form reading
            // "Infinite" and a choice that will be refused.
            //
            // The empty canvas is the one case where the choice is not the
            // document's yet — `insertSubnetwork` adopts whatever the sheet
            // says — and NetworkEditorModel's document default is `false`. So
            // "Start from an Archetype…", the primary call to action on the
            // empty canvas, used to hand back a network with finite buffers
            // and all twelve infinite-buffer methods (QNA, RQNA, SBD, exact
            // product form, matrix-analytic QBD, …) greyed out for a reason
            // nothing on screen explains — while the archetype library's own
            // blurbs promise the exact Jackson branch. On an empty canvas the
            // control therefore opens on Infinite, which is the regime the
            // archetypes are written around; a document that already holds
            // stations keeps its own regime, as before.
            initialInfiniteBuffers: activeEditor.nodes.isEmpty
                ? true : activeEditor.infiniteBuffers,
            onInsert: { archetype, parameters in
                let built = NetworkArchetypeBuilder.build(archetype, parameters)
                activeEditor.insertSubnetwork(
                    nodes: built.nodes,
                    links: built.links,
                    infiniteBuffers: built.infiniteBuffers,
                    at: NetworkArchetypeBuilder.canvasOrigin,
                    actionName: "Insert " + NetworkArchetypeBuilder.blueprint(for: archetype).title,
                    detail: NetworkArchetypeBuilder.summary(archetype, parameters)
                )
            },
            onDismiss: { showArchetypeSheet = false }
        )
    }

    // MARK: - The dialog panels
    //
    // Five forms that used to be `.sheet`s and are now movable, resizable
    // panels.  Each follows the shape the archetype gallery above proved:
    //
    //   * the `@State` flag stays the single switch, so every menu item,
    //     shortcut and `appSheetPresented` reading is unchanged — only the
    //     presentation moved;
    //   * `onClose:` is the ONE teardown path (footer Cancel, title-bar
    //     button, ⌘W, Escape, Quit all arrive there), so the flag is
    //     cleared exactly once and cannot stick.  A stuck flag disables the
    //     canvas tool letters and ⌫ until relaunch — the bug the comment in
    //     `presentRunParameters` records;
    //   * `DSPanelWindow.close(id:)` deliberately does NOT run `onClose`,
    //     so the re-entrant path (`ref.close()` → `onClose` → flag = false
    //     → this function again → `close(id:)`) terminates in a no-op;
    //   * `.documentModal`, which is the modality the sheets already had:
    //     the form belongs to the window it acts on, travels with it and
    //     stays above it, and the bare canvas tool letters do not fire
    //     underneath a form full of number fields;
    //   * `escapeCloses: false`, because every one of these bodies is a
    //     `DSSheet` whose `DSSheetFooter` already binds Cancel to Escape.
    //
    // Each panel's title is verbatim its form's own `DSSheetHeader` title,
    // so a window is never named one thing and headed another.

    private func syncTestSetPanel(presented: Bool) {
        guard presented else {
            DSPanelWindow.close(id: "test-set")
            return
        }
        let infinite = testSetIsInfinite
        DSPanelWindow.present(
            id: "test-set",
            title: "Run \(infinite ? "Infinite" : "Finite") Test Set",
            size: .regular,
            modality: .documentModal,
            escapeCloses: false,
            onClose: { showTestSetSheet = false }
        ) { ref in
            TestSetParameterSheet(
                params: $testSetParams,
                infinite: infinite,
                onCancel: { ref.close() },
                onRun: { p in
                    // Ordering is load-bearing: the sweep drives the shell,
                    // so the panel must be on its way out before it starts.
                    testSetParams = p
                    ref.close()
                    Task.detached(priority: .userInitiated) { [self, p, infinite] in
                        await executeTestSet(params: p, infinite: infinite)
                    }
                }
            )
        }
    }

    private func syncSpectralConvergencePanel(presented: Bool) {
        guard presented else {
            DSPanelWindow.close(id: "spectral-convergence")
            return
        }
        DSPanelWindow.present(
            id: "spectral-convergence",
            title: "Run Infinite Spectral Convergence",
            size: .tall,
            modality: .documentModal,
            escapeCloses: false,
            onClose: { showSpectralConvergenceSheet = false }
        ) { ref in
            SpectralConvergenceParameterSheet(
                params: $spectralConvergenceParams,
                onCancel: { ref.close() },
                onRun: { p in
                    spectralConvergenceParams = p
                    ref.close()
                    Task.detached(priority: .userInitiated) { [self, p] in
                        await executeSpectralConvergence(params: p)
                    }
                }
            )
        }
    }

    private func syncGenerateRandomPanel(presented: Bool) {
        guard presented else {
            DSPanelWindow.close(id: "generate-random")
            return
        }
        DSPanelWindow.present(
            id: "generate-random",
            title: "Generate Random Network",
            size: .regular,
            modality: .documentModal,
            escapeCloses: false,
            onClose: { showGenerateRandomSheet = false }
        ) { ref in
            GenerateRandomNetworkSheet(
                onCancel: { ref.close() },
                onGenerate: { params in
                    // Close FIRST: `createRandomNetworkTab` makes a tab and
                    // hands it key status, which it must take from a window
                    // that is already gone rather than from this one.
                    ref.close()
                    createRandomNetworkTab(params: params)
                }
            )
        }
    }

    /// The run-parameter panel, driven by `runParameterRequest` rather than
    /// by a Bool: the request IS the state, and nilling it is how both Run
    /// and Cancel already finish.
    ///
    /// `onClose` routes through `request.onCancel` rather than around it,
    /// because that closure is what nils the request and writes the
    /// caller's "cancelled" status line; closing the window by any other
    /// means must mean exactly what pressing Cancel means. Run and Cancel
    /// both nil the request themselves, which brings us back here with the
    /// request gone and takes the `close(id:)` branch — where `onClose`
    /// does not run, so the cancel closure cannot fire after a Run.
    private func syncRunParameterPanel() {
        guard let request = runParameterRequest else {
            DSPanelWindow.close(id: "run-parameters")
            return
        }
        DSPanelWindow.present(
            id: "run-parameters",
            title: request.spec.title,
            // The spec's own band, the same one the sheet body applies with
            // `.dsSheetFrame(spec.size)`; a Run Comparison form and a Monte
            // Carlo form are not the same height.
            size: request.spec.size,
            modality: .documentModal,
            escapeCloses: false,
            onClose: { request.onCancel() }
        ) { _ in
            RunParameterSheet(request: request)
        }
    }

    private func syncFindNodePanel(presented: Bool) {
        guard presented else {
            DSPanelWindow.close(id: "find-node")
            return
        }
        DSPanelWindow.present(
            id: "find-node",
            title: "Find Node",
            size: .compact,
            modality: .documentModal,
            escapeCloses: false,
            onClose: { showFindNodeSheet = false }
        ) { ref in
            // `FindNodePanelBody`, not `FindNodeSheet`: a panel's root is
            // built once and the canvas underneath it stays editable, so
            // the node list has to be observed rather than copied.
            FindNodePanelBody(
                editor: activeEditor,
                onCancel: { ref.close() },
                onFind: { query in
                    ref.close()
                    _ = activeEditor.findAndRevealNode(named: query)
                }
            )
        }
    }

    var body: some Scene {
        WindowGroup("Qnet") {
            mainContent
        }
        .defaultSize(width: 1500, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            QnetCommands(
                editor: activeEditor,
                appSettings: appSettings,
                menuContext: menuContext,
                terminal: terminalModel,
                testSetRunning: testSetRunning,
                actions: commandActions
            )

            // ── Workspace: View ▸ Panes, Window ▸ tabs / focus, Shell ──
            workspaceCommands
        }

        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }
        // SettingsView declares a minWidth/minHeight and an ideal size
        // (DS.Layout.Window.settings*); without this the scene's
        // resizability is whatever SwiftUI infers, and the window can be
        // dragged below the size its own split view needs.
        .windowResizability(.contentMinSize)
    }

    // MARK: - Menu-bar actions

    /// Closures handed to `QnetCommands`. The menu bar owns enablement;
    /// these just call the existing handlers.
    private var commandActions: QnetCommandActions {
        QnetCommandActions(
            newNetwork: { newNetwork() },
            openNetwork: { loadNetwork() },
            openExample: { loadExample() },
            openRecent: { url in loadNetworkFile(at: url) },
            closeTab: { closeTabOrKeyWindow() },
            closeAllTabs: { closeAllTabs() },
            closeWindow: { closeKeyWindow() },
            save: { saveNetwork() },
            saveAs: { saveNetworkAs() },
            exportFiniteSimulatorInput: { exportNetwork() },
            exportSRBMSolverInput: { activeEditor.showSRBMExportSheet = true },
            exportQNAInput: { exportQNA() },
            exportAllSolverInputs: { exportAllSolverInputs() },
            // Routed: searches the Shell scrollback when the shell is
            // first responder, else finds a node.
            // Routing by front window (Help / Settings / Status) happens in
            // QnetCommands.performFind — Settings has its own ⌘F route there,
            // which posts .bnetSettingsFocusSearch — so this closure is only
            // ever reached for the canvas and the Shell in the main window.
            findNode: { FocusRouter.shared.find { showFindNodePrompt() } },
            clearCanvas: { clearCanvasWithConfirmation() },
            // The one Clear Status Log: same code path as the Status
            // pane's trash button and the log's context menu, so all three
            // ask the same question above the same threshold and share the
            // same undo backlog and empty state.
            clearStatusLog: { activeEditor.clearStatusLog() },
            analyzeNetwork: { analyzeNetwork() },
            showNetworkPrimitives: { showNetworkPrimitives() },
            generateRandomNetwork: { generateRandomNetwork() },
            checkDependencies: { showStartupDependencyCheck = true },
            insertArchetype: { insertArchetype() },
            runComparison: {
                if activeEditor.infiniteBuffers { runComparisonInfinite() } else { runComparison() }
            },
            runMonteCarloInfinite: { runSimulationInfinite() },
            runOpenProductForm: { runOpenProductForm() },
            runQBD: { runQBD() },
            runSpectralInfinite: { runSpectralMethodInfinite() },
            runQNA: { runQNA() },
            runRQNA: { runRQNA() },
            runSBD: { runSBD() },
            runExactSimulation: { runExactSim() },
            runLinearProgram: { runLinearProgram() },
            runMonteCarloFinite: { runSimulation() },
            runSpectralFinite: { runSpectralMethod() },
            runFiniteElement: { runFiniteElement() },
            runFiniteLP: { runFiniteLP() },
            runGenericCTMC: { runGenericCTMC() },
            runFiniteDecomposition: { runFiniteDecomposition() },
            runTruncatedCTMC: { runTruncatedCTMC() },
            runAdaptiveLowRankBAR: { runAdaptiveLowRankBAR() },
            runBARMomentBounds: { runBARMomentBounds() },
            runRegenerativeMonteCarlo: { runRegenerativeMonteCarlo() },
            runMultiClassSRBM: { runMultiClassSRBM() },
            runInfiniteTestSet: {
                testSetIsInfinite = true
                testSetParams = loadTestSetDefaults(infinite: true)
                showTestSetSheet = true
            },
            runFiniteTestSet: {
                testSetIsInfinite = false
                testSetParams = loadTestSetDefaults(infinite: false)
                showTestSetSheet = true
            },
            runSpectralConvergence: {
                spectralConvergenceParams = loadSpectralConvergenceDefaults()
                showSpectralConvergenceSheet = true
            },
            showHelpTopic: { topic in showHelp(topic: topic) }
        )
    }

    /// File ▸ Close Tab (⌘W). When an auxiliary window (About, Help,
    /// Release Notes, Settings…) is in front, ⌘W closes *that* window like
    /// every other Mac app; only when the canvas window is key does it
    /// close the active tab.
    private func closeTabOrKeyWindow() {
        if MainWindowRegistry.keyWindowIsMainContent() {
            closeTab(id: activeTabID)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// File ▸ Close Window (⇧⌘W).
    private func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }


    /// Edit ▸ Clear Canvas… — destructive, so it confirms first.
    private func clearCanvasWithConfirmation() {
        let editor = activeEditor
        guard !editor.nodes.isEmpty || !editor.links.isEmpty else { return }
        guard ConfirmAlert.destructive(
            title: "Clear the canvas?",
            message: "Every node and link in “\(activeTabTitle)” will be removed. This can be undone with Edit ▸ Undo.",
            confirmTitle: "Clear Canvas"
        ) else { return }
        editor.clear()
    }

    /// Title of the active tab, used for save-panel defaults and dialogs.
    private var activeTabTitle: String {
        tabs.first(where: { $0.id == activeTabID })?.title ?? "Untitled"
    }

    /// Document-derived base name (no extension) for export panels.
    private var exportBaseName: String {
        if let url = activeEditor.currentFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        let t = activeTabTitle
        return t.hasSuffix(".bnet") ? String(t.dropLast(5)) : t
    }

    /// Configures a save panel the same way for every exporter: the real
    /// extension, a name derived from the document, the document's folder
    /// and folder creation.
    private func configureExportPanel(_ panel: NSSavePanel, title: String, fileExtension: String) {
        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldStringValue = exportBaseName + "." + fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        if let dir = activeEditor.currentFileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
    }

    // MARK: - Save / Load

    private func newNetwork() {
        let tab = NetworkTab()
        tabs.append(tab)
        activeTabID = tab.id
        persistCurrentTabURLs()
    }

    /// Opens the Generate Random Network sheet (dimensions, classes, buffer
    /// type, topology, target ρ, seed). On Generate, `createRandomNetworkTab`
    /// builds a random multi-class network in a new tab named "Random N".
    private func generateRandomNetwork() {
        showGenerateRandomSheet = true
    }

    /// File ▸ New from Archetype… (⌥⌘N) and Network ▸ Insert Archetype… —
    /// opens the archetype gallery. Both items open the SAME sheet and the
    /// insert lands in the current canvas: on an empty canvas that is
    /// "new from a template", and on an occupied one the sheet says, in
    /// its own footer, that the archetype goes clear to the right of what
    /// is already there.
    private func insertArchetype() {
        // The panel is presented from `.onChange(of: showArchetypeSheet)`,
        // so writing `true` over a flag that is ALREADY true fires nothing.
        // That mattered once File ▸ New from Archetype… stopped being
        // `.disabled(sheetPresented)` (round-4 blocker R6): asking again
        // while the gallery is up must raise it, not do nothing, because the
        // gallery is a movable window the user is meant to work beside.
        if showArchetypeSheet {
            if DSPanelWindow.bringForward(id: ArchetypeGalleryPanel.panelID) { return }
            // The flag is standing with no panel behind it. That happens to a
            // scene whose request was answered by *another* window's panel:
            // `DSPanelWindow.present` brought that one forward instead, so
            // this scene never receives the `onClose` that clears its flag,
            // and `appSheetPresented` would stay true — killing this command
            // and every bare canvas tool letter for the rest of the session
            // (round-4 W1-INT-2). Present directly and let the panel's own
            // teardown clear the flag; `.onChange` cannot fire for a value
            // that is already true.
            syncArchetypePanel(presented: true)
            return
        }
        showArchetypeSheet = true
    }

    private func createRandomNetworkTab(params: RandomNetworkGenerator.Parameters) {
        let result = RandomNetworkGenerator.generate(params)

        // Count existing "Random N" tabs to pick the next number.
        let existingNumbers: [Int] = tabs.compactMap { tab in
            let t = tab.title
            guard t.hasPrefix("Random ") else { return nil }
            return Int(t.dropFirst("Random ".count))
        }
        let nextN = (existingNumbers.max() ?? 0) + 1

        let newTab = NetworkTab(title: "Random \(nextN)")
        newTab.editor.nodes = result.nodes
        newTab.editor.links = result.links
        newTab.editor.infiniteBuffers = result.infiniteBuffers
        newTab.editor.hasBeenAnalyzed = false

        tabs.append(newTab)
        activeTabID = newTab.id
        persistCurrentTabURLs()

        let topoLabel: String
        switch params.topology {
        case .feedForward:       topoLabel = "feed-forward"
        case .jacksonFeedback:   topoLabel = "Jackson feedback"
        case .generalPMatrix:    topoLabel = "general P-matrix"
        case .reentrantFeedback: topoLabel = "reentrant (class-change)"
        }
        newTab.editor.addStatus(
            "Generated Random \(nextN): d=\(params.stations), c=\(params.classes), "
            + (params.infiniteBuffers ? "infinite buffers, " : "finite buffers, ")
            + "target ρ=\(String(format: "%.2f", params.targetRho)), "
            + "topology=\(topoLabel)."
        )

        // Diagnostic: run SRBMExporter on the freshly-generated network and
        // print both ρ and any warnings that fire, so the user can see
        // exactly what's tripping the banner (if anything).
        switch SRBMExporter.computeData(
            nodes: result.nodes, links: result.links,
            infiniteBuffers: result.infiniteBuffers
        ) {
        case .success(let data):
            var rhoLine = "Qnet-computed ρ:"
            for i in 0..<data.d {
                let rho = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : Double.nan
                rhoLine += String(format: "  S%d=%.3f", i + 1, rho)
            }
            newTab.editor.addStatus(rhoLine)
            let warnings = networkWarnings(for: data, infiniteBuffers: result.infiniteBuffers)
            if warnings.isEmpty {
                newTab.editor.addStatus("No warnings — banner should stay hidden.")
            } else {
                newTab.editor.addStatus("Banner WILL fire — warnings: \(warnings.count)")
                for w in warnings {
                    newTab.editor.addStatus("  • \(w)")
                }
            }
        case .failure(let err):
            newTab.editor.addStatus("SRBMExporter failed on generated network: \(err.localizedDescription)", severity: .error)
        }
    }

    /// The one owner of "close these tabs". Every entry point — ⌘W, ⌥⌘W,
    /// the tab's close button, a middle-click and the tab context menu's
    /// three items — lands here, so the Save / Don't Save / Cancel guard
    /// cannot be bypassed and every closed tab is remembered for Window ▸
    /// Reopen Closed Tab. Closing the last tab leaves a fresh Untitled one,
    /// as before; closing the front tab activates its nearest surviving
    /// neighbour (the one after it, else the one before), as Safari does.
    private func closeTabs(ids: Set<UUID>) {
        // Keep the run's destination alive until the shared Shell releases
        // it. Otherwise diagnostics would still be correctly routed to the
        // captured editor object, but the user could no longer see that tab.
        if let ownerID = terminalModel.activeRunOwnerID,
           ids.contains(ownerID),
           let run = terminalModel.activeRun,
           let ownerTab = tabs.first(where: { $0.id == ownerID }) {
            NSSound.beep()
            ownerTab.editor.addStatus(
                "“\(ownerTab.title)” cannot be closed while \(run) is running. Stop or wait for the run first.",
                severity: .warning
            )
            return
        }
        let closing = tabs.filter { ids.contains($0.id) }
        guard !closing.isEmpty, confirmClose(tabs: closing) else { return }
        for tab in closing { closedTabs.remember(tab) }

        let remaining = tabs.filter { !ids.contains($0.id) }
        if remaining.isEmpty {
            let newTab = NetworkTab()
            tabs = [newTab]
            activeTabID = newTab.id
        } else {
            if ids.contains(activeTabID),
               let idx = tabs.firstIndex(where: { $0.id == activeTabID }) {
                let after = tabs[idx...].first(where: { !ids.contains($0.id) })
                let before = tabs[..<idx].last(where: { !ids.contains($0.id) })
                tabs = remaining
                activeTabID = (after ?? before ?? remaining[0]).id
            } else {
                tabs = remaining
            }
        }
        persistCurrentTabURLs()
    }

    /// Save / Don't Save / Cancel for every dirty tab in `tabs`, reviewed
    /// one at a time in tab-bar order (multi-tab closes ask per tab, the
    /// way Xcode does). True when the close may go ahead.
    func confirmClose(tabs: [NetworkTab]) -> Bool {
        TabClosing.confirmClose(tabs) { tab in saveTab(tab) }
    }

    /// Saves one tab's document — to its file, or through the Save panel
    /// for an untitled network — whether or not it is the front tab. False
    /// when the user cancelled the panel or the write failed (reported).
    private func saveTab(_ tab: NetworkTab) -> Bool {
        let url: URL
        if let existing = tab.editor.currentFileURL {
            url = existing
        } else {
            let base = tab.title.hasSuffix(".bnet") ? String(tab.title.dropLast(5)) : tab.title
            guard let chosen = TabDocumentWriter.runSavePanel(suggestedName: base, directory: nil) else {
                return false
            }
            url = chosen
        }
        do {
            try TabDocumentWriter.write(editor: tab.editor, to: url)
            menuContext.noteRecentDocument(url)
            if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[idx].title = url.lastPathComponent
            }
            persistCurrentTabURLs()
            return true
        } catch {
            showAlert(title: "Save Failed", message: error.localizedDescription, style: .critical)
            tab.editor.addStatus("Save failed: \(error.localizedDescription)", severity: .error)
            return false
        }
    }

    private func closeTab(id: UUID) {
        closeTabs(ids: [id])
    }

    private func closeAllTabs() {
        closeTabs(ids: Set(tabs.map(\.id)))
    }

    private func persistCurrentTabURLs() {
        let urls = tabs.compactMap { $0.editor.currentFileURL?.absoluteString }
        UserDefaults.standard.set(urls, forKey: "tabs.currentURLs")
    }

    private func saveNetwork() {
        if let url = activeEditor.currentFileURL {
            writeNetwork(to: url)
        } else {
            saveNetworkAs()
        }
    }

    private func saveNetworkAs() {
        let panel = NSSavePanel()
        panel.title = "Save Network As"
        panel.nameFieldStringValue = activeEditor.currentFileURL?.lastPathComponent ?? (exportBaseName + ".bnet")
        panel.allowedContentTypes = [UTType(filenameExtension: "bnet") ?? .json]
        panel.canCreateDirectories = true

        if let currentDir = activeEditor.currentFileURL?.deletingLastPathComponent() {
            panel.directoryURL = currentDir
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        writeNetwork(to: url)
    }

    private func writeNetwork(to url: URL) {
        do {
            // The same encoder the close guard's Save uses (TabClosing.swift).
            try TabDocumentWriter.write(editor: activeEditor, to: url)
            menuContext.noteRecentDocument(url)
            if let idx = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[idx].title = url.lastPathComponent
                bindAIConversation()
            }
            persistCurrentTabURLs()
        } catch {
            showAlert(title: "Save Failed", message: error.localizedDescription, style: .critical)
            activeEditor.addStatus("Save failed: \(error.localizedDescription)", severity: .error)
        }
    }

    private func loadNetwork() {
        let panel = NSOpenPanel()
        panel.title = "Open Network"
        panel.allowedContentTypes = [UTType(filenameExtension: "bnet") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadNetworkFile(at: url)
    }

    private func loadExample() {
        let panel = NSOpenPanel()
        panel.title = "Open Example"
        panel.allowedContentTypes = [UTType(filenameExtension: "bnet") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let lookup = locateExamples()
        if let examplesDir = lookup.url {
            panel.directoryURL = examplesDir
        } else {
            // A miss used to be silent: the panel opened on whatever directory
            // the user was last in, showed no .bnet files, and offered no
            // explanation — the same dead end as an empty file dialog, with a
            // different cause. It is reachable by a bundle built before the
            // examples were packaged, or by one whose Resources were stripped.
            // Say what was looked for, in the Status pane and on the panel
            // itself, so the answer is "these paths do not exist" rather than
            // "the app is broken". Home is a deterministic starting point; the
            // last-used directory is not.
            activeEditor.addStatus(
                "No examples directory found — looked in: " + lookup.searchTrail + ".",
                severity: .warning
            )
            panel.message = "The bundled examples could not be found. "
                + "Choose a .bnet file, or see the Status pane for the paths that were tried."
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadNetworkFile(at: url)
    }

    /// Decodes a .bnet document at `url` and loads it into the active tab
    /// (if empty) or a fresh tab.
    private func loadNetworkFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let document = try decoder.decode(NetworkDocument.self, from: data)

            // If the active tab is an empty untitled network, load into it
            // instead of creating a new tab
            let isBlank = activeEditor.nodes.isEmpty
                && activeEditor.links.isEmpty
                && activeEditor.currentFileURL == nil
            if isBlank {
                activeEditor.loadNetwork(document: document)
                activeEditor.currentFileURL = url
                activeEditor.addStatus("Loaded \(url.lastPathComponent).", severity: .success)
                if let idx = tabs.firstIndex(where: { $0.id == activeTabID }) {
                    tabs[idx].title = url.lastPathComponent
                    bindAIConversation()
                }
            } else {
                let tab = NetworkTab(title: url.lastPathComponent)
                tab.editor.loadNetwork(document: document)
                tab.editor.currentFileURL = url
                tab.editor.addStatus("Loaded \(url.lastPathComponent).", severity: .success)
                tabs.append(tab)
                activeTabID = tab.id
            }
            persistCurrentTabURLs()
            menuContext.noteRecentDocument(url)

            // Auto-run the Network Primitives analysis on load so the user
            // sees the parameterization immediately, and so the warning banner
            // (if any) is set before they interact with the canvas.
            showNetworkPrimitives()
        } catch {
            showAlert(title: "Load Failed", message: error.localizedDescription, style: .critical)
            activeEditor.addStatus("Load failed: \(error.localizedDescription)", severity: .error)
        }
    }

    /// The outcome of one example-directory lookup: the directory if a
    /// candidate existed, and — always — the candidates that were tried, in
    /// precedence order.
    ///
    /// The trail is the point. `SolverRuntimeResolver` learned the same lesson
    /// about missing binaries: "not found" is not a report a user can act on,
    /// whereas "these seven paths do not exist" tells them immediately whether
    /// the bundle is incomplete or they are running from an unexpected place.
    private struct ExamplesLookup {
        let url: URL?
        let searched: [URL]

        /// The first few candidates, joined for a one-line status entry. All
        /// of them would be a paragraph in a pane sized for a sentence, and
        /// the ones that matter are always at the front: the bundle's own
        /// Resources, then the override, then the neighbouring `Qnet.app`.
        var searchTrail: String {
            let shown = searched.prefix(4).map { $0.path }
            let rest = searched.count - shown.count
            return shown.joined(separator: ", ")
                + (rest > 0 ? ", and \(rest) more" : "")
        }
    }

    /// Locates the 50 bundled literature networks.
    ///
    /// Precedence deliberately mirrors `SolverRuntimeResolver.runtimeRoots()`:
    /// **a packaged copy inside the app bundle → `QNET_SOLVER_ROOT` → a nearby
    /// `Qnet.app` → the development source tree**, walking up from both the
    /// working directory and the executable rather than the working directory
    /// alone. The old walk started at `FileManager.default.currentDirectoryPath`
    /// only, which for a Finder-launched .app is `/`, so "Open an Example…" —
    /// the one action the empty canvas offers — opened a file panel on
    /// wherever the user happened to be last. It worked in a `swift run`
    /// checkout, which is exactly why it went unnoticed.
    ///
    /// `build_app.sh` copies `input/examples` to `Contents/Resources/examples`;
    /// `input/examples` is also accepted under Resources so an older bundle
    /// laid out that way still resolves.
    private func locateExamples() -> ExamplesLookup {
        let fm = FileManager.default
        let leaves = ["examples", "input/examples"]
        var candidates: [URL] = []

        // A packaged app must be self-contained and is always authoritative.
        if let resources = Bundle.main.resourceURL {
            candidates += leaves.map { resources.appendingPathComponent($0, isDirectory: true) }
        }

        if let raw = ProcessInfo.processInfo.environment["QNET_SOLVER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let override = URL(fileURLWithPath: raw, isDirectory: true)
            candidates.append(
                override.appendingPathComponent("Contents/Resources/examples", isDirectory: true)
            )
            candidates += leaves.map { override.appendingPathComponent($0, isDirectory: true) }
        }

        // Both anchors, because `swift run` executes from the checkout while a
        // launched bundle executes from Contents/MacOS.
        var anchors = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        if let executable = Bundle.main.executableURL {
            anchors.append(executable.deletingLastPathComponent())
        }
        var ancestors: [URL] = []
        var seen: Set<String> = []
        for anchor in anchors {
            var current = anchor.standardizedFileURL
            for _ in 0..<7 {
                if seen.insert(current.path).inserted { ancestors.append(current) }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        // A packaged copy beside the checkout beats an unpackaged source tree,
        // for the same reason a packaged solver binary does.
        for ancestor in ancestors {
            candidates.append(
                ancestor.appendingPathComponent(
                    "Qnet.app/Contents/Resources/examples", isDirectory: true
                )
            )
        }
        for ancestor in ancestors {
            candidates += leaves.map { ancestor.appendingPathComponent($0, isDirectory: true) }
        }

        for candidate in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            return ExamplesLookup(url: candidate, searched: candidates)
        }
        return ExamplesLookup(url: nil, searched: candidates)
    }

    // MARK: - Export

    /// Writes every solver input file for the active network into one
    /// folder — the same seven files `Qnet --export-cmp` produces, via the
    /// same exporters.
    private func exportAllSolverInputs() {
        // Finite-buffer networks first pick the blocking convention the
        // exported SRBM files should encode — the same choice the SRBM
        // export sheet and `--export-cmp --loss-fix / --bas-fix` offer, now
        // in the shared run-parameter sheet instead of a save-panel
        // accessory. Infinite networks never block, so they go straight to
        // the folder chooser.
        guard !activeEditor.infiniteBuffers else {
            exportAllSolverInputs(convention: .manufacturing)
            return
        }
        presentRunParameters(
            .exportBlockingConvention(
                convention: SRBMExportSheet.BlockingConvention.manufacturing.rawValue,
                conventions: SRBMExportSheet.BlockingConvention.allCases.map(\.title)
            )
        ) { values in
            let convention = SRBMExportSheet.BlockingConvention(rawValue: values.int(RunKey.convention))
                ?? .manufacturing
            exportAllSolverInputs(convention: convention)
        }
    }

    /// Writes the files once the destination folder — and, for finite
    /// buffers, the blocking convention — are known.
    private func exportAllSolverInputs(convention: SRBMExportSheet.BlockingConvention) {
        let panel = NSOpenPanel()
        panel.title = "Export All Solver Inputs"
        panel.message = "Choose a folder for the solver input files (sm.in, fm.in, lp.in, sim.txt, qna.qna, cmp_sm.in, cmp_sim.sim)."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let dir = activeEditor.currentFileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }

        let inf = activeEditor.infiniteBuffers

        guard panel.runModal() == .OK, let outdir = panel.url else { return }

        let lossFix = !inf && convention == .lossCorrection
        let basFix  = !inf && convention == .basCorrection

        let nodes = activeEditor.nodes
        let links = activeEditor.links
        var written: [String] = []
        var failures: [String] = []

        func write(_ name: String, _ result: Result<String, some Error>) {
            switch result {
            case .success(let text):
                let url = outdir.appendingPathComponent(name)
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    written.append(name)
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            case .failure(let error):
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        write("sm.in", SRBMExporter.exportForSpectral(
            nodes: nodes, links: links, infiniteBuffers: inf, degree: 8,
            lossModeCorrection: lossFix, basModeCorrection: basFix))
        write("fm.in", SRBMExporter.exportForFiniteElement(
            nodes: nodes, links: links, infiniteBuffers: inf, meshSize: 12,
            lossModeCorrection: lossFix, basModeCorrection: basFix))
        write("lp.in", SRBMExporter.exportForFiniteLP(
            nodes: nodes, links: links,
            lossModeCorrection: lossFix, basModeCorrection: basFix))
        write("sim.txt", NetworkExporter.export(nodes: nodes, links: links))
        write("qna.qna", QNAExporter.export(nodes: nodes, links: links))
        write("cmp_sm.in", BNASRBMExporter.exportForSpectral(nodes: nodes, links: links, degree: 8))
        write("cmp_sim.sim", BNANetworkExporter.export(nodes: nodes, links: links))

        let conventionNote = inf ? "" : " Blocking convention: \(convention.title)."
        activeEditor.addStatus("Exported \(written.count) solver input file(s) to \(outdir.path): \(written.joined(separator: ", ")).\(conventionNote)", severity: .success)
        if !failures.isEmpty {
            // Never an alert. The export succeeded for everything else, and
            // the list of what it skipped is something the user wants to keep
            // and scroll back to — not to dismiss before they have read it.
            reportBlocked(
                "\(failures.count) of \(written.count + failures.count) solver input files were not written.",
                detail: failures.joined(separator: "\n"),
                severity: .warning,
                on: activeEditor
            )
        }
    }

    private func exportQNA() {
        let result = QNAExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("QNA export failed: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let panel = NSSavePanel()
            configureExportPanel(panel, title: "Export QNA Input", fileExtension: "qna")

            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                activeEditor.addStatus("Exported QNA to \(url.lastPathComponent).", severity: .success)
            } catch {
                reportBlocked(
                    "QNA export write failed: \(error.localizedDescription)",
                    on: activeEditor
                )
            }
        }
    }

    private func exportNetwork() {
        let result = NetworkExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("Export failed: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let panel = NSSavePanel()
            configureExportPanel(panel, title: "Export Finite Simulator Input", fileExtension: "txt")

            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                activeEditor.addStatus("Exported network to \(url.lastPathComponent).", severity: .success)
            } catch {
                reportBlocked(
                    "Export write failed: \(error.localizedDescription)",
                    on: activeEditor
                )
            }
        }
    }

    // MARK: - Run

    /// True while any sheet owned by this scene is presented. `QnetCommands`
    /// mirrors it through `MenuContext` so bare-letter tool shortcuts and
    /// ⌫ never fire on the canvas underneath one of these sheets.
    private var appSheetPresented: Bool {
        showStartupDependencyCheck || showGenerateRandomSheet || showArchetypeSheet
            || showFindNodeSheet || showTestSetSheet
            || showSpectralConvergenceSheet || runParameterRequest != nil
    }

    /// Presents the one run-parameter sheet and hands the collected values
    /// back. Replaces the per-solver `NSAlert` + `AlertFormBuilder`
    /// accessory; the run logic itself is unchanged and lives in `onRun`.
    ///
    /// - Parameters:
    ///   - spec: the form to show.
    ///   - onSetDefault: writes the current values into `AppSettings` when
    ///     the footer's "Set as Default" button is pressed. Omit for
    ///     dialogs that have no stored defaults.
    ///   - onCancel: runs on Escape / Cancel (usually a status line).
    ///   - onRun: runs on Return / Run with the collected values.
    private func presentRunParameters(
        _ spec: RunParameterSpec,
        onSetDefault: ((RunParameterValues) -> Void)? = nil,
        onCancel: @escaping () -> Void = {},
        onRun: @escaping (RunParameterValues) -> Void
    ) {
        // There is one integrated shell and therefore one solver job at a
        // time. Refuse before collecting parameters when another tab owns
        // that shell; `beginRun` repeats the guard at launch to close the
        // race between presenting and submitting this sheet.
        if let active = terminalModel.activeRun {
            NSSound.beep()
            activeEditor.addStatus(
                "\(spec.title) cannot open while \(active) is running for “\(terminalModel.activeRunOwnerTitle ?? "another tab")”. Stop or wait for that run first.",
                severity: .warning
            )
            return
        }
        // Belt and braces behind the menu items' `.disabled(sheetPresented)`.
        // The form is a panel now, and `DSPanelWindow.present` keyed by id
        // brings an OPEN panel forward rather than replacing its contents —
        // so a second request raised while the first is up would show the
        // first solver's form under the second solver's expectations, and
        // whichever answer came back would be attributed to the wrong run.
        // (As a sheet the same request was dropped on the floor instead,
        // leaving `appSheetPresented` stuck true and the canvas tool letters
        // and ⌫ dead until relaunch.) Either way a run asked for underneath
        // an open dialog is simply refused.
        guard !appSheetPresented else {
            NSSound.beep()
            activeEditor.addStatus(
                "\(spec.title) needs the open dialog to be closed first.",
                severity: .warning)
            return
        }
        runParameterRequest = RunParameterRequest(
            spec: spec,
            onSetDefault: onSetDefault,
            onCancel: {
                runParameterRequest = nil
                onCancel()
            },
            onRun: { values in
                runParameterRequest = nil
                onRun(values)
            }
        )
    }

    private func runSimulation() {
        let result = NetworkExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("Simulation aborted: \(error.localizedDescription)", on: activeEditor)
            return

        case .success(let content):
            guard let binary = findFBNAsimBinary() else {
                reportBlocked(
                    "Simulation aborted: fBNAsim binary not found.",
                    detail: "Could not locate the fBNAsim binary. Make sure it is compiled (run 'make' in the fBNAsim directory).",
                    on: activeEditor
                )
                return
            }

            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_network_\(ProcessInfo.processInfo.processIdentifier).txt")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Simulation aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            // Ask for the run parameters in the shared DSSheet form; the
            // launch logic below is unchanged.
            presentRunParameters(
                .monteCarloFinite(blocking: appSettings.simBlocking,
                                  parallel: appSettings.simParallel,
                                  replications: appSettings.simReplications,
                                  warmup: appSettings.simWarmup,
                                  simTime: appSettings.simTime,
                                  seedFixed: appSettings.simSeedFixed,
                                  seed: appSettings.simSeed),
                onSetDefault: { v in
                    appSettings.simParallel = v.int(RunKey.parallel)
                    appSettings.simBlocking = v.int(RunKey.blocking)
                    appSettings.simReplications = max(1, v.int(RunKey.replications))
                    appSettings.simWarmup = max(0, v.int(RunKey.warmup))
                    appSettings.simTime = max(1, v.int(RunKey.simTime))
                    appSettings.simSeedFixed = v.flag(RunKey.seedFixed)
                    appSettings.simSeed = max(0, v.int(RunKey.seed))
                },
                onCancel: { activeEditor.addStatus("Simulation cancelled.", severity: .warning) }
            ) { values in
                let numRuns = max(1, values.int(RunKey.replications, default: 50))
                let warmup = max(0, values.int(RunKey.warmup, default: 1_000_000))
                let simTime = max(1, values.int(RunKey.simTime, default: 5_000_000))
                let fixedSeed = values.flag(RunKey.seedFixed)
                let enteredSeed = max(0, values.int(
                    RunKey.seed, default: AppSettings.Defaults.simSeed
                ))
                let baseSeed = fixedSeed
                    ? enteredSeed : Int.random(in: 1...Int(Int32.max))

                var parallelFlag = ""
                switch values.int(RunKey.parallel) {
                case 0: parallelFlag = " -a"   // Apple GCD
                case 1: parallelFlag = " -o"   // OpenMP
                default: break                  // Sequential (no flag)
                }

                let blockingFlag: String
                let blockingDesc: String
                switch values.int(RunKey.blocking) {
                case 0:  blockingFlag = " -l"; blockingDesc = "loss"
                case 2:  blockingFlag = " -e"; blockingDesc = "BAS+ext-loss"
                default: blockingFlag = "";    blockingDesc = "BAS"
                }

                let outFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BNET_sim_out_\(ProcessInfo.processInfo.processIdentifier).txt")
                let progFile = progressFilePath(label: "fin_sim")
                let runCmd = runWithStderrOnFailure(
                    "\"\(binary.path)\" -f \"\(tempFile.path)\" -G -n \(numRuns) -w \(warmup) -T \(simTime) -s \(baseSeed) -P \"\(progFile)\"\(parallelFlag)\(blockingFlag)",
                    stdoutTo: outFile.path,
                    label: "Simulation"
                )
                let runWithBar = withProgress(prefix: "Running simulation ...  ", command: runCmd, progressFile: progFile)
                let filterCmd = singleMethodFormatCmd(
                    outFile: outFile.path, methodLabel: "Simulation", varName: "X",
                    showGamma: true, showSojourn: true, showXClass: false)
                let command = "\(threadCountBanner(parallel: true)) && _t0=$(perl -MTime::HiRes=time -e 'print time') && \(runWithBar) && echo && \(filterCmd) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')'"
                if let script = silentScript(
                    command,
                    label: "sim",
                    parameters: [
                        "blocking": blockingDesc,
                        "parallelism": values.int(RunKey.parallel).description,
                        "replications": numRuns.description,
                        "warm-up": warmup.description,
                        "simulation time": simTime.description,
                        "fixed seed": fixedSeed.description,
                    ],
                    seed: UInt64(baseSeed),
                    replicationSeeds: (0..<numRuns).map { UInt64(baseSeed + $0 / 2) }
                ) {
                    // The Shell can refuse the command (a full-screen program or
                    // a stdin-reading command owns it); TerminalModel has already
                    // said so and retired the run, so do not follow it with a
                    // "Running …" line that is not true.
                    if terminalModel.sendCommand(script) {
                        activeEditor.addStatus("Running simulation via fBNAsim (\(blockingDesc) mode)...", severity: .info)
                    }
                }
            }
        }
    }

    /// Exact queue-level reference for finite, Markovian loss networks. The
    /// Python solver enumerates only reachable ordered-FCFS states and stops
    /// at its state limit rather than silently truncating the chain.
    private func runGenericCTMC() {
        // Two engines, one method: `fbna_gc` (C) and `solver.py`. The Settings
        // row is shared with the adaptive truncated CTMC, which runs the same
        // power-iteration kernel.
        let resolvedEngine: ResolvedEngine
        switch resolveEngine(
            for: .finiteGenericCTMC,
            preferred: SolverEngine(storedValue: appSettings.engineCTMC),
            pythonScript: "solver.py",
            pythonSubdirectory: "fBNAgc"
        ) {
        case .failure(let unavailable):
            reportBlocked(
                "Exact sparse CTMC aborted: Python solver runtime unavailable.",
                detail: unavailable.diagnostic,
                on: activeEditor
            )
            return
        case .success(let resolved):
            resolvedEngine = resolved
        }
        if let note = resolvedEngine.note {
            activeEditor.addStatus(note, severity: .warning)
        }
        switch FiniteMarkovExporter.genericCTMC(
            editor: activeEditor, name: activeTabTitle
        ) {
        case .failure(let error):
            reportBlocked(
                "Exact sparse CTMC not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_ctmc_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Exact sparse CTMC aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(resolvedEngine.launchPrefix) \(shellQuote(inputFile.path)) --top-states 0"
            let command = withSpinner(
                prefix: "Solving exact CTMC (\(resolvedEngine.engine.title)) ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "generic_ctmc",
                parameters: [
                    "blocking": "loss",
                    "service discipline": "FCFS",
                    "max reachable states": "200000",
                    "stationary tolerance": "1e-12",
                    "engine": resolvedEngine.engine.title,
                    "runtime": resolvedEngine.provenance
                ]
            ) {
                activeEditor.addStatus(
                    "Running exact sparse CTMC on the \(resolvedEngine.engine.descriptiveName) "
                    + "(queue process, loss on full).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    /// Fast queue-level finite-buffer approximation between exact state
    /// enumeration and DES. BAS variants are labeled as approximations by
    /// both the runner and solver output.
    private func runFiniteDecomposition() {
        let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "fbna_decomp.py", subdirectory: "fBNAdecomp", groups: ["finite"]
        )
        guard let solver = lookup.url,
              let python = lookup.resolution?.runtimeExecutableURL else {
            reportBlocked(
                "Finite-buffer decomposition aborted: Python solver runtime unavailable.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }
        let blocking: (solver: String, display: String)
        switch appSettings.simBlocking {
        case 0: blocking = ("loss", "Loss")
        case 1: blocking = ("bas", "BAS approximation")
        default: blocking = ("bas_external_loss", "BAS + external loss approximation")
        }
        switch FiniteMarkovExporter.decomposition(
            editor: activeEditor,
            name: activeTabTitle,
            blocking: blocking.solver
        ) {
        case .failure(let error):
            reportBlocked(
                "Finite-buffer decomposition not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_decomp_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Finite-buffer decomposition aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(shellQuote(python.path)) -B \(shellQuote(solver.path)) \(shellQuote(inputFile.path)) --format text"
            let command = withSpinner(
                prefix: "Solving finite decomposition ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "fb_decomp",
                parameters: [
                    "blocking": blocking.display,
                    "fixed-point tolerance": "1e-10",
                    "maximum iterations": "1000",
                    "damping": "0.5",
                    "BAS is approximation": (appSettings.simBlocking != 0).description,
                    "runtime": lookup.resolution?.provenanceDescription ?? "unknown"
                ]
            ) {
                activeEditor.addStatus(
                    "Running finite-buffer decomposition (\(blocking.display)).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    /// Exact queue-level solution for the strict open FCFS BCMP/Jackson
    /// subclass represented by the visual editor. Unlike the older
    /// analytical banner, this is a first-class auditable solver run.
    private func runOpenProductForm() {
        let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "solver.py", subdirectory: "BNApf", groups: ["infinite"]
        )
        guard let solver = lookup.url,
              let python = lookup.resolution?.runtimeExecutableURL else {
            reportBlocked(
                "Exact product form aborted: solver support is unavailable.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }
        switch ProductFormExporter.export(editor: activeEditor, name: activeTabTitle) {
        case .failure(let error):
            reportBlocked(
                "Exact product form not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_open_product_form_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Exact product form aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(shellQuote(python.path)) -B \(shellQuote(solver.path)) \(shellQuote(inputFile.path))"
            let command = withSpinner(
                prefix: "Solving exact open product form ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "product_form",
                parameters: [
                    "model": "exact open FCFS BCMP/Jackson",
                    "local queues": "M/M/c",
                    "state-space truncation": "none",
                    "traffic equations": "class-preserving open routing",
                    "runtime": lookup.resolution?.provenanceDescription ?? "unknown"
                ]
            ) {
                activeEditor.addStatus(
                    "Running exact open product form (analytic M/M/c local normalizers).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    /// Exact matrix-geometric queue-length solution for the strict scalar
    /// QBD subclass represented by one open M/M/1 station. Station feedback
    /// remains exact because only non-feedback completions lower the level.
    private func runQBD() {
        // Two engines, one method: `bna_qbd` (C) and `qbd_solver.py`. This
        // method is deterministic, so their output is byte-identical with no
        // exceptions; the choice is only how long the wait is.
        let resolvedEngine: ResolvedEngine
        switch resolveEngine(
            for: .matrixAnalyticQBD,
            preferred: SolverEngine(storedValue: appSettings.engineQBD),
            pythonScript: "qbd_solver.py",
            pythonSubdirectory: "BNAqbd"
        ) {
        case .failure(let unavailable):
            reportBlocked(
                "Exact QBD aborted: solver support is unavailable.",
                detail: unavailable.diagnostic,
                on: activeEditor
            )
            return
        case .success(let resolved):
            resolvedEngine = resolved
        }
        if let note = resolvedEngine.note {
            activeEditor.addStatus(note, severity: .warning)
        }
        switch QBDExporter.export(editor: activeEditor, name: activeTabTitle) {
        case .failure(let error):
            reportBlocked(
                "Exact QBD not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_qbd_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Exact QBD aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(resolvedEngine.launchPrefix) \(shellQuote(inputFile.path)) --human"
            let command = withSpinner(
                prefix: "Solving exact matrix-analytic QBD (\(resolvedEngine.engine.title)) ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "qbd",
                parameters: [
                    "model": "exact scalar continuous-time QBD",
                    "queue": "one-station M/M/1 with optional feedback",
                    "algorithm": "minimal nonnegative matrix-geometric rate",
                    "maximum iterations": "100000",
                    "engine": resolvedEngine.engine.title,
                    "runtime": resolvedEngine.provenance
                ]
            ) {
                activeEditor.addStatus(
                    "Running exact matrix-analytic QBD solution on the "
                    + "\(resolvedEngine.engine.descriptiveName).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    /// Queue-process approximation for infinite, single-class Markovian
    /// networks. The solver adaptively enlarges a total-population cap and
    /// keeps its heuristic truncation evidence separate from any available
    /// Foster--Lyapunov certificate.
    private func runTruncatedCTMC() {
        if let issue = truncatedCTMCScaleIssue() {
            reportBlocked(
                "Adaptive truncated CTMC not started: \(issue)",
                severity: .warning,
                on: activeEditor
            )
            return
        }
        // Two engines, one method: `bna_tc` (C) and `truncated_ctmc.py`. The
        // Settings row is shared with the finite Exact Sparse CTMC, which runs
        // the same kernel.
        let resolvedEngine: ResolvedEngine
        switch resolveEngine(
            for: .truncatedCTMC,
            preferred: SolverEngine(storedValue: appSettings.engineCTMC),
            pythonScript: "truncated_ctmc.py",
            pythonSubdirectory: "BNAtc"
        ) {
        case .failure(let unavailable):
            reportBlocked(
                "Adaptive truncated CTMC aborted: solver not found.",
                detail: unavailable.diagnostic,
                on: activeEditor
            )
            return
        case .success(let resolved):
            resolvedEngine = resolved
        }
        if let note = resolvedEngine.note {
            activeEditor.addStatus(note, severity: .warning)
        }
        switch FiniteMarkovExporter.truncatedInfiniteCTMC(
            editor: activeEditor, name: activeTabTitle
        ) {
        case .failure(let error):
            reportBlocked(
                "Adaptive truncated CTMC not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_truncated_ctmc_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Adaptive truncated CTMC aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(resolvedEngine.launchPrefix) \(shellQuote(inputFile.path)) --human"
            let command = withSpinner(
                prefix: "Solving adaptive truncated CTMC (\(resolvedEngine.engine.title)) ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "truncated_ctmc",
                parameters: [
                    "process": "open single-class M/M/c network",
                    "initial total-population cap": "8",
                    "maximum total-population cap": "64",
                    "maximum states": "200000",
                    "boundary mass tolerance": "1e-8",
                    "successive refinement tolerance": "1e-7",
                    "truncation evidence": "heuristic",
                    "engine": resolvedEngine.engine.title,
                    "runtime": resolvedEngine.provenance
                ]
            ) {
                activeEditor.addStatus(
                    "Running adaptive truncated CTMC on the \(resolvedEngine.engine.descriptiveName) "
                    + "(queue process; heuristic truncation diagnostics).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    private func truncatedCTMCScaleIssue() -> String? {
        guard activeEditor.infiniteBuffers,
              activeEditor.tractabilityIsExact,
              activeEditor.tractabilityMeansLabel.localizedCaseInsensitiveContains("Jackson")
        else { return nil }
        let dimension = activeEditor.stationsInExportOrder.count
        guard dimension > 1 else { return nil }

        func stateCount(cap: Int) -> Double {
            var value = 1.0
            for k in 1...dimension {
                value *= Double(cap + k) / Double(k)
            }
            return value
        }
        var feasibleCap = 1
        for cap in 1...64 where stateCount(cap: cap) <= 200_000 {
            feasibleCap = cap
        }
        let exactMean = activeEditor.tractabilityMeans.reduce(0, +)
        guard exactMean > 0.75 * Double(feasibleCap) else { return nil }
        let states = Int(stateCount(cap: feasibleCap).rounded())
        return "The exact Jackson mean population is \(exactMean.formatted(.number.precision(.fractionLength(1)))) customers, while the 200,000-state budget only reaches total population \(feasibleCap) (about \(states.formatted()) states). That boundary lies inside the distribution's main mass, so truncation cannot be reliable. Run Exact Open Product Form instead; it is exact and does not enumerate the infinite state space."
    }

    /// Complete empty-to-empty cycles provide the IID units for this queue-
    /// process simulation. The form records a fixed-width stopping contract
    /// and a reproducible 64-bit seed/stream pair in result provenance.
    private func runRegenerativeMonteCarlo() {
        // Two engines, one method: `bna_rmc` (C) and `regenerative_mc.py`. They
        // draw the same random stream and print the same report, so this picks
        // the wait, not the answer. See `resolveEngine(for:...)` for what
        // happens when the chosen one is not installed.
        let engineChoice: Result<ResolvedEngine, SolverEngineUnavailable> = resolveEngine(
            for: .regenerativeMonteCarlo,
            preferred: SolverEngine(storedValue: appSettings.engineRegenerative),
            pythonScript: "regenerative_mc.py",
            pythonSubdirectory: "BNArmc"
        )
        let resolvedEngine: ResolvedEngine
        switch engineChoice {
        case .failure(let unavailable):
            reportBlocked(
                "Regenerative Monte Carlo aborted: simulator not found.",
                detail: unavailable.diagnostic,
                on: activeEditor
            )
            return
        case .success(let resolved):
            resolvedEngine = resolved
        }
        if let note = resolvedEngine.note {
            activeEditor.addStatus(note, severity: .warning)
        }
        presentRunParameters(
            .regenerativeMonteCarlo(
                infiniteBuffers: activeEditor.infiniteBuffers,
                seedFixed: appSettings.simSeedFixed,
                seed: appSettings.simSeed
            ),
            onCancel: {
                activeEditor.addStatus("Regenerative Monte Carlo cancelled.", severity: .warning)
            }
        ) { values in
            let confidence = values.double(RunKey.confidence, default: 0.95)
            let absoluteHalfWidth = values.double(RunKey.absoluteHalfWidth, default: 0.05)
            let relativeHalfWidth = values.double(RunKey.relativeHalfWidth, default: 0.10)
            let minimumCycles = max(30, values.int(RunKey.minimumCycles, default: 500))
            let maximumCycles = max(
                minimumCycles,
                values.int(RunKey.maximumCycles, default: 20_000)
            )
            let maximumWallSeconds = max(
                1, values.int(RunKey.maximumWallSeconds, default: 30)
            )
            let fixedSeed = values.flag(RunKey.seedFixed)
            let enteredSeed = max(0, values.int(
                RunKey.seed, default: AppSettings.Defaults.simSeed
            ))
            let seed = UInt64(
                fixedSeed ? enteredSeed : Int.random(in: 1...Int(Int32.max))
            )
            let stream = UInt64(max(0, values.int(RunKey.stream)))
            let emptyProbability = estimatedMarkovEmptyProbability()
            if let emptyProbability, emptyProbability < 1e-4 {
                activeEditor.addStatus(
                    "Regenerative-cycle warning: estimated empty-system probability is \(emptyProbability.formatted(.number.notation(.scientific).precision(.significantDigits(3)))); the default wall-time safeguard may produce few complete cycles. A partial result will be labelled as partial.",
                    severity: .warning
                )
            }
            let stopping = RegenerativeStoppingOptions(
                confidence: confidence,
                absoluteHalfWidth: absoluteHalfWidth,
                relativeHalfWidth: relativeHalfWidth,
                minimumCycles: minimumCycles,
                minimumEffectiveCycles: Double(min(30, minimumCycles)),
                minimumPositiveCycles: 5,
                checkEveryCycles: min(100, minimumCycles),
                maximumCycles: maximumCycles,
                maximumEvents: 10_000_000,
                maximumSimulatedTime: 1_000_000_000,
                maximumCycleTime: 10_000_000,
                maximumEventsPerCycle: 2_000_000,
                maximumWallSeconds: Double(maximumWallSeconds)
            )
            switch RegenerativeExporter.export(
                editor: activeEditor,
                name: activeTabTitle,
                baseSeed: seed,
                stream: stream,
                stopping: stopping
            ) {
            case .failure(let error):
                reportBlocked(
                    "Regenerative Monte Carlo not started: \(error.localizedDescription)",
                    severity: .warning,
                    on: activeEditor
                )
            case .success(let input):
                let inputFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qnet_regenerative_\(UUID().uuidString.lowercased()).json")
                do {
                    try input.write(to: inputFile, atomically: true, encoding: .utf8)
                } catch {
                    reportBlocked(
                        "Regenerative Monte Carlo aborted: could not write the solver input file: \(error.localizedDescription)",
                        on: activeEditor
                    )
                    return
                }
                let solve = "\(resolvedEngine.launchPrefix) \(shellQuote(inputFile.path))"
                let command = withSpinner(
                    prefix: "Running regenerative simulation (\(resolvedEngine.engine.title)) ...  ",
                    command: commandWithCleanup(solve, paths: [inputFile.path])
                )
                var parameters = [
                    "buffer regime": activeEditor.infiniteBuffers
                        ? "infinite" : "finite loss on full",
                    "confidence": confidence.description,
                    "absolute half-width": absoluteHalfWidth.description,
                    "relative half-width": relativeHalfWidth.description,
                    "minimum cycles": minimumCycles.description,
                    "maximum cycles": maximumCycles.description,
                    "maximum wall seconds": maximumWallSeconds.description,
                    "stream": stream.description,
                    "IID unit": "complete empty-to-empty cycle",
                    "interval": "asymptotic regenerative-ratio t",
                    "engine": resolvedEngine.engine.title,
                    "runtime": resolvedEngine.provenance
                ]
                if let emptyProbability {
                    parameters["estimated empty-system probability"] = emptyProbability.description
                }
                if runScript(
                    command,
                    label: "regenerative_mc",
                    parameters: parameters,
                    seed: seed
                ) {
                    activeEditor.addStatus(
                        "Running regenerative Monte Carlo on the \(resolvedEngine.engine.descriptiveName) "
                        + "(seed \(seed), stream \(stream)).",
                        severity: .info
                    )
                } else {
                    try? FileManager.default.removeItem(at: inputFile)
                }
            }
        }
    }

    /// Product of exact M/M/c empty probabilities using the traffic solution.
    /// This is a cycle-scarcity forecast only; it never changes the estimator.
    private func estimatedMarkovEmptyProbability() -> Double? {
        guard activeEditor.infiniteBuffers else { return nil }
        let result = SRBMExporter.computeData(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: true
        )
        guard case .success(let data) = result, data.d > 0 else { return nil }
        var networkEmpty = 1.0
        for i in 0..<data.d {
            let servers = data.numberOfServers[i]
            guard servers > 0, data.capacity[i] > 0 else { return nil }
            let serviceRate = data.capacity[i] / Double(servers)
            let offered = data.alpha[i] / serviceRate
            let rho = offered / Double(servers)
            guard rho >= 0, rho < 1 else { return nil }
            var term = 1.0
            var normalizer = 1.0
            if servers > 1 {
                for k in 1..<servers {
                    term *= offered / Double(k)
                    normalizer += term
                }
            }
            term *= offered / Double(servers)
            normalizer += term / (1.0 - rho)
            networkEmpty *= 1.0 / normalizer
        }
        return networkEmpty.isFinite ? networkEmpty : nil
    }

    /// Grid-free stationary SRBM approximation. The input comes from the
    /// same BNASRBMExporter calculation as Spectral/LP/MLMC, which keeps the
    /// model layer and parameter convention directly comparable.
    private func runAdaptiveLowRankBAR() {
        let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "low_rank_bar.py", subdirectory: "BNAalr"
        )
        guard let solver = lookup.url,
              let python = lookup.resolution?.runtimeExecutableURL else {
            reportBlocked(
                "Adaptive low-rank BAR aborted: solver not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }
        switch BNASRBMExporter.exportForAdaptiveBAR(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            name: activeTabTitle
        ) {
        case .failure(let error):
            reportBlocked(
                "Adaptive low-rank BAR not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_adaptive_bar_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Adaptive low-rank BAR aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            // The solver reports SRBM coordinates E[Z_i]: unfinished work, in
            // time units. Every other method in a comparison reports a queue
            // count, so the two were read side by side in different units and
            // the BAR column looked uniformly small.
            //
            // The conversion is E[X_i] = mu_i * E[Z_i] — the identity that
            // makes mu * E[W] = rho / (1 - rho) exact for M/M/1, a number in
            // system that already includes the customer in service. BNAmc
            // applies the same scaling to its own workload output.
            //
            // Verified against exact Jackson answers, not assumed. On
            // DaiNguyenReiman94.d3.c1.1 every mu_eff is 1 and the solver
            // returns 2.076923077 / 9.000000002 / 0.8181818182 against exact
            // rho/(1-rho) of 2.0769230769 / 9 / 0.8181818182. On 3dtandem,
            // where mu_eff is 1.1111, it returns 8.100000891 against an exact
            // 9.0, and 9.0 / 1.1111 = 8.1. Scaling by mu reconciles both. The
            // alternative reading — a missing in-service customer, E[X] - rho —
            // is refuted by the first network, where it predicts 1.4019 / 8.1 /
            // 0.3682 rather than what the solver returns.
            //
            // MULTI-SERVER IS DELIBERATELY EXCLUDED. The identity above is the
            // single-server one. Checked against exact M/M/c answers on a
            // three-station tandem of c = 3 stations:
            //
            //   rho = 0.90   E[Z] = 3.000   exact L_q =  7.354   c*E[Z] = 9.00  (+22%)
            //   rho = 0.95   E[Z] = 6.333   exact L_q = 17.233   c*E[Z] = 19.00 (+10%)
            //
            // The error halves as rho climbs, so for c > 1 the relation is
            // asymptotic in heavy traffic rather than exact, and no scalar
            // recovers E[X] across loads — unlike the single-server case, which
            // was exact at rho = 0.45, 0.675 and 0.9. Printing a converted
            // queue length for a multi-server station would therefore be
            // presenting a heavy-traffic approximation as if it were the same
            // exact conversion. The workload rows still print; only the
            // converted column is withheld, with the reason said out loud.
            var muList = ""
            var indexWidth = 1
            let multiServerStations = activeEditor.nodes
                .filter { $0.kind == .station && $0.numberOfServers > 1 }
                .map(\.name)
            if case .success(let data) = BNASRBMExporter.computeData(
                nodes: activeEditor.nodes, links: activeEditor.links
            ) {
                // meanServiceTimes is tau[i] = 1 / (s_i * muEff_i), so its
                // reciprocal is the station's TOTAL capacity c_i = s_i * muEff_i,
                // not a per-server rate. For a single-server station the two
                // coincide, which is the case this conversion is verified for.
                let capacity = data.meanServiceTimes.map { tau in tau > 0 ? 1.0 / tau : 1.0 }
                // %.17g, not a rounded literal: awk consumes these numerically
                // and a station whose capacity is small must not become zero.
                muList = capacity.map { String(format: "%.17g", $0) }.joined(separator: " ")
                indexWidth = String(capacity.count).count
            }

            // `solve` stays the name of the command handed to
            // commandWithCleanup: validation/gui_runtime_contracts.sh counts
            // that exact call across the eight Python runners, and the
            // cancellation-safe cleanup it pins is a property of the whole
            // pipeline, conversion included.
            var solve = "\(shellQuote(python.path)) -B \(shellQuote(solver.path)) \(shellQuote(inputFile.path))"

            // Pass the solver's own output through untouched, then append one
            // queue-length row per coordinate. `L_i` is the row
            // ResultOutputParser already reads as a queue length
            // (convertedQueueRow), so this adds no new parser contract, and the
            // workload it was converted from stays visible beside it.
            if !multiServerStations.isEmpty {
                let names = multiServerStations.joined(separator: ", ")
                let verb = multiServerStations.count == 1 ? "has" : "have"
                let note = "  Queue lengths not derived: \(names) \(verb) more than one "
                    + "server, and the workload-to-queue identity used for single-server "
                    + "stations is only asymptotic in heavy traffic when c > 1. The workload "
                    + "means above are the solver's own output."
                solve += " && printf '%s\\n' \(shellQuote(note))"
            } else if !muList.isEmpty {
                // -v, not an environment assignment: awk does not import the
                // environment into its own variable namespace, so `mu=... awk`
                // leaves `mu` empty and the conversion silently emits nothing.
                let awk = "awk -v w=\(indexWidth) -v mu=\(shellQuote(muList)) '"
                    + "BEGIN{n=split(mu,m,\" \")}"
                    + "{print}"
                    + "/^E\\[Z_[0-9]+\\] =/{s=$1;gsub(/[^0-9]/,\"\",s);i=s+0;"
                    + "if(i>=1&&i<=n){q[i]=$3*m[i];z[i]=$3;u[i]=m[i];if(i>d)d=i}}"
                    + "END{if(d>0){printf \"\\n\";"
                    + "for(i=1;i<=d;i++)printf \"  L_%0*d = %.6f    (workload E[Z_%0*d] = %.6f, mu_i = %.6f)\\n\","
                    + "w,i,q[i],w,i,z[i],u[i]}}'"
                solve = "\(solve) | \(awk)"
            }
            let command = withSpinner(
                prefix: "Fitting adaptive low-rank BAR ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "adaptive_bar",
                parameters: [
                    "model layer": "stationary orthant SRBM",
                    "maximum mixture rank": "12",
                    "training BAR points": "max(64, 6 × dimension)",
                    "held-out BAR points": "max(32, 6 × dimension)",
                    "BAR tolerance": "2e-5",
                    "moment-change tolerance": "2e-3",
                    "certified error bound": "false except exact product form",
                    "runtime": lookup.resolution?.provenanceDescription ?? "unknown"
                ]
            ) {
                activeEditor.addStatus(
                    "Running adaptive low-rank BAR (SRBM; held-out numerical diagnostics).",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    /// Polynomial BAR/Stieltjes outer relaxation. `auto` uses a locally
    /// installed CVXPY SDP backend when available. The solver itself labels
    /// floating solutions uncertified; no backend still produces the exact
    /// 1D/product-form answers or a useful auditable relaxation summary.
    private func runBARMomentBounds() {
        let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "solver.py", subdirectory: "BNAbb"
        )
        guard let solver = lookup.url,
              let python = lookup.resolution?.runtimeExecutableURL else {
            reportBlocked(
                "BAR moment bounds aborted: solver not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }
        switch BNASRBMExporter.exportForBARBounds(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            name: activeTabTitle
        ) {
        case .failure(let error):
            reportBlocked(
                "BAR moment bounds not started: \(error.localizedDescription)",
                severity: .warning,
                on: activeEditor
            )
        case .success(let input):
            let inputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("qnet_bar_bounds_\(UUID().uuidString.lowercased()).json")
            do {
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "BAR moment bounds aborted: could not write the solver input file: \(error.localizedDescription)",
                    on: activeEditor
                )
                return
            }
            let solve = "\(shellQuote(python.path)) -B \(shellQuote(solver.path)) \(shellQuote(inputFile.path)) --backend auto --require-bounds"
            let command = withSpinner(
                prefix: "Constructing BAR moment bounds ...  ",
                command: commandWithCleanup(solve, paths: [inputFile.path])
            )
            if runScript(
                command,
                label: "bar_bounds",
                parameters: [
                    "model layer": "stationary orthant SRBM",
                    "moment-relaxation order": "2",
                    "backend": "auto (CVXPY when available)",
                    "certification": "exact 1D/product form only; floating SDP results uncertified",
                    "runtime": lookup.resolution?.provenanceDescription ?? "unknown"
                ]
            ) {
                activeEditor.addStatus(
                    "Running BAR moment relaxation; certification will be stated in the result.",
                    severity: .info
                )
            } else {
                try? FileManager.default.removeItem(at: inputFile)
            }
        }
    }

    private func runFiniteElement() {
        // Auto-cap mesh size for high-dimensional networks where the FEM
        // matrix becomes too dense for direct sparse factorization. The FEM
        // cost scales roughly as n^{2d} and fill-in of the Cholesky factor
        // makes d=4, n=10 impractical; at d=4 we cap at 8 so a first run
        // completes in tens of seconds, and the user can still override.
        let stationCount = activeEditor.nodes.filter { $0.kind == .station }.count
        let meshCap: Int
        switch stationCount {
        case 0..<4: meshCap = 20          // no effective cap
        case 4:     meshCap = 8           // d=4: ~15 s on Apple Silicon
        case 5:     meshCap = 6           // d=5: FEM rapidly infeasible
        default:    meshCap = 4
        }
        let suggestedMesh = min(appSettings.femMeshSize, meshCap)

        // Ask for the quadrature rule and mesh size, then run.
        presentRunParameters(
            .finiteElement(quadrature: appSettings.femSolver,
                           mesh: suggestedMesh,
                           meshCap: meshCap,
                           stations: stationCount),
            onSetDefault: { v in
                appSettings.femSolver = v.int(RunKey.quadrature)
                appSettings.femMeshSize = max(2, v.int(RunKey.mesh))
            },
            onCancel: { activeEditor.addStatus("Finite element run cancelled.", severity: .warning) }
        ) { values in
            runFiniteElement(useGauss: values.int(RunKey.quadrature) == 0,
                             meshSize: max(2, values.int(RunKey.mesh, default: 10)))
        }
    }

    /// Second half of Run ▸ Run Finite Element, once the quadrature rule and
    /// mesh size have been collected.
    private func runFiniteElement(useGauss: Bool, meshSize: Int) {
        let binaryName = useGauss ? "bna_fm_gauss" : "bna_fm_cbc"
        guard let binary = findBinary(name: binaryName, subdirectory: "fBNAfm") else {
            reportBlocked(
                "Finite element aborted: \(binaryName) binary not found.",
                detail: "Could not locate the \(binaryName) binary. Make sure it is compiled (run 'make' in the fBNAfm directory).",
                on: activeEditor
            )
            return
        }

        let result = SRBMExporter.exportForFiniteElement(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers,
            meshSize: meshSize
        )

        switch result {
        case .failure(let error):
            reportBlocked("Finite element aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_fm_\(ProcessInfo.processInfo.processIdentifier).in")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Finite element aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_fm_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let progFile = progressFilePath(label: "fin_fe")
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" \"\(tempFile.path)\" -G -P \"\(progFile)\"",
                stdoutTo: outFile.path,
                label: "Finite Element"
            )
            let runWithBar = withProgress(prefix: "Running finite element method ...  ", command: runCmd, progressFile: progFile)
            let filterCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "Finite Element", varName: "X",
                showGamma: true, showSojourn: true, showXClass: false)
            let command = "\(threadCountBanner(parallel: true)) && _t0=$(perl -MTime::HiRes=time -e 'print time') && \(runWithBar) && echo && \(filterCmd) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')'"
            if let script = silentScript(
                command,
                label: "fm",
                parameters: [
                    "quadrature": useGauss ? "Gauss-Legendre" : "CBC QMC",
                    "mesh per dimension": meshSize.description,
                ]
            ) {
                // A refused launch has already been reported and retired;
                // do not follow it with a "Running …" line that is not true.
                if terminalModel.sendCommand(script) {
                    activeEditor.addStatus("Running finite element (\(useGauss ? "Gauss-Legendre" : "CBC QMC"), mesh=\(meshSize))...", severity: .info)
                }
            }
        }
    }

    /// Runs fBNAlp — the LP-based stationary-distribution solver for SRBM
    /// in a d-dimensional rectangle (Saure-Glynn-Zeevi 2008 extended to
    /// finite buffers). Uses the same SRBMExporter primitives as the FEM
    /// and spectral pipelines.
    private func runFiniteLP() {
        guard let binary = findBinary(name: "fBNAlp_solver", subdirectory: "fBNAlp") else {
            reportBlocked(
                "Finite LP aborted: fBNAlp_solver binary not found.",
                detail: "Could not locate the fBNAlp_solver binary. Make sure it is compiled (run 'make' in the fBNAlp directory).",
                on: activeEditor
            )
            return
        }

        let solverNames = ["highs", "glpk", "cplex"]
        let solver = solverNames[max(0, min(appSettings.flpSolver, solverNames.count - 1))]
        let gridType = appSettings.flpGridType == 1 ? "chebyshev" : "uniform"

        let pid = ProcessInfo.processInfo.processIdentifier
        let outPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_flp_csv_\(pid)").path

        let result = SRBMExporter.exportForFiniteLP(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            gridN: appSettings.flpGridN,
            basisM: appSettings.flpBasisM,
            gridType: gridType,
            solver: solver,
            outputPrefix: outPrefix,
            basisNormalize: appSettings.flpBasisNormalize
        )

        switch result {
        case .failure(let error):
            reportBlocked("Finite LP aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_flp_\(pid).in")
            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Finite LP aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_flp_out_\(pid).txt")
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" --input \"\(tempFile.path)\" --solver \(solver)",
                stdoutTo: outFile.path,
                label: "Finite LP"
            )
            let runWithSpin = withSpinner(prefix: "Running finite LP method (\(solver)) ...  ", command: runCmd)
            let filterCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "Finite LP", varName: "X",
                showGamma: true, showSojourn: true, showXClass: false)
            let cleanupCsv = "rm -f \"\(outPrefix)\"_marginal_*.csv \"\(outPrefix)\"_distribution.csv \"\(tempFile.path)\" \"\(outFile.path)\""
            let command = "\(threadCountBanner(parallel: false)) && _t0=$(perl -MTime::HiRes=time -e 'print time') && \(runWithSpin) && echo && \(filterCmd) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')' && \(cleanupCsv)"
            if let script = silentScript(
                command,
                label: "flp",
                parameters: [
                    "solver": solver,
                    "grid type": gridType,
                    "grid size": appSettings.flpGridN == 0 ? "auto" : appSettings.flpGridN.description,
                    "basis size": appSettings.flpBasisM == 0 ? "auto" : appSettings.flpBasisM.description,
                    "basis normalization": appSettings.flpBasisNormalize.description,
                ]
            ) {
                // A refused launch has already been reported and retired;
                // do not follow it with a "Running …" line that is not true.
                if terminalModel.sendCommand(script) {
                    activeEditor.addStatus("Running finite LP (\(solver))...", severity: .info)
                }
            }
        }
    }

    /// Runs the class-aware workload SRBM solver
    /// (`infinite/BNAmd/mc_solver`).
    /// Differs from the production FEM path: mc_solver parses the .bnet JSON
    /// directly (not SRBMExporter output), and uses compound service-time and
    /// per-class routing-variance formulas with a Harrison-Reiman reflection
    /// matrix on infinite-buffer networks.
    private func runMultiClassSRBM() {
        guard activeEditor.infiniteBuffers else {
            reportBlocked(
                "Multi-class SRBM aborted: the network has finite buffers.",
                detail: "The class-aware workload diffusion is defined for infinite-buffer networks. Use finite queue simulation or an explicitly bounded SRBM method for this network.",
                on: activeEditor
            )
            return
        }
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "mc_solver", subdirectory: "BNAmd"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "Multi-class SRBM aborted: mc_solver binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        // Ask for the formulation and mesh size, then run.
        presentRunParameters(
            .multiClassSRBM(),
            onCancel: { activeEditor.addStatus("Multi-class SRBM run cancelled.", severity: .warning) }
        ) { values in
            runMultiClassSRBM(binary: binary,
                              useLegacy: values.int(RunKey.formulation) == 1,
                              meshSize: max(0, values.int(RunKey.mesh)))
        }
    }

    /// Second half of Run ▸ Run Multi-Class SRBM, once the formulation and
    /// mesh size have been collected.
    private func runMultiClassSRBM(binary: URL, useLegacy: Bool, meshSize: Int) {
        // mc_solver parses the .bnet JSON directly, so we serialize the
        // current canvas state to a temp file.
        let document = NetworkDocument(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers,
            canvasScale: activeEditor.canvasScale
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let bnetData: Data
        do {
            bnetData = try encoder.encode(document)
        } catch {
            reportBlocked(
                "Multi-class SRBM aborted: could not serialize network.",
                detail: error.localizedDescription,
                on: activeEditor
            )
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_mc_\(pid).bnet")

        do {
            try bnetData.write(to: tempFile, options: .atomic)
        } catch {
            reportBlocked(
                "Multi-class SRBM aborted: could not write temp file.",
                detail: error.localizedDescription,
                on: activeEditor
            )
            return
        }

        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_mc_out_\(pid).txt")

        var flags = "-G"
        if useLegacy { flags += " --legacy-params" }
        if meshSize > 0 { flags += " -n \(meshSize)" }

        let runCmd = runWithStderrOnFailure(
            "\"\(binary.path)\" \(flags) \"\(tempFile.path)\"",
            stdoutTo: outFile.path,
            label: "Multi-Class SRBM"
        )
        let filterCmd = singleMethodFormatCmd(
            outFile: outFile.path, methodLabel: "Multi-Class SRBM", varName: "X",
            showGamma: true, showSojourn: true, showXClass: false)
        let flavorLabel = useLegacy ? "legacy" : "research"
        let meshLabelText = meshSize > 0 ? "mesh=\(meshSize)" : "mesh=auto"
        let command = "_t0=$(perl -MTime::HiRes=time -e 'print time') && printf 'Running multi-class SRBM (\(flavorLabel), \(meshLabelText)) ... ' && \(runCmd) && echo done. && echo && \(filterCmd) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')'"
        if let script = silentScript(
            command,
            label: "mc",
            parameters: [
                "formulation": flavorLabel,
                "mesh per dimension": meshSize > 0 ? meshSize.description : "auto",
            ]
        ) {
            // A refused launch has already been reported and retired;
            // do not follow it with a "Running …" line that is not true.
            if terminalModel.sendCommand(script) {
                activeEditor.addStatus("Running multi-class SRBM (\(flavorLabel), \(meshLabelText))...", severity: .info)
            }
        }
    }

    private func runSpectralMethod() {
        // Ask for the polynomial degree and basis, then run.
        presentRunParameters(
            .spectralFinite(degree: appSettings.smDegree, legendre: appSettings.smLegendre),
            onSetDefault: { v in
                appSettings.smDegree = max(2, v.int(RunKey.degree))
                appSettings.smLegendre = v.flag(RunKey.legendre)
            },
            onCancel: { activeEditor.addStatus("Spectral method run cancelled.", severity: .warning) }
        ) { values in
            runSpectralMethod(degree: max(2, values.int(RunKey.degree, default: 8)),
                              useLegendre: values.flag(RunKey.legendre))
        }
    }

    /// Second half of Run ▸ Run Spectral Method (finite buffers), once the
    /// degree and basis have been collected.
    private func runSpectralMethod(degree: Int, useLegendre: Bool) {
        // The chosen basis is used for THIS run only. Writing it back to
        // appSettings here made ticking Legendre once change the default
        // for every later run, while the degree beside it did not — two
        // persistence rules in one dialog, and it made the sheet's
        // explicit "Set as Default" button redundant for that one field.
        guard let binary = findBinary(name: "srbm_solver", subdirectory: "fBNAsm") else {
            reportBlocked(
                "Spectral method aborted: srbm_solver binary not found.",
                detail: "Could not locate the srbm_solver binary. Make sure it is compiled (run 'make' in the fBNAsm directory).",
                on: activeEditor
            )
            return
        }

        let result = SRBMExporter.exportForSpectral(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers,
            degree: degree
        )

        switch result {
        case .failure(let error):
            reportBlocked(
                "Spectral method aborted: \(error.localizedDescription)",
                on: activeEditor
            )

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_sm_\(ProcessInfo.processInfo.processIdentifier).in")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Spectral method aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_sm_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let progFile = progressFilePath(label: "fin_sm")
            let legendreFlag = useLegendre ? " -L" : ""
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" \"\(tempFile.path)\" -G -P \"\(progFile)\"\(legendreFlag)",
                stdoutTo: outFile.path,
                label: "Spectral Method"
            )
            let runWithBar = withProgress(prefix: "Running spectral method ...  ", command: runCmd, progressFile: progFile)
            let filterCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "Spectral", varName: "X",
                showGamma: true, showSojourn: true, showXClass: false)
            let basisLabel = useLegendre ? ", Legendre" : ""
            let command = "\(threadCountBanner(parallel: true)) && _t0=$(perl -MTime::HiRes=time -e 'print time') && \(runWithBar) && echo && \(filterCmd) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')'"
            if let script = silentScript(
                command,
                label: "sm",
                parameters: [
                    "polynomial degree": degree.description,
                    "basis": useLegendre ? "Legendre" : "monomial",
                ]
            ) {
                // A refused launch has already been reported and retired;
                // do not follow it with a "Running …" line that is not true.
                if terminalModel.sendCommand(script) {
                    activeEditor.addStatus("Running spectral method (degree=\(degree)\(basisLabel))...", severity: .info)
                }
            }
        }
    }

    private func runComparison() {
        // Find all three binaries
        guard let smBinary = findBinary(name: "srbm_solver", subdirectory: "fBNAsm") else {
            reportBlocked(
                "Comparison aborted: srbm_solver binary not found.",
                detail: "Could not locate the srbm_solver binary. Make sure it is compiled (run 'make' in the fBNAsm directory).",
                on: activeEditor
            )
            return
        }

        let fmBinaryName = appSettings.femSolver == 0 ? "bna_fm_gauss" : "bna_fm_cbc"
        let fmLabel = appSettings.femSolver == 0 ? "FE (Gauss)" : "FE (CBC)"
        guard let fmBinary = findBinary(name: fmBinaryName, subdirectory: "fBNAfm") else {
            reportBlocked(
                "Comparison aborted: \(fmBinaryName) binary not found.",
                detail: "Could not locate the \(fmBinaryName) binary. Make sure it is compiled (run 'make' in the fBNAfm directory).",
                on: activeEditor
            )
            return
        }

        guard let mcBinary = findFBNAsimBinary() else {
            reportBlocked(
                "Comparison aborted: fBNAsim binary not found.",
                detail: "Could not locate the fBNAsim binary. Make sure it is compiled (run 'make' in the fBNAsim directory).",
                on: activeEditor
            )
            return
        }

        // Optional: fBNAlp (finite LP). Missing binary degrades gracefully —
        // the comparison runs without an LP column rather than aborting.
        let lpBinary = findBinary(name: "fBNAlp_solver", subdirectory: "fBNAlp")

        // Ask the user which blocking regime the simulation should run in
        // (unless they previously ticked "Remember choice" — in which case
        // reuse the saved simBlocking silently). Spectral / FE results are
        // always for the SRBM (manufacturing blocking, offered arrival
        // rate α); the match against the simulation depends on which
        // physical queueing model the sim implements.
        //
        // Read the "remember" flag straight from UserDefaults — @AppStorage
        // in an ObservableObject class is not always reactive to fresh
        // writes made from another view, so going through the canonical
        // store avoids stale reads. Default is `false` (prompt) if the key
        // has never been set.
        let remember = UserDefaults.standard.bool(forKey: "runCompare.remember")

        if remember {
            // Silent mode — use the stored Default Choice.
            runComparison(chosenBlocking: appSettings.simBlocking, smBinary: smBinary,
                          fmBinary: fmBinary, fmLabel: fmLabel, mcBinary: mcBinary,
                          lpBinary: lpBinary)
        } else {
            presentRunParameters(
                .comparisonBlocking(blocking: appSettings.simBlocking),
                onCancel: { activeEditor.addStatus("Comparison cancelled.", severity: .warning) }
            ) { values in
                if values.flag(RunKey.remember) {
                    // Save both the flag AND the chosen option — the Settings
                    // pane's "Default Choice" dropdown reads the same
                    // simBlocking key, so it'll reflect this selection.
                    // Re-enable the prompt from Settings ▸ General — uncheck
                    // "Remember choice".
                    appSettings.rememberRunComparisonChoice = true
                    UserDefaults.standard.set(true, forKey: "runCompare.remember")
                    // Only now is the regime a *default*. Picking one for a
                    // single comparison used to overwrite the stored choice
                    // silently, which made the dialog's own opt-in
                    // meaningless.
                    appSettings.simBlocking = values.int(RunKey.blocking)
                    UserDefaults.standard.set(values.int(RunKey.blocking), forKey: "sim.blocking")
                }
                runComparison(chosenBlocking: values.int(RunKey.blocking), smBinary: smBinary,
                              fmBinary: fmBinary, fmLabel: fmLabel, mcBinary: mcBinary,
                              lpBinary: lpBinary)
            }
        }
    }

    /// Second half of Run ▸ Run Comparison (finite buffers), once the
    /// simulation's blocking regime is known. Every solver invocation below
    /// is unchanged.
    /// `chosenBlocking` governs this run only; it is written back to
    /// `appSettings.simBlocking` by the caller, and only when the user
    /// ticked "Skip this dialog from now on".
    private func runComparison(chosenBlocking: Int, smBinary: URL, fmBinary: URL,
                               fmLabel: String, mcBinary: URL, lpBinary: URL?) {
        let (chosenBlockingFlag, chosenBlockingDesc): (String, String) = {
            switch chosenBlocking {
            case 0:  return (" -l", "loss")
            case 2:  return (" -e", "BAS+ext-loss")
            default: return ("",    "BAS")
            }
        }()

        // For Loss-mode comparisons (`-l`) the SRBM exporter applies an
        // M/M/1/K-style throughput correction so the SRBM drift reflects
        // post-rejection arrivals. For BAS / BAS+ExtLoss it instead
        // applies a back-pressure approximation that inflates effective
        // service time at upstream stations when downstream buffers fill.
        // Both corrections live in SRBMExporter.computeData and are
        // mutually exclusive; infinite-buffer runs skip both.
        let lossCorrect = (chosenBlocking == 0) && !activeEditor.infiniteBuffers
        let basCorrect  = (chosenBlocking != 0) && !activeEditor.infiniteBuffers

        // Heavy-traffic + BAS warning. The SRBM hypercube model with
        // continuous upper-face reflection is closer to "production
        // blocking with infinite-server downstream" than to true BAS;
        // at near-saturation (ρ > 0.97) the algorithms typically
        // under-predict queue means by ~10% against a BAS simulator
        // because they don't model back-pressure. Surface this as a
        // status note up-front so the user isn't surprised by the
        // deltas they'll see. Only emit for finite-buffer runs in
        // BAS / BAS+ExtLoss mode; the Loss correction handles the
        // -l case.
        if !activeEditor.infiniteBuffers && chosenBlocking != 0 {
            switch SRBMExporter.computeData(
                nodes: activeEditor.nodes,
                links: activeEditor.links,
                infiniteBuffers: false
            ) {
            case .success(let d):
                var hotStations: [String] = []
                for i in 0..<d.d where d.capacity[i] > 1e-12 {
                    if d.alpha[i] / d.capacity[i] > 0.97 {
                        hotStations.append("S\(i + 1)")
                    }
                }
                if !hotStations.isEmpty {
                    activeEditor.addStatus(
                        "Warning: \(hotStations.joined(separator: ", ")) at ρ > 0.97 with "
                      + "sim blocking = \(chosenBlockingDesc). Continuous-reflection SRBM "
                      + "doesn't model BAS back-pressure — expect the algorithm columns to "
                      + "under-predict queue means by roughly 10%. Pick Loss in the popup "
                      + "for tighter agreement, or see Help ▸ Test Sets ▸ BAS vs Loss.")
                }
            case .failure:
                break  // exporter will error out below; warning is best-effort.
            }
        }

        // Export SM/FM input (SRBM format with saved defaults)
        let smResult = SRBMExporter.exportForSpectral(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers,
            degree: appSettings.smDegree,
            lossModeCorrection: lossCorrect,
            basModeCorrection: basCorrect
        )
        guard case .success(let smContent) = smResult else {
            if case .failure(let error) = smResult {
                reportBlocked("Comparison aborted: \(error.localizedDescription)", on: activeEditor)
            }
            return
        }

        // Apply the same dimension-aware mesh cap used in runFiniteElement
        // so the FEM step of the comparison completes in reasonable time
        // on high-dimensional networks.
        let fmStationCount = activeEditor.nodes.filter { $0.kind == .station }.count
        let fmMeshCap: Int
        switch fmStationCount {
        case 0..<4: fmMeshCap = 20
        case 4:     fmMeshCap = 8
        case 5:     fmMeshCap = 6
        default:    fmMeshCap = 4
        }
        let fmMesh = min(appSettings.femMeshSize, fmMeshCap)

        let fmResult = SRBMExporter.exportForFiniteElement(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers,
            meshSize: fmMesh,
            lossModeCorrection: lossCorrect,
            basModeCorrection: basCorrect
        )
        guard case .success(let fmContent) = fmResult else {
            if case .failure(let error) = fmResult {
                reportBlocked("Comparison aborted: \(error.localizedDescription)", on: activeEditor)
            }
            return
        }

        // Export MC input (network format)
        let mcResult = NetworkExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)
        guard case .success(let mcContent) = mcResult else {
            if case .failure(let error) = mcResult {
                reportBlocked("Comparison aborted: \(error.localizedDescription)", on: activeEditor)
            }
            return
        }

        // Export fBNAlp input (only if the binary was located).
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmpDir = FileManager.default.temporaryDirectory
        let lpCsvPrefix = tmpDir.appendingPathComponent("BNET_cmp_lp_csv_\(pid)").path
        let lpSolverNames = ["highs", "glpk", "cplex"]
        let lpSolver = lpSolverNames[max(0, min(appSettings.flpSolver, lpSolverNames.count - 1))]
        let lpGridType = appSettings.flpGridType == 1 ? "chebyshev" : "uniform"

        var lpContent: String? = nil
        if lpBinary != nil {
            let r = SRBMExporter.exportForFiniteLP(
                nodes: activeEditor.nodes,
                links: activeEditor.links,
                gridN: appSettings.flpGridN,
                basisM: appSettings.flpBasisM,
                gridType: lpGridType,
                solver: lpSolver,
                outputPrefix: lpCsvPrefix,
                basisNormalize: appSettings.flpBasisNormalize,
                lossModeCorrection: lossCorrect,
                basModeCorrection: basCorrect
            )
            if case .success(let s) = r { lpContent = s }
            else if case .failure(let error) = r {
                activeEditor.addStatus("Comparison: skipping LP — \(error.localizedDescription)")
            }
        }

        // Write temp files
        let smFile = tmpDir.appendingPathComponent("BNET_cmp_sm_\(pid).in")
        let fmFile = tmpDir.appendingPathComponent("BNET_cmp_fm_\(pid).in")
        let mcFile = tmpDir.appendingPathComponent("BNET_cmp_mc_\(pid).txt")
        let lpFile = tmpDir.appendingPathComponent("BNET_cmp_lp_\(pid).in")

        do {
            try smContent.write(to: smFile, atomically: true, encoding: .utf8)
            try fmContent.write(to: fmFile, atomically: true, encoding: .utf8)
            try mcContent.write(to: mcFile, atomically: true, encoding: .utf8)
            if let s = lpContent {
                try s.write(to: lpFile, atomically: true, encoding: .utf8)
            }
        } catch {
            reportBlocked(
                "Comparison aborted: could not write temp files.",
                detail: error.localizedDescription,
                on: activeEditor
            )
            return
        }

        // Build compound command: run all three with -G to output files, then format with awk
        var mcParallelFlag = ""
        switch appSettings.simParallel {
        case 0: mcParallelFlag = " -a"   // Apple GCD
        case 1: mcParallelFlag = " -o"   // OpenMP
        default: break                   // Sequential
        }
        // Use the blocking regime the user just picked in the dialog
        // above (chosenBlockingFlag / chosenBlockingDesc).
        let mcBlockingFlag = chosenBlockingFlag
        let comparisonSeed = appSettings.simSeedFixed
            ? max(0, appSettings.simSeed)
            : Int.random(in: 1...Int(Int32.max))

        let smOut = tmpDir.appendingPathComponent("BNET_cmp_sm_out_\(pid).txt")
        let fmOut = tmpDir.appendingPathComponent("BNET_cmp_fm_out_\(pid).txt")
        let mcOut = tmpDir.appendingPathComponent("BNET_cmp_mc_out_\(pid).txt")
        let lpOut = tmpDir.appendingPathComponent("BNET_cmp_lp_out_\(pid).txt")

        // Run all three programs with progress messages.
        // runWithStderrOnFailure replaces the prior `2>/dev/null` so
        // a failing solver dumps its stderr to the shell pane (where
        // the memory-cap diagnostic and other errors live).
        //
        // Pad every per-algo prefix to a uniform width so the bars
        // line up vertically across the comparison output. Width is
        // computed from the actual labels in this run (LP solver name
        // is variable, so dynamic is more robust than a hard-coded
        // constant).
        let haveLP = (lpBinary != nil && lpContent != nil)
        let cmpLabels: [String] = {
            var v = ["Running spectral method ...",
                     "Running finite element method ...",
                     "Running simulation ..."]
            if haveLP { v.append("Running finite LP method (\(lpSolver)) ...") }
            return v
        }()
        let cmpWidth = (cmpLabels.map(\.count).max() ?? 0) + 2
        let pad: (String) -> String = { s in
            s + String(repeating: " ", count: max(0, cmpWidth - s.count))
        }

        let smProgFile = progressFilePath(label: "fin_cmp_sm")
        let smRaw = runWithStderrOnFailure(
            "\"\(smBinary.path)\" \"\(smFile.path)\" -G -P \"\(smProgFile)\"",
            stdoutTo: smOut.path,
            label: "Spectral Method")
        let runSM = withProgress(prefix: pad("Running spectral method ..."), command: smRaw, progressFile: smProgFile)
        let fmProgFile = progressFilePath(label: "fin_cmp_fm")
        let fmRaw = runWithStderrOnFailure(
            "\"\(fmBinary.path)\" \"\(fmFile.path)\" -G -P \"\(fmProgFile)\"",
            stdoutTo: fmOut.path,
            label: "Finite Element")
        let runFM = withProgress(prefix: pad("Running finite element method ..."), command: fmRaw, progressFile: fmProgFile)
        let mcProgFile = progressFilePath(label: "fin_cmp_mc")
        let mcRaw = runWithStderrOnFailure(
            "\"\(mcBinary.path)\" -f \"\(mcFile.path)\" -G -n \(appSettings.simReplications) -w \(appSettings.simWarmup) -T \(appSettings.simTime) -s \(comparisonSeed) -P \"\(mcProgFile)\"\(mcParallelFlag)\(mcBlockingFlag)",
            stdoutTo: mcOut.path,
            label: "Simulation")
        let runMC = withProgress(prefix: pad("Running simulation ..."), command: mcRaw, progressFile: mcProgFile)
        // The fBNAlp solver writes srbm_out_*.csv files to its cwd unless we
        // override `output_prefix` (we do, into /tmp). Clean those up after
        // the LP step so the comparison leaves no artifacts behind.
        let runLP: String? = haveLP ? {
            let cmd = runWithStderrOnFailure(
                "\"\(lpBinary!.path)\" --input \"\(lpFile.path)\" --solver \(lpSolver) -c",
                stdoutTo: lpOut.path,
                label: "Finite LP")
            return withSpinner(prefix: pad("Running finite LP method (\(lpSolver)) ..."), command: cmd)
        }() : nil

        // CTMC reference (optional). Single-class M/M/1 loss tandems
        // with d ≤ 4 and very small buffers fit a state space the direct
        // dense CTMC solver (ctmc_dtandem.py) can handle safely. When the
        // network qualifies we add a "CTMC (exact loss)" column ahead of
        // simulation so the algorithms have a noise-free reference.
        // Multi-class, non-exponential, or non-tandem networks fall
        // back to no CTMC column. Dense state-space cap = 1,000.
        let ctmcOut = tmpDir.appendingPathComponent("BNET_cmp_ctmc_out_\(pid).txt")
        var runCTMC: String? = nil
        var ctmcLabel: String? = nil
        var ctmcRuntimeProvenance = "omitted"
        if let plan = buildCTMCRunCommand(
            blocking: chosenBlocking, outputPath: ctmcOut.path,
            spinnerPad: pad
        ) {
            runCTMC = plan.command
            ctmcLabel = "CTMC (exact loss)"
            ctmcRuntimeProvenance = plan.runtimeProvenance
        }

        // awk script: unified builder adds an "Exact Result" column when the
        // network is tractable, shifting every delta to use the analytical
        // value as the reference for E[X_k].
        let analyticalPath = writeAnalyticalFile(varName: "X")
        var outputs: [(file: String, label: String)] = [
            (file: smOut.path, label: "Spectral"),
            (file: fmOut.path, label: fmLabel),
        ]
        if runLP != nil {
            outputs.append((file: lpOut.path, label: "Finite LP"))
        }
        if let label = ctmcLabel {
            outputs.append((file: ctmcOut.path, label: label))
        }
        outputs.append((file: mcOut.path, label: "Simulation"))
        let awkScript = buildComparisonAwk(
            outputs: outputs,
            varName: "X",
            showGamma: true,
            showSojourn: true,
            showXClass: false,
            analyticalPath: analyticalPath,
            analyticalLabel: activeEditor.tractabilityMeansLabel,
            analyticalIsExact: activeEditor.tractabilityIsExact,
            showAverageAlgorithm: true
        )
        let hdr = tractabilityHeader()
        let regime = regimeHeader(infiniteBuffers: false)
        let bannerParts = [regime, hdr].filter { !$0.isEmpty }
        let hdrPrefix = bannerParts.isEmpty ? "" : "\(bannerParts.joined(separator: " && ")) && "

        let runChain = [runSM, runFM, runLP, runCTMC, runMC].compactMap { $0 }.joined(separator: " && ")
        let cleanupCsv = "rm -f \"\(lpCsvPrefix)\"_marginal_*.csv \"\(lpCsvPrefix)\"_distribution.csv"
        let command = "\(threadCountBannerMixed()) && _t0=$(perl -MTime::HiRes=time -e 'print time') && \(runChain) && echo && \(hdrPrefix)\(awkScript) && \(cleanupCsv) && perl -MTime::HiRes=time -e 'printf(\"Elapsed time: %.3fs\\n\\n\", time - '$_t0')'"

        if let script = silentScript(
            command,
            label: "cmp",
            parameters: [
                "blocking": chosenBlockingDesc,
                "spectral degree": appSettings.smDegree.description,
                "finite-element mesh": fmMesh.description,
                "simulation replications": appSettings.simReplications.description,
                "simulation warm-up": appSettings.simWarmup.description,
                "simulation time": appSettings.simTime.description,
                "exact CTMC runtime": ctmcRuntimeProvenance,
            ],
            seed: UInt64(comparisonSeed),
            replicationSeeds: (0..<appSettings.simReplications).map {
                UInt64(comparisonSeed + $0 / 2)
            }
        ) {
            // A refused launch has already been reported and retired;
            // do not follow it with a "Running …" line that is not true.
            if terminalModel.sendCommand(script) {
                let chain = runLP != nil ? "SM → FM → LP → MC" : "SM → FM → MC"
                activeEditor.addStatus("Running comparison (\(chain), sim blocking = \(chosenBlockingDesc))...", severity: .info)
            }
        }
    }

    // MARK: - Infinite Buffer Run Functions

    private func runSimulationInfinite() {
        let result = BNANetworkExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked(
                "Simulation (infinite) aborted: \(error.localizedDescription)",
                on: activeEditor
            )
            return

        case .success(let content):
            let lookup = SolverRuntimeResolver.shared.resolveExecutable(
                name: "jackson_sim", subdirectory: "BNAsim"
            )
            guard let binary = lookup.url else {
                reportBlocked(
                    "Simulation (infinite) aborted: jackson_sim binary not found.",
                    detail: lookup.actionableDiagnostic,
                    on: activeEditor
                )
                return
            }

            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_inf_sim_\(ProcessInfo.processInfo.processIdentifier).sim")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Simulation (infinite) aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            // Ask for the run length in the shared DSSheet form; the launch
            // logic below is unchanged.
            presentRunParameters(
                .monteCarloInfinite(replications: appSettings.simReplications,
                                    warmup: appSettings.simWarmup,
                                    simTime: appSettings.simTime,
                                    seedFixed: appSettings.simSeedFixed,
                                    seed: appSettings.simSeed),
                onSetDefault: { v in
                    appSettings.simReplications = max(1, v.int(RunKey.replications))
                    appSettings.simWarmup = max(0, v.int(RunKey.warmup))
                    appSettings.simTime = max(1, v.int(RunKey.simTime))
                    appSettings.simSeedFixed = v.flag(RunKey.seedFixed)
                    appSettings.simSeed = max(0, v.int(RunKey.seed))
                },
                onCancel: { activeEditor.addStatus("Simulation (infinite) cancelled.", severity: .warning) }
            ) { values in
                let numRuns = max(1, values.int(RunKey.replications, default: 50))
                let warmup = max(0, values.int(RunKey.warmup, default: 1_000_000))
                let simTime = max(1, values.int(RunKey.simTime, default: 5_000_000))
                let fixedSeed = values.flag(RunKey.seedFixed)
                let enteredSeed = max(0, values.int(
                    RunKey.seed, default: AppSettings.Defaults.simSeed
                ))
                let baseSeed = fixedSeed
                    ? enteredSeed : Int.random(in: 1...Int(Int32.max))

                let outFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BNET_inf_sim_out_\(ProcessInfo.processInfo.processIdentifier).txt")
                let progFile = progressFilePath(label: "inf_sim")
                let outputCmd = singleMethodFormatCmd(
                    outFile: outFile.path, methodLabel: "Simulation", varName: "Q",
                    showGamma: true, showSojourn: true, showXClass: false)
                let runCmd = runWithStderrOnFailure(
                    "\"\(binary.path)\" \"\(tempFile.path)\" -c -n \(numRuns) -w \(warmup) -r \(simTime) -s \(baseSeed) -P \"\(progFile)\"",
                    stdoutTo: outFile.path,
                    label: "Simulation (infinite)"
                )
                let runWithBar = withProgress(prefix: "Running simulation ...  ", command: runCmd, progressFile: progFile)
                let command = "\(threadCountBanner(parallel: true)) && \(runWithBar) && echo && \(outputCmd)"
                if runScript(
                    command,
                    label: "inf_sim",
                    parameters: [
                        "replications": numRuns.description,
                        "warm-up": warmup.description,
                        "simulation time": simTime.description,
                        "fixed seed": fixedSeed.description,
                    ],
                    seed: UInt64(baseSeed),
                    replicationSeeds: (0..<numRuns).map { UInt64(baseSeed + $0) }
                ) {
                    activeEditor.addStatus("Running simulation (infinite) via jackson_sim...", severity: .info)
                }
            }
        }
    }

    /// Conservative cost guard for the polynomial spectral system.  The
    /// implementation materializes a dense matrix whose side is the number
    /// of total-degree monomials, C(d+p,p); checking that quantity prevents
    /// an innocent default from requesting tens of gigabytes.
    private func spectralResourceIssue(dimension d: Int, degree p: Int) -> String? {
        guard d > 0, p > 0 else { return nil }
        func basisCount(_ degree: Int) -> Double {
            guard degree > 0 else { return 1 }
            var value = 1.0
            for k in 1...degree {
                value *= Double(d + k) / Double(k)
            }
            return value
        }
        let basis = basisCount(p)
        let bytes = basis * basis * 8.0
        let limit = 2.0 * 1024.0 * 1024.0 * 1024.0
        guard !bytes.isFinite || bytes > limit else { return nil }

        var safeDegree: Int?
        if p >= 2 {
            for candidate in 2...p where basisCount(candidate) * basisCount(candidate) * 8.0 <= limit {
                safeDegree = candidate
            }
        }
        let basisText = basis.formatted(.number.precision(.significantDigits(3)))
        let memoryText = bytes.isFinite
            ? ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max))), countStyle: .memory)
            : "more than addressable memory"
        let alternative = safeDegree.map {
            "Try degree \($0) or lower, or use Adaptive Low-Rank BAR / product form when applicable."
        } ?? "No degree of at least 2 fits the safety budget; use Adaptive Low-Rank BAR, MLMC, or product form instead."
        return "For d=\(d) and degree \(p), the spectral basis has about \(basisText) terms and its dense matrix alone needs about \(memoryText). The 2 GB safety limit prevents this run. \(alternative)"
    }

    /// Estimates the tensor-grid and boundary/slack columns constructed by
    /// BNAlp.  This is deliberately checked before an input file or giant
    /// allocation is made.
    private func linearProgramResourceIssue(
        dimension d: Int,
        gridSize n: Int,
        smoothness: Double
    ) -> String? {
        guard d > 0, n >= 2 else { return nil }
        func power(_ base: Double, _ exponent: Int) -> Double {
            guard exponent > 0 else { return 1 }
            var result = 1.0
            for _ in 0..<exponent {
                result *= base
                if !result.isFinite { return .infinity }
            }
            return result
        }
        let interior = power(Double(n), d)
        let perFace = power(Double(n), d - 1)
        let boundary = Double(d) * perFace
        let slack = smoothness > 0
            ? Double(d * (n - 1)) * perFace
            : 0
        let columns = interior + boundary + slack + 1
        let safeColumnLimit = 2_000_000.0
        guard !columns.isFinite || columns > safeColumnLimit else { return nil }
        let countText = columns.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
        let smoothText = smoothness > 0 ? " including smoothness slacks" : ""
        return "For d=\(d) and grid_n=\(n), BNAlp would create about \(countText) variables\(smoothText), above the 2 million-variable safety limit. Reduce grid_n or smoothness, or use Adaptive Low-Rank BAR / MLMC. Tensor-grid LP is not practical at this scale."
    }

    private func runSpectralMethodInfinite() {
        // Ask for the polynomial degree, then run.
        presentRunParameters(
            .spectralInfinite(degree: appSettings.smDegree),
            onSetDefault: { v in appSettings.smDegree = max(2, v.int(RunKey.degree)) },
            onCancel: { activeEditor.addStatus("Spectral method (infinite) cancelled.", severity: .warning) }
        ) { values in
            runSpectralMethodInfinite(degree: max(2, values.int(RunKey.degree, default: 8)))
        }
    }

    /// Second half of Run ▸ Run Spectral Method (infinite buffers), once the
    /// degree has been collected.
    private func runSpectralMethodInfinite(degree: Int) {
        let dimension = activeEditor.nodes.filter { $0.kind == .station }.count
        if let issue = spectralResourceIssue(dimension: dimension, degree: degree) {
            reportBlocked(
                "Spectral method not started: \(issue)",
                severity: .warning,
                on: activeEditor
            )
            return
        }
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "bnet", subdirectory: "BNAsm"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "Spectral method (infinite) aborted: bnet binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        let result = BNASRBMExporter.exportForSpectral(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            degree: degree
        )

        switch result {
        case .failure(let error):
            reportBlocked(
                "Spectral method (infinite) aborted: \(error.localizedDescription)",
                on: activeEditor
            )

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_inf_sm_\(ProcessInfo.processInfo.processIdentifier).in")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Spectral method (infinite) aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_inf_sm_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let outputCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "Spectral", varName: "Q",
                showGamma: true, showSojourn: true, showXClass: false)
            let progFile = progressFilePath(label: "inf_sm")
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" -c -P \"\(progFile)\" \"\(tempFile.path)\"",
                stdoutTo: outFile.path,
                label: "Spectral Method (infinite)"
            )
            let runWithBar = withProgress(prefix: "Running spectral method ...  ", command: runCmd, progressFile: progFile)
            let command = "\(threadCountBanner(parallel: true)) && \(runWithBar) && echo && \(outputCmd)"
            if runScript(
                command,
                label: "inf_sm",
                parameters: ["polynomial degree": degree.description]
            ) {
                activeEditor.addStatus("Running spectral method (infinite, degree=\(degree))...", severity: .info)
            }
        }
    }

    private func runQNA() {
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "bna_qna", subdirectory: "BNAqna"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "QNA aborted: bna_qna binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        let result = QNAExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("QNA aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_qna_\(ProcessInfo.processInfo.processIdentifier).qna")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "QNA aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_qna_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let outputCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "QNA", varName: "Q",
                showGamma: true, showSojourn: true, showXClass: false)
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" \"\(tempFile.path)\" -c",
                stdoutTo: outFile.path,
                label: "QNA"
            )
            let runWithSpin = withSpinner(prefix: "Running QNA ...  ", command: runCmd)
            let command = "\(threadCountBanner(parallel: false)) && \(runWithSpin) && echo && \(outputCmd)"
            if runScript(command, label: "qna") {
                activeEditor.addStatus("Running QNA...", severity: .info)
            }
        }
    }

    private func runRQNA() {
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "bna_rqna", subdirectory: "BNArqna"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "RQNA aborted: bna_rqna binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        let result = QNAExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("RQNA aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_rqna_\(ProcessInfo.processInfo.processIdentifier).qna")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "RQNA aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_rqna_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let outputCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "RQNA", varName: "Q",
                showGamma: true, showSojourn: true, showXClass: false)
            let runCmd = runWithStderrOnFailure(
                "\"\(binary.path)\" \"\(tempFile.path)\" -c",
                stdoutTo: outFile.path,
                label: "RQNA"
            )
            let runWithSpin = withSpinner(prefix: "Running RQNA ...  ", command: runCmd)
            let command = "\(threadCountBanner(parallel: false)) && \(runWithSpin) && echo && \(outputCmd)"
            if runScript(command, label: "rqna") {
                activeEditor.addStatus("Running RQNA...", severity: .info)
            }
        }
    }

    private func runSBD() {
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "bna_sbd", subdirectory: "BNAsbd"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "SBD aborted: bna_sbd binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        let spectralBinary = findBinary(name: "bnet", subdirectory: "BNAsm")
        if spectralBinary == nil {
            activeEditor.addStatus(
                "SBD dependency warning: bnet is unavailable. Multi-station subnetworks will be reported as partial fallback results.",
                severity: .warning
            )
        }

        let result = QNAExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)

        switch result {
        case .failure(let error):
            reportBlocked("SBD aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let content):
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_sbd_\(ProcessInfo.processInfo.processIdentifier).qna")

            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "SBD aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_sbd_out_\(ProcessInfo.processInfo.processIdentifier).txt")
            let outputCmd = singleMethodFormatCmd(
                outFile: outFile.path, methodLabel: "SBD", varName: "Q",
                showGamma: true, showSojourn: true, showXClass: false)
            let bnetEnvironment = spectralBinary.map {
                "BNET_BIN=\(shellQuote($0.path)) "
            } ?? ""
            let runCmd = runWithStderrOnFailure(
                "\(bnetEnvironment)\"\(binary.path)\" \"\(tempFile.path)\" -c",
                stdoutTo: outFile.path,
                label: "SBD"
            )
            let runWithSpin = withSpinner(prefix: "Running SBD ...  ", command: runCmd)
            let statusCmd = "grep '^QNET_SBD_STATUS_V1' \(shellQuote(outFile.path)) || true"
            let command = "\(threadCountBanner(parallel: false)) && \(runWithSpin) && echo && \(outputCmd) && \(statusCmd)"
            if runScript(command, label: "sbd") {
                activeEditor.addStatus("Running SBD...", severity: .info)
            }
        }
    }

    // MARK: - SRBM MLMC (Blanchet-Chen-Glynn-Si 2021)
    //
    // BNAmc / rbm_mlmc implements a two-parameter multilevel Monte Carlo
    // estimator for the stationary mean of a reflected Brownian motion in
    // the positive orthant.  The input file format is:
    //   d
    //   mu_1 ... mu_d
    //   Sigma row 1
    //   ...
    //   Sigma row d
    //   R row 1
    //   ...
    //   R row d
    //
    // This is exactly BNASRBMExporter.formatStandard (via export()).  The SRBM
    // produced by BNASRBMExporter is in WORKLOAD units (theta = Rho - 1, Gamma
    // with the tau scaling); the raw output E[Y_i] is mean workload.
    // To report a mean-queue-length figure consistent with QNA/SBD, we post-
    // process the output by scaling E[Y_i] with the effective service rate
    // mu_eff_i = 1 / tau_i (computed in the exporter and embedded as a
    // trailing comment in the input file below for the awk stage).
    private struct MLMCCostPreview {
        let pathLength: Double
        let levels: Int
    }

    private func mlmcCostPreview(
        data: BNASRBMExporter.BNASRBMData,
        gamma: Double,
        epsilon: Double
    ) -> MLMCCostPreview? {
        guard data.d > 0, gamma > 0, gamma < 1,
              epsilon > 0, epsilon <= 1,
              let eta = solveRuntimeLinearSystem(data.R, data.drift)
        else { return nil }
        let logD = log(Double(data.d))
        var pathLength = max(5.0, logD * logD / 2.0)
        for i in 0..<data.d where abs(eta[i]) > 1e-14 {
            let relaxation = data.gamma[i][i] / (2.0 * eta[i] * eta[i])
            if relaxation.isFinite {
                pathLength = max(pathLength, 5.0 * relaxation)
            }
        }
        let levelNumerator = data.d > 1
            ? log(max(logD, Double.leastNonzeroMagnitude))
                + 2.0 * log(1.0 / epsilon) - 2.0
            : 0
        let rawLevels = ceil(levelNumerator / log(1.0 / gamma))
        guard pathLength.isFinite, pathLength > 0,
              levelNumerator.isFinite, rawLevels.isFinite,
              rawLevels >= -1_000_000, rawLevels <= 1_000_000 else { return nil }
        let levels = max(1, Int(rawLevels))
        return MLMCCostPreview(
            pathLength: pathLength,
            levels: levels
        )
    }

    /// Matches the native solver's classical automatic sample formula for an
    /// already-resolved level count. Keeping this separate is important: an
    /// explicit `--N` must bypass a potentially overflowing `gamma^-L`, and
    /// adaptive runs are bounded by their maximum-sample safeguard instead.
    private func mlmcAutomaticSamples(gamma: Double, levels: Int) -> Double? {
        guard gamma > 0, gamma < 1, levels > 0 else { return nil }
        let gammaL = pow(gamma, Double(levels))
        let inverseGammaL = pow(gamma, Double(-levels))
        let normalization = (1.0 - gamma) / (1.0 - gammaL)
        let samples = ceil(
            (1.0 / normalization) * inverseGammaL * Double(levels)
        )
        guard gammaL.isFinite, gammaL > 0,
              inverseGammaL.isFinite,
              normalization.isFinite, normalization > 0,
              samples.isFinite, samples >= 1 else { return nil }
        return samples
    }

    /// SplitMix64 turns adjacent user-facing base seeds into widely separated
    /// top-level streams. The high two bits stay clear so the native solver can
    /// safely derive its small per-worker offsets without signed overflow.
    private func mlmcReplicationSeeds(baseSeed: Int, count: Int) -> [UInt64] {
        guard count > 0 else { return [] }
        var state = UInt64(truncatingIfNeeded: baseSeed)
        return (0..<count).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return (value & 0x3FFF_FFFF_FFFF_FFFF) + 1
        }
    }

    /// Two-sided 95% Student-t critical value for independent replication
    /// means. Small degrees of freedom use the standard table; the
    /// large-sample branch uses a third-order normal-quantile expansion.
    private func mlmc95Critical(replications: Int) -> Double {
        let smallSample: [Double] = [
            12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365,
            2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145,
            2.131, 2.120, 2.110, 2.101, 2.093, 2.086, 2.080,
            2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045
        ]
        guard replications >= 2 else { return 1.96 }
        if replications <= 30 { return smallSample[replications - 2] }
        let degrees = Double(replications - 1)
        let z = 1.959963984540054
        let z2 = z * z
        let z3 = z2 * z
        let z5 = z3 * z2
        let z7 = z5 * z2
        return z
            + (z3 + z) / (4 * degrees)
            + (5 * z5 + 16 * z3 + 3 * z) / (96 * degrees * degrees)
            + (3 * z7 + 19 * z5 + 17 * z3 - 15 * z)
                / (384 * degrees * degrees * degrees)
    }

    private func solveRuntimeLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-14 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }
            if column + 1 < n {
                for row in (column + 1)..<n {
                    let factor = a[row][column] / a[column][column]
                    for j in column..<n { a[row][j] -= factor * a[column][j] }
                    b[row] -= factor * b[column]
                }
            }
        }
        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var value = b[row]
            if row + 1 < n {
                for j in (row + 1)..<n { value -= a[row][j] * solution[j] }
            }
            solution[row] = value / a[row][row]
        }
        return solution
    }

    private func runExactSim() {
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "rbm_mlmc", subdirectory: "BNAmc"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "SRBM MLMC aborted: rbm_mlmc binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        // Build SRBM primitives + collect tau (for workload -> queue-length scaling)
        let dataResult = BNASRBMExporter.computeData(nodes: activeEditor.nodes, links: activeEditor.links)
        switch dataResult {
        case .failure(let error):
            reportBlocked("SRBM MLMC aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let data):
            // Write the BNAmc-format input file
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_mlmc_\(ProcessInfo.processInfo.processIdentifier).in")
            let content = BNASRBMExporter.formatBNAmcInput(data: data)
            do {
                try content.write(to: tempFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "SRBM MLMC aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            // Pull accuracy / speed knobs from Settings.  Fall back to the
            // paper-recommended defaults if a user entered something bogus.
            let epsRaw  = appSettings.exactSimEpsilon
            let gammaRaw = appSettings.exactSimGamma
            let epsilon = (epsRaw > 0 && epsRaw <= 1) ? epsRaw : 0.01
            let reciprocalGamma = 1.0 / gammaRaw
            let roundedReciprocal = reciprocalGamma.rounded()
            let gammaIsNativeCompatible = gammaRaw.isFinite
                && gammaRaw > 0 && gammaRaw < 1
                && reciprocalGamma.isFinite
                && roundedReciprocal >= 1
                && roundedReciprocal <= Double(Int32.max)
                && abs(roundedReciprocal * gammaRaw - 1) <= 1e-9
            let gamma = gammaIsNativeCompatible
                ? gammaRaw : AppSettings.Defaults.exactSimGamma
            if !gammaIsNativeCompatible {
                activeEditor.addStatus(
                    "Stored MLMC γ=\(gammaRaw) is incompatible with the native solver because 1/γ must be an integer; using the documented default γ=\(gamma).",
                    severity: .warning
                )
            }
            let K = max(1, appSettings.exactSimReplications)

            let automaticCost = mlmcCostPreview(data: data, gamma: gamma, epsilon: epsilon)
            // One place to refuse a plan: say why, and drop the input file the
            // run will now never read. The alert these calls used to raise also
            // carried a Title Case headline ("SRBM MLMC Plan Is Too Large"),
            // which is gone deliberately — every one of these messages is a
            // complete sentence that names the limit it hit, so the headline
            // only restated it in the pane's one-line format.
            func abortPlan(_ message: String) {
                reportBlocked(
                    "SRBM MLMC not started: \(message)",
                    severity: .warning,
                    on: activeEditor
                )
                try? FileManager.default.removeItem(at: tempFile)
            }

            let effectiveT: Double?
            if appSettings.exactSimOverrideT {
                effectiveT = appSettings.exactSimT.isFinite && appSettings.exactSimT > 0
                    ? appSettings.exactSimT : nil
            } else {
                effectiveT = automaticCost?.pathLength
            }
            let effectiveL: Int?
            if appSettings.exactSimOverrideL {
                effectiveL = appSettings.exactSimL > 0 ? appSettings.exactSimL : nil
            } else {
                effectiveL = automaticCost?.levels
            }
            guard let effectiveT, let effectiveL else {
                abortPlan(
                    "Qnet could not derive finite positive T and L values. Supply deliberate T/L overrides after reviewing finite-horizon and discretization bias, or use Adaptive Low-Rank BAR."
                )
                return
            }

            let adaptive = appSettings.exactSimAdaptive
            let effectiveN: Double
            let samplePlanLabel: String
            if adaptive {
                let batch = appSettings.exactSimBatchSize
                let minimum = appSettings.exactSimMinSamples
                let maximum = appSettings.exactSimMaxSamples
                guard batch > 0, minimum >= 2, maximum >= 2,
                      batch <= maximum, minimum <= maximum else {
                    abortPlan(
                        "Adaptive MLMC requires a positive batch size and at least two minimum/maximum samples so it can estimate variance, with batch and minimum no larger than the maximum. The maximum is the hard cost cap."
                    )
                    return
                }
                effectiveN = Double(maximum)
                samplePlanLabel = "maximum N=\(maximum)"
            } else if appSettings.exactSimOverrideN {
                guard appSettings.exactSimN > 0 else {
                    abortPlan(
                        "The explicit sample count N must be positive."
                    )
                    return
                }
                effectiveN = Double(appSettings.exactSimN)
                samplePlanLabel = "N=\(appSettings.exactSimN)"
            } else {
                guard let samples = mlmcAutomaticSamples(gamma: gamma, levels: effectiveL) else {
                    abortPlan(
                        "The automatic sample formula overflows at L=\(effectiveL). Choose a deliberate positive N override after reviewing bias, enable adaptive sampling with a finite maximum-sample cap, or use Adaptive Low-Rank BAR."
                    )
                    return
                }
                effectiveN = samples
                samplePlanLabel = "N≈\(samples.formatted(.number.notation(.compactName).precision(.significantDigits(4))))"
            }

            guard effectiveN <= Double(Int32.max) else {
                abortPlan(
                    "The resolved sample count exceeds the native solver's \(Int32.max) sample limit. Choose a smaller explicit N, use adaptive sampling with a finite cap, or increase ε/reduce L after reviewing bias."
                )
                return
            }
            let finestStepCount = effectiveT / pow(gamma, Double(effectiveL))
            let coarsestCoupledStepCount = effectiveL > 1
                ? Double(effectiveL - 1) * effectiveT
                    / pow(gamma, Double(effectiveL - 1))
                : 0
            guard finestStepCount.isFinite,
                  finestStepCount >= 1,
                  finestStepCount <= Double(Int32.max),
                  coarsestCoupledStepCount.isFinite,
                  coarsestCoupledStepCount >= 0,
                  coarsestCoupledStepCount <= Double(Int32.max) else {
                abortPlan(
                    "The finest/coupled path grids would require about \(finestStepCount.formatted(.number.notation(.scientific))) and \(coarsestCoupledStepCount.formatted(.number.notation(.scientific))) loop iterations, respectively; at least one exceeds the native solver's safe integer grid. Reduce T or L, increase γ, or use Adaptive Low-Rank BAR."
                )
                return
            }

            let antitheticFactor = appSettings.exactSimAntithetic ? 2.0 : 1.0
            // Under the truncated geometric level law, this is the exact
            // closed-form expected fine + coarse path-loop count per sample
            // before integer rounding. It includes the 1/gamma fine substeps
            // and the growing phase-2 horizon, which a T×L proxy misses.
            let levels = Double(effectiveL)
            let gammaL = pow(gamma, levels)
            let levelNormalizer = (1 - gamma) / (1 - gammaL)
            let expectedStepsPerSample = levelNormalizer * effectiveT * (
                levels * (levels + 1) / (2 * gamma)
                    + levels * (levels - 1) / 2
            )
            let pathStepWorkIndex = expectedStepsPerSample * effectiveN
                * Double(K) * antitheticFactor
            let coordinateWorkIndex = pathStepWorkIndex * Double(max(data.d, 1))
            let preview = "Estimated MLMC plan: T≈\(effectiveT.formatted(.number.precision(.significantDigits(4)))), L=\(effectiveL), \(samplePlanLabel) per replication."
            activeEditor.addStatus(preview, severity: .info)
            if !pathStepWorkIndex.isFinite || !coordinateWorkIndex.isFinite
                || pathStepWorkIndex > 1_000_000_000
                || coordinateWorkIndex > 20_000_000_000 {
                let message = preview + " Across \(K) replication\(K == 1 ? "" : "s"), its expected coupled-path work exceeds Qnet's safety budget (1 billion vector steps or 20 billion coordinate steps, including γ and antithetic cost). Reduce the adaptive maximum or choose deliberate T/L/N values after reviewing bias, or use Adaptive Low-Rank BAR."
                abortPlan(message)
                return
            }

            // Build CLI flags based on what the user overrode.
            var extraFlags: [String] = []
            if appSettings.exactSimOverrideT && appSettings.exactSimT > 0 {
                extraFlags += ["--T", String(format: "%g", appSettings.exactSimT)]
            }
            if appSettings.exactSimOverrideL && appSettings.exactSimL > 0 {
                extraFlags += ["--L", "\(appSettings.exactSimL)"]
            }
            if !adaptive, appSettings.exactSimOverrideN && appSettings.exactSimN > 0 {
                extraFlags += ["--N", "\(appSettings.exactSimN)"]
            }
            switch appSettings.exactSimBackend {
            case 1: extraFlags += ["--backend", "openmp"]
            case 2: extraFlags += ["--backend", "accelerate"]
            case 3: extraFlags += ["--backend", "serial"]
            default: break // auto-select
            }
            if appSettings.exactSimThreads > 0 {
                extraFlags += ["--threads", "\(appSettings.exactSimThreads)"]
            }
            // NOTE: --seed is handled per-replication below (not here) so that
            // K > 1 replications use distinct seeds.

            // Variance-reduction flags
            if appSettings.exactSimAntithetic {
                extraFlags += ["--antithetic"]
            }
            if adaptive {
                extraFlags += ["--adaptive"]
                extraFlags += ["--batch-size", "\(appSettings.exactSimBatchSize)"]
                extraFlags += ["--min-samples", "\(appSettings.exactSimMinSamples)"]
                extraFlags += ["--max-samples", "\(appSettings.exactSimMaxSamples)"]
            }

            let baseSeed: Int = appSettings.exactSimSeedFixed ? appSettings.exactSimSeed
                                                              : Int.random(in: 1...1_000_000_000)
            let replicationSeeds = mlmcReplicationSeeds(baseSeed: baseSeed, count: K)

            // Shell-quote each flag so filenames / values with spaces survive.
            let flagsJoined = extraFlags.map { "\"\($0)\"" }.joined(separator: " ")

            // Display string: what we're about to run, without flooding the terminal
            var cliSummary = "γ=\(String(format: "%g", gamma)), ε=\(String(format: "%g", epsilon))"
            if appSettings.exactSimOverrideT {
                cliSummary += ", T=\(String(format: "%g", appSettings.exactSimT))"
            }
            if appSettings.exactSimOverrideL {
                cliSummary += ", L=\(appSettings.exactSimL)"
            }
            if !adaptive, appSettings.exactSimOverrideN {
                cliSummary += ", N=\(appSettings.exactSimN)"
            }
            if appSettings.exactSimAntithetic { cliSummary += ", antithetic" }
            if adaptive {
                cliSummary += ", adaptive (max \(appSettings.exactSimMaxSamples))"
            }
            if K > 1 { cliSummary += ", K=\(K) replications" }

            // Build a per-station effective service rate vector (mu_eff = 1/tau)
            // as a shell array so the awk script can scale workload -> queue
            // length without re-parsing the SRBM.
            let muEff = data.meanServiceTimes.map { tau in tau > 0 ? 1.0 / tau : 1.0 }
            // %.17g, not %.10f: MU is consumed numerically by awk (muarr[i]+0)
            // and scales workload into queue length. A station whose mean
            // service time is large enough that mu_eff < 1e-10 used to be
            // handed to awk as the literal string "0.0000000000", zeroing
            // that station's whole L column. %.17g round-trips the Double.
            let muEffStr = muEff.map { String(format: "%.17g", $0) }.joined(separator: " ")

            let outFileBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_mlmc_out_\(ProcessInfo.processInfo.processIdentifier)")
                .path

            let gammaStr = String(format: "%g", gamma)
            let epsStr   = String(format: "%g", epsilon)
            let replicationSeedList = replicationSeeds.map(String.init)
                .joined(separator: " ")
            let confidenceCritical = mlmc95Critical(replications: K)
            let confidenceCriticalStr = String(format: "%.12g", confidenceCritical)

            // Build the replication loop.  Each replication writes its output to
            // a distinct file `outFileBase.k` and we then feed them all to a
            // single awk aggregator that extracts the workload E[X_i] per run
            // and prints per-station means ± SE across K runs plus the
            // queue-length conversion.
            let command = """
            (
            cleanup_mlmc() {
              rm -f "\(outFileBase)."*.err "\(outFileBase)."*[0-9]
              rm -f \(shellQuote(tempFile.path))
            }
            trap cleanup_mlmc EXIT
            trap 'exit 130' INT TERM
            printf 'Running SRBM MLMC (\(cliSummary)) ... '
            MU="\(muEffStr)"
            K=\(K)
            REPLICATION_SEEDS=(\(replicationSeedList))
            for k in $(seq 1 $K); do
              SEED=${REPLICATION_SEEDS[$((k - 1))]}
              \(shellQuote(binary.path)) \(shellQuote(tempFile.path)) \(gammaStr) \(epsStr) --seed $SEED \(flagsJoined) > "\(outFileBase).$k" 2> "\(outFileBase).$k.err"
              RC=$?
              if [ $RC -ne 0 ]; then
                echo
                echo "SRBM MLMC replication $k failed with status $RC."
                if [ -s "\(outFileBase).$k.err" ]; then
                  cat "\(outFileBase).$k.err"
                fi
                exit $RC
              fi
              if ! awk -v expected=\(data.meanServiceTimes.count) '
                /^  *[0-9]+ +[^ ]+ / {
                  idx=$1+0
                  if ($2 !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/ ||
                      $3 !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/ ||
                      $4 !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/ ||
                      idx < 1 || idx > expected || seen[idx]++) bad=1
                }
                END {
                  for (i=1; i<=expected; i++) if (!seen[i]) bad=1
                  exit bad ? 1 : 0
                }
              ' "\(outFileBase).$k"; then
                echo
                echo "SRBM MLMC replication $k returned incomplete or malformed station output (expected \(data.meanServiceTimes.count) rows)."
                if [ -s "\(outFileBase).$k.err" ]; then
                  cat "\(outFileBase).$k.err"
                fi
                exit 65
              fi
              if [ -s "\(outFileBase).$k.err" ]; then
                echo
                echo "SRBM MLMC replication $k diagnostics:"
                cat "\(outFileBase).$k.err"
              fi
            done
            echo done.
            echo
            awk -v mu="$MU" -v K=$K -v critical=\(confidenceCriticalStr) -v base="\(outFileBase)" -v seeds="\(replicationSeedList)" '
              BEGIN {
                n_mu = split(mu, muarr, " ")
                n_seed = split(seeds, seedarr, " ")
                printf "SRBM MLMC (Blanchet-Chen-Glynn-Si)\\n"
                printf "==============================================\\n"
              }
              function process_file(path, k,    line, idx, w, native_se, fields, n, j) {
                while ((getline line < path) > 0) {
                  if (line ~ /^# Dimension:/ && k == 1) { print line; continue }
                  if (line ~ /^# gamma=/) {
                    if (k == 1) print line
                    n = split(line, fields, " ")
                    for (j = 1; j <= n; j++) {
                      if (fields[j] ~ /^N=/) {
                        actual_n[k] = fields[j]
                        sub(/^N=/, "", actual_n[k])
                      }
                    }
                    continue
                  }
                  if (line ~ /^# backend=/   && k == 1) { print line; continue }
                  if (line ~ /^# antithetic/) {
                    if (k == 1) print line
                    if (line ~ /adaptive=on/) {
                      adaptive_runs++
                      if (line ~ /stop=SE target achieved/) {
                        stop_status[k] = "precision-met"
                      } else {
                        stop_status[k] = "cap-reached"
                        adaptive_unmet++
                      }
                    } else {
                      stop_status[k] = "fixed-count"
                    }
                    continue
                  }
                  if (line ~ /^# Total Gaussian/) {
                    gauss_this = line
                    sub(/.* /, "", gauss_this)
                    total_gauss += gauss_this + 0
                    continue
                  }
                  if (line ~ /^  *[0-9]+ +[-0-9.eE+]+ /) {
                    # Native row: component, mean, standard error, 95% half-width.
                    n = split(line, fields, " ")
                    idx       = fields[1] + 0
                    w         = fields[2] + 0
                    native_se = fields[3] + 0
                    sum_w[idx]  += w
                    sum_w2[idx] += w * w
                    run_w[k, idx] = w
                    run_se[k, idx] = native_se
                    if (idx > d) d = idx
                  }
                }
                close(path)
              }
              END {
                for (k = 1; k <= K; k++) process_file(base "." k, k)
                printf "# Replications: %d (independent top-level streams)\\n", K
                printf "# Replication seeds: %s\\n", seeds
                for (k = 1; k <= K; k++)
                  printf "# Replication %d: seed=%s N=%s stop=%s\\n",
                         k, seedarr[k], actual_n[k], stop_status[k]
                printf "#\\n"
                printf "\\nPer-Station Mean Queue Length (L_i = mu_i * E[Y_i]):\\n"
                sumq = 0
                iw = 1; _t = d; while (_t >= 10) { iw++; _t = int(_t/10) }
                for (i = 1; i <= d; i++) {
                  m   = sum_w[i] / K
                  var = (K >= 2) ? (sum_w2[i] - K * m * m) / (K - 1) : 0
                  if (var < 0) var = 0
                  # Preserve the native within-run SE for K=1. For K>1,
                  # uncertainty comes from independent replication estimates.
                  se  = (K >= 2) ? sqrt(var / K) : run_se[1, i]
                  mu_i = muarr[i] + 0
                  L = m * mu_i
                  printf "  L_%0*d = %10.4f  ± %7.4f (95%%)    (workload E[Y_%0*d] = %7.4f ± %6.4f, mu_i = %.4f)\\n",
                         iw, i, L, critical * se * mu_i, iw, i, m, critical * se, mu_i
                  sumq += L
                }
                avgq = (d > 0) ? sumq / d : 0
                if (K >= 2 && d > 0) {
                  sum_avg = 0; sum_avg2 = 0
                  for (k = 1; k <= K; k++) {
                    avg_run = 0
                    for (i = 1; i <= d; i++)
                      avg_run += (muarr[i] + 0) * run_w[k, i]
                    avg_run /= d
                    sum_avg += avg_run
                    sum_avg2 += avg_run * avg_run
                  }
                  avg_var = (sum_avg2 - K * (sum_avg / K) * (sum_avg / K)) / (K - 1)
                  if (avg_var < 0) avg_var = 0
                  avg_se = sqrt(avg_var / K)
                  printf "\\nAverage queue length: %.4f  ± %.4f (95%% across independent replications)\\n",
                         avgq, critical * avg_se
                } else {
                  printf "\\nAverage queue length: %.4f (no joint CI: one run does not identify cross-station covariance)\\n", avgq
                }
                printf "Total Gaussian RVs (summed over replications): %lld\\n", total_gauss
                if (adaptive_runs > 0)
                  # The ternary MUST stay parenthesised. /usr/bin/awk (BWK
                  # one-true-awk 20200816, the macOS default) parses `>` in a
                  # print/printf argument list as an output redirection, so a
                  # bare `adaptive_unmet > 0 ? "no" : "yes"` is a syntax error
                  # at PARSE time — which killed the whole aggregator and left
                  # every MLMC run with no table, no status record and no
                  # visible failure.
                  printf "QNET_MLMC_STATUS_V1 adaptive=yes precision_met=%s cap_hits=%d\\n",
                         (adaptive_unmet > 0 ? "no" : "yes"), adaptive_unmet
                else
                  printf "QNET_MLMC_STATUS_V1 adaptive=no precision_met=na cap_hits=0\\n"
              }
              { }
            ' < /dev/null
            RC=$?
            exit $RC
            )
            """
            if runScript(
                command,
                label: "mlmc",
                parameters: [
                    "epsilon": epsStr,
                    "gamma": gammaStr,
                    "path length T": effectiveT.description,
                    "levels L": effectiveL.description,
                    "sample plan": adaptive
                        ? "adaptive, maximum \(appSettings.exactSimMaxSamples)"
                        : effectiveN.description,
                    "replications": K.description,
                    "antithetic": appSettings.exactSimAntithetic.description,
                    "adaptive": appSettings.exactSimAdaptive.description,
                    "backend": appSettings.exactSimBackend.description,
                    "threads": appSettings.exactSimThreads == 0
                        ? "automatic" : appSettings.exactSimThreads.description,
                    "runtime": lookup.resolution?.provenanceDescription ?? "unknown",
                ],
                seed: UInt64(baseSeed),
                replicationSeeds: replicationSeeds
            ) {
                activeEditor.addStatus("Running SRBM MLMC (\(cliSummary))...", severity: .info)
            } else {
                try? FileManager.default.removeItem(at: tempFile)
            }
        }
    }

    // MARK: - Linear Program (BNAlp / Saure-Glynn-Zeevi 2008)
    //
    // BNAlp / srbm_lp solves the steady-state distribution of an SRBM by
    // approximating the Basic Adjoint Relationship with a linear program
    // over a finite grid.  The binary takes a keyword-driven text input
    // (see BNASRBMExporter.formatBNAlpInput for the format), runs the LP
    // via CPLEX by default (GLPK fallback is compiled in too), and prints
    // per-dimension E[Y_i(∞)] along with moment tables.
    //
    // Output is WORKLOAD, same as BNAmc, so the awk stage converts to
    // queue length by multiplying by mu_eff_i for symmetry with the
    // other infinite-buffer algorithms.
    /// Resolved LP parameters for a single run.  Gathered from
    /// `AppSettings` and optionally overridden by a pre-run dialog.
    private struct LPRunParams {
        var gridN: Int               // 0 → auto-scaled by d
        var basisM: Int              // 0 → auto-scaled by d
        var solverFlag: String?      // nil → binary picks default
        var gridType: String         // "exponential" | "dyadic" | "exprandom"
        var smoothness: Double
        var basisNormalize: Bool
        var multiLevel: Bool
    }

    private func readLPSettings() -> LPRunParams {
        let solverFlag: String? = {
            switch appSettings.lpSolver {
            case 1: return "cplex"
            case 2: return "glpk"
            case 3: return "highs"
            default: return nil
            }
        }()
        let gridType: String = {
            switch appSettings.lpGridType {
            case 1: return "dyadic"
            case 2: return "exprandom"
            default: return "exponential"
            }
        }()
        return LPRunParams(
            gridN:          appSettings.lpGridN,
            basisM:         appSettings.lpBasisM,
            solverFlag:     solverFlag,
            gridType:       gridType,
            smoothness:     appSettings.lpSmoothness,
            basisNormalize: appSettings.lpBasisNormalize,
            multiLevel:     appSettings.lpMultiLevel
        )
    }

    /// Pre-run parameter sheet shown before each LP run when the user opts
    /// into per-run confirmation (Settings ▸ Linear Program). Hands the
    /// edited parameters to `onRun`; `onCancel` runs on Escape / Cancel.
    private func presentLPParams(
        _ initial: LPRunParams,
        d: Int,
        onCancel: @escaping () -> Void,
        onRun: @escaping (LPRunParams) -> Void
    ) {
        let solverIndex = ["cplex", "glpk", "highs"].firstIndex(of: initial.solverFlag ?? "").map { $0 + 1 } ?? 0
        let gridTypeIndex = ["dyadic", "exprandom"].firstIndex(of: initial.gridType).map { $0 + 1 } ?? 0

        func resolved(_ v: RunParameterValues) -> LPRunParams {
            var params = initial
            params.gridN = max(0, v.int(RunKey.gridN, default: initial.gridN))
            params.basisM = max(0, v.int(RunKey.basisM, default: initial.basisM))
            params.solverFlag = [nil, "cplex", "glpk", "highs"][min(3, max(0, v.int(RunKey.solver)))]
            params.gridType = ["exponential", "dyadic", "exprandom"][min(2, max(0, v.int(RunKey.gridType)))]
            params.smoothness = max(0, v.double(RunKey.smoothness, default: initial.smoothness))
            params.basisNormalize = v.flag(RunKey.normalise)
            params.multiLevel = v.flag(RunKey.multiLevel)
            return params
        }

        presentRunParameters(
            .linearProgram(gridN: initial.gridN, basisM: initial.basisM,
                           solver: solverIndex, gridType: gridTypeIndex,
                           smoothness: initial.smoothness,
                           normalise: initial.basisNormalize,
                           multiLevel: initial.multiLevel,
                           dimension: d),
            onSetDefault: { v in
                let p = resolved(v)
                appSettings.lpGridN = p.gridN
                appSettings.lpBasisM = p.basisM
                appSettings.lpSolver = min(3, max(0, v.int(RunKey.solver)))
                appSettings.lpGridType = min(2, max(0, v.int(RunKey.gridType)))
                appSettings.lpSmoothness = p.smoothness
                appSettings.lpBasisNormalize = p.basisNormalize
                appSettings.lpMultiLevel = p.multiLevel
            },
            onCancel: onCancel
        ) { v in
            onRun(resolved(v))
        }
    }

    private func runLinearProgram() {
        let lookup = SolverRuntimeResolver.shared.resolveExecutable(
            name: "srbm_lp", subdirectory: "BNAlp"
        )
        guard let binary = lookup.url else {
            reportBlocked(
                "Linear Program aborted: srbm_lp binary not found.",
                detail: lookup.actionableDiagnostic,
                on: activeEditor
            )
            return
        }

        let dataResult = BNASRBMExporter.computeData(
            nodes: activeEditor.nodes, links: activeEditor.links
        )
        switch dataResult {
        case .failure(let error):
            reportBlocked("Linear Program aborted: \(error.localizedDescription)", on: activeEditor)

        case .success(let data):
            // Resolve parameters: Settings → optional pre-run sheet.
            let params = readLPSettings()
            // Default on the smart choice for d ≥ 3: normalise the basis,
            // which dramatically improves CPLEX conditioning.
            if data.d >= 3 && appSettings.lpBasisNormalize == false
               && appSettings.lpAskBeforeRun == false {
                // leave user's explicit "off" alone; only promote if the
                // user is in pure-default mode.
            }

            if appSettings.lpAskBeforeRun {
                presentLPParams(
                    params, d: data.d,
                    onCancel: { activeEditor.addStatus("Linear Program cancelled by user.", severity: .warning) }
                ) { edited in
                    runLinearProgram(binary: binary, data: data, params: edited)
                }
            } else {
                runLinearProgram(binary: binary, data: data, params: params)
            }
        }
    }

    /// Second half of Run ▸ Run Linear Program, once the parameters are
    /// settled (from Settings, or from the pre-run sheet).
    private func runLinearProgram(binary: URL, data: BNASRBMExporter.BNASRBMData, params: LPRunParams) {
        do {
            // Resolve grid_n / basis_m: 0 means auto-scaled by dimension.
            let rec = BNASRBMExporter.recommendedBNAlpGrid(forDimension: data.d)
            let resolvedGridN  = params.gridN  > 0 ? params.gridN  : rec.0
            let resolvedBasisM = params.basisM > 0 ? params.basisM : rec.1

            if let issue = linearProgramResourceIssue(
                dimension: data.d,
                gridSize: resolvedGridN,
                smoothness: params.smoothness
            ) {
                reportBlocked(
                    "Linear Program not started: \(issue)",
                    severity: .warning,
                    on: activeEditor
                )
                return
            }

            // Per-station mu_eff vector for workload → queue-length scaling.
            // %.17g for the same reason as the MLMC runner: awk only ever
            // reads MU numerically, and a fixed %.10f silently truncated a
            // sub-1e-10 service rate to zero, zeroing the L column with it.
            let muEff = data.meanServiceTimes.map { tau in tau > 0 ? 1.0 / tau : 1.0 }
            let muEffStr = muEff.map { String(format: "%.17g", $0) }.joined(separator: " ")

            // Servers per station for the output table.
            let servers: [Int] = activeEditor.nodes
                .filter { $0.kind == .station }
                .sorted { stationIndex($0.name) < stationIndex($1.name) }
                .map { $0.numberOfServers }
            let serversStr = servers.map(String.init).joined(separator: " ")

            // Compose the list of (grid_n, stage-label) to run.  For
            // multi-level we run a coarse preview first, then the full run.
            var stages: [(Int, String)] = []
            if params.multiLevel && resolvedGridN >= 8 {
                let coarseN = max(resolvedGridN / 2, 6)
                stages.append((coarseN,           "COARSE PREVIEW (grid_n = \(coarseN))"))
                stages.append((resolvedGridN,     "REFINED RUN (grid_n = \(resolvedGridN))"))
            } else {
                stages.append((resolvedGridN, ""))
            }

            // Build + write each stage's input file; emit one shell script
            // that runs each stage sequentially, streams its output, then
            // runs the awk formatter.  The captured output files are
            // cleaned up at the end.
            let pid = ProcessInfo.processInfo.processIdentifier
            var shellLines: [String] = []
            shellLines.append("printf 'Running Linear Program (BNAlp, Saure-Glynn-Zeevi 2008)\\n'")
            let gridNote = params.gridN == 0 && params.basisM == 0
                ? "auto-scaled for d=\(data.d): grid_n=\(rec.0), basis_m=\(rec.1)"
                : "user-set: grid_n=\(resolvedGridN), basis_m=\(resolvedBasisM)"
            shellLines.append("printf '%s\\n\\n' \(shellQuote(gridNote))")

            shellLines.append("MU=\(shellQuote(muEffStr))")
            shellLines.append("SERVERS=\(shellQuote(serversStr))")
            shellLines.append("set -o pipefail")

            for (stageIdx, stage) in stages.enumerated() {
                let (stageN, label) = stage

                // Write stage-specific input file
                let inFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BNET_lp_\(pid)_s\(stageIdx).in")
                let content = BNASRBMExporter.formatBNAlpInput(
                    data: data,
                    gridN: stageN,
                    basisM: resolvedBasisM,
                    gridType: params.gridType,
                    smoothnessWeight: params.smoothness,
                    basisNormalize: params.basisNormalize
                )
                do {
                    try content.write(to: inFile, atomically: true, encoding: .utf8)
                } catch {
                    reportBlocked(
                        "Linear Program aborted: could not write temp file.",
                        detail: error.localizedDescription,
                        on: activeEditor
                    )
                    return
                }
                let outFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BNET_lp_\(pid)_s\(stageIdx).out")

                if !label.isEmpty {
                    shellLines.append("printf '===== %s =====\\n' \(shellQuote(label))")
                }

                let solverArg = params.solverFlag.map { "--solver \($0)" } ?? ""
                shellLines.append(
                    "\"\(binary.path)\" --input \"\(inFile.path)\" \(solverArg) 2>&1 | tee \"\(outFile.path)\""
                )
                shellLines.append("RC=${PIPESTATUS[0]}")
                shellLines.append("if [ $RC -ne 0 ]; then printf '\\nSolver exited with code %d.\\n' \"$RC\"; exit $RC; fi")
                shellLines.append(lpSummaryAwk(outFile: outFile.path))
                shellLines.append("rm -f \"\(inFile.path)\" \"\(outFile.path)\"")
            }

            let command = shellLines.joined(separator: "\n")
            if runScript(
                command,
                label: "lp",
                parameters: [
                    "grid size": resolvedGridN.description,
                    "basis size": resolvedBasisM.description,
                    "grid type": params.gridType,
                    "solver": params.solverFlag ?? "automatic",
                    "smoothness": params.smoothness.description,
                    "basis normalization": params.basisNormalize.description,
                    "multi-level": params.multiLevel.description,
                ]
            ) {
                activeEditor.addStatus("Running Linear Program (BNAlp)...", severity: .info)
            }
        }
    }

    /// Returns the awk block that reformats a single captured stage's
    /// output into the QNA-style per-station table + network totals.
    private func lpSummaryAwk(outFile: String) -> String {
        return """
        printf '\\n'
        awk -v mu="$MU" -v servers="$SERVERS" '
          BEGIN {
            nMu = split(mu,      muarr, " ")
            nSv = split(servers, svarr, " ")
          }
          /^\\[Solve\\] Optimal/       { u_star=$4; solver_line=$0; next }
          /^\\[Solve\\] Using solver:/ { solver_name=$NF; next }
          /^\\[Total\\]/               { total_s=$2 "s"; next }
          /^  grid_n/                 { grid_n=$NF; next }
          /^  basis_m/                { basis_m=$NF; next }
          /^\\[Build LP\\]/            { build_line=$0; next }
          /^E\\[X_[0-9]+\\] = /        {
            m = match($1, /[0-9]+/)
            idx = substr($1, RSTART, RLENGTH) + 0
            workloads[idx] = $NF + 0
            if (idx > d) d = idx
            next
          }
          END {
            printf "Linear Program (Saure-Glynn-Zeevi 2008 LP)\\n"
            printf "==========================================\\n\\n"
            printf "Solver: %s  |  grid_n = %s  |  basis_m = %s\\n",
                   solver_name, grid_n, basis_m
            if (build_line  != "") print build_line
            if (solver_line != "") print solver_line
            if (total_s     != "") printf "[Total] %s\\n", total_s
            printf "\\n%-6s %-8s %-16s %-16s %-10s\\n",
                   "Node","Servers","E[Y] (workload)","L = mu·E[Y]","mu_i"
            sumL = 0
            for (i = 1; i <= d; i++) {
              mu_i = muarr[i] + 0
              sv   = (i <= nSv ? svarr[i] : 1)
              L    = workloads[i] * mu_i
              printf "%-6d %-8d %-16.4f %-16.4f %-10.4f\\n",
                     i, sv, workloads[i], L, mu_i
              sumL += L
            }
            printf "\\nNetwork Totals:\\n"
            if (d > 0) {
              printf "  Total E[N]:             %.4f\\n", sumL
              printf "  Average queue length:   %.4f\\n", sumL / d
            }
          }
        ' "\(outFile)"
        """
    }

    /// Very small shell-quoting helper used by `runLinearProgram` so the
    /// grid-note string is safe to embed in the heredoc without worrying
    /// about embedded quotes / backslashes / newlines.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Settles which engine a dual-engine method will run, and returns the
    /// command prefix for it.
    ///
    /// Three methods ship a C engine beside the original Python one and the
    /// user picks per method in Settings ▸ Solvers ▸ Solver Engine. This is the
    /// single place that choice is honoured; a new dual-engine method must come
    /// through here rather than reading the setting itself, so that the
    /// fallback below cannot be forgotten in one place out of four.
    ///
    /// THE FALLBACK IS THE POINT. A source checkout that has not run
    /// `build_all_algorithms.sh` has no `bna_rmc`, and a user who has selected
    /// the C engine must still be able to run the method — with an explanation,
    /// not with a "solver not found" dead end. So an unresolvable engine falls
    /// back to the other one and returns a `note` the caller puts in the Status
    /// pane. Only when NEITHER resolves is the run refused, and then the
    /// diagnostic names both attempts.
    private func resolveEngine(
        for method: DualEngineMethod,
        preferred: SolverEngine,
        pythonScript: String,
        pythonSubdirectory: String
    ) -> Result<ResolvedEngine, SolverEngineUnavailable> {
        let native = method.nativeExecutable

        func resolveC() -> (prefix: String, provenance: String)? {
            let lookup = SolverRuntimeResolver.shared.resolveExecutable(
                name: native.name, subdirectory: native.subdirectory, groups: native.groups
            )
            guard let url = lookup.url else { return nil }
            return (shellQuote(url.path), lookup.resolution?.provenanceDescription ?? "unknown")
        }

        func resolvePython() -> (prefix: String, provenance: String)? {
            let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
                name: pythonScript, subdirectory: pythonSubdirectory
            )
            guard let url = lookup.url,
                  let interpreter = lookup.resolution?.runtimeExecutableURL else { return nil }
            return ("\(shellQuote(interpreter.path)) -B \(shellQuote(url.path))",
                    lookup.resolution?.provenanceDescription ?? "unknown")
        }

        let resolveChosen  = preferred == .c ? resolveC : resolvePython
        let resolveOther   = preferred == .c ? resolvePython : resolveC

        if let chosen = resolveChosen() {
            return .success(ResolvedEngine(
                engine: preferred,
                launchPrefix: chosen.prefix,
                provenance: "\(preferred.descriptiveName); \(chosen.provenance)",
                note: nil
            ))
        }
        if let other = resolveOther() {
            let fallback = preferred.other
            return .success(ResolvedEngine(
                engine: fallback,
                launchPrefix: other.prefix,
                provenance: "\(fallback.descriptiveName) (fallback); \(other.provenance)",
                note: "\(method.displayName): the \(preferred.descriptiveName) is not available in "
                    + "this installation, so the \(fallback.descriptiveName) ran instead. The two "
                    + "produce the same result; only the run time differs. Settings ▸ Solvers ▸ "
                    + "Solver Engine chooses."
            ))
        }
        return .failure(SolverEngineUnavailable(diagnostic:
            "Neither engine for \(method.displayName) could be resolved: no loadable "
            + "\(native.name) and no runnable \(pythonScript). Rebuild the solvers with "
            + "./build_all_algorithms.sh, or reinstall the application."
        ))
    }

    /// Runs a solver in an isolated shell that always removes its exported
    /// temporary inputs. The signal traps matter because Stop escalates to the
    /// entire process group; a trailing `rm` alone is skipped when that happens.
    private func commandWithCleanup(_ command: String, paths: [String]) -> String {
        let targets = paths.map(shellQuote).joined(separator: " ")
        guard !targets.isEmpty else { return command }
        return """
        (
          cleanup_qnet_solver_inputs() { rm -f \(targets); }
          trap cleanup_qnet_solver_inputs EXIT
          trap 'exit 130' INT TERM
          \(command)
        )
        """
    }

    /// Extracts the numeric index at the end of a station name for
    /// consistent ordering (e.g. "S10" → 10).  Returns 0 for names
    /// without a trailing number.
    private func stationIndex(_ name: String) -> Int {
        var s = name[...]
        while let last = s.last, last.isLetter || last == "_" {
            s = s.dropLast()
        }
        return Int(String(s)) ?? 0
    }

    private func runComparisonInfinite() {
        // Availability is method-local: a missing or unloadable solver must
        // not prevent the remaining comparison columns from running.
        let smBinary = findBinary(name: "bnet", subdirectory: "BNAsm")
        let qnaBinary = findBinary(name: "bna_qna", subdirectory: "BNAqna")
        let simBinary = findBinary(name: "jackson_sim", subdirectory: "BNAsim")

        // SBD binary is optional — comparison proceeds without it if not found
        let sbdBinary = findBinary(name: "bna_sbd", subdirectory: "BNAsbd")
        let haveSBD = sbdBinary != nil

        // RQNA binary is optional — comparison proceeds without it if not found
        let rqnaBinary = findBinary(name: "bna_rqna", subdirectory: "BNArqna")
        let haveRQNA = rqnaBinary != nil

        // Export SM input (SRBM format with saved defaults)
        let smResult = BNASRBMExporter.exportForSpectral(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            degree: appSettings.smDegree
        )
        let smContent: String?
        let smExportProblem: String?
        switch smResult {
        case .success(let value): smContent = value; smExportProblem = nil
        case .failure(let error): smContent = nil; smExportProblem = error.localizedDescription
        }

        // Export QNA input (also used by SBD — same format)
        let qnaResult = QNAExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)
        let qnaContent: String?
        let qnaExportProblem: String?
        switch qnaResult {
        case .success(let value): qnaContent = value; qnaExportProblem = nil
        case .failure(let error): qnaContent = nil; qnaExportProblem = error.localizedDescription
        }

        // Export Sim input (network format)
        let simResult = BNANetworkExporter.export(nodes: activeEditor.nodes, links: activeEditor.links)
        let simContent: String?
        let simExportProblem: String?
        switch simResult {
        case .success(let value): simContent = value; simExportProblem = nil
        case .failure(let error): simContent = nil; simExportProblem = error.localizedDescription
        }

        guard smContent != nil || qnaContent != nil || simContent != nil else {
            let details = [smExportProblem, qnaExportProblem, simExportProblem]
                .compactMap { $0 }.joined(separator: "\n\n")
            reportBlocked(
                "Comparison not started: no method accepted this network.",
                detail: details,
                on: activeEditor
            )
            return
        }

        // Write temp files
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmpDir = FileManager.default.temporaryDirectory
        let smFile = tmpDir.appendingPathComponent("BNET_inf_cmp_sm_\(pid).in")
        let qnaFile = tmpDir.appendingPathComponent("BNET_inf_cmp_qna_\(pid).qna")
        let sbdFile = tmpDir.appendingPathComponent("BNET_inf_cmp_sbd_\(pid).qna")
        let rqnaFile = tmpDir.appendingPathComponent("BNET_inf_cmp_rqna_\(pid).qna")
        let simFile = tmpDir.appendingPathComponent("BNET_inf_cmp_sim_\(pid).sim")

        do {
            if let smContent {
                try smContent.write(to: smFile, atomically: true, encoding: .utf8)
            }
            if let qnaContent {
                try qnaContent.write(to: qnaFile, atomically: true, encoding: .utf8)
                try qnaContent.write(to: sbdFile, atomically: true, encoding: .utf8)
                try qnaContent.write(to: rqnaFile, atomically: true, encoding: .utf8)
            }
            if let simContent {
                try simContent.write(to: simFile, atomically: true, encoding: .utf8)
            }
        } catch {
            reportBlocked(
                "Comparison (infinite) aborted: could not write temp files.",
                detail: error.localizedDescription,
                on: activeEditor
            )
            return
        }

        // Output files for compact (-c) output
        let smOut = tmpDir.appendingPathComponent("BNET_inf_cmp_sm_out_\(pid).txt")
        let qnaOut = tmpDir.appendingPathComponent("BNET_inf_cmp_qna_out_\(pid).txt")
        let sbdOut = tmpDir.appendingPathComponent("BNET_inf_cmp_sbd_out_\(pid).txt")
        let rqnaOut = tmpDir.appendingPathComponent("BNET_inf_cmp_rqna_out_\(pid).txt")
        let simOut = tmpDir.appendingPathComponent("BNET_inf_cmp_sim_out_\(pid).txt")

        // Run all programs sequentially with progress messages.
        // runWithStderrOnFailure dumps each binary's stderr to the
        // shell pane on non-zero exit so memcheck and solver errors
        // become visible (previously suppressed by 2>/dev/null).
        //
        // Pad every per-algo prefix to a uniform width so the bars
        // line up vertically.
        let cmpLabels = ["Running spectral method ...",
                         "Running QNA ...",
                         "Running RQNA ...",
                         "Running SBD ...",
                         "Running simulation ..."]
        let cmpWidth = (cmpLabels.map(\.count).max() ?? 0) + 2
        let pad: (String) -> String = { s in
            s + String(repeating: " ", count: max(0, cmpWidth - s.count))
        }

        func independentStep(
            _ command: String,
            label: String,
            token: String,
            output: URL
        ) -> String {
            let quotedLabel = shellQuote(label)
            let quotedToken = shellQuote(token)
            let quotedOutput = shellQuote(output.path)
            return """
            { ( \(command) ); _cmp_rc=$?; \
              if [ $_cmp_rc -ne 0 ]; then \
                printf 'QNET_METHOD_FAILURE_V1 method=%s exit=%d\n' \(quotedToken) "$_cmp_rc" > \(quotedOutput); \
                CMP_FAILED="${CMP_FAILED}\(token),"; \
                printf '%s failed; continuing with independent methods.\n' \(quotedLabel); \
              else \
                CMP_SUCCEEDED=$((CMP_SUCCEEDED + 1)); \
              fi; }
            """
        }

        func skippedStep(
            label: String,
            token: String,
            reason: String,
            output: URL
        ) -> String {
            """
            { printf '%s skipped: %s\n' \(shellQuote(label)) \(shellQuote(reason)); \
              printf 'QNET_METHOD_FAILURE_V1 method=%s skipped=yes reason=%s\n' \(shellQuote(token)) \(shellQuote(reason)) > \(shellQuote(output.path)); \
              CMP_FAILED="${CMP_FAILED}\(token),"; }
            """
        }

        let dimension = activeEditor.nodes.filter { $0.kind == .station }.count
        let runSM: String
        if let smBinary, smContent != nil,
           spectralResourceIssue(dimension: dimension, degree: appSettings.smDegree) == nil {
            let infSmProgFile = progressFilePath(label: "inf_cmp_sm")
            let infSmRaw = runWithStderrOnFailure(
                "\"\(smBinary.path)\" -c -P \"\(infSmProgFile)\" \"\(smFile.path)\"",
                stdoutTo: smOut.path,
                label: "Spectral Method")
            let progress = withProgress(
                prefix: pad("Running spectral method ..."),
                command: infSmRaw,
                progressFile: infSmProgFile
            )
            runSM = independentStep(progress, label: "Spectral", token: "spectral", output: smOut)
        } else {
            let reason = smExportProblem
                ?? spectralResourceIssue(dimension: dimension, degree: appSettings.smDegree)
                ?? "solver unavailable"
            runSM = skippedStep(label: "Spectral", token: "spectral", reason: reason, output: smOut)
        }

        let runQNA: String
        if let qnaBinary, qnaContent != nil {
            let qnaRaw = runWithStderrOnFailure(
                "\"\(qnaBinary.path)\" \"\(qnaFile.path)\" -c",
                stdoutTo: qnaOut.path,
                label: "QNA"
            )
            runQNA = independentStep(
                withSpinner(prefix: pad("Running QNA ..."), command: qnaRaw),
                label: "QNA", token: "qna", output: qnaOut
            )
        } else {
            runQNA = skippedStep(
                label: "QNA", token: "qna",
                reason: qnaExportProblem ?? "solver unavailable", output: qnaOut
            )
        }
        let runRQNA: String
        if let rqnaBinary, qnaContent != nil {
            let rqnaRaw = runWithStderrOnFailure("\"\(rqnaBinary.path)\" \"\(rqnaFile.path)\" -c", stdoutTo: rqnaOut.path, label: "RQNA")
            runRQNA = independentStep(
                withSpinner(prefix: pad("Running RQNA ..."), command: rqnaRaw),
                label: "RQNA", token: "rqna", output: rqnaOut
            )
        } else {
            runRQNA = skippedStep(
                label: "RQNA", token: "rqna",
                reason: qnaExportProblem ?? "solver unavailable", output: rqnaOut
            )
        }
        let runSBD: String
        if let sbdBinary, qnaContent != nil {
            let bnetEnvironment = smBinary.map { "BNET_BIN=\(shellQuote($0.path)) " } ?? ""
            let sbdRaw = runWithStderrOnFailure(
                "\(bnetEnvironment)\"\(sbdBinary.path)\" \"\(sbdFile.path)\" -c",
                stdoutTo: sbdOut.path,
                label: "SBD"
            )
            runSBD = independentStep(
                withSpinner(prefix: pad("Running SBD ..."), command: sbdRaw),
                label: "SBD", token: "sbd", output: sbdOut
            ) + """

            { if grep -q '^QNET_SBD_STATUS_V1 fallback_used=yes' \(shellQuote(sbdOut.path)); then
                CMP_FAILED="${CMP_FAILED}sbd-fallback,";
                printf 'SBD used a fallback after an internal spectral subproblem failed; retaining it as a partial column.\n';
              fi; }
            """
        } else {
            runSBD = skippedStep(
                label: "SBD", token: "sbd",
                reason: qnaExportProblem ?? "solver unavailable", output: sbdOut
            )
        }
        let comparisonSeed = appSettings.simSeedFixed
            ? max(0, appSettings.simSeed)
            : Int.random(in: 1...Int(Int32.max))
        let runSim: String
        if let simBinary, simContent != nil {
            let simProgFile = progressFilePath(label: "inf_cmp_sim")
            let simRaw = runWithStderrOnFailure(
                "\"\(simBinary.path)\" \"\(simFile.path)\" -c -n \(appSettings.simReplications) -w \(appSettings.simWarmup) -r \(appSettings.simTime) -s \(comparisonSeed) -P \"\(simProgFile)\"",
                stdoutTo: simOut.path,
                label: "Simulation")
            runSim = independentStep(
                withProgress(prefix: pad("Running simulation ..."), command: simRaw, progressFile: simProgFile),
                label: "Simulation", token: "simulation", output: simOut
            )
        } else {
            runSim = skippedStep(
                label: "Simulation", token: "simulation",
                reason: simExportProblem ?? "solver unavailable", output: simOut
            )
        }

        // Unified comparison awk — emits an extra "Exact Result" column when
        // the network is tractable and makes the analytical value the
        // reference for all E[Q_k] deltas.
        let analyticalPath = writeAnalyticalFile(varName: "Q")
        let awkScript = buildComparisonAwk(
            outputs: [
                (file: smOut.path,  label: "Spectral"),
                (file: qnaOut.path, label: "QNA"),
                (file: rqnaOut.path, label: "RQNA"),
                (file: sbdOut.path, label: "SBD"),
                (file: simOut.path, label: "Simulation"),
            ],
            varName: "Q",
            showGamma: true,
            showSojourn: true,
            showXClass: false,
            analyticalPath: analyticalPath,
            analyticalLabel: activeEditor.tractabilityMeansLabel,
            analyticalIsExact: activeEditor.tractabilityIsExact,
            showAverageAlgorithm: true
        )
        let hdr = tractabilityHeader()
        let regime = regimeHeader(infiniteBuffers: true)
        let bannerParts = [regime, hdr].filter { !$0.isEmpty }
        let hdrPrefix = bannerParts.isEmpty ? "" : "\(bannerParts.joined(separator: " && ")) && "

        let statusTrailer = """
        if [ "$CMP_SUCCEEDED" -eq 0 ]; then
          echo 'QNET_COMPARISON_STATUS_V1 partial=yes successful=0 failed=all'
          exit 70
        elif [ -n "$CMP_FAILED" ]; then
          echo "QNET_COMPARISON_STATUS_V1 partial=yes successful=$CMP_SUCCEEDED failed=${CMP_FAILED%,}"
        else
          echo "QNET_COMPARISON_STATUS_V1 partial=no successful=$CMP_SUCCEEDED"
        fi
        """
        let command = """
        \(threadCountBannerMixed())
        CMP_FAILED=''
        CMP_SUCCEEDED=0
        \(runSM)
        \(runQNA)
        \(runRQNA)
        \(runSBD)
        \(runSim)
        echo
        \(hdrPrefix)\(awkScript)
        \(statusTrailer)
        """

        if runScript(
            command,
            label: "inf_cmp",
            parameters: [
                "spectral degree": appSettings.smDegree.description,
                "simulation replications": appSettings.simReplications.description,
                "simulation warm-up": appSettings.simWarmup.description,
                "simulation time": appSettings.simTime.description,
                "RQNA solver found": haveRQNA.description,
                "SBD solver found": haveSBD.description,
            ],
            seed: UInt64(comparisonSeed),
            replicationSeeds: (0..<appSettings.simReplications).map {
                UInt64(comparisonSeed + $0)
            }
        ) {
            activeEditor.addStatus("Running independent infinite-buffer comparison methods...", severity: .info)
        }
    }

    /// Builds the shell command to run the CTMC reference solver
    /// (`finite/fBNActmc/ctmc_dtandem.py`), or returns nil if the active
    /// network doesn't qualify. CTMC is exact but limited to:
    ///   * single customer class (K = 1)
    ///   * exponential service at every station + exponential source
    ///   * every external arrival enters station 1
    ///   * pure tandem topology (S_i → S_{i+1}, single path)
    ///   * loss-on-full semantics and one server per station
    ///   * d ≤ 4 and total state space ≤ 1,000 (∏(buffer_i + 2))
    /// When called from finite Run Comparison the result is added as a
    /// "CTMC (exact loss)" column; the SRBM solvers continue to be reported
    /// alongside it. `outputPath` is the file the solver should write
    /// its `-grid`-format output to.
    private func buildCTMCRunCommand(
        blocking: Int,
        outputPath: String,
        spinnerPad: (String) -> String
    ) -> (command: String, runtimeProvenance: String)? {
        // 1) The compact dense solver implements loss-on-full only. True BAS
        // needs an explicit blocked-server state and is intentionally omitted.
        guard blocking == 0 else { return nil }
        // 2) Compute SRBM data — gives us routing, arrivals, and service rates.
        let dataResult = SRBMExporter.computeData(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: false)
        guard case .success(let data) = dataResult else { return nil }
        // 3) Single-class only.
        guard data.K == 1 else { return nil }
        // 4) d ≤ 4 (state space cap below catches larger cases too).
        guard data.d >= 1 && data.d <= 4 else { return nil }
        // 5) Tandem topology: aggregatedP[i][i+1] = 1 (last row all zero).
        for i in 0..<data.d {
            for j in 0..<data.d {
                let p = data.aggregatedP[i][j]
                let expected: Double = (j == i + 1) ? 1.0 : 0.0
                if abs(p - expected) > 1e-6 { return nil }
            }
        }
        // 6) All service distributions exponential and exactly one server.
        let stations = activeEditor.nodes.filter { $0.kind == .station }
            .sorted { stationOrder($0.name) < stationOrder($1.name) }
        guard stations.count == data.d else { return nil }
        guard data.numberOfServers.allSatisfy({ $0 == 1 }) else { return nil }
        for st in stations {
            if st.distribution != .exponential { return nil }
            for (_, cfg) in st.serviceDistributions {
                if cfg.distribution != .exponential { return nil }
            }
        }
        // 7) Source Markovian (Poisson process ⇔ exponential inter-arrivals).
        let sources = activeEditor.nodes.filter { $0.kind == .source }
        guard sources.count == 1 else { return nil }
        let srcDist = sources[0].distribution
        guard srcDist == .exponential || srcDist == .poisson else {
            return nil
        }
        // The script has a scalar arrival parameter, so every external arrival
        // must enter S1. A split directly to a later station is a different CTMC.
        guard let external = data.classExternalArrivalRates.first,
              external.count == data.d,
              external[0].isFinite,
              external[0] > 0 else { return nil }
        let externalTolerance = max(1.0, external[0]) * 1e-10
        guard external.dropFirst().allSatisfy({
            $0.isFinite && abs($0) <= externalTolerance
        }) else { return nil }
        // 8) Buffer sizes per station.
        var buffers: [Int] = []
        for st in stations {
            let feed = activeEditor.nodes.filter { cand in
                cand.kind == .buffer &&
                activeEditor.links.contains { $0.fromNodeID == cand.id && $0.toNodeID == st.id }
            }
            guard let buf = feed.first else { return nil }
            buffers.append(buf.bufferSize)
        }
        // 9) Dense state-space cap. The solver materializes Q and Q^T and
        // performs an O(n^3) solve, so 50K states would require tens of GB.
        var stateSpace = 1
        for i in 0..<data.d {
            let factor = buffers[i] + data.numberOfServers[i] + 1
            guard factor > 0, stateSpace <= 1_000 / factor else { return nil }
            stateSpace *= factor
        }
        // 10) Build args.
        let lambda = external[0]
        let mu = data.serviceRates  // μ_eff per station (single-server tandem)
        let lookup = SolverRuntimeResolver.shared.resolvePythonSupportFile(
            name: "ctmc_dtandem.py",
            subdirectory: "fBNActmc",
            groups: ["finite"],
            requiredModules: ["numpy"]
        )
        guard let script = lookup.url,
              let python = lookup.resolution?.runtimeExecutableURL else {
            activeEditor.addStatus(
                "Exact tandem CTMC omitted: \(lookup.actionableDiagnostic)",
                severity: .warning
            )
            return nil
        }

        let bufStr = buffers.map(String.init).joined(separator: " ")
        let svrStr = data.numberOfServers.map(String.init).joined(separator: " ")
        let muStr  = mu.map { String(format: "%.10g", $0) }.joined(separator: " ")
        let invocation = "\(shellQuote(python.path)) -B \(shellQuote(script.path)) --buffers \(bufStr) --servers \(svrStr) " +
            "--lam \(String(format: "%.10g", lambda)) --mu \(muStr) " +
            "--mode loss --grid"
        let checked = runWithStderrOnFailure(
            invocation,
            stdoutTo: outputPath,
            label: "Exact loss-tandem CTMC"
        )
        // This reference column is optional. A runtime/input failure remains
        // visible and marks the comparison Partial, while the independent
        // spectral/FEM/LP/simulation columns are still allowed to finish.
        let tolerant = """
        ( \(checked) )
        _ctmc_rc=$?
        if [ $_ctmc_rc -ne 0 ]; then
          printf 'QNET_METHOD_FAILURE_V1 method=ctmc exit=%s\\n' "$_ctmc_rc" > \(shellQuote(outputPath))
          printf 'Continuing comparison without the exact loss-tandem CTMC column.\\n'
          printf 'QNET_COMPARISON_STATUS_V1 partial=yes successful=other failed=ctmc\\n'
        fi
        exit 0
        """
        return (
            command: withSpinner(
                prefix: spinnerPad("Running CTMC (exact loss) ..."),
                command: tolerant
            ),
            runtimeProvenance: lookup.resolution?.provenanceDescription ?? "unknown"
        )
    }

    private func stationOrder(_ name: String) -> Int {
        let digits = name.drop(while: { !$0.isNumber })
        return Int(digits) ?? Int.max
    }

    /// Writes the closed-form / asymptotic means to a temp file in -G-style
    /// `E[<var>_k] = value` format and returns the path, or nil if the active
    /// network isn't tractable.
    private func writeAnalyticalFile(varName: String) -> String? {
        let editor = activeEditor
        guard editor.isAnalyticallyTractable, !editor.tractabilityMeans.isEmpty else {
            return nil
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_analytical_\(pid).txt")
        var lines = [String]()

        // Per-station exact arrival/service rates from the SRBM exporter.
        // These let us include rho_k, Gamma_k, and sojourn_k in the
        // analytical column — not just E[X_k] / E[Q_k]. Effective arrival
        // rate α_k IS the exact throughput Γ_k (in steady state, what
        // enters leaves). ρ_k = α_k / (s_k · μ_k). Sojourn = E[Q_k] / Γ_k
        // by Little's Law. For Jackson exact and skew-symmetric exact
        // these are exact; for the GCDG asymptotic branches, ρ_k and
        // Γ_k remain exact (linear traffic equations) while sojourn
        // inherits the asymptotic E[X_k].
        let exportResult = SRBMExporter.computeData(
            nodes: editor.nodes,
            links: editor.links,
            infiniteBuffers: editor.infiniteBuffers
        )
        // Every value below is written with %.17g, not a fixed number of
        // fraction digits. This file is a private machine handoff to
        // buildComparisonAwk (it is never shown to anyone), and awk's
        // `v+0` parses %.17g — exponent and all — exactly. Writing %.6f
        // here used to cap the Exact Result column at six real digits, so
        // asking for 9 decimals printed six true digits followed by three
        // fabricated zeros beside honestly-rounded algorithm columns.
        // %.17g round-trips a Double, and fmt7 then rounds the column to
        // whatever precision the user actually asked for.
        if case .success(let data) = exportResult,
           data.d == editor.tractabilityMeans.count {
            for k in 0..<data.d {
                let rho = data.capacity[k] > 1e-12
                    ? data.alpha[k] / data.capacity[k] : 0.0
                lines.append(String(format: "rho_%d = %.17g", k + 1, rho))
            }
            for k in 0..<data.d {
                lines.append(String(format: "Gamma_%d = %.17g", k + 1, data.alpha[k]))
            }
            for k in 0..<data.d {
                let g = data.alpha[k]
                let soj = g > 1e-12 ? editor.tractabilityMeans[k] / g : 0.0
                lines.append(String(format: "sojourn_%d = %.17g", k + 1, soj))
            }
        }

        for (i, m) in editor.tractabilityMeans.enumerated() {
            lines.append(String(format: "E[%@_%d] = %.17g", varName, i + 1, m))
        }
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return file.path
    }

    /// Returns a short "──── <tractability detail> ────" header printed
    /// before a comparison table when the network is tractable. Empty string
    /// otherwise.
    private func tractabilityHeader() -> String {
        let editor = activeEditor
        guard editor.isAnalyticallyTractable else { return "" }
        let detail = editor.tractabilityDetail.isEmpty
            ? "Analytical product form"
            : editor.tractabilityDetail
        let escaped = detail.replacingOccurrences(of: "'", with: "'\\''")
        return "printf '──  \(escaped)  ──\\n'"
    }

    /// Returns a one-line "Network load: ρ_max = 0.xx (note)" banner that
    /// appears above every Run Comparison table. The banner sets user
    /// expectations: SRBM and the finite-element method are heavy-traffic
    /// limits, so disagreement with the simulator is expected at moderate
    /// load (ρ < 0.9) and shrinks as ρ → 1. Returns "" if ρ_max cannot be
    /// computed (network export fails).
    private func regimeHeader(infiniteBuffers: Bool) -> String {
        let result = SRBMExporter.computeData(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: infiniteBuffers
        )
        guard case .success(let data) = result else { return "" }
        var rhos = [Double](repeating: 0, count: data.d)
        var rhoMax = 0.0
        var argMax = 0
        for i in 0..<data.d {
            rhos[i] = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : 0.0
            if rhos[i] > rhoMax { rhoMax = rhos[i]; argMax = i }
        }
        let rhoNote: String = {
            if rhoMax >= 0.95 {
                return "heavy-traffic regime — analytical methods are most accurate here"
            } else if rhoMax >= 0.85 {
                return "near heavy-traffic — small O(1) deviation expected"
            } else {
                return "moderate load — SRBM/FEM are heavy-traffic limits; expect deviation from simulation"
            }
        }()
        var lines: [String] = []
        lines.append(String(
            format: "Network load: rho_max = %.4f at S%d  (%@)",
            rhoMax, argMax + 1, rhoNote
        ))

        // Feedback indicator: QNA's variability fixed-point assumes light
        // feedback (Whitt 1983), so heavy rework loops can degrade the
        // QNA column noticeably. SBD on cycles was validated against
        // Dai-Nguyen-Reiman (1994) — see validation/sbd_cyclic_validation.md.
        if AnalyticalTractability.hasRoutingCycles(data.aggregatedP) {
            lines.append(
                "Routing graph contains feedback (cycle or self-loop) — QNA may degrade under heavy load; use queue-process simulation with confidence intervals as the reference"
            )
        }

        // Heavy-traffic buffer-scaling diagnostic (finite networks only).
        // SRBM theory expects b_n ~ sqrt(n) and (1 - rho_n) ~ 1/sqrt(n), so
        // the product b_i * (1 - rho_i) is the natural scaling invariant —
        // it should be O(1) in the heavy-traffic limit. We flag stations
        // where this ratio is far from O(1):
        //   < 1.0  : buffer is binding hard relative to rho — the SRBM
        //            diffusion limit overestimates queue length and
        //            underestimates loss; expect 10-20% deviation.
        //   > 10   : buffer is effectively infinite for this rho — the
        //            finite-buffer correction is negligible and an
        //            infinite-buffer model would give the same answer.
        // We only diagnose stations with rho >= 0.50; below that the
        // SRBM approximation is loose for unrelated reasons (low-rho
        // diffusion error) and the b*(1-rho) scaling isn't the issue.
        if !infiniteBuffers {
            // Total per-station state-space capacity K_i = bufferSize_i +
            // numServers_i (waiting room plus in-service slot). Walk the
            // nodes the same way SRBMExporter does so indices line up.
            let stationNodes = activeEditor.nodes.filter { $0.kind == .station }
            var Ks = [Int](repeating: 0, count: data.d)
            for (idx, station) in stationNodes.enumerated() where idx < data.d {
                let bSize = activeEditor.nodes.first(where: { cand in
                    cand.kind == .buffer &&
                    activeEditor.links.contains { $0.fromNodeID == cand.id && $0.toNodeID == station.id }
                })?.bufferSize ?? 0
                Ks[idx] = bSize + station.numberOfServers
            }

            // Heavy-traffic invariant K_i * (1 - rho_i). Should be O(1) in
            // the SRBM diffusion limit. Flag stations with rho >= 0.50 only
            // (low-rho diffusion error is unrelated to buffer scaling).
            var worstSmall: (i: Int, ratio: Double)? = nil
            var worstLarge: (i: Int, ratio: Double)? = nil
            for i in 0..<data.d {
                guard rhos[i] >= 0.5, Ks[i] > 0 else { continue }
                let ratio = Double(Ks[i]) * (1.0 - rhos[i])
                if ratio < 1.0 {
                    if worstSmall == nil || ratio < worstSmall!.ratio {
                        worstSmall = (i, ratio)
                    }
                } else if ratio > 10.0 {
                    if worstLarge == nil || ratio > worstLarge!.ratio {
                        worstLarge = (i, ratio)
                    }
                }
            }
            if let w = worstSmall {
                lines.append(String(
                    format: "Buffer regime: K*(1-rho) = %.2f at S%d (K=%d, rho=%.3f) — small for the heavy-traffic limit (target ~1-5); SRBM may overstate E[X] / understate loss by 10-20%%",
                    w.ratio, w.i + 1, Ks[w.i], rhos[w.i]
                ))
            } else if let w = worstLarge {
                lines.append(String(
                    format: "Buffer regime: K*(1-rho) = %.1f at S%d (K=%d, rho=%.3f) — buffer is effectively infinite at this rho; finite-buffer correction is negligible",
                    w.ratio, w.i + 1, Ks[w.i], rhos[w.i]
                ))
            }
        }

        let escaped = lines.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
        let payload = escaped.map { "'\($0)'" }.joined(separator: " ")
        return "printf '%s\\n' \(payload)"
    }

    /// Builds a unified side-by-side comparison awk script that parses one or
    /// more -G-format output files and optionally an analytical file, then
    /// emits a metric-by-method table. When an analytical file is supplied,
    /// the table gains an extra `Exact Result` column and every E[X_k] row
    /// delta is measured against the analytical value (rho / Gamma / sojourn
    /// fall back to the last method as reference since they have no
    /// closed-form analogue in the general case).
    ///
    /// - Parameters:
    ///   - outputs: one entry per method solver, in the order files appear on
    ///              the awk command line.
    ///   - varName: "X" for finite buffers (E[X_k]), "Q" for infinite (E[Q_k]).
    ///   - showGamma / showSojourn / showXClass: include optional metric rows.
    ///   - analyticalPath: if non-nil, appended as the last file; enables the
    ///                     Exact Result column.
    private func buildComparisonAwk(
        outputs: [(file: String, label: String)],
        varName: String,
        showGamma: Bool,
        showSojourn: Bool,
        showXClass: Bool,
        analyticalPath: String?,
        analyticalLabel: String? = nil,
        analyticalIsExact: Bool = true,
        showAverageAlgorithm: Bool = false
    ) -> String {
        let n = outputs.count
        let hasAn = analyticalPath != nil
        // Average-Algorithm column: ensemble mean of every method output
        // EXCEPT the last (which Run Comparison reserves for simulation).
        // We require ≥ 2 algorithm columns to add it — with only one
        // algorithm + sim the average is identical to the algorithm
        // value, so the column adds noise. Skip silently otherwise.
        let hasAvg = showAverageAlgorithm && n >= 3
        let totalFiles = hasAn ? n + 1 : n

        // Per-metric reference index. The analytical file carries exact
        // ρ_k, Γ_k, sojourn_k AND E[VAR_k] (see writeAnalyticalFile).
        //
        //   - When the analytical is EXACT (Jackson, skew-symmetric),
        //     it is the truth — use it as reference for every metric.
        //   - When the analytical is ASYMPTOTIC (GCDG branches), it can
        //     differ substantially from the queueing-system truth at
        //     finite ρ. Using it as the reference would make every
        //     algorithm column show large %-deltas that look like
        //     algorithm errors but are actually asymptotic-vs-truth
        //     discrepancies. Use the last method (typically simulation)
        //     as the reference instead.
        //   - Without analytical, fall back to the last method.
        //   - For a single-method run with no analytical column there
        //     is no meaningful reference — pass empty so fmtv just
        //     formats the value without the (+0.0%) tag.
        let refMethod = n                    // 1-based awk index for last method
        let noRef = n == 1 && !hasAn
        let useAnRef = hasAn && analyticalIsExact
        let refEx  = useAnRef ? "an[k]"    : (noRef ? "\"\"" : "ex[\(refMethod),k]")
        let refRho = useAnRef ? "an_rh[k]" : (noRef ? "\"\"" : "rh[\(refMethod),k]")
        let refGm  = useAnRef ? "an_gm[k]" : (noRef ? "\"\"" : "gm[\(refMethod),k]")
        let refSj  = useAnRef ? "an_sj[k]" : (noRef ? "\"\"" : "sj[\(refMethod),k]")
        let refXc  = noRef ? "\"\"" : "xc[\(refMethod),k]"

        // 1-based column indices:
        //   1               row label
        //   2..n+1          method outputs (sim is at column n+1)
        //   n+2             Average Algorithm  (when hasAvg)
        //   n+2 / n+3       Analytical         (when hasAn; +1 if avg present)
        let avgCol = n + 2
        let anCol  = hasAn ? (hasAvg ? n + 3 : n + 2) : 0
        let ncols  = n + 1 + (hasAvg ? 1 : 0) + (hasAn ? 1 : 0)
        let anEm   = hasAn ? "C[R,\(anCol)]=\"—\";" : ""

        // ── AWK body ─────────────────────────────────────────────
        // Strategy: parse all output files into per-method arrays
        // (rh, gm, sj, xc, ex) and an optional analytical array (an).
        // In END, build every printed row into a 2D buffer C[R,col],
        // then compute the max width of each column, and finally
        // print rows using those widths with a 2-space gutter. This
        // keeps headers and value rows aligned regardless of how
        // wide individual values turn out to be.
        var awk = "awk '"
        awk += "FNR==1{f++}"
        awk += "/^=/{next}/^$/{next}"
        awk += "function parsci(s){gsub(/[()]/,\"\",s);return s}"
        awk += "f<=\(n){"
        awk += "if($0~/^rho_/){s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;rh[f,k]=$3;if(NF>=4&&$4~/^\\(/)ci_rh[f,k]=parsci($4);if(k>dr)dr=k;next}"
        awk += "if($0~/^Gamma_/){s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;gm[f,k]=$3;if(NF>=4&&$4~/^\\(/)ci_gm[f,k]=parsci($4);if(k>dg)dg=k;next}"
        awk += "if($0~/^sojourn_/){s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;sj[f,k]=$3;if(NF>=4&&$4~/^\\(/)ci_sj[f,k]=parsci($4);if(k>ds)ds=k;next}"
        awk += "if($0~/^X\\(class/){s=$2;gsub(/[^0-9]/,\"\",s);k=s+0;xc[f,k]=$4;if(NF>=5&&$5~/^\\(/)ci_xc[f,k]=parsci($5);if(k>dxc)dxc=k;next}"
        awk += "if($0~/^E\\[\(varName)_/){s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;ex[f,k]=$3;if(NF>=4&&$4~/^\\(/)ci_ex[f,k]=parsci($4);if(k>dx)dx=k;next}"
        awk += "}"
        if hasAn {
            // Analytical file carries rho_k / Gamma_k / sojourn_k / E[VAR_k]
            // (writeAnalyticalFile emits all four for tractable networks).
            // Parse each into its own analytical array so the render loop
            // below can fill the Exact Result column for every metric row.
            awk += "f==\(totalFiles)&&/^rho_/{s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;an_rh[k]=$3;if(k>dr)dr=k;next}"
            awk += "f==\(totalFiles)&&/^Gamma_/{s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;an_gm[k]=$3;if(k>dg)dg=k;next}"
            awk += "f==\(totalFiles)&&/^sojourn_/{s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;an_sj[k]=$3;if(k>ds)ds=k;next}"
            awk += "f==\(totalFiles)&&/^E\\[\(varName)_/{s=$1;gsub(/[^0-9]/,\"\",s);k=s+0;an[k]=$3;if(k>dx)dx=k;next}"
        }
        awk += "function eqline(n){s=\"\";for(i=0;i<n;i++)s=s\"=\";return s}"
        // fmt7 (legacy name; now configurable): fixed-decimal-place
        // formatting controlled by Settings ▸ Output Format ▸ Output
        // decimals. Empty strings and em-dashes pass through.
        //
        // The magnitude policy is deliberately the same one the terminal's
        // display-precision filter applies (see `outputPrecisionFilter`):
        // below 10^-decimals a fixed format prints "0.000" for a value that
        // is not zero, so switch to scientific with one digit fewer. Sharing
        // the policy is what makes these tables idempotent under the filter —
        // the filter re-reads what fmt7 wrote and must reproduce it exactly,
        // character for character, or every awk-computed column width shears.
        let decimals = max(0, min(9, appSettings.outputDecimals))
        let sciDigits = max(1, decimals - 1)
        // Exact power of ten, written as a literal so no rounding creeps in.
        // At 0 decimals there is no scientific fallback at all — the user
        // asked for whole numbers, and DS.Number.display (the same rule for
        // the Swift-rendered surfaces) makes the same call. A threshold of 0
        // makes the small-magnitude test vacuously false, which is what
        // switches the fallback off.
        let smallest = decimals == 0 ? "0" : "1e-\(decimals)"
        // The symmetric upper guard. A fixed rendering of 3.456789e+20 is
        // twenty-one digits of floating-point noise the solver never computed,
        // and it shears whatever column it lands in; above 1e9 fall back to
        // scientific exactly as the small case does. The terminal filter uses
        // the same 1e9 line, which is what keeps the two idempotent.
        let largest = "1e9"
        awk += "function absv(x){return x<0?-x:x}"
        // A displayed "-0.000" reads as a sign error rather than as a small
        // negative, so a signed zero loses its sign here, in the filter, and
        // in DS.Number.display. Stripping happens before the column widths are
        // computed, so it cannot shear a table.
        awk += "function nz(s){return s ~ /^-0(\\.0*)?$/ ? substr(s,2) : s}"
        awk += "function fmt7(v,  x){if(v==\"\"||v==\"—\")return v;x=v+0;"
        awk += "if(x!=0&&(absv(x)<\(smallest)||absv(x)>=\(largest)))"
        awk += "return nz(sprintf(\"%.\(sciDigits)e\",x));"
        awk += "return nz(sprintf(\"%.\(decimals)f\",x))}"
        // fmtv renders one cell: "value ± half (+delta%)". Empty -> em-dash;
        // no usable reference -> the formatted value alone. The percent is
        // computed on values ROUNDED to the displayed precision, so two
        // values that print identically always show 0.0% and the delta
        // scales naturally when the user changes Output decimals; if the
        // reference rounds to 0 the percent is dropped rather than divided
        // by a quantized zero. No padding here — column widths are computed
        // after every row is built.
        //
        // The ± half-width is the whole point of a replicated simulation and
        // it used to be parsed into ci_rh/ci_gm/ci_sj/ci_xc/ci_ex and then
        // never read again — a fifty-replication Monte Carlo printed a bare
        // number. It is emitted only for the columns that actually reported
        // one, so no analytical method is given a fabricated interval and a
        // five-method table does not double in width.
        //
        // Order matters: ± half comes BEFORE the (+x.x%) delta, because
        // ResultOutputParser strips a trailing "(…%)" before reading the row,
        // and what must survive that strip is "value ± half".
        //
        // vr/rr round through fmt7 itself rather than repeating its format
        // string: the delta must be computed on exactly the numbers the user
        // can see, so when fmt7 falls back to scientific the comparison has
        // to fall back with it. awk's string→number conversion parses an
        // exponent, so fmt7's scientific output round-trips through `+0`.
        awk += "function fmtv(v,ref,ci,  s,vr,rr){if(v==\"\")return \"—\";s=fmt7(v);"
        awk += "if(ci!=\"\")s=s\" ± \"fmt7(ci);"
        awk += "if(ref==\"\"||ref+0==0)return s;vr=fmt7(v)+0;rr=fmt7(ref)+0;if(rr==0)return s;"
        awk += "return sprintf(\"%s (%+.1f%%)\",s,(vr-rr)/rr*100)}"
        // Display width, not byte length. awk's length() counts bytes, and
        // the two non-ASCII characters these tables print — the em-dash
        // placeholder (3 bytes) and ± (2) — would otherwise be padded as if
        // they were three and two columns wide, so a row holding one landed
        // two characters left of the rows around it.
        awk += "function dwid(s,  n,t){t=s;n=length(t);n-=2*gsub(/—/,\"\",t);n-=gsub(/±/,\"\",t);return n}"
        awk += "function idxw(n){w=1;t=n;while(t>=10){w++;t=int(t/10)}return w}"
        awk += "END{"
        awk += "wr=idxw(dr);wg=idxw(dg);wsj=idxw(ds);wxc=idxw(dxc);wx=idxw(dx);"
        awk += "R=0;NC=\(ncols);"

        // Header row
        awk += "R++;G[R]=0;C[R,1]=\"\";"
        for (i, o) in outputs.enumerated() {
            let label = o.label.replacingOccurrences(of: "'", with: "'\\''")
            awk += "C[R,\(i+2)]=\"\(label)\";"
        }
        if hasAvg {
            awk += "C[R,\(avgCol)]=\"Average of Algorithms\";"
        }
        if hasAn {
            // Header for the analytical column. Default to "Exact Result"
            // for backward compatibility, but callers should pass the
            // editor's `tractabilityMeansLabel` so the header reflects
            // exact vs asymptotic kinds (e.g., "Exact E[N]  (Jackson)"
            // vs "Asymptotic E[X]"). This is critical for re-entrant or
            // mixed-ρ networks where the GCDG asymptotic can differ
            // substantially from algorithm/simulation values — calling
            // it "Exact Result" was misleading.
            let trimmed = (analyticalLabel ?? "").trimmingCharacters(in: .whitespaces)
            let label = trimmed.isEmpty ? "Exact Result" : trimmed
            let escaped = label.replacingOccurrences(of: "'", with: "'\\''")
            awk += "C[R,\(anCol)]=\"\(escaped)\";"
        }

        // Separator row (blank line follows)
        awk += "R++;G[R]=1;C[R,1]=\"\";"
        for (i, o) in outputs.enumerated() {
            awk += "C[R,\(i+2)]=eqline(\(o.label.count));"
        }
        if hasAvg { awk += "C[R,\(avgCol)]=eqline(21);" }
        if hasAn  { awk += "C[R,\(anCol)]=eqline(12);" }

        // When the analytical file is present, fill the Exact Result
        // column with the parsed an_*[k] value; otherwise hold the
        // em-dash. fmt7 passes empty strings through unchanged so
        // missing entries still render as "—".
        let rhoAnFill = hasAn ? "C[R,\(anCol)]=an_rh[k]==\"\"?\"—\":fmt7(an_rh[k]);" : ""
        let gmAnFill  = hasAn ? "C[R,\(anCol)]=an_gm[k]==\"\"?\"—\":fmt7(an_gm[k]);" : ""
        let sjAnFill  = hasAn ? "C[R,\(anCol)]=an_sj[k]==\"\"?\"—\":fmt7(an_sj[k]);" : ""

        // Average-Algorithm cell builder. Averages every algorithm
        // column (1..n−1, since column n is the simulation reference)
        // for the current row and renders "value (±%)" against the
        // simulation cell. Skips empty cells so a missing method
        // doesn't pull the mean toward zero.
        //
        // `arr` is the awk array to read (rh / gm / sj / xc / ex) and
        // `ref` is the simulation reference for the % delta. When the
        // average column isn't requested both helpers expand to "" and
        // the row generator uses the legacy form.
        func avgFill(arr: String, ref: String) -> String {
            guard hasAvg else { return "" }
            var s = "_s=0;_c=0;"
            for i in 1..<n {
                s += "if(\(arr)[\(i),k]!=\"\"){_s+=\(arr)[\(i),k]+0;_c++}"
            }
            // No half-width: the mean of several methods' point estimates is
            // not a sampling distribution, and giving it an error bar would
            // claim a precision nobody computed.
            s += "if(_c>0)C[R,\(avgCol)]=fmtv(_s/_c,\(ref),\"\");else C[R,\(avgCol)]=\"—\";"
            return s
        }

        // rho rows
        awk += "for(k=1;k<=dr;k++){R++;G[R]=0;"
        awk += "C[R,1]=sprintf(\"rho_%0*d\",wr,k);"
        for i in 1...n {
            awk += "C[R,\(i+1)]=fmtv(rh[\(i),k],\(refRho),ci_rh[\(i),k]);"
        }
        awk += avgFill(arr: "rh", ref: refRho)
        awk += rhoAnFill.isEmpty ? anEm : rhoAnFill
        awk += "}if(dr>0)G[R]=1;"

        // Gamma rows (optional)
        if showGamma {
            awk += "for(k=1;k<=dg;k++){R++;G[R]=0;"
            awk += "C[R,1]=sprintf(\"Gamma_%0*d\",wg,k);"
            for i in 1...n {
                awk += "C[R,\(i+1)]=fmtv(gm[\(i),k],\(refGm),ci_gm[\(i),k]);"
            }
            awk += avgFill(arr: "gm", ref: refGm)
            awk += gmAnFill.isEmpty ? anEm : gmAnFill
            awk += "}if(dg>0)G[R]=1;"
        }

        // sojourn rows (optional)
        if showSojourn {
            awk += "for(k=1;k<=ds;k++){R++;G[R]=0;"
            awk += "C[R,1]=sprintf(\"sojourn_%0*d\",wsj,k);"
            for i in 1...n {
                awk += "C[R,\(i+1)]=fmtv(sj[\(i),k],\(refSj),ci_sj[\(i),k]);"
            }
            awk += avgFill(arr: "sj", ref: refSj)
            awk += sjAnFill.isEmpty ? anEm : sjAnFill
            awk += "}if(ds>0)G[R]=1;"
        }

        // X(class) rows (optional, for -c infinite format)
        if showXClass {
            awk += "for(k=1;k<=dxc;k++){R++;G[R]=0;"
            awk += "C[R,1]=sprintf(\"X(class %0*d)\",wxc,k);"
            for i in 1...n {
                awk += "C[R,\(i+1)]=fmtv(xc[\(i),k],\(refXc),ci_xc[\(i),k]);"
            }
            awk += avgFill(arr: "xc", ref: refXc)
            awk += anEm
            awk += "}if(dxc>0)G[R]=1;"
        }

        // E[VAR_k] rows — analytical is reference when present and the
        // analytical column carries an[k] rather than an em-dash.
        let exAnFill = hasAn ? "C[R,\(anCol)]=fmt7(an[k]);" : ""
        awk += "for(k=1;k<=dx;k++){R++;G[R]=0;"
        awk += "C[R,1]=sprintf(\"E[\(varName)_%0*d]\",wx,k);"
        for i in 1...n {
            awk += "C[R,\(i+1)]=fmtv(ex[\(i),k],\(refEx),ci_ex[\(i),k]);"
        }
        awk += avgFill(arr: "ex", ref: refEx)
        awk += exAnFill
        awk += "}if(dx>0)G[R]=1;"

        // Compute max width per column across every row that will be
        // printed (header + separator + every metric row), then emit
        // each row left-padded to that per-column width with a
        // 2-space gutter between columns. The last column has no
        // gutter so trailing whitespace doesn't bloat the line.
        awk += "for(c=1;c<=NC;c++)mw[c]=0;"
        awk += "for(r=1;r<=R;r++)for(c=1;c<=NC;c++){l=dwid(C[r,c]);if(l>mw[c])mw[c]=l}"
        awk += "for(r=1;r<=R;r++){"
        awk += "for(c=1;c<=NC;c++){"
        // Padding is counted, not delegated to printf's %-*s, because that
        // pads by bytes and these cells can hold a multi-byte character.
        awk += "printf \"%s\",C[r,c];"
        awk += "if(c<NC){p=mw[c]-dwid(C[r,c])+2;while(p>0){printf \" \";p--}}"
        awk += "}printf \"\\n\";"
        awk += "if(G[r])printf \"\\n\""
        awk += "}"

        awk += "}' "
        for o in outputs { awk += "\"\(o.file)\" " }
        if let a = analyticalPath { awk += "\"\(a)\" " }
        return awk.trimmingCharacters(in: .whitespaces)
    }

    /// Formats one single-method run as the same vertical metric-per-row
    /// table Run Comparison prints. When the network is tractable an Exact
    /// Result column with % deltas is appended beside the method's own.
    private func singleMethodFormatCmd(
        outFile: String,
        methodLabel: String,
        varName: String,
        showGamma: Bool,
        showSojourn: Bool,
        showXClass: Bool
    ) -> String {
        // Always use the comparison-style awk so single-method runs print
        // the same vertical metric-per-row layout as Run Comparison —
        // critical for networks with many stations, where the older
        // station-major horizontal layout (one column per station) would
        // run off the right edge of the terminal. The analytical column
        // is appended only when the network is tractable; otherwise the
        // table is just (row label | method value). The station-major
        // layout it replaced (`stationFilterCmd`) was kept behind a
        // `fallback:` parameter that was assigned and discarded on every
        // run; both are gone.
        let analytic = writeAnalyticalFile(varName: varName)
        let awk = buildComparisonAwk(
            outputs: [(file: outFile, label: methodLabel)],
            varName: varName,
            showGamma: showGamma,
            showSojourn: showSojourn,
            showXClass: showXClass,
            analyticalPath: analytic,
            analyticalLabel: activeEditor.tractabilityMeansLabel,
            analyticalIsExact: activeEditor.tractabilityIsExact
        )
        // Match Run Comparison's banner: regime line first (rho_max +
        // buffer-scaling note), then the tractability tag (when present),
        // then the table. Each banner part is a printf shell command that
        // emits one line; we chain them with && so they print before the
        // awk runs.
        let regime = regimeHeader(infiniteBuffers: activeEditor.infiniteBuffers)
        let hdr = tractabilityHeader()
        let bannerParts = [regime, hdr].filter { !$0.isEmpty }
        if bannerParts.isEmpty { return awk }
        return bannerParts.joined(separator: " && ") + " && " + awk
    }

    /// Writes a command to a temp script and executes it. The script
    /// erases the echoed `bash /tmp/...` line from the terminal, times
    /// the command, and prints an "Elapsed time: X.XXXs" line at the end.
    /// Dump a block of plain-text help to the integrated terminal pane.
    ///
    /// Written via a temp file and `cat` so that the help content is printed
    /// verbatim regardless of special characters — no quoting, no escape
    /// headaches.  The temp file is cleaned up immediately after.
    private func printHelpToTerminal(_ text: String, label: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_\(label)_\(pid).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            activeEditor.addStatus("Help (\(label)): failed to write temp file.", severity: .error)
            return
        }
        // Print, then remove.  `cat` then `rm`, both from a shell command so
        // they interleave correctly with the terminal's prompt management.
        let command = "cat \"\(file.path)\"; rm -f \"\(file.path)\""
        // Help is prose. Normalizing it turns "eq. 2.7" into "eq. 2.700000"
        // and "ρ in 0.7–0.95" into "0.700000–0.950000", and leaves the
        // sentence-final "default 1.0" alone, so one paragraph would carry
        // two number formats.
        runScript(command, label: label, normalizeNumbers: false)
    }

    /// Builds a shell fragment that runs a binary, captures its
    /// stderr to a sibling `.err` file, and:
    ///   - on a non-zero exit: dumps stderr to the Interactive Shell and
    ///     appends a labelled record to the status inbox so the GUI
    ///     surfaces it in the Status pane.
    ///   - on success: greps stderr for warning-like lines (matching
    ///     /warn/i, /unstable/i, /bramson/i, /vande[ -]?vate/i, /kumar[ -]?seidman/i,
    ///     /diverg/i, /caution/i) and surfaces those to the Status pane
    ///     even though the exit was clean. The remaining stderr (progress
    ///     prints, etc.) is discarded so it doesn't drown the results.
    ///
    /// Rationale: BNAqna prints a Dai-Vande Vate global-stability warning
    /// to stderr at high-ρ Kumar-Seidman / Bramson networks but exits 0;
    /// before this hook the warning never reached the user.
    ///
    /// `binaryAndArgs` should be the shell-quoted invocation up to
    /// (but not including) the stdout redirect — e.g.
    ///   "\"path/to/bnet\" \"input.bnet\" -G"
    /// `outPath` is the file stdout should land in.
    private func runWithStderrOnFailure(
        _ binaryAndArgs: String,
        stdoutTo outPath: String,
        label: String = "Solver"
    ) -> String {
        let escapedLabel = label.replacingOccurrences(of: "'", with: "'\\''")
        let errPath = outPath + ".err"
        // The run UUID does not exist yet while commands are assembled.
        // `runScript` / `silentScript` replace this marker with that run's
        // private inbox before the wrapper is written.
        let inboxPath = TerminalModel.statusInboxPlaceholder
        // Warning-line filter regex (extended awk syntax). Case-insensitive
        // via tolower(). Catches the documented stability warnings without
        // matching every solver progress line.
        let warnPattern = "warn|unstable|bramson|vande[ -]?vate|kumar[ -]?seidman|diverg|caution"
        return """
        { \(binaryAndArgs) > "\(outPath)" 2> "\(errPath)"; \
        _rc=$?; \
        if [ $_rc -ne 0 ]; then \
        printf '\\n⚠ \(escapedLabel) failed (exit %d):\\n' "$_rc"; \
        cat "\(errPath)"; \
        { printf '⚠ \(escapedLabel) failed (exit %d):\\n' "$_rc"; cat "\(errPath)"; printf '<<<END>>>\\n'; } >> "\(inboxPath)"; \
        rm -f "\(errPath)"; \
        exit $_rc; \
        fi; \
        if [ -s "\(errPath)" ]; then \
        _warns=$(awk 'BEGIN{IGNORECASE=1} tolower($0) ~ /\(warnPattern)/ { print }' "\(errPath)"); \
        if [ -n "$_warns" ]; then \
        { printf '⚠ \(escapedLabel) warnings:\\n%s\\n<<<END>>>\\n' "$_warns"; } >> "\(inboxPath)"; \
        fi; \
        fi; \
        rm -f "\(errPath)"; }
        """
    }

    /// Returns a unique progress-file path used by simulators that
    /// support the `-P PATH` flag (jackson_sim, fBNAsim). Each call
    /// suffixes a fresh nanosecond timestamp so concurrent runs in
    /// the same process don't share the file.
    private func progressFilePath(label: String) -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1_000_000)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_progress_\(label)_\(pid)_\(stamp).bin")
            .path
        // The status bar polls the same file the shell's ASCII bar does,
        // so a solver that reports a total gets a determinate bar and a
        // percentage there too (TerminalModel.beginRun picks these up).
        terminalModel.registerProgressFile(path)
        return path
    }

    /// Wraps a solver/simulator command (already configured with `-P
    /// <progressFile>` so the binary emits a `<total>\n` header
    /// followed by one '.' byte per completed unit) with a shell
    /// pattern that:
    ///   1. truncates the progress file,
    ///   2. prints a placeholder line so the prefix and an empty bar
    ///      appear immediately,
    ///   3. backgrounds the binary,
    ///   4. polls the progress file every 200 ms — first reads the
    ///      header for the total, then re-emits a `\r<prefix>[bar]
    ///      k/N (x%)` line as the byte count grows,
    ///   5. once the bar reaches 100% but the binary is still running
    ///      (typical of opaque post-assembly phases like Cholesky/CBC
    ///      solves), animates a 4-frame spinner appended to the
    ///      finished bar so the user sees the process is still alive,
    ///   6. waits for the binary and propagates its exit code so
    ///      callers can chain with `&&` exactly as before, then
    ///      finishes with a newline.
    /// Bar width is 30 columns. The prefix should already include any
    /// trailing spaces the caller wants between text and bar.
    private func withProgress(
        prefix: String,
        command: String,
        progressFile: String,
        barWidth: Int = 15
    ) -> String {
        // ANSI reverse-video produces a "white rectangle" effect (the
        // cell's background becomes the foreground colour, which on the
        // default dark terminal scheme reads as a solid white block)
        // without using any multibyte Unicode — SwiftTerm and similar
        // embedded terminals can mishandle multibyte block characters
        // by rendering them as zero-width, which makes the bar appear
        // to collapse as it fills.
        //
        // Each logical position renders as 2 visible columns:
        //   filled = inverse-video space + plain space  ("█ ")
        //   empty  = plain space + plain space          ("  ")
        // The printf format interprets `\e[7m`/`\e[27m` directly; the
        // dynamic in-progress loop builds the same bytes via $'\e...'
        // (bash ANSI-C quoting). Default barWidth = 15 → 30 visible cols.
        let emptyBar = String(repeating: "  ", count: barWidth)
        let fullBar  = String(repeating: "\\e[7m \\e[27m ", count: barWidth)
        // Prefix is embedded in printf format strings — escape % and '
        // so it survives bash and printf intact. (The caller controls
        // the text and we want raw passthrough.)
        let escaped = prefix
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "'", with: "'\\''")
        // Fixed-column layout shared by bar and spinner so columns
        // align across rows in a Run Comparison. Widths are constants:
        //   [bar32] (2sp) ratio(11) (2sp) pct(6) (2sp) time(7)
        return """
        : > "\(progressFile)" ; \
        printf '\(escaped)[\(emptyBar)]  starting ...' ; \
        _wp_t0=$(perl -MTime::HiRes=time -e 'print time') ; \
        { \(command) ; } & \
        _sim_pid=$! ; \
        ( \
        _bw=\(barWidth) ; \
        _total=0 ; _hdr=0 ; _tw=1 ; _last=-2 ; _spin=0 ; _spinchars='|/-\\\\' ; \
        while kill -0 $_sim_pid 2>/dev/null ; do \
        sleep 0.2 ; \
        if [ "$_total" -eq 0 ] ; then \
        _hdrline=$(head -n 1 "\(progressFile)" 2>/dev/null) ; \
        case "$_hdrline" in \
        ''|*[!0-9]*) continue ;; \
        esac ; \
        _total=$_hdrline ; \
        _hdr=$(( ${#_hdrline} + 1 )) ; \
        _tw=${#_hdrline} ; \
        [ "$_total" -lt 1 ] && _total=1 ; \
        fi ; \
        _size=$(wc -c < "\(progressFile)" 2>/dev/null | tr -d ' \\t\\n') ; \
        [ -z "$_size" ] && _size=0 ; \
        _done=$(( _size - _hdr )) ; \
        [ "$_done" -lt 0 ] && _done=0 ; \
        [ "$_done" -gt "$_total" ] && _done=$_total ; \
        _ratio=$(printf "%${_tw}d/%d" "$_done" "$_total") ; \
        _block=$'\\e[7m \\e[27m ' ; \
        if [ "$_done" -ge "$_total" ] ; then \
        _spin=$(( (_spin + 1) % 4 )) ; \
        _ch=$(printf '%s' "$_spinchars" | cut -c$((_spin + 1))) ; \
        printf '\\r\\033[K\(escaped)[\(fullBar)]  %-11s  (100%%)  %7s' "$_ratio" "$_ch" ; \
        elif [ "$_done" != "$_last" ] ; then \
        _last=$_done ; \
        _pct=$(( _done * 100 / _total )) ; \
        _filled=$(( _done * _bw / _total )) ; \
        _bar="" ; _i=0 ; while [ $_i -lt $_filled ] ; do _bar="${_bar}${_block}" ; _i=$((_i+1)) ; done ; \
        _j=$_filled ; while [ $_j -lt $_bw ] ; do _bar="$_bar  " ; _j=$((_j+1)) ; done ; \
        printf '\\r\\033[K\(escaped)[%s]  %-11s  (%3d%%)%9s' "$_bar" "$_ratio" "$_pct" '' ; \
        fi ; \
        done ; \
        ) & \
        _poller_pid=$! ; \
        wait $_sim_pid ; _rc=$? ; \
        kill $_poller_pid 2>/dev/null ; wait $_poller_pid 2>/dev/null ; \
        _hdrline=$(head -n 1 "\(progressFile)" 2>/dev/null) ; \
        case "$_hdrline" in ''|*[!0-9]*) _hdrline=1 ;; esac ; \
        _tw=${#_hdrline} ; \
        _ratio=$(printf "%${_tw}d/%d" "$_hdrline" "$_hdrline") ; \
        _wp_el=$(perl -MTime::HiRes=time -e 'printf("%.1f", time - '$_wp_t0')') ; \
        printf '\\r\\033[K\(escaped)[\(fullBar)]  %-11s  (100%%)  %6.1fs\\n' "$_ratio" "$_wp_el" ; \
        rm -f "\(progressFile)" ; \
        ( exit $_rc )
        """
    }

    /// A private capture file for one `withSpinner` invocation.
    ///
    /// One per call, not one per process: a comparison run assembles four or
    /// five spinners into a single script, and a shared name would let a later
    /// step's `>` truncate an earlier step's output before it was printed. The
    /// pid keeps two Qnet processes apart; the UUID keeps two steps apart.
    private static func spinnerCapturePath() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let token = UUID().uuidString.prefix(8).lowercased()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_spin_\(pid)_\(token).out")
            .path
    }

    /// Companion to `withProgress` for opaque solvers that own their
    /// own iteration loop (e.g. CBC / HiGHS / GLPK in fBNAlp). No
    /// progress file — just a 4-frame spinner with elapsed time on
    /// the same line as the prefix. Exit code is propagated.
    ///
    /// The wrapped command never shares the spinner's line. The spinner owns
    /// the terminal for the whole run: it prints an unterminated frame and
    /// redraws it with `\r\033[K` every 200 ms, so anything the command wrote
    /// to the same terminal landed *inside* a frame and was then erased by the
    /// next redraw. The visible symptom was the solver's first output line
    /// welded onto the progress line ("Solving exact open product form ...
    /// [ ]  0.0sExact open BCMP product-form analysis") with the closing
    /// `[done]` frame arriving after the results instead of over the frame it
    /// was meant to replace. Half the spinner-wrapped runners already avoided
    /// it by accident, because `runWithStderrOnFailure` redirects the solver's
    /// stdout to a file of its own; the eight that print straight to stdout
    /// (product_form, qbd, truncated_ctmc, regenerative_mc, bar_bounds,
    /// adaptive_bar, generic_ctmc, fb_decomp) did not. Capturing here rather
    /// than at each call site fixes all of them at once and also stops a
    /// long-running solver's output being sliced mid-line by a redraw.
    ///
    /// stderr is merged into the capture on purpose. `runScript` already runs
    /// the whole wrapper under `2>&1 | tee`, so this changes nothing about what
    /// is archived or parsed — only *when* a traceback appears, which is now
    /// after the spinner has finished with the line rather than through it.
    private func withSpinner(
        prefix: String,
        command: String
    ) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "'", with: "'\\''")
        let capture = Self.spinnerCapturePath()
        // Match the bar's fixed-column layout so the trailing time
        // lands at the same column as in `withProgress`. Bar layout
        // after prefix is 32 + 2 + 11 + 2 + 6 + 2 + 7 = 62 chars; the
        // time block is the last 7. Spinner renders `[X]` (3 chars)
        // then 52 spaces then 7-char time. Final uses `[done]` (6
        // chars) then 49 spaces then 7-char time.
        return """
        printf '\(escaped)[ ]%52s%6.1fs' '' 0.0 ; \
        _t0=$(perl -MTime::HiRes=time -e 'print time') ; \
        { \(command) ; } > "\(capture)" 2>&1 & \
        _sim_pid=$! ; \
        ( \
        _spin=0 ; _spinchars='|/-\\\\' ; \
        while kill -0 $_sim_pid 2>/dev/null ; do \
        sleep 0.2 ; \
        _spin=$(( (_spin + 1) % 4 )) ; \
        _ch=$(printf '%s' "$_spinchars" | cut -c$((_spin + 1))) ; \
        _el=$(perl -MTime::HiRes=time -e 'printf("%.1f", time - '$_t0')') ; \
        printf '\\r\\033[K\(escaped)[%s]%52s%6.1fs' "$_ch" '' "$_el" ; \
        done ; \
        ) & \
        _poller_pid=$! ; \
        wait $_sim_pid ; _rc=$? ; \
        kill $_poller_pid 2>/dev/null ; wait $_poller_pid 2>/dev/null ; \
        _el=$(perl -MTime::HiRes=time -e 'printf("%.1f", time - '$_t0')') ; \
        printf '\\r\\033[K\(escaped)[done]%49s%6.1fs\\n' '' "$_el" ; \
        cat "\(capture)" 2>/dev/null ; rm -f "\(capture)" ; \
        ( exit $_rc )
        """
    }

    /// The perl program that normalizes displayed precision. It is written
    /// to a temp file rather than squeezed into `perl -e '…'`: the program
    /// is full of backslash escapes and quotes, and routing them through a
    /// Swift literal, then bash, then perl is three chances to corrupt a
    /// regex silently. See `outputPrecisionFilter(decimals:)`.
    private static let outputPrecisionProgram = """
        # Qnet display-precision filter. argv[0] = fraction digits (0-9).
        # Runs as the LAST stage of the run wrapper's pipeline, after `tee`,
        # so the archived run output the result parser reads keeps every digit
        # the solver printed and only the terminal is normalized.
        use strict; use warnings;
        $| = 1;
        my $D = defined $ARGV[0] ? $ARGV[0] + 0 : 6;
        $D = 0 if $D < 0;
        $D = 9 if $D > 9;
        # Below 10^-D a fixed format would print "0.000" for a nonzero value,
        # so switch to scientific with one digit fewer than asked (never < 1).
        # At D = 0 there is no such fallback: the user asked for whole numbers and
        # DS.Number.display makes the same call, and these two must never disagree.
        my $E = $D - 1 < 1 ? 1 : $D - 1;
        # Spelled as the decimal literal "1e-<D>", not as 10 ** -$D: the
        # boundary test below compares against it for EQUALITY, and the value a
        # rounded token like "1.00000e-06" parses to is the nearest double to
        # the literal. pow() is free to land one ulp away from that.
        my $T = $D > 0 ? ("1e-" . $D) + 0 : 0;
        # Symmetric upper guard. Without it 3.456789e+20 renders as
        # 345678899999999983616.000 — twenty digits of floating-point noise the
        # solver never computed, in a field sized for eight characters. fmt7 in
        # buildComparisonAwk uses the same threshold so the two agree.
        my $U = 1e9;

        # Reformat one number. Three rules, in order of how much damage getting them
        # wrong does:
        #
        #   1. Never invent digits. A token that arrived in scientific notation keeps
        #      that notation and never gains mantissa digits: the solver printed
        #      4.567e-09 because four significant figures is what it can defend, and
        #      4.56700e-09 claims two it never computed. This is also what makes the
        #      filter idempotent over fmt7's own scientific fallback.
        #   2. Never move a column's left edge. `$pad` is the whitespace the token
        #      arrived behind. A replacement that is SHORTER is right-aligned inside
        #      the original token width, so a right-aligned %10.4f column keeps its
        #      decimal points stacked; a replacement that is LONGER simply takes the
        #      room it needs and the line grows to the right. Reclaiming leading
        #      spaces (the previous behaviour) shifted the value out from under its
        #      header and — because how much could be reclaimed depended on the
        #      value's own width — sheared rows against each other.
        #   3. Never pad a number that is not in a column. A column is produced by a
        #      printf field, so the character in front of its leading whitespace is
        #      a digit or a header word. A number introduced by '=', ':' or ',' is
        #      prose — `generator residual = 4.11409192216e-13`,
        #      `mean_number_in_system: 0.98283912`, `[0.88368701, 1.0819912]` — and
        #      right-aligning a shorter replacement inside the original token width
        #      wedged up to eleven spaces into those sentences at the DEFAULT
        #      setting. Prose keeps the spacing the solver printed, exactly: no
        #      padding taken, and no column debt repaid out of it either.
        #   4. Pay a longer replacement back out of the NEXT gap, so the column
        #      after it starts where the solver's printf put it. See `$debt`.
        #   5. Never pad the ONLY number on a record when it is standing one
        #      space behind its neighbour. Rule 3 catches prose that announces
        #      itself with '=', ':' or ',', and that is most of it; what it
        #      cannot see is a sentence with no introducer at all —
        #      `[Parse] 0.000 s`, `[Total] 0.155 s`, and the `effective cycles
        #      4345.2` clause of a regenerative line whose only other numbers
        #      are bare integers this pattern does not match. Right-aligning
        #      those inside their old width wedged four spaces into each one at
        #      0 decimal places. A printf field, by contrast, leaves SLACK in
        #      front of its value, and a table row carries a row of values: one
        #      field behind one space is what says "sentence".
        #      Both halves are load-bearing, and each is wrong on its own — a
        #      bare field count un-pads rbm_mlmc.c:1127's genuine one-column
        #      `#   %-16s  %10.6f` table, and a bare pad test un-pads any column
        #      whose widest value happens to fill its own field. Measured over
        #      every example every solver in the tree ships: the rule fires on
        #      17 records, all seventeen of them prose, and on no row of any
        #      table at any of the seven reachable settings.

        # Characters the previous replacement on this record grew by and has not
        # yet paid back.
        #
        # Rule 2 lets a longer replacement take the room it needs, which is right
        # for the value but pushes every column to its right — srbm_output.c
        # prints `  E[Z_%d^k]    ` headers (srbm_output.c:136) over `  %12.6f`
        # fields (:142), and that table keeps its rows mutually aligned at
        # display precision 6 but slides them out from under their own headings.
        # (An earlier version of this comment cited `%-11s` over `%-11.4f` in
        # rbm_mlmc and srbm_output; neither file contains that format. The
        # right-aligned table above is the real one, and rbm_mlmc.c:1221's
        # `#   %-16s  W = %10.6f` is the other.) The gap the printf left after
        # the field is exactly the slack that growth should come out of, so it
        # is taken from the NEXT token's leading pad instead of from the line's
        # total width.
        #
        # Growth is set by the field's own printf precision, not by the value, so
        # every row of a column grows by the same amount and repays the same
        # amount: rows stay aligned with each other, which is the property round
        # 1 established and the one this must not cost. One space always
        # survives, so two columns can never fuse into a single token; and a gap
        # of a single space — prose, and `k = v` pairs — can pay nothing, which
        # is what keeps a sentence from being re-spaced.
        #
        # The residual, stated plainly: repayment is capped by the gap the printf
        # left, and a value can outgrow its whole field. `%-11.4f` grows by
        # D - 4, so at the shipped D = 6 every plausible value still fits its
        # eleven columns and the table lands exactly under its headers; at D = 9
        # a row holding `123.4567` cannot repay in full and ends one or two
        # characters right of its neighbours. That is a strictly smaller defect
        # than the alternative it replaced, where at D = 9 *every* column of
        # *every* row sat up to twenty characters away from its own heading —
        # but it is a real one, and it is why the fix belongs here rather than
        # in a widened header that would drift by the same amount.
        my $debt = 0;

        # $prose is true when the token is introduced by '=', ':' or ',' (see rule
        # 3), or when it is a sentinel's key=value field. A prose token neither
        # takes padding nor repays column debt: whatever spacing the solver put
        # around it survives byte for byte.
        #
        # Prose is sticky to the end of the record. An introducer identifies the
        # LINE as a sentence, not just the one token behind it: srbm_lp's
        # parameter echo prints a space-separated pair per key
        # (`  drift         = -1.0000 0.0000`), and regenerative MC writes a whole
        # clause (`mean_number_in_system: 9.09 (sequential interval [7.30, 10.88];
        # effective cycles 5442.3)`). Exempting only the first value left every
        # later one right-aligned inside its original width, which is the same
        # stray-space defect one token further along the same sentence. A printf
        # table row carries no '=', ':' or ',' ahead of its columns, so the flag
        # cannot be raised on one.
        my $prose_run = 0;
        sub prose_flag {
            $prose_run = 1 if $_[0];
            return $prose_run;
        }
        sub fmtnum {
            my ($pad, $tok, $prose, $lone) = @_;
            if (!$prose && $debt > 0 && length($pad) > 1) {
                my $pay = length($pad) - 1;
                $pay = $debt if $debt < $pay;
                $pad = substr($pad, $pay);
                $debt -= $pay;
            }
            my $v = $tok + 0;
            # %+ keeps a deliberately signed column (fBNAsm's drift b_i is printed
            # %+8.5f so the sign carries the stability verdict) reading as one format.
            my $plus = substr($tok, 0, 1) eq '+' ? '+' : '';
            my $out;
            # Notation follows the VALUE, not the spelling the solver chose, so
            # that this agrees with awk fmt7 and DS.Number.display for every input
            # (the one exception is the exact-threshold tie below). Deciding it on
            # /[eE]/ meant `Optimal u* = 0.0000000000e+00` (srbm_lp prints %.10e)
            # stayed `0.00000e+00` in the Shell while the same zero read
            # `0.000000` in the Results pane, at the shipped default.
            my $sci = ($v != 0 && (abs($v) < $T || abs($v) >= $U)) ? 1 : 0;
            # Boundary hysteresis, and the ONLY place the token's spelling is
            # allowed back into the notation decision.
            #
            # fmt7 and DS.Number.display choose from the exact value; this
            # filter only ever sees the ROUNDED token, and rounding can carry a
            # value across the very threshold that chose its notation:
            #   * fmt7 sees 9.999996e-07 at D = 6, takes the scientific branch
            #     because it is below 10^-6, and prints "1.00000e-06" — whose
            #     value IS 10^-6. Read back, that is inside the fixed band, so
            #     the filter rewrote fmt7's own cell as "0.000001": a different
            #     notation, in a column awk had already sized.
            #   * symmetrically, %.3f of 999999999.9999 is "1000000000.000",
            #     which reads back as exactly 1e9 and flipped to "1.00e+09".
            # At exactly the threshold the two readings are indistinguishable
            # from the value alone, so the tie goes to the notation the token
            # already carries — but ONLY when the token is byte-identical to what
            # fmt7/DS.Number.display would have written for that value at this
            # setting. That narrowness is the point: `1.00000e-06` at D = 6 is
            # fmt7's own cell and is left alone, while a solver's own `1e-06` or
            # `1.0000000000000001e-06` is not fmt7's output and still normalizes
            # to `0.000001` like every other value in the fixed band. So the
            # spelling decides nothing except "this cell has already been
            # formatted by the formatter I am required to agree with".
            if (!$sci && $D > 0 && abs($v) == $T
                && $tok eq sprintf("%$plus.*e", $E, $v)) { $sci = 1 }
            if ($sci && abs($v) == $U
                && $tok eq sprintf("%$plus.*f", $D, $v)) { $sci = 0 }
            if ($sci) {
                # Rule 1 still holds inside the scientific band: a token that
                # arrived scientific never gains mantissa digits, which is also
                # what makes the filter idempotent over fmt7's own fallback.
                my $digits = $E;
                if ($tok =~ /[eE]/) {
                    my ($mantissa) = ($tok =~ /\\A([^eE]*)/);
                    my $have = ($mantissa =~ /\\.(\\d+)\\z/) ? length($1) : 0;
                    $digits = $have if $have < $E;
                }
                $out = sprintf("%$plus.*e", $digits, $v);
            } else {
                $out = sprintf("%$plus.*f", $D, $v);
            }
            # A displayed "-0.000000" reads as a sign error, not as a small negative.
            $out =~ s/\\A-(0(?:\\.0+)?)\\z/$1/;
            my $lo = length($out);
            my $lt = length($tok);
            return $pad . $out if $prose;
            # Rule 5 (see $FIELD_RE): the ONLY number on the record, standing
            # one space behind whatever precedes it, is prose too. `$lone` is
            # the record-wide field count, `$pad` the separation; a printf that
            # laid this number out in a column left slack in front of it, and a
            # sentence left a single space. Both halves are load-bearing:
            # dropping the count would un-pad rbm_mlmc.c:1127's genuine
            # single-column `#   %-16s  %10.6f` table, and dropping the pad test
            # would un-pad a one-column row whose neighbours are integers.
            return $pad . $out if $lone && length($pad) < 2;
            # A column token still grows the line rather than borrowing from a gap
            # that does not exist; the debt is recorded so a table whose first
            # column is flush left still repays out of the second gap.
            $debt += $lo - $lt if $lo > $lt;
            return $out if length($pad) == 0;
            return $pad . (' ' x ($lt - $lo)) . $out if $lo < $lt;
            return $pad . $out;
        }

        # The one pattern that finds every number this filter may rewrite, and
        # the only place its shape is written down. Each record runs it TWICE —
        # once to count the fields, once to rewrite them — and sharing the qr//
        # is what guarantees the two passes agree about what a number is. Two
        # hand-copied regexes that drifted apart would let a token be padded as
        # a column while the count had already called the record prose.
        my $FIELD_RE = qr{
            (\\e\\[[0-?]*[ -\\/]*[@-~])
          | ([=:,]?)(\\ *)(?<![\\w.\\@\\/])([+-]?(?:\\d+\\.\\d+|\\.\\d+|\\d+(?=[eE]))(?:[eE][+-]?\\d+)?)(?![\\w%\\/])(?!\\.\\S)
        }x;

        sub emit {
            my ($rec) = @_;
            # Column debt is a property of one printed line. A record boundary
            # ends the row, so it ends the debt too.
            $debt = 0;
            $prose_run = 0;
            # Machine sentinels are contracts, and most of them accompany a
            # report rather than replace it. Skipping the whole record left
            # `estimate=1.9999999999722793` on screen at every setting, so a
            # record that IS shown is rewritten here.
            #
            # So the record is rewritten, but far more conservatively than prose:
            # only a token that is the COMPLETE value of one of the NAMED
            # float-bearing keys below, followed by whitespace or the end of the
            # record. The head, every key, every integer-valued field (level=,
            # iterations=, exit=, cap_hits=) and every percent-encoded string
            # (value=M%2FM%2F1) are byte-identical because they are not on the
            # list. No padding is applied, ever.
            #
            # This is display only. ResultOutputParser and the CSV export read the
            # tee'd file, which is written by the pipeline stage BEFORE this one
            # and still holds every digit the solver printed.
            # Two sentinel classes a reader never needs to see, because the
            # solver that writes them now prints the same numbers as a report
            # directly above them.
            #
            # Regenerative Monte Carlo prints a per-node table and a
            # confidence-interval table, so its QNET_NODE_METRIC_V1 records were
            # the same values a second time at 17 significant digits — ten
            # key=value pairs per node per metric. Exact Matrix-Analytic QBD used
            # to print QNET_QBD_*_V1 records and NOTHING else, which is why this
            # was once a single-class rule; qbd_solver.py format_human now leads
            # with a report, so the records are duplicate here too — and they
            # carried the last percent-encoded prose on screen
            # (`value=M%2FM%2F1`).
            #
            # Both are still WRITTEN, because ResultOutputParser and the CSV
            # export read them out of the tee'd archive that this stage never
            # touches; they are only withheld from the screen. Still NOT
            # generalised to every sentinel — QNET_METHOD_FAILURE_V1 and
            # QNET_MLMC_STATUS_V1 are the only report of what they report.
            if ($rec =~ /\\AQNET_(?:NODE_METRIC|QBD_(?:METRIC|EVIDENCE|ERROR))_V1(?![A-Za-z0-9_])/) {
                return;
            }
            if ($rec =~ /\\AQNET_[A-Z0-9_]+_V1(?![A-Za-z0-9_])/) {
                # The key list, not the spelling of the value. A syntactic rule
                # ("any '='-preceded token carrying a decimal point or an
                # exponent") skips a float-bearing field whose value happens to
                # land on an exact integer, and then the SAME quantity appears
                # twice on adjacent lines in two spellings:
                #   QNET_NODE_METRIC_V1 ... estimate=1 ci_low=1 ci_high=1
                #   QNET_NODE_METRIC_V1 ... estimate=0.900000 ci_low=0.880000
                # (both classes below are withheld from the screen today, but the
                # rule governs every sentinel that is shown, and an exact-integer
                # measurement is not rare)
                # Naming the keys instead is what makes `estimate=1.000000`,
                # `standard_error=0.000000` and `ci_low=1.000000` come out at the
                # configured precision like every other measurement.
                #
                # Every other field of every sentinel is left byte-identical by
                # construction, because it is not on this list: metric=, level=,
                # node_id=, class_id=, iterations=, cap_hits=, exit=,
                # successful=, fallback_used=.
                #
                # Known, deliberate, and NOT a bug to re-derive next round: the
                # same exact-integer case in PROSE is still left at the solver's
                # own spelling. `external_blocking_probability: 0` sits beside
                # `departure_rate: 0.999550` in regenerative MC's human lines
                # because a prose token carries no key to consult, and there the
                # bare integer is as likely to be a count (`Complete
                # empty-to-empty cycles: 20000`, `iterations`, a station index)
                # as a measurement. Rewriting every bare integer in prose would
                # break the one guarantee this filter is built on — that a count
                # never gains a decimal point. The honest fix is solver-side: the
                # handful of human-output writers that print a measurement with
                # %g (regenerative_mc.py, truncated_ctmc.py, product_form) should
                # print measurements with an explicit fixed format so they always
                # carry a point.
                my $float_key = qr/estimate|standard_error|ci_confidence
                                  |ci_low|ci_high|ci_half_width|effective_cycles/x;
                my $num = qr/[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?/;
                $rec =~ s{
                    (?<![A-Za-z0-9_])($float_key=)($num)(?=[\\s;,]|\\z)
                }{ $1 . fmtnum('', $2, 1, 0) }gex;
                # There was a second rewrite here, for QNET_QBD_EVIDENCE_V1's
                # `value=` field, whose contents are a number for some keys and a
                # percent-encoded string for others. It is gone because the whole
                # QBD class is suppressed above: unreachable code that still
                # looked like a live rule about how values are formatted.
            } else {
                # Branch 1 consumes ANSI escapes untouched. Branch 2 rewrites a
                # token that carries a decimal point, and — only when an exponent
                # follows — a bare integer mantissa, so that a line printing both
                # "1e-9" and "6.02e23" does not come out in two spellings. Plain
                # counts, indices, seeds and exit codes carry neither and stay out
                # of scope by construction.
                #
                # The look-around keeps "S1.2", version "0.90.34" and
                # "/tmp/x_3.4.sh" whole; '/' and '@' additionally keep a path or a
                # formula out of it ("python@3.11/lib" must not become
                # "python@3.110/lib" in a diagnostic the user is about to copy);
                # and excluding a trailing '%' leaves the comparison table's
                # (+1.2%) delta at exactly the width awk computed its column
                # widths for. A following '.' disqualifies a token only when
                # something non-blank follows the '.' as well — that is what
                # separates the middle of "0.90.34" from the end of the sentence
                # "the utilisation is 0.5.", which used to be the one number in a
                # paragraph left at the solver's own precision.
                #
                # Two known, currently unreachable hazards, recorded here so the
                # next person adding a diagnostic line knows them. (1) A
                # TWO-component version or identifier in prose is a decimal
                # number to this regex: "Python 3.11" would become
                # "Python 3.110000". Three components are safe — the trailing-dot
                # guard catches "0.90.34" — and no normalized run path prints a
                # two-component version today (the GJN/MCN/bnetio banners sit
                # behind -v flags the app never passes). (2) A number written
                # immediately after an ANSI escape is never rewritten: branch 1
                # consumes the escape, and the look-behind then sees the CSI's
                # terminating letter and refuses. No solver colours a value
                # today; one that starts to would opt out of the setting in
                # silence.
                #
                # The optional [=:,] prefix is captured and re-emitted verbatim;
                # its only job is to tell fmtnum that this number is introduced by
                # a sentence rather than laid out by a printf field (rule 3).
                # Rule 5's field count, taken before anything is rewritten:
                # how many tokens on THIS record fmtnum is about to see. A
                # printf table row carries a whole row of them; a sentence with
                # a measurement in it carries one.
                my $fields = 0;
                {
                    my $scan = $rec;
                    while ($scan =~ /$FIELD_RE/g) { $fields++ if defined $4 }
                }
                $rec =~ s{$FIELD_RE}{
                    defined $1 ? $1
                               : $2 . fmtnum($3, $4, prose_flag(length($2) > 0),
                                             $fields < 2 ? 1 : 0)
                }ge;
            }
            print $rec;
        }

        # Record-at-a-time, CR-aware and unbuffered. The progress bar and spinner
        # redraw with \\r and emit no newline until the run ends, so a line-oriented
        # filter would swallow every intermediate frame: split after \\r as well as
        # \\n, and release an unterminated tail once the pipe has been idle for a
        # tick.
        #
        # `holding` is the safety interlock on that release. A tail is held when
        # letting it go could change a number:
        #   * it could still grow into a QNET_ sentinel, whose body must pass through
        #     byte for byte; or
        #   * it ends inside a numeric token. A solver that pauses mid-buffer — every
        #     spinner-wrapped run does, and so does any convergence trace — can split
        #     `0.666666` into `0.66` and `6666`. Formatting the first half and then
        #     printing the second produced `0.6606666`: a wrong number, on screen, in
        #     the pane this release makes the centrepiece. The trailing-character test
        #     is exact rather than heuristic, because a split inside a numeric token
        #     always leaves the buffer ending in one of its characters.
        # Holding is unbounded, not one tick: the release branch simply does not fire
        # while `holding()` is true, so a tail that stops growing stays held until
        # more bytes arrive. Nothing reachable stalls on it — every progress frame
        # ends in `s` and every result line in a newline — but a future solver that
        # paused mid-number with nothing further to write would leave that fragment
        # on screen only when the run ended. Releasing early instead prints a value
        # that is not the solver's, which is the worse of the two.
        my $rin = '';
        vec($rin, fileno(STDIN), 1) = 1;
        my $buf = '';
        sub holding {
            return 0 unless length $buf;
            return 1 if $buf =~ /\\AQNET_/ || "QNET_" =~ /\\A\\Q$buf\\E/;
            return 1 if $buf =~ /[0-9.eE+-]\\z/;
            return 0;
        }
        while (1) {
            my $timeout = length($buf) ? 0.05 : undef;
            my $ready = select(my $rout = $rin, undef, undef, $timeout);
            if (defined $ready && $ready > 0) {
                my $chunk = '';
                my $n = sysread(STDIN, $chunk, 65536);
                if (!defined $n) { next if $!{EINTR}; last }
                last if $n == 0;
                $buf .= $chunk;
                while ($buf =~ s/\\A([^\\r\\n]*[\\r\\n])//) { emit($1) }
            } elsif (!holding()) {
                emit($buf) if length $buf;
                $buf = '';
            }
        }
        emit($buf) if length $buf;
        """

    /// Returns the last stage of a run wrapper's pipeline: a filter that
    /// rewrites every decimal number the solvers print to Settings ▸ Output
    /// Format ▸ Output decimals.
    ///
    /// Why here and not in the solvers: display precision is a GUI
    /// preference, not a property of a numerical method. Only 12 of the 22
    /// run paths ever honoured the setting (the ones that end in
    /// `buildComparisonAwk`), so one session could show `0.66666667`,
    /// `4.0000000000000018`, `4.0000` and `4.000` for the same class of
    /// quantity. Teaching ~23 output writers across 14 C files and 8 Python
    /// solvers a `--decimals` flag would be a twenty-fold larger change
    /// surface delivering nothing this boundary filter does not.
    ///
    /// Why AFTER `tee`: the tee'd file is what `ResultOutputParser` and the
    /// CSV export read. Filtering before the tee would quietly record
    /// rounded values — a data-integrity regression far worse than the
    /// inconsistency it fixes. Appending a SECOND pipe stage (rather than
    /// wrapping the brace group) also leaves `${PIPESTATUS[0]}` pointing at
    /// the solver, so every exit code is unchanged.
    ///
    /// Falls back to `cat` if the program cannot be written, and again — in
    /// the wrapper, at exec time — if it has since been removed. Losing the
    /// run's entire output would be a far worse failure than showing it at
    /// the solver's own precision, and a `perl` that cannot open its program
    /// exits 2 having printed nothing: the run would be recorded as a success
    /// beside an empty Shell, or, once the solver filled the pipe buffer, be
    /// killed by SIGPIPE.
    ///
    /// `normalize` is false for the diagnostics that are prose rather than
    /// solver output (see `runScript`), which get a plain `cat` stage so the
    /// pipeline shape — and therefore `${PIPESTATUS[0]}` — is identical
    /// either way.
    private func outputPrecisionFilter(decimals: Int, normalize: Bool = true) -> String {
        guard normalize else { return "cat" }
        let d = max(0, min(9, decimals))
        let program = Self.outputPrecisionProgramURL
        do {
            try Self.outputPrecisionProgram.write(to: program, atomically: true, encoding: .utf8)
        } catch {
            return "cat"
        }
        // `exec` in both arms: without it the subshell survives the chosen
        // stage and a fallback could re-read a stream the first arm already
        // consumed, duplicating output.
        return "{ if [ -r \"\(program.path)\" ]; then exec perl \"\(program.path)\" \(d); "
            + "else exec cat; fi; }"
    }

    /// The temp file `outputPrecisionFilter` writes its program to. One file
    /// per process, rewritten before each launch so it self-heals if a temp
    /// sweeper removed it, and removed again by each wrapper's EXIT trap so
    /// the pipeline leaves nothing behind. Concurrent runs cannot race for
    /// it: TerminalModel.beginRun refuses a second run while one owns the
    /// Shell.
    private static let outputPrecisionProgramURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BNET_outfmt_\(ProcessInfo.processInfo.processIdentifier).pl")

    /// Launches one document-owned shell run. The TerminalModel allocates a
    /// UUID and refuses this launch if another run already owns the shared
    /// Shell. All lifecycle messages retain the editor captured here rather
    /// than following `activeEditor` when the user switches tabs.
    @discardableResult
    private func runScript(
        _ command: String,
        label: String = "cmd",
        parameters: [String: String] = [:],
        seed: UInt64? = nil,
        replicationSeeds: [UInt64] = [],
        normalizeNumbers: Bool = true
    ) -> Bool {
        let ownerID = activeTabID
        let ownerTitle = activeTabTitle
        let ownerEditor = activeEditor
        guard let handle = terminalModel.beginRun(
            label: label,
            ownerID: ownerID,
            ownerTitle: ownerTitle,
            report: { text, severity in
                ownerEditor.addStatus(text, severity: severity)
            }
        ) else {
            NSSound.beep()
            return false
        }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_run_\(handle.id.uuidString.lowercased()).sh")
        // ESC[A = cursor up, ESC[2K = erase line; removes the echoed bash command.
        // Timing uses perl Time::HiRes for sub-millisecond resolution.
        // Status-bar run indicator: TerminalModel polls the completion
        // file this script writes on exit (see TerminalModel.beginRun).
        // The wrapper reports its own pid first: Run ▸ Stop Run and the
        // status bar's Stop button send SIGINT to that job's process
        // group, exactly as ⌃C in the shell would.
        // The completion file is written from an EXIT trap, not from the
        // last line: SIGINT from Stop Run (or ⌃C in the shell) kills the
        // wrapper before that line runs, and the status bar used to tick
        // "Running…" for the rest of the session. The trap fires on every
        // exit path — normal, SIGINT, SIGTERM — and reports 130 when the
        // command never got to set `_rc`.
        let donePath = handle.donePath
        let scopedCommand = command.replacingOccurrences(
            of: TerminalModel.statusInboxPlaceholder,
            with: handle.statusPath
        )
        // Display-precision normalizer, appended AFTER the tee so the
        // archived output keeps the solver's own digits (see
        // `outputPrecisionFilter(decimals:normalize:)`). `normalizeNumbers`
        // is false for the two report printers and the Help dumps: those are
        // advisory prose, not solver output, and a recommended band written
        // "ideally 0.85–0.99" is a band, not a measurement — restating it at
        // nine decimals as "0.850000000–0.990000000" makes advice look like a
        // result. The display setting exists to make the *solvers* agree with
        // each other, and there is no solver behind a sentence.
        let displayFilter = outputPrecisionFilter(
            decimals: appSettings.outputDecimals,
            normalize: normalizeNumbers
        )
        // The EXIT trap also removes the generated perl program: it is the
        // one artefact of this pipeline that used to outlive the run.
        let scriptBody = """
        printf '\\033[A\\033[2K'
        printf '%s\\n' "$$" > "\(handle.pidPath)"
        trap 'printf "%s\\n" "${_rc:-130}" > "\(donePath)" ; rm -f "\(Self.outputPrecisionProgramURL.path)"' EXIT
        _t0=$(perl -MTime::HiRes=time -e 'print time')
        {
          \(scopedCommand)
          _command_rc=$?
          perl -MTime::HiRes=time -e 'printf("Elapsed time: %.3fs\\n\\n", time - '"$_t0"')'
          exit $_command_rc
        } 2>&1 | tee "\(handle.outputPath)" | \(displayFilter)
        _rc=${PIPESTATUS[0]}
        exit $_rc
        """
        do {
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            terminalModel.failRunToLaunch(
                handle,
                message: "\(TerminalModel.displayLabel(forRunLabel: label)) could not start: \(error.localizedDescription)"
            )
            return false
        }
        registerStructuredResult(
            handle: handle,
            label: label,
            ownerID: ownerID,
            ownerTitle: ownerTitle,
            ownerEditor: ownerEditor,
            parameters: parameters,
            seed: seed,
            replicationSeeds: replicationSeeds
        )
        // The Shell can refuse to type the command (a full-screen program
        // or a stdin-reading command owns it). It has already reported that
        // and retired the run, so report the truth to the caller too.
        return terminalModel.sendCommand("bash \"\(script.path)\"")
    }

    /// Stable scientific classification for each existing runner. Utility
    /// commands (network analysis and primitive reports) intentionally return
    /// nil because they are diagnostics, not steady-state estimates.
    private func resultMethod(forRunLabel label: String) -> ResultMethodMetadata? {
        switch label {
        case "sim", "inf_sim": return .monteCarlo
        case "sm", "inf_sm": return .spectral
        case "fm": return .finiteElement
        case "flp", "lp": return .linearProgram
        case "mc": return .multiClassSRBM
        case "qna": return .qna
        case "rqna": return .rqna
        case "sbd": return .sbd
        case "mlmc": return .srbmMLMC
        case "generic_ctmc": return .finiteCTMC
        case "fb_decomp": return .finiteDecomposition
        case "truncated_ctmc": return .truncatedCTMC
        case "adaptive_bar": return .adaptiveLowRankBAR
        case "bar_bounds": return .barMomentBounds
        case "regenerative_mc": return .regenerativeMonteCarlo
        case "product_form": return .openProductForm
        case "qbd": return .qbd
        case "cmp", "inf_cmp": return .comparison
        case "testset": return .testSet
        case "spc": return .spectralConvergence
        default: return nil
        }
    }

    private func registerStructuredResult(
        handle: TerminalModel.RunHandle,
        label: String,
        ownerID: UUID,
        ownerTitle: String,
        ownerEditor: NetworkEditorModel,
        parameters: [String: String],
        seed: UInt64?,
        replicationSeeds: [UInt64]
    ) {
        guard let method = resultMethod(forRunLabel: label) else { return }
        ResultsStore.shared.beginRun(
            id: handle.id,
            tabID: ownerID,
            networkTitle: ownerTitle,
            editor: ownerEditor,
            method: method,
            parameters: parameters,
            seed: seed,
            replicationSeeds: replicationSeeds
        )
    }

    private func finalizeStructuredResult(_ summary: TerminalRunSummary) {
        // A non-zero exit has to be visible where the user is already looking.
        // It was recorded on the Results record and in the status bar's
        // trailing segment, but nothing reached the Status log, so a run that
        // died read as one still in progress: `Run ▸ Run SRBM MLMC`'s awk
        // aggregator failed to PARSE (a bare ternary inside a printf argument
        // list, which BWK awk reads as an output redirection), printed three
        // parser errors instead of the whole table, exited 2 — and the Status
        // pane's last line stayed "Running SRBM MLMC…". That is what let the
        // defect survive several rounds of review. Cancellations are excluded:
        // stopping a run is not a failure and already reports itself.
        if !summary.succeeded,
           !summary.cancelled,
           let ownerTab = tabs.first(where: { $0.id == summary.ownerID }) {
            ownerTab.editor.addStatus(summary.text, severity: .error)
        }
        let store = ResultsStore.shared
        guard let record = store.record(id: summary.id) else { return }
        let raw = terminalModel.lastRunOutput
        if summary.cancelled {
            // A run the user stopped is not a result. Filing a 0-measurement
            // record for it makes a deliberate Stop look like a failed run in
            // the Results workspace; the Status log's "… cancelled." line is
            // the whole trace a cancellation should leave.
            //
            // `ResultRunStatus.cancelled` stays in the enum on purpose: it is a
            // Codable case and stores already on disk contain records with
            // status == "cancelled". Removing it would break decoding.
            store.delete(summary.id)
            return
        }
        guard summary.succeeded else {
            store.failRun(
                summary.id,
                message: "\(summary.label) exited with status \(summary.exitCode). See the originating tab's Status pane and retained output.",
                rawOutput: raw,
                completedAt: summary.finishedAt
            )
            return
        }
        let parsed = ResultOutputParser.parse(raw, for: record)
        switch parsed.disposition {
        case .completed:
            store.completeRun(
                summary.id,
                measurements: parsed.measurements,
                evidence: parsed.evidence,
                warnings: parsed.warnings,
                rawOutput: raw,
                completedAt: summary.finishedAt
            )
        case .partial(let message):
            store.partialRun(
                summary.id,
                message: message,
                measurements: parsed.measurements,
                evidence: parsed.evidence,
                warnings: parsed.warnings,
                rawOutput: raw,
                completedAt: summary.finishedAt
            )
        case .failed(let message):
            store.failRun(
                summary.id,
                message: message,
                rawOutput: raw,
                completedAt: summary.finishedAt
            )
        }
    }

    private func findFBNAsimBinary() -> URL? {
        findBinary(name: "fBNAsim", subdirectory: "fBNAsim")
    }

    /// Searches for a binary in finite/ or infinite/ subdirectories, walking up from cwd.
    private func findBinary(name: String, subdirectory: String) -> URL? {
        SolverRuntimeResolver.shared.resolveExecutable(
            name: name, subdirectory: subdirectory
        ).url
    }

    // MARK: - Network Primitives

    /// Computes the Brownian-network primitives (α, μ, c, ρ, drift, routing,
    /// reflection, covariance) from the current canvas and prints a structured
    /// report to the interactive shell. Warnings are emitted for conditions
    /// that compromise the Brownian (SRBM) heavy-traffic approximation.
    private func showNetworkPrimitives() {
        let result = SRBMExporter.computeData(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers
        )

        switch result {
        case .failure(let error):
            reportBlocked(
                "Network primitives aborted: \(error.localizedDescription)",
                on: activeEditor
            )

        case .success(let data):
            var warnings = networkWarnings(for: data, infiniteBuffers: activeEditor.infiniteBuffers)
            warnings += Self.validateLinkStructure(
                nodes: activeEditor.nodes, links: activeEditor.links,
                infiniteBuffers: activeEditor.infiniteBuffers)
            activeEditor.networkHasWarnings = !warnings.isEmpty
            activeEditor.networkWarningList = warnings
            applyTractability(to: activeEditor, data: data)
            activeEditor.hasBeenAnalyzed = true

            // Per-station diagnostic so we can cross-check what the report
            // table prints vs the underlying values. Also dump per-class
            // α and service rates to spot any mis-aggregation.
            var dbg = "Primitives ρ:"
            for i in 0..<data.d {
                let rho = data.capacity[i] > 1e-12
                    ? data.alpha[i] / data.capacity[i] : Double.nan
                dbg += String(format: "  S%d[α=%.4f,μ=%.4f,ρ=%.4f]",
                              i + 1, data.alpha[i], data.serviceRates[i], rho)
            }
            activeEditor.addStatus(dbg)
            for k in 0..<data.K {
                var line = "  class \(k + 1) α·μ per station:"
                for i in 0..<data.d {
                    line += String(format: "  [%.3f/%.3f]",
                                   data.alphaPerClass[k][i],
                                   data.classServiceRates[k][i])
                }
                activeEditor.addStatus(line)
            }

            let report = formatNetworkPrimitives(data, warnings: warnings)
            let pid = ProcessInfo.processInfo.processIdentifier
            let reportFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_primitives_\(pid).txt")
            do {
                try report.write(to: reportFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Network primitives aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            // Grow the terminal view width so long warning lines stay on one
            // line; the horizontal ScrollView activates its scrollbar when
            // the pane is narrower.
            let longestLine = report
                .components(separatedBy: "\n")
                .map { $0.count }
                .max() ?? 0
            terminalModel.reportLongestLineChars(longestLine)

            let command = "cat \"\(reportFile.path)\""
            // A diagnostic report, not solver output: it chooses its own
            // column widths (%10.5f, %+8.5f — the drift column's sign is the
            // stability verdict) and its prose quotes thresholds like
            // "ρ ≳ 0.995". `resultMethod(forRunLabel:)` already classifies
            // this label as not-a-result for the same reason.
            if let script = silentScript(command, label: "primitives", normalizeNumbers: false) {
                // A refused launch has already been reported and retired;
                // do not follow it with a line claiming it ran.
                if terminalModel.sendCommand(script) {
                    activeEditor.addStatus("Displayed network primitives.")
                }
            }
        }
    }

    /// Produces a thorough Brownian-approximation reliability report for the
    /// current network. Looks at ρ, SCVs, server count, buffer truncation,
    /// routing feedback, class heterogeneity, and covariance health; for each
    /// issue found, explains the mechanism and suggests parameter changes.
    private func analyzeNetwork() {
        let result = SRBMExporter.computeData(
            nodes: activeEditor.nodes,
            links: activeEditor.links,
            infiniteBuffers: activeEditor.infiniteBuffers
        )

        switch result {
        case .failure(let error):
            reportBlocked(
                "Analyze network aborted: \(error.localizedDescription)",
                on: activeEditor
            )

        case .success(let data):
            // Explicit diagnostic so we can cross-reference report ρ with
            // the live SRBMExporter output.
            var rhoLine = "Analyze Network ρ (data.alpha/data.capacity):"
            for i in 0..<data.d {
                let rho = data.capacity[i] > 1e-12
                    ? data.alpha[i] / data.capacity[i] : Double.nan
                rhoLine += String(format: "  S%d α=%.4f c=%.4f ρ=%.4f",
                                  i + 1, data.alpha[i], data.capacity[i], rho)
            }
            activeEditor.addStatus(rhoLine)

            let report = formatNetworkAnalysis(data, infiniteBuffers: activeEditor.infiniteBuffers)
            let pid = ProcessInfo.processInfo.processIdentifier
            let reportFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("BNET_analysis_\(pid).txt")
            do {
                try report.write(to: reportFile, atomically: true, encoding: .utf8)
            } catch {
                reportBlocked(
                    "Analyze network aborted: could not write temp file.",
                    detail: error.localizedDescription,
                    on: activeEditor
                )
                return
            }

            let longestLine = report.components(separatedBy: "\n").map { $0.count }.max() ?? 0
            terminalModel.reportLongestLineChars(longestLine)

            let command = "cat \"\(reportFile.path)\""
            // Advisory prose. "Target ρ < 1 with comfortable margin, ideally
            // 0.85–0.99" is a recommended band, and restating it at the output
            // decimal setting would dress advice up as a measurement.
            if let script = silentScript(command, label: "analyze", normalizeNumbers: false) {
                // A refused launch has already been reported and retired;
                // do not follow it with a line claiming it ran.
                if terminalModel.sendCommand(script) {
                    activeEditor.addStatus("Displayed network analysis.")
                }
            }
        }
    }

    // MARK: - Find Node prompt

    /// Presents the Find Node sheet; the sheet's Find action calls
    /// `findAndRevealNode(named:)` on the active editor.
    @MainActor
    private func showFindNodePrompt() {
        showFindNodeSheet = true
    }

    // MARK: - Help-menu dispatch

    /// Routes a Help menu topic to whichever destination the user has
    /// chosen in Settings ▸ Help menu: the Status pane, the Interactive
    /// Shell, or the Qnet Help window opened at that topic.
    ///
    /// One switch, three destinations, no unreachable branch: the old
    /// free-text overload had a `.popup` case that could never run,
    /// because this function had already handled `.popup` before
    /// delegating. Its window (`HelpTextWindow`) is gone with it.
    @MainActor
    private func showHelp(topic: HelpTopic) {
        let dest = HelpOutputDestination(rawValue: appSettings.helpOutputDestination) ?? .popup
        switch dest {
        case .popup:
            QnetHelpWindow.show(topic: topic)
        case .statusWindow:
            printHelpToStatus(title: topic.windowTitle, text: topic.text)
        case .interactiveShell:
            printHelpToTerminal(topic.text, label: topic.label)
        }
    }

    /// Settings ▸ Help ▸ "Status pane (plain text)": the topic body, with
    /// a visible divider above and below so it reads apart from ordinary
    /// status traffic.
    @MainActor
    private func printHelpToStatus(title: String, text: String) {
        let editor = activeEditor
        editor.statusMessages.append(StatusEntry(text: "──── \(title) ────"))
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            editor.statusMessages.append(StatusEntry(text: String(line)))
        }
        editor.statusMessages.append(StatusEntry(text: "──── end ────"))
    }

    // MARK: - AI tool dispatch

    /// Registers the default tool catalog with the shared registry. Safe to
    /// call repeatedly; new registrations replace same-named tools.
    @MainActor
    private func registerDefaultAITools() {
        // Tools act on the network the CONVERSATION is about: while the
        // assistant is working for one tab and the user switches to
        // another, `read_network` / `update_node` still target the tab the
        // question was asked in. `run_command` is the exception: it
        // dispatches through the menu handlers, which run on the tab in
        // front, so while the conversation's tab is NOT in front the tool
        // refuses with a result that names both tabs rather than
        // analysing the wrong network.
        let tools = AIToolFactory.makeDefaultTools(
            activeEditor: { [self] in
                if let id = aiModel.busyTabID,
                   let tab = tabs.first(where: { $0.id == id }) {
                    return tab.editor
                }
                return self.activeEditor
            },
            runCommandRefusal: { [self] in
                guard let id = aiModel.busyTabID, id != activeTabID,
                      let conversationTab = tabs.first(where: { $0.id == id }) else { return nil }
                return "Not run: this conversation belongs to the tab “\(conversationTab.title)”, "
                    + "but “\(activeTabTitle)” is in front and menu commands act on the front tab. "
                    + "Ask the user to switch back to “\(conversationTab.title)” and try again; "
                    + "read_network and the update tools still work on the right tab meanwhile."
            }
        )
        for t in tools { toolRegistry.register(t) }
    }

    /// Route a tool-initiated command to the same handler the menu bar
    /// would have invoked. Buffer-mode guards mirror the menu: commands
    /// marked "finite-only" / "infinite-only" no-op (with a status note)
    /// when the active network is in the wrong mode.
    @MainActor
    private func dispatch(aiCommand cmd: AICommand) {
        let inf = activeEditor.infiniteBuffers
        switch cmd {
        case .runComparison:
            inf ? runComparisonInfinite() : runComparison()
        case .runMonteCarlo:
            inf ? runSimulationInfinite() : runSimulation()
        case .runSpectralMethod:
            inf ? runSpectralMethodInfinite() : runSpectralMethod()
        case .runFiniteElement:
            if inf { activeEditor.addStatus("AI: Finite Element is finite-buffer only.") }
            else { runFiniteElement() }
        case .runQNA:
            if inf { runQNA() }
            else { activeEditor.addStatus("AI: Whitt QNA is infinite-buffer only.") }
        case .runSBD:
            if inf { runSBD() }
            else { activeEditor.addStatus("AI: SBD is infinite-buffer only.") }
        case .runMultiClassSRBM:
            runMultiClassSRBM()
        case .runExactSimulation:
            if inf { runExactSim() }
            else { activeEditor.addStatus("AI: SRBM MLMC is infinite-buffer only.") }
        case .runLinearProgram:
            if inf { runLinearProgram() }
            else { activeEditor.addStatus("AI: Linear Program is infinite-buffer only.") }
        case .runFiniteLP:
            if inf { activeEditor.addStatus("AI: Finite LP is finite-buffer only.") }
            else { runFiniteLP() }
        case .showNetworkPrimitives:
            showNetworkPrimitives()
        case .analyzeNetwork:
            analyzeNetwork()
        }
    }

    /// Runs the primitives/warnings analysis for the currently-active tab if
    /// it hasn't been analyzed yet. No terminal output — only updates the
    /// `networkHasWarnings` flag so the red canvas banner appears when needed.
    /// Called on initial appear and whenever the active tab changes.
    private func analyzeActiveTabIfNeeded(quiet: Bool = false) {
        let editor = activeEditor
        guard !editor.hasBeenAnalyzed else { return }
        guard !editor.nodes.isEmpty else {
            // Empty canvas after an edit / undo: clear stale flags.
            if quiet {
                editor.networkHasWarnings = false
                editor.networkWarningList = []
                clearTractability(on: editor)
                editor.hasBeenAnalyzed = true
            }
            return
        }

        switch SRBMExporter.computeData(nodes: editor.nodes, links: editor.links, infiniteBuffers: editor.infiniteBuffers) {
        case .success(let data):
            var warnings = networkWarnings(for: data, infiniteBuffers: editor.infiniteBuffers)
            warnings += Self.validateLinkStructure(
                nodes: editor.nodes, links: editor.links,
                infiniteBuffers: editor.infiniteBuffers)
            editor.networkHasWarnings = !warnings.isEmpty
            editor.networkWarningList = warnings
            applyTractability(to: editor, data: data, quiet: quiet)

            // Diagnostic: print the computed ρ values so the user can see
            // exactly what BNET's analyser is using for the banner decision.
            // Skipped in quiet mode (re-analysis after a parameter edit) so
            // every Save doesn't spam the status pane; the flag bar pills
            // and their popovers carry the result instead.
            if !quiet {
                var rhoLine = "Silent analysis ρ:"
                for i in 0..<data.d {
                    let rho = data.capacity[i] > 1e-12
                        ? data.alpha[i] / data.capacity[i] : Double.nan
                    rhoLine += String(format: "  S%d=%.4f", i + 1, rho)
                }
                editor.addStatus(rhoLine)
                if warnings.isEmpty {
                    editor.addStatus("No warnings — banner hidden.")
                } else {
                    editor.addStatus("Banner triggered by \(warnings.count) warning(s):")
                    for w in warnings { editor.addStatus("  • \(w)") }
                }
            }
        case .failure(let err):
            // A network that can't be analyzed (e.g. missing source/sink)
            // isn't overloaded per se — just leave the flag alone.
            editor.networkHasWarnings = false
            editor.networkWarningList = []
            clearTractability(on: editor)
            if !quiet {
                editor.addStatus("Silent analysis failed: \(err.localizedDescription)", severity: .error)
            }
        }
        editor.hasBeenAnalyzed = true
    }

    /// Runs `AnalyticalTractability.assess` on the current editor and publishes
    /// the result into the editor's banner / comparison-column fields.
    private func applyTractability(to editor: NetworkEditorModel,
                                   data: SRBMExporter.SRBMData,
                                   quiet: Bool = false) {
        // Always run with the asymptotic GCDG branches enabled so any
        // known tractability case is detected. The popover's `detail`
        // labels exact vs asymptotic so users can tell which kind matched.
        let result = AnalyticalTractability.assess(
            data: data,
            nodes: editor.nodes,
            infiniteBuffers: editor.infiniteBuffers,
            allowGCDG: true
        )
        let hasCycles = AnalyticalTractability.hasRoutingCycles(data.aggregatedP)
        // Re-entrant networks + ASYMPTOTIC GCDG: the multi-scaling
        // regime requires geometric δᵢ = rⁱ ordering, which re-entrant
        // multi-class networks rarely satisfy. The resulting means can
        // differ from algorithm/simulation by orders of magnitude (e.g.,
        // BanksDai96: GCDG ≈ 3.7, algos & sim ≈ 9.1). Suppress the
        // analytical machinery entirely for this combination — the
        // honest signal is "no reliable analytical for re-entrant
        // asymptotic networks". Exact branches (Jackson, skew-sym) ARE
        // exact even on re-entrant networks, so they still light the
        // pill and populate the means.
        let suppressForReentrant = hasCycles && result.isTractable && !result.isExact
        // GCDG asymptotic formulas (gcdgMeans) consume only Γ and R — they
        // are blind to buffer sizes. In finite-buffer networks the actual
        // queue means are bounded by the buffer, while the asymptotic
        // means are not, so showing them as a reference column is
        // misleading (they typically read 5-10× too small at moderate ρ
        // and finite K). Suppress for any finite-buffer + asymptotic match.
        let suppressForFiniteAsymptotic = !editor.infiniteBuffers
            && result.isTractable && !result.isExact
        if suppressForReentrant || suppressForFiniteAsymptotic {
            editor.isAnalyticallyTractable = false
            editor.tractabilityTitle = ""
            editor.tractabilityDetail = ""
            editor.tractabilityMeans = []
            editor.tractabilityMeansLabel = ""
            editor.tractabilityExplanation = ""
            editor.tractabilityIsExact = false
            let reason = suppressForReentrant
                ? "the network is re-entrant — the multi-scaling regime is unreliable here"
                : "the network has finite buffers — the GCDG asymptotic formulas are infinite-buffer predictions and don't bound the queue at the buffer"
            if !quiet {
                editor.addStatus(
                    "Analytical match is ASYMPTOTIC (\(result.detail)) but \(reason), "
                  + "so the analytical column is suppressed in Run Comparison.")
            }
        } else {
            editor.isAnalyticallyTractable = result.isTractable
            editor.tractabilityTitle = result.title
            editor.tractabilityDetail = result.detail
            editor.tractabilityMeans = result.means
            editor.tractabilityMeansLabel = result.meansLabel
            editor.tractabilityExplanation = result.explanation
            editor.tractabilityIsExact = result.isExact
            // For asymptotic-but-feed-forward (no cycles) the regime is
            // typically well-satisfied, but still flag finite-ρ deviation.
            if result.isTractable && !result.isExact && !quiet {
                editor.addStatus(
                    "Analytical match is ASYMPTOTIC (\(result.detail)). "
                  + "At finite ρ, the asymptotic means may differ from algorithm/simulation values; "
                  + "Run Comparison's algorithm-vs-asymptotic deltas use simulation as the reference instead.")
            }
        }
        editor.hasFeedback = hasCycles
        editor.feedbackDescription = editor.hasFeedback
            ? Self.describeFeedback(aggregatedP: data.aggregatedP)
            : ""
        let (q, crit) = Self.diffusionFriendlinessAssessment(
            data: data, hasFeedback: editor.hasFeedback)
        editor.feedbackQuality = q
        editor.feedbackCriteria = crit
    }

    /// Evaluate the diffusion-friendliness criteria for a re-entrant
    /// network (rule of thumb: per-station ρ < 0.85; service SCV in
    /// [0.5, 2]; max re-entry probability < 0.5; no class-transition
    /// amplification at heavily-loaded stations). Returns (quality, criteria)
    /// where `criteria` is a (label, ok, detail) tuple per check.
    ///
    /// `quality`:
    ///   .notReentrant — network has no routing cycles, button stays grey
    ///   .green        — all criteria pass, diffusion methods should be accurate
    ///   .yellow       — 1-2 criteria fail, expect 10-30% under-prediction
    ///   .red          — multiple criteria fail or a single severe violation
    ///                   (Kumar-Seidman / Bramson regime); expect >30% gap to sim
    private static func diffusionFriendlinessAssessment(
        data: SRBMExporter.SRBMData,
        hasFeedback: Bool
    ) -> (NetworkEditorModel.FeedbackQuality, [(label: String, ok: Bool, detail: String)]) {
        guard hasFeedback else { return (.notReentrant, []) }

        var criteria: [(label: String, ok: Bool, detail: String)] = []
        let d = data.d

        // 1. Per-station ρ < 0.85 (preferably < 0.7).
        var rhos: [Double] = []
        for i in 0..<d {
            let rho = data.capacity[i] > 1e-12
                ? data.alpha[i] / data.capacity[i] : 0.0
            rhos.append(rho)
        }
        let maxRho = rhos.max() ?? 0.0
        let rhoOK = maxRho < 0.85
        criteria.append((
            label: "Per-station ρ < 0.85",
            ok: rhoOK,
            detail: "max ρ = \(String(format: "%.3f", maxRho))"
                + (rhoOK ? "" : " — heavy traffic amplifies the per-class burstiness gap")
        ))

        // 2. Service SCV in [0.5, 2].
        var scvOK = true
        var worstScv = 1.0
        for i in 0..<d {
            let s = data.effectiveServiceSCVs[i]
            if s < 0.5 || s > 2.0 {
                scvOK = false
                if abs(s - 1.0) > abs(worstScv - 1.0) { worstScv = s }
            }
        }
        criteria.append((
            label: "Service SCV in [0.5, 2]",
            ok: scvOK,
            detail: scvOK
                ? "all stations within range"
                : "worst c²_s = \(String(format: "%.3f", worstScv)) (extreme variance breaks 2-moment methods)"
        ))

        // 3. Max re-entry probability < 0.5: largest entry of the
        // aggregated routing matrix that points "back" — operationally,
        // any single P[i][j] that's part of a cycle. We use the simpler
        // upper bound: max self-loop or max entry on station-pair cycles.
        let P = data.aggregatedP
        var maxLoopP = 0.0
        for i in 0..<d {
            if P[i][i] > maxLoopP { maxLoopP = P[i][i] }
            for j in 0..<d where i != j {
                if P[i][j] > 1e-12 && P[j][i] > 1e-12 {
                    let cyc = min(P[i][j], P[j][i])
                    if cyc > maxLoopP { maxLoopP = cyc }
                }
            }
        }
        // For single-class Markovian (K=1, all c²_s ≈ 1) networks the
        // p_loop concern is vacuous: Jackson product form is exact at any
        // feedback probability. Only fail this criterion when the
        // network is non-Markovian or multi-class. */
        let isMarkovian = (data.K == 1)
            && data.effectiveServiceSCVs.allSatisfy { abs($0 - 1.0) < 0.1 }
        let pOK = (maxLoopP < 0.5) || isMarkovian
        let pDetail: String
        if isMarkovian && maxLoopP >= 0.5 {
            pDetail = "largest cycle prob = \(String(format: "%.3f", maxLoopP)) — vacuous for single-class Markovian network (Jackson is exact)"
        } else if pOK {
            pDetail = "largest cycle prob = \(String(format: "%.3f", maxLoopP))"
        } else {
            pDetail = "largest cycle prob = \(String(format: "%.3f", maxLoopP)) — heavy feedback inflates the per-class temporal correlation"
        }
        criteria.append((
            label: "Max re-entry probability < 0.5",
            ok: pOK,
            detail: pDetail
        ))

        // 4. No class-transition amplification at heavily-loaded stations.
        // Heuristic: at a station with ρ > 0.7, check whether the per-class
        // service-rate ratio (max/min over classes that visit there) exceeds
        // 3. A wide ratio at high load is the Kumar-Seidman / Bramson signal —
        // a slow class can hold up the bottleneck while a fast class would
        // free it, so the FCFS mix has highly bursty effective service.
        var amplifyOK = true
        var worstStation = -1
        var worstRatio = 1.0
        let K = data.K
        if K > 1 {
            for i in 0..<d where rhos[i] > 0.7 {
                var muMin = Double.infinity, muMax = 0.0
                var seenAnyClass = false
                for k in 0..<K where data.alphaPerClass[k][i] > 1e-12 {
                    let mu = data.classServiceRates[k][i]
                    if mu > 0 {
                        if mu < muMin { muMin = mu }
                        if mu > muMax { muMax = mu }
                        seenAnyClass = true
                    }
                }
                if seenAnyClass && muMin > 0 {
                    let r = muMax / muMin
                    if r > 3.0 {
                        amplifyOK = false
                        if r > worstRatio { worstRatio = r; worstStation = i }
                    }
                }
            }
        }
        criteria.append((
            label: "No class-transition amplification at high-ρ stations",
            ok: amplifyOK,
            detail: amplifyOK
                ? (K > 1 ? "no station with ρ > 0.7 has class μ-ratio > 3"
                         : "single-class network — N/A")
                : "S\(worstStation + 1) has ρ = \(String(format: "%.2f", rhos[worstStation])) and class μ-ratio = \(String(format: "%.1f", worstRatio)) (Kumar-Seidman / Bramson signature)"
        ))

        // Aggregate. Severity: criterion 4 (class-transition amplification)
        // is the strongest signal of pathology — when it fires alone it
        // already pushes to red. Otherwise count failures: 0 → green,
        // 1-2 → yellow, ≥3 → red.
        let failures = criteria.filter { !$0.ok }.count
        let amplifyFails = !amplifyOK
        let q: NetworkEditorModel.FeedbackQuality
        if amplifyFails {
            q = .red
        } else if failures == 0 {
            q = .green
        } else if failures <= 2 {
            q = .yellow
        } else {
            q = .red
        }
        return (q, criteria)
    }

    private func clearTractability(on editor: NetworkEditorModel) {
        editor.isAnalyticallyTractable = false
        editor.tractabilityTitle = ""
        editor.tractabilityDetail = ""
        editor.tractabilityMeans = []
        editor.tractabilityMeansLabel = ""
        editor.tractabilityExplanation = ""
        editor.tractabilityIsExact = false
        editor.hasFeedback = false
        editor.feedbackDescription = ""
        editor.feedbackQuality = .notReentrant
        editor.feedbackCriteria = []
    }

    /// Build a short human-readable description of the routing cycles in
    /// `aggregatedP`: lists self-loops, immediate two-station feedbacks,
    /// and notes the count of any longer cycles via SCC. Stations are
    /// 1-indexed in the user-facing text. Used by the Re-entrant
    /// flag's popover so the user can see *why* the network is marked
    /// re-entrant, not just that it is.
    private static func describeFeedback(aggregatedP P: [[Double]]) -> String {
        let d = P.count
        var lines: [String] = []
        var selfLoops: [Int] = []
        for i in 0..<d where P[i][i] > 1e-12 { selfLoops.append(i + 1) }
        if !selfLoops.isEmpty {
            let list = selfLoops.map { "S\($0)" }.joined(separator: ", ")
            lines.append("Self-loop(s): \(list).")
        }
        var pairs: [(Int, Int)] = []
        for i in 0..<d {
            for j in (i + 1)..<d where P[i][j] > 1e-12 && P[j][i] > 1e-12 {
                pairs.append((i + 1, j + 1))
            }
        }
        if !pairs.isEmpty {
            let list = pairs.map { "S\($0.0) ↔ S\($0.1)" }.joined(separator: ", ")
            lines.append("Immediate feedback: \(list).")
        }
        // Longer cycles: stations belonging to a non-trivial SCC after
        // removing self-loops and direct two-cycles already reported.
        let longCycleStations = stationsInLongerCycles(P, ignoreSelfLoops: selfLoops, ignorePairs: pairs)
        if !longCycleStations.isEmpty {
            let list = longCycleStations.map { "S\($0)" }.joined(separator: ", ")
            lines.append("Longer rework loop through: \(list).")
        }
        if lines.isEmpty {
            lines.append("Routing graph contains a directed cycle.")
        }
        return lines.joined(separator: "\n")
    }

    /// Tarjan-style SCC over the routing graph; returns the union of
    /// stations that belong to any SCC of size ≥ 2 *excluding* the
    /// already-reported direct two-cycles. Stations are 1-indexed in
    /// the returned list.
    private static func stationsInLongerCycles(
        _ P: [[Double]],
        ignoreSelfLoops: [Int],
        ignorePairs: [(Int, Int)]
    ) -> [Int] {
        let d = P.count
        var index = 0
        var indices = [Int](repeating: -1, count: d)
        var lowlink = [Int](repeating: 0, count: d)
        var onStack = [Bool](repeating: false, count: d)
        var stack: [Int] = []
        var sccs: [[Int]] = []

        func strongconnect(_ v: Int) {
            indices[v] = index
            lowlink[v] = index
            index += 1
            stack.append(v); onStack[v] = true
            for w in 0..<d where v != w && P[v][w] > 1e-12 {
                if indices[w] == -1 {
                    strongconnect(w)
                    lowlink[v] = min(lowlink[v], lowlink[w])
                } else if onStack[w] {
                    lowlink[v] = min(lowlink[v], indices[w])
                }
            }
            if lowlink[v] == indices[v] {
                var comp: [Int] = []
                while let top = stack.popLast() {
                    onStack[top] = false
                    comp.append(top)
                    if top == v { break }
                }
                if comp.count >= 2 { sccs.append(comp) }
            }
        }
        for v in 0..<d where indices[v] == -1 { strongconnect(v) }

        let pairSet = Set(ignorePairs.flatMap { [$0.0, $0.1] })
        var out: Set<Int> = []
        for comp in sccs {
            // A 2-element SCC matching an immediate-feedback pair is
            // already covered; skip it.
            if comp.count == 2 {
                let a = comp[0] + 1, b = comp[1] + 1
                if pairSet.contains(a) && pairSet.contains(b) { continue }
            }
            for v in comp { out.insert(v + 1) }
        }
        for s in ignoreSelfLoops { out.remove(s) }
        return out.sorted()
    }

    /// Heavy-traffic / Brownian-approximation health checks for the network.
    /// Shared by `showNetworkPrimitives` (for the full report) and the canvas
    /// overlay banner logic (to decide whether to display the red warning).
    /// `infiniteBuffers` suppresses the small-buffer warning for networks
    /// modeled with infinite capacity.
    private func networkWarnings(for data: SRBMExporter.SRBMData,
                                 infiniteBuffers: Bool) -> [String] {
        let d = data.d
        var rho = [Double](repeating: 0, count: d)
        for i in 0..<d {
            rho[i] = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : 0
        }

        var warnings: [String] = []

        for i in 0..<d {
            if rho[i] >= 1.0 {
                warnings.append(String(
                    format: "station %d is overloaded (ρ = %.4f ≥ 1). The network is unstable in the infinite-buffer sense; the Brownian heavy-traffic approximation does not apply and analytical rho_i, Gamma_i values will be unreliable.",
                    i + 1, rho[i]
                ))
            } else if rho[i] >= 0.95 {
                // near-saturation is ideal for heavy-traffic — no warning
            } else if rho[i] < 0.5 && rho[i] > 1e-9 {
                warnings.append(String(
                    format: "station %d has low utilization (ρ = %.4f). The SRBM heavy-traffic approximation is most accurate when ρ is close to 1; results here may diverge from simulation.",
                    i + 1, rho[i]
                ))
            } else if rho[i] <= 1e-9 {
                warnings.append(String(
                    format: "station %d has no offered traffic (ρ ≈ 0); check that sources route to it.",
                    i + 1
                ))
            }
        }

        // Unbalanced traffic intensities
        let activeRhos = rho.filter { $0 > 1e-9 && $0 < 1.0 }
        if let rMax = activeRhos.max(), let rMin = activeRhos.min(),
           rMax - rMin > 0.30 {
            warnings.append(String(
                format: "traffic intensities are unbalanced (ρ ranges from %.3f to %.3f). Balanced heavy-traffic theory assumes all stations near ρ = 1 simultaneously; single-bottleneck behavior may dominate.",
                rMin, rMax
            ))
        }

        // Covariance-matrix health
        var sigmaDiagMin = Double.infinity
        for i in 0..<d { sigmaDiagMin = min(sigmaDiagMin, data.gamma[i][i]) }
        if sigmaDiagMin < 1e-6 {
            warnings.append("Σ has a near-zero diagonal entry. SRBM requires genuine stochasticity on every coordinate; a deterministic station will make the diffusion degenerate.")
        }

        // Reflection-matrix existence condition (completely-S / no trap).
        let rCheck = Self.checkReflectionCompletelyS(aggregatedP: data.aggregatedP, d: d)
        if !rCheck.ok, let reason = rCheck.reason {
            warnings.append("Reflection matrix R = I − Pᵀ is not completely-S: \(reason) SRBM does not exist on this network — results are meaningless.")
        }

        // Small buffer sizes — only relevant for finite-capacity networks.
        // Infinite-capacity networks use buffer size = 1 as a placeholder; it
        // carries no physical meaning, so no warning.
        if !infiniteBuffers {
            for i in 0..<d {
                if data.aVec[i] < 2 {
                    warnings.append(String(
                        format: "station %d has a very small buffer (a = %g). The SRBM is a continuous hypercube limit; with a ≤ 1 the approximation can be coarse.",
                        i + 1, data.aVec[i]
                    ))
                }
            }
        }

        return warnings
    }

    /// Validates the physical link structure of the network against the
    /// conventions BNET assumes for SRBM analysis:
    ///
    ///   • Every link leaving a source must enter a buffer. Sources feed
    ///     queueing buffers, not stations directly — the arrival variance
    ///     must pass through the buffer.
    ///   • Every link entering a sink must come from a station (infinite
    ///     buffers), or from a station or a buffer (finite buffers). The
    ///     finite-buffer allowance corresponds to overflow loss, where
    ///     jobs that cannot enter a full buffer spill straight to sink.
    ///   • No link may leave a sink. A sink is terminal; the exporters
    ///     ignore an arc out of one.
    ///
    /// Returns an array of violation messages (empty if the network is
    /// well-formed). Callers append these to the warning list so both
    /// the canvas banner and the Analyze Network report flag the issue.
    private static func validateLinkStructure(
        nodes: [NetworkNode],
        links: [NetworkLink],
        infiniteBuffers: Bool
    ) -> [String] {
        var byID = [UUID: NetworkNode]()
        for n in nodes { byID[n.id] = n }

        var out: [String] = []
        for link in links {
            guard let from = byID[link.fromNodeID],
                  let to   = byID[link.toNodeID] else { continue }

            // Rule 1 — sources feed buffers only.
            if from.kind == .source && to.kind != .buffer {
                out.append("link from source '\(from.name)' goes to '\(to.name)' (kind=\(to.kind.rawValue)); sources must route to a buffer.")
            }

            // Rule 1b — a sink is terminal. Every exporter walks
            // source → buffer → station → sink and drops an arc that
            // leaves a sink, so a document carrying one is solved as a
            // different network than the one drawn. The Link tool refuses
            // to create one (NetworkEditorModel.handleLinkSelection); this
            // is the converse rule, for a document that already has one.
            if from.kind == .sink {
                out.append("link out of sink '\(from.name)' goes to '\(to.name)' (kind=\(to.kind.rawValue)); a sink is terminal, and every exporter ignores this link. Delete it, or route from the station that feeds the sink instead.")
            }

            // Rule 2 — sink sources depend on buffer model.
            if to.kind == .sink {
                if infiniteBuffers {
                    if from.kind != .station {
                        out.append("link into sink '\(to.name)' comes from '\(from.name)' (kind=\(from.kind.rawValue)); infinite-buffer networks only allow station → sink.")
                    }
                } else {
                    if from.kind != .station && from.kind != .buffer {
                        out.append("link into sink '\(to.name)' comes from '\(from.name)' (kind=\(from.kind.rawValue)); finite-buffer networks only allow station → sink or buffer → sink (overflow).")
                    }
                }
            }
        }
        return out
    }

    /// Verifies the reflection matrix R = I − P⊤ is completely-S (the
    /// Taylor-Williams existence condition for SRBM on the orthant), and
    /// in particular an M-matrix (which automatically implies completely-S
    /// for generalized Jackson networks). Returns (true, nil) when OK.
    ///
    /// For physical queueing networks the check normally passes because P
    /// is sub-stochastic with at least one sink-connected row. It fails in
    /// pathological cases: closed routing loops with no sink path, or
    /// extreme self-loops that leave R singular.
    ///
    /// Algorithm:
    ///   1. Solve R·u = 1 (u ∈ ℝᵈ). If the solve is singular → fail.
    ///   2. Every uᵢ must be > 0 (strict). u interprets as the "stability
    ///      certificate": fluid-fill of station i before emptying.
    ///   3. R must have positive diagonal and non-positive off-diagonals.
    private static func checkReflectionCompletelyS(
        aggregatedP P: [[Double]], d: Int
    ) -> (ok: Bool, reason: String?) {
        guard d > 0 else { return (true, nil) }

        // Build R = I − P⊤.
        var R = Array(repeating: [Double](repeating: 0, count: d), count: d)
        for i in 0..<d {
            for j in 0..<d {
                R[i][j] = (i == j ? 1.0 : 0.0) - P[j][i]
            }
        }

        // Sign-pattern check: R_ii > 0, R_ij ≤ 0 for i ≠ j.
        for i in 0..<d {
            if R[i][i] <= 1e-12 {
                return (false, "diagonal entry R[\(i + 1)][\(i + 1)] = \(String(format: "%.4f", R[i][i])) is not positive (station has a self-loop with probability ≥ 1).")
            }
            for j in 0..<d where j != i {
                if R[i][j] > 1e-9 {
                    return (false, "off-diagonal R[\(i + 1)][\(j + 1)] = \(String(format: "%.4f", R[i][j])) > 0 — a routing probability is negative (generator bug).")
                }
            }
        }

        // Solve R·u = 1 and check u > 0 componentwise.
        var A = R
        var rhs = [Double](repeating: 1.0, count: d)
        for i in 0..<d {
            var piv = i
            var best = abs(A[i][i])
            for r in (i + 1)..<d where abs(A[r][i]) > best {
                best = abs(A[r][i]); piv = r
            }
            if best < 1e-14 {
                return (false, "R is singular — routing matrix P has spectral radius 1 (closed cycle with no sink path).")
            }
            if piv != i { A.swapAt(i, piv); rhs.swapAt(i, piv) }
            for r in (i + 1)..<d {
                let f = A[r][i] / A[i][i]
                for c in i..<d { A[r][c] -= f * A[i][c] }
                rhs[r] -= f * rhs[i]
            }
        }
        var u = [Double](repeating: 0, count: d)
        for i in stride(from: d - 1, through: 0, by: -1) {
            var s = rhs[i]
            for c in (i + 1)..<d { s -= A[i][c] * u[c] }
            u[i] = s / A[i][i]
        }
        for i in 0..<d {
            if u[i] <= 1e-9 {
                return (false, "station \(i + 1) has no finite mean fluid-fill time (u_\(i + 1) = \(String(format: "%.4f", u[i])) ≤ 0). Jobs at station \(i + 1) cannot escape to the sink — add a positive sink route.")
            }
        }
        return (true, nil)
    }

    /// Finding produced by `formatNetworkAnalysis`. Each issue is classified
    /// by severity and paired with a mechanism explanation and an actionable
    /// fix, plus a list of performance metrics whose reliability it dents.
    private struct AnalysisFinding {
        enum Severity: Int { case critical = 0, warning = 1, info = 2 }
        let severity: Severity
        let title: String
        let why: String
        let fix: String
        let affects: [String]
    }

    /// Builds a comprehensive reliability analysis of the current network.
    /// Checks every primitive (ρ, SCVs, servers, buffers, routing, covariance,
    /// drift) against the assumptions of SRBM heavy-traffic theory, and for
    /// each issue provides: (a) the mechanism by which it hurts accuracy,
    /// (b) the parameter change that would bring the approximation closer to
    /// simulation, and (c) which performance metrics to distrust.
    private func formatNetworkAnalysis(_ data: SRBMExporter.SRBMData,
                                       infiniteBuffers: Bool) -> String {
        let d = data.d
        let K = data.K
        var findings: [AnalysisFinding] = []

        // ── Per-station ρ ────────────────────────────────────────────
        var rho = [Double](repeating: 0, count: d)
        for i in 0..<d {
            rho[i] = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : 0
        }

        for i in 0..<d {
            if rho[i] >= 1.0 {
                findings.append(AnalysisFinding(
                    severity: .critical,
                    title: String(format: "Station %d is unstable (ρ = %.3f ≥ 1)", i + 1, rho[i]),
                    why: "Heavy-traffic SRBM requires every station to be stable (ρ < 1). An overloaded station has an infinite queue in the fluid limit; the diffusion approximation is undefined and E[X] values returned by the solver are meaningless.",
                    fix: String(format: "Reduce the effective arrival rate to station %d (lower λ or reroute traffic) or increase capacity by adding servers / raising the service rate μ (currently %.4f). Target ρ < 1 with comfortable margin, ideally 0.85–0.99.", i + 1, data.serviceRates[i]),
                    affects: ["E[X_\(i+1)]", "sojourn_\(i+1)", "E[X] for every station (unstable network)"]
                ))
            } else if rho[i] >= 0.995 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Station %d is near-critical (ρ = %.3f)", i + 1, rho[i]),
                    why: "At ρ ≳ 0.995 the queue has long correlation time; finite-buffer truncation and Σ-scaling sensitivity both amplify, so E[X] can be very sensitive to mesh size and buffer choice.",
                    fix: String(format: "If physically accurate, keep this — SRBM is most accurate near ρ = 1. But run two mesh sizes to confirm E[X_%d] has converged. On finite-buffer networks, increase buffer a_%d well beyond E[X_%d].", i + 1, i + 1, i + 1),
                    affects: ["E[X_\(i+1)] (numerical stability)"]
                ))
            } else if rho[i] < 0.5 && rho[i] > 1e-9 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Station %d is lightly loaded (ρ = %.3f, below heavy-traffic regime)", i + 1, rho[i]),
                    why: "SRBM is the heavy-traffic limit where ρ → 1. At low ρ the stationary distribution has a large atom at zero that the diffusion smooths out; the approximation systematically underestimates P(X=0) and overestimates mean queue length. Error ranges roughly 20–50% below ρ = 0.5.",
                    fix: String(format: "Raise α_%d (route more traffic through station %d) or reduce μ_%d (currently %.4f) so that ρ_%d is closer to 1. If the true load is this low, prefer an M/G/1 or M/G/s closed-form — SRBM is not the right model.", i + 1, i + 1, i + 1, data.serviceRates[i], i + 1),
                    affects: ["E[X_\(i+1)]", "sojourn_\(i+1)", "class waiting times"]
                ))
            } else if rho[i] <= 1e-9 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Station %d has no offered traffic (ρ ≈ 0)", i + 1),
                    why: "No class routes through this station, so α = 0. SRBM produces degenerate output; the station is effectively disconnected.",
                    fix: String(format: "Check your routing links — either some source should feed station %d or this station should be removed.", i + 1),
                    affects: ["station \(i+1) metrics (undefined)"]
                ))
            } else if rho[i] < 0.7 {
                findings.append(AnalysisFinding(
                    severity: .info,
                    title: String(format: "Station %d is moderately loaded (ρ = %.3f)", i + 1, rho[i]),
                    why: "Below ρ ≈ 0.7 the heavy-traffic approximation starts to noticeably overestimate queue length. Expect 10–20% error vs simulation.",
                    fix: "If possible, run a Monte Carlo comparison; or raise ρ toward 0.85 to sit comfortably in the heavy-traffic regime.",
                    affects: ["E[X_\(i+1)]"]
                ))
            }
        }

        // ── Unbalanced utilizations ──────────────────────────────────
        let activeRhos = rho.filter { $0 > 1e-9 && $0 < 1.0 }
        if let rMax = activeRhos.max(), let rMin = activeRhos.min(), rMax - rMin > 0.30 {
            findings.append(AnalysisFinding(
                severity: .warning,
                title: String(format: "Utilizations are unbalanced (ρ range %.3f – %.3f, spread %.2f)", rMin, rMax, rMax - rMin),
                why: "Balanced heavy-traffic theory (Harrison–Reiman) assumes every station simultaneously approaches ρ → 1. When one station dominates, the multi-dimensional SRBM degenerates toward the one-dimensional M/G/1 of the bottleneck, and non-bottleneck E[X_i] values are biased low.",
                fix: "Balance capacities: either add servers / raise μ at the bottleneck, or combine stations whose load patterns resemble each other. Alternatively, accept that only the bottleneck's E[X] will be close to simulation.",
                affects: activeRhos.count > 1 ? ["E[X_i] for non-bottleneck stations"] : []
            ))
        }

        // ── Service SCV extremes ─────────────────────────────────────
        for i in 0..<d {
            let scv = data.effectiveServiceSCVs[i]
            if scv > 4.0 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Station %d has a highly variable service time (c²_s = %.2f)", i + 1, scv),
                    why: "SRBM is a two-moment approximation: it only sees mean and variance of service time. With c²_s > 4 (e.g. hyperexponential / long-tail), higher moments dominate the queue dynamics and the two-moment fit systematically UNDERESTIMATES E[X] (often by 30% or more).",
                    fix: String(format: "If the true service distribution is long-tailed, consider simulation or a matrix-exponential method. If the SCV = %.2f is the result of mixing several class service times, splitting those into separate stations would reduce the aggregated SCV.", scv),
                    affects: ["E[X_\(i+1)]", "sojourn_\(i+1)"]
                ))
            } else if scv <= 1e-9 {
                // Service SCV = 0 is only a CRITICAL failure when it makes
                // Σ_ii degenerate. With random arrivals the station is a
                // well-posed M/D/1-type queue and SRBM is just two-moment-fit
                // inaccurate (not undefined).
                if data.gamma[i][i] < 1e-6 {
                    findings.append(AnalysisFinding(
                        severity: .critical,
                        title: String(format: "Station %d has zero covariance (c²_s = 0 and no arrival variance)", i + 1),
                        why: "SRBM requires a non-degenerate covariance Σ. Combined zero service and arrival variance make Σ_ii = 0, which degenerates the diffusion PDE and produces unreliable or singular results.",
                        fix: String(format: "Change station %d's service distribution away from Constant — use Erlang, Gamma, or Exponential with the same mean. Alternatively, add variability to the upstream arrival stream. Even a small c²_s (say 0.1) restores well-posedness.", i + 1),
                        affects: ["E[X_\(i+1)]", "entire solve (PDE singular)"]
                    ))
                } else {
                    findings.append(AnalysisFinding(
                        severity: .info,
                        title: String(format: "Station %d has deterministic service (c²_s = 0) — M/D/1-like", i + 1),
                        why: "Station is well-posed (Σ_ii is kept positive by arrival variability), but the two-moment SRBM slightly overestimates queue length relative to the Pollaczek–Khinchine exact answer for M/D/1.",
                        fix: String(format: "If you need high accuracy for deterministic-service stations, cross-check E[X_%d] against the M/D/1 formula ρ²/(2(1−ρ)). Otherwise SRBM is usually within ~10%.", i + 1),
                        affects: ["E[X_\(i+1)]"]
                    ))
                }
            } else if scv < 0.1 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Station %d has near-deterministic service (c²_s = %.3f)", i + 1, scv),
                    why: "With very low service-time variance, the two-moment SRBM OVERESTIMATES queue length compared to simulation. The true distribution has negligible tail; the diffusion's Gaussian smoothing adds spurious variance.",
                    fix: "If service really is deterministic, use a D/G/1 or simulation. Otherwise, increase the service-distribution variance (e.g. replace a Constant with an Erlang or Gamma) so c²_s ≳ 0.2.",
                    affects: ["E[X_\(i+1)]", "sojourn_\(i+1)"]
                ))
            }
        }

        // ── External arrival SCV extremes ────────────────────────────
        for c in 0..<K where c < data.arrivalSCVs.count {
            let scv = data.arrivalSCVs[c]
            let lam = data.classExternalArrivals[c]
            guard lam > 1e-12 else { continue }
            if scv > 4.0 {
                findings.append(AnalysisFinding(
                    severity: .warning,
                    title: String(format: "Class %d has a highly variable (bursty) arrival process (c²_a = %.2f)", c + 1, scv),
                    why: "High arrival SCV drives station-1 covariance up linearly: Σ_11 ≈ λ·(c²_a + c²_s). With c²_a > 4 the Whitt superposition formulas used downstream break down — departure-SCV propagation becomes unreliable and E[X] at downstream stations is biased low.",
                    fix: String(format: "Replace class-%d's arrival distribution with one closer to exponential (c²_a = 1), or decompose the bursty source into several Poisson sources with different rates.", c + 1),
                    affects: ["E[X_i] at every station visited by class \(c+1)"]
                ))
            } else if scv < 0.1 && scv > 1e-9 {
                findings.append(AnalysisFinding(
                    severity: .info,
                    title: String(format: "Class %d has near-periodic arrivals (c²_a = %.3f)", c + 1, scv),
                    why: "Deterministic-like arrivals reduce Σ_ii at the entry station. The SRBM diffusion still applies but the two-moment fit slightly overestimates queue variability.",
                    fix: "Usually fine to leave as-is; SCV near 0 matters less than SCV near ∞.",
                    affects: []
                ))
            }
        }

        // ── Multi-server stations ────────────────────────────────────
        for i in 0..<d {
            if data.numberOfServers[i] > 1 {
                findings.append(AnalysisFinding(
                    severity: .info,
                    title: String(format: "Station %d is multi-server (s = %d)", i + 1, data.numberOfServers[i]),
                    why: "SRBM is strictly correct for single-server FIFO queues; for multi-server stations BNET uses the G/G/s heavy-traffic heuristic (capacity = s·μ). This is accurate to within ~5–10% when ρ is near 1 but degrades at moderate ρ.",
                    fix: "If exact multi-server accuracy matters, compare against M/M/s closed form or simulation. Otherwise, the heuristic is usually adequate.",
                    affects: ["E[X_\(i+1)]"]
                ))
            }
        }

        // ── Finite-buffer truncation ─────────────────────────────────
        if !infiniteBuffers {
            for i in 0..<d {
                if data.aVec[i] < 2 {
                    findings.append(AnalysisFinding(
                        severity: .warning,
                        title: String(format: "Station %d buffer is very small (a = %g)", i + 1, data.aVec[i]),
                        why: "The FEM mesh needs several cells to resolve the density; with a ≤ 1 the hypercube domain is too thin to represent the boundary-layer structure near x = 0.",
                        fix: String(format: "Increase buffer size at station %d to at least 4–5 units; re-check E[X] at that buffer and one larger to confirm insensitivity.", i + 1),
                        affects: ["E[X_\(i+1)]"]
                    ))
                } else if data.aVec[i] < 10 {
                    findings.append(AnalysisFinding(
                        severity: .info,
                        title: String(format: "Station %d buffer is modest (a = %g)", i + 1, data.aVec[i]),
                        why: "Small buffers mean blocking effects dominate; the SRBM answer is still meaningful but the loss / blocking probability will not match classical Jackson intuition.",
                        fix: "If you want the infinite-buffer Harrison-Reiman answer, toggle 'Infinite Buffers' instead. If you want manufacturing blocking, this is correct as-is.",
                        affects: []
                    ))
                }
            }
        }

        // ── Routing feedback / cycles ────────────────────────────────
        var hasTwoCycle = false
        var maxSelfLoop = 0.0
        for i in 0..<d {
            maxSelfLoop = max(maxSelfLoop, data.aggregatedP[i][i])
            for j in 0..<d where j != i {
                if data.aggregatedP[i][j] > 1e-9 && data.aggregatedP[j][i] > 1e-9 {
                    hasTwoCycle = true
                }
            }
        }
        if maxSelfLoop > 1e-6 {
            findings.append(AnalysisFinding(
                severity: .info,
                title: String(format: "Routing has self-loops (max P[i][i] = %.3f)", maxSelfLoop),
                why: "A customer can re-enter the same station. The arrival stream to that station is no longer the renewal superposition Whitt's formula assumes, so the computed arrival SCV (and therefore Σ) is an approximation.",
                fix: "If the self-loop is physically meaningful, the approximation is usually fine at moderate probabilities (P < 0.3). For P close to 1 (e.g. heavy rework), consider modeling the loop as a separate station.",
                affects: ["E[X] at looped stations"]
            ))
        }
        if hasTwoCycle {
            findings.append(AnalysisFinding(
                severity: .info,
                title: "Routing has feedback cycles (i ↔ j)",
                why: "Departure processes from station j feed back into station i whose departures in turn feed j. The Whitt superposition/departure approximations iterate to a fixed point; the fixed-point SCV is correct only in heavy traffic and converges slowly.",
                fix: "Raise all ρ in the cycle toward 1 to tighten the heavy-traffic limit. For lightly-loaded feedback networks, simulation is more reliable.",
                affects: ["E[X_i] for stations in the cycle"]
            ))
        }

        // ── Link-structure validation (source/sink connection rules)
        let structureViolations = Self.validateLinkStructure(
            nodes: activeEditor.nodes, links: activeEditor.links,
            infiniteBuffers: infiniteBuffers)
        for msg in structureViolations {
            findings.append(AnalysisFinding(
                severity: .critical,
                title: "Illegal link: \(msg.prefix(80))\(msg.count > 80 ? "…" : "")",
                why: "Qnet's SRBM pipeline assumes sources feed buffers (so arrival variance flows through the queue) and sinks receive only stations (infinite-buffer networks) or stations plus overflowing buffers (finite-buffer networks). Links that violate these rules corrupt the exported (Γ, R, α) primitives.",
                fix: "Delete the offending link and reconnect it via the correct node kinds. On finite-buffer networks you may add a direct buffer → sink link to represent overflow loss.",
                affects: ["every metric (input network ill-formed)"]
            ))
        }

        // ── Reflection matrix R must be completely-S (Taylor-Williams)
        let rCheck = Self.checkReflectionCompletelyS(aggregatedP: data.aggregatedP, d: d)
        if !rCheck.ok, let reason = rCheck.reason {
            findings.append(AnalysisFinding(
                severity: .critical,
                title: "Reflection matrix R = I − Pᵀ is not completely-S",
                why: "SRBM on the orthant only exists when R is completely-S (Taylor-Williams 1993). For generalized Jackson networks this reduces to: every station must have a positive-probability path to the sink. The specific failure: \(reason)",
                fix: "Ensure every station has some escape route to the sink. If the offending station routes only to other stations, add a sink probability (e.g. reduce forward / feedback probabilities so their sum < 1).",
                affects: ["every metric (SRBM is undefined)"]
            ))
        }

        // ── Covariance health ────────────────────────────────────────
        var sigmaDiagMin = Double.infinity
        var minDiagIdx = 0
        for i in 0..<d {
            if data.gamma[i][i] < sigmaDiagMin {
                sigmaDiagMin = data.gamma[i][i]
                minDiagIdx = i
            }
        }
        if sigmaDiagMin < 1e-6 {
            findings.append(AnalysisFinding(
                severity: .critical,
                title: String(format: "Covariance matrix Σ is near-singular (min diag %.2e at station %d)", sigmaDiagMin, minDiagIdx + 1),
                why: "SRBM is a non-degenerate diffusion — every coordinate must have positive variance. A zero on the diagonal means the PDE loses ellipticity and the solve is ill-posed.",
                fix: String(format: "Add variability to station %d's arrival or service distribution (anything non-Constant). Also check that at least one upstream source is non-deterministic.", minDiagIdx + 1),
                affects: ["all metrics (PDE undefined)"]
            ))
        }

        // ── Class heterogeneity at a station ─────────────────────────
        if K > 1 {
            for i in 0..<d {
                var minRate = Double.infinity
                var maxRate = 0.0
                var visitingClasses = 0
                for k in 0..<K {
                    let rate = data.classServiceRates[k][i]
                    if data.alphaPerClass[k][i] > 1e-9 && rate > 1e-12 {
                        minRate = min(minRate, rate)
                        maxRate = max(maxRate, rate)
                        visitingClasses += 1
                    }
                }
                if visitingClasses >= 2 && maxRate > 0, minRate.isFinite, maxRate / minRate > 5.0 {
                    findings.append(AnalysisFinding(
                        severity: .warning,
                        title: String(format: "Station %d services classes with very different speeds (ratio %.1fx)", i + 1, maxRate / minRate),
                        why: "Compound service-time aggregation (the new research flavor) computes E[S] and E[S²] from a mixture, but the stationary distribution of a multi-class FIFO queue is not fully characterized by two moments when class service times differ by more than ~5x. Expect 10–30% error on E[X] and per-class W.",
                        fix: "If possible, dedicate separate stations to the fast and slow classes. Or use priority queueing with a different analytical model.",
                        affects: ["E[X_\(i+1)]", "per-class waiting times at station \(i+1)"]
                    ))
                }
            }
        }

        // ── Drift-to-variance ratio (heavy-traffic tightness) ────────
        for i in 0..<d where rho[i] > 1e-9 && rho[i] < 1.0 && data.gamma[i][i] > 1e-12 {
            // η_i = 2|θ_i| / Σ_ii — the exponent of the exponential tail for
            // the marginal 1D SRBM at station i. η too large → queue nearly
            // always empty, heavy-traffic limit is loose.
            let eta = 2.0 * abs(data.drift[i]) / data.gamma[i][i]
            if eta > 5.0 {
                findings.append(AnalysisFinding(
                    severity: .info,
                    title: String(format: "Station %d has a sharply-peaked stationary density (η = %.2f)", i + 1, eta),
                    why: "The marginal SRBM decay rate 2|θ|/Σ is large, meaning the queue is rarely non-empty — the continuous diffusion is fitting what is essentially a point mass at zero. Numerically this is easy to solve but produces small E[X].",
                    fix: "Usually fine to leave as-is; but if you expected more queueing, raise ρ (increase λ or reduce μ).",
                    affects: []
                ))
            }
        }

        // ── Compose the report ───────────────────────────────────────
        let critCount = findings.filter { $0.severity == .critical }.count
        let warnCount = findings.filter { $0.severity == .warning }.count
        let infoCount = findings.filter { $0.severity == .info }.count
        let score = max(0, min(100, 100 - 35 * critCount - 15 * warnCount - 3 * infoCount))

        let reliabilityLabel: String
        if critCount > 0 { reliabilityLabel = "UNRELIABLE" }
        else if score >= 85 { reliabilityLabel = "HIGH" }
        else if score >= 65 { reliabilityLabel = "MODERATE" }
        else if score >= 40 { reliabilityLabel = "LOW" }
        else { reliabilityLabel = "UNRELIABLE" }

        func severityTag(_ s: AnalysisFinding.Severity) -> String {
            switch s {
            case .critical: return "[CRITICAL]"
            case .warning:  return "[WARNING ]"
            case .info:     return "[INFO    ]"
            }
        }

        // Padding helpers — avoid String(format:) with "%s" which is undefined
        // behavior in Swift (Swift String is not a C string).
        func padR(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        func padL(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }

        var out = ""
        out += "NETWORK ANALYSIS — Brownian Heavy-Traffic Reliability\n"
        out += "=====================================================\n\n"

        // ── Summary ──
        out += "NETWORK SUMMARY\n"
        out += "---------------\n"
        out += "Stations:         \(d)\n"
        out += "Customer classes: \(K)\n"
        out += "Buffer model:     \(infiniteBuffers ? "infinite" : "finite")\n\n"

        // ── Primitives snapshot ──
        out += "KEY PRIMITIVES\n"
        out += "--------------\n"
        out += "  " + padR("Station", 8) + "  " + padL("servers", 7) + "  " + padL("μ_eff", 7)
            + "  " + padL("α", 7) + "  " + padL("ρ", 9) + "  " + padL("c²_s_eff", 9)
            + "  " + padL("buffer", 7) + "\n"
        for i in 0..<d {
            let svr = padL("\(data.numberOfServers[i])", 7)
            let mu  = padL(String(format: "%.4f", data.serviceRates[i]), 7)
            let al  = padL(String(format: "%.4f", data.alpha[i]), 7)
            let rh  = padL(String(format: "%.4f", rho[i]), 9)
            let sc  = padL(String(format: "%.4f", data.effectiveServiceSCVs[i]), 9)
            let buf = padL(infiniteBuffers ? "∞" : String(format: "%g", data.aVec[i]), 7)
            out += "  " + padR("S\(i + 1)", 8) + "  " + svr + "  " + mu
                + "  " + al + "  " + rh + "  " + sc + "  " + buf + "\n"
        }
        out += "\n"
        out += "  " + padR("Class", 8) + "  " + padL("λ (ext)", 9) + "  " + padL("c²_a", 7) + "\n"
        for c in 0..<K {
            let scv = c < data.arrivalSCVs.count ? data.arrivalSCVs[c] : 0
            let lam = padL(String(format: "%.4f", data.classExternalArrivals[c]), 9)
            let sc  = padL(String(format: "%.4f", scv), 7)
            out += "  " + padR("C\(c + 1)", 8) + "  " + lam + "  " + sc + "\n"
        }
        out += "\n"

        // ── Overall assessment ──
        out += "OVERALL RELIABILITY ASSESSMENT\n"
        out += "------------------------------\n"
        out += "Score: \(score) / 100  (\(reliabilityLabel))\n"
        out += "Findings: \(critCount) critical, \(warnCount) warning, \(infoCount) info\n\n"

        switch reliabilityLabel {
        case "HIGH":
            out += "The network sits comfortably inside the assumptions of heavy-traffic SRBM theory. E[X] estimates should be within ~5–10% of simulation for most primitives.\n\n"
        case "MODERATE":
            out += "Some primitives sit near the edge of the heavy-traffic regime. E[X] estimates are probably directionally correct but may have 10–30% error. See the findings below for specifics.\n\n"
        case "LOW":
            out += "Several primitives violate the assumptions used by SRBM. Treat absolute E[X] values with caution — use them for relative comparisons only, and verify against simulation.\n\n"
        default: // UNRELIABLE
            if critCount > 0 {
                out += "At least one critical issue makes the SRBM approximation inapplicable. Resolve the critical findings before trusting any output.\n\n"
            } else {
                out += "The aggregated reliability score is very low. Expect absolute E[X] errors exceeding 30%.\n\n"
            }
        }

        // ── Findings ──
        if findings.isEmpty {
            out += "FINDINGS\n--------\nNo issues detected — all checks passed.\n\n"
        } else {
            out += "FINDINGS (grouped by severity)\n"
            out += "------------------------------\n\n"
            let ordered = findings.sorted { $0.severity.rawValue < $1.severity.rawValue }
            for (idx, f) in ordered.enumerated() {
                out += "\(severityTag(f.severity)) \(idx + 1). \(f.title)\n"
                out += "  Why:     \(f.why)\n"
                out += "  Fix:     \(f.fix)\n"
                if !f.affects.isEmpty {
                    out += "  Affects: \(f.affects.joined(separator: ", "))\n"
                }
                out += "\n"
            }
        }

        // ── Metric-by-metric reliability summary ──
        out += "PERFORMANCE METRIC RELIABILITY\n"
        out += "------------------------------\n"
        let rhoBelowHT = rho.contains { $0 > 1e-9 && $0 < 0.7 }
        let svcSCVBad  = (0..<d).contains { data.effectiveServiceSCVs[$0] > 4 || data.effectiveServiceSCVs[$0] < 0.1 }
        let arrSCVBad  = (0..<K).contains { c in c < data.arrivalSCVs.count && data.arrivalSCVs[c] > 4 }
        let unstable   = rho.contains { $0 >= 1.0 }

        func metric(_ name: String, _ level: String, _ note: String) -> String {
            "  " + padR(name + ":", 30) + "  " + padR(level, 10) + "  " + note + "\n"
        }

        if unstable {
            out += metric("E[X_i] (queue length)", "UNRELIABLE", "network is unstable — values are meaningless")
            out += metric("Throughput (Γ_i)",      "HIGH",       "throughput is bounded by capacity regardless of stability")
            out += metric("Utilization (ρ_i)",     "HIGH",       "computed directly from primitives")
            out += metric("Sojourn time",          "UNRELIABLE", "Little's law applied to meaningless E[X]")
            out += metric("Per-class W, T, N",     "UNRELIABLE", "downstream of E[X]")
        } else {
            let exLevel: String = (rhoBelowHT || svcSCVBad || arrSCVBad) ? "MODERATE" : "HIGH"
            let exNote: String
            if svcSCVBad { exNote = "service SCV is extreme — expect bias in E[X]" }
            else if arrSCVBad { exNote = "arrival SCV is extreme — expect bias in E[X]" }
            else if rhoBelowHT { exNote = "ρ below heavy-traffic regime — E[X] systematically biased" }
            else { exNote = "primitives inside heavy-traffic sweet spot" }
            out += metric("E[X_i] (queue length)", exLevel, exNote)
            out += metric("Throughput (Γ_i)",      "HIGH",  "Γ = α; derived exactly from traffic equations")
            out += metric("Utilization (ρ_i)",     "HIGH",  "ρ = α / (s·μ); derived exactly from primitives")
            out += metric("Sojourn time",          exLevel, "sojourn = E[X]/Γ; inherits E[X] reliability")
            out += metric("Per-class W, T, N",     exLevel, "Little's law applied to E[X]; inherits its reliability")
        }
        out += "\n"

        // ── Top suggestions ──
        if !findings.isEmpty {
            out += "TOP ACTIONABLE SUGGESTIONS\n"
            out += "--------------------------\n"
            let top = findings
                .sorted { $0.severity.rawValue < $1.severity.rawValue }
                .prefix(3)
            for (idx, f) in top.enumerated() {
                out += "\(idx + 1). \(f.fix)\n"
            }
            out += "\n"
        }

        return out
    }

    /// Builds a structured text report from SRBM primitives, plus heavy-traffic
    /// validity warnings (supplied by `networkWarnings(for:)`).
    private func formatNetworkPrimitives(_ data: SRBMExporter.SRBMData,
                                         warnings: [String]) -> String {
        let d = data.d
        let K = data.K

        // Per-station derived quantities
        var rho  = [Double](repeating: 0, count: d)
        for i in 0..<d {
            rho[i] = data.capacity[i] > 1e-12 ? data.alpha[i] / data.capacity[i] : 0
        }


        // ── Header ──────────────────────────────────────────────────
        var s = ""
        s += String(repeating: "=", count: 72) + "\n"
        s += "NETWORK PRIMITIVES (Brownian / SRBM)\n"
        s += String(repeating: "=", count: 72) + "\n\n"

        s += "Structure:\n"
        s += "  Stations (d):         \(d)\n"
        s += "  Customer classes (K): \(K)\n"
        s += "  Buffer sizes a:       [" +
             data.aVec.map { String(format: "%g", $0) }.joined(separator: ", ") + "]\n"
        s += "  Servers s_i:          [" +
             data.numberOfServers.map { "\($0)" }.joined(separator: ", ") + "]\n\n"

        // ── External arrivals ────────────────────────────────────────
        s += "External arrival rates λ_k (per class):\n"
        for k in 0..<K {
            s += String(format: "  Class %d:  %10.5f\n", k + 1, data.classExternalArrivals[k])
        }
        let totalLambda = data.classExternalArrivals.reduce(0, +)
        s += String(format: "  Total:    %10.5f\n\n", totalLambda)

        // ── Per-station primitives ───────────────────────────────────
        s += "Per-station primitives:\n"
        s += "  i | servers |        α_i |        μ_i |        c_i |       ρ_i |      b_i\n"
        s += "  " + String(repeating: "-", count: 72) + "\n"
        for i in 0..<d {
            s += String(format: "  %d |   %3d   | %10.5f | %10.5f | %10.5f | %9.5f | %+8.5f\n",
                        i + 1,
                        data.numberOfServers[i],
                        data.alpha[i],
                        data.serviceRates[i],
                        data.capacity[i],
                        rho[i],
                        data.drift[i])
        }
        s += "\n"
        s += "  α_i = Σ_k α^(k)_i     offered arrival rate at station i\n"
        s += "  μ_i = Σ_k (α^(k)_i/α_i) μ^(k)_i     throughput-weighted service rate\n"
        s += "  c_i = s_i · μ_i       station capacity\n"
        s += "  ρ_i = α_i / c_i       nominal traffic intensity\n"
        s += "  b_i = α_i - c_i       drift (SRBM)\n\n"

        // ── Per-class throughput per station ─────────────────────────
        s += "Per-class throughput α^(k)_i:\n"
        s += "         "
        for i in 0..<d { s += String(format: " station %d ", i + 1) }
        s += "\n"
        for k in 0..<K {
            s += String(format: "  class %d  ", k + 1)
            for i in 0..<d {
                s += String(format: "%10.5f ", data.alphaPerClass[k][i])
            }
            s += "\n"
        }
        s += "\n"

        // ── Routing matrix ───────────────────────────────────────────
        s += "Aggregated routing matrix P (row i → col j):\n"
        s += "          "
        for j in 0..<d { s += String(format: "    →%d    ", j + 1) }
        s += "\n"
        for i in 0..<d {
            s += String(format: "  from %d  ", i + 1)
            for j in 0..<d {
                s += String(format: " %8.4f ", data.aggregatedP[i][j])
            }
            s += "\n"
        }
        s += "\n"

        // ── Reflection matrix (diagonal + summary) ───────────────────
        s += "Reflection matrix R (d × 2d, columns = [lower_1, upper_1, lower_2, upper_2, …]):\n"
        for i in 0..<d {
            s += String(format: "  row %d: ", i + 1)
            for col in 0..<(2 * d) {
                s += String(format: "%+7.3f ", data.R[i][col])
            }
            s += "\n"
        }
        s += "\n"

        // ── Covariance matrix ────────────────────────────────────────
        s += "Covariance matrix Σ (diffusion coefficient):\n"
        for i in 0..<d {
            s += "  "
            for j in 0..<d {
                s += String(format: "%10.5f ", data.gamma[i][j])
            }
            s += "\n"
        }
        s += "\n"

        // ── Warnings ─────────────────────────────────────────────────
        if warnings.isEmpty {
            s += "No warnings — parameters look healthy for the Brownian approximation.\n"
        } else {
            // Emit each warning on a single line. If a line exceeds the
            // shell pane's width, the enclosing horizontal ScrollView
            // provides a scrollbar (see ContentView's TerminalPaneView).
            // ANSI escape \u{1B}[1;31m = bold red; \u{1B}[0m = reset.
            let redBold = "\u{1B}[1;31m"
            let reset   = "\u{1B}[0m"
            for msg in warnings {
                s += "\(redBold)!! Warning:\(reset) \(msg)\n"
            }
        }

        return s
    }

    // MARK: - Helpers

    /// Writes a command to a uniquely named, document-owned shell script.
    /// Returns nil when another run already owns the shared Shell or when
    /// the wrapper cannot be written.
    private func silentScript(
        _ command: String,
        label: String,
        parameters: [String: String] = [:],
        seed: UInt64? = nil,
        replicationSeeds: [UInt64] = [],
        normalizeNumbers: Bool = true
    ) -> String? {
        // ESC[A = cursor up, ESC[2K = erase line — removes the echoed bash command
        // Trailing line reports the exit status to the status-bar run
        // indicator (see TerminalModel.beginRun).
        // Same EXIT trap as `runScript`: the completion file is written
        // however the wrapper ends, so an interrupted run still finishes
        // in the status bar.
        let ownerID = activeTabID
        let ownerTitle = activeTabTitle
        let ownerEditor = activeEditor
        guard let handle = terminalModel.beginRun(
            label: label,
            ownerID: ownerID,
            ownerTitle: ownerTitle,
            report: { text, severity in
                ownerEditor.addStatus(text, severity: severity)
            }
        ) else {
            NSSound.beep()
            return nil
        }
        let donePath = handle.donePath
        let scopedCommand = command.replacingOccurrences(
            of: TerminalModel.statusInboxPlaceholder,
            with: handle.statusPath
        )
        // Same display-precision stage as `runScript`, and for the same
        // reason: it must sit after the tee, and as a separate pipeline
        // stage so `${PIPESTATUS[0]}` still names the solver.
        let displayFilter = outputPrecisionFilter(
            decimals: appSettings.outputDecimals,
            normalize: normalizeNumbers
        )
        // The wrapper's EXIT trap also removes the generated perl program —
        // the one artefact of this pipeline that used to outlive the run.
        let removeFilterProgram = "rm -f \"\(Self.outputPrecisionProgramURL.path)\""
        let script = "printf '\\033[A\\033[2K'\nprintf '%s\\n' \"$$\" > \"\(handle.pidPath)\"\ntrap 'printf \"%s\\n\" \"${_rc:-130}\" > \"\(donePath)\" ; \(removeFilterProgram)' EXIT\n{\n\(scopedCommand)\n_command_rc=$?\nexit $_command_rc\n} 2>&1 | tee \"\(handle.outputPath)\" | \(displayFilter)\n_rc=${PIPESTATUS[0]}\nexit $_rc"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_run_\(handle.id.uuidString.lowercased()).sh")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            terminalModel.failRunToLaunch(
                handle,
                message: "\(TerminalModel.displayLabel(forRunLabel: label)) could not start: \(error.localizedDescription)"
            )
            return nil
        }
        registerStructuredResult(
            handle: handle,
            label: label,
            ownerID: ownerID,
            ownerTitle: ownerTitle,
            ownerEditor: ownerEditor,
            parameters: parameters,
            seed: seed,
            replicationSeeds: replicationSeeds
        )
        return "bash \"\(file.path)\""
    }


    /// Reports a failure that stopped an action *before it started* — to the
    /// Status pane, not to a modal alert.
    ///
    /// Seventy-four call sites used to raise a one-button app-modal `NSAlert`
    /// **and** write the same failure to the Status pane on the same code
    /// path. The user was interrupted, with a generic Finder folder icon and
    /// an OK button, to acknowledge a sentence that was about to appear in a
    /// pane they were already looking at — and the half that carried the
    /// useful part (the resolver's search trail, the exporter's diagnosis of
    /// which station is unfed) was the half that vanished when they clicked
    /// OK. Here the summary and its detail arrive together: timestamped,
    /// filterable, selectable, exportable, and beside the rest of the run
    /// history that explains them.
    ///
    /// An alert is still right when the user believes an action *succeeded*
    /// and silence would be a lie — Save and Load are the two that remain.
    /// "The run did not start" is not one of those: the Status pane is
    /// precisely where someone looks to find out why a run produced nothing.
    ///
    /// - Parameters:
    ///   - summary: one line, already phrased for the log ("QNA aborted: …").
    ///   - detail: the longer diagnosis the alert used to carry. Indented
    ///     under the summary, one entry per line.
    ///   - severity: `.error` for a failure, `.warning` for "this method does
    ///     not apply to this network", which is a fact about the network
    ///     rather than a fault.
    ///   - editor: the tab that owns the action; a background tab must not
    ///     have its log written into by a foreground one.
    private func reportBlocked(
        _ summary: String,
        detail: String? = nil,
        severity: StatusSeverity = .error,
        on editor: NetworkEditorModel
    ) {
        // A report nobody can see is worse than the modal it replaced, so a
        // hidden Status pane is opened rather than written into blind. Same
        // spelling as View ▸ Panes ▸ Status so the two agree about motion.
        WorkspaceCommands.reveal(.status, appSettings: appSettings)
        editor.addStatus(summary, severity: severity)
        guard let detail else { return }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        // Most summaries already interpolate a one-line `localizedDescription`.
        // Repeating it underneath itself reads as a stutter, not as detail.
        guard !trimmed.isEmpty, !summary.contains(trimmed) else { return }
        for line in trimmed.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // `.info`, not the summary's severity: one failure should raise the
            // pane's warning-and-error count by one, not by however many lines
            // the resolver had to say about it.
            editor.addStatus("    " + text, severity: .info)
        }
    }

    /// An app-modal, one-button alert. Reserved for a failure the user would
    /// otherwise believe was a success — a save that did not write, a document
    /// that did not load. Everything that merely stops a run from starting
    /// goes to `reportBlocked` instead; see its comment for why.
    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Returns a shell `printf` fragment that announces how many CPU
    /// cores the about-to-run algorithm will use. Prepended to every
    /// runner's command string with `&&` so users can see at a glance
    /// whether they're getting all cores. For `parallel: true` we print
    /// the system's active processor count (OpenMP defaults to that);
    /// for `parallel: false` we say "single-threaded" to make clear it's
    /// by design (analytical algorithms like QNA / SBD don't benefit
    /// from threading at typical network sizes).
    private func threadCountBanner(parallel: Bool) -> String {
        let n = ProcessInfo.processInfo.activeProcessorCount
        if parallel {
            return "printf '[Threads] Using %d CPU cores (OpenMP)\\n' \(n)"
        } else {
            return "printf '[Threads] Single-threaded (analytical solver)\\n'"
        }
    }

    /// Banner for mixed-parallelism comparison runs that include both
    /// OpenMP-parallel sub-solvers (Sim/Spectral/FE) and single-threaded
    /// analytical sub-solvers (QNA/SBD/LP).
    private func threadCountBannerMixed() -> String {
        let n = ProcessInfo.processInfo.activeProcessorCount
        return "printf '[Threads] %d CPU cores for parallel solvers (Sim/Spectral/FE); analytical solvers (QNA/SBD/LP) are single-threaded\\n' \(n)"
    }

    // MARK: - Test set executor

    /// Generates `params.numTestCases` random networks within the
    /// requested bounds, then drives the entire algorithm sweep through
    /// a single shell script — same plumbing as Run Comparison so the
    /// progress lines, per-binary status, and final aggregate table all
    /// land in the Interactive Shell with one continuous command.
    ///
    /// Two phases:
    ///   1. Swift pre-generates every random network and writes the
    ///      input files (.qna, SRBM-spectral, .sim) to a per-run
    ///      temp directory.
    ///   2. Swift builds one large shell script that loops over the
    ///      cases, invokes each binary with stdout redirected to a
    ///      per-(case, algo) output file, prints a progress line per
    ///      case, then runs an inline awk aggregator over all output
    ///      files to print the final accuracy table.
    /// Builds a `TestSetParameters` from the AppSettings defaults for the
    /// requested regime. Used to pre-populate the popup so the user starts
    /// from their saved Settings ▸ Test Sets values rather than the
    /// hard-coded struct defaults.
    @MainActor
    private func loadTestSetDefaults(infinite: Bool) -> TestSetParameters {
        var p = TestSetParameters()
        if infinite {
            p.stationsLower = appSettings.testsetInfStationsLo
            p.stationsUpper = appSettings.testsetInfStationsHi
            p.classesLower  = appSettings.testsetInfClassesLo
            p.classesUpper  = appSettings.testsetInfClassesHi
            p.rhoLower      = appSettings.testsetInfRhoLo
            p.rhoUpper      = appSettings.testsetInfRhoHi
            p.numTestCases  = appSettings.testsetInfNumCases
            p.topology      = RandomNetworkGenerator.Topology(
                rawValue: appSettings.testsetInfTopology) ?? .feedForward
        } else {
            p.stationsLower = appSettings.testsetFinStationsLo
            p.stationsUpper = appSettings.testsetFinStationsHi
            p.classesLower  = appSettings.testsetFinClassesLo
            p.classesUpper  = appSettings.testsetFinClassesHi
            p.rhoLower      = appSettings.testsetFinRhoLo
            p.rhoUpper      = appSettings.testsetFinRhoHi
            p.numTestCases  = appSettings.testsetFinNumCases
            p.topology      = RandomNetworkGenerator.Topology(
                rawValue: appSettings.testsetFinTopology) ?? .feedForward
        }
        return p
    }

    /// Builds a `SpectralConvergenceParameters` from saved Settings defaults.
    @MainActor
    private func loadSpectralConvergenceDefaults() -> SpectralConvergenceParameters {
        var p = SpectralConvergenceParameters()
        p.stationsLower = appSettings.testsetSpcStationsLo
        p.stationsUpper = appSettings.testsetSpcStationsHi
        p.classesLower  = appSettings.testsetSpcClassesLo
        p.classesUpper  = appSettings.testsetSpcClassesHi
        p.rhoStart      = appSettings.testsetSpcRhoStart
        p.rhoEnd        = appSettings.testsetSpcRhoEnd
        p.rhoStep       = appSettings.testsetSpcRhoStep
        p.numTestCases  = appSettings.testsetSpcNumCases
        p.topology      = RandomNetworkGenerator.Topology(
            rawValue: appSettings.testsetSpcTopology) ?? .feedForward
        return p
    }

    nonisolated private func executeTestSet(params: TestSetParameters, infinite: Bool) async {
        await MainActor.run { self.testSetRunning = true }

        // ── Resolve binaries + sim params + output paths on MainActor ──
        struct Resolved {
            let bins: TestSetBinaries
            let simReps: Int, simWarm: Int, simTime: Int
            let smDegree: Int
            let femMeshSize: Int
            let femSolverIdx: Int
            let flpSolverName: String
            let flpGridN: Int
            let flpBasisM: Int
            let flpGridType: String
            let flpBasisNormalize: Bool
            let workDir: URL
            let lossCorrect: Bool
            let basCorrect: Bool
            let simBlockingFlag: String   // "-l" / " -e" / "" — passed to fBNAsim
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_testset_\(pid)_\(stamp)")
        try? FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)

        let r = await MainActor.run { () -> Resolved in
            let lpNames = ["highs", "glpk", "cplex"]
            return Resolved(
                bins: TestSetBinaries(
                    bnetSm:     findBinary(name: "bnet",        subdirectory: "BNAsm"),
                    bnaQna:     findBinary(name: "bna_qna",     subdirectory: "BNAqna"),
                    bnaRqna:    findBinary(name: "bna_rqna",    subdirectory: "BNArqna"),
                    bnaSbd:     findBinary(name: "bna_sbd",     subdirectory: "BNAsbd"),
                    jacksonSim: findBinary(name: "jackson_sim", subdirectory: "BNAsim"),
                    fSrbm:      findBinary(name: "srbm_solver", subdirectory: "fBNAsm"),
                    fFm:        findBinary(name: appSettings.femSolver == 0
                                                 ? "bna_fm_gauss" : "bna_fm_cbc",
                                            subdirectory: "fBNAfm"),
                    fLp:        findBinary(name: "fBNAlp_solver", subdirectory: "fBNAlp"),
                    fSim:       findBinary(name: "fBNAsim",      subdirectory: "fBNAsim")
                ),
                simReps: appSettings.simReplications,
                simWarm: appSettings.simWarmup,
                simTime: appSettings.simTime,
                smDegree: appSettings.smDegree,
                femMeshSize: appSettings.femMeshSize,
                femSolverIdx: appSettings.femSolver,
                flpSolverName: lpNames[max(0, min(appSettings.flpSolver, lpNames.count - 1))],
                flpGridN: appSettings.flpGridN,
                flpBasisM: appSettings.flpBasisM,
                flpGridType: appSettings.flpGridType == 1 ? "chebyshev" : "uniform",
                flpBasisNormalize: appSettings.flpBasisNormalize,
                workDir: workDir,
                // Mirror Run Comparison: SRBM exporters get the loss-mode
                // correction iff the user picked "Loss" (simBlocking == 0)
                // and the BAS-mode correction for BAS/BAS+ExtLoss
                // (simBlocking != 0). Infinite test sets bypass both
                // (lossModeCorrection / basModeCorrection have no effect
                // there anyway).
                lossCorrect: !infinite && appSettings.simBlocking == 0,
                basCorrect:  !infinite && appSettings.simBlocking != 0,
                simBlockingFlag: {
                    switch appSettings.simBlocking {
                    case 0:  return " -l"
                    case 2:  return " -e"
                    default: return ""
                    }
                }()
            )
        }

        // ── Pre-generate networks; write inputs to disk ──
        struct CaseMeta {
            let idx: Int
            let d: Int
            let K: Int
            let rho: Double
            let networkSeed: UInt64
            let simulationSeed: UInt64
        }
        var caseMeta: [CaseMeta] = []
        let baseSeed = params.seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        var rng = SeededRNG(seed: baseSeed)
        for caseIdx in 0..<params.numTestCases {
            let stations = Int.random(in: params.stationsLower...params.stationsUpper, using: &rng)
            let classes  = Int.random(in: params.classesLower...params.classesUpper, using: &rng)
            let rho      = Double.random(in: params.rhoLower...params.rhoUpper, using: &rng)
            let networkSeed = rng.next()
            let simulationSeed = rng.next() & UInt64(Int32.max)
            caseMeta.append(CaseMeta(
                idx: caseIdx, d: stations, K: classes, rho: rho,
                networkSeed: networkSeed, simulationSeed: simulationSeed
            ))

            let net = await MainActor.run {
                RandomNetworkGenerator.generate(.init(
                    stations: stations, classes: classes,
                    infiniteBuffers: infinite,
                    targetRho: rho, topology: params.topology,
                    seed: networkSeed))
            }

            await MainActor.run { [r] in
                let stem = r.workDir.appendingPathComponent("case_\(caseIdx)").path
                if infinite {
                    if case .success(let s) = QNAExporter.export(nodes: net.nodes, links: net.links) {
                        try? s.write(toFile: stem + ".qna", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = BNASRBMExporter.exportForSpectral(
                        nodes: net.nodes, links: net.links, degree: r.smDegree) {
                        try? s.write(toFile: stem + ".smin", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = BNANetworkExporter.export(nodes: net.nodes, links: net.links) {
                        try? s.write(toFile: stem + ".sim", atomically: true, encoding: .utf8)
                    }
                } else {
                    // Finite: Spectral (.smin), FE (.fmin), LP (.lpin), Sim (.sim).
                    // FE mesh is auto-capped by station count to keep the
                    // direct-sparse FEM tractable on randomly-sized cases —
                    // matches runComparison()'s fmMeshCap policy.
                    let d = stations
                    let meshCap: Int = (d < 4) ? 20 : (d == 4 ? 8 : (d == 5 ? 6 : 4))
                    let mesh = min(r.femMeshSize, meshCap)
                    if case .success(let s) = SRBMExporter.exportForSpectral(
                        nodes: net.nodes, links: net.links,
                        infiniteBuffers: false, degree: r.smDegree,
                        lossModeCorrection: r.lossCorrect,
                        basModeCorrection: r.basCorrect) {
                        try? s.write(toFile: stem + ".smin", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = SRBMExporter.exportForFiniteElement(
                        nodes: net.nodes, links: net.links,
                        infiniteBuffers: false, meshSize: mesh,
                        lossModeCorrection: r.lossCorrect,
                        basModeCorrection: r.basCorrect) {
                        try? s.write(toFile: stem + ".fmin", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = SRBMExporter.exportForFiniteLP(
                        nodes: net.nodes, links: net.links,
                        gridN: r.flpGridN, basisM: r.flpBasisM,
                        gridType: r.flpGridType,
                        solver: r.flpSolverName,
                        outputPrefix: stem + "_lp",
                        basisNormalize: r.flpBasisNormalize,
                        lossModeCorrection: r.lossCorrect,
                        basModeCorrection: r.basCorrect) {
                        try? s.write(toFile: stem + ".lpin", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = NetworkExporter.export(
                        nodes: net.nodes, links: net.links) {
                        try? s.write(toFile: stem + ".sim", atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        // ── Build the shell script ──
        let varName = infinite ? "Q" : "X"
        let referenceKey = "Sim"
        let algoOrder = infinite
            ? ["Spectral", "QNA", "RQNA", "SBD", "Sim"]
            : ["Spectral", "FE", "LP", "Sim"]
        let topoLabel: String = {
            switch params.topology {
            case .feedForward:       return "feed-forward"
            case .jacksonFeedback:   return "Jackson + feedback"
            case .generalPMatrix:    return "general P-matrix"
            case .reentrantFeedback: return "re-entrant"
            }
        }()

        var script = ""
        // Header — printed before any binary runs.
        script += "printf '══════════════════════════════════════════════════════════════════\\n'\n"
        script += "printf '\(infinite ? "Infinite" : "Finite") Test Set — \(params.numTestCases) cases\\n'\n"
        script += "printf '  Stations:  \(params.stationsLower)…\(params.stationsUpper)\\n'\n"
        script += "printf '  Classes:   \(params.classesLower)…\(params.classesUpper)\\n'\n"
        script += "printf '  ρ range:   %.2f…%.2f\\n' \(params.rhoLower) \(params.rhoUpper)\n"
        script += "printf '  Topology:  \(topoLabel)\\n'\n"
        script += "printf '  Base seed: \(baseSeed)\\n'\n"
        script += "printf '  Reference: \(referenceKey)\\n'\n"
        script += "printf '──────────────────────────────────────────────────────────────────\\n'\n"

        // Per-case: build the binary chain as one composite command, then
        // wrap it in a spinner that ticks while the binaries run and
        // finishes with the per-case elapsed time.
        for meta in caseMeta {
            let i = meta.idx
            let stem = "\(r.workDir.path)/case_\(i)"
            let outStem = "\(r.workDir.path)/out_\(i)"

            var caseCmds: [String] = []
            if infinite {
                if let bin = r.bins.bnetSm {
                    caseCmds.append("\"\(bin.path)\" -c \"\(stem).smin\" > \"\(outStem)_Spectral.txt\" 2>/dev/null")
                }
                if let bin = r.bins.bnaQna {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).qna\" -c > \"\(outStem)_QNA.txt\" 2>/dev/null")
                }
                if let bin = r.bins.bnaRqna {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).qna\" -c > \"\(outStem)_RQNA.txt\" 2>/dev/null")
                }
                if let bin = r.bins.bnaSbd {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).qna\" -c > \"\(outStem)_SBD.txt\" 2>/dev/null")
                }
                if let bin = r.bins.jacksonSim {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).sim\" -c -n \(r.simReps) -w \(r.simWarm) -r \(r.simTime) -s \(meta.simulationSeed) > \"\(outStem)_Sim.txt\" 2>/dev/null")
                }
            } else {
                // Finite: Spectral / FE / LP / Sim. All four emit
                // `E[X_k] = value` lines that the awk aggregator below
                // reads — Spectral natively, FE / LP via -c, Sim via -G.
                if let bin = r.bins.fSrbm {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).smin\" > \"\(outStem)_Spectral.txt\" 2>/dev/null")
                }
                if let bin = r.bins.fFm {
                    caseCmds.append("\"\(bin.path)\" \"\(stem).fmin\" -c > \"\(outStem)_FE.txt\" 2>/dev/null")
                }
                if let bin = r.bins.fLp {
                    caseCmds.append("\"\(bin.path)\" --input \"\(stem).lpin\" --solver \(r.flpSolverName) -c > \"\(outStem)_LP.txt\" 2>/dev/null")
                }
                if let bin = r.bins.fSim {
                    // -G = grid-format output (one `E[X_k] = mean (stderr)`
                    // line per station). Blocking regime tracks the user's
                    // simBlocking setting — same dialog the Run Comparison
                    // popup writes — so when "Loss" is chosen the test set
                    // also runs the SRBM exporters with the loss-mode
                    // correction (set above into r.lossCorrect).
                    caseCmds.append("\"\(bin.path)\" -G -f \"\(stem).sim\" -n \(r.simReps) -w \(r.simWarm) -T \(r.simTime) -s \(meta.simulationSeed)\(r.simBlockingFlag) > \"\(outStem)_Sim.txt\" 2>/dev/null")
                }
            }

            // The per-case prefix is fixed-width so the spinner / done
            // marker land at the same column on every case. ρ uses
            // %.3f; pad to 6 chars so the values align even at ρ=1.000.
            let prefixFmt = "  [%d/\(params.numTestCases)] d=%d K=%d ρ=%.3f"
            let prefixArgs = "\(i + 1) \(meta.d) \(meta.K) \(meta.rho)"
            // Compose the whole per-case command (binary chain joined
            // with `;` so failures don't abort the loop). Empty list
            // (no binaries available) still gets a spinner that
            // immediately finishes — keeps the output table aligned.
            let chain = caseCmds.isEmpty ? "true" : caseCmds.joined(separator: " ; ")
            script += testSetCaseSpinner(prefixFmt: prefixFmt,
                                         prefixArgs: prefixArgs,
                                         command: chain)
        }

        // Inline awk aggregator: reads every out_<i>_<algo>.txt, parses
        // E[<var>_k] = value lines, computes per-case mean abs % error vs
        // the reference algorithm, then aggregates per algo (mean, P50,
        // P90, max, N, total time-not-tracked-here).
        script += testSetAggregatorAwk(
            workDir: r.workDir.path,
            varName: varName,
            algoOrder: algoOrder,
            referenceKey: referenceKey)

        // Cleanup. fBNAlp writes <prefix>_marginal_*.csv and
        // <prefix>_distribution.csv into outputPrefix; those land inside
        // workDir already, so a single rm -rf clears everything.
        script += "rm -rf \"\(r.workDir.path)\"\n"

        await MainActor.run {
            if !self.runScript(
                script,
                label: "testset",
                parameters: [
                    "capacity": infinite ? "infinite" : "finite",
                    "cases": params.numTestCases.description,
                    "station range": "\(params.stationsLower)...\(params.stationsUpper)",
                    "class range": "\(params.classesLower)...\(params.classesUpper)",
                    "rho range": "\(params.rhoLower)...\(params.rhoUpper)",
                    "topology": topoLabel,
                ],
                seed: baseSeed,
                replicationSeeds: caseMeta.map(\.simulationSeed)
            ) {
                try? FileManager.default.removeItem(at: r.workDir)
            }
            self.testSetRunning = false
        }
    }

    /// Per-case wrapper: prints the case prefix, runs `command` in the
    /// background, drives a spinner (`|/-\`) on the same line until the
    /// command finishes, then overwrites the spinner with `done` and
    /// the case's wall-clock elapsed time.
    ///
    /// `prefixFmt` is a printf format string ending in the static part
    /// of the line (no trailing newline). `prefixArgs` is the
    /// space-separated argument list shell-printf will splice in.
    nonisolated private func testSetCaseSpinner(
        prefixFmt: String, prefixArgs: String, command: String
    ) -> String {
        // The prefix shows up three times in the script: on the initial
        // print, on each spinner repaint, and on the final `done` line.
        // Stage it once into a shell variable so we don't re-evaluate
        // %d / %f formatting per spinner tick (and so the shell-string
        // escaping stays self-contained).
        return """
        _pfx=$(printf '\(prefixFmt)' \(prefixArgs))
        printf '%s [ ]' "$_pfx"
        _t0=$(perl -MTime::HiRes=time -e 'print time')
        { \(command) ; } &
        _pid=$!
        ( _i=0 ; _ch='|/-\\\\' ; \
        while kill -0 $_pid 2>/dev/null ; do \
        sleep 0.15 ; \
        _i=$(( (_i + 1) % 4 )) ; \
        _c=$(printf '%s' "$_ch" | cut -c$((_i + 1))) ; \
        printf '\\r%s [%s]' "$_pfx" "$_c" ; \
        done ) &
        _poll=$!
        wait $_pid
        kill $_poll 2>/dev/null ; wait $_poll 2>/dev/null
        _el=$(perl -MTime::HiRes=time -e 'printf("%.2f", time - '"$_t0"')')
        printf '\\r%s done in %ss\\n' "$_pfx" "$_el"

        """
    }

    /// Builds the awk aggregator that runs after all binaries have
    /// finished. Operates on the per-(case, algo) `.txt` files in
    /// `workDir`. Every algorithm's row is: case-mean-abs-%err averaged
    /// across cases (mean), 50th and 90th percentiles, max, count.
    nonisolated private func testSetAggregatorAwk(
        workDir: String, varName: String,
        algoOrder: [String], referenceKey: String
    ) -> String {
        // Pass algo list and reference name to awk via -v.
        let algoCSV = algoOrder.joined(separator: ",")
        // POSIX-portable awk; no gawk-only features.
        var awk = ""
        awk += "awk -v VAR=\"\(varName)\" -v ALGOS=\"\(algoCSV)\" -v REF=\"\(referenceKey)\" '\n"
        awk += "BEGIN {\n"
        awk += "  n_algos = split(ALGOS, algos, \",\")\n"
        awk += "}\n"
        awk += "FNR == 1 {\n"
        awk += "  # Filename pattern: <workDir>/out_<idx>_<algo>.txt\n"
        awk += "  nm = FILENAME\n"
        awk += "  sub(/.*\\/out_/, \"\", nm)\n"
        awk += "  sub(/\\.txt$/, \"\", nm)\n"
        awk += "  split(nm, parts, \"_\")\n"
        awk += "  cur_case = parts[1] + 0\n"
        awk += "  cur_algo = parts[2]\n"
        awk += "  seen_case[cur_case] = 1\n"
        awk += "}\n"
        awk += "{\n"
        awk += "  # Match \"E[<VAR>_k] = value\". $1 = \"E[<VAR>_k]\", $3 = value.\n"
        awk += "  if ($1 ~ \"^E\\\\[\" VAR \"_[0-9]+\\\\]$\" && $2 == \"=\") {\n"
        awk += "    s = $1; sub(\"^E\\\\[\" VAR \"_\", \"\", s); sub(\"\\\\]$\", \"\", s)\n"
        awk += "    k = s + 0\n"
        awk += "    eq[cur_case, cur_algo, k] = $3 + 0\n"
        awk += "    have_k[cur_case, cur_algo, k] = 1\n"
        awk += "    if (k > nstn[cur_case]) nstn[cur_case] = k\n"
        awk += "  }\n"
        awk += "}\n"
        awk += "END {\n"
        awk += "  # Per (algo): collect per-case mean abs % error vs REF.\n"
        awk += "  # Also collect the ensemble (\"Average of Algorithms\") case\n"
        awk += "  # error by averaging every non-REF algorithm at each station\n"
        awk += "  # for that case, then computing the same |Δ|/|ref|·100% summary.\n"
        awk += "  # Track the single largest per-station error per algorithm\n"
        awk += "  # across the entire sweep (\"worst station\" column).\n"
        awk += "  AVG_IDX = n_algos + 1   # synthetic algo slot for the ensemble\n"
        awk += "  for (t in seen_case) {\n"
        awk += "    if (!((t SUBSEP REF SUBSEP 1) in have_k)) continue\n"
        awk += "    n = nstn[t]\n"
        awk += "    if (n < 1) continue\n"
        awk += "    for (a = 1; a <= n_algos; a++) {\n"
        awk += "      algo = algos[a]\n"
        awk += "      if (algo == REF) continue\n"
        awk += "      sum = 0; cnt = 0\n"
        awk += "      for (k = 1; k <= n; k++) {\n"
        awk += "        if (have_k[t, REF, k] && have_k[t, algo, k]) {\n"
        awk += "          rv = eq[t, REF, k]\n"
        awk += "          av = eq[t, algo, k]\n"
        awk += "          if (rv > 1e-9 || rv < -1e-9) {\n"
        awk += "            d = av - rv; if (d < 0) d = -d\n"
        awk += "            pct = d / (rv > 0 ? rv : -rv) * 100\n"
        awk += "            sum += pct\n"
        awk += "            cnt++\n"
        awk += "            if (pct > worst_station[a]) worst_station[a] = pct\n"
        awk += "          }\n"
        awk += "        }\n"
        awk += "      }\n"
        awk += "      if (cnt > 0) {\n"
        awk += "        ce = sum / cnt\n"
        awk += "        case_err[a, ++case_count[a]] = ce\n"
        awk += "      }\n"
        awk += "    }\n"
        awk += "    # Ensemble row: per-station mean across all non-REF algos.\n"
        awk += "    sum_avg = 0; cnt_avg = 0\n"
        awk += "    for (k = 1; k <= n; k++) {\n"
        awk += "      if (!have_k[t, REF, k]) continue\n"
        awk += "      rv = eq[t, REF, k]\n"
        awk += "      if (!(rv > 1e-9 || rv < -1e-9)) continue\n"
        awk += "      ssum = 0; scnt = 0\n"
        awk += "      for (a = 1; a <= n_algos; a++) {\n"
        awk += "        algo = algos[a]\n"
        awk += "        if (algo == REF) continue\n"
        awk += "        if (have_k[t, algo, k]) { ssum += eq[t, algo, k]; scnt++ }\n"
        awk += "      }\n"
        awk += "      if (scnt > 0) {\n"
        awk += "        avg_v = ssum / scnt\n"
        awk += "        d = avg_v - rv; if (d < 0) d = -d\n"
        awk += "        pct = d / (rv > 0 ? rv : -rv) * 100\n"
        awk += "        sum_avg += pct\n"
        awk += "        cnt_avg++\n"
        awk += "        if (pct > worst_station[AVG_IDX]) worst_station[AVG_IDX] = pct\n"
        awk += "      }\n"
        awk += "    }\n"
        awk += "    if (cnt_avg > 0) {\n"
        awk += "      ce = sum_avg / cnt_avg\n"
        awk += "      case_err[AVG_IDX, ++case_count[AVG_IDX]] = ce\n"
        awk += "    }\n"
        awk += "  }\n"
        awk += "  # Header. First column widened to fit \"Average of Algorithms\".\n"
        awk += "  printf \"\\n\"\n"
        awk += "  printf \"%-22s  %10s  %8s  %8s  %8s  %12s  %5s\\n\", \"Algorithm\", \"Mean %err\", \"P50\", \"P90\", \"Max\", \"Worst station\", \"N\"\n"
        awk += "  printf \"──────────────────────────────────────────────────────────────────────────────────────────\\n\"\n"
        awk += "  # Helper: print one row from a case_err slot, computing the\n"
        awk += "  # quantile summary and a label that may include \" (ref)\".\n"
        awk += "  # Implemented inline (no awk functions needed).\n"
        awk += "  for (a = 1; a <= n_algos; a++) {\n"
        awk += "    algo = algos[a]\n"
        awk += "    if (algo == REF) continue\n"
        awk += "    cn = case_count[a] + 0\n"
        awk += "    if (cn == 0) {\n"
        awk += "      printf \"%-22s  %10s  %8s  %8s  %8s  %12s  %5d\\n\", algo, \"—\", \"—\", \"—\", \"—\", \"—\", 0\n"
        awk += "      continue\n"
        awk += "    }\n"
        awk += "    # Sort case_err[a,1..cn] ascending (insertion sort; small N).\n"
        awk += "    for (i = 1; i <= cn; i++) sorted[i] = case_err[a, i]\n"
        awk += "    for (i = 2; i <= cn; i++) {\n"
        awk += "      v = sorted[i]; j = i - 1\n"
        awk += "      while (j >= 1 && sorted[j] > v) { sorted[j+1] = sorted[j]; j-- }\n"
        awk += "      sorted[j+1] = v\n"
        awk += "    }\n"
        awk += "    mean = 0; for (i = 1; i <= cn; i++) mean += sorted[i]; mean /= cn\n"
        awk += "    pi50 = int((cn - 1) * 0.50 + 1.5); if (pi50 > cn) pi50 = cn\n"
        awk += "    pi90 = int((cn - 1) * 0.90 + 1.5); if (pi90 > cn) pi90 = cn\n"
        awk += "    p50  = sorted[pi50]; p90 = sorted[pi90]; mx = sorted[cn]\n"
        awk += "    ws = worst_station[a] + 0\n"
        awk += "    printf \"%-22s  %9.2f%%  %7.2f%%  %7.2f%%  %7.2f%%  %11.2f%%  %5d\\n\", algo, mean, p50, p90, mx, ws, cn\n"
        awk += "    delete sorted\n"
        awk += "  }\n"
        awk += "  # Ensemble row.\n"
        awk += "  cn = case_count[AVG_IDX] + 0\n"
        awk += "  if (cn > 0) {\n"
        awk += "    for (i = 1; i <= cn; i++) sorted[i] = case_err[AVG_IDX, i]\n"
        awk += "    for (i = 2; i <= cn; i++) {\n"
        awk += "      v = sorted[i]; j = i - 1\n"
        awk += "      while (j >= 1 && sorted[j] > v) { sorted[j+1] = sorted[j]; j-- }\n"
        awk += "      sorted[j+1] = v\n"
        awk += "    }\n"
        awk += "    mean = 0; for (i = 1; i <= cn; i++) mean += sorted[i]; mean /= cn\n"
        awk += "    pi50 = int((cn - 1) * 0.50 + 1.5); if (pi50 > cn) pi50 = cn\n"
        awk += "    pi90 = int((cn - 1) * 0.90 + 1.5); if (pi90 > cn) pi90 = cn\n"
        awk += "    p50  = sorted[pi50]; p90 = sorted[pi90]; mx = sorted[cn]\n"
        awk += "    ws = worst_station[AVG_IDX] + 0\n"
        awk += "    printf \"%-22s  %9.2f%%  %7.2f%%  %7.2f%%  %7.2f%%  %11.2f%%  %5d\\n\", \"Average of Algorithms\", mean, p50, p90, mx, ws, cn\n"
        awk += "    delete sorted\n"
        awk += "  } else {\n"
        awk += "    printf \"%-22s  %10s  %8s  %8s  %8s  %12s  %5d\\n\", \"Average of Algorithms\", \"—\", \"—\", \"—\", \"—\", \"—\", 0\n"
        awk += "  }\n"
        awk += "  # Reference line for completeness.\n"
        awk += "  ref_n = 0; for (t in seen_case) if ((t SUBSEP REF SUBSEP 1) in have_k) ref_n++\n"
        awk += "  printf \"%-22s  %10s  %8s  %8s  %8s  %12s  %5d\\n\", REF \" (ref)\", \"—\", \"—\", \"—\", \"—\", \"—\", ref_n\n"
        awk += "  printf \"\\n\"\n"
        awk += "  printf \"All numeric columns are percent errors.  Per case, err = mean over\\n\"\n"
        awk += "  printf \"stations of |algo_k - ref_k| / |ref_k| * 100%%, with ref = %s.\\n\", REF\n"
        awk += "  printf \"Mean = average across cases; P50 / P90 = 50th / 90th percentile;\\n\"\n"
        awk += "  printf \"Max = single worst case; N = cases that contributed to the row.\\n\"\n"
        awk += "  printf \"Worst station = the single largest |algo_k - ref_k|/|ref_k|*100 seen at\\n\"\n"
        awk += "  printf \"any station in any case (highlights where this algorithm struggles).\\n\"\n"
        awk += "  printf \"Average of Algorithms: per case and per station, the unweighted mean\\n\"\n"
        awk += "  printf \"of every non-reference algorithm cell, then the same error summary.\\n\"\n"
        awk += "  printf \"══════════════════════════════════════════════════════════════════════════════════════════\\n\"\n"
        awk += "}' \"\(workDir)\"/out_*.txt\n"
        return awk
    }

    // MARK: - Spectral convergence sweep

    /// Per case: generate one random network (seed = case index), then
    /// sweep that single network across every ρ in
    /// `params.rhoValues`. At each ρ we re-invoke the random generator
    /// with the same seed but the new targetRho — the generator's RNG
    /// draws for routing P / service distributions stay identical, only
    /// the external arrival rates rescale. Final aggregator reports per-ρ
    /// mean Spectral error (and QNA error as a flat-line baseline)
    /// averaged across all cases.
    nonisolated private func executeSpectralConvergence(
        params: SpectralConvergenceParameters
    ) async {
        await MainActor.run { self.testSetRunning = true }

        struct Resolved {
            let bins: TestSetBinaries
            let simReps: Int, simWarm: Int, simTime: Int
            let smDegree: Int
            let workDir: URL
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BNET_spc_\(pid)_\(stamp)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let r = await MainActor.run { () -> Resolved in
            Resolved(
                bins: TestSetBinaries(
                    bnetSm:     findBinary(name: "bnet",        subdirectory: "BNAsm"),
                    bnaQna:     findBinary(name: "bna_qna",     subdirectory: "BNAqna"),
                    bnaRqna:    nil, bnaSbd: nil,
                    jacksonSim: findBinary(name: "jackson_sim", subdirectory: "BNAsim"),
                    fSrbm: nil, fFm: nil, fLp: nil, fSim: nil
                ),
                simReps: appSettings.simReplications,
                simWarm: appSettings.simWarmup,
                simTime: appSettings.simTime,
                smDegree: appSettings.smDegree,
                workDir: workDir
            )
        }

        // ── Pre-generate networks for every (case, ρ) pair ──
        // Same seed across the ρ sweep keeps topology / service draws
        // identical; only λ_ext scales. Use SystemRandomNumberGenerator
        // once to draw stations / classes / case-seed per case, then
        // hand the seed to the generator at every ρ.
        struct CaseMeta {
            let idx: Int
            let d: Int
            let K: Int
            let seed: UInt64
            let simulationSeed: UInt64
        }
        var caseMeta: [CaseMeta] = []
        let baseSeed = params.seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        var rngOuter = SeededRNG(seed: baseSeed)
        for caseIdx in 0..<params.numTestCases {
            let stations = Int.random(in: params.stationsLower...params.stationsUpper, using: &rngOuter)
            let classes  = Int.random(in: params.classesLower...params.classesUpper, using: &rngOuter)
            let seed     = UInt64.random(in: UInt64.min...UInt64.max, using: &rngOuter)
            let simulationSeed = rngOuter.next() & UInt64(Int32.max)
            caseMeta.append(CaseMeta(
                idx: caseIdx, d: stations, K: classes,
                seed: seed, simulationSeed: simulationSeed
            ))
        }
        let rhoGrid = params.rhoValues

        for meta in caseMeta {
            for (rhoIdx, rho) in rhoGrid.enumerated() {
                await MainActor.run { [r] in
                    let stem = r.workDir.appendingPathComponent("case_\(meta.idx)_r\(rhoIdx)").path
                    let net = RandomNetworkGenerator.generate(.init(
                        stations: meta.d, classes: meta.K,
                        infiniteBuffers: true,
                        targetRho: rho, topology: params.topology,
                        seed: meta.seed))
                    if case .success(let s) = QNAExporter.export(nodes: net.nodes, links: net.links) {
                        try? s.write(toFile: stem + ".qna", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = BNASRBMExporter.exportForSpectral(
                        nodes: net.nodes, links: net.links, degree: r.smDegree) {
                        try? s.write(toFile: stem + ".smin", atomically: true, encoding: .utf8)
                    }
                    if case .success(let s) = BNANetworkExporter.export(nodes: net.nodes, links: net.links) {
                        try? s.write(toFile: stem + ".sim", atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        // ── Build the shell script ──
        let topoLabel: String = {
            switch params.topology {
            case .feedForward:       return "feed-forward"
            case .jacksonFeedback:   return "Jackson + feedback"
            case .generalPMatrix:    return "general P-matrix"
            case .reentrantFeedback: return "re-entrant"
            }
        }()

        var script = ""
        script += "printf '══════════════════════════════════════════════════════════════════\\n'\n"
        script += "printf 'Infinite Spectral Convergence — \(params.numTestCases) cases × \(rhoGrid.count) ρ values\\n'\n"
        script += "printf '  Stations:  \(params.stationsLower)…\(params.stationsUpper)\\n'\n"
        script += "printf '  Classes:   \(params.classesLower)…\(params.classesUpper)\\n'\n"
        script += "printf '  ρ sweep:   %.3f → %.3f step %.3f  (\(rhoGrid.count) values)\\n' \(params.rhoStart) \(params.rhoEnd) \(params.rhoStep)\n"
        script += "printf '  Topology:  \(topoLabel)\\n'\n"
        script += "printf '  Base seed: \(baseSeed)\\n'\n"
        script += "printf '  Reference: Sim   |   Baseline: QNA\\n'\n"
        script += "printf '──────────────────────────────────────────────────────────────────\\n'\n"

        // Per-case header + one progress line per ρ value. Each ρ gets
        // its own spinner that overwrites itself with `done in X.XXs`,
        // so the user sees concrete progress every few seconds rather
        // than one spinner that ticks for many minutes.
        for meta in caseMeta {
            script += "printf '  [%d/\(params.numTestCases)] d=%d K=%d  (\(rhoGrid.count) ρ values)\\n' \(meta.idx + 1) \(meta.d) \(meta.K)\n"
            for (rhoIdx, rho) in rhoGrid.enumerated() {
                let stem = "\(r.workDir.path)/case_\(meta.idx)_r\(rhoIdx)"
                let outStem = "\(r.workDir.path)/out_\(meta.idx)_r\(rhoIdx)"
                var rhoCmds: [String] = []
                if let bin = r.bins.bnetSm {
                    rhoCmds.append("\"\(bin.path)\" -c \"\(stem).smin\" > \"\(outStem)_Spectral.txt\" 2>/dev/null")
                }
                if let bin = r.bins.bnaQna {
                    rhoCmds.append("\"\(bin.path)\" \"\(stem).qna\" -c > \"\(outStem)_QNA.txt\" 2>/dev/null")
                }
                if let bin = r.bins.jacksonSim {
                    rhoCmds.append("\"\(bin.path)\" \"\(stem).sim\" -c -n \(r.simReps) -w \(r.simWarm) -r \(r.simTime) -s \(meta.simulationSeed) > \"\(outStem)_Sim.txt\" 2>/dev/null")
                }
                let prefixFmt = "      ρ=%.3f"
                let prefixArgs = "\(rho)"
                let chain = rhoCmds.isEmpty ? "true" : rhoCmds.joined(separator: " ; ")
                script += testSetCaseSpinner(prefixFmt: prefixFmt,
                                             prefixArgs: prefixArgs,
                                             command: chain)
            }
        }

        // Aggregator: groups outputs by ρ value, reports per-ρ mean abs %
        // error of Spectral and QNA vs Sim across cases.
        script += spectralConvergenceAggregatorAwk(
            workDir: r.workDir.path,
            rhoValues: rhoGrid)

        script += "rm -rf \"\(r.workDir.path)\"\n"

        await MainActor.run {
            if !self.runScript(
                script,
                label: "spc",
                parameters: [
                    "cases": params.numTestCases.description,
                    "station range": "\(params.stationsLower)...\(params.stationsUpper)",
                    "class range": "\(params.classesLower)...\(params.classesUpper)",
                    "rho sweep": "\(params.rhoStart)...\(params.rhoEnd) by \(params.rhoStep)",
                    "topology": topoLabel,
                    "spectral degree": r.smDegree.description,
                ],
                seed: baseSeed,
                replicationSeeds: caseMeta.map(\.simulationSeed)
            ) {
                try? FileManager.default.removeItem(at: r.workDir)
            }
            self.testSetRunning = false
        }
    }

    /// Awk aggregator for the spectral-convergence sweep. Output files are
    /// named `out_<caseIdx>_r<rhoIdx>_{Spectral,QNA,Sim}.txt`. For each ρ
    /// bucket we compute mean abs % error of Spectral and QNA vs Sim
    /// across the cases that contributed.
    nonisolated private func spectralConvergenceAggregatorAwk(
        workDir: String, rhoValues: [Double]
    ) -> String {
        // Emit the ρ list as a comma-separated -v var so awk can label
        // rows. Use %.6f for round-trip-stability (the bucket key in awk
        // is just the rhoIdx anyway — labels come from the Swift list).
        let rhoCSV = rhoValues.map { String(format: "%.6f", $0) }.joined(separator: ",")
        var awk = ""
        awk += "awk -v RHO_LIST=\"\(rhoCSV)\" '\n"
        awk += "BEGIN { n_rho = split(RHO_LIST, rho_list, \",\") }\n"
        awk += "FNR == 1 {\n"
        awk += "  # Filename: <workDir>/out_<caseIdx>_r<rhoIdx>_<algo>.txt\n"
        awk += "  nm = FILENAME\n"
        awk += "  sub(/.*\\/out_/, \"\", nm)\n"
        awk += "  sub(/\\.txt$/, \"\", nm)\n"
        awk += "  # Split on underscore: <case>_r<rhoIdx>_<algo>\n"
        awk += "  split(nm, parts, \"_\")\n"
        awk += "  cur_case = parts[1] + 0\n"
        awk += "  rtok = parts[2]; sub(/^r/, \"\", rtok); cur_rho = rtok + 0\n"
        awk += "  cur_algo = parts[3]\n"
        awk += "}\n"
        awk += "{\n"
        awk += "  if ($1 ~ /^E\\[Q_[0-9]+\\]$/ && $2 == \"=\") {\n"
        awk += "    s = $1; sub(/^E\\[Q_/, \"\", s); sub(/\\]$/, \"\", s)\n"
        awk += "    k = s + 0\n"
        awk += "    val[cur_case, cur_rho, cur_algo, k] = $3 + 0\n"
        awk += "    have[cur_case, cur_rho, cur_algo, k] = 1\n"
        awk += "    if (k > nstn[cur_case, cur_rho]) nstn[cur_case, cur_rho] = k\n"
        awk += "    cases[cur_case] = 1\n"
        awk += "  }\n"
        awk += "}\n"
        awk += "END {\n"
        awk += "  # For each (case, rho), compute per-algo mean-abs-%err vs Sim.\n"
        awk += "  for (c in cases) {\n"
        awk += "    for (ri = 0; ri < n_rho; ri++) {\n"
        awk += "      n = nstn[c, ri]\n"
        awk += "      if (n < 1) continue\n"
        awk += "      if (!((c SUBSEP ri SUBSEP \"Sim\" SUBSEP 1) in have)) continue\n"
        awk += "      for (algo_i = 1; algo_i <= 2; algo_i++) {\n"
        awk += "        algo = (algo_i == 1 ? \"Spectral\" : \"QNA\")\n"
        awk += "        sum = 0; cnt = 0\n"
        awk += "        for (k = 1; k <= n; k++) {\n"
        awk += "          if (have[c, ri, \"Sim\", k] && have[c, ri, algo, k]) {\n"
        awk += "            rv = val[c, ri, \"Sim\", k]\n"
        awk += "            av = val[c, ri, algo, k]\n"
        awk += "            if (rv > 1e-9 || rv < -1e-9) {\n"
        awk += "              d = av - rv; if (d < 0) d = -d\n"
        awk += "              sum += d / (rv > 0 ? rv : -rv) * 100\n"
        awk += "              cnt++\n"
        awk += "            }\n"
        awk += "          }\n"
        awk += "        }\n"
        awk += "        if (cnt > 0) {\n"
        awk += "          ce = sum / cnt\n"
        awk += "          err_sum[ri, algo] += ce\n"
        awk += "          err_n[ri, algo] += 1\n"
        awk += "          if (ce > err_max[ri, algo]) err_max[ri, algo] = ce\n"
        awk += "        }\n"
        awk += "      }\n"
        awk += "      # Average-of-Algorithms case-error: per-station mean of\n"
        awk += "      # Spectral and QNA, then |Δ|/|ref|·100% averaged over k.\n"
        awk += "      sum_avg = 0; cnt_avg = 0\n"
        awk += "      for (k = 1; k <= n; k++) {\n"
        awk += "        if (!have[c, ri, \"Sim\", k]) continue\n"
        awk += "        rv = val[c, ri, \"Sim\", k]\n"
        awk += "        if (!(rv > 1e-9 || rv < -1e-9)) continue\n"
        awk += "        ssum = 0; scnt = 0\n"
        awk += "        if (have[c, ri, \"Spectral\", k]) { ssum += val[c, ri, \"Spectral\", k]; scnt++ }\n"
        awk += "        if (have[c, ri, \"QNA\",      k]) { ssum += val[c, ri, \"QNA\",      k]; scnt++ }\n"
        awk += "        if (scnt > 0) {\n"
        awk += "          avg_v = ssum / scnt\n"
        awk += "          d = avg_v - rv; if (d < 0) d = -d\n"
        awk += "          sum_avg += d / (rv > 0 ? rv : -rv) * 100\n"
        awk += "          cnt_avg++\n"
        awk += "        }\n"
        awk += "      }\n"
        awk += "      if (cnt_avg > 0) {\n"
        awk += "        ce = sum_avg / cnt_avg\n"
        awk += "        err_sum[ri, \"Avg\"] += ce\n"
        awk += "        err_n[ri, \"Avg\"]   += 1\n"
        awk += "      }\n"
        awk += "    }\n"
        awk += "  }\n"
        awk += "  printf \"\\n\"\n"
        awk += "  printf \"%-7s  %14s  %12s  %12s  %14s  %5s\\n\", \"ρ\", \"Spectral mean\", \"Spectral max\", \"QNA mean\", \"Avg-algos mean\", \"N\"\n"
        awk += "  printf \"───────────────────────────────────────────────────────────────────────────────────\\n\"\n"
        awk += "  for (ri = 0; ri < n_rho; ri++) {\n"
        awk += "    sn = err_n[ri, \"Spectral\"] + 0\n"
        awk += "    qn = err_n[ri, \"QNA\"] + 0\n"
        awk += "    an = err_n[ri, \"Avg\"] + 0\n"
        awk += "    if (sn == 0 && qn == 0 && an == 0) {\n"
        awk += "      printf \"%-7.3f  %14s  %12s  %12s  %14s  %5d\\n\", rho_list[ri+1], \"—\", \"—\", \"—\", \"—\", 0\n"
        awk += "      continue\n"
        awk += "    }\n"
        awk += "    sm = (sn > 0 ? err_sum[ri, \"Spectral\"] / sn : 0)\n"
        awk += "    smax = (sn > 0 ? err_max[ri, \"Spectral\"] : 0)\n"
        awk += "    qm = (qn > 0 ? err_sum[ri, \"QNA\"] / qn : 0)\n"
        awk += "    am = (an > 0 ? err_sum[ri, \"Avg\"] / an : 0)\n"
        awk += "    nmax = sn; if (qn > nmax) nmax = qn; if (an > nmax) nmax = an\n"
        awk += "    printf \"%-7.3f  %13.2f%%  %11.2f%%  %11.2f%%  %13.2f%%  %5d\\n\", rho_list[ri+1], sm, smax, qm, am, nmax\n"
        awk += "  }\n"
        awk += "  printf \"\\n\"\n"
        awk += "  printf \"Each row: per-case mean abs %% error of E[Q_k] vs Sim, averaged across\\n\"\n"
        awk += "  printf \"the cases that reached that rho.  Spectral converges toward the QNA\\n\"\n"
        awk += "  printf \"accuracy band as rho approaches 1 (heavy-traffic regime); QNA stays\\n\"\n"
        awk += "  printf \"flat near zero for the Markovian-style random networks generated here.\\n\"\n"
        awk += "  printf \"══════════════════════════════════════════════════════════════════\\n\"\n"
        awk += "}' \"\(workDir)\"/out_*.txt\n"
        return awk
    }
}

// Bundle of binary URLs the test-set runner needs. nil entries are
// silently skipped per case.
private struct TestSetBinaries {
    let bnetSm:    URL?
    let bnaQna:    URL?
    let bnaRqna:   URL?
    let bnaSbd:    URL?
    let jacksonSim:URL?
    let fSrbm:     URL?    // finite Spectral (srbm_solver)
    let fFm:       URL?    // finite FE (bna_fm_gauss / bna_fm_cbc)
    let fLp:       URL?    // finite LP (fBNAlp_solver)
    let fSim:      URL?    // finite simulation reference (fBNAsim)
}
