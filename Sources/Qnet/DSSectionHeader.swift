import SwiftUI

/// The one header every pane and section uses: a fixed 32-pt title row
/// (`DS.Layout.headerHeight`) on `DS.Color.surface`, an optional accessory
/// next to the title (badge, status chip), trailing controls, an optional
/// single-line monospaced subtitle (paths, session info) and a bottom
/// hairline. A 2-pt accent rule appears along the top edge when the pane
/// holds keyboard focus.
///
/// ```swift
/// DSSectionHeader("Status", isFocused: focused) {
///     DSBadge(text: "128")
/// } trailing: {
///     DSIconButton(systemImage: DS.Symbol.clearPane, help: "Clear the status log") { … }
/// }
/// ```
struct DSSectionHeader<Accessory: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let isFocused: Bool
    /// Draw the hairline under the header. Off for sheets, whose content
    /// starts directly below the title.
    let showsDivider: Bool
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        isFocused: Bool = false,
        showsDivider: Bool = true,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isFocused = isFocused
        self.showsDivider = showsDivider
        self.accessory = accessory
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Text(title)
                    .font(DS.Font.sectionTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)

                accessory()

                Spacer(minLength: DS.Spacing.s)

                HStack(spacing: DS.Spacing.xs) {
                    trailing()
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.headerHeight)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Font.monoCaption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.bottom, DS.Spacing.xs)
                    .help(subtitle)
            }
        }
        .frame(maxWidth: .infinity)
        .background(DS.Color.surface)
        .overlay(alignment: .bottom) {
            if showsDivider { DSRule() }
        }
        .dsFocusRule(isFocused)
    }
}

extension DSSectionHeader where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        isFocused: Bool = false,
        showsDivider: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(title, subtitle: subtitle, isFocused: isFocused, showsDivider: showsDivider,
                  accessory: { EmptyView() }, trailing: trailing)
    }
}

extension DSSectionHeader where Accessory == EmptyView, Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        isFocused: Bool = false,
        showsDivider: Bool = true
    ) {
        self.init(title, subtitle: subtitle, isFocused: isFocused, showsDivider: showsDivider,
                  accessory: { EmptyView() }, trailing: { EmptyView() })
    }
}

// MARK: - Focus rule

extension View {
    /// The pane keyboard-focus indicator: one 2-pt accent line along the
    /// top edge, fading in and out with `DS.Motion.quick`.
    ///
    /// One implementation for every pane.  `DSSectionHeader` draws it for
    /// the four panes that have a header; `TabBarView` draws it for the
    /// canvas, which has none of its own (the tab bar *is* the canvas
    /// pane's header).  Purely decorative — it never takes a hit and is
    /// hidden from VoiceOver, which learns about focus from the focused
    /// control itself.
    func dsFocusRule(_ isFocused: Bool) -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Color.accent)
                .frame(height: DS.Stroke.selection)
                .opacity(isFocused ? 1 : 0)
                .dsAnimation(DS.Motion.quick, value: isFocused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
