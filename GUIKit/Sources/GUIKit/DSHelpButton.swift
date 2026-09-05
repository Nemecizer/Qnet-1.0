import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The Mac help control.
//
// A dialog that links to documentation shows the round "?" button in its
// bottom-left corner — System Settings, every Save panel, Xcode's sheets. It
// is an AppKit bezel (`NSButton.BezelStyle.helpButton`), so it is hosted
// rather than redrawn: the hover, pressed and disabled looks, the focus ring
// and the Increase Contrast treatment all come from the system, and the
// control is exactly the one users know from other apps.
//
// `DSSheetFooter(helpTopic:)` is the one place sheets adopt it, so every sheet
// gets the same control in the same corner.
// ─────────────────────────────────────────────────────────────────────────────

struct DSHelpButton: NSViewRepresentable {
    /// Short spoken name ("Help about the spectral method").
    let label: String
    /// Tooltip.
    let help: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator,
                              action: #selector(Coordinator.fire(_:)))
        button.bezelStyle = .helpButton
        button.setButtonType(.momentaryPushIn)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(help)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ sender: Any?) { action() }
    }
}
