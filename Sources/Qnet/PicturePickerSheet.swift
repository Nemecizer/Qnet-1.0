import SwiftUI

/// The station inspector's "Choose…" form. Shows a grid of SF-Symbol-based
/// resource icons matching the kinds of resource pools commercial
/// discrete-event simulators (Arena, FlexSim, Simio) offer: human
/// operators, manufacturing equipment, automated / robotic stations,
/// service resources, and logistics icons.
///
/// Presented as a movable `DSPanelWindow` panel rather than a sheet — the
/// picture being chosen is drawn inside the station circle on the canvas,
/// which is the thing a sheet would sit on top of. It dismisses itself
/// through `\.qnetDismiss` rather than SwiftUI's `\.dismiss`, because in a
/// panel it is the hosting *window* that has to close and `\.dismiss` there
/// either does nothing or dismisses something else (see `QnetDismissAction`).
///
/// Keyboard: arrow keys move the highlight, Return chooses, Esc cancels.
/// Double-clicking a tile chooses it immediately.
struct PicturePickerSheet: View {
    @Binding var selection: StationPicture
    @Environment(\.qnetDismiss) private var dismiss

    /// Provisional choice (highlighted tile); committed by Choose / Return.
    @State private var highlighted: StationPicture = .none
    @FocusState private var focusedTile: StationPicture?

    /// Grouping used to lay the picker out with section headers.
    private struct PictureSection: Identifiable {
        let title: String
        let items: [StationPicture]
        var id: String { title }
    }

    private static let sections: [PictureSection] = [
        PictureSection(title: "No Picture",
                       items: [.none]),
        PictureSection(title: "People / Operators",
                       items: [.singleOperator, .twoOperators, .team]),
        PictureSection(title: "Manufacturing",
                       items: [.machine, .workbench, .repairStation, .printer, .automated]),
        PictureSection(title: "Service Industry",
                       items: [.healthcare, .cashier, .teller, .callCenter]),
        PictureSection(title: "Logistics / Compute",
                       items: [.packageBox, .inspection, .serverRack, .gear]),
    ]

    private static let columnCount = 4
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.s),
                                    count: PicturePickerSheet.columnCount)

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Station Picture",
                subtitle: "Choose a resource icon to draw inside the station circle. Pictures scale with zoom and fit the circle at every size."
            ) {
                StationPicturePreview(picture: highlighted, size: DS.Layout.sheetGlyphSize)
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        ForEach(Self.sections) { section in
                            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                                Text(section.title)
                                    .font(DS.Font.chromeEmphasis)
                                    .foregroundStyle(DS.Color.textSecondary)
                                LazyVGrid(columns: gridColumns, spacing: DS.Spacing.s) {
                                    ForEach(section.items, id: \.self) { picture in
                                        PictureCell(
                                            picture: picture,
                                            isHighlighted: highlighted == picture,
                                            isCurrent: selection == picture,
                                            isFocused: focusedTile == picture,
                                            onSelect: {
                                                highlighted = picture
                                                focusedTile = picture
                                            },
                                            onChoose: { choose(picture) }
                                        )
                                        .id(picture)
                                        .focusable()
                                        .focused($focusedTile, equals: picture)
                                        .focusEffectDisabled()
                                    }
                                }
                            }
                        }
                    }
                    .padding(DS.Spacing.l)
                }
                .onChange(of: highlighted) { _, newValue in
                    withAnimation(DS.Motion.quick) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onKeyPress(.leftArrow)  { move(by: -1);                      return .handled }
            .onKeyPress(.rightArrow) { move(by: 1);                       return .handled }
            .onKeyPress(.upArrow)    { move(by: -Self.columnCount);       return .handled }
            .onKeyPress(.downArrow)  { move(by: Self.columnCount);        return .handled }
        } footer: {
            DSSheetFooter(
                confirmTitle: "Choose",
                cancelHelp: "Keep the current picture (Esc)",
                confirmHelp: "Use \(highlighted.displayName) (Return)",
                onCancel: { dismiss() },
                onConfirm: { choose(highlighted) }
            ) {
                Text(highlighted.displayName)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel("Highlighted: \(highlighted.displayName)")
            }
        }
        .dsSheetFrame(.wide)
        .onChange(of: focusedTile) { _, newValue in
            if let newValue { highlighted = newValue }
        }
        // Deterministic initial focus on the current picture's tile (no
        // timer race on a slow first presentation).
        .defaultFocus($focusedTile, selection)
        .onAppear {
            highlighted = selection
        }
    }

    private static let flatOrder: [StationPicture] = sections.flatMap(\.items)

    /// Keyboard navigation over the flat tile order.  Left/right step by
    /// one; up/down step by a grid row, clamped to the ends.
    private func move(by delta: Int) {
        let order = Self.flatOrder
        guard let idx = order.firstIndex(of: highlighted) else {
            highlighted = order.first ?? .none
            focusedTile = highlighted
            return
        }
        let next = min(max(idx + delta, 0), order.count - 1)
        highlighted = order[next]
        focusedTile = highlighted
    }

    private func choose(_ picture: StationPicture) {
        selection = picture
        dismiss()
    }
}

/// Individual tile in the picture grid.  Renders the target icon inside a
/// preview circle so the user sees exactly how the station will look.
private struct PictureCell: View {
    let picture: StationPicture
    let isHighlighted: Bool
    let isCurrent: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    @DSAccessibility private var a11y
    let onChoose: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            StationPicturePreview(picture: picture, size: DS.Layout.pictureTileSize, isSelected: isHighlighted)
            Text(picture.displayName)
                .font(DS.Font.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(height: DS.Spacing.xl + DS.Spacing.xs, alignment: .top)
        }
        .padding(DS.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(isHighlighted
                      ? DS.Color.selectionFill(a11y.contrast)
                      : (isHovering ? DS.Color.hoverFill(a11y.contrast) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .stroke(isFocused ? DS.Color.accent : Color.clear, lineWidth: DS.Stroke.selection)
        )
        .dsAnimation(DS.Motion.quick, value: isHighlighted)
        .dsAnimation(DS.Motion.quick, value: isHovering)
        .overlay(alignment: .topTrailing) {
            if isCurrent {
                Image(systemName: DS.Symbol.success)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accent)
                    .padding(DS.Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .onTapGesture(count: 2) { onChoose() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
        .help(picture.displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(picture.displayName + (isCurrent ? ", current picture" : ""))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onChoose() }
    }
}

/// Shared preview view — used inside the picker tiles and the inspector's
/// in-line preview next to the "Choose…" button.  Draws the canvas station
/// fill colour with the chosen SF Symbol inscribed inside so the preview
/// matches the real node.
struct StationPicturePreview: View {
    let picture: StationPicture
    let size: CGFloat
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DS.Color.nodeFill(for: .station))
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? DS.Color.accent : DS.Color.nodeStroke,
                            lineWidth: isSelected ? DS.Stroke.focusRing : DS.Stroke.hairlineBold
                        )
                )
            if let sys = picture.systemImageName {
                // Inscribe the icon in a square that fits inside the
                // circle: inset by size·(1 − 1/√2)/2 ≈ 0.146·size so the
                // diagonal of the icon box equals the circle's diameter.
                Image(systemName: sys)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(DS.Color.nodeGlyph)
                    .padding(size * 0.18)
            } else {
                // "No Picture" — hint at empty state without obscuring the
                // circle fill.
                Image(systemName: DS.Symbol.blocked)
                    .font(DS.Font.glyph(fitting: size))
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}
