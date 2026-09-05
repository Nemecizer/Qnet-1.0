import SwiftUI
import AppKit

// MARK: - Icon button

/// The one icon-only control: pane headers, the tab bar, floating canvas
/// clusters. A square `DS.Layout.iconButtonWidth` × `DS.Layout.controlHeight`
/// target with `DSToolbarButtonStyle` (hover / pressed / disabled washes).
/// `help` is mandatory: it becomes the tooltip and — unless a separate
/// `label` is given — the accessibility label, so an icon-only button can
/// never ship without a description. `isDestructive` tints the glyph
/// `DS.Color.danger` (clear, restart, delete).
struct DSIconButton: View {
    let systemImage: String
    let label: String
    let help: String
    let isDestructive: Bool
    let action: () -> Void

    init(systemImage: String, help: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = help
        self.help = help
        self.isDestructive = isDestructive
        self.action = action
    }

    /// `label` is the short accessibility name ("Clear Shell"); `help` the
    /// longer tooltip ("Clear the screen and scrollback (⌘K)…").
    init(systemImage: String, label: String, help: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.help = help
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Font.iconButton)
                .imageScale(.medium)
                .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSToolbarButtonStyle(tint: isDestructive ? DS.Color.danger : nil))
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Icon toggle

/// The one icon-only *toggle* (snap-to-grid in the zoom cluster): a
/// `DSIconButton` that carries its on state as the selection wash plus a
/// hairline, exactly like a selected palette button. `help` is the tooltip;
/// `label` the spoken name; the value ("on" / "off") is spoken separately.
struct DSIconToggle: View {
    let systemImage: String
    @Binding var isOn: Bool
    let label: String
    let help: String

    init(systemImage: String, isOn: Binding<Bool>, label: String, help: String) {
        self.systemImage = systemImage
        self._isOn = isOn
        self.label = label
        self.help = help
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: systemImage)
                .font(DS.Font.iconButton)
                .imageScale(.medium)
                .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSToolbarButtonStyle(isSelected: isOn))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Icon menu

/// The one icon-only *menu* (export menu in the AI pane header, the row
/// menu in the node inspector): a `Menu` whose label is drawn exactly like
/// a `DSIconButton`, indicator hidden. It carries the same three states
/// its DSIconButton neighbours do — hover, open (the pull-down equivalent
/// of pressed, so the button does not look idle while its menu is on
/// screen) and disabled.
struct DSIconMenu<Content: View>: View {
    let systemImage: String
    let label: String
    let help: String
    @ViewBuilder let content: () -> Content

    init(systemImage: String, label: String, help: String, @ViewBuilder content: @escaping () -> Content) {
        self.systemImage = systemImage
        self.label = label
        self.help = help
        self.content = content
    }

    @Environment(\.isEnabled) private var isEnabled
    @DSAccessibility private var a11y
    @State private var isHovering = false
    @State private var isOpen = false

    private var fill: Color {
        guard isEnabled else { return .clear }
        if isOpen { return DS.Color.selectionFill(a11y.contrast) }
        return isHovering ? DS.Color.hoverFill(a11y.contrast) : .clear
    }

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(DS.Font.iconButton)
                .imageScale(.medium)
                .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A menu button is still a button: same hover wash, open wash and
        // disabled dimming as the DSIconButtons standing next to it in a
        // header.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .stroke(isOpen ? DS.Color.controlBorder(a11y.contrast) : .clear,
                        lineWidth: DS.Stroke.hairline(a11y.contrast))
        )
        .opacity(isEnabled ? 1 : DS.Opacity.disabled)
        .onHover { hovering in
            withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
        }
        .dsAnimation(DS.Motion.quick, value: isOpen)
        // SwiftUI's Menu exposes no "is presented" state on macOS 14, and a
        // pull-down that looks idle while its menu is open is the thing
        // this fixes. A menu can only be opened by pressing the control the
        // pointer is over, so "an NSMenu began tracking while this button
        // was hovered" identifies our own menu; keyboard activation (no
        // hover) simply gets no wash, which is a graceful degradation
        // rather than a wrong one.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if isEnabled && isHovering { isOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            if isOpen { isOpen = false }
        }
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Toolbar button style

/// Borderless toolbar button with explicit interaction states:
///   • idle      — no chrome
///   • hover     — `DS.Color.hoverFill`
///   • pressed   — `DS.Color.selectionFill`
///   • selected  — `DS.Color.selectionFill` + hairline (`isSelected`, toggles)
///   • disabled  — 40 % opacity, hover suppressed
/// The same wash is used by every borderless control in the window (pane
/// headers, tab bar, zoom cluster, font menu) so hover never looks
/// different from one pane to the next. `tint` overrides the label colour
/// (destructive actions).
struct DSToolbarButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        DSToolbarButtonBody(configuration: configuration, tint: tint, isSelected: isSelected)
    }
}

private struct DSToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color?
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @DSAccessibility private var a11y
    @State private var isHovering = false

    private var fill: Color {
        if !isEnabled { return isSelected ? DS.Color.selectionFill(a11y.contrast) : .clear }
        if configuration.isPressed { return DS.Color.selectionFill(a11y.contrast) }
        if isSelected {
            return isHovering ? DS.Color.selectionFillStrong : DS.Color.selectionFill(a11y.contrast)
        }
        if isHovering { return DS.Color.hoverFill(a11y.contrast) }
        return .clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(tint ?? DS.Color.textPrimary)
            .frame(minHeight: DS.Layout.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(isSelected ? DS.Color.controlBorder(a11y.contrast) : .clear,
                            lineWidth: DS.Stroke.hairline(a11y.contrast))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .onHover { hovering in
                withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
            }
            .dsAnimation(DS.Motion.quick, value: configuration.isPressed)
            .dsAnimation(DS.Motion.quick, value: isSelected)
    }
}

