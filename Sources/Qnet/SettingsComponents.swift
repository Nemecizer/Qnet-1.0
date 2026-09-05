import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Settings window building blocks
// ─────────────────────────────────────────────────────────────────────────────
//
// Every pane in SettingsView is a grouped `Form` made of the rows below, so
// labels, field widths, units, validation captions and tooltips are
// identical across panes. All colours, fonts and spacings come from the
// `DS` design-system tokens, and every editing control IS a DS component:
//
//   SettingsNumberRow   → DSNumericField  (validate live, commit on blur,
//                          clamp into range, empty-means-auto, linear or
//                          multiplicative stepper, override switch)
//   SettingsRangeRow    → DSRangeFields   (min … max pair, lo ≤ hi check)
//   SettingsSliderRow   → DSLabelledSlider
//   SettingsToggleRow   → Toggle + DSRowLabel (`SettingsLabel`) + DSGlossarySlot
//   SettingsMenuRow     → DSMenuPicker    (short noun-phrase titles; the
//                          consequence of the chosen item is a
//                          selection-dependent caption under the label,
//                          never an em-dash essay inside the menu)
//   multi-line text     → DSTextArea
//   advisory rows       → InlineFieldMessage(_, severity: .warning)
//   SettingsReferenceButton → DSPopover(size: .wide)
//
// The Settings-prefixed names exist only so a pane reads as a list of
// settings; they add the Settings defaults (narrow field, `.form` layout)
// and nothing else. Nothing in this file draws a field, a caption or a
// popover of its own.
//
// Every row type takes `glossary:` and forwards it, so a jargon-only label
// ("Utilisation ρ", "Target RMSE (ε)", "Grid size (grid_n)") carries a
// clickable "?" — reachable by keyboard and spoken by VoiceOver — and not
// only a tooltip that a pointer has to find. The "?" owns the trailing
// column of every row (`DSGlossarySlot`, reserved whether or not the row
// has an entry), and every glossary string is a `DS.Glossary` entry —
// `SettingsGlossaryAudit` traps on a literal in debug builds, so the
// Settings window and the run dialogs can never explain one quantity two
// ways.
// ─────────────────────────────────────────────────────────────────────────────

extension Notification.Name {
    /// Posted by Edit ▸ Find… (QnetGUIApp) when the Settings window is key,
    /// so ⌘F focuses the settings search field instead of the node finder.
    static let bnetSettingsFocusSearch = Notification.Name("bnet.settings.focusSearch")
    /// Posted by Edit ▸ Find Next / Find Previous (⌘G / ⇧⌘G) while the
    /// Settings window is key; `userInfo["delta"]` is +1 or −1 and
    /// `SettingsView` steps its match cursor by it.
    static let bnetSettingsStepMatch = Notification.Name("bnet.settings.stepMatch")
}

/// The Settings window's live search state, one instance, so the menu bar
/// can enable Find Next / Find Previous from the match count without
/// reaching into the window (the same arrangement `HelpWindowModel.shared`
/// gives the Help window).
@MainActor
final class SettingsSearchModel: ObservableObject {
    static let shared = SettingsSearchModel()
    /// Matches of the current query across every pane; 0 when the query is
    /// empty or matched nothing.
    @Published private(set) var matchCount = 0
    /// The query itself, for the menu item's tooltip.
    @Published private(set) var query = ""

    private init() {}

    func update(query: String, matchCount: Int) {
        if self.query != query { self.query = query }
        if self.matchCount != matchCount { self.matchCount = matchCount }
    }
}

// MARK: - Search registry

/// One searchable control in the Settings window. `id` doubles as the
/// `ScrollViewReader` anchor of the row (see `settingsAnchor(_:)`), so a
/// match can be scrolled to and highlighted. By convention the id is the
/// `@AppStorage` key of the control (or a stable synthetic key for rows
/// without one). `keys` lists every `@AppStorage` key the row edits — the
/// id itself by default, several for range / override rows, none for rows
/// that only display something — and drives Reset to Defaults' change
/// detection.
struct SettingEntry: Identifiable, Hashable {
    let id: String
    let pane: SettingsView.Tab
    let section: String
    let title: String
    let keywords: [String]
    let keys: [String]

    init(_ id: String, _ pane: SettingsView.Tab, _ section: String, _ title: String, _ keywords: [String] = [], keys: [String]? = nil) {
        self.id = id
        self.pane = pane
        self.section = section
        self.title = title
        self.keywords = keywords
        self.keys = keys ?? [id]
    }

