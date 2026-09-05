# W2 — integration requests, round 3

Two requests, independent of one another, neither of them blocking a W2 task.

**W2-INT-8 is a re-file.** It was raised as `W2-INT-6` in round 2, was not applied, and is still
reproducible against today's tree — a silently wrong ρ printed as an exact Jackson answer. It is in
a W6-owned file and W2 cannot touch it. **W2-INT-9** is one changelog bullet.

Round-2's other three requests (`W2-INT-4` gallery buffer seed, `W2-INT-5` `pendingFitOnAppear`
consumer, `W2-INT-7` changelog bullet) were all applied and verified present today, so they are not
repeated here.

---

## W2-INT-8 — `solveTrafficEquations` still returns the right-hand side on a singular system

1. **ID** — `W2-INT-8` (re-file of round-2's `W2-INT-6`, unapplied). Not a completion of any W2
   task — a defect found while verifying **W2-03** (the station self-loop) against `--dump-rho`.
   It is **pre-existing and not caused by W2-03**: any routing cycle whose probabilities leave no
   exit reaches it, and the Link tool has always allowed those. W2-03 makes it one gesture cheaper
   to reach. Every W2 task ships without it.

2. **Target file and anchor** — `Sources/Qnet/SRBMExporter.swift` (owned by **W6**),
   `private static func solveTrafficEquations(P:externalRates:d:)`. Two anchors, quoted verbatim
   from today's source:

   * line 945: `            if abs(pivot) < 1e-15 { continue }`
   * lines 963–965:

     ```swift
                 if abs(A[i][i]) > 1e-15 {
                     x[i] /= A[i][i]
                 }
     ```

3. **Insert / replace** — a **decision, not a patch**, so it is stated as a requirement: the
   singular case must not be reported as a solved system. Both guards skip the division and leave
   `x[i] = rhs[i]`, i.e. the *external* arrival rate, which is then printed as if it were the solved
   throughput.

   Reproduction, re-run today against `/tmp/qnet-build-W2/debug/Qnet`:

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
     means(Exact E[N]  (Jackson)): S1=9.0000
   ```

   With P[1][1] = 1.0 the traffic equation is α = λ + α, which has no finite solution: the station
   is unstable and α is unbounded. Reporting α = 1.0, ρ = 0.900, "exact Jackson" and E[N] = 9.0 is a
   wrong number presented as a right one — the failure mode `docs/STEADY_STATE_METHODS.md`'s
   vocabulary exists to prevent. `AnalyticalTractability` cannot defend against it, because it is
   handed the already-wrong α and every one of its own guards (ρ < 1, exponential everywhere,
   infinite buffers) passes on that α.

   Suggested shape, for W6 to accept or replace: give `solveTrafficEquations` a failable return, and
   have `computeData` map a singular system to a new `NetworkError` case alongside
   `.routingProbabilityExceedsOne` — the row sum is ≤ 1 here, so that existing check cannot catch
   it. The message should name the station and say why: *"Routing from S1 returns every job to S1,
   so its throughput is unbounded. Lower P[S1][S1] below 1."*

   Note the neighbouring subtlety, which is also why the existing guard misses this: the row-sum
   check at `SRBMExporter.swift:173-177` only accumulates links that `resolveTargetStation` maps to
   a station, so an outgoing link to a *sink* contributes nothing to the sum. In the file above S1's
   two links sum to 2.0 as the user sees them in the Inspector, but to 1.0 as the matrix sees them.

4. **New symbols it depends on** — none from W2.

5. **Gate impact** — `validation/gui_runtime_contracts.sh` **does** read `SRBMExporter.swift`, but
   its assertions there are about the exported text, not about this function; check the script's
   `SRBMExporter` block before touching anything that prints. A new `NetworkError` case is a new
   user-facing string and belongs in whatever error-text switch already lists
   `.routingProbabilityExceedsOne`.

6. **Verification** — the `--dump-rho` command above must report the error instead of ρ = 0.900.
   The regression set below must be unaffected; W2 re-ran all of it today against the round-3 tree,
   and these are the expected classifications **after** the round-3 Jackson change (W2 owns
   `AnalyticalTractability.swift`; the `(N classes, no shared station)` suffix is new this round and
   is correct — see the notes at the end of this document):

   ```
   tandem3            d=3 K=1  ρ=0.900000 ×3   exactJackson
   rework3            d=3 K=1  α=1.428571 ρ=0.900000 ×3   exactJackson
   reentrant          d=2 K=1  α=1.428571 ρ=0.900000 ×2   exactJackson
   fork               d=3 K=1  S1 α=1.0, S2/S3 α=0.5, all ρ=0.900000   exactJackson
   handplaced         d=1 K=1  ρ=0.900000   exactJackson
   twoclass           d=2 K=2  ρ=0.900000 ×2   exactJackson (2 classes, no shared station)
   tandem3_plus_mm1   d=4 K=2  ρ=0.900000 ×4   exactJackson (2 classes, no shared station)
   ```

   Those `.bnet` files are in `/tmp/qnet-build-W2-nets/`; they are hand-written copies of what
   `NetworkArchetypeBuilder` emits at its defaults, so they can be regenerated from the builder.

7. **Priority** — **P1**. Severe (a silently wrong ρ, now also a silently wrong exact E[N]) but
   pre-existing, reachable without any change from rounds 1–3, and outside W2's ownership entirely.

---

## W2-INT-9 — one changelog bullet for the round-3 tractability fix

1. **ID** — `W2-INT-9`. Documentation only; nothing is half-dead without it.

2. **Target file and anchor** — `Sources/Qnet/Changelog.swift` (owned by **W6**), the topmost
   `timestamp: nil` entry. Anchor quoted verbatim — the END of the round-2 W2 bullet, line 54, which
   begins `"A network is born at a useful load.` and ends:

   ```swift
   … The template gallery draws each network it offers.",
   ```

3. **Insert / replace** — insert this ONE array element immediately after that line:

   ```swift
                   "Two networks side by side are still exactly solvable. Inserting a second archetype gives the document a second customer class, and the tractability detector used to demote any such document from the exact Jackson branch to the GCDG asymptotic branch purely on the class count — with the asymptotic branch switched off it reported no closed form at all. A document whose classes share no station is not a multi-class network; it is that many independent Jackson networks drawn on one canvas, and it is now recognised as one. The bundled Schwerer01.d3.c3 example — three independent M/M/1 queues at ρ = 0.45, 0.40 and 0.42 — is the case in point: it now reports the exact E[N] of 0.8182, 0.6667 and 0.7241 instead of an approximation of them. A station that two classes genuinely share is still refused, and the gallery footer now says which of the two an insert gives you.",
   ```

4. **New symbols it depends on** — none. `AnalyticalTractability.singleClassPerStation`
   (`Sources/Qnet/AnalyticalTractability.swift`, `private static func
   singleClassPerStation(data: SRBMExporter.SRBMData) -> [Int]?`) is the mechanism the bullet
   describes, but the bullet is prose and references nothing at compile time.

5. **Gate impact** — `validation/design_lint.sh` reads this file as prose: the bullet names no menu
   (so no `→` in a menu path), contains no bare ⌘-digit and no TeX braces. It is one element of an
   existing `[String]`; no version or timestamp changes, and `AppVersion.swift` stays at 0.90.34.

6. **Verification** — `swift build`, then Help ▸ Release Notes: the new bullet appears under the
   in-development entry, immediately below the "A network is born at a useful load" bullet.

7. **Priority** — **P1**.

---

## Not a request — a note for the integrator on a behaviour change inside W2's own files

`AnalyticalTractability.assess` now returns `.exactJackson` for a `K > 1` document whose classes
visit disjoint station sets. Nothing outside `AnalyticalTractability.swift` needed to change for it
(`FlagBarView` and the `--dump-rho` dump both render `Result.detail` verbatim, and no validation
script greps for `exactJackson` or for the detail string), but two observable outputs move, and an
integrator diffing round 2 against round 3 will see them:

* `input/examples/Schwerer01.d3.c3.inf.bnet` — three independent M/M/1 queues — moves from
  `asymptoticLowerTriangular` to `exactJackson`, and the Analytical popover's means become the exact
  ρ/(1−ρ) values. This is the fix working, and the numbers were checked by hand.
* `/tmp/qnet-build-W2-nets/twoclass.bnet` moves from `exactSkewSymmetric` to `exactJackson` —
  both branches are exact, but Jackson is the exact *queue-process* answer where skew-symmetry is
  the exact answer to the SRBM, so the promotion is in the direction
  `docs/STEADY_STATE_METHODS.md` wants.

The 48 other bundled examples are unchanged. `swift build`, `design_lint.sh`,
`gui_runtime_contracts.sh` and `result_output_parser_check.sh` all pass on the round-3 tree.
