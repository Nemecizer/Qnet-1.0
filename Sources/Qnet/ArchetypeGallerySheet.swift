import SwiftUI

/// File ▸ New from Archetype… / Network ▸ Insert Archetype…
///
/// Pick a starting network on the left, set its size and load on the right,
/// press Insert. The network is built by `NetworkArchetypeBuilder` and handed
/// to `NetworkEditorModel.insertSubnetwork(...)`, which lands the whole thing
/// as ONE undo step with the document's own node numbering continued.
///
/// Structure follows `PicturePickerSheet` (DSSheet chrome, a sectioned
/// LazyVGrid with arrow-key navigation and double-click to choose) and the
/// knob column follows `GenerateRandomNetworkSheet` (grouped Form of
/// `LabeledContent` + `DSNumericField` rows, first blocking problem in the
/// footer) — two sheets a user of this one has probably already seen.
struct ArchetypeGallerySheet: View {
    /// What is already on the canvas. The sheet does not read the editor
    /// itself: it only needs to tell the user what an insert will do to the
    /// network they already have.
    let canvasNodeCount: Int
    let canvasSourceCount: Int
    /// The buffer regime the DOCUMENT is in. The Buffers control opens on it,
    /// so the sheet never shows a regime that is not the user's — an empty
    /// canvas is the only case where the choice made here becomes the
    /// document's, and `insertSubnetwork` enforces that.
    let initialInfiniteBuffers: Bool
    let onCancel: () -> Void
    let onInsert: (NetworkArchetype, ArchetypeParameters) -> Void

    init(
        canvasNodeCount: Int,
        canvasSourceCount: Int,
        initialInfiniteBuffers: Bool = true,
        onCancel: @escaping () -> Void,
        onInsert: @escaping (NetworkArchetype, ArchetypeParameters) -> Void
    ) {
        self.canvasNodeCount = canvasNodeCount
        self.canvasSourceCount = canvasSourceCount
        self.initialInfiniteBuffers = initialInfiniteBuffers
        self.onCancel = onCancel
        self.onInsert = onInsert
        _infiniteBuffers = State(initialValue: initialInfiniteBuffers)
    }

    /// Provisional choice (highlighted tile); committed by Insert / Return.
    @State private var highlighted: NetworkArchetype = .tandemLine
    @FocusState private var focusedTile: NetworkArchetype?
    /// Raised by the first click or arrow key on the gallery. Until then a
    /// focus change is AppKit's doing, not the user's — see the
    /// `.onChange(of: focusedTile)` handler.
    @State private var userMovedFocus = false
    @State private var focusPushBacks = 0
    private static let maxFocusPushBacks = 3

    @State private var stations = 3
    @State private var servers = 1
    @State private var capacity = 10
    @State private var infiniteBuffers: Bool
    @State private var rhoText = "0.90"
    @State private var feedbackText = "0.30"
    @State private var lambdaText = "1.0"