    /// Case- and diacritic-insensitive match against title, section,
    /// pane title and keywords. Every whitespace-separated term of the
    /// query must match somewhere.
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = ([title, section, pane.title] + keywords).joined(separator: " ")
        return terms.allSatisfy { term in
            haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// A request to scroll to (and briefly highlight) one setting row. A new
/// `token` re-fires the jump even when the id is unchanged.
struct SettingsJump: Equatable {
    let id: String
    let token: Int
}

/// Rows to flash after a Reset to Defaults: only the anchors whose stored
/// value actually changed. A new `token` re-fires even for the same set.
struct SettingsFlash: Equatable {
    let ids: Set<String>
    let token: Int
}

// MARK: - Environment plumbing

private struct SettingsJumpKey: EnvironmentKey {
    static let defaultValue: SettingsJump? = nil
}

private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: SettingsFlash? = nil
}

private struct SettingsQueryKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// Pending search jump, consumed by `SettingsPane` (scroll) and by
    /// `settingsAnchor(_:)` (highlight).
    var settingsJump: SettingsJump? {
        get { self[SettingsJumpKey.self] }
        set { self[SettingsJumpKey.self] = newValue }
    }

    /// Set by a pane's Reset to Defaults; anchored rows whose id is in the
    /// set flash once.
    var settingsFlash: SettingsFlash? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }

    /// The live search query. An anchored row that matches it keeps a
    /// low-contrast tint for as long as the query stands, so all N matches
    /// on a pane are visible at once instead of only the one Return
    /// jumped to.
    var settingsQuery: String {
        get { self[SettingsQueryKey.self] }
        set { self[SettingsQueryKey.self] = newValue }
    }
}

// MARK: - Row anchor (scroll target + highlight)

private struct SettingsAnchorModifier: ViewModifier {
    let id: String
    /// The row's own visible title, checked against the registry in debug
    /// builds so search results name the row the user will actually see.
    let label: String?
    @Environment(\.settingsJump) private var jump
    @Environment(\.settingsFlash) private var flash
    @Environment(\.settingsQuery) private var query
    @State private var glow = false
    @DSAccessibility private var a11y

    /// True while the live query matches this row — a steady, quieter
    /// wash than the one-shot jump flash.
    private var isMatch: Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return SettingsRegistry.entry(id)?.matches(query) == true
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.selectionFill(a11y.contrast))
                    .padding(.horizontal, -DS.Spacing.s)
                    .padding(.vertical, -DS.Spacing.xs)
                    .opacity(glow ? 1 : (isMatch ? DS.Opacity.matchTint : 0))
                    .dsAnimation(DS.Motion.quick, value: isMatch)
                    .allowsHitTesting(false)
            }
            .onAppear {
                SettingsRegistry.registerAnchor(id, label: label)
                if jump?.id == id { flashRow(duration: 0.6) }
            }
            .onChange(of: jump) { _, newValue in
                if newValue?.id == id { flashRow(duration: 0.6) }
            }
            .onChange(of: flash) { _, newValue in
                if newValue?.ids.contains(id) == true { flashRow(duration: DS.Motion.normal) }
            }
    }

    private func flashRow(duration: Double) {
        // Snap the tint on, then fade it out on a later tick — setting and
        // clearing `glow` in the same transaction would render nothing.
        glow = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(DS.Motion.fadeOut(duration: duration)) {
                glow = false
            }
        }
    }
}

extension View {
    /// Register this row as the scroll / highlight target for the
    /// `SettingEntry` with the same id. Pass the row's visible `label` —
    /// debug builds assert it equals the registry title, because the two
    /// drifted ("Shell font" in search results, "Font" on the row) when
    /// nothing checked them.
    func settingsAnchor(_ id: String, label: String? = nil) -> some View {
        modifier(SettingsAnchorModifier(id: id, label: label))
    }
}

// MARK: - Settings window tagger (⌘F routing)

/// Records which NSWindow hosts the Settings scene so the app-wide
/// Edit ▸ Find… command can tell "the user pressed ⌘F in Settings" from
/// "find a node on the canvas". Placed once as a background of
/// `SettingsView`.
struct SettingsWindowTagger: NSViewRepresentable {
    @MainActor private static weak var taggedWindow: NSWindow?

