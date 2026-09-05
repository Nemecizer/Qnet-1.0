import SwiftUI
import AppKit

// MARK: - Model

enum StatusSeverity: String, Codable, CaseIterable, Hashable {
    case info, success, warning, error

    var symbolName: String {
        switch self {
        case .info:    return DS.Symbol.info
        case .success: return DS.Symbol.success
        case .warning: return DS.Symbol.warning
        case .error:   return DS.Symbol.failure
        }
    }

    var color: Color {
        switch self {
        case .info:    return DS.Color.textSecondary
        case .success: return DS.Color.successText
        case .warning: return DS.Color.warningText
        case .error:   return DS.Color.dangerText
        }
    }

    var label: String {
        switch self {
        case .info:    return "Info"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }
}

/// One line of the Status pane. Codable so the per-tab log survives a
/// relaunch (TabPersistence) and so the AI `read_status` tool can emit
/// the structured form.
struct StatusEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let severity: StatusSeverity
    let text: String

    init(text: String, severity: StatusSeverity = .info, date: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.severity = severity
        self.text = text
    }

    /// Migrates a legacy pre-formatted `"[hh:mm:ss] text"` string. The
    /// leading bracketed time is parsed back into today's date when it
    /// matches the locale's medium time style; anything else keeps the
    /// text verbatim and is stamped with the current time.
    init(legacy: String) {
        var text = legacy
        var date = Date()
        if legacy.hasPrefix("["), let close = legacy.firstIndex(of: "]") {
            let stamp = String(legacy[legacy.index(after: legacy.startIndex)..<close])
            let rest = legacy[legacy.index(after: close)...]
            if let parsed = Self.legacyTimeParser.date(from: stamp) {
                let cal = Calendar.current
                let t = cal.dateComponents([.hour, .minute, .second], from: parsed)
                var d = cal.dateComponents([.year, .month, .day], from: Date())
                d.hour = t.hour; d.minute = t.minute; d.second = t.second
                date = cal.date(from: d) ?? Date()
                text = rest.trimmingCharacters(in: .whitespaces)
            }
        }
        self.init(text: text, severity: Self.inferSeverity(text), date: date)
    }

    private static let legacyTimeParser: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    enum CodingKeys: String, CodingKey { case id, date, severity, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        severity = try c.decodeIfPresent(StatusSeverity.self, forKey: .severity) ?? .info
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(severity, forKey: .severity)
        try c.encode(text, forKey: .text)
    }

    /// Classifies a message by its wording. Centralised so the 170+
    /// existing `addStatus(_:)` call sites keep working and get a
    /// sensible severity; call `addStatus(_:severity:)` to override.
    static func inferSeverity(_ text: String) -> StatusSeverity {
        let lower = text.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("⚠") {
            return lower.contains("failed") || lower.contains("aborted") ? .error : .warning
        }
        // Negated forms first: "No warnings — banner hidden." is good news,
        // not a warning, and must never trip the substring tests below.
        let negations = ["no warnings", "0 warnings", "without warning", "no errors", "0 errors",
                         "no error", "without error", "no failures", "0 failures"]
        if negations.contains(where: { lower.contains($0) }) {
            return .success
        }
        if lower.contains(" aborted:") || lower.hasPrefix("error")
            || lower.contains(" failed") || lower.hasPrefix("failed")
            || lower.contains("not found") || lower.hasPrefix("cannot ")
            || lower.contains("could not ") || lower.contains("invalid ") {
            return .error
        }
        if lower.contains("warning") || lower.contains("warn:")
            || lower.contains("cancelled") || lower.contains("canceled")
            || lower.hasPrefix("banner will fire") || lower.hasPrefix("banner triggered")
            || lower.contains("unstable") || lower.contains("caution")
            || lower.hasPrefix("nothing ") || lower.hasPrefix("no node matches")
            || lower.contains("skipping") {
            return .warning
        }
        let successPrefixes = [
            "wrote", "updated", "aligned", "saved", "exported", "loaded",
            "straightened", "distributed", "displayed", "fit network",
            "pasted", "copied", "added ", "renamed", "found ", "undid"
        ]
        if successPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .success
        }
        return .info
    }

    /// Severity of one line of solver stdout / stderr routed through the
    /// status inbox. Solvers tag their own diagnostics with a leading token,
    /// so only that token is trusted — never the wording heuristic, which
    /// would mis-tag any result line that happens to contain "invalid" or
    /// "not found".
    static func solverLineSeverity(_ line: String) -> StatusSeverity {
        let t = line.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if t.hasPrefix("WARNING") || lower.hasPrefix("warning:") { return .warning }
        if t.hasPrefix("ERROR") || lower.hasPrefix("error:") || lower.hasPrefix("fatal") { return .error }
        return .info
    }

    /// `hh:mm:ss` in the user's locale, for the timestamp column.
    var timeString: String {
        Self.timeFormatter.string(from: date)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// Plain-text rendering used by Copy and by the AI `read_status` tool:
    /// `[hh:mm:ss] [WARNING] text` (severity tag omitted for info).
    var formattedLine: String {
        severity == .info
            ? "[\(timeString)] \(text)"
            : "[\(timeString)] [\(severity.label.uppercased())] \(text)"
    }
}