    // One column: the tiles carry a title and a route line, so they read as a
    // list of networks rather than as a grid of glyphs. `columnCount` still
    // drives the up/down key step, exactly as in the picture picker.
    private static let columnCount = 1
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.s),
                                    count: ArchetypeGallerySheet.columnCount)

    // MARK: - Parsed values

    private var rhoValue: Double? {
        guard let v = DS.Number.parse(rhoText),
              ArchetypeParameters.rhoRange.contains(v) else { return nil }
        return v
    }

    private var feedbackValue: Double? {
        guard let v = DS.Number.parse(feedbackText),
              ArchetypeParameters.feedbackRange.contains(v) else { return nil }
        return v
    }

    private var lambdaValue: Double? {
        guard let v = DS.Number.parse(lambdaText),
              ArchetypeParameters.arrivalRateRange.contains(v) else { return nil }
        return v
    }

    private var blueprint: ArchetypeBlueprint {
        NetworkArchetypeBuilder.blueprint(for: highlighted)
    }

    /// The parameters as they stand; unparseable fields fall back to the
    /// defaults so the preview line never goes blank while `problem` is what
    /// actually blocks the insert.
    private var parameters: ArchetypeParameters {
        var p = ArchetypeParameters()
        p.stations = stations
        p.servers = servers
        p.infiniteBuffers = infiniteBuffers
        p.bufferCapacity = capacity
        if let rhoValue { p.targetRho = rhoValue }
        if let feedbackValue { p.feedbackProbability = feedbackValue }
        if let lambdaValue { p.arrivalRate = lambdaValue }
        return p
    }

    /// First blocking problem, in the order the fields are read.
    private var problem: String? {
        if blueprint.uses(.stations), !ArchetypeParameters.stationRange.contains(stations) {
            return "Stations must be between 1 and 12."
        }
        if blueprint.uses(.servers), !ArchetypeParameters.serverRange.contains(servers) {
            return "Servers must be between 1 and 16."
        }
        if blueprint.uses(.arrivalRate), lambdaValue == nil {
            return "Arrival rate λ must be a positive number."
        }
        if blueprint.uses(.targetRho), rhoValue == nil {
            return "Target ρ must be a number between 0.05 and 0.99."
        }
        if blueprint.uses(.feedbackProbability), feedbackValue == nil {
            return "Feedback probability p must be a number between 0.00 and 0.90."
        }
        if blueprint.uses(.buffers), !infiniteBuffers,
           !ArchetypeParameters.capacityRange.contains(capacity) {
            return "Buffer capacity must be between 1 and 500."
        }
        return nil
    }

    /// What Insert will produce, in one line, for the footer.
    private var summary: String {
        NetworkArchetypeBuilder.summary(highlighted, parameters)
    }

    // MARK: - Body

    var body: some View {
        DSSheet {
            DSSheetHeader(
                "Insert Archetype",
                subtitle: "Pick a starting network and set its size and load. It is inserted into the current canvas as one undoable step, already laid out and ready to run."
            ) {
                DSSheetSymbolGlyph(fill: DS.Color.tintFill(DS.Color.info),
                                   systemImage: DS.Symbol.network,
                                   tint: DS.Color.infoText)
            }
        } content: {
            HStack(spacing: 0) {
                gallery
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                DSRule(.vertical)
                knobs
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            DSSheetFooter(
                problem: problem,
                confirmTitle: "Insert",
                canConfirm: problem == nil,
                cancelHelp: "Close without changing the network (Esc)",
                confirmHelp: "Insert \(blueprint.title) into the current canvas as one undoable step (Return)",
                blockedHelp: "Fix the highlighted values to insert",
                onCancel: onCancel,
                onConfirm: { insert(highlighted) }
            ) {
                Text(summary)
                    .font(DS.Font.chrome)
                    .foregroundStyle(DS.Color.textSecondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Will insert: \(summary)")
            }
        }
        .dsSheetFrame(.wide)
        .defaultFocus($focusedTile, highlighted)
        .onChange(of: focusedTile) { _, newValue in
            guard let newValue else { return }
            // Focus is allowed to redefine the selection only once the USER
            // is the one moving it.
            //
            // Inside a `DSPanelWindow` the panel's first responder is chosen
            // by AppKit when the window is ordered in, and it picks the FIRST
            // focusable tile in the catalogue — M/M/c Station — AFTER
            // `.defaultFocus` has already put focus on the declared default.
            // Adopting that second, machine-made focus change is what made
            // the gallery open on M/M/c: the Stations knob was absent, the
            // footer read "1 station, 4 nodes, 3 links", and reaching Tandem
            // Line — the default the sheet declares and the path the
            // three-station-tandem recipe walks — cost an extra click.
            //
            // Every user route into the grid (a click through `onSelect`, an
            // arrow key through `move(by:)`) sets `highlighted` and
            // `focusedTile` together and raises the flag first, so nothing a
            // user does is lost by waiting for it.
            guard userMovedFocus else {
                guard newValue != highlighted else { return }
                // Not the user: put focus back where the sheet declared it.
                // Bounded, so a window that insists on its own first
                // responder settles for a stray focus ring rather than
                // ping-ponging with this handler.
                guard focusPushBacks < Self.maxFocusPushBacks else { return }
                focusPushBacks += 1
                focusedTile = highlighted
                return
            }
            highlighted = newValue
        }
    }

    // MARK: - Gallery column

    private var gallery: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ForEach(NetworkArchetypeBuilder.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            Text(group)
                                .font(DS.Font.chromeEmphasis)
                                .foregroundStyle(DS.Color.textSecondary)
                            LazyVGrid(columns: gridColumns, spacing: DS.Spacing.s) {
                                ForEach(NetworkArchetypeBuilder.blueprints.filter { $0.group == group }) { item in
                                    ArchetypeCell(
                                        blueprint: item,
                                        isHighlighted: highlighted == item.id,
                                        isFocused: focusedTile == item.id,
                                        onSelect: {
                                            userMovedFocus = true
                                            highlighted = item.id
                                            focusedTile = item.id
                                        },
                                        onChoose: { insert(item.id) }
                                    )
                                    .id(item.id)
                                    .focusable()
                                    .focused($focusedTile, equals: item.id)
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
        // Arrow keys walk the flat catalogue order. Only the gallery column
        // takes them, so the arrow keys inside a numeric field on the right
        // still step its value.
        .onKeyPress(.leftArrow)  { move(by: -1);                        return .handled }
        .onKeyPress(.rightArrow) { move(by: 1);                         return .handled }
        .onKeyPress(.upArrow)    { move(by: -Self.columnCount);         return .handled }
        .onKeyPress(.downArrow)  { move(by: Self.columnCount);          return .handled }
    }

    // MARK: - Knob column

    private var knobs: some View {
        Form {
            Section {
                if blueprint.uses(.stations) {
                    LabeledContent("Stations") {
                        DSNumericField(
                            label: "Number of stations",
                            value: $stations,
                            range: ArchetypeParameters.stationRange,
                            stepper: 1,
                            commit: .onEdit,
                            help: "Number of service stations in the line (1–12)",
                            width: DS.Layout.compactFieldWidth,
                            accessibilityLabel: "Number of stations"
                        )
                        .dsRowLayout(.bare)
                    }
                    .help("Number of service stations in the line (1–12)")
                }

                LabeledContent("Servers per station") {
                    DSNumericField(
                        label: "Servers per station",
                        value: $servers,
                        range: ArchetypeParameters.serverRange,
                        stepper: 1,
                        commit: .onEdit,
                        help: "Parallel servers c at every station; the service rate is scaled so ρ is unchanged",
                        width: DS.Layout.compactFieldWidth,
                        accessibilityLabel: "Servers per station"
                    )
                    .dsRowLayout(.bare)
                }
                .help("Parallel servers c at every station (1–16)")
            } header: {
                Text("Size")
            } footer: {
                Text(blueprint.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Arrival rate λ") {
                    DSNumericField(
                        label: "External arrival rate lambda",
                        text: $lambdaText,
                        range: ArchetypeParameters.arrivalRateRange,
                        stepper: 0.1,
                        help: DS.Glossary.lambda,
                        placeholder: "1.0",
                        width: DS.Layout.compactFieldWidth,
                        accessibilityLabel: "External arrival rate lambda"
                    )
                    .dsRowLayout(.bare)
                }
                .help("Poisson arrival rate of the single source")

                LabeledContent("Target ρ") {
                    DSNumericField(
                        label: "Target utilisation rho",
                        text: $rhoText,
                        range: ArchetypeParameters.rhoRange,
                        stepper: 0.05,
                        help: DS.Glossary.rho,
                        placeholder: "0.90",
                        width: DS.Layout.compactFieldWidth,
                        accessibilityLabel: "Target utilisation rho"
                    )
                    .dsRowLayout(.bare)
                }
                .help("Service rates are back-solved as μ = α / (ρ · c), so every station lands at exactly this ρ")

                if blueprint.uses(.feedbackProbability) {
                    LabeledContent("Feedback p") {
                        DSNumericField(
                            label: "Feedback probability p",
                            text: $feedbackText,
                            range: ArchetypeParameters.feedbackRange,
                            stepper: 0.05,
                            help: "Fraction of a station's output that goes round the feedback arc instead of onward",
                            placeholder: "0.30",
                            width: DS.Layout.compactFieldWidth,
                            accessibilityLabel: "Feedback probability p"
                        )
                        .dsRowLayout(.bare)
                    }
                    .help("Fraction of a station's output that goes round the feedback arc (0.00–0.90)")
                }
            } header: {
                Text("Load")
            } footer: {
                Text("λ and ρ fix the service rates: μ = α / (ρ · c) at every station, where α is the throughput the traffic equations give.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Buffers", selection: $infiniteBuffers) {
                    Text("Infinite").tag(true)
                    Text("Finite").tag(false)
                }
                .pickerStyle(.menu)
                .help("Infinite buffers keep the network in the exact Jackson branch; finite buffers add blocking")

                if !infiniteBuffers {
                    LabeledContent("Capacity") {
                        DSNumericField(
                            label: "Buffer capacity",
                            value: $capacity,
                            range: ArchetypeParameters.capacityRange,
                            stepper: 1,
                            commit: .onEdit,
                            help: "Queue capacity of every inserted buffer",
                            width: DS.Layout.compactFieldWidth,
                            accessibilityLabel: "Buffer capacity"
                        )
                        .dsRowLayout(.bare)
                    }
                    .help("Queue capacity of every inserted buffer (1–500)")
                }
            } header: {
                Text("Buffer model")
            } footer: {
                Text(insertNote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .dsAnimation(DS.Motion.quick, value: highlighted)
        .dsAnimation(DS.Motion.quick, value: infiniteBuffers)
    }

    /// What the insert will do to the network that is already there — the
    /// four things a user is about to be surprised by: where the block lands,
    /// which customer class its traffic ends up on, what that second class
    /// does and does not cost the analysis, and what does NOT happen to the
    /// buffer regime of the stations already on the canvas.
    private var insertNote: String {
        guard canvasNodeCount > 0 else {
            return "The buffer model is network-wide. This canvas is empty, so the choice above becomes the whole network's: the insert will put it on \(infiniteBuffers ? "infinite" : "finite") buffers."
        }
        var note = "The archetype is inserted clear to the right of the \(canvasNodeCount) node\(canvasNodeCount == 1 ? "" : "s") already on the canvas, with its own numbering continued."
        if canvasSourceCount > 0 {
            // Not a warning, a fact: the inserted source is the (n+1)-th
            // source, so it owns the (n+1)-th class and `insertSubnetwork`
            // moves the links that came with it onto that class.
            note += " Its source becomes \(CustomerClass.label(for: canvasSourceCount)), and the links inserted with it are moved onto that class."
            // The question a second class raises — "have I just lost my exact
            // answer?" — has a definite answer, so give it rather than leave
            // the user to infer one. An inserted block brings its own
            // stations, so the two classes share no server, and
            // `AnalyticalTractability.singleClassPerStation` keeps the
            // document in the exact Jackson branch on exactly that ground.
            note += " The two blocks share no station, so a second class does not cost the analysis its exactness — a link drawn between them later is what would make the document genuinely multi-class."
        }
        if infiniteBuffers != initialInfiniteBuffers {
            note += " The canvas is on \(initialInfiniteBuffers ? "infinite" : "finite") buffers and an insert does not re-interpret the stations already there, so the network stays on \(initialInfiniteBuffers ? "infinite" : "finite") buffers — Network ▸ Buffer Model changes it for the whole network."
        }
        return note
    }

    // MARK: - Actions

    private static let flatOrder: [NetworkArchetype] =
        NetworkArchetypeBuilder.blueprints.map(\.id)

    /// Keyboard navigation over the flat catalogue order, clamped at the ends
    /// (a picker that wraps loses the user's place).
    private func move(by delta: Int) {
        userMovedFocus = true
        let order = Self.flatOrder
        guard let index = order.firstIndex(of: highlighted) else {
            highlighted = order.first ?? .tandemLine
            focusedTile = highlighted
            return
        }
        let next = min(max(index + delta, 0), order.count - 1)
        highlighted = order[next]
        focusedTile = highlighted
    }

    private func insert(_ archetype: NetworkArchetype) {
        guard problem == nil else { return }
        onInsert(archetype, parameters)
    }
}

/// One archetype in the gallery: name, a schematic of the network it builds,
/// and the route in one line. The schematic is the reason the route line can
/// be prose — a stencil browser is judged by whether the shape is legible
/// before the words are read.
private struct ArchetypeCell: View {
    let blueprint: ArchetypeBlueprint
    let isHighlighted: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onChoose: () -> Void

    @DSAccessibility private var a11y
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: blueprint.systemImage)
                    .font(DS.Font.iconButton)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: DS.Layout.paletteIconWidth)
                    .accessibilityHidden(true)
                Text(blueprint.title)
                    .font(DS.Font.labelEmphasis)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: 0)
            }
            // The picture, not a second glyph: the route line below it is
            // prose, and prose is what a stencil browser exists to replace.
            // Full width rather than a fixed box so it still reads at
            // Accessibility text sizes, where the tile grows around it.
            ArchetypeThumbnail(schematic: NetworkArchetypeBuilder.schematic(for: blueprint.id))
            Text(blueprint.subtitle)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .onTapGesture(count: 2) { onChoose() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
        .help(blueprint.subtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(blueprint.title). \(blueprint.subtitle)")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        // The default action is the KEYBOARD equivalent of a single click,
        // so it highlights and nothing more — the knobs on the right (λ, ρ,
        // stations, servers, buffers) are the point of the panel, and a
        // VoiceOver user arrowing through the tiles must reach them before
        // anything is inserted. Committing is a named action of its own,
        // matching the double-click.
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Insert") { onChoose() }
    }
}

/// The schematic drawn on the gallery tile: the archetype's own nodes and
/// links, scaled into the tile's width.
///
/// A `Canvas` rather than a stack of shapes because the picture is one flat
/// drawing with no hit-testing, no animation and no accessibility surface of
/// its own (the tile's label already reads the title and the route line), and
/// because a `Canvas` draw closure is the cheapest thing SwiftUI can put in a
/// scrolling list of tiles.
///
/// Everything is derived from the drawing rect, so there is no size the tile
/// can be given at which the picture stops fitting.
private struct ArchetypeThumbnail: View {
    let schematic: ArchetypeSchematic

    var body: some View {
        Canvas { context, size in
            // Inset by one node radius plus the height of a self-loop arc, so
            // a loop over the top station is never clipped.
            let radius = min(size.height * 0.11, DS.Spacing.s)
            // Asymmetric on purpose: the top edge carries the self-loop and
            // the returning arc, the bottom edge only a node.
            let rect = CGRect(x: radius + DS.Spacing.xxs,
                              y: radius * 3,
                              width: size.width - (radius + DS.Spacing.xxs) * 2,
                              height: size.height - radius * 4)
            guard rect.width > 0, rect.height > 0 else { return }

            func place(_ unit: CGPoint) -> CGPoint {
                CGPoint(x: rect.minX + unit.x * rect.width,
                        y: rect.minY + unit.y * rect.height)
            }

            // Links first: nodes sit on top of the lines that meet them.
            for edge in schematic.edges {
                let a = place(edge.from)
                let b = place(edge.to)
                var path = Path()
                if edge.isLoop {
                    // The rework arc, drawn where the canvas draws it — a
                    // small circle riding above the station.
                    path.addEllipse(in: CGRect(x: a.x - radius, y: a.y - radius * 2.8,
                                               width: radius * 2, height: radius * 2))
                } else if edge.isBackward {
                    // A returning arc bows over the top, which is what tells
                    // a re-entrant pair from a fork at tile size.
                    path.move(to: a)
                    path.addQuadCurve(to: b,
                                      control: CGPoint(x: (a.x + b.x) / 2,
                                                       y: min(a.y, b.y) - rect.height * 0.55))
                } else {
                    path.move(to: a)
                    path.addLine(to: b)
                }
                context.stroke(path, with: .color(DS.Color.textSecondary),
                               lineWidth: DS.Stroke.hairlineAdaptive)
            }

            // The markers speak the canvas's vocabulary, in both of the
            // ways a canvas node is recognised: its SHAPE (diamond source,
            // rectangle buffer open on its inflow side, circle station,
            // rounded-square sink — the four cases of `NodeOutlineShape`)
            // and its COLOUR (`DS.Color.nodeFill(for:)`, the same value the
            // canvas fills with). Accent appears nowhere here: inside a tile
            // it already means "this archetype's glyph" and "this tile has
            // keyboard focus", and a colour cannot also mean "station".
            for marker in schematic.markers {
                let centre = place(marker.point)
                let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: radius * 2, height: radius * 2)
                let fill = GraphicsContext.Shading.color(DS.Color.nodeFill(for: marker.kind))
                let ink = GraphicsContext.Shading.color(DS.Color.nodeStroke)
                switch marker.kind {
                case .source:
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: box.midX, y: box.minY))
                    diamond.addLine(to: CGPoint(x: box.maxX, y: box.midY))
                    diamond.addLine(to: CGPoint(x: box.midX, y: box.maxY))
                    diamond.addLine(to: CGPoint(x: box.minX, y: box.midY))
                    diamond.closeSubpath()
                    context.fill(diamond, with: fill)
                    context.stroke(diamond, with: ink, lineWidth: DS.Stroke.hairlineAdaptive)
                case .buffer:
                    // Open on the inflow (left) side, exactly as the canvas
                    // draws an infinite buffer — which is what every
                    // archetype inserts.
                    let body = box.insetBy(dx: radius * 0.15, dy: radius * 0.25)
                    context.fill(Path(body), with: fill)
                    var open = Path()
                    open.move(to: CGPoint(x: body.minX, y: body.minY))
                    open.addLine(to: CGPoint(x: body.maxX, y: body.minY))
                    open.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
                    open.addLine(to: CGPoint(x: body.minX, y: body.maxY))
                    context.stroke(open, with: ink, lineWidth: DS.Stroke.hairlineAdaptive)
                case .station:
                    context.fill(Path(ellipseIn: box), with: fill)
                    context.stroke(Path(ellipseIn: box), with: ink,
                                   lineWidth: DS.Stroke.hairlineAdaptive)
                case .sink:
                    let shape = Path(roundedRect: box, cornerRadius: DS.Radius.swatch,
                                     style: .continuous)
                    context.fill(shape, with: fill)
                    context.stroke(shape, with: ink, lineWidth: DS.Stroke.hairlineAdaptive)
                }
            }
        }
        .frame(height: DS.Layout.pictureTileSize)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
