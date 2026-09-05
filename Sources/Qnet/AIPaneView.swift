import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Transcript model

/// A tool invocation the model requested, as shown in the transcript.
/// `result` / `finished` are filled in once the tool returns.
struct AIToolCall: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// Pretty-printed JSON of the input arguments.
    let inputText: String
    /// One-line `key=value, …` summary for the collapsed row.
    let inputSummary: String
    var result: String?
    var isError: Bool = false
    let started: Date
    var finished: Date?

    var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
    var isRunning: Bool { finished == nil }
}

/// Role of a single message in the AI transcript.
enum AIMessageRole: Hashable {
    case user
    case assistant
    case system
    case tool(AIToolCall)
}

/// An inline action offered by a `.system` row (a button in the transcript).
enum AIMessageAction: Hashable {
    /// Re-enter the tool loop with the existing history after it hit the
    /// iteration ceiling.
    case continueToolLoop
}

struct AIMessage: Identifiable, Hashable {
    let id: UUID
    var role: AIMessageRole
    var text: String
    let timestamp: Date
    /// True while text deltas are still arriving for this message.
    var isStreaming: Bool
    /// Optional action button rendered with a `.system` row; cleared once
    /// the action has been taken so the row becomes a plain note.
    var action: AIMessageAction?

    init(id: UUID = UUID(), role: AIMessageRole, text: String, isStreaming: Bool = false, action: AIMessageAction? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.action = action
    }

    var toolCall: AIToolCall? {
        if case .tool(let call) = role { return call }
        return nil
    }

    /// `hh:mm:ss` for the hover caption.
    var timeString: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }

    /// Full date and time for tooltips and the exported transcript.
    var fullTimeString: String {
        timestamp.formatted(date: .abbreviated, time: .standard)
    }
}

/// One tab's conversation: what the pane shows and what the provider is
/// sent. Stored per tab id in `AIModel.conversations`; the active tab's
/// copy lives in `AIModel.messages` / `llmHistory` while it is in front.
struct AIConversation {
    var messages: [AIMessage] = []
    var llmHistory: [LLMMessage] = []
}

@MainActor
final class AIModel: ObservableObject {
    /// The ACTIVE tab's transcript. Every network keeps its own
    /// conversation (see `bind(tabID:title:)`), so a question asked about
    /// one tab can never be answered — or acted on — in another.
    @Published var messages: [AIMessage] = []
    @Published var input: String = ""
    @Published var isBusy: Bool = false
    /// Tab whose conversation is in front, and the network name the pane
    /// header shows for it ("about 3dtandem.inf.bnet").
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var boundNetworkName: String = "Untitled"
    /// Tab the in-flight request belongs to. Tool calls target this tab's
    /// editor and the streamed reply lands in its transcript even if the
    /// user switches tabs while the model is working.
    @Published private(set) var busyTabID: UUID?
    /// Network name of that tab, captured when the request started, so the
    /// header can say "Working on 3dtandem.inf.bnet" from another tab.
    @Published private(set) var busyTabTitle: String = ""
    /// Conversations of the tabs that are not in front.
    private var conversations: [UUID: AIConversation] = [:]
    /// Short description of what the assistant is doing right now
    /// ("Thinking…", "Running read_network…") for the progress row.
    @Published var busyPhase: String = ""
    /// Bumped to ask the composer to take keyboard focus.
    @Published var focusRequest: Int = 0

    /// The in-flight agentic loop. Cancelled by `cancel()` (Stop button
    /// / Esc while busy).
    private(set) var currentTask: Task<Void, Never>?

    /// Injected by QnetGUIApp so the model can build an `LLMConfig` from
    /// current user settings at send-time.
    var configProvider: (() -> LLMConfig)?

    /// Injected by QnetGUIApp; holds the catalog of tools the model may
    /// invoke. Leave nil to disable tool use entirely.
    var toolRegistry: ToolRegistry?

    /// Wire-format conversation mirror. `messages` (UI) is kept separate
    /// so we can show abbreviated status lines for tool calls without
    /// round-tripping them back to the model. `llmHistory` is what we
    /// actually send to the provider and includes every tool_use /
    /// tool_result block verbatim.
    private var llmHistory: [LLMMessage] = []

    /// Safety valve on the agentic loop. Bails out if the model keeps
    /// calling tools without finalizing an answer.
    private let maxToolIterations = 10

    // No seeded greeting: a user with a working key used to open the pane
    // and find one instruction telling them to configure the backend they
    // had already configured. What to say is derived from state — see
    // AIPaneView.starterPanel (configured) and .emptyState (not).

    // MARK: Per-tab conversations

    /// Makes `tabID`'s conversation the one the pane shows. Called by
    /// QnetGUIApp whenever the active tab (or its title) changes: the
    /// outgoing tab's transcript is parked in `conversations`, the
    /// incoming one restored. A request in flight keeps writing to the
    /// tab it started in (`busyTabID`).
    func bind(tabID: UUID, title: String) {
        boundNetworkName = title
        guard tabID != activeTabID else { return }
        if let current = activeTabID {
            conversations[current] = AIConversation(messages: messages, llmHistory: llmHistory)
        }
        activeTabID = tabID
        let stored = conversations.removeValue(forKey: tabID) ?? AIConversation()
        messages = stored.messages
        llmHistory = stored.llmHistory
    }

    /// Drops the conversations of tabs that were closed.
    func pruneConversations(keeping ids: Set<UUID>) {
        conversations = conversations.filter { ids.contains($0.key) }
    }

    /// Edits the transcript of `tab` — the live `messages` while that tab
    /// is in front, its parked copy otherwise.
    private func mutateMessages(_ tab: UUID?, _ body: (inout [AIMessage]) -> Void) {
        if let tab, tab != activeTabID {
            var conv = conversations[tab] ?? AIConversation()
            body(&conv.messages)
            conversations[tab] = conv
        } else {
            body(&messages)
        }
    }

    private func mutateHistory(_ tab: UUID?, _ body: (inout [LLMMessage]) -> Void) {
        if let tab, tab != activeTabID {
            var conv = conversations[tab] ?? AIConversation()
            body(&conv.llmHistory)
            conversations[tab] = conv
        } else {
            body(&llmHistory)
        }
    }

    private func history(of tab: UUID?) -> [LLMMessage] {
        if let tab, tab != activeTabID { return conversations[tab]?.llmHistory ?? [] }
        return llmHistory
    }

    /// True while the request in flight belongs to the tab in front, so
    /// the transcript shows its progress row only where it applies.
    var isBusyForActiveTab: Bool { isBusy && busyTabID == activeTabID }

    /// True while a request is running for a tab that is NOT in front.
    /// The header then shows a "Working on <tab>" badge instead of
    /// claiming this tab's backend is busy, and the composer explains
    /// why Send is waiting (one request at a time, per client).
    var isBusyElsewhere: Bool { isBusy && busyTabID != activeTabID }

