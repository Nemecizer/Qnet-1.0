# Round 5 — W2 integration requests

Two requests, both for the same round-4 improvement: *"Align and Distribute: 3 of 8 commands exist
and none is in the menu bar (headline metric 19 has not moved from its 0 baseline)"*. Round 4
raised the model set from three helpers to six and wired all six into the node context menu; this
round W2 added the two that were still missing — the centre alignments — so the model now offers
the complete eight-command set every diagramming tool ships.

Both requests are surfacing work in files W2 does not own. **The two new model methods have no
call site until at least one of them is applied**, so this improvement is half-shipped by design
and W2 says so rather than pretending otherwise.

The eight methods, all on `NetworkEditorModel` (W2-owned,
`Sources/Qnet/NetworkEditorModel.swift`), all `@MainActor`, all `-> Void`, all no-ops below their
own selection threshold, and all individually undoable through `performMutation` with the undo
name quoted:

| Method | Undo name | Minimum selection | Landed |
| --- | --- | --- | --- |
| `alignSelectedNodesTop()` | "Align Top" | 2 nodes | round ≤ 4 |
| `alignSelectedNodesBottom()` | "Align Bottom" | 2 nodes | round ≤ 4 |
| `alignSelectedNodesLeft()` | "Align Left" | 2 nodes | round ≤ 4 |
| `alignSelectedNodesRight()` | "Align Right" | 2 nodes | round ≤ 4 |
| `alignSelectedNodesHorizontalCentres()` | "Align Horizontal Centres" | 2 nodes | **round 5, new** |
| `alignSelectedNodesVerticalCentres()` | "Align Vertical Centres" | 2 nodes | **round 5, new** |
| `distributeSelectedNodesHorizontally()` | "Distribute Horizontally" | 3 nodes | round ≤ 4 |
| `distributeSelectedNodesVertically()` | "Distribute Vertically" | 3 nodes | round ≤ 4 |

---

## W2-INT-1 — an Arrange submenu in the Network menu

1. **ID** — `W2-INT-1`, completes the round-4 improvement *"Align and Distribute: 3 of 8 commands
   exist and none is in the menu bar"* (headline metric 19). The two new model methods ship
   without it and are then unreachable; the six older ones remain reachable from the node context
   menu either way. **Not shippable without this or W2-INT-2** — a model method nothing calls is
   dead code.