    /// True when `window` is the Settings window (by tag, or by the
    /// identifier SwiftUI gives the Settings scene as a fallback before the
    /// tagger has attached).
    @MainActor static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if let tagged = taggedWindow, tagged === window { return true }
        return window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
    }

    func makeNSView(context: Context) -> NSView {
        // The coordinator, not the whole `Context`: a `Context` carries the
        // environment and the current transaction, and an escaping closure
        // has no business holding either past this call.
        let coordinator = context.coordinator
        let v = WindowAttachView { window in
            Self.taggedWindow = window
            Self.restoreFrameOnce(window)
            coordinator.observe(window)
        }
        // `viewDidMoveToWindow` covers the normal path, but a view can also
        // be built with its window already set, and SwiftUI has been known
        // to install the hierarchy after the representable is made — so the
        // deferred attempt stays as the belt to that brace.
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            Self.taggedWindow = window
            Self.restoreFrameOnce(window)
            coordinator.observe(window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window {
            Self.taggedWindow = w
            Self.restoreFrameOnce(w)
            context.coordinator.observe(w)
        }
    }

    /// Windows this launch have already been put back where the user left
    /// them. Keyed by identity and weak, so that if SwiftUI ever does build
    /// a fresh Settings window (measured on this OS it re-shows the same
    /// one, but that is an implementation detail of the Settings scene) the
    /// old one cannot keep the new one out.
    @MainActor private static let restored = NSHashTable<NSWindow>.weakObjects()

    /// Puts the Settings window back at its saved frame as early as the view
    /// hierarchy allows.
    ///
    /// `SettingsView` also carries `WindowFrameAutosave(name:)`, which is the
    /// authority for *saving* and would restore too — but only from a
    /// `DispatchQueue.main.async` after the first layout pass, by which point
    /// the window has been ordered front at its centred ideal size and the
    /// user has seen it jump. `AuxiliaryWindow.make` avoids that for the
    /// other seven windows by reading the frame before it orders the window
    /// front; a `Settings` scene gives us no such hook, because SwiftUI owns
    /// the window's creation. `viewDidMoveToWindow` is the earliest moment
    /// this app can observe — it fires synchronously as the hosting view is
    /// installed, i.e. before SwiftUI orders the window front — so the
    /// restore happens there instead. The later autosaver restore then sets
    /// the same rect and is invisible.
    @MainActor private static func restoreFrameOnce(_ window: NSWindow) {
        makeResizable(window)
        keepResizable(window)
        guard !restored.contains(window) else { return }
        restored.add(window)
        guard let saved = WindowFrameAutosave.savedFrame(named: settingsFrameKey) else { return }
        window.setFrame(saved, display: false, animate: false)
    }

    /// Gives the Settings window the resize control every other window in
    /// the app has.
    ///
    /// SwiftUI builds a `Settings` scene's window WITHOUT `.resizable` in
    /// its style mask, and nothing declared in Swift moves it: measured on
    /// this OS, the scene's `.windowResizability(.contentMinSize)` already
    /// leaves `contentMaxSize` unbounded (1.8e308 in both axes) and the
    /// window is still `resizable == false`, and adding `maxWidth: .infinity,
    /// maxHeight: .infinity` to the view's own `.frame(…)` — the obvious fix
    /// — changes neither flag. The mask is the only thing left, so it is set
    /// here, on the one hook this app has into that window.
    ///
    /// It is safe precisely BECAUSE the limits are already right: the drag
    /// is bounded below by `contentMinSize`, which SwiftUI took from
    /// `SettingsView`'s `minWidth` / `minHeight`, and above by nothing —
    /// which is what a form of long scrolling panes wants. `SettingsView`'s
    /// `.frame(…)` carries the matching `maxWidth` / `maxHeight` so the
    /// panes actually grow into the extra room instead of leaving it blank.
    ///
    /// Idempotent: inserting a flag already present is a no-op. It is not
    /// sufficient on its own, though — see `keepResizable`, which re-asserts
    /// it after SwiftUI clears it.
    @MainActor private static func makeResizable(_ window: NSWindow) {
        guard !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
    }

    /// Windows whose `.resizable` flag is already being kept alive by an
    /// observer. Weak, and keyed by identity, for the same reason `restored`
    /// is.
    @MainActor private static let resizeWatched = NSHashTable<NSWindow>.weakObjects()

    /// Keeps `.resizable` set for as long as the Settings window exists.
    ///
    /// `makeResizable` at attach time is enough for the FIRST Settings
    /// window of a launch and no other. Measured on this OS, by logging the
    /// style mask from every `NSWindow` notification: SwiftUI clears the flag
    /// again one run-loop pass after the window is first ordered front (the
    /// existing `updateNSView` call happens to put it back, which is why the
    /// first open looks fixed), and clears it a second time as the window
    /// closes. ⌘, then does NOT build a new window — it re-shows the SAME
    /// `NSWindow`, identical `windowNumber` — so the view never left it,
    /// neither `viewDidMoveToWindow` nor `updateNSView` runs again, and
    /// nothing puts the flag back. Every Settings window after the first in a
    /// session was fixed-size until relaunch.
    ///
    /// The window's own notifications are the only hook that survives that
    /// re-show. `didUpdate` is the one that fires after SwiftUI's clear;
    /// `didBecomeKey` is observed too so the resize control is never briefly
    /// dead while the window is already on screen. `makeResizable` returns
    /// immediately when the flag is present, so the steady-state cost is one
    /// bit test per event-loop pass, and setting a flag SwiftUI is not
    /// clearing cannot ping-pong with it.
    ///
    /// Registered once per window and never removed: the observers must
    /// outlive both the SwiftUI view and each close, they hold the window
    /// weakly, and `resizeWatched` bounds them to one registration per
    /// window.
    @MainActor private static func keepResizable(_ window: NSWindow) {
        guard !resizeWatched.contains(window) else { return }
        resizeWatched.add(window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    makeResizable(window)
                }
            }
        }
    }

    /// Shared with the `WindowFrameAutosave` attached in `SettingsView`;
    /// the two must name the same key or the restore reads what nothing wrote.
    static let settingsFrameKey = "QnetSettingsWindow"

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Resigns first responder as the window starts to close, so a field
    /// still being edited fires its focus-loss commit before SwiftUI tears
    /// the view down. Without this, typing a value and pressing ⌘W
    /// immediately discarded it — the same rule System Settings follows.
    @MainActor
    final class Coordinator: NSObject {
        private weak var observed: NSWindow?

        func observe(_ window: NSWindow?) {
            guard let window, observed !== window else { return }
            if let old = observed {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            }
            observed = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }

        @objc private func windowWillClose(_ note: Notification) {
            (note.object as? NSWindow)?.makeFirstResponder(nil)
        }

        // No deinit teardown: NotificationCenter keeps a zeroing weak
        // reference to a selector-based observer, and the coordinator
        // outlives the window it watches only until the view goes away.
    }
}