// MARK: - Status pane

struct StatusPanelView: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var focusRouter = FocusRouter.shared

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", warnings = "Warnings", errors = "Errors"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var searchText: String = ""
    @State private var selection: Set<UUID> = []
    /// Keyboard focus of the search field, so Edit ▸ Search Status Log…
    /// (⌘F) can put the caret in it while the Status pane has focus.
    @FocusState private var searchFocused: Bool
    /// Measured width of the filter row; the "k of n" readout inside the
    /// search field only appears while there is room for it.
    @State private var filterRowWidth: CGFloat = 0
    /// Index into `filtered` of the entry Return / ⌘G last stepped to.
    /// The same "current match of n matches" the Settings search and the
    /// AI transcript search count — one idiom, one meaning.
    @State private var matchIndex = 0
    /// Entry the list should scroll to, bumped with `scrollToken` so the
    /// same entry can be requested twice.
    @State private var scrollTargetID: UUID?
    @State private var scrollToken = 0
    /// True while the bottom sentinel row is on screen. New entries only
    /// auto-scroll when the user is already reading the tail.
    @State private var isPinnedToBottom = true
    @State private var focusRequest = 0
    /// This instance's identity for its `FocusRouter` registrations, so a
    /// late `onDisappear` cannot clear a newer instance's handler.
    @State private var handlerOwner = PaneHandlerOwner()
    /// True when the pane hosts the Analytical / Re-entrant / Warnings
    /// pills (`FlagBarView`) under its header, so the right column reads
    /// header-then-content like every other pane instead of the pills
    /// floating in the seam between the Inspector and this header.
    var showsFlagBar: Bool = false

    private var filtered: [StatusEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return editor.statusMessages.filter { entry in
            switch filter {
            case .all: break
            case .warnings: if entry.severity != .warning && entry.severity != .error { return false }
            case .errors: if entry.severity != .error { return false }
            }
            if query.isEmpty { return true }
            return entry.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var warningCount: Int {
        editor.statusMessages.filter { $0.severity == .warning || $0.severity == .error }.count
    }

    /// True while a severity filter or a search query hides entries.
    private var isFiltering: Bool {
        filter != .all || hasQuery
    }

    /// True while the search field holds a query. Only a QUERY gets the
    /// "k of n" readout and Return / ⌘G stepping — the same idiom, with the
    /// same meaning, as the AI transcript and Settings searches. A
    /// severity filter alone counts in the header badge's tooltip.
    private var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSectionHeader("Status", isFocused: focusRouter.focusedPane == .status) {
                DSBadge(text: "\(editor.statusMessages.count)")
                    .help(isFiltering
                          ? "\(filtered.count) of \(editor.statusMessages.count) entries shown by the current filter · \(warningCount) warnings or errors in total"
                          : "\(editor.statusMessages.count) entries, \(warningCount) warnings or errors")
                    .accessibilityLabel(isFiltering
                                        ? "\(filtered.count) of \(editor.statusMessages.count) entries shown"
                                        : "\(editor.statusMessages.count) entries")
            } trailing: {
                // Header control order, shared by the Status, Shell and AI
                // panes: [pane-specific] … Find · Copy/Export · font family
                // · text size · destructive last. Status has its Find in
                // the filter row and no font family, so: Export · A± · Clear.
                exportMenu
                FontSizeStepper(
                    canDecrease: appSettings.statusFontSize > AppSettings.statusMinFontSize,
                    canIncrease: appSettings.statusFontSize < AppSettings.statusMaxFontSize,
                    onDecrease: { appSettings.decreaseStatusFontSize() },
                    onIncrease: { appSettings.increaseStatusFontSize() }
                )
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Clear Status Log",
                    help: "Clear the status log. It is not restored on the next launch, but Undo Clear in the empty log brings it back until the next clear.",
                    isDestructive: true
                ) { clearLog() }
                .disabled(editor.statusMessages.isEmpty)
                // Last in the row, after the destructive control: this one
                // changes the window, not the log. Same position in every
                // pane header that has it.
                PaneSoloButton(.status)
            }

            if showsFlagBar { FlagBarView() }

            filterRow

            StatusListView(
                entries: filtered,
                fontSize: appSettings.statusFontSize,
                selection: $selection,
                isPinnedToBottom: $isPinnedToBottom,
                focusRequest: focusRequest,
                scrollTargetID: scrollTargetID,
                scrollToken: scrollToken,
                isFiltering: isFiltering,
                searchQuery: searchText,
                undoClearCount: editor.clearedStatusBacklog.isEmpty ? nil : editor.clearedStatusBacklog.count,
                onCopySelected: copySelected,
                onCopyAll: copyAll,
                onClear: clearLog,
                onUndoClear: undoClear
            )
            .dsContentWell()
        }
        .background(PaneFocusMarker(.status))
        .onAppear {
            FocusRouter.shared.setFocusHandler(.status, owner: handlerOwner.id) { focusRequest += 1 }
            FocusRouter.shared.setZoomHandler(.status, owner: handlerOwner.id) { step in
                if step > 0 { appSettings.increaseStatusFontSize() } else { appSettings.decreaseStatusFontSize() }
            } canZoom: { step in
                step > 0
                    ? appSettings.statusFontSize < AppSettings.statusMaxFontSize
                    : appSettings.statusFontSize > AppSettings.statusMinFontSize
            }
            // ⌘F with the Status pane focused searches the log rather than
            // opening Find Node on the canvas; ⌘G / ⇧⌘G then step through
            // the matching entries, exactly as Return in the field does.
            FocusRouter.shared.setFindHandler(.status, owner: handlerOwner.id) { searchFocused = true }
            FocusRouter.shared.setFindStepHandler(.status, owner: handlerOwner.id) { delta in
                stepMatch(delta)
            } canStep: {
                hasQuery && !filtered.isEmpty
            }
        }
        .onDisappear {
            FocusRouter.shared.setFocusHandler(.status, owner: handlerOwner.id, nil)
            FocusRouter.shared.setZoomHandler(.status, owner: handlerOwner.id, nil)
            FocusRouter.shared.setFindHandler(.status, owner: handlerOwner.id, nil)
            FocusRouter.shared.setFindStepHandler(.status, owner: handlerOwner.id, nil)
        }
        .onChange(of: searchText) { _, _ in
            matchIndex = 0
            FocusRouter.shared.noteFindStateChanged()
        }
        .onChange(of: filter) { _, _ in
            matchIndex = 0
            FocusRouter.shared.noteFindStateChanged()
        }
        .onChange(of: filtered.count) { _, _ in
            FocusRouter.shared.noteFindStateChanged()
        }
    }

    /// Copy All · Copy Selected · Save Status Log… — the same DSIconMenu
    /// shape the AI pane's export button has, so the two panes that keep
    /// a record offer it the same way. Save is also File ▸ Export ▸
    /// Status Log….
    private var exportMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.export,
            label: "Export status log",
            help: "Copy the visible entries, or save the status log to a text file"
        ) {
            Button("Copy All") { copyAll() }
                .disabled(filtered.isEmpty)
            Button("Copy Selected") { copySelected() }
                .disabled(selection.isEmpty)
            Divider()
            Button("Save Status Log…") { StatusLogExport.save(editor: editor, entries: filtered) }
                .disabled(filtered.isEmpty)
        }
        .disabled(editor.statusMessages.isEmpty)
    }

    /// "k of n" for the search field: the entry Return / ⌘G last stepped
    /// to, of the entries the filter and query leave visible. Nil while
    /// nothing is being searched for, so the field stays plain.
    private var matchStatus: String? {
        guard hasQuery, filterRowWidth >= DS.Layout.matchCountMinRowWidth else { return nil }
        let total = filtered.count
        guard total > 0 else { return nil }
        return "\(min(matchIndex, total - 1) + 1) of \(total)"
    }

    /// Return / ⌘G: select the next (or previous) matching entry and
    /// scroll it into view. A no-op without a query: Return in the empty
    /// field must not walk the severity filter's rows.
    private func stepMatch(_ delta: Int) {
        let total = filtered.count
        guard hasQuery, total > 0 else { return }
        matchIndex = (min(matchIndex, total - 1) + delta + total) % total
        let entry = filtered[matchIndex]
        selection = [entry.id]
        scrollTargetID = entry.id
        scrollToken += 1
    }

    private var filterRow: some View {
        HStack(spacing: DS.Spacing.s) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show all entries, only warnings and errors, or only errors")
            .accessibilityLabel("Severity filter")

            // The "k of n" readout lives INSIDE the field (DSSearchField's
            // `status:` slot), attached to the query it counts, and means
            // the same thing it means in Settings and the AI pane: the
            // match Return / ⌘G last stepped to, of the matches. The
            // filtered-of-total count is the header badge's tooltip. In a
            // narrow pane the readout is dropped so the field keeps a
            // usable width.
            DSSearchField(
                text: $searchText,
                placeholder: "Search status log",
                shortcutHint: "⌘F",
                help: "Show only the entries that contain this text. Return, ⌘G and ⇧⌘G step through the matches",
                status: matchStatus,
                accessibilityLabel: "Search status log",
                focus: $searchFocused,
                onSubmit: { stepMatch(+1) }
            )
        }
        .dsChromeBar(.bottom, horizontal: DS.Spacing.s, height: DS.Layout.filterRowHeight)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { filterRowWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in filterRowWidth = w }
            }
        )
    }

    private func copySelected() {
        let items = filtered.filter { selection.contains($0.id) }
        guard !items.isEmpty else { copyAll(); return }
        copy(items)
    }

    private func copyAll() {
        copy(filtered)
    }

    /// Copy is never silent: the log says how many entries went to the
    /// clipboard, the way the Shell's Copy reports what it copied.
    private func copy(_ items: [StatusEntry]) {
        guard !items.isEmpty else { return }
        let text = items.map(\.formattedLine).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        editor.addStatus(
            "Copied \(items.count) status entr\(items.count == 1 ? "y" : "ies") to the clipboard.",
            severity: .success
        )
    }

    /// One Clear Status Log for the pane header, the list's context menu
    /// and Edit ▸ Clear Status Log. Clearing a long log asks first — the
    /// same pattern as Restart Shell and Clear Conversation — and every
    /// clear is undoable from the empty state until the next one, because
    /// the log is not restored on the next launch. The confirmation, the
    /// undo backlog and the empty state all live on the editor
    /// (`NetworkEditorModel.clearStatusLog` and its `clearConfirmThreshold`),
    /// so the menu item and this button cannot drift apart again — and
    /// hiding the pane (⌥⌘2) no longer throws the undo away with the
    /// view's state.
    ///
    /// TabPersistenceObserver picks up the count change and schedules a
    /// debounced save; on the next launch the `!saved.isEmpty` guard means
    /// the default greeting is shown instead of the old history.
    private func clearLog() {
        if editor.clearStatusLog() {
            selection.removeAll()
        }
    }

    private func undoClear() {
        editor.undoClearStatusLog()
    }
}

