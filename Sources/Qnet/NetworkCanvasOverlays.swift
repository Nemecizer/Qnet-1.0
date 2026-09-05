import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Canvas overlays: class legend (bottom-left), zoom cluster (bottom-right)
// and the empty-canvas hint (centred).  The two corner panels never share
// a corner, so they cannot collide at any window width.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Floating panel chrome

private struct CanvasFloatingPanel: ViewModifier {
    @DSAccessibility private var a11y

    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.s)
            // Flat, not translucent. DesignSystem rule 2: every chrome
            // surface in Qnet is one opaque `DS.Color.surface`. A blurred
            // panel over the dotted grid also shifted tone as the user
            // panned and dropped the legend chips below the contrast the
            // gate certifies for a flat ground.
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(DS.Color.separator(a11y.contrast), lineWidth: DS.Stroke.hairline(a11y.contrast))
            )
            .dsShadow(DS.Shadow.card)
            .padding(DS.Spacing.s)
    }
}

private extension View {
    func canvasFloatingPanel() -> some View { modifier(CanvasFloatingPanel()) }
}

// MARK: - Class legend

/// One chip per customer class.  Clicking a chip pins a class filter so
/// only that class's routing is drawn; clicking it again clears it.
struct CanvasClassLegend: View {
    @EnvironmentObject private var editor: NetworkEditorModel

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(0..<editor.numberOfCustomerClasses, id: \.self) { classIdx in
                let isActiveFilter = editor.classFilter == classIdx
                let anyFilter = editor.classFilter != nil
                let label = CustomerClass.label(for: classIdx)
                Button {
                    editor.classFilter = isActiveFilter ? nil : classIdx
                } label: {
                    DSBadge(
                        text: label,
                        tint: CustomerClass.color(for: classIdx),
                        emphasis: isActiveFilter ? .selected : .neutral,
                        swatch: true,
                        dimmed: anyFilter && !isActiveFilter
                    )
                }
                .buttonStyle(.plain)
                .help(isActiveFilter
                      ? "Showing only \(label) routing. Click to clear the filter."
                      : "Click to show only \(label) routing.")
                .accessibilityLabel("\(label) filter")
                .accessibilityValue(isActiveFilter ? "on" : "off")
                .accessibilityAddTraits(isActiveFilter ? .isSelected : [])
            }
        }
        .canvasFloatingPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Customer class legend")
    }
}

// MARK: - Zoom cluster

/// Zoom out · percentage menu · zoom in · fit · snap toggle.
struct CanvasZoomCluster: View {
    @EnvironmentObject private var editor: NetworkEditorModel

    private var percentText: String {
        "\(Int((editor.canvasScale * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            DSIconButton(systemImage: DS.Symbol.zoomOut,
                         help: "Zoom out (⌘−)") {
                editor.zoomOut()
            }
            .disabled(editor.canvasScale <= NetworkEditorModel.zoomRange.lowerBound + 0.001)

            Menu {
                ForEach([0.5, 1.0, 2.0], id: \.self) { level in
                    Button("\(Int(level * 100))%") { editor.setZoom(CGFloat(level)) }
                }
                Divider()
                Button("Zoom to Fit") { editor.zoomToFit() }
                    .disabled(editor.nodes.isEmpty)
                Button("Zoom to Selection") { editor.zoomToFitSelection() }
                    .disabled(!editor.canZoomToSelection)
            } label: {
                Text(percentText)
                    .font(DS.Font.numberSmall)
                    .foregroundStyle(DS.Color.textPrimary)
                    .frame(minWidth: DS.Layout.zoomReadoutWidth, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Zoom level — pick a preset, Zoom to Fit (\(KeyboardShortcutReference.key(for: .zoomToFit))) or Zoom to Selection (\(KeyboardShortcutReference.key(for: .zoomToSelection))). \(KeyboardShortcutReference.key(for: .actualSize)) is actual size.")
            .accessibilityLabel("Zoom level")
            .accessibilityValue(percentText)

            DSIconButton(systemImage: DS.Symbol.zoomIn,
                         help: "Zoom in (⌘=)") {
                editor.zoomIn()
            }
            .disabled(editor.canvasScale >= NetworkEditorModel.zoomRange.upperBound - 0.001)

            DSRule(.vertical, length: DS.Layout.controlHeight - DS.Spacing.s)

            DSIconButton(systemImage: DS.Symbol.zoomToFit,
                         help: "Zoom to fit the whole network (\(KeyboardShortcutReference.key(for: .zoomToFit)))") {
                editor.zoomToFit()
            }
            .disabled(editor.nodes.isEmpty)

            snapToggle
        }
        .canvasFloatingPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom controls")
    }