/// An `NSView` that reports the window it has been installed into, at the
/// moment AppKit installs it. `NSViewRepresentable` offers no such hook —
/// `makeNSView` runs before the view is in a hierarchy and `updateNSView`
/// runs after the first layout pass — and the difference matters for
/// anything that has to act before the window is ordered front.
private final class WindowAttachView: NSView {
    private let onAttach: @MainActor (NSWindow) -> Void

    init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
        self.onAttach = onAttach
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach(window) }
    }
}

// MARK: - Pane scaffold

/// Grouped form with a fixed bottom bar carrying the pane's
/// "Reset to Defaults" button. Handles scroll-to-top on appearance and
/// search jumps into the pane. Every toggle in the form is a switch, as in
/// System Settings.
///
/// Reset snapshots the pane's stored keys (from `SettingsRegistry`, or the
/// `resetKeys` override) before calling `reset`, diffs afterwards, and
/// flashes only the rows that changed. The button is disabled while every
/// key already holds its default.
struct SettingsPane<Content: View>: View {
    let tab: SettingsView.Tab
    let reset: (() -> Void)?
    let resetKeys: [String]?
    @ViewBuilder let content: () -> Content

    @Environment(\.settingsJump) private var jump
    @State private var flash: SettingsFlash? = nil
    @State private var flashCounter = 0
    @State private var atDefaults = false

    @MainActor
    init(_ tab: SettingsView.Tab, reset: (() -> Void)? = nil, resetKeys: [String]? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.tab = tab
        self.reset = reset
        self.resetKeys = resetKeys
        self.content = content
        // Decide the Reset button's state before the first frame — computing
        // it in `onAppear` alone showed an enabled button for one frame on a
        // pane that was already at its defaults.
        let keys = resetKeys ?? SettingsRegistry.resetKeys(for: tab)
        _atDefaults = State(initialValue: keys.allSatisfy { AppSettings.isStoredAtDefault($0) })
    }

    /// The keys this pane's Reset touches — `SettingsRegistry.resetKeys(for:)`,
    /// which the sidebar's "differs from defaults" dot reads too, so the
    /// dot and the Reset button can never disagree.
    private var keys: [String] { resetKeys ?? SettingsRegistry.resetKeys(for: tab) }

    var body: some View {
        // Each pane is a distinct view type instantiated on selection, so
        // the underlying list is fresh (scrolled to top) on every switch;
        // only search jumps scroll it programmatically.
        ScrollViewReader { proxy in
            Form {
                content()
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .dsRowLayout(.form)
            .environment(\.settingsFlash, flash)
            .onAppear { performJump(proxy) }
            .onChange(of: jump) { _, _ in performJump(proxy) }
        }
        .navigationTitle(tab.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let reset {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { performReset(reset) }
                        .disabled(atDefaults)
                        .help(atDefaults
                              ? "Already at defaults"
                              : "Restore the defaults for the \(tab.title) pane only. Other panes are not affected.")
                        .accessibilityLabel("Reset \(tab.title) settings to defaults")
                        .accessibilityHint(atDefaults ? "Already at defaults" : "")
                }
                .dsChromeBar(.top)
            }
        }
        .onAppear { recomputeAtDefaults() }
        .onChange(of: keys) { _, _ in recomputeAtDefaults() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            recomputeAtDefaults()
        }
    }

    private func recomputeAtDefaults() {
        atDefaults = keys.allSatisfy { AppSettings.isStoredAtDefault($0) }
    }

