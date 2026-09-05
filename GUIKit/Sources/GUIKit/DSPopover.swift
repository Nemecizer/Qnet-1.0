import SwiftUI

/// Width class of a `DSPopover`.
enum DSPopoverSize {
    /// Glossary explanations: one paragraph, `DS.Layout.popoverCompactWidth`.
    case compact
    /// Flag-bar details and similar reports: the
    /// `popoverMinWidth … popoverMaxWidth` band.
    case regular
    /// Scrollable preformatted reference text:
    /// `popoverWideWidth × popoverWideHeight`.
    case wide
}

/// The one popover chrome. A header row — optional tinted symbol, title in
/// `DS.Font.sectionTitle`, optional trailing caption — above the content,
/// padded `DS.Spacing.l` (`DS.Spacing.m` when compact) and sized by
/// `DSPopoverSize`. Every `.popover` in the app presents one of these so a
/// glossary "?" bubble, a flag-bar report and a Settings reference panel
/// share one title row and one padding.
///
/// ```swift
/// .popover(isPresented: $show) {
///     DSPopover(title: "Warnings", systemImage: DS.Symbol.warning,
///               tint: DS.Color.warning, trailing: "3 issues") { … }
/// }
/// ```
struct DSPopover<Content: View>: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let trailing: String?
    let size: DSPopoverSize
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String? = nil,
        tint: Color = DS.Color.textSecondary,
        trailing: String? = nil,
        size: DSPopoverSize = .regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.size = size
        self.content = content
    }

    private var padding: CGFloat { size == .compact ? DS.Spacing.m : DS.Spacing.l }

    var body: some View {
        switch size {
        case .compact:
            stack
                .padding(padding)
                .frame(maxWidth: DS.Layout.popoverCompactWidth, alignment: .leading)
        case .regular:
            stack
                .padding(padding)
                .frame(minWidth: DS.Layout.popoverMinWidth,
                       idealWidth: DS.Layout.popoverIdealWidth,
                       maxWidth: DS.Layout.popoverMaxWidth,
                       alignment: .leading)
        case .wide:
            // The content (a ScrollView) fills the frame; only the header
            // carries the outer padding.
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                header
                    .padding(.horizontal, padding)
                    .padding(.top, padding)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Width is pinned on purpose — this case exists to hold a
            // reading column of preformatted reference text, and a measure
            // that changes with the content is harder to read, not easier.
            // Height is a floor and an opening size rather than a lock: at
            // an Accessibility text size the header alone can need two
            // lines, and a popover that cannot grow would eat them out of
            // the scrolling region.
            .frame(minWidth: DS.Layout.popoverWideWidth,
                   idealWidth: DS.Layout.popoverWideWidth,
                   maxWidth: DS.Layout.popoverWideWidth,
                   minHeight: DS.Layout.popoverWideHeight,
                   idealHeight: DS.Layout.popoverWideHeight)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            header
            content()
        }
    }

    @ViewBuilder
    private var header: some View {
        if !title.isEmpty {
            HStack(spacing: DS.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DS.Font.sectionTitle)
                    // Two lines, not one: a popover title is short, so it
                    // wraps only at an Accessibility text size — and a
                    // truncated title tells the reader nothing about what
                    // they opened.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
