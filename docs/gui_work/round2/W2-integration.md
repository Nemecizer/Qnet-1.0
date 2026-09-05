# W2 — integration requests, round 2

Four requests, all independent of one another.

**W2-INT-4 is the second half of a blocker fix** and the only one marked P0: the model side
(`insertSubnetwork` no longer converts an occupied document's buffer regime) is landed and safe on
its own, but until INT-4 is applied the sheet's Buffers control still opens on "Infinite" for a
document that is on finite buffers — it lies about the document rather than damaging it.

W2-INT-5 completes the round-1 pre-seed `pendingFitOnAppear`, which now has a producer and no
consumer. W2-INT-6 is a defect found while verifying W2-03 and belongs to W6. W2-INT-7 is one
changelog bullet.

---

## W2-INT-4 — the archetype gallery must open on the document's own buffer regime

1. **ID** — `W2-INT-4`, completes the round-2 blocker *"Inserting an archetype silently converts the
   whole document's buffer regime, and the gallery never seeds itself from the document."* The model
   half is **already landed**: `NetworkEditorModel.insertSubnetwork` now assigns `infiniteBuffers`
   only when the canvas is empty or the incoming block already agrees, and says so in the status log
   otherwise. This request is the sheet half. Shippable without it — the damage is fixed either way
   — but the control still shows a value that is not the document's.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, inside the
   `.sheet(isPresented: $showArchetypeSheet)` modifier. Anchor quoted verbatim from today's source,
   lines 755–757:

   ```swift
                       ArchetypeGallerySheet(
                           canvasNodeCount: activeEditor.nodes.count,
                           canvasSourceCount: activeEditor.nodes.filter { $0.kind == .source }.count,
   ```

3. **Insert / replace** — insert ONE line immediately after the `canvasSourceCount:` line
   (i.e. as the third argument, before `onCancel:`):

   ```swift
                           initialInfiniteBuffers: activeEditor.infiniteBuffers,
   ```

   Nothing else in the closure changes. `built.infiniteBuffers` still goes to
   `insertSubnetwork(infiniteBuffers:)`; the model decides whether it may be adopted.

4. **New symbols it depends on** — `ArchetypeGallerySheet.init` gained
   `initialInfiniteBuffers: Bool = true` (`Sources/Qnet/ArchetypeGallerySheet.swift`, explicit
   memberwise-style `init` at the top of the struct; the parameter seeds
   `@State private var infiniteBuffers`). **It has a default**, so the call site compiles today
   without this change — that is deliberate, so the tree stays green until the integrator runs, and
   it is also why this request is easy to forget. `NetworkEditorModel.infiniteBuffers` is an
   existing `@Published var`.

5. **Gate impact** — none. No shell string, no menu item, no keyboard shortcut, no DS token.
   `validation/gui_runtime_contracts.sh` does not read this region (it asserts the awk formatters,
   the two shell wrappers, the `commandWithCleanup` count and the EXIT/INT/TERM traps).

6. **Verification** — open any `input/examples/*.fin.bnet` (a finite-buffer network), then
   File ▸ New from Template…: the Buffers control reads **Finite** and the Capacity field is
   showing. Switch it to Infinite and press Insert: the network stays finite, and the Status pane
   gains "… The network stays on finite buffers — an insert never re-interprets the stations already
   on the canvas. Use Network ▸ Buffer Model to change the whole network."

7. **Priority** — **P0**.

---

## W2-INT-5 — consume `pendingFitOnAppear` on the canvas

1. **ID** — `W2-INT-5`, completes the round-2 polish item *"Dead @Published: `pendingFitOnAppear`
   was seeded for W1 and never used."* The producer is now real:
   `NetworkEditorModel.insertSubnetwork` sets `pendingFitOnAppear = true` after every bulk insert.
   Without this request the flag is written and never read, and an archetype inserted clear to the
   right of a large existing network can land outside the viewport with no indication that anything
   happened except a status line.

2. **Target file and anchor** — `Sources/Qnet/NetworkCanvasView.swift` (owned by **W1**), inside
   `NetworkCanvasView.body`'s `GeometryReader`. Anchor quoted verbatim from today's source,
   lines 78–81:

   ```swift
               .onAppear { editor.canvasViewportSize = geometry.size }
               .onChange(of: geometry.size) { _, newSize in
                   editor.canvasViewportSize = newSize
               }
   ```

3. **Insert / replace**

   **before →** the four anchor lines.

   **after →**

   ```swift
               .onAppear {
                   editor.canvasViewportSize = geometry.size
                   consumePendingFit()
               }
               .onChange(of: geometry.size) { _, newSize in
                   editor.canvasViewportSize = newSize
                   consumePendingFit()
               }
               // A bulk insert (File ▸ New from Template…) can land a whole
               // sub-network clear to the right of everything the viewport
               // shows. The model raises the flag; only this side knows the
               // viewport size, so only this side can act on it.
               .onChange(of: editor.pendingFitOnAppear) { _, _ in consumePendingFit() }
   ```

   and add this method to `NetworkCanvasView`, immediately after `body`:

   ```swift
       /// One-shot "frame the content" request from the model
       /// (`NetworkEditorModel.pendingFitOnAppear`). Cleared BEFORE the fit so
       /// the re-layout the fit itself provokes cannot run it a second time,
       /// and skipped until the viewport has a real size — `zoomToFit()` is a
       /// no-op below 1 pt and would silently swallow the request.
       private func consumePendingFit() {
           guard editor.pendingFitOnAppear, editor.canvasViewportSize.width > 1 else { return }
           editor.pendingFitOnAppear = false
           editor.zoomToFit()
       }
   ```

4. **New symbols it depends on** — none new this round.
   `NetworkEditorModel.pendingFitOnAppear` is the round-1 pre-seed (`NetworkEditorModel.swift:436`,
   `@Published var pendingFitOnAppear: Bool = false`); `zoomToFit()` and `canvasViewportSize` are
   existing members (`NetworkEditorModel.swift:1939` and the viewport publisher this same anchor
   writes to).

5. **Gate impact** — none. No DS token, no `Divider()`, no `DSEmptyState` title, no menu path, no
   shortcut. `validation/design_lint.sh` and `validation/gui_runtime_contracts.sh` are unaffected.

6. **Verification** — build a network that fills the canvas, scroll it so the right-hand edge is off
   screen, then File ▸ New from Template… → Insert. The view zooms out to frame both networks
   instead of leaving the new one off-screen. ⌘Z afterwards undoes the insert (the fit is not part of
   the undo step and is not expected to be).

7. **Priority** — **P1** (the insert is still correct without it; only the framing is missing).

---

## W2-INT-6 — `solveTrafficEquations` silently returns the right-hand side on a singular system

1. **ID** — `W2-INT-6`. Not a completion of any W2 task — a defect found while verifying **W2-03**
   (the station self-loop) against `--dump-rho`. It is **pre-existing and not caused by W2-03**: any
   routing cycle whose probabilities leave no exit reaches it, and the Link tool has always allowed
   those. W2-03 makes it one gesture cheaper to reach, which is why it is being reported now.

2. **Target file and anchor** — `Sources/Qnet/SRBMExporter.swift` (owned by **W6**),
   `private static func solveTrafficEquations(P:externalRates:d:)`. Two anchors, quoted verbatim:

   * line 945: `            if abs(pivot) < 1e-15 { continue }`
   * lines 962–964:

     ```swift
                 if abs(A[i][i]) > 1e-15 {
                     x[i] /= A[i][i]
                 }
     ```

3. **Insert / replace** — this one is a **decision, not a patch**, so it is stated as a requirement
   rather than as literal Swift: the singular case must not be reported as a solved system. The two
   guards above skip the division and leave `x[i] = rhs[i]`, i.e. the *external* arrival rate, which
   is then printed as if it were the solved throughput.

   Reproduction, exactly as run:

   ```sh
   swift run Qnet --dump-rho /tmp/qnet-build-W2-nets/selfloop.bnet
   ```

   (`Src1 → B1 → S1 → Sink1`, plus one `S1 → S1` link, both of S1's outgoing links at p = 1.0.)
   It prints, with no warning of any kind:

   ```
   d=1, K=1, infiniteBuffers=true
   S1: α=1.000000  μ_eff=1.111111  c=1.111111  ρ=0.900000
   aggregatedP (1×1):
     S1: 1.0000
   AnalyticalTractability.assess(allowGCDG=true)  → kind=exactJackson, isTractable=true
   ```

   With P[1][1] = 1.0 the traffic equation is α = λ + α, which has no finite solution: the station is
   unstable and α is unbounded. Reporting α = 1.0, ρ = 0.900 and "exact Jackson" is a wrong number
   presented as a right one — the one failure mode `docs/STEADY_STATE_METHODS.md`'s vocabulary
   exists to prevent.

   Suggested shape, for W6 to accept or replace: give `solveTrafficEquations` a failable return, and
   have `computeData` map a singular system to a new `NetworkError` case alongside
   `.routingProbabilityExceedsOne` — the row sum is ≤ 1 here, so that existing check cannot catch it.
   The message should name the station and say why: *"Routing from S1 returns every job to S1, so its
   throughput is unbounded. Lower P[S1][S1] below 1."*

   Note the neighbouring subtlety, which is also why the existing guard misses this: the row-sum
   check at `SRBMExporter.swift:170-176` only accumulates links that `resolveTargetStation` maps to a
   station, so an outgoing link to a *sink* contributes nothing to the sum. In the file above S1's
   two links sum to 2.0 as the user sees them in the Inspector, but to 1.0 as the matrix sees them.

4. **New symbols it depends on** — none from W2.

5. **Gate impact** — `validation/gui_runtime_contracts.sh` **does** read `SRBMExporter.swift`, but
   its assertions there are about the export text, not about this function; check the script's
   `SRBMExporter` block before touching anything that prints. A new `NetworkError` case is a new
   user-facing string and belongs in whatever error-text switch already lists
   `.routingProbabilityExceedsOne`.

6. **Verification** — the `--dump-rho` command above must report the error instead of ρ = 0.900. The
   five archetype shapes must be unaffected; W2 verified them today and they are the regression set:

   ```
   tandem3    → S1..S3 ρ=0.900000, kind=exactJackson
   rework3    → S1..S3 α=1.428571, ρ=0.900000, kind=exactJackson
   reentrant  → S1,S2  α=1.428571, ρ=0.900000, kind=exactJackson
   fork       → S1 α=1.000000, S2/S3 α=0.500000, all ρ=0.900000, kind=exactJackson
   twoclass   → d=2, K=2, class 1 α=[1,0], class 2 α=[0,1], kind=exactSkewSymmetric
   ```

   (Those six `.bnet` files are in `/tmp/qnet-build-W2-nets/`; they are hand-written copies of what
   `NetworkArchetypeBuilder` emits at its defaults, so they can be regenerated from the builder.)

7. **Priority** — **P1**. It is severe (a silently wrong ρ) but pre-existing, reachable without any
   round-1 or round-2 change, and out of W2's ownership entirely.

---

## W2-INT-7 — one changelog bullet for the round-2 model work

1. **ID** — `W2-INT-7`. Documentation only; nothing is half-dead without it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (owned by **W6**), the topmost
   `timestamp: nil` entry. Anchor quoted verbatim — the END of the existing round-1 W2 bullet,
   line 46:

   ```swift
                   "Delete removes a selected link. ⌫ with a link selected used to do nothing, and the undo step is now named for what actually went — Delete Link, Delete Node or Delete Selection. A station may also link to itself now: a rework loop that repeats a station’s own service is a real network, and only sources, sinks and buffers still refuse (each says why). Clear Canvas keeps the promise its alert makes — one Undo brings the network back, numbering included.",
   ```

3. **Insert / replace** — insert this ONE array element immediately after that line:

   ```swift
                   "A network is born at a useful load. A station placed by hand is served at μ = 1.1111111 against the default source rate of λ = 1, so the first chain anyone builds sits at ρ = 0.900 instead of exactly 1.000 — the boundary of instability, where the analysis used to short-circuit to \"unstable\" and paint every ρ in red. Sources arrive Poisson, the way every bundled example spells them. The status line says the number rather than merely applying it. The flag bar now follows the build: adding a node, drawing a link, deleting a selection, clearing the canvas and inserting a template all invalidate the analysis and re-run it quietly, where before only a parameter edit did, so the Analytical, Re-entrant and Warnings pills could describe a network that no longer existed for a whole session. Dragging nodes does not re-run it — layout is not an input to any of them. Inserting a template into a canvas that already has a source now moves the inserted links onto the customer class its own source actually owns, instead of leaving a second class with no routing at all, and an insert never re-interprets the buffer regime of the stations already on the canvas. The template gallery draws each network it offers.",
   ```

   The escaped quotes inside the string are required as written.

4. **New symbols it depends on** — none.

5. **Gate impact** — `validation/design_lint.sh` reads this file as prose: the bullet contains no
   `→` in a menu path (it names no menu), no bare ⌘-digit, and no TeX braces. It is one element of an
   existing `[String]`; no version or timestamp changes, and `AppVersion.swift` stays at 0.90.34.

6. **Verification** — `swift build`, then Help ▸ Release Notes: the new bullet appears under the
   in-development entry, below the existing "Delete removes a selected link" bullet.

7. **Priority** — **P1**.