2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift` (W5-owned), inside the Network
   `CommandMenu`. Anchor, quoted verbatim from today's source at line 928-933 (W5 is editing this
   file this round, so match on the quoted text, not the number):

   ```swift
            Button("Generate Random Network…") { actions.generateRandomNetwork() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(sheetPresented)
                .help("Build a random network of a chosen size, topology and utilisation in a new tab")

            Button("Insert Archetype…") { actions.insertArchetype() }
                .disabled(sheetPresented)
                .help("Insert a ready-made network into this canvas at a chosen size and utilisation, as one undoable step")
   ```

   The new submenu goes immediately **before** that `Generate Random Network…` button, after the
   `Straighten and Fit to Window` item and its following `Divider()`.

3. **Insert** — add exactly this, then a `Divider()` between it and `Generate Random Network…`:

   ```swift
            // Align and Distribute, the set every diagramming tool ships.
            // Until now the only route to any of them was the node context
            // menu, which is a route a user has to already know about.
            // `alignEnabled` / `distributeEnabled` mirror the model's own
            // thresholds (2 nodes to align, 3 to distribute) so a greyed
            // item and a no-op method never disagree.
            Menu("Arrange") {
                Button("Align Left") { editor.alignSelectedNodesLeft() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the x of the leftmost one")
                Button("Align Horizontal Centres") { editor.alignSelectedNodesHorizontalCentres() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node onto the vertical line halfway between the leftmost and rightmost of them")
                Button("Align Right") { editor.alignSelectedNodesRight() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the x of the rightmost one")

                Divider()

                Button("Align Top") { editor.alignSelectedNodesTop() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the y of the topmost one")
                Button("Align Vertical Centres") { editor.alignSelectedNodesVerticalCentres() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node onto the horizontal line halfway between the topmost and bottommost of them")
                Button("Align Bottom") { editor.alignSelectedNodesBottom() }
                    .disabled(!alignEnabled)
                    .help("Snap every selected node to the y of the bottommost one")

                Divider()

                Button("Distribute Horizontally") { editor.distributeSelectedNodesHorizontally() }
                    .disabled(!distributeEnabled)
                    .help("Keep the leftmost and rightmost selected nodes and space the rest evenly along x (needs three or more)")
                Button("Distribute Vertically") { editor.distributeSelectedNodesVertically() }
                    .disabled(!distributeEnabled)
                    .help("Keep the topmost and bottommost selected nodes and space the rest evenly along y (needs three or more)")
            }
   ```

   and, beside the other computed gates in the same `Commands` type (the file already computes
   `hasNodeSelection` and `hasSelection` there — put these next to them):

   ```swift
    /// The model aligns from two nodes and distributes from three; the menu
    /// says the same thing rather than offering a command that silently
    /// does nothing.
    private var alignEnabled: Bool {
        editor.selectedNodeIDs.count >= 2 && !sheetPresented
    }
    private var distributeEnabled: Bool {
        editor.selectedNodeIDs.count >= 3 && !sheetPresented
    }
   ```

   **No `.keyboardShortcut` anywhere in this insert**, deliberately — see Gate impact.

4. **New symbols it depends on** — two, both added by W2 this round in
   `Sources/Qnet/NetworkEditorModel.swift`, immediately above
   `distributeSelectedNodesHorizontally()`:

   - `func alignSelectedNodesHorizontalCentres()`
   - `func alignSelectedNodesVerticalCentres()`

   The other six methods and `editor.selectedNodeIDs` already exist and are already called from
   `NetworkCanvasView.swift:1406-1411`. Nothing else is new: `Menu`, `Divider`, `.disabled`,
   `.help` and `sheetPresented` are all already used in this file.

5. **Gate impact** — checked by name:
   - `validation/design_lint.sh`: the submenu adds a `Divider()` **inside a `Menu`**, which the
     "separators are DSRule outside menus" rule permits (the existing Network menu already
     carries two). No `DSEmptyState` title, no token, no `▸` inside a title (the ▸ rule applies to
     menu-path prose; "Arrange" carries none). No bare ⌘-digit. Verified green on W2's tree with
     `DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` before and after the model half.
   - `QNET_MENU_AUDIT=1`: **no new key equivalent is requested**, so the audit has nothing to
     re-clear. The natural shortcuts here (⌘⌥←/→/↑/↓) collide with text-field word motion and with
     the canvas nudge; picking one is a design decision W5 should make deliberately rather than
     inherit from this document.
   - `validation/gui_runtime_contracts.sh`: greps `QnetGUIApp.swift`, `SRBMExporter.swift` and
     `ctmc_dtandem.py` only. Untouched; passed on W2's tree.
   - The headless unit checks compile one real file each; `QnetCommands.swift` is not one of them.

6. **Verification** — build, launch, place three nodes, ⌘A, then open Network ▸ Arrange: all eight
   items are enabled and none is greyed. Click Align Vertical Centres; the three nodes land on one
   horizontal line, the status log gains
   `Aligned 3 nodes to their vertical centre.`, and ⌘Z restores the layout in one step. With only
   two nodes selected the six Align items stay enabled and the two Distribute items grey out. With
   nothing selected the whole submenu greys out.

7. **Priority** — **P1**. Six of the eight commands are already reachable from the node context
   menu, so no capability is lost without this; what is lost is the menu-bar route the headline
   metric measures, and the two centre alignments have no other route at all.

---

## W2-INT-2 — the two centre alignments in the node context menu

1. **ID** — `W2-INT-2`, same improvement. Independent of W2-INT-1 and much smaller: it makes the
   context menu list the same eight commands the model offers, instead of six of them. If only one
   of the two requests can be applied, apply W2-INT-1 — it is the one the headline metric counts.

2. **Target file and anchor** — `Sources/Qnet/NetworkCanvasView.swift` (W1-owned), in
   `nodeContextMenu(_:)`. Anchor, quoted verbatim from today's source at line 1404-1412:

   ```swift
        if editor.selectedNodeIDs.count >= 2 && editor.selectedNodeIDs.contains(node.id) {
            Button("Align Top") { editor.alignSelectedNodesTop() }
            Button("Align Bottom") { editor.alignSelectedNodesBottom() }
            Button("Align Left") { editor.alignSelectedNodesLeft() }
            Button("Align Right") { editor.alignSelectedNodesRight() }
            Button("Distribute Horizontally") { editor.distributeSelectedNodesHorizontally() }
            Button("Distribute Vertically") { editor.distributeSelectedNodesVertically() }
            Divider()
        }
   ```

3. **Replace** that block with exactly:

   ```swift
        if editor.selectedNodeIDs.count >= 2 && editor.selectedNodeIDs.contains(node.id) {
            Button("Align Top") { editor.alignSelectedNodesTop() }
            Button("Align Vertical Centres") { editor.alignSelectedNodesVerticalCentres() }
            Button("Align Bottom") { editor.alignSelectedNodesBottom() }
            Button("Align Left") { editor.alignSelectedNodesLeft() }
            Button("Align Horizontal Centres") { editor.alignSelectedNodesHorizontalCentres() }
            Button("Align Right") { editor.alignSelectedNodesRight() }
            Button("Distribute Horizontally") { editor.distributeSelectedNodesHorizontally() }
            Button("Distribute Vertically") { editor.distributeSelectedNodesVertically() }
            Divider()
        }
   ```

   The six existing titles are byte-identical to what ships today, deliberately: the context menu
   and the menu bar must read the same. Only two lines are added, and the ordering now runs
   top → centre → bottom, then left → centre → right.

4. **New symbols it depends on** — the same two W2 methods listed under W2-INT-1 §4. Nothing else.

5. **Gate impact** — none. No new `Divider()` (the existing one is unchanged and is inside a menu),
   no `.keyboardShortcut`, no token, no `DSEmptyState` title, no `▸`. `design_lint.sh` and
   `gui_runtime_contracts.sh` both pass on W2's tree with the model half in place.

6. **Verification** — select two nodes, right-click one of them: the menu lists eight arrange
   commands rather than six. Choose Align Horizontal Centres; both nodes land on one vertical line,
   the status log gains `Aligned 2 nodes to their horizontal centre.`, and one ⌘Z puts them back.

7. **Priority** — **P1**. Same reason as W2-INT-1, and strictly smaller.