    private func performReset(_ reset: () -> Void) {
        let before = Dictionary(uniqueKeysWithValues: keys.map { ($0, AppSettings.storedSignature(forKey: $0)) })
        reset()
        let changed = keys.filter { AppSettings.storedSignature(forKey: $0) != before[$0] }
        let ids = Set(changed.compactMap { SettingsRegistry.anchorID(forKey: $0) })
        flashCounter += 1
        flash = SettingsFlash(ids: ids, token: flashCounter)
        recomputeAtDefaults()
    }

    private func performJump(_ proxy: ScrollViewProxy) {
        guard let jump, SettingsRegistry.entry(jump.id)?.pane == tab else { return }
        // Let the list lay out before asking it to scroll.
        Task { @MainActor in
            withAnimation(DS.Motion.standard) {
                proxy.scrollTo(jump.id, anchor: .center)
            }
        }
    }
}

// MARK: - Labels and captions

// `SettingsLabel` is `DSRowLabel` (DSControls.swift): title + optional
// caption, dimming with the row. Inline errors and advisories are
// `InlineFieldMessage` (DSFields.swift) — there is no Settings-specific
// caption view.

/// Section footer text with DS typography.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Toggle row

/// Switch with a titled label and optional caption. The switch style comes
/// from the enclosing `SettingsPane` form, so every toggle in the window
/// matches.
struct SettingsToggleRow: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool
    let help: String
    let glossary: String?

    @MainActor
    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>, help: String, glossary: String? = nil) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
        self.help = help
        self.glossary = glossary
        SettingsGlossaryAudit.check(glossary, row: title)
    }

    var body: some View {
        // The switch sits in the control column and the "?" in the same
        // reserved trailing slot every field row ends with (DSGlossarySlot),
        // so a toggle with a glossary entry and the number row under it
        // share one trailing edge and the "?" never changes sides within a
        // section.
        LabeledContent {
            HStack(spacing: DS.Spacing.s) {
                Toggle(isOn: $isOn) { Text(title) }
                    .labelsHidden()
                    .help(help)
                    .accessibilityLabel(title)
                    .accessibilityHint(help)
                DSGlossarySlot(label: title, text: glossary)
            }
        } label: {
            SettingsLabel(title, caption: caption)
                .help(help)
        }
    }
}

// MARK: - Menu row

/// Pop-up menu row with the Settings defaults: the pop-up sizes to its
/// widest title (`width: nil`), every title is a short noun phrase
/// ("Loss", "BAS", "HiGHS") and the consequence of the chosen item is a
/// caption under the label that follows the selection — the System
/// Settings idiom, instead of "BAS + external loss — matches the RBM
/// model" inside the menu, which did not fit the minimum window. Debug
/// builds measure every title against `DS.Layout.settingsMenuTitleMaxWidth`
/// (`SettingsMenuTitleAudit`) and check the glossary is a `DS.Glossary`
/// entry (`SettingsGlossaryAudit`).
struct SettingsMenuRow<Option: Hashable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let help: String
    let glossary: String?
    let title: (Option) -> String
    /// Caption for the CURRENT selection (nil for none). A fixed caption
    /// can be passed as `{ _ in "…" }`.
    let detail: (Option) -> String?

    @MainActor
    init(
        _ label: String,
        selection: Binding<Option>,
        options: [Option],
        help: String,
        glossary: String? = nil,
        title: @escaping (Option) -> String,
        detail: @escaping (Option) -> String? = { _ in nil }
    ) {
        self.label = label
        self._selection = selection
        self.options = options
        self.help = help
        self.glossary = glossary
        self.title = title
        self.detail = detail
        SettingsGlossaryAudit.check(glossary, row: label)
        for option in options { SettingsMenuTitleAudit.check(title(option), row: label) }
    }

    var body: some View {
        DSMenuPicker(
            label: label,
            caption: detail(selection),
            selection: $selection,
            options: options,
            help: help,
            glossary: glossary,
            width: nil,
            title: title
        )
        .dsAnimation(DS.Motion.quick, value: detail(selection))
    }
}

// MARK: - Glossary audit

/// Every glossary string a Settings row shows must be a `DS.Glossary`
/// entry — the same entry the run dialog for that solver uses — so one
/// quantity is never explained two ways depending on which door the user
/// came through. Debug builds trap on a literal, naming the row.
enum SettingsGlossaryAudit {
    @MainActor static func check(_ glossary: String?, row: String) {
        #if DEBUG
        guard let glossary, !glossary.isEmpty, checked.insert(glossary).inserted else { return }
        assert(DS.Glossary.isEntry(glossary), """
            Settings row "\(row)" passes a glossary string that is not a DS.Glossary entry. \
            Add it to DS.Glossary (and to DS.Glossary.all) so the run dialogs share it, \
            then pass DS.Glossary.<name> here.
            """)
        #endif
    }

    #if DEBUG
    @MainActor private static var checked = Set<String>()
    #endif
}

// MARK: - Menu title audit