/// The scrolling table of entries. Auto-scrolls to new entries only
/// while the bottom sentinel is visible, so a user reading older lines
/// is never yanked back down.
private struct StatusListView: View {
    let entries: [StatusEntry]
    let fontSize: Double
    @Binding var selection: Set<UUID>
    @Binding var isPinnedToBottom: Bool
    let focusRequest: Int
    /// Entry to scroll into view (Return / ⌘G stepping); `scrollToken`
    /// changes on every request so repeats are honoured.
    let scrollTargetID: UUID?
    let scrollToken: Int
    /// True while a severity filter or search query hides entries, so an
    /// empty list shows the "no results" state rather than "no entries".
    let isFiltering: Bool
    let searchQuery: String
    /// Number of entries the last Clear removed, while they can still be
    /// restored; nil when there is nothing to undo.
    let undoClearCount: Int?
    let onCopySelected: () -> Void
    let onCopyAll: () -> Void
    let onClear: () -> Void
    let onUndoClear: () -> Void

    private static let bottomID = "status.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(entries) { entry in
                    StatusRow(entry: entry, fontSize: fontSize, searchQuery: searchQuery)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.s, bottom: DS.Spacing.xs, trailing: DS.Spacing.s))
                        .listRowSeparator(.hidden)
                }
                Color.clear
                    .frame(height: DS.Layout.scrollSentinelHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .id(Self.bottomID)
                    .onAppear { isPinnedToBottom = true }
                    .onDisappear { isPinnedToBottom = false }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(StatusTableFocusHook(focusRequest: focusRequest))
            .copyable(entries.filter { selection.contains($0.id) }.map(\.formattedLine))
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Copy") { onCopySelected() }
                    .disabled(ids.isEmpty)
                Button("Copy All") { onCopyAll() }
                Divider()
                Button("Clear Status Log", role: .destructive) { onClear() }
            }
            .onChange(of: entries.count) { _, _ in
                if isPinnedToBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: scrollToken) { _, _ in
                guard let id = scrollTargetID else { return }
                withAnimation(DS.Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Pin to the newest entry on first appearance so a restored
            // tab opens on the most recent line rather than "Ready…".
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .overlay {
                if entries.isEmpty {
                    if isFiltering {
                        DSEmptyState.search(query: searchQuery)
                            .allowsHitTesting(false)
                    } else if let undoClearCount {
                        // Clear is destructive and the log is not restored
                        // on the next launch, so the empty state offers the
                        // way back until the next clear.
                        DSEmptyState(
                            systemImage: DS.Symbol.statusLog,
                            title: "Status Log Cleared",
                            message: "\(undoClearCount) entr\(undoClearCount == 1 ? "y was" : "ies were") removed. Solver output and warnings appear here.",
                            actionTitle: "Undo Clear",
                            action: onUndoClear
                        )
                    } else {
                        DSEmptyState(
                            systemImage: DS.Symbol.statusLog,
                            title: "No Status Entries",
                            message: "Solver output and warnings appear here."
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

private struct StatusRow: View {
    let entry: StatusEntry
    let fontSize: Double
    /// The live filter text, so a match is visible in the row and not only
    /// implied by the row still being in the list — the same treatment the
    /// Help window gives its hits.
    let searchQuery: String

    /// The entry text with every occurrence of the query washed in the
    /// accent tint (the shared `highlightingMatches(of:)`, so the AI
    /// transcript's hits look the same). Plain when nothing is searched.
    private var text: AttributedString {
        entry.text.highlightingMatches(of: searchQuery)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: entry.severity.symbolName)
                .font(DS.Font.userMonoSymbol(size: fontSize))
                .foregroundStyle(entry.severity.color)
                .frame(width: DS.Spacing.l, alignment: .center)
                .accessibilityLabel(entry.severity.label)
            Text(entry.timeString)
                .font(DS.Font.userMonoCaption(size: fontSize))
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Text(text)
                .font(DS.Font.userMono(size: fontSize))
                .foregroundStyle(entry.severity == .error ? DS.Color.dangerText : DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No tooltip: the row wraps, so it is fully visible — a tooltip
        // that repeats what is already on screen is noise.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.formattedLine)
    }
}

/// Finds the List's backing NSTableView so "Focus Status" (⌃⌘2) can make
/// it first responder.
private struct StatusTableFocusHook: NSViewRepresentable {
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastRequest != focusRequest else { return }
        context.coordinator.lastRequest = focusRequest
        guard focusRequest > 0 else { return }
        DispatchQueue.main.async {
            var current: NSView? = nsView.superview
            // Walk up to the pane root, then down to the first NSTableView.
            while let v = current, !(v.superview is NSSplitView) { current = v.superview }
            guard let root = current, let table = Self.findTable(in: root) else { return }
            table.window?.makeFirstResponder(table)
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for s in view.subviews {
            if let t = findTable(in: s) { return t }
        }
        return nil
    }

    @MainActor
    final class Coordinator {
        var lastRequest = 0
    }
}