    func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        messages.append(AIMessage(role: .user, text: trimmed))
        llmHistory.append(LLMMessage(role: .user, text: trimmed))
        input = ""
        startLoop()
    }

    /// "Continue" after the tool loop hit its iteration ceiling: re-enter
    /// the loop with the existing history (the model's last turn was a
    /// tool result, so it simply carries on). The offering row loses its
    /// button so it cannot be pressed twice.
    func continueToolLoop() {
        guard !isBusy else { return }
        for i in messages.indices where messages[i].action == .continueToolLoop {
            messages[i].action = nil
        }
        startLoop()
    }

    /// Kick off one agentic run over the active tab's history. The tab is
    /// captured now: everything the run produces goes to that tab's
    /// transcript, wherever the user is looking when it arrives.
    private func startLoop() {
        guard let configProvider else {
            appendError("AI backend is not wired up. (Missing configProvider)")
            return
        }
        let config = configProvider()
        let toolSchemas: [LLMTool] = config.provider.supportsToolUse
            ? (toolRegistry?.allSchemas() ?? [])
            : []

        let tab = activeTabID
        isBusy = true
        busyTabID = tab
        busyTabTitle = boundNetworkName
        busyPhase = "Thinking…"
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false
                self.busyPhase = ""
                self.currentTask = nil
                self.finishStreamingMessages(in: tab)
                self.busyTabID = nil
            }
            do {
                try await self.runAgenticLoop(config: config, toolSchemas: toolSchemas, tab: tab)
            } catch is CancellationError {
                self.mutateMessages(tab) { $0.append(AIMessage(role: .system, text: "Stopped.")) }
            } catch {
                self.appendError(error.localizedDescription, tab: tab)
            }
        }
    }

    /// Cancels the in-flight request. Partial streamed text is kept.
    func cancel() {
        currentTask?.cancel()
    }

    /// Number of user / assistant exchanges so far (excludes system notes
    /// and tool rows). Gates the export menu and the clear confirmation.
    var exchangeCount: Int {
        messages.filter {
            switch $0.role {
            case .user, .assistant: return true
            case .system, .tool: return false
            }
        }.count
    }

    /// Repeatedly send the conversation, execute any requested tools, and
    /// feed the results back — until the model returns a text-only reply
    /// (loop end) or we exceed `maxToolIterations`.
    private func runAgenticLoop(
        config: LLMConfig,
        toolSchemas: [LLMTool],
        tab: UUID?
    ) async throws {
        let client = try LLMClientFactory.make(from: config)

        for _ in 0..<maxToolIterations {
            try Task.checkCancellation()
            busyPhase = "Thinking…"
            let historySnapshot = history(of: tab)
            let response = try await send(
                client: client, history: historySnapshot, tools: toolSchemas, tab: tab
            )
            try Task.checkCancellation()

            mutateHistory(tab) { $0.append(LLMMessage(role: .assistant, content: response)) }

            var toolCalls: [(id: String, name: String, input: [String: Any])] = []
            for block in response {
                if case .toolUse(let id, let name, let input) = block {
                    toolCalls.append((id: id, name: name, input: input))
                }
            }

            if toolCalls.isEmpty {
                return
            }

            var resultBlocks: [LLMContent] = []
            for call in toolCalls {
                try Task.checkCancellation()
                let record = AIToolCall(
                    id: UUID(),
                    name: call.name,
                    inputText: Self.prettyJSON(call.input),
                    inputSummary: formatInput(call.input),
                    started: Date()
                )
                let messageID = UUID()
                mutateMessages(tab) { $0.append(AIMessage(id: messageID, role: .tool(record), text: "")) }
                busyPhase = "Running \(call.name)…"

                var finished = record
                do {
                    let result = try await toolRegistry?
                        .execute(name: call.name, input: call.input)
                        ?? "No tool registry available."
                    finished.result = result
                    finished.isError = false
                    resultBlocks.append(.toolResult(id: call.id, content: result, isError: false))
                } catch {
                    finished.result = error.localizedDescription
                    finished.isError = true
                    resultBlocks.append(.toolResult(
                        id: call.id, content: error.localizedDescription, isError: true
                    ))
                }
                finished.finished = Date()
                mutateMessages(tab) { list in
                    if let idx = list.firstIndex(where: { $0.id == messageID }) {
                        list[idx].role = .tool(finished)
                    }
                }
            }
            mutateHistory(tab) { $0.append(LLMMessage(role: .user, content: resultBlocks)) }
        }

        // Not a dead end: the history is intact (the last turn is a tool
        // result), so the row offers a Continue button that re-enters the
        // loop for another `maxToolIterations` rounds.
        mutateMessages(tab) {
            $0.append(AIMessage(
                role: .system,
                text: "Paused after \(maxToolIterations) tool calls without a final answer. Continue to let the assistant keep working, or ask a narrower question.",
                action: .continueToolLoop
            ))
        }
    }

    /// One round trip. Streams text into a placeholder assistant message
    /// when the client supports it; otherwise appends the reply once.
    private func send(
        client: LLMClient,
        history: [LLMMessage],
        tools: [LLMTool],
        tab: UUID?
    ) async throws -> [LLMContent] {
        let placeholderID = UUID()
        let response: [LLMContent]

        if let streaming = client as? LLMStreamingClient {
            response = try await streaming.sendStreaming(
                history: history, tools: tools
            ) { [weak self] delta in
                guard let self else { return }
                self.mutateMessages(tab) { list in
                    if let idx = list.firstIndex(where: { $0.id == placeholderID }) {
                        list[idx].text += delta
                    } else {
                        list.append(
                            AIMessage(id: placeholderID, role: .assistant, text: delta, isStreaming: true)
                        )
                    }
                }
            }
        } else {
            response = try await client.send(history: history, tools: tools)
        }

        let assistantText = response.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        mutateMessages(tab) { list in
            if let idx = list.firstIndex(where: { $0.id == placeholderID }) {
                if assistantText.isEmpty {
                    list.remove(at: idx)
                } else {
                    list[idx].text = assistantText
                    list[idx].isStreaming = false
                }
            } else if !assistantText.isEmpty {
                list.append(AIMessage(role: .assistant, text: assistantText))
            }
        }
        return response
    }

    /// Marks any still-streaming message as complete (after cancel or
    /// error) so the caret stops blinking.
    private func finishStreamingMessages(in tab: UUID?) {
        mutateMessages(tab) { list in
            for i in list.indices where list[i].isStreaming {
                list[i].isStreaming = false
            }
            for i in list.indices {
                if case .tool(var call) = list[i].role, call.isRunning {
                    call.finished = Date()
                    call.isError = true
                    call.result = call.result ?? "Cancelled."
                    list[i].role = .tool(call)
                }
            }
        }
    }

    /// Empties the ACTIVE tab's transcript (other tabs keep theirs). The
    /// pane then re-derives what to show the same way it does on a fresh
    /// launch — the starter panel when a backend is configured, the "no
    /// backend" empty state otherwise — so Clear and first launch never
    /// disagree. A request running for this tab is cancelled with it.
    func clear() {
        if busyTabID == activeTabID { cancel() }
        messages = []
        llmHistory = []
    }

    /// True until the conversation has anything in it at all. Drives the
    /// starter panel and the Clear button's enablement.
    var isEmptyTranscript: Bool { messages.isEmpty }

    // MARK: Export

    /// The whole transcript as Markdown: a heading per turn with the
    /// timestamp, tool calls as fenced JSON input + result blocks.
    func transcriptMarkdown() -> String {
        var out = "# Qnet AI Assistant transcript\n\n"
        out += "_Exported \(Date().formatted(date: .abbreviated, time: .standard))_\n\n"
        for m in messages {
            switch m.role {
            case .user:
                out += "## You · \(m.fullTimeString)\n\n\(m.text)\n\n"
            case .assistant:
                out += "## Assistant · \(m.fullTimeString)\n\n\(m.text)\n\n"
            case .system:
                out += "> _\(m.text)_\n\n"
            case .tool(let call):
                out += "### Tool: `\(call.name)` · \(m.fullTimeString)"
                if let d = call.duration { out += " · \(Self.format(duration: d))" }
                out += "\n\n**Input**\n\n```json\n\(call.inputText)\n```\n\n"
                if let result = call.result {
                    out += "**\(call.isError ? "Error" : "Result")**\n\n```\n\(result)\n```\n\n"
                }
            }
        }
        return out
    }

    /// Copies `transcriptMarkdown()` to the clipboard.
    func copyConversation() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcriptMarkdown(), forType: .string)
    }

    /// Save Transcript… — NSSavePanel, Markdown.
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.nameFieldLabel = "Save As:"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "Qnet AI transcript \(stamp).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appendError("Could not save the transcript: \(error.localizedDescription)")
        }
    }

    static func format(duration: TimeInterval) -> String {
        duration < 1 ? String(format: "%.0f ms", duration * 1000) : String(format: "%.1f s", duration)
    }

    func increaseFontSize(settings: AppSettings) {
        settings.aiFontSize = min(settings.aiFontSize + 1, AppSettings.aiMaxFontSize)
    }

    func decreaseFontSize(settings: AppSettings) {
        settings.aiFontSize = max(settings.aiFontSize - 1, AppSettings.aiMinFontSize)
    }

    private func appendError(_ msg: String, tab: UUID? = nil) {
        mutateMessages(tab ?? busyTabID) { $0.append(AIMessage(role: .system, text: "⚠ \(msg)")) }
    }

    private func formatInput(_ input: [String: Any]) -> String {
        guard !input.isEmpty else { return "" }
        let parts = input.keys.sorted().map { key -> String in
            var v = "\(input[key] ?? "")"
            if v.count > 40 { v = String(v.prefix(40)) + "…" }
            return "\(key)=\(v)"
        }
        return parts.joined(separator: ", ")
    }

    private static func prettyJSON(_ input: [String: Any]) -> String {
        guard !input.isEmpty else { return "{}" }
        if JSONSerialization.isValidJSONObject(input),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(input)"
    }

    /// Resolved monospaced NSFont for code in the transcript (fenced
    /// blocks, tool input / results), built from the user's AI-pane font
    /// settings. Prose is proportional (`DS.Font.userProse`) at the same
    /// size, so the font menu governs code, not prose. Falls back to the
    /// system monospaced font when the configured family isn't available.
    func resolvedFont(settings: AppSettings) -> NSFont {
        let size = CGFloat(settings.aiFontSize)
        if !settings.aiFontName.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: settings.aiFontName])
            if let font = NSFont(descriptor: descriptor, size: size) { return font }
            if let font = NSFont(name: settings.aiFontName, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Pane view

/// The AI Assistant pane.
///
/// Conversations are PER TAB. `AIModel` keeps one transcript and one
/// provider history per `NetworkTab` id and QnetGUIApp binds the active
/// tab on every switch, so asking "which stations are unstable?" in one
/// tab and "now raise the service rate" in another can never edit the
/// wrong network with the first tab's discussion above it. A request in
/// flight stays bound to the tab it was asked in: its reply, its tool
/// calls and their edits all land there. The header names the network
/// the visible conversation is about (a badge after the provider chip),
/// and the starter panel and composer placeholder say it too.
///
/// Header control order, shared with the Status and Shell panes:
/// [pane-specific: Stop] · Find · Export · font family · text size ·
/// destructive (Clear) last.
struct AIPaneView: View {
    @EnvironmentObject private var ai: AIModel
    @EnvironmentObject private var appSettings: AppSettings
    /// Observed only to arbitrate ⌘.: while a solver run is in flight the
    /// menu bar's Run ▸ Stop owns that key, so this pane's Stop button
    /// stands down and exactly one handler is live.
    @EnvironmentObject private var terminal: TerminalModel
    @ObservedObject private var focusRouter = FocusRouter.shared

    /// Transcript search (⌘F while the AI pane has focus). Empty and
    /// hidden until the find handler fires. The transcript is filtered to
    /// matching messages, every hit is highlighted in place, and Return /
    /// ⌘G / ⇧⌘G step through the matches ("k of n" in the field) — the
    /// same three behaviours the Status pane and Qnet Help have.
    @State private var isSearching = false
    @State private var transcriptQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var matchIndex = 0
    @State private var scrollTargetID: UUID?
    @State private var scrollToken = 0
    /// Measured pane width: below `DS.Layout.headerCondenseWidthNarrow`
    /// the header's least-used controls fold into one overflow menu
    /// instead of squeezing the title and the provider chip to nothing.
    @State private var paneWidth: CGFloat = 0

    /// Whether an API key is present for the current provider. Read from
    /// the Keychain on appear / provider change / window activation
    /// (i.e. when the user comes back from Settings), never per-render.
    @State private var apiKeyPresent = false

    /// This instance's identity for its `FocusRouter` registrations, so a
    /// late `onDisappear` cannot clear a newer instance's handler.
    @State private var handlerOwner = PaneHandlerOwner()

    private enum BackendStatus {
        case busy, ready, missingKey, notConfigured

        var color: Color {
            switch self {
            case .busy: return DS.Color.accent
            case .ready: return DS.Color.success
            case .missingKey: return DS.Color.warning
            case .notConfigured: return DS.Color.textSecondary
            }
        }

        var label: String {
            switch self {
            case .busy: return "Working"
            case .ready: return "Ready"
            case .missingKey: return "API key missing"
            case .notConfigured: return "Not configured"
            }
        }

        /// Shape the header chip's status dot takes under "Differentiate
        /// Without Colour", where the four dot colours are indistinguishable.
        var symbol: String {
            switch self {
            case .busy: return DS.Symbol.pending
            case .ready: return DS.Symbol.success
            case .missingKey: return DS.Symbol.warning
            case .notConfigured: return DS.Symbol.blocked
            }
        }
    }

    private var provider: LLMProvider { appSettings.aiProviderResolved }
    private var modelName: String { appSettings.aiModel(for: provider).trimmingCharacters(in: .whitespaces) }

    /// The chip describes THIS tab's conversation: "Working" only while
    /// the request in flight is this tab's. A request running for another
    /// tab is reported by `elsewhereBadge`, not by lying here.
    private var backendStatus: BackendStatus {
        if ai.isBusyForActiveTab { return .busy }
        if modelName.isEmpty || appSettings.aiBaseURL(for: provider).trimmingCharacters(in: .whitespaces).isEmpty {
            return .notConfigured
        }
        if provider.requiresAPIKey && !apiKeyPresent { return .missingKey }
        return .ready
    }

    private var isConfigured: Bool {
        switch backendStatus {
        case .busy, .ready: return true
        case .missingKey, .notConfigured: return false
        }
    }

    /// Show the empty state only until the first real exchange.
    private var showEmptyState: Bool {
        !isConfigured && !ai.messages.contains { if case .user = $0.role { return true } else { return false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSectionHeader("AI Assistant", isFocused: focusRouter.focusedPane == .ai) {
                providerChip
                if !isCondensedHeader { networkBadge }
                if ai.isBusyElsewhere { elsewhereBadge }
            } trailing: {
                // The Stop slot is ALWAYS laid out and only its content
                // changes, so sending a message no longer shifts every
                // control beside it 62 pt and back. Then the shared order:
                // Find · Export · font family · text size · Clear.
                stopSlot
                DSIconButton(
                    systemImage: DS.Symbol.find,
                    label: "Search Conversation",
                    help: "Search the transcript (⌘F while this pane has focus)"
                ) { showSearch() }
                .disabled(ai.isEmptyTranscript)
                exportMenu
                if !isCondensedHeader {
                    MonospaceFontMenu(family: $appSettings.aiFontName, help: "Code font (fenced code and tool output; prose uses the system font)")
                    FontSizeStepper(
                        canDecrease: appSettings.aiFontSize > AppSettings.aiMinFontSize,
                        canIncrease: appSettings.aiFontSize < AppSettings.aiMaxFontSize,
                        onDecrease: { ai.decreaseFontSize(settings: appSettings) },
                        onIncrease: { ai.increaseFontSize(settings: appSettings) }
                    )
                } else {
                    overflowMenu
                }
                // Clear acts on THIS tab's transcript, so only a request
                // running for this tab blocks it.
                DSIconButton(
                    systemImage: DS.Symbol.clearPane,
                    label: "Clear Conversation",
                    help: ai.isBusyForActiveTab ? "Stop the request before clearing the conversation" : "Clear the conversation…",
                    isDestructive: true
                ) { confirmClear() }
                .disabled(ai.isBusyForActiveTab || ai.isEmptyTranscript)
                // Last in the row, after the destructive control: this one
                // changes the window, not the conversation.
                PaneSoloButton(.ai)
            }

            if isSearching { searchRow }

            Group {
                if showEmptyState {
                    emptyState
                } else if showStarterPanel {
                    starterPanel
                } else if visibleMessages.isEmpty {
                    // Searching, nothing matched: the same "No Results"
                    // state the Status pane and Qnet Help show.
                    DSEmptyState.search(query: transcriptQuery)
                } else {
                    AITranscriptView(
                        messages: visibleMessages,
                        isBusy: ai.isBusyForActiveTab,
                        busyPhase: ai.busyPhase,
                        fontSize: appSettings.aiFontSize,
                        monoFont: Font(ai.resolvedFont(settings: appSettings)),
                        searchQuery: activeQuery,
                        currentMatchID: currentMatchID,
                        scrollTargetID: scrollTargetID,
                        scrollToken: scrollToken,
                        onContinue: { ai.continueToolLoop() },
                        onCopyConversation: { ai.copyConversation() },
                        onSaveTranscript: { ai.saveTranscript() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsContentWell()

            DSRule()
            composer
        }
        .background(PaneFocusMarker(.ai))
        .onAppear {
            refreshKeyPresence()
            // Focus the composer when the pane is shown by the user, but
            // not on app launch (the canvas keeps focus then).
            if Date().timeIntervalSince(AppLaunch.date) > 2 {
                ai.focusRequest += 1
            }
            FocusRouter.shared.setFocusHandler(.ai, owner: handlerOwner.id) { ai.focusRequest += 1 }
            FocusRouter.shared.setZoomHandler(.ai, owner: handlerOwner.id) { step in
                if step > 0 { ai.increaseFontSize(settings: appSettings) } else { ai.decreaseFontSize(settings: appSettings) }
            } canZoom: { step in
                step > 0
                    ? appSettings.aiFontSize < AppSettings.aiMaxFontSize
                    : appSettings.aiFontSize > AppSettings.aiMinFontSize
            }
            // ⌘F with the AI pane focused searches the transcript rather
            // than opening Find Node on the canvas (Edit ▸ Search
            // Conversation…); ⌘G / ⇧⌘G then walk the matches.
            FocusRouter.shared.setFindHandler(.ai, owner: handlerOwner.id) { showSearch() }
            FocusRouter.shared.setFindStepHandler(.ai, owner: handlerOwner.id) { delta in
                stepMatch(delta)
            } canStep: {
                isSearching && !activeQuery.isEmpty && !visibleMessages.isEmpty
            }
        }
        .onDisappear {
            FocusRouter.shared.setFocusHandler(.ai, owner: handlerOwner.id, nil)
            FocusRouter.shared.setZoomHandler(.ai, owner: handlerOwner.id, nil)
            FocusRouter.shared.setFindHandler(.ai, owner: handlerOwner.id, nil)
            FocusRouter.shared.setFindStepHandler(.ai, owner: handlerOwner.id, nil)
        }
        .onChange(of: transcriptQuery) { _, _ in
            matchIndex = 0
            FocusRouter.shared.noteFindStateChanged()
        }
        .onChange(of: isSearching) { _, _ in FocusRouter.shared.noteFindStateChanged() }
        .onChange(of: visibleMessages.count) { _, _ in FocusRouter.shared.noteFindStateChanged() }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { paneWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in paneWidth = w }
            }
        )
        .onChange(of: appSettings.aiProvider) { _, _ in refreshKeyPresence() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshKeyPresence()
        }
    }

    // MARK: Header pieces

    /// Fixed-width slot for Stop. The button itself only exists while a
    /// request is in flight — so its ⌘. key equivalent is registered only
    /// then, and only when no solver run already owns ⌘. — but the slot
    /// never changes width, so nothing beside it moves.
    private var stopSlot: some View {
        ZStack {
            if ai.isBusy {
                Button {
                    ai.cancel()
                } label: {
                    // Word plus glyph while there is room; the glyph alone
                    // in a narrow pane, where the word would crowd out the
                    // provider chip.
                    if isCondensedHeader {
                        Image(systemName: DS.Symbol.stop)
                            .font(DS.Font.iconButton)
                            .imageScale(.medium)
                            .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                            .contentShape(Rectangle())
                    } else {
                        Label("Stop", systemImage: DS.Symbol.stop)
                            .font(DS.Font.chromeEmphasis)
                            .labelStyle(.titleAndIcon)
                            .frame(height: DS.Layout.controlHeight)
                            .padding(.horizontal, DS.Spacing.xs)
                    }
                }
                .buttonStyle(DSToolbarButtonStyle(tint: DS.Color.danger))
                .help(stopHelp)
                .accessibilityLabel(ai.isBusyElsewhere
                                    ? "Stop the request running for \(ai.busyTabTitle)"
                                    : "Stop request")
                .keyboardShortcut(terminal.activeRun == nil
                                  ? KeyboardShortcut(".", modifiers: .command)
                                  : nil)
                .transition(.opacity)
            }
        }
        .frame(width: isCondensedHeader
               ? DS.Layout.iconButtonWidth
               : DS.Layout.headerTransientSlotWidth)
        .dsAnimation(DS.Motion.quick, value: ai.isBusy)
    }

    /// Says WHICH request Stop stops — this tab's, or the one running for
    /// another tab — and which key does it (⌘. belongs to Run ▸ Stop while
    /// a solver runs).
    private var stopHelp: String {
        let what = ai.isBusyElsewhere
            ? "Stop the request running for “\(ai.busyTabTitle)” (not this tab's conversation)"
            : "Stop the current request"
        let key = terminal.activeRun == nil
            ? "\(KeyboardShortcutReference.key(for: .stop)), or Esc while the message field has focus"
            : "Esc while the message field has focus; \(KeyboardShortcutReference.key(for: .stop)) is stopping \(terminal.activeRun ?? "the run") right now"
        return "\(what) (\(key))"
    }

    /// Shown beside the chip while a request runs for ANOTHER tab: the
    /// chip stays honest about this tab and the badge says where the
    /// work is happening.
    private var elsewhereBadge: some View {
        DSBadge(text: "Working on \(ai.busyTabTitle)", dot: DS.Color.accent, dotRing: true,
                dotSymbol: DS.Symbol.pending)
            .frame(maxWidth: DS.Layout.chipMaxWidth)
            .help("The assistant is answering a question asked in the “\(ai.busyTabTitle)” tab. Its reply lands there; this tab can send once it finishes, or Stop cancels it.")
            .accessibilityLabel("Working on \(ai.busyTabTitle) in another tab")
            .transition(.opacity)
    }

    /// True while the pane is too narrow for the full header control set.
    private var isCondensedHeader: Bool { paneWidth < DS.Layout.headerCondenseWidthNarrow }

    /// Names the network this conversation is about. Each tab keeps its
    /// own conversation, so the badge changes with the tab.
    private var networkBadge: some View {
        DSBadge(text: ai.boundNetworkName, tint: DS.Color.textSecondary)
            .frame(maxWidth: DS.Layout.chipMaxWidth)
            .help("This conversation is about \(ai.boundNetworkName). Each tab keeps its own conversation; switch tabs to see the others.")
            .accessibilityLabel("Conversation about \(ai.boundNetworkName)")
    }

    /// The header's least-used controls, folded into one menu when the
    /// pane is too narrow to show them all (the same degrade-gracefully
    /// rule the status bar uses when it swaps words for symbols).
    private var overflowMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.more,
            label: "More AI pane controls",
            help: "Code font and text size"
        ) {
            Button("Increase Text Size") { ai.increaseFontSize(settings: appSettings) }
                .disabled(appSettings.aiFontSize >= AppSettings.aiMaxFontSize)
            Button("Decrease Text Size") { ai.decreaseFontSize(settings: appSettings) }
                .disabled(appSettings.aiFontSize <= AppSettings.aiMinFontSize)
            Divider()
            Picker("Code Font", selection: $appSettings.aiFontName) {
                Text("System Monospaced").tag("")
                ForEach(MonospaceFontMenu.monospaceFamilies(), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
        }
    }

    // MARK: Search

    /// Messages the transcript shows. Everything while no search is
    /// active; only matching turns (and the tool rows whose name, input
    /// or result matches) while one is.
    private var visibleMessages: [AIMessage] {
        let q = activeQuery
        guard !q.isEmpty else { return ai.messages }
        return ai.messages.filter { Self.matches($0, query: q) }
    }

    /// The query the transcript is being filtered and highlighted by —
    /// empty while the search row is closed.
    private var activeQuery: String {
        guard isSearching else { return "" }
        return transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message Return / ⌘G last stepped to, marked in the transcript.
    private var currentMatchID: UUID? {
        guard !activeQuery.isEmpty, !visibleMessages.isEmpty else { return nil }
        return visibleMessages[min(matchIndex, visibleMessages.count - 1)].id
    }

    /// "k of n" for the search field: the match Return / ⌘G last stepped
    /// to, of the messages that match — the same meaning the readout has
    /// in the Status pane and in Settings.
    private var matchStatus: String? {
        guard !activeQuery.isEmpty else { return nil }
        let total = visibleMessages.count
        guard total > 0 else { return nil }
        return "\(min(matchIndex, total - 1) + 1) of \(total)"
    }

    /// Return / ⌘G / ⇧⌘G: scroll the next (previous) matching message
    /// into view and mark it.
    private func stepMatch(_ delta: Int) {
        let total = visibleMessages.count
        guard total > 0 else { return }
        matchIndex = (min(matchIndex, total - 1) + delta + total) % total
        scrollTargetID = visibleMessages[matchIndex].id
        scrollToken += 1
    }

    /// Escape, or the close button: the row goes away and every message
    /// comes back.
    private func closeSearch() {
        withAnimation(a11y.animation(DS.Motion.quick)) {
            isSearching = false
            transcriptQuery = ""
        }
        matchIndex = 0
    }

    private static func matches(_ message: AIMessage, query: String) -> Bool {
        if message.text.localizedCaseInsensitiveContains(query) { return true }
        guard let call = message.toolCall else { return false }
        return call.name.localizedCaseInsensitiveContains(query)
            || call.inputText.localizedCaseInsensitiveContains(query)
            || (call.result?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func showSearch() {
        withAnimation(a11y.animation(DS.Motion.quick)) { isSearching = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    private var searchRow: some View {
        HStack(spacing: DS.Spacing.s) {
            // The "k of n" readout lives inside the field (DSSearchField's
            // `status:` slot). Escape does not merely empty the field — it
            // closes the search, which is what the close button's tooltip
            // promises — so the field's own Escape handling is off and the
            // row handles the key itself.
            DSSearchField(
                text: $transcriptQuery,
                placeholder: "Search conversation",
                shortcutHint: "⌘F",
                help: "Show only the messages that contain this text, highlighted; Return, ⌘G and ⇧⌘G step through them",
                status: matchStatus,
                accessibilityLabel: "Search the conversation",
                escapeClears: false,
                focus: $searchFocused,
                onSubmit: { stepMatch(+1) }
            )
            DSIconButton(
                systemImage: DS.Symbol.remove,
                label: "Close Search",
                help: "Close the search and show every message (Escape)"
            ) { closeSearch() }
        }
        .dsChromeBar(.bottom, horizontal: DS.Spacing.s, height: DS.Layout.filterRowHeight)
        .onExitCommand { closeSearch() }
        .transition(.opacity)
    }

    // MARK: Starter panel

    /// Shown when a backend IS configured and nothing has been said yet:
    /// names the model in use and offers three prompts drawn from what the
    /// tool registry actually exposes. Clicking one fills the composer.
    private var showStarterPanel: Bool {
        isConfigured && ai.isEmptyTranscript
    }

    private static let starterPrompts = [
        "Summarise this network",
        "Which stations are unstable?",
        "Run QNA and explain the ρ values"
    ]

    private var starterPanel: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: DS.Symbol.assistant)
                .font(DS.Font.largeTitle)
                .foregroundStyle(DS.Color.accent)
                .accessibilityHidden(true)
            Text("Ask \(modelName.isEmpty ? providerShortName : modelName) about \(ai.boundNetworkName)")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text("The assistant can read this tab's canvas, change it, and run any solver from the Run menu. Each tab keeps its own conversation.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Layout.popoverMinWidth)
            VStack(spacing: DS.Spacing.xs) {
                ForEach(Self.starterPrompts, id: \.self) { prompt in
                    Button {
                        ai.input = prompt
                        ai.focusRequest += 1
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(prompt)
                                .font(DS.Font.label)
                                .lineLimit(1)
                            Spacer(minLength: DS.Spacing.xs)
                            Image(systemName: DS.Symbol.next)
                                .font(DS.Font.chevron)
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                        .frame(maxWidth: DS.Layout.popoverMinWidth)
                    }
                    .buttonStyle(DSPaletteButtonStyle(isSelected: false))
                    .help("Put “\(prompt)” in the message field")
                    .accessibilityLabel("Example prompt: \(prompt)")
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No messages yet")
    }

    private func refreshKeyPresence() {
        apiKeyPresent = !LLMKeychain.load(for: provider).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Copy Conversation / Save Transcript… — a pop-up menu drawn as one
    /// more icon button in the header row.
    private var exportMenu: some View {
        DSIconMenu(
            systemImage: DS.Symbol.export,
            label: "Export conversation",
            help: "Copy the conversation as Markdown, or save it to a file"
        ) {
            Button("Copy Conversation") { ai.copyConversation() }
            Button("Save Transcript…") { ai.saveTranscript() }
        }
        .disabled(ai.exchangeCount == 0)
    }

    /// Clearing a long conversation asks first (same pattern as Restart
    /// Shell); a short one clears immediately. Never available while a
    /// request runs for THIS tab (another tab's request is unaffected).
    private func confirmClear() {
        guard !ai.isBusyForActiveTab else { return }
        if ai.exchangeCount <= 4 {
            ai.clear()
            return
        }
        guard ConfirmAlert.destructive(
            title: "Clear the conversation?",
            message: "All \(ai.exchangeCount) messages and the assistant's context will be discarded. Save Transcript… keeps a copy first.",
            confirmTitle: "Clear Conversation"
        ) else { return }
        ai.clear()
    }

    // MARK: Header chip

    private var providerChip: some View {
        Button {
            openSettingsPane(SettingsView.Tab.ai.rawValue)
        } label: {
            DSBadge(text: chipText, dot: backendStatus.color,
                    dotRing: backendStatus == .busy, dotSymbol: backendStatus.symbol)
                .padding(.horizontal, DS.Spacing.xxs)
        }
        // Same hover / pressed / disabled washes as every other control in
        // the header — the chip is a button and must look like one.
        .buttonStyle(DSToolbarButtonStyle())
        .frame(maxWidth: DS.Layout.chipMaxWidth)
        .help("\(providerShortName) · \(modelName.isEmpty ? "no model" : modelName)\nStatus: \(backendStatus.label)\nClick to open Settings ▸ AI Assistant")
        .accessibilityLabel("AI backend: \(providerShortName), \(modelName.isEmpty ? "no model" : modelName), \(backendStatus.label)")
    }

    private var providerShortName: String {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .ollama:    return "Ollama"
        case .lmstudio:  return "LM Studio"
        }
    }

    private var chipText: String {
        switch backendStatus {
        case .notConfigured: return "\(providerShortName) · not configured"
        case .missingKey:    return "\(providerShortName) · \(modelName) · no key"
        default:             return "\(providerShortName) · \(modelName)"
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        DSEmptyState(
            systemImage: DS.Symbol.assistant,
            title: "No AI Backend Configured",
            message: backendStatus == .missingKey
                ? "\(providerShortName) needs an API key. Add it in Settings ▸ AI Assistant."
                : "Choose a provider and model in Settings ▸ AI Assistant to chat about the current network and run solvers by name.",
            actionTitle: "Open AI Settings…",
            keyboardShortcut: KeyboardShortcut(",", modifiers: [.command, .option]),
            action: { openSettingsPane(SettingsView.Tab.ai.rawValue) }
        )
    }

    // MARK: Composer

    @DSAccessibility private var a11y

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.s) {
            AIComposerTextView(
                text: $ai.input,
                // Prose is proportional at the transcript size; the
                // monospaced family is reserved for code.
                font: NSFont.systemFont(ofSize: CGFloat(appSettings.aiFontSize)),
                placeholder: composerPlaceholder,
                focusRequest: ai.focusRequest,
                onSubmit: { ai.submit() },
                onEscape: {
                    if ai.isBusyForActiveTab { ai.cancel() } else { FocusRouter.shared.focus(.canvas) }
                }
            )
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Color.fieldBackground)
            )
            // `strokeBorder` keeps the bezel inside the well; the focus
            // ring is the shared `dsFocusRing`, a soft halo drawn OUTSIDE
            // the bezel the way AppKit draws it (DSSearchField, DSTextArea
            // and this composer are the one treatment).
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(focusRouter.focusedPane == .ai ? DS.Color.accentStroke
                                                                  : DS.Color.separator(a11y.contrast),
                                  lineWidth: DS.Stroke.hairline(a11y.contrast))
            )
            .dsFocusRing(focusRouter.focusedPane == .ai, radius: DS.Radius.panel)
            .dsAnimation(DS.Motion.quick, value: focusRouter.focusedPane == .ai)

            Button {
                ai.submit()
            } label: {
                Image(systemName: DS.Symbol.send)
                    .font(DS.Font.chromeEmphasis)
                    .frame(width: DS.Layout.controlHeight, height: DS.Layout.controlHeight)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(ai.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.isBusy)
            .help(sendHelp)
            .accessibilityLabel("Send message")
        }
        .padding(DS.Spacing.s)
        .background(DS.Color.surface)
    }

    /// The composer says why it is waiting when it is: the client runs
    /// one request at a time, and while that request belongs to another
    /// tab the placeholder names it rather than leaving Send dimmed
    /// without a word.
    private var composerPlaceholder: String {
        guard isConfigured else { return "Configure a backend to start chatting" }
        if ai.isBusyElsewhere {
            return "Waiting for the request in “\(ai.busyTabTitle)” to finish…"
        }
        return "Ask about \(ai.boundNetworkName)…  (⇧↩ for a new line)"
    }

    private var sendHelp: String {
        if ai.isBusyElsewhere {
            return "Send (↩) — available once the request running for “\(ai.busyTabTitle)” finishes, or after Stop"
        }
        if ai.isBusyForActiveTab { return "Send (↩) — waiting for the current reply" }
        return "Send (↩)"
    }
}

// MARK: - Transcript

/// Message rows with role styling, tool-call disclosure, a progress
/// row while the model works, and auto-scroll that only follows new
/// content while the user is already reading the tail.
///
/// Typography: prose is proportional (`DS.Font.userProse(size:)`) at
/// `fontSize`; fenced code and tool input / results use `monoFont`, the
/// family chosen in the header's font menu at the same size.
private struct AITranscriptView: View {
    let messages: [AIMessage]
    let isBusy: Bool
    let busyPhase: String
    let fontSize: Double
    let monoFont: Font
    /// Live search query (empty when not searching): every hit is washed
    /// in the accent tint inside the rows, so a match deep in a long
    /// reply is visible and not merely implied by the row still showing.
    let searchQuery: String
    /// The match Return / ⌘G last stepped to; its row carries an accent
    /// rule on its leading edge.
    let currentMatchID: UUID?
    /// Row to scroll into view, bumped with `scrollToken`.
    let scrollTargetID: UUID?
    let scrollToken: Int
    let onContinue: () -> Void
    @DSAccessibility private var a11y
    let onCopyConversation: () -> Void
    let onSaveTranscript: () -> Void

    @State private var isPinnedToBottom = true
    @State private var lastContentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "ai.bottom"

    private struct ContentMetrics: Equatable {
        var height: CGFloat
        var maxY: CGFloat
    }

    private struct ContentMetricsKey: PreferenceKey {
        static let defaultValue = ContentMetrics(height: 0, maxY: 0)
        static func reduce(value: inout ContentMetrics, nextValue: () -> ContentMetrics) {
            value = nextValue()
        }
    }

    /// Whether to show the progress row (not while a message is
    /// actively streaming text — the caret already shows activity).
    private var showProgressRow: Bool {
        isBusy && !(messages.last?.isStreaming ?? false)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.s) {
                    ForEach(messages) { message in
                        AIMessageRow(
                            message: message,
                            fontSize: fontSize,
                            monoFont: monoFont,
                            searchQuery: searchQuery,
                            isCurrentMatch: message.id == currentMatchID,
                            onContinue: onContinue
                        )
                        .id(message.id)
                    }
                    if showProgressRow {
                        HStack(spacing: DS.Spacing.s) {
                            ProgressView()
                                .controlSize(.small)
                            Text(busyPhase.isEmpty ? "Thinking…" : busyPhase)
                                .font(DS.Font.chrome)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .padding(.horizontal, DS.Spacing.s)
                        .accessibilityLabel(busyPhase.isEmpty ? "Thinking" : busyPhase)
                    }
                    Color.clear
                        .frame(height: DS.Layout.scrollSentinelHeight)
                        .id(Self.bottomID)
                }
                .padding(.vertical, DS.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ContentMetricsKey.self,
                            value: ContentMetrics(
                                height: g.size.height,
                                maxY: g.frame(in: .named("ai.transcript")).maxY
                            )
                        )
                    }
                )
                // Background context menu: whole-conversation actions.
                // Rows carry their own "Copy Message" menu on top.
                .contextMenu {
                    Button("Copy Conversation") { onCopyConversation() }
                    Button("Save Transcript…") { onSaveTranscript() }
                }
            }
            .coordinateSpace(name: "ai.transcript")
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { viewportHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in viewportHeight = h }
                }
            )
            .onPreferenceChange(ContentMetricsKey.self) { metrics in
                // A height change means new content arrived: follow it
                // only if we were pinned. Otherwise the change came from
                // the user scrolling, so re-derive the pinned state.
                if abs(metrics.height - lastContentHeight) > 0.5 {
                    lastContentHeight = metrics.height
                    if isPinnedToBottom {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                } else {
                    isPinnedToBottom = (metrics.maxY - viewportHeight) < 32
                }
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: scrollToken) { _, _ in
                guard let id = scrollTargetID else { return }
                isPinnedToBottom = false
                withAnimation(DS.Motion.quick) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    Button {
                        isPinnedToBottom = true
                        withAnimation(DS.Motion.standard) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: DS.Symbol.download)
                            .font(DS.Font.chromeEmphasis)
                            .frame(width: DS.Layout.controlHeight, height: DS.Layout.controlHeight)
                            .background(Circle().fill(DS.Color.surface))
                            .overlay(Circle().stroke(DS.Color.separator(a11y.contrast),
                                                     lineWidth: DS.Stroke.hairline(a11y.contrast)))
                    }
                    .buttonStyle(.plain)
                    .padding(DS.Spacing.s)
                    .dsTooltip("Scroll to latest message")
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Rows

private struct AIMessageRow: View {
    let message: AIMessage
    let fontSize: Double
    let monoFont: Font
    /// Live search query, highlighted in place (empty when not searching).
    let searchQuery: String
    /// True for the match Return / ⌘G last stepped to.
    let isCurrentMatch: Bool
    let onContinue: () -> Void

    @State private var isHovering = false
    @DSAccessibility private var a11y

    /// Timestamp caption that appears on hover beside user and assistant
    /// rows. Always laid out (opacity only) so nothing shifts.
    private var timeCaption: some View {
        Text(message.timeString)
            .font(DS.Font.userProseCaption(size: fontSize))
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .dsAnimation(DS.Motion.quick, value: isHovering)
            .accessibilityHidden(true)
    }

    var body: some View {
        content
            // The current search match: one accent rule on the leading
            // edge, the same mark the tab strip uses for a drop target.
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.accent)
                    .frame(width: DS.Stroke.selection)
                    .padding(.vertical, DS.Spacing.xxs)
                    .opacity(isCurrentMatch ? 1 : 0)
                    .dsAnimation(DS.Motion.quick, value: isCurrentMatch)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom, spacing: DS.Spacing.s) {
                Spacer(minLength: DS.Spacing.xxl)
                timeCaption
                Text(message.text.highlightingMatches(of: searchQuery))
                    .font(DS.Font.userProse(size: fontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                            .fill(DS.Color.selectionFill(a11y.contrast))
                    )
                    .contextMenu { copyItem }
                    .accessibilityLabel("You, \(message.timeString): \(message.text)")
            }
            .padding(.horizontal, DS.Spacing.s)
            .onHover { isHovering = $0 }
            .help("Sent \(message.fullTimeString)")

        case .assistant:
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Image(systemName: DS.Symbol.assistant)
                    .font(DS.Font.chromeEmphasis)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: DS.Spacing.l, height: DS.Spacing.l + DS.Spacing.xxs)
                    .accessibilityHidden(true)
                if message.isStreaming {
                    // Plain text while deltas arrive; the Markdown layout
                    // is applied once, on completion, so blocks do not
                    // re-flow on every token.
                    Text(message.text + " ▍")
                        .font(DS.Font.userProse(size: fontSize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { copyItem }
                        .accessibilityLabel("Assistant, streaming: \(message.text)")
                } else {
                    AIMarkdownView(text: message.text, fontSize: fontSize, monoFont: monoFont, highlight: searchQuery)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { copyItem }
                        .accessibilityLabel("Assistant, \(message.timeString): \(message.text)")
                }
                timeCaption
                    .padding(.top, DS.Spacing.xxs)
            }
            .padding(.horizontal, DS.Spacing.s)
            .onHover { isHovering = $0 }
            .help("Received \(message.fullTimeString)")

        case .system:
            VStack(spacing: DS.Spacing.xs) {
                HStack {
                    Spacer(minLength: 0)
                    // System notes scale with the transcript, one step
                    // below the prose, so the whole pane reads at one size.
                    Text(message.text.highlightingMatches(of: searchQuery))
                        .font(DS.Font.userProseCaption(size: fontSize + 1))
                        .foregroundStyle(message.text.hasPrefix("⚠") ? DS.Color.warningText : DS.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .contextMenu { copyItem }
                    Spacer(minLength: 0)
                }
                if message.action == .continueToolLoop {
                    Button {
                        onContinue()
                    } label: {
                        Label("Continue", systemImage: DS.Symbol.run)
                    }
                    .controlSize(.small)
                    .help("Let the assistant keep working with the same conversation")
                    .accessibilityLabel("Continue the assistant's work")
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.xxs)
            .help(message.fullTimeString)

        case .tool(let call):
            AIToolCallRow(call: call, monoFont: monoFont, highlight: searchQuery)
                .padding(.horizontal, DS.Spacing.s)
                .help(message.fullTimeString)
        }
    }

    private var copyItem: some View {
        Button("Copy Message") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(message.text, forType: .string)
        }
    }
}

// MARK: - Code well

/// The one scrolling code surface in the transcript: fenced code blocks
/// and tool-call input / result panes. Content taller than `maxHeight`
/// scrolls on BOTH axes inside the cap (a horizontal-only scroller would
/// leave the tail of a long result unreachable), and a well longer than
/// `DS.Layout.wellExpandLineCount` lines offers "Show all N lines", which
/// lifts the cap so the transcript itself scrolls it. Selection and the
/// Copy menu are always available.
private struct AICodeWell: View {
    let text: String
    let monoFont: Font
    var maxHeight: CGFloat = DS.Layout.codeWellMaxHeight
    var fill: Color = DS.Color.surfaceRaised
    var bordered: Bool = true
    var accessibilityName: String = "Code block"
    /// Search query to highlight inside the block (empty for none).
    var highlight: String = ""

    @State private var expanded = false
    @DSAccessibility private var a11y

    private var lineCount: Int {
        text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var isLong: Bool { lineCount > DS.Layout.wellExpandLineCount }

    private var content: some View {
        Text(text.highlightingMatches(of: highlight))
            .font(monoFont)
            .textSelection(.enabled)
            .padding(DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Group {
                if expanded {
                    // Uncapped: the block takes its natural height and the
                    // transcript scrolls it; only overlong lines scroll here.
                    ScrollView(.horizontal, showsIndicators: true) { content }
                } else {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) { content }
                        .frame(maxHeight: maxHeight)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
                }
            }
            .contextMenu {
                Button("Copy") { AICodeWell.copy(text) }
            }
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(text)

            if isLong {
                Button {
                    withAnimation(DS.Motion.quick) { expanded.toggle() }
                } label: {
                    Label(
                        expanded ? "Show less" : "Show all \(lineCount) lines",
                        systemImage: expanded ? DS.Symbol.collapse : DS.Symbol.expand
                    )
                    .font(DS.Font.chrome)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.horizontal, DS.Spacing.xs)
                }
                .buttonStyle(DSToolbarButtonStyle())
                .help(expanded
                      ? "Collapse this block back to a scrolling excerpt"
                      : "Expand this block to its full \(lineCount) lines")
                .accessibilityLabel(expanded ? "Show less" : "Show all \(lineCount) lines")
            }
        }
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Markdown renderer

/// Renders an assistant reply as Markdown blocks. Foundation's
/// `AttributedString(markdown:)` with `.full` syntax parses headings,
/// lists, block quotes, thematic breaks, tables and fenced code into
/// `presentationIntent` runs; SwiftUI's `Text` only draws inline styles,
/// so each block is laid out here as its own view: prose blocks in the
/// proportional transcript font, tables as a `Grid`, fenced code in
/// `monoFont` inside an `AICodeWell`. Inline `code` spans are re-fonted
/// to `monoFont` so they match the fenced blocks. Parse failures fall
/// back to plain text.
private struct AIMarkdownView: View {
    let text: String
    let fontSize: Double
    let monoFont: Font
    /// Search query to highlight (empty for none). Applied AFTER the block
    /// cache — to each block's attributed text at render time — so the
    /// parse memo is keyed by the message text alone and typing a query
    /// never re-parses a 400-line reply.
    var highlight: String = ""
    @DSAccessibility private var a11y

    /// One parsed Markdown table: an optional header row, the body rows
    /// and one alignment per column (`.leading` when the source did not
    /// say, which the renderer may still override for numeric columns).
    struct MarkdownTable {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var alignments: [TextAlignment] = []

        var columnCount: Int {
            max(header.count, rows.map(\.count).max() ?? 0)
        }

        /// Tab-separated rendering for "Copy Table (TSV)" — pastes
        /// straight into a spreadsheet or a plot script.
        var tsv: String {
            var lines: [String] = []
            if !header.isEmpty {
                lines.append(header.map { String($0.characters) }.joined(separator: "\t"))
            }
            for row in rows {
                lines.append(row.map { String($0.characters) }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        }
    }

    private enum Block {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case listItem(marker: String, depth: Int, AttributedString)
        case quote(AttributedString)
        case code(String)
        case table(MarkdownTable)
        case rule
    }

    private struct IndexedBlock: Identifiable {
        let id: Int
        let block: Block
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(blocks) { item in
                render(item.block)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(styled(s))
                .font(DS.Font.userProse(size: fontSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let s):
            // Headings keep the heading face throughout: a monospaced
            // inline span at the prose size inside a 1.45× heading would
            // read as a typo, not as code.
            Text(s.highlightingMatches(of: highlight))
                .font(DS.Font.userProseHeading(size: fontSize, level: level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? DS.Spacing.xs : 0)
                .accessibilityAddTraits(.isHeader)

        case .listItem(let marker, let depth, let s):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(marker)
                    .font(DS.Font.userProse(size: fontSize).monospacedDigit())
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(minWidth: DS.Spacing.l, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(styled(s))
                    .font(DS.Font.userProse(size: fontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * DS.Spacing.l)

        case .quote(let s):
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                RoundedRectangle(cornerRadius: DS.Radius.swatch)
                    .fill(DS.Color.controlBorder(a11y.contrast))
                    .frame(width: DS.Stroke.focusRing)
                Text(styled(s))
                    .font(DS.Font.userProse(size: fontSize))
                    .foregroundStyle(DS.Color.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code):
            AICodeWell(text: code, monoFont: monoFont, highlight: highlight)

        case .table(let table):
            tableView(table)

        case .rule:
            DSRule()
        }
    }

    // MARK: Table

    /// A Markdown table as a `Grid`: header row in semibold with a rule
    /// beneath, numeric columns right-aligned with monospaced digits, and
    /// horizontal scrolling so a wide table never widens the pane.
    private func tableView(_ table: MarkdownTable) -> some View {
        let columns = max(table.columnCount, 1)
        let alignments = (0..<columns).map { alignment(for: $0, in: table) }
        return ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(table.header.indices.contains(c) ? table.header[c] : AttributedString(),
                                 alignment: alignments[c], isHeader: true)
                        }
                    }
                    DSRule()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(columns)
                }
                ForEach(table.rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(table.rows[r].indices.contains(c) ? table.rows[r][c] : AttributedString(),
                                 alignment: alignments[c], isHeader: false)
                        }
                    }
                }
            }
            .padding(.vertical, DS.Spacing.xxs)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
        )
        .contextMenu {
            Button("Copy Table (TSV)") { AICodeWell.copy(table.tsv) }
        }
        .accessibilityLabel("Table, \(table.rows.count) rows, \(columns) columns")
    }

    private func cell(_ s: AttributedString, alignment: TextAlignment, isHeader: Bool) -> some View {
        let base = DS.Font.userProse(size: fontSize)
        let numeric = Self.isNumericText(String(s.characters))
        return Text(styled(s))
            .font(isHeader ? base.weight(.semibold) : (numeric ? base.monospacedDigit() : base))
            .multilineTextAlignment(alignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .frame(minWidth: DS.Layout.tableCellMinWidth,
                   alignment: alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading))
    }

    /// The source alignment when the table declared one; otherwise
    /// `.trailing` for a column whose body cells are all numbers (the
    /// per-station ρ / Γ tables the assistant emits), else `.leading`.
    private func alignment(for column: Int, in table: MarkdownTable) -> TextAlignment {
        if table.alignments.indices.contains(column), table.alignments[column] != .leading {
            return table.alignments[column]
        }
        let cells = table.rows
            .compactMap { $0.indices.contains(column) ? String($0[column].characters) : nil }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cells.isEmpty, cells.allSatisfy(Self.isNumericText) { return .trailing }
        return .leading
    }

    private static func isNumericText(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "%", with: "")
        t = t.replacingOccurrences(of: ",", with: "")
        guard !t.isEmpty else { return false }
        return Double(t) != nil
    }

    // MARK: Inline styling

    /// Draws inline `code` spans in the transcript's code font, so a
    /// `rho_1` inside a sentence matches the fenced blocks and the tool
    /// output instead of falling back to SwiftUI's default monospace.
    private func inlineStyled(_ s: AttributedString) -> AttributedString {
        var out = s
        let ranges: [Range<AttributedString.Index>] = out.runs[\.inlinePresentationIntent]
            .compactMap { intent, range in
                guard let intent, intent.contains(.code) else { return nil }
                return range
            }
        for r in ranges { out[r].font = monoFont }
        return out
    }

    /// Inline code font plus the search highlight, in that order.
    private func styled(_ s: AttributedString) -> AttributedString {
        inlineStyled(s).highlightingMatches(of: highlight)
    }

    /// Memo of parsed blocks, keyed by the message text. `blocks` is read
    /// on every body evaluation, and a row's body runs far more often than
    /// once: `isHovering` flips twice per pointer pass and every A+ / A−
    /// re-renders every visible row. Without the memo a 400-line reply
    /// paid for a full `AttributedString(markdown:)` plus a run-by-run
    /// intent walk each time. Bounded to the most recent
    /// `limit` distinct texts so a long session cannot grow it without end.
    private final class BlockCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: [Block]] = [:]
        private var order: [String] = []
        private let limit = 64

        func blocks(for text: String) -> [Block] {
            lock.lock()
            if let hit = storage[text] {
                lock.unlock()
                return hit
            }
            lock.unlock()
            let parsed = AIMarkdownView.parse(text)
            lock.lock()
            if storage[text] == nil {
                storage[text] = parsed
                order.append(text)
                if order.count > limit {
                    let evicted = order.removeFirst()
                    storage.removeValue(forKey: evicted)
                }
            }
            lock.unlock()
            return parsed
        }
    }

    private static let cache = BlockCache()

    private var blocks: [IndexedBlock] {
        Self.cache.blocks(for: text)
            .enumerated()
            .map { IndexedBlock(id: $0.offset, block: $0.element) }
    }

    /// Accumulates the cells of one table while its runs stream past.
    private struct TableBuilder {
        let identity: Int
        var alignments: [TextAlignment]
        var header: [Int: AttributedString] = [:]
        var rowOrder: [Int] = []
        var rows: [Int: [Int: AttributedString]] = [:]

        mutating func add(_ slice: AttributedString, row: Int, column: Int, isHeader: Bool) {
            var trimmed = slice
            while let last = trimmed.characters.last, last == "\n" {
                trimmed.removeSubrange(trimmed.index(beforeCharacter: trimmed.endIndex)..<trimmed.endIndex)
            }
            if isHeader {
                header[column, default: AttributedString()].append(trimmed)
            } else {
                if rows[row] == nil {
                    rows[row] = [:]
                    rowOrder.append(row)
                }
                rows[row]?[column, default: AttributedString()].append(trimmed)
            }
        }

        func build() -> MarkdownTable? {
            guard !header.isEmpty || !rowOrder.isEmpty else { return nil }
            let headerWidth = (header.keys.max().map { $0 + 1 }) ?? 0
            let bodyWidth = rowOrder.compactMap { rows[$0]?.keys.max().map { $0 + 1 } }.max() ?? 0
            let width = max(headerWidth, bodyWidth)
            guard width > 0 else { return nil }
            func flatten(_ cells: [Int: AttributedString]) -> [AttributedString] {
                (0..<width).map { cells[$0] ?? AttributedString() }
            }
            return MarkdownTable(
                header: header.isEmpty ? [] : flatten(header),
                rows: rowOrder.map { flatten(rows[$0] ?? [:]) },
                alignments: alignments
            )
        }
    }

    nonisolated private static func parse(_ text: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [.paragraph(AttributedString(text))]
        }

        var blocks: [Block] = []
        var builder: TableBuilder?

        func flushTable() {
            if let table = builder?.build() { blocks.append(.table(table)) }
            builder = nil
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let slice = AttributedString(parsed[range])
            guard let intent else {
                // No block intent (rare with `.full`): plain paragraph.
                flushTable()
                if !String(slice.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.paragraph(slice))
                }
                continue
            }

            var headingLevel: Int?
            var isCode = false
            var isQuote = false
            var isRule = false
            var listDepth = 0
            var ordinal: Int?
            var ordered = false
            var tableIdentity: Int?
            var tableAlignments: [TextAlignment] = []
            var rowIdentity: Int?
            var isHeaderRow = false
            var columnIndex: Int?
            // Components are ordered innermost → outermost.
            for component in intent.components {
                switch component.kind {
                case .header(let level):         headingLevel = level
                case .codeBlock:                 isCode = true
                case .blockQuote:                isQuote = true
                case .thematicBreak:             isRule = true
                case .listItem(let o):
                    if ordinal == nil { ordinal = o }
                case .orderedList:
                    listDepth += 1
                    if listDepth == 1 { ordered = true }
                case .unorderedList:             listDepth += 1
                case .table(let columns):
                    tableIdentity = component.identity
                    tableAlignments = columns.map(Self.textAlignment(for:))
                case .tableHeaderRow:
                    rowIdentity = component.identity
                    isHeaderRow = true
                case .tableRow:
                    rowIdentity = component.identity
                case .tableCell(let c):
                    columnIndex = c
                default: break
                }
            }

            if let tableIdentity, let rowIdentity, let columnIndex {
                if builder?.identity != tableIdentity {
                    flushTable()
                    builder = TableBuilder(identity: tableIdentity, alignments: tableAlignments)
                }
                builder?.add(slice, row: rowIdentity, column: columnIndex, isHeader: isHeaderRow)
                continue
            }
            flushTable()

            if isRule {
                blocks.append(.rule)
            } else if isCode {
                var code = String(slice.characters)
                while code.hasSuffix("\n") { code.removeLast() }
                blocks.append(.code(code))
            } else if let level = headingLevel {
                blocks.append(.heading(level: level, slice))
            } else if listDepth > 0 {
                let marker: String
                if ordered, let ordinal { marker = "\(ordinal)." } else { marker = "•" }
                blocks.append(.listItem(marker: marker, depth: listDepth, slice))
            } else if isQuote {
                blocks.append(.quote(slice))
            } else {
                blocks.append(.paragraph(slice))
            }
        }
        flushTable()

        if blocks.isEmpty {
            return [.paragraph(AttributedString(text))]
        }
        return blocks
    }

    nonisolated private static func textAlignment(for column: PresentationIntent.TableColumn) -> TextAlignment {
        switch column.alignment {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        @unknown default: return .leading
        }
    }
}