/// A pop-up in the Settings detail column has a width budget at the
/// minimum window size (`DS.Layout.settingsMenuTitleMaxWidth` for the
/// title alone, beside the label, the "?" column and the pop-up's chrome).
/// Debug builds measure each title once, at the pop-up's own font, and
/// trap with the row named — the way `SettingsUnitAudit` polices units.
enum SettingsMenuTitleAudit {
    @MainActor static func check(_ title: String, row: String) {
        #if DEBUG
        guard !title.isEmpty, measured.insert(title).inserted else { return }
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        assert(width <= DS.Layout.settingsMenuTitleMaxWidth, """
            Settings pop-up title "\(title)" on "\(row)" measures \(Int(width.rounded())) pt, \
            but the budget is \(Int(DS.Layout.settingsMenuTitleMaxWidth)) pt at the minimum \
            window width. Shorten it to a noun phrase and move the explanation into the \
            row's `detail:` caption.
            """)
        #endif
    }

    #if DEBUG
    @MainActor private static var measured = Set<String>()
    #endif
}

// MARK: - Unit column audit

/// The unit column beside a Settings field is a fixed
/// `DS.Layout.unitColumnWidth`, so every field in a section lines up. A
/// unit string wider than the column pushes its field out of line (and
/// truncates where the column is clipped). Debug builds measure each unit
/// once, at the column's own font, and trap with the offending row named —
/// so "per dimension" (74 pt at 11 pt, column 72 pt) is caught the first
/// time the pane opens instead of by eye.
enum SettingsUnitAudit {
    @MainActor static func check(_ unit: String?, row: String) {
        #if DEBUG
        guard let unit, !unit.isEmpty, measured.insert(unit).inserted else { return }
        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let width = (unit as NSString).size(withAttributes: [.font: font]).width
        assert(width <= DS.Layout.unitColumnWidth, """
            Settings unit "\(unit)" on "\(row)" measures \(Int(width.rounded())) pt at \
            DS.Font.numberSmall, but the unit column is \(Int(DS.Layout.unitColumnWidth)) pt. \
            Shorten the unit (for example "/ axis") or widen DS.Layout.unitColumnWidth.
            """)
        #endif
    }

    #if DEBUG
    @MainActor private static var measured = Set<String>()
    #endif
}

// MARK: - Numeric row

/// Numeric entry row: `DSNumericField` with the Settings defaults — a
/// `DS.Layout.narrowFieldWidth` field, a stepper, the reserved unit column,
/// live validation with commit on Return / focus loss / stepper (clamped
/// into `range`). `toggle:` adds the override switch (the label dims when
/// it is off); `crossCheck` is a caller-supplied message for rules spanning
/// several rows (min ≤ max); `zeroMeansAuto` shows a stored 0 as an empty
/// field whose placeholder names the automatic value.
struct SettingsNumberRow: View {
    private enum Store {
        case int(Binding<Int>, ClosedRange<Int>, DSNumericField.Step, Bool)
        case double(Binding<Double>, ClosedRange<Double>, DSNumericField.Step, FloatingPointFormatStyle<Double>)
    }

    private let label: String
    private let caption: String?
    private let store: Store
    private let unit: String?
    private let help: String
    private let glossary: String?
    private let placeholder: String
    private let crossCheck: String?
    private let toggle: Binding<Bool>?

    /// Integer field.
    @MainActor
    init(
        _ label: String,
        caption: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        help: String,
        glossary: String? = nil,
        placeholder: String = "",
        crossCheck: String? = nil,
        zeroMeansAuto: Bool = false,
        toggle: Binding<Bool>? = nil
    ) {
        self.label = label
        self.caption = caption
        self.store = .int(value, range, .linear(Double(step)), zeroMeansAuto)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.placeholder = placeholder
        self.crossCheck = crossCheck
        self.toggle = toggle
        SettingsUnitAudit.check(unit, row: label)
        SettingsGlossaryAudit.check(glossary, row: label)
    }

    /// Floating-point field. `logarithmic` makes the stepper multiply /
    /// divide by `step` instead of adding it.
    @MainActor
    init(
        _ label: String,
        caption: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        logarithmic: Bool = false,
        format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...4)),
        unit: String? = nil,
        help: String,
        glossary: String? = nil,
        placeholder: String = "",
        crossCheck: String? = nil,
        toggle: Binding<Bool>? = nil
    ) {
        self.label = label
        self.caption = caption
        self.store = .double(value, range, logarithmic ? .multiplicative(step) : .linear(step), format)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.placeholder = placeholder
        self.crossCheck = crossCheck
        self.toggle = toggle
        SettingsUnitAudit.check(unit, row: label)
        SettingsGlossaryAudit.check(glossary, row: label)
    }

    var body: some View {
        switch store {
        case .int(let value, let range, let step, let zeroMeansAuto):
            DSNumericField(
                label: label, caption: caption, value: value, unit: unit, range: range,
                stepper: step, emptyFor: zeroMeansAuto ? 0 : nil, error: crossCheck,
                help: help, glossary: glossary, placeholder: placeholder,
                width: DS.Layout.narrowFieldWidth,
                overrideToggle: toggle
            )
        case .double(let value, let range, let step, let format):
            DSNumericField(
                label: label, caption: caption, value: value, unit: unit, format: format, range: range,
                stepper: step, error: crossCheck,
                help: help, glossary: glossary, placeholder: placeholder,
                width: DS.Layout.narrowFieldWidth,
                overrideToggle: toggle
            )
        }
    }
}