    /// Dimmed while ⌃ is held during a drag — the one-drag override that
    /// takes a node off the grid and past the guides — so the state is
    /// visible, not just in effect.
    private var snapToggle: some View {
        DSIconToggle(
            systemImage: DS.Symbol.snapToGrid,
            isOn: Binding(get: { editor.snapToGrid }, set: { editor.snapToGrid = $0 }),
            label: "Snap to Grid",
            help: editor.snapSuspended
                ? "Free placement — ⌃ is held, so Snap to Grid and the alignment guides stand down for this drag"
                : (editor.snapToGrid
                   ? "Snap to Grid is on — node moves land on the 28 pt grid (⌥⌘G to turn off). Hold ⌃ while dragging to place a node freely."
                   : "Snap to Grid is off (⌥⌘G to turn on). Alignment guides still line a dragged node up with its neighbours; hold ⌃ to place it freely.")
        )
        .opacity(editor.snapSuspended ? DS.Opacity.disabled : 1)
        .dsAnimation(DS.Motion.quick, value: editor.snapSuspended)
    }
}

// MARK: - Empty hint

/// Guidance shown while the canvas has no nodes, with a way out of the
/// blank page: an empty state the user can act on rather than a sentence
/// they can only read.
///
/// The message states the model's shape, because it is the rule a first
/// network breaks: `SRBMExporter` requires every station to be fed
/// through exactly one buffer, and nothing else in the UI says so before
/// the export refuses.
///
/// Hit testing: `DSEmptyState` already opts its icon and its two text
/// blocks out individually (see its doc comment), which is what lets the
/// hint sit over the canvas as an overlay with no blanket
/// `.allowsHitTesting(false)` on top — a click through the middle of the
/// text still reaches the canvas gesture and places a node, and the
/// buttons beneath it are the only live targets in the block.
struct CanvasEmptyHint: View {
    /// Opens the example picker. Nil hides the button — the canvas passes
    /// nil when File ▸ Open Example… is not in the menu bar to drive.
    var onOpenExample: (() -> Void)?
    /// Opens the archetype gallery. Nil hides the button — the canvas
    /// passes nil when File ▸ New from Archetype… is not in the menu bar
    /// to drive.
    var onStartArchetype: (() -> Void)?

    /// One way out of the blank page: what the button says, what its
    /// tooltip says it will do, and the menu item it performs.
    private struct Offer {
        let title: String
        /// The sentence the button needs, which is never its own label
        /// again: a tooltip that repeats the title tells the reader
        /// nothing they did not just read. It is the promise the menu
        /// item behind the button makes, in the menu item's own words.
        let help: String
        let run: () -> Void
    }

    /// The offers, in the order a first-time user should meet them —
    /// which is not the order the parameters are declared in. An
    /// archetype arrives sized, parametrised and immediately runnable, so
    /// it is the shortest path there is from a blank page to a solver
    /// result and it goes first; the bundled literature networks are the
    /// slower, more studious route and go second. Either may be absent
    /// (its menu item is gone or disabled), and one absent offer simply
    /// promotes the other.
    private var offers: [Offer] {
        var out: [Offer] = []
        if let onStartArchetype {
            out.append(Offer(
                title: "Start from an Archetype…",
                help: "Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation",
                run: onStartArchetype))
        }
        if let onOpenExample {
            out.append(Offer(
                title: "Open an Example…",
                help: "Open one of the 50 bundled literature networks",
                run: onOpenExample))
        }
        return out
    }

    var body: some View {
        // Both offers go through `DSEmptyState`'s own action row, which
        // owns the prominent fill: the archetype takes it, the example
        // stays plain beneath it, and each carries the sentence its menu
        // item makes rather than a tooltip that repeats its own label.
        // Neither carries a key equivalent: File already owns ⇧⌘O and
        // ⌥⌘N, and a second binding for the same command would hide a
        // collision from the menu audit. The state gives up its greedy
        // height when it has buttons so the block stays together and
        // centred.
        let offers = self.offers
        DSEmptyState(
            systemImage: DS.Symbol.network,
            title: "No Network Yet",
            message: "Press S, then click to place a station. A station is served through exactly one buffer: Source → Buffer → Station → Sink.",
            actions: offers.enumerated().map { index, offer in
                DSEmptyStateAction(title: offer.title,
                                   help: offer.help,
                                   prominent: index == 0,
                                   action: offer.run)
            }
        )
        .fixedSize(horizontal: false, vertical: !offers.isEmpty)
        .multilineTextAlignment(.center)
    }
}
