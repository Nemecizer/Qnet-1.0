import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The one confirmation idiom for window-level actions.
//
// Qnet has two kinds of "are you sure?":
//
//   • Window-level — Clear Canvas, Clear Status Log, Restart Shell, Clear
//     Conversation, Restore Tabs on quit. These are app-modal, may run with no SwiftUI
//     view in scope (the app delegate's quit handler) and must block the
//     action until answered: they use `NSAlert`, always through the helpers
//     below so the wording, button order and destructive styling match.
//
//   • Sheet-level — discarding unsaved edits inside an open inspector.
//     A second NSAlert over a sheet is bad form, so those keep SwiftUI's
//     `.confirmationDialog` (LinkParameterEditorSheet).
//
// Nothing else should build an NSAlert for a question. `showAlert` in
// QnetGUIApp stays for one-button error reports.
//
// House rules, applied here once:
//   • Title is a question ending in "?"; the message says what will be lost
//     and names the non-destructive alternative.
//   • The confirm button repeats the verb ("Clear Canvas"), never "OK".
//   • Cancel is second, so Escape and ⌘. cancel.
//   • Destructive actions use `.warning`; plain questions use `.informational`.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum ConfirmAlert {

    /// Answer to the Save / Don't Save / Cancel question.
    enum SaveChoice { case save, discard, cancel }

    /// The standard Mac "Do you want to save the changes…?" sheet-as-alert
    /// for closing a dirty document (a tab here). Buttons in the HIG
    /// order — Don't Save on the left, Cancel, Save as the default —
    /// with ⌘D for Don't Save and Escape / ⌘. for Cancel, exactly as
    /// TextEdit and Xcode lay it out. `hasFile` only changes the wording:
    /// an untitled network is told it has never been saved and that Save
    /// will ask where.
    static func saveChanges(documentTitle: String, hasFile: Bool) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(documentTitle)”?"
        alert.informativeText = hasFile
            ? "Your changes will be lost if you don’t save them."
            : "This network has never been saved. Your changes will be lost if you don’t save them; Save asks where to put the .bnet file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: hasFile ? "Save" : "Save…")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        dontSave.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Destructive confirmation: returns true when the user confirmed.
    @discardableResult
    static func destructive(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel"
    ) -> Bool {
        ask(title: title, message: message, confirmTitle: confirmTitle,
            cancelTitle: cancelTitle, style: .warning).confirmed
    }

    /// Two-way question with an optional "Do not ask again" checkbox.
    /// Returns the choice and whether the box was ticked.
    @discardableResult
    static func ask(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        style: NSAlert.Style = .informational,
        suppressionTitle: String? = nil
    ) -> (confirmed: Bool, suppress: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)

        var checkbox: NSButton?
        if let suppressionTitle {
            let box = NSButton(checkboxWithTitle: suppressionTitle, target: nil, action: nil)
            box.state = .off
            alert.accessoryView = box
            checkbox = box
        }

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return (confirmed, checkbox?.state == .on)
    }
}
