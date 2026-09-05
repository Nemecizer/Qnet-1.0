# W2 — integration requests, round 1

Three requests. **W2-INT-1 and W2-INT-2 are one atomic change**: INT-2 adds a field to
`QnetCommandActions`, and that struct has no memberwise default, so applying either one alone
does not compile. Apply both or neither.

W2-INT-3 is independent and belongs to W2-06, whose model-side change is **not** in this round.

---

## W2-INT-1 — present the archetype gallery and perform the insert

1. **ID** — `W2-INT-1`, completes **W2-01**. W2-01 is **not shippable without it**: the sheet and
   the builder are on disk and compile, but nothing in the app can open the sheet. Everything else
   of W2-01 (the library, the builder, `insertSubnetwork`) is already landed and verified.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, four places in
   `struct QnetGUIApp`. Anchors quoted verbatim from today's source:

   * (a) line 552: `    @State private var showGenerateRandomSheet = false`
   * (b) line 745: `                .sheet(isPresented: $showGenerateRandomSheet) {`
   * (c) line 1587: `        showStartupDependencyCheck || showGenerateRandomSheet`
   * (d) line 1040: `            generateRandomNetwork: { generateRandomNetwork() },`
     (inside the `QnetCommandActions(` literal that starts at line 1011)
   * (e) line 1154: `        showGenerateRandomSheet = true` — the body of
     `private func generateRandomNetwork()`; insert the new function immediately **after** that
     function's closing brace.

3. **Insert / replace**

   **(a) — insert one line after the anchor:**

   ```swift
       @State private var showArchetypeSheet = false
   ```

   **(b) — insert this whole modifier immediately BEFORE the anchor line** (so it sits beside the
   Generate Random Network sheet, in the same `.sheet` run):

   ```swift
                   // Archetype gallery — builds one of the five starting
                   // networks (tandem, M/M/c, fork, rework loop, re-entrant
                   // pair) at a chosen size and ρ and inserts it into the
                   // CURRENT canvas as ONE undoable step. The insert itself
                   // is `NetworkEditorModel.insertSubnetwork`, which owns
                   // naming, id remapping and the undo entry; this closure
                   // only builds and hands over.
                   .sheet(isPresented: $showArchetypeSheet) {
                       ArchetypeGallerySheet(
                           canvasNodeCount: activeEditor.nodes.count,
                           canvasSourceCount: activeEditor.nodes.filter { $0.kind == .source }.count,
                           onCancel: { showArchetypeSheet = false },
                           onInsert: { archetype, parameters in
                               showArchetypeSheet = false
                               let built = NetworkArchetypeBuilder.build(archetype, parameters)
                               activeEditor.insertSubnetwork(
                                   nodes: built.nodes,
                                   links: built.links,
                                   infiniteBuffers: built.infiniteBuffers,
                                   at: NetworkArchetypeBuilder.canvasOrigin,
                                   actionName: "Insert " + NetworkArchetypeBuilder.blueprint(for: archetype).title,
                                   detail: NetworkArchetypeBuilder.summary(archetype, parameters)
                               )
                           }
                       )
                   }
   ```

   **(c) — replace the anchor line:**

   before → `        showStartupDependencyCheck || showGenerateRandomSheet`

   after  → `        showStartupDependencyCheck || showGenerateRandomSheet || showArchetypeSheet`

   **(d) — insert one line immediately after the anchor line:**

   ```swift
               insertArchetype: { insertArchetype() },
   ```

   **(e) — insert this function after `generateRandomNetwork()`'s closing brace:**

   ```swift
       /// File ▸ New from Template… (⌥⌘N) and Network ▸ Insert Archetype… —
       /// opens the archetype gallery. Both items open the SAME sheet and the
       /// insert lands in the current canvas: on an empty canvas that is
       /// "new from a template", and on an occupied one the sheet says, in
       /// its own footer, that the archetype goes clear to the right of what
       /// is already there.
       private func insertArchetype() {
           showArchetypeSheet = true
       }
   ```