/// Collapsed: symbol + tool name + duration. Expanded: arguments and
/// result in the transcript's monospaced font.
private struct AIToolCallRow: View {
    let call: AIToolCall
    let monoFont: Font
    /// Search query to highlight in the name, the summary and the wells.
    var highlight: String = ""
    @State private var expanded = false
    @DSAccessibility private var a11y

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Input")
                    .font(DS.Font.chromeEmphasis)
                    .foregroundStyle(DS.Color.textSecondary)
                codeBlock(call.inputText, name: "Input to \(call.name)")
                if let result = call.result {
                    Text(call.isError ? "Error" : "Result")
                        .font(DS.Font.chromeEmphasis)
                        .foregroundStyle(call.isError ? DS.Color.dangerText : DS.Color.textSecondary)
                    codeBlock(result, name: "\(call.isError ? "Error" : "Result") from \(call.name)")
                }
            }
            .padding(.top, DS.Spacing.xs)
        } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: symbolName)
                    .font(DS.Font.chromeEmphasis)
                    .foregroundStyle(symbolColor)
                    .frame(width: DS.Spacing.l)
                Text(call.name.highlightingMatches(of: highlight))
                    .font(DS.Font.monoCallout)
                    .lineLimit(1)
                if !call.inputSummary.isEmpty {
                    Text(call.inputSummary.highlightingMatches(of: highlight))
                        .font(DS.Font.chrome)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Spacing.xs)
                if call.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let d = call.duration {
                    Text(AIModel.format(duration: d))
                        .font(DS.Font.numberSmall)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast)))
        )
        .help(call.isRunning ? "Running \(call.name)…" : "\(call.name) — \(call.isError ? "failed" : "completed")\(call.duration.map { " in \(AIModel.format(duration: $0))" } ?? "")")
        .accessibilityLabel("Tool call \(call.name), \(call.isRunning ? "running" : (call.isError ? "failed" : "completed"))")
    }

    private var symbolName: String {
        if call.isRunning { return DS.Symbol.toolCall }
        return call.isError ? DS.Symbol.failure : DS.Symbol.success
    }

    private var symbolColor: Color {
        if call.isRunning { return DS.Color.textSecondary }
        return call.isError ? DS.Color.dangerText : DS.Color.successText
    }

    /// Tool input / result well. The same `AICodeWell` the transcript's
    /// fenced code uses, so a long `read_network` result scrolls in both
    /// directions inside the cap and can be expanded in place.
    private func codeBlock(_ text: String, name: String) -> some View {
        AICodeWell(
            text: text,
            monoFont: monoFont,
            maxHeight: DS.Layout.toolWellMaxHeight,
            fill: DS.Color.fieldBackground,
            bordered: false,
            accessibilityName: name,
            highlight: highlight
        )
    }
}

