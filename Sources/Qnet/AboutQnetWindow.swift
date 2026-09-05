import SwiftUI
import AppKit

/// "About Qnet" — replaces macOS's default About panel via
/// CommandGroup(replacing: .appInfo). Shows the version, the build
/// identifier (version + MM.DD.YYYY.HHMM) and a human-readable build
/// date so a user looking at a running binary can pin down exactly
/// which build they're on.

/// Opening dimensions for the panel. The window's content size and the
/// SwiftUI view's outer frame use the SAME values, which prevents the
/// macOS 26 NSHostingView constraint recursion that caused crashes
/// on first display when the panel was free to negotiate its own size.
///
/// They are the view's *minimum* rather than its exact size: at an
/// Accessibility text size the version line, the build stamp, the
/// description, the acknowledgements link and the Close button need more
/// than 392 points of height, and the panel is deliberately not resizable
/// — so the content scrolls inside whatever height the panel gets rather
/// than running off the bottom with no way to reach it. The window is
/// still built with `resizable: false`; only the content gives.
private let aboutWindowSize = DS.Layout.Window.aboutPanel

struct AboutQnetView: View {
    let windowRef: WindowRef?

    /// Captured once when the view is constructed so the icon branch
    /// can't flip mid-layout (NSApp.applicationIconImage briefly returns
    /// nil in some launch states). When the binary is not running from a
    /// .app bundle (e.g. `swift run`) AppKit hands back the generic
    /// executable icon, so we fall back to an SF Symbol instead.
    private let appIcon: NSImage? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return NSApp.applicationIconImage
    }()

    @State private var showAcknowledgements = false

    private var buildDateLine: String? {
        guard let d = BuildStamp.dateText(AppVersion.buildTimestamp),
              let t = BuildStamp.timeText(AppVersion.buildTimestamp) else { return nil }
        return "Built \(d) at \(t)"
    }

    private var copyrightYear: String {
        if let d = BuildStamp.date(from: AppVersion.buildTimestamp) {
            return String(Calendar.current.component(.year, from: d))
        }
        return "2026"
    }

    var body: some View {
        ScrollView {
            panel
        }
        // Ideal == minimum, so the panel's preferred content size never
        // changes and the window is still the fixed size the constraint
        // workaround needs (see `aboutWindowSize`). At an Accessibility text
        // size the *content* overflows instead of the window growing, and
        // the ScrollView above makes the overflow reachable — which is the
        // whole fix. The Close button keeps its Return binding either way.
        .frame(minWidth: aboutWindowSize.width, idealWidth: aboutWindowSize.width,
               minHeight: aboutWindowSize.height, idealHeight: aboutWindowSize.height)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            iconView
                .frame(width: DS.Layout.aboutIconSize, height: DS.Layout.aboutIconSize)
                .padding(.bottom, DS.Spacing.l)

            Text("Qnet")
                .font(DS.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, DS.Spacing.s)

            VStack(spacing: DS.Spacing.xs) {
                Text("Version \(AppVersion.version) (\(AppVersion.fullVersion))")
                    .font(DS.Font.callout)
                    .monospacedDigit()
                    .textSelection(.enabled)
                if let buildDateLine {
                    Text(buildDateLine)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, DS.Spacing.l)

            Text("Draws open queueing networks and analyses them with spectral SRBM, finite-element, QNA and simulation solvers.")
                .multilineTextAlignment(.center)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Layout.aboutColumnWidth)
                .padding(.bottom, DS.Spacing.s)

            Text("© \(copyrightYear) Joseph Nemec")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)

            // Pushes the link row to the bottom at the opening size, and
            // collapses to nothing once the text needs the whole panel.
            Spacer(minLength: DS.Spacing.l)

            HStack(spacing: DS.Spacing.l) {
                Button("Release Notes") { ReleaseNotesWindow.show() }
                    .buttonStyle(.link)
                    .help("Open the Release Notes window")
                    .accessibilityLabel("Release Notes")
                Button("Acknowledgements") { showAcknowledgements.toggle() }
                    .buttonStyle(.link)
                    .help("Third-party libraries used by Qnet")
                    .accessibilityLabel("Acknowledgements")
                    .popover(isPresented: $showAcknowledgements, arrowEdge: .bottom) {
                        acknowledgements
                    }
                Spacer()
                Button("Close") { windowRef?.close() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close this window")
                    .accessibilityLabel("Close About window")
            }
        }
        .padding(DS.Spacing.xl)
        // Fills the panel's width so the centred column stays centred, and
        // takes at least its full height so the Spacer above still pushes
        // the link row to the bottom edge.
        .frame(maxWidth: .infinity, minHeight: aboutWindowSize.height)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .accessibilityLabel("Qnet application icon")
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.appIcon(for: DS.Layout.aboutIconSize), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DS.Color.dimmed(DS.Color.accent, DS.Opacity.arrowHead), DS.Color.accent],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: DS.Symbol.network)
                    .font(DS.Font.hero)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Qnet application icon")
        }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Acknowledgements")
                .font(DS.Font.headline)
            Text("Qnet builds on the following open-source software.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                acknowledgement("SwiftTerm", "Embedded terminal emulator (MIT)")
                acknowledgement("HiGHS", "Linear-programming backend (MIT)")
                acknowledgement("SuiteSparse", "CHOLMOD / UMFPACK sparse solvers (LGPL, BSD)")
                acknowledgement("libomp", "LLVM OpenMP runtime (Apache 2.0)")
            }
            .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.l)
        .frame(width: DS.Layout.aboutDetailWidth)
    }

    private func acknowledgement(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(name)
                .font(DS.Font.labelEmphasis)
                .frame(width: DS.Layout.aboutLabelWidth, alignment: .leading)
            Text(detail)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum AboutQnetWindow {
    private static var retained: NSWindow?

    /// Where the user last dragged the About panel.
    ///
    /// Deliberately NOT `AuxiliaryWindow.make(frameKey:)`: that installs
    /// `WindowFrameAutosave`, which restores the whole saved rect, and this
    /// panel's *size* is a lock, not a preference — `resizable: false` plus
    /// `sizingOptions = [.preferredContentSize]` is the workaround for the
    /// macOS 26 NSHostingView constraint recursion (WindowSupport.swift), and
    /// a remembered size would fight it the day `aboutWindowSize` changes.
    ///
    /// The ORIGIN is a different question, and the answer is the one the
    /// standard Mac About panel gives: a window a user has moved should come
    /// back where they left it, fixed size or not. So the origin is restored
    /// and the size is ignored. The key is the same `WindowFrame.<name>`
    /// namespace the other seven windows use, so the two spellings cannot
    /// drift apart.
    private static let frameKey = "QnetAboutWindow"

    /// Kept for the process lifetime alongside `retained` — the panel is
    /// built once and never released, so there is nothing to tear down.
    private static var frameObservers: [NSObjectProtocol] = []

    static func show() {
        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }
        let window = AuxiliaryWindow.make(
            id: "about",
            title: "About Qnet",
            contentSize: aboutWindowSize,
            resizable: false,
            transparentTitlebar: true,
            fullScreenAuxiliary: true
        ) { ref in
            AboutQnetView(windowRef: ref)
        }
        // After `make`, which has already centred it: move it back to where
        // the user left it, keeping the size `make` just set. Done before
        // `present` so the panel never appears centred and then jumps.
        if let saved = WindowFrameAutosave.savedFrame(named: frameKey) {
            window.setFrameOrigin(saved.origin)
        }
        observeFrame(of: window)
        retained = window
        AuxiliaryWindow.present(window)
    }

    /// Records the panel's position as it is dragged, and once more as the
    /// app quits (a drag that ends during termination would otherwise be
    /// lost). `didMove` is the only event worth watching: the window cannot
    /// be resized.
    private static func observeFrame(of window: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let save: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { saveFrame(of: window) }
        }
        frameObservers.append(nc.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: save))
        frameObservers.append(nc.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: save))
    }

    private static func saveFrame(of window: NSWindow) {
        let frame = window.frame
        // The same degenerate-frame guard the autosaver applies: a window
        // reports a near-zero frame while it is being torn down, and that is
        // not a position the user chose.
        guard frame.width > WindowFrameAutosave.degenerateFrameSide,
              frame.height > WindowFrameAutosave.degenerateFrameSide else { return }
        UserDefaults.standard.set(NSStringFromRect(frame),
                                  forKey: WindowFrameAutosave.defaultsKey(for: frameKey))
    }
}