// MARK: - Palette button style

/// Full-width tool button for the Tools pane. Carries the selected state
/// itself (selection wash + hairline, primary text — never white on the
/// accent, which fails contrast for light accents), adds a hover wash, and
/// keeps the system focus ring so keyboard navigation is visible.
struct DSPaletteButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        DSPaletteButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct DSPaletteButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @DSAccessibility private var a11y
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return DS.Color.selectionFill(a11y.contrast) }
        if !isEnabled { return .clear }
        if configuration.isPressed { return DS.Color.selectionFill(a11y.contrast) }
        if isHovering { return DS.Color.hoverFill(a11y.contrast) }
        return .clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(isSelected ? DS.Color.controlBorder(a11y.contrast) : .clear,
                            lineWidth: DS.Stroke.hairline(a11y.contrast))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .onHover { hovering in
                withAnimation(a11y.animation(DS.Motion.quick)) { isHovering = hovering }
            }
            .dsAnimation(DS.Motion.quick, value: isSelected)
            .dsAnimation(DS.Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Text-size stepper

/// Text-size stepper shared by the Status, Shell and AI pane headers.
/// Keyboard routes, both via `FocusRouter` to the pane that has focus:
/// View ▸ Panes ▸ Increase / Decrease Pane Text Size (⌥⌘= / ⌥⌘−, from
/// `WorkspaceCommands`) and View ▸ Zoom In / Zoom Out (⌘= / ⌘−). The
/// tooltips name exactly those bindings.
struct FontSizeStepper: View {
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            DSIconButton(
                systemImage: DS.Symbol.textSizeSmaller,
                label: "Decrease Text Size",
                help: "Decrease text size (⌥⌘− or ⌘− while this pane has focus)",
                action: onDecrease
            )
            .disabled(!canDecrease)
            DSIconButton(
                systemImage: DS.Symbol.textSizeLarger,
                label: "Increase Text Size",
                help: "Increase text size (⌥⌘= or ⌘= while this pane has focus)",
                action: onIncrease
            )
            .disabled(!canIncrease)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
    }
}

// MARK: - Monospace font menu

/// Pop-up menu of fixed-pitch font families, anchored to the button.
/// Empty family string means "System Monospaced". The current family is
/// check-marked.
struct MonospaceFontMenu: View {
    @Binding var family: String
    var help: String = "Font"

    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            present()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: DS.Symbol.fontFamily)
                    .font(DS.Font.iconButton)
                Text(displayName)
                    .font(DS.Font.chrome)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: DS.Symbol.menuChevron)
                    .font(DS.Font.chevron)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.xs)
            .frame(height: DS.Layout.controlHeight)
            .frame(maxWidth: DS.Layout.fontMenuMaxWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSToolbarButtonStyle())
        .background(MenuAnchorView(box: anchor))
        .help(help)
        .accessibilityLabel("\(help): \(displayName)")
    }

    private var displayName: String {
        family.isEmpty ? "System Mono" : family
    }

    /// Fixed-pitch families only, resolved from face names.
    static func monospaceFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families = Set<String>()
        for name in names {
            if let font = NSFont(name: name, size: 12), let fam = font.familyName {
                // Skip hidden system faces (".SF Mono" etc. are exposed
                // through the "System Monospaced" default entry).
                if fam.hasPrefix(".") { continue }
                families.insert(fam)
            }
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func present() {
        let target = FontMenuTarget.shared
        target.onSelect = { name in family = name }

        let menu = NSMenu()
        let defaultItem = NSMenuItem(
            title: "System Monospaced",
            action: #selector(FontMenuTarget.fontItemClicked(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = target
        defaultItem.representedObject = ""
        defaultItem.state = family.isEmpty ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        for fam in Self.monospaceFamilies() {
            let item = NSMenuItem(
                title: fam,
                action: #selector(FontMenuTarget.fontItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = fam
            item.state = (fam == family) ? .on : .off
            if let f = NSFont(name: fam, size: 12) {
                item.attributedTitle = NSAttributedString(
                    string: fam,
                    attributes: [.font: NSFont(descriptor: f.fontDescriptor, size: NSFont.systemFontSize) ?? f]
                )
            }
            menu.addItem(item)
        }

        if let view = anchor.view {
            let origin = NSPoint(x: 0, y: view.bounds.height + DS.Spacing.xs)
            menu.popUp(positioning: nil, at: origin, in: view)
        } else if let event = NSApp.currentEvent, let contentView = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }
}

/// Weak box so a SwiftUI button can anchor an NSMenu to its own NSView.
@MainActor
final class MenuAnchorBox {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let box: MenuAnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// NSObject shim so NSMenuItem has a valid @objc target/action.
@MainActor
private final class FontMenuTarget: NSObject {
    static let shared = FontMenuTarget()
    var onSelect: ((String) -> Void)?

    @objc func fontItemClicked(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        onSelect?(name)
    }
}
