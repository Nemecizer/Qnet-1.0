import SwiftUI
import AppKit
@preconcurrency import SwiftTerm

/// Left-hand tool palette.  Tools are grouped (selection · nodes · link)
/// with dividers; every button has a tooltip, a shortcut badge, hover and
/// pressed feedback, a clear selected state, and remains keyboard-focusable.
struct ToolPaletteView: View {
    @EnvironmentObject private var editor: NetworkEditorModel
    @ObservedObject private var focusRouter = FocusRouter.shared
    /// Which tool button holds keyboard focus. Window ▸ Focus Tools (⌃⌘1)
    /// puts it on the selected tool, so the pane's focus rule is reachable
    /// from the keyboard and not only by clicking.
    @FocusState private var focusedTool: EditorTool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Tools", isFocused: focusRouter.focusedPane == .palette)

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ForEach(Array(EditorTool.paletteGroups.enumerated()), id: \.offset) { groupIndex, group in
                    ForEach(group, id: \.self) { tool in
                        ToolButton(tool: tool, isActive: editor.selectedTool == tool) {
                            editor.setTool(tool)
                        }
                        .focused($focusedTool, equals: tool)
                    }
                    if groupIndex < EditorTool.paletteGroups.count - 1 {
                        DSRule()
                            .padding(.vertical, DS.Spacing.xs)
                            .padding(.horizontal, DS.Spacing.xs)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.s)
        }
        .background(DS.Color.surface)
        .background(PaneFocusMarker(.palette))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools pane")
        .onAppear {
            ToolShortcutGuard.installIfNeeded()
            FocusRouter.shared.setFocusHandler(.palette) {
                focusedTool = editor.selectedTool
            }
        }
        .onDisappear { FocusRouter.shared.setFocusHandler(.palette, nil) }
    }
}

/// One tool row: symbol, name, keycap. Selection wash, hover, pressed and
/// the focus ring all come from `DSPaletteButtonStyle`.
private struct ToolButton: View {
    let tool: EditorTool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: tool.systemImage)
                    .font(DS.Font.control)
                    .frame(width: DS.Layout.paletteIconWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(tool.paletteLabel)
                    .font(DS.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Spacing.xs)
                ShortcutBadge(key: String(tool.shortcutKey))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(DSPaletteButtonStyle(isSelected: isActive))
        .help(tool.helpText)
        .accessibilityLabel("\(tool.paletteLabel) tool")
        .accessibilityValue(isActive ? "selected" : "")
        .accessibilityHint("Shortcut \(String(tool.shortcutKey)) on the canvas")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The Tools menu binds the single-letter tool hotkeys (V, M, H, S, B, O,
/// X, L) with no modifier so they appear in the menu exactly as the canvas
/// uses them.  AppKit dispatches menu key equivalents *before* the first
/// responder's `keyDown`, which would steal those letters from text fields
/// and the shell.  This local event monitor delivers such keystrokes
/// straight to the window when a text view or the terminal is first
/// responder, bypassing menu key-equivalent matching.
@MainActor
enum ToolShortcutGuard {
    private static var monitor: Any?

    static func installIfNeeded() {
        guard monitor == nil else { return }
        // The handler is a non-Sendable closure formed inside this
        // @MainActor enum, so it inherits main-actor isolation and can call
        // the guard directly; local monitors always run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            deliverDirectlyIfTextEntry(event) ? nil : event
        }
    }

    /// Returns true when the event was delivered straight to the window
    /// (and must therefore be swallowed by the monitor).
    private static func deliverDirectlyIfTextEntry(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let ch = chars.first,
              EditorTool(shortcutCharacter: ch) != nil else {
            return false
        }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .capsLock, .numericPad, .function])
        guard mods.isEmpty else { return false }

        guard let window = event.window ?? NSApp.keyWindow,
              let responder = window.firstResponder else {
            return false
        }
        guard wantsPlainKeystrokes(responder) else { return false }

        // Text entry owns this keystroke: deliver it directly so the menu
        // never sees it.
        window.sendEvent(event)
        return true
    }

    /// True for first responders that consume plain letters as input:
    /// field editors / text views (every SwiftUI TextField, SecureField,
    /// TextEditor) and the embedded terminal.
    private static func wantsPlainKeystrokes(_ responder: NSResponder) -> Bool {
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return responder is TerminalView
    }
}