4. **New symbols it depends on** — all added by W2 this round and already building:

   | symbol | file | declaration |
   |---|---|---|
   | `ArchetypeGallerySheet` | `Sources/Qnet/ArchetypeGallerySheet.swift` | `struct ArchetypeGallerySheet: View` with `let canvasNodeCount: Int`, `let canvasSourceCount: Int`, `let onCancel: () -> Void`, `let onInsert: (NetworkArchetype, ArchetypeParameters) -> Void` |
   | `NetworkArchetype` | `Sources/Qnet/NetworkArchetypes.swift` | `enum NetworkArchetype: String, CaseIterable, Identifiable` |
   | `ArchetypeParameters` | `Sources/Qnet/NetworkArchetypes.swift` | `struct ArchetypeParameters: Equatable` |
   | `NetworkArchetypeBuilder.build` | `Sources/Qnet/NetworkArchetypes.swift` | `static func build(_ archetype: NetworkArchetype, _ params: ArchetypeParameters, origin: CGPoint = canvasOrigin) -> RandomNetworkGenerator.Result` |
   | `NetworkArchetypeBuilder.canvasOrigin` | `Sources/Qnet/NetworkArchetypes.swift` | `nonisolated static let canvasOrigin: CGPoint` |
   | `NetworkArchetypeBuilder.blueprint(for:)` | `Sources/Qnet/NetworkArchetypes.swift` | `static func blueprint(for archetype: NetworkArchetype) -> ArchetypeBlueprint` (`.title` is a `String`) |
   | `insertSubnetwork` | `Sources/Qnet/NetworkEditorModel.swift` | `@discardableResult func insertSubnetwork(nodes: [NetworkNode], links: [NetworkLink], infiniteBuffers: Bool, at origin: CGPoint, actionName: String, detail: String? = nil) -> Set<UUID>` |
   | `NetworkArchetypeBuilder.summary` | `Sources/Qnet/NetworkArchetypes.swift` | `static func summary(_ archetype: NetworkArchetype, _ params: ArchetypeParameters) -> String` — "3 stations, 8 nodes, 7 links, λ = 1.000, ρ = 0.900 at every station" |
   | `insertArchetype` (the actions field) | `Sources/Qnet/QnetCommands.swift` | added by **W2-INT-2**; `var insertArchetype: () -> Void` |

5. **Gate impact** — none for `validation/gui_runtime_contracts.sh`: it greps the awk formatters,
   the two shell wrappers, the `commandWithCleanup` count and the EXIT/INT/TERM traps, and this
   change touches none of them (no shell string, no Run action). No `Divider()`, no `DSEmptyState`
   title, no menu-path arrow and no ⌘-digit are added here, so `validation/design_lint.sh` is
   unaffected by this half. The `.keyboardShortcut` lives in W2-INT-2, not here.

6. **Verification** — `swift build`, then launch and press ⌥⌘N on an empty canvas: the sheet opens,
   Tandem Line is one of five entries, and Insert produces 8 nodes / 7 links. Then ⌘Z once: the
   canvas empties and the Edit menu reads "Undo Insert Tandem Line". Headless proof that the
   inserted network is correct, if you want it without the GUI: the same builder output run through
   `swift run Qnet --dump-rho` reports `ρ=0.900000` at every station and
   `kind=exactJackson` (W2 ran this for all five archetypes).

7. **Priority** — **P0**.

---

## W2-INT-2 — the two menu items

1. **ID** — `W2-INT-2`, completes **W2-01**. Not shippable without it (nothing invokes
   `insertArchetype`), and it does not compile without W2-INT-1(d).

2. **Target file and anchor** — `Sources/Qnet/QnetCommands.swift`, three places.
   Anchors quoted verbatim from today's source:

   * (a) line 29: `    var generateRandomNetwork: () -> Void` (in `struct QnetCommandActions`)
   * (b) lines 239–241, in `private var fileMenu: some Commands`:

     ```swift
                 Button("Open Example…") { actions.openExample() }
                     .keyboardShortcut("o", modifiers: [.command, .shift])
                     .help("Open one of the bundled literature networks")
     ```
   * (c) lines 759–762, at the end of `private var networkMenu: some Commands`:

     ```swift
                 Button("Generate Random Network…") { actions.generateRandomNetwork() }
                     .keyboardShortcut("r", modifiers: [.command, .shift])
                     .disabled(sheetPresented)
                     .help("Build a random network of a chosen size, topology and utilisation in a new tab")
     ```

3. **Insert / replace**

   **(a) — insert one line immediately after the anchor line:**

   ```swift
       var insertArchetype: () -> Void
   ```

   **(b) — insert immediately AFTER the three anchor lines (before the `Divider()` that follows):**

   ```swift
               Button("New from Template…") { actions.insertArchetype() }
                   .keyboardShortcut("n", modifiers: [.command, .option])
                   .disabled(sheetPresented)
                   .help("Insert a ready-made network — tandem line, M/M/c station, fork, rework loop or re-entrant pair — at a chosen size and utilisation, as one undoable step")
   ```

   **(c) — insert immediately AFTER the four anchor lines (still inside `CommandMenu("Network")`), as the last item of the Network menu:**

   ```swift
               Button("Insert Archetype…") { actions.insertArchetype() }
                   .disabled(sheetPresented)
                   .help("Insert a ready-made network into this canvas at a chosen size and utilisation, as one undoable step")
   ```

   Both items open the same sheet on purpose: File is where a user goes to start a document, and
   Network is where the other network-building command (Generate Random Network…) already lives.
   Only the File item carries the key equivalent — one command, one shortcut.

