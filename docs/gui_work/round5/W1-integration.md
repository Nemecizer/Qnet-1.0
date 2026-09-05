# Round 5 — W1 (Canvas gestures and rendering) integration requests

W1 was assigned no blockers and no verifier findings this round. The single
IMPROVEMENTS.json entry carrying a W1 token is *"The one empty-state component
now has two visual grammars for the same job"*, whose fix lands in
`Sources/Qnet/DSEmptyState.swift` (W4-owned). W1 cannot apply the caller half on
its own — the caller half does not compile until the component grows the API —
so the whole change is written out here, both halves, ready to apply in one pass.

**No W1-owned file was modified this round.** `swift build` and
`DS_SKIP_CONTRAST=1 validation/design_lint.sh` were both run against the tree as
found and both pass.

---

## W1-INT-1 — Give `DSEmptyState` a prominent primary and a second action, and move the canvas call site back into it

1. **ID** — `W1-INT-1`. Completes IMPROVEMENTS.json entry index 31 ("The one
   empty-state component now has two visual grammars for the same job",
   workstream "W4 owns DSEmptyState.swift; W1 owns the NetworkCanvasOverlays.swift
   call site"). No task is half-dead without it: the canvas empty state is fully
   functional today (verified in the running app this round — both buttons draw,
   both are live, both perform their menu item). This is a consistency defect,
   not a behaviour defect.

2. **Target file and anchor** — two coupled edits.

   **(a) `Sources/Qnet/DSEmptyState.swift`.** Anchor, verbatim from today's
   source, lines 29-31 (the stored properties of `struct DSEmptyState`):

   ```swift
       let actionTitle: String?
       let keyboardShortcut: KeyboardShortcut?
       let action: (() -> Void)?
   ```

   and the `actions:` builder of its `ContentUnavailableView`, lines 80-93:

   ```swift
           } actions: {
               if let actionTitle, let action {
                   if let keyboardShortcut {
                       Button(actionTitle, action: action)
                           .controlSize(.regular)
                           .keyboardShortcut(keyboardShortcut)
                           .dsTooltip(actionTitle)
                   } else {
                       Button(actionTitle, action: action)
                           .controlSize(.regular)
                           .dsTooltip(actionTitle)
                   }
               }
           }
   ```

   **(b) `Sources/Qnet/NetworkCanvasOverlays.swift`** (W1-owned), the whole body
   of `struct CanvasEmptyHint`, lines 221-261. Anchor, verbatim, line 250:

   ```swift
                           .buttonStyle(.borderedProminent)
   ```

   This is the third and last raw `.buttonStyle(.borderedProminent)` outside a
   `DS*.swift` file that the critic counted (the other two are
   `AIPaneView.swift:1175` and `MethodChooserView.swift:717`); this request
   removes only the canvas one. The other two are not W1's and are left alone.

3. **Insert / replace**

   **(a) In `DSEmptyState.swift`.** Add, above `struct DSEmptyState`:

   ```swift
   /// One offer in a `DSEmptyState`'s action row.
   ///
   /// `prominent` marks the single primary. Two equally weighted buttons are
   /// two buttons with no primary: the eye has to read both before it can
   /// choose, so at most one offer in a row sets it. `help` is the sentence
   /// the tooltip needs — never the title again, because a tooltip that
   /// repeats the label tells the reader nothing they did not just read;
   /// nil falls back to the title, which is what the single-action
   /// initialiser has always done.
   struct DSEmptyStateAction {
       let title: String
       let help: String?
       let prominent: Bool
       let keyboardShortcut: KeyboardShortcut?
       let action: () -> Void

       init(title: String,
            help: String? = nil,
            prominent: Bool = false,
            keyboardShortcut: KeyboardShortcut? = nil,
            action: @escaping () -> Void) {
           self.title = title
           self.help = help
           self.prominent = prominent
           self.keyboardShortcut = keyboardShortcut
           self.action = action
       }
   }
   ```

   Replace the three stored properties at lines 29-31 with:

   ```swift
       let actions: [DSEmptyStateAction]
   ```

   Keep the existing initialiser exactly as it is spelled today — every current
   call site (`AIPaneView`, `MethodChooserView`, the Status pane, the Inspector,
   Qnet Help, and `DSEmptyState.search(query:)`) keeps compiling unchanged —
   but make it forward:

   ```swift
       init(
           systemImage: String,
           title: String,
           message: String,
           actionTitle: String? = nil,
           keyboardShortcut: KeyboardShortcut? = nil,
           action: (() -> Void)? = nil
       ) {
           self.systemImage = systemImage
           self.title = title
           self.message = message
           if let actionTitle, let action {
               self.actions = [DSEmptyStateAction(title: actionTitle,
                                                  keyboardShortcut: keyboardShortcut,
                                                  action: action)]
           } else {
               self.actions = []
           }
       }

       /// The multi-offer form: the archetype/example pair on the empty
       /// canvas, and any future state that has a primary and a fallback.
       init(
           systemImage: String,
           title: String,
           message: String,
           actions: [DSEmptyStateAction]
       ) {
           self.systemImage = systemImage
           self.title = title
           self.message = message
           self.actions = actions
       }
   ```

   Replace the `actions:` builder at lines 80-93 with:

   ```swift
           } actions: {
               ForEach(Array(actions.enumerated()), id: \.offset) { _, offer in
                   dsEmptyStateButton(offer)
               }
           }
   ```

   (Identity is the offset, deliberately: the row is a fixed, ordered list of
   at most two offers, and a synthesised `Identifiable` id would be freshly
   minted on every `body` evaluation and rebuild both buttons each time.)

   and add, as a private method on `DSEmptyState`:

   ```swift
       /// One offer, drawn the one way. The prominent fill lives here rather
       /// than in a caller so a second empty state cannot invent a third
       /// grammar for the same job.
       @ViewBuilder
       private func dsEmptyStateButton(_ offer: DSEmptyStateAction) -> some View {
           let button = Button(offer.title, action: offer.action)
               .controlSize(.regular)
               .dsTooltip(offer.help ?? offer.title)
           if let shortcut = offer.keyboardShortcut {
               if offer.prominent {
                   button.keyboardShortcut(shortcut).buttonStyle(.borderedProminent)
               } else {
                   button.keyboardShortcut(shortcut)
               }
           } else {
               if offer.prominent {
                   button.buttonStyle(.borderedProminent)
               } else {
                   button
               }
           }
       }
   ```

   Note for the integrator: `ContentUnavailableView`'s `actions:` builder lays
   its buttons out in a column, which is the layout `CanvasEmptyHint` builds by
   hand today (primary above, secondary below). No `VStack` is needed in the
   component.

   **(b) In `NetworkCanvasOverlays.swift`.** Replace the whole of
   `CanvasEmptyHint.body` (lines 221-261, from `    var body: some View {` down
   to and including the closing `    }` of `body`) with:

   ```swift
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
   ```

   Nothing else in `CanvasEmptyHint` changes: `onOpenExample`, `onStartArchetype`,
   the private `Offer` struct and the `offers` ordering comment all stay exactly
   as they are, so the archetype still comes first and an absent offer still
   promotes the other.

4. **New symbols it depends on** — one, and it is created by this same request:
   `DSEmptyStateAction` (declared in `Sources/Qnet/DSEmptyState.swift` by edit
   (a)). Edit (b) must not be applied without edit (a): it does not compile
   against today's `DSEmptyState`. Everything else the snippets touch already
   exists: `DS.Symbol.network`, `dsTooltip(_:)`, `DSEmptyState.search(query:)`.

5. **Gate impact**
   - `validation/design_lint.sh`: the **"empty-state titles are Title Case"**
     rule reads `DSEmptyState(title:` / the `title:` literal — the title stays
     the byte-identical `"No Network Yet"`, so it still passes. The
     **"no borderless push buttons outside DS*.swift"** rule is unaffected
     (neither button is borderless). `.buttonStyle(.borderedProminent)` moves
     from a view file into `DSEmptyState.swift`, which is a `DS*.swift` file;
     no rule counts its occurrences, so the count drops from 3 to 2 with no
     assertion to update.
   - `validation/gui_runtime_contracts.sh`: no string it greps is touched (it
     greps `QnetGUIApp.swift`, `SRBMExporter.swift`, `ctmc_dtandem.py`).
   - `QNET_MENU_AUDIT=1`: no `.keyboardShortcut` is added or removed — both
     canvas offers stay deliberately unbound, as the comment says.
   - The headless Swift unit checks compile one real file each plus stubs;
     none of them compiles `DSEmptyState.swift` or `NetworkCanvasOverlays.swift`,
     so no stub has to grow.

6. **Verification**

   ```sh
   swift build --scratch-path /tmp/qnet-build-int
   DS_SKIP_CONTRAST=1 ./validation/design_lint.sh
   /tmp/qnet-build-int/debug/Qnet &
   ```

   Open a new tab (the `+` at the right of the tab strip) to get an empty
   canvas. The hint must read "No Network Yet", then the message sentence, then
   **"Start from an Archetype…"** drawn in the prominent blue fill, then
   **"Open an Example…"** drawn plain — i.e. pixel-equivalent to today, which is
   the point: the grammar moves into the component without the canvas changing
   appearance. Hover each button and confirm the tooltip is the menu item's
   sentence, not the button's own label. Click "Start from an Archetype…" → the
   Insert Archetype panel opens; leave it open and click the button again → it
   must still be accepted (this is round-4 blocker R6, which is fixed and must
   stay fixed). Press `S` and click through the middle of the message text →
   exactly one station is placed (the text block still opts out of hit-testing).
   Then `pkill -f 'qnet-build-int/debug/Qnet'`.

7. **Priority** — **P1.** The empty state works today; this is the consistency
   half. Nothing is unreachable meanwhile.