// MARK: - Range row (lo … hi)

/// Two numeric fields for a closed range with a live `lo ≤ hi` check —
/// `DSRangeFields` in the `.form` row layout.
struct SettingsRangeRow: View {
    private enum Store {
        case int(Binding<Int>, Binding<Int>, ClosedRange<Int>)
        case double(Binding<Double>, Binding<Double>, ClosedRange<Double>, FloatingPointFormatStyle<Double>, DSNumericField.Step?)
    }

    private let label: String
    private let caption: String?
    private let store: Store
    private let unit: String?
    private let help: String
    private let glossary: String?
    private let strict: Bool
    private let orderMessage: String?

    @MainActor
    init(_ label: String, caption: String? = nil, lo: Binding<Int>, hi: Binding<Int>, range: ClosedRange<Int>, unit: String? = nil, help: String, glossary: String? = nil) {
        self.label = label
        self.caption = caption
        self.store = .int(lo, hi, range)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.strict = false
        self.orderMessage = nil
        SettingsUnitAudit.check(unit, row: label)
        SettingsGlossaryAudit.check(glossary, row: label)
    }

    /// `step` is the stepper increment of *both* fields — a ρ range steps
    /// by 0.05 like every other numeric row. (It used to be accepted and
    /// silently dropped, so the three ρ ranges had no arrows at all.)
    @MainActor
    init(_ label: String, caption: String? = nil, lo: Binding<Double>, hi: Binding<Double>, range: ClosedRange<Double>, step: Double, format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(2)), unit: String? = nil, help: String, glossary: String? = nil, strict: Bool = false, orderMessage: String? = nil) {
        self.label = label
        self.caption = caption
        self.store = .double(lo, hi, range, format, step > 0 ? .linear(step) : nil)
        self.unit = unit
        self.help = help
        self.glossary = glossary
        self.strict = strict
        self.orderMessage = orderMessage
        SettingsUnitAudit.check(unit, row: label)
        SettingsGlossaryAudit.check(glossary, row: label)
    }

    var body: some View {
        switch store {
        case .int(let lo, let hi, let range):
            DSRangeFields(label: label, caption: caption, lower: lo, upper: hi, range: range,
                          unit: unit, strict: strict, orderMessage: orderMessage,
                          help: help, glossary: glossary)
        case .double(let lo, let hi, let range, let format, let stepper):
            DSRangeFields(label: label, caption: caption, lower: lo, upper: hi, range: range,
                          format: format, stepper: stepper, unit: unit, strict: strict,
                          orderMessage: orderMessage, help: help, glossary: glossary)
        }
    }
}

// MARK: - Slider row

/// Slider with a fixed-width monospaced readout — `DSLabelledSlider` in
/// the `.form` row layout.
struct SettingsSliderRow: View {
    let label: String
    let caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?
    let format: FloatingPointFormatStyle<Double>
    let help: String
    let glossary: String?

    @MainActor
    init(
        _ label: String,
        caption: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String? = nil,
        format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0)),
        help: String,
        glossary: String? = nil
    ) {
        self.label = label
        self.caption = caption
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.format = format
        self.help = help
        self.glossary = glossary
        SettingsGlossaryAudit.check(glossary, row: label)
    }

    var body: some View {
        DSLabelledSlider(label: label, caption: caption, value: $value, range: range,
                         step: step, unit: unit, format: format, help: help, glossary: glossary)
    }
}

// MARK: - Font family row

/// Font-family menu for the monospaced panes. Lists fixed-pitch families
/// by default (the Shell pane needs equal-width cells); a "Show all fonts"
/// switch under the menu widens it to every installed family for panes
/// where proportional type is legitimate (the AI transcript).
/// "System Monospaced (default)" is first.
///
/// Each menu item asks for its own face, but macOS menu `Picker`s do not
/// reliably honour a per-item font, so the row also carries a sample line
/// under the menu drawn in the chosen family — that preview is the
/// promise, the per-item font is a bonus where AppKit obliges.
struct SettingsFontFamilyRow: View {
    let label: String
    let caption: String?
    @Binding var selection: String
    let help: String
    /// Offer the "Show all fonts" switch. Off for the Shell pane, whose
    /// character grid breaks with proportional fonts.
    var allowsProportional: Bool = true

