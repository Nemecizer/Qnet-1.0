import SwiftUI

/// The one empty-state placeholder, built on `ContentUnavailableView`
/// (macOS 14+) with DS typography. Used by the canvas, the Status pane,
/// the Inspector, the AI pane and Qnet Help so emptiness looks the same
/// everywhere.
///
/// Wording: `title` is a **Title Case noun phrase** — "No Selection",
/// "No Status Entries", "Status Log Cleared" — the HIG convention for
/// `ContentUnavailableView` ("No Mail", "No Results"); `message` is a
/// **sentence** with a full stop that says what will appear here or what
/// to do next. Five panes once mixed "No Selection" with "No status
/// entries" and "No network yet"; `design_lint.sh` now checks every
/// `DSEmptyState(title:)` literal for a lower-case word (articles and
/// prepositions excepted) so the rule is checked rather than remembered.
///
/// Use it as an `.overlay` on the container that will hold the content —
/// never as a conditional replacement of the container — so the layout
/// does not jump when the first item arrives.
///
/// The text block ignores hit-testing so clicks on an empty canvas still
/// reach the canvas gestures beneath; only the optional action button is
/// interactive. `keyboardShortcut` binds the action (e.g. ⌥⌘, for
/// "Open AI Settings…").
/// One offer in a `DSEmptyState`'s action row.
///
/// `prominent` marks the single primary. Two equally weighted buttons are
/// two buttons with no primary: the eye has to read both before it can
/// choose, so at most one offer in a row sets it. `help` is the sentence
/// the tooltip needs — never the title again, because a tooltip that
/// repeats the label tells the reader nothing they did not just read;
/// nil falls back to the title, which is what the single-action
/// initialiser has always done.
struct DSEmptyStateAction {
    let title: String
    let help: String?
    let prominent: Bool
    let keyboardShortcut: KeyboardShortcut?
    let action: () -> Void

    init(title: String,
         help: String? = nil,
         prominent: Bool = false,
         keyboardShortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.prominent = prominent
        self.keyboardShortcut = keyboardShortcut
        self.action = action
    }
}

struct DSEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: [DSEmptyStateAction]
    @DSAccessibility private var a11y

    init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        keyboardShortcut: KeyboardShortcut? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        if let actionTitle, let action {
            self.actions = [DSEmptyStateAction(title: actionTitle,
                                               keyboardShortcut: keyboardShortcut,
                                               action: action)]
        } else {
            self.actions = []
        }
    }

    /// The multi-offer form: the archetype/example pair on the empty
    /// canvas, and any future state that has a primary and a fallback.
    init(
        systemImage: String,
        title: String,
        message: String,
        actions: [DSEmptyStateAction]
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions
    }

    /// The one "no matches" state for a search or filter (Status pane,
    /// Settings sidebar, Qnet Help). Quotes the query so the user sees what
    /// was searched for.
    static func search(query: String) -> DSEmptyState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return DSEmptyState(
            systemImage: DS.Symbol.find,
            title: q.isEmpty ? "No Results" : "No Results for “\(q)”",
            message: "Check the spelling or try a different search."
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.textPrimary)
            } icon: {
                Image(systemName: systemImage)
                    .font(DS.Font.largeTitle)
                    .foregroundStyle(DS.Color.textTertiary(a11y.contrast))
            }
            .allowsHitTesting(false)
        } description: {
            Text(message)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(maxWidth: DS.Layout.popoverMinWidth)
                .allowsHitTesting(false)
        } actions: {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, offer in
                dsEmptyStateButton(offer)
            }
        }
        .padding(DS.Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(message)
        .transition(.opacity)
    }

    /// One offer, drawn the one way. The prominent fill lives here rather
    /// than in a caller so a second empty state cannot invent a third
    /// grammar for the same job.
    @ViewBuilder
    private func dsEmptyStateButton(_ offer: DSEmptyStateAction) -> some View {
        let button = Button(offer.title, action: offer.action)
            .controlSize(.regular)
            .dsTooltip(offer.help ?? offer.title)
        if let shortcut = offer.keyboardShortcut {
            if offer.prominent {
                button.keyboardShortcut(shortcut).buttonStyle(.borderedProminent)
            } else {
                button.keyboardShortcut(shortcut)
            }
        } else {
            if offer.prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button
            }
        }
    }
}