// MARK: - Composer text view

/// Multi-line composer: ↩ sends, ⇧↩ inserts a newline, Esc calls
/// `onEscape`. Grows from one to six lines with its content. An
/// NSTextView is used (rather than a vertical-axis TextField) so the
/// Return/Shift-Return split is exact and focus can be requested.
private struct AIComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let placeholder: String
    let focusRequest: Int
    let onSubmit: () -> Void
    let onEscape: () -> Void

    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = .textColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 2
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholderString = placeholder
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        tv.string = text
        tv.setAccessibilityLabel("Message to the AI assistant")

        scroll.documentView = tv
        scroll.textView = tv
        context.coordinator.textView = tv
        context.coordinator.recalculateHeight()
        return scroll
    }

    func updateNSView(_ nsView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.textView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.recalculateHeight()
        }
        if tv.font != font {
            tv.font = font
            context.coordinator.recalculateHeight()
        }
        tv.placeholderString = placeholder
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: context.coordinator.preferredHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerTextView
        weak var textView: ComposerTextView?
        var lastFocusRequest = 0
        private(set) var preferredHeight: CGFloat = 22

        init(parent: AIComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let lineHeight = lm.defaultLineHeight(for: tv.font ?? .systemFont(ofSize: 12))
            let minH = lineHeight + tv.textContainerInset.height * 2
            let maxH = lineHeight * AIComposerTextView.maxLines + tv.textContainerInset.height * 2
            let h = min(maxH, max(minH, used + tv.textContainerInset.height * 2))
            if abs(h - preferredHeight) > 0.5 {
                preferredHeight = h
                tv.enclosingScrollView?.invalidateIntrinsicContentSize()
                tv.needsDisplay = true
            }
        }
    }
}

/// Scroll view whose intrinsic height follows the composer text.
final class ComposerScrollView: NSScrollView {
    weak var textView: ComposerTextView?

    override var intrinsicContentSize: NSSize {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 22)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let lineHeight = lm.defaultLineHeight(for: tv.font ?? .systemFont(ofSize: 12))
        let minH = lineHeight + tv.textContainerInset.height * 2
        let maxH = lineHeight * 6 + tv.textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: min(maxH, max(minH, used + tv.textContainerInset.height * 2)))
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let inset = textContainerInset
        let pad = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: inset.width + pad, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
        case #selector(cancelOperation(_:)):
            onEscape?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }
}