    @State private var showAll = false

    /// Preview string under the menu.
    private static let sampleText = "Il1 O0 ρ=0.85 λ/μ"

    /// Cached once per process — AppKit's family list is stable while the
    /// app runs, and resolving ~300 faces on every render would be wasteful.
    @MainActor private static var monoCache: [String]?
    @MainActor private static var allCache: [String]?

    private var families: [String] {
        var list = (showAll && allowsProportional) ? Self.allFamilies() : Self.monospaceFamilies()
        // The current choice must always be selectable, even if it is a
        // proportional family chosen while "Show all fonts" was on.
        if !selection.isEmpty, !list.contains(selection) { list.insert(selection, at: 0) }
        return list
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Picker(selection: $selection) {
                        Text("System Monospaced (default)")
                            .font(DS.Font.mono)
                            .tag("")
                        Divider()
                        ForEach(families, id: \.self) { family in
                            Text(family)
                                .font(DS.Font.familyPreview(family))
                                .tag(family)
                        }
                    } label: {
                        Text(label)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: DS.Layout.wideFieldWidth + DS.Spacing.xxl)
                    .help(help)
                    .accessibilityLabel(label)
                    .accessibilityValue(selection.isEmpty ? "System Monospaced" : selection)
                    // No glossary on a font menu, but the column is
                    // reserved so the menu ends where every field does.
                    DSGlossarySlot(label: label, text: nil)
                }

                // Sample of the chosen face: digits, an ambiguous trio and
                // punctuation, so a family that renders 1/l/I alike is
                // obvious before it lands in a solver log.
                Text(Self.sampleText)
                    .font(selection.isEmpty ? DS.Font.mono : DS.Font.familyPreview(selection))
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: DS.Layout.wideFieldWidth + DS.Spacing.xxl, alignment: .trailing)
                    .help("Preview of \(selection.isEmpty ? "System Monospaced" : selection)")
                    .accessibilityHidden(true)
                    .dsAnimation(DS.Motion.quick, value: selection)
                    .padding(.trailing, DS.Layout.glossaryColumnWidth + DS.Spacing.s)

                if allowsProportional {
                    Toggle(isOn: $showAll) {
                        Text("Show all fonts")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    .controlSize(.mini)
                    .help("Off: fixed-pitch families only. On: every installed family, including proportional ones.")
                    .accessibilityLabel("Show all fonts for \(label)")
                    .padding(.trailing, DS.Layout.glossaryColumnWidth + DS.Spacing.s)
                }
            }
        } label: {
            SettingsLabel(label, caption: caption)
        }
        .onAppear {
            // A proportional family chosen earlier means the user wants the
            // wide list; start there so the menu makes sense.
            if allowsProportional, !selection.isEmpty, !Self.monospaceFamilies().contains(selection) {
                showAll = true
            }
        }
    }

    /// Fixed-pitch families, resolved from face names (same rule as the
    /// pane-header `MonospaceFontMenu`), hidden system faces excluded.
    @MainActor static func monospaceFamilies() -> [String] {
        if let cached = monoCache { return cached }
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var set = Set<String>()
        for name in names {
            if let font = NSFont(name: name, size: 12), let fam = font.familyName, !fam.hasPrefix(".") {
                set.insert(fam)
            }
        }
        let sorted = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        monoCache = sorted
        return sorted
    }

    /// Every installed family, hidden system faces excluded.
    @MainActor static func allFamilies() -> [String] {
        if let cached = allCache { return cached }
        let sorted = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        allCache = sorted
        return sorted
    }
}

// MARK: - Reference popover

/// Button that shows a block of preformatted reference text in a wide
/// `DSPopover` (monospaced, scrollable, selectable) so help never lands in
/// the shell behind the Settings window.
struct SettingsReferenceButton: View {
    let title: String
    let text: String
    let help: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(title, systemImage: DS.Symbol.help)
        }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DSPopover(title: title, systemImage: DS.Symbol.help, size: .wide) {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(DS.Font.monoCallout)
                        .textSelection(.enabled)
                        .padding(.horizontal, DS.Spacing.l)
                        .padding(.bottom, DS.Spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
    }
}

// MARK: - Status label (test-connection results etc.)

/// Inline status line with a semantic icon: spinner while running,
/// green check on success, red octagon on failure. Colour is applied
/// through the icon only; the text stays in the primary colour.
struct SettingsStatusLabel: View {
    enum Kind { case running, success, failure, info }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            switch kind {
            case .running:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: DS.Symbol.success).foregroundStyle(DS.Color.successText)
            case .failure:
                Image(systemName: DS.Symbol.failure).foregroundStyle(DS.Color.dangerText)
            case .info:
                Image(systemName: DS.Symbol.info).foregroundStyle(DS.Color.infoText)
            }
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