4. **New symbols it depends on** — `insertArchetype` on `QnetCommandActions` is added by (a) of
   this same request and initialised by W2-INT-1(d). Nothing else.

5. **Gate impact**
   * `validation/design_lint.sh`: adds no `Divider()`, no `DSEmptyState` title, no `→` in a menu
     path and no bare ⌘-digit (⌥⌘N is a letter). The `.help(…)` strings contain an em dash and no
     TeX braces. Clean as written — do not reword them into a "Settings → …" shape.
   * `QNET_MENU_AUDIT=1` **must be re-cleared**: this adds one key equivalent, ⌥⌘N. It was verified
     free against every `.keyboardShortcut` in `QnetCommands.swift` and `WorkspaceCommands.swift`
     on the day this was written (⌘N is New Network; ⌥⌘ is otherwise used only with digits, `=`,
     `-`, `w`, `c`, `a`, `g`, `m`, `s`, `q`, `b`). If another workstream has since claimed ⌥⌘N,
     drop the `.keyboardShortcut` line rather than moving the item — the Network-menu twin keeps
     the feature reachable.
   * `validation/gui_runtime_contracts.sh`: untouched (it does not read `QnetCommands.swift`).

6. **Verification** — `swift build`, then open the File menu: "New from Template…" sits under
   "Open Example…" showing ⌥⌘N. Open the Network menu: "Insert Archetype…" is the last item. Both
   open the same sheet. `QNET_MENU_AUDIT=1 swift run Qnet` reports no duplicate key equivalent.

7. **Priority** — **P0**.

---

## W2-INT-3 — debounce the analysis-invalidation notification (prerequisite for W2-06)

1. **ID** — `W2-INT-3`, prerequisite for **W2-06**. W2-06's model-side change (posting
   `.bnetNetworkParametersDidChange` from structural mutations, not only parameter ones) is
   **deliberately NOT in this round** — see the honesty note at the end. This request is the
   receive-side half, it is **safe and correct on its own**, and applying it first means W2-06 can
   land in round 2 as a two-line model change with no performance cliff.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, lines 843–850, quoted verbatim:

   ```swift
                   .onReceive(
                       NotificationCenter.default.publisher(for: .bnetNetworkParametersDidChange)
                   ) { notification in
                       guard let changed = notification.object as? NetworkEditorModel,
                             changed === activeEditor else { return }
                       analyzeActiveTabIfNeeded(quiet: true)
                   }
   ```

3. **Insert / replace** — replace the publisher expression only, leaving the closure body exactly
   as it is:

   before →

   ```swift
                       NotificationCenter.default.publisher(for: .bnetNetworkParametersDidChange)
   ```

   after →

   ```swift
                       // Coalesce bursts: once the STRUCTURAL mutations post this
                       // too (W2-06), a fast sequence of edits — dragging out a
                       // chain of links, deleting a multi-selection — would
                       // otherwise re-run SRBMExporter.computeData once per step.
                       // 150 ms is the same window the utilisation badges already
                       // settle on (NetworkEditorModel.init, lines 21–26), so the
                       // two silent recomputes stay in step.
                       NotificationCenter.default.publisher(for: .bnetNetworkParametersDidChange)
                           .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
   ```

   `Combine` and `DispatchQueue` are already available in this file (`import Combine` at the top of
   the module's other files and `DispatchQueue.main` used by the existing scheduler calls); if the
   compiler disagrees, add `import Combine` to `QnetGUIApp.swift`.

4. **New symbols it depends on** — none. Nothing W2 added this round is referenced.

5. **Gate impact** — none. No shell string, no menu item, no DS token. `gui_runtime_contracts.sh`
   does not read this region (it asserts the awk formatters, the trap pattern, the
   `commandWithCleanup` count and `${PIPESTATUS[0]}`).

6. **Verification** — `swift build`, then edit a station's service rate in the Inspector and press
   Save: the flag bar's pills still refresh, now ~150 ms later. Nothing else changes this round,
   because nothing new posts the notification yet.

7. **Priority** — **P1 this round** (it changes nothing user-visible on its own), and **P0 for
   whoever lands W2-06's model-side post** — that post must not ship before this debounce.

---

### Honesty note on W2-06

W2-06 was **not** assigned to W2 for round 1 and its model-side change is not in the tree. Beyond
the debounce above, the round-2 implementation needs one thing the backlog's `implementation`
field does not mention: the before/after comparison in `performMutation` / `endMutation` must be
**position-blind**. `endMutation`'s existing test is `before.nodes == nodes`, and a node drag
changes `nodes`, so reusing it verbatim would re-run the analysis on every drag commit — which the
task's own acceptance criteria forbid ("Dragging a node (positions only) does NOT re-run the
analysis"). The fix is a structural fingerprint over ids, kinds, names, buffer sizes, server
counts, distributions and links — everything the analysis reads and nothing it does not.
