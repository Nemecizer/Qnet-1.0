# W6 — round 4 integration requests and closure record

Workstream: **W6 — Output, results and numeric consistency**, owner of `Sources/Qnet/QnetGUIApp.swift`.
Assigned round-4 issues: **R2, R3, R10, R11, R12**. All five were closed in W6-owned files.
Only one integration request follows (W6-INT-1, P1, a wording change in a file W6 does not own).

---

## Closure record for the prior blocker R2 (raised in rounds 2, 3 and 4)

**This prior blocker is now closed.** Option **(a)** of the required fix was taken: `emit()` in
`outputPrecisionProgram` (`QnetGUIApp.swift`) no longer skips a `QNET_…_V1` record whole. Option (b)
(a `--decimals` flag on `qbd_solver.py` and `regenerative_mc.py`) was rejected: it needs the human
channel separated from the machine channel first, it would put display precision inside two solvers
while the other twenty keep it at the boundary, and it cannot reach the sentinels the other Python
methods print.

The rewrite is deliberately narrower than the prose path. Inside a sentinel record only a token that
is the **complete value of a `key=` field** — preceded by `=`, followed by whitespace or end of
record — is rewritten, and no padding is applied. The record head, every key, every integer-valued
field (`level=`, `iterations=`, `exit=`, `cap_hits=`) and every percent-encoded string
(`value=M%2FM%2F1%20with%20lambda%3D2`) come through byte-identical by construction, because an
integer carries neither a decimal point nor an exponent and `%20`-encoded text never leaves a
numeric token flush against an `=`.

Measured through the exact pipeline shape the wrapper builds
(`{ solver ; } 2>&1 | tee <archive> | { … exec perl <program> <decimals> … }`), on
`infinite/matrix_analytic/examples/mm1.json`:

    before (any decimals setting, unchanged by it):
      QNET_QBD_METRIC_V1 metric=mean_level estimate=1.9999999999722793
      QNET_QBD_METRIC_V1 metric=probability_empty estimate=0.33333333333564347
      QNET_QBD_EVIDENCE_V1 key=rate_equation_residual_inf value=3.4652281044600386e-12

    after, decimals = 3:
      QNET_QBD_METRIC_V1 metric=mean_level estimate=2.000
      QNET_QBD_METRIC_V1 metric=probability_empty estimate=0.333
      QNET_QBD_EVIDENCE_V1 key=rate_equation_residual_inf value=3.47e-12

    after, decimals = 6:
      QNET_QBD_METRIC_V1 metric=mean_level estimate=2.000000
      QNET_QBD_METRIC_V1 metric=probability_empty estimate=0.333333
      QNET_QBD_EVIDENCE_V1 key=rate_equation_residual_inf value=3.46523e-12

    unchanged at both settings (head, keys, integers, encoded name):
      QNET_QBD_METRIC_V1 metric=tail_probability level=10 estimate=0.017342
      QNET_QBD_EVIDENCE_V1 key=iterations value=110
      QNET_QBD_EVIDENCE_V1 key=net_level_drift value=-1
      QNET_QBD_EVIDENCE_V1 key=name value=M%2FM%2F1%20with%20lambda%3D2%20and%20mu%3D3

Regenerative Monte Carlo, `infinite/regenerative_mc/examples/mm1.json`, decimals = 6 — the two
spellings of one quantity on one screen are now one spelling:

    before:
      mean_number_in_system:   0.982839 (sequential interval [0.883687,  1.081991]; effective cycles 5442.300000)
      QNET_NODE_METRIC_V1 node_id=server metric=mean_number class_id=- estimate=0.98283912377700089 standard_error=0.023644096937800636 ci_confidence=0.94999999999999996 …
    after:
      mean_number_in_system: 0.982839 (sequential interval [0.883687, 1.081991]; effective cycles 5442.300000)
      QNET_NODE_METRIC_V1 node_id=server metric=mean_number class_id=- estimate=0.982839 standard_error=0.023644 ci_confidence=0.950000 ci_low=0.936492 ci_high=1.029186 ci_half_width=0.046347 effective_cycles=5442.334557

The archived file `tee` writes — the one `ResultOutputParser` and the CSV export read — was compared
byte for byte against the raw solver output and is identical. `validation/result_output_parser_check.sh`
passes.

---

## W6-INT-1 — `ArchetypeGallerySheet.insertNote` should say which regime an empty-canvas insert establishes

1. **ID** — `W6-INT-1`, completes the second half of **R10**. R10 is shippable without it: the
   behaviour fix has landed and is verified in the running app; this is the sentence that explains it.
2. **Target file and anchor** — `Sources/Qnet/ArchetypeGallerySheet.swift`, computed property
   `insertNote`, first statement. Anchor, quoted verbatim from today's source (line 366-368):

   ```swift
        guard canvasNodeCount > 0 else {
            return "The buffer model is network-wide. This canvas is empty, so the choice above becomes the whole network's."
        }
   ```
3. **Insert / replace** — replace the returned string with:

   ```swift
        guard canvasNodeCount > 0 else {
            return "The buffer model is network-wide. This canvas is empty, so the choice above becomes the whole network's: the insert will put it on \(infiniteBuffers ? "infinite" : "finite") buffers."
        }
   ```

   Nothing else in the file changes. `infiniteBuffers` is the sheet's existing `@State` (declared at
   line 51), so the sentence follows the popup as the user changes it.
4. **New symbols it depends on** — none. `infiniteBuffers` and `canvasNodeCount` both already exist
   in this file.
5. **Gate impact** — none. Not a string `validation/gui_runtime_contracts.sh` greps; no
   `.keyboardShortcut`; not a `DSEmptyState` title, a `Divider()`, a menu-path arrow or a ⌘-digit,
   so `validation/design_lint.sh` is unaffected. It is prose inside an existing `Text`.
6. **Verification** — launch, File ▸ New Network, Network ▸ Insert Archetype…; the footer under
   Buffers reads "… the insert will put it on infinite buffers." Switch Buffers to Finite and the
   sentence follows.
7. **Priority** — **P1**.

---

## What W6 changed in its own files (no integration needed)

* **R2** — `QnetGUIApp.swift`, `outputPrecisionProgram` / `emit`. Sentinel records are rewritten
  field-by-field instead of skipped. See the closure record above.
* **R3** — `QnetGUIApp.swift`, `outputPrecisionProgram` / `fmtnum` + `emit`. Rule 3 was widened from
  "`$pad` is empty" to "the token is introduced by `=`, `:` or `,`". The regex gained an optional
  captured `[=:,]` prefix, re-emitted verbatim, whose only job is to set fmtnum's new `$prose` flag;
  a prose token neither takes width padding nor repays column debt. `,` is included beyond the
  critic's stated minimum because the critic's own evidence lists
  `(sequential interval [0.883687,  1.081991]` — a comma-separated pair pulled apart — and a
  comma-preceded gap is never a printf column.
  Measured, decimals = 6 → `generator residual = 4.11409e-13` (was 7 inserted spaces);
  decimals = 2 → `generator residual = 4.1e-13` (was 11); LP at 3 → `drift         = -1.000  0.000`
  (was `=  -1.000  0.000`). The `bna_qna` fixed-column table (`Node Servers Util(rho) …`) is
  byte-identical before and after at 3 and at 6, so no real column was lost.
* **R12** — `QnetGUIApp.swift`, `fmtnum`. Notation is decided from `$v`, not from whether `$tok`
  contains `[eE]`: the scientific branch is taken only when `$v != 0 && (abs($v) < $T || abs($v) >= $U)`,
  which is the same test `fmt7` and `DS.Number.display` apply. Rule 1 is kept inside that branch —
  a token that arrived scientific still caps its mantissa at `min($E, $have)`, so `4.567e-09` stays
  `4.567e-09`. Measured at decimals 6: `0.0000000000e+00` → `0.000000` (was `0.00000e+00`),
  `1.5e-03` → `0.001500`, `1e+06` → `1000000.000000`.
  **fmt7 idempotency re-checked** at decimals 0, 1, 3, 6 and 9 over a table built by a transcription
  of `buildComparisonAwk`'s `fmt7`/`fmtv` (values spanning 0, 1.2e-08, 1.23e+11, -4e-07, 5442.33,
  3.47e-12, and `value ± half (+delta%)` cells): **0 differing lines at every setting.**
  One residual, stated plainly: inside the scientific band the filter caps mantissa digits at what
  the solver printed while `DS.Number.display` pads to `max(1, d-1)`, so a solver's `4.567e-09` reads
  `4.567e-09` in the Shell and `4.56700e-09` in the Results pane at decimals 6. That is rule 1, which
  R12 explicitly asked to keep; the notation itself now agrees everywhere.
* **R10** — `QnetGUIApp.swift`, `syncArchetypePanel(presented:)`:
  `initialInfiniteBuffers: activeEditor.nodes.isEmpty ? true : activeEditor.infiniteBuffers`.
  The alternative (changing `NetworkEditorModel.infiniteBuffers`'s document default, W2's file) was
  **not** done — the two must not both be done.
* **R11** — `Sources/Qnet/QNAExporter.swift` and `Sources/Qnet/BNASRBMExporter.swift`.
  `solveTrafficEquations` now returns `(alpha:singularIndex:)`, set exactly where the pivot is
  skipped, and each caller returns `.failure(.trafficEquationsSingular(station, class))`.
  **Note for the integrator:** the sentence is spelled out inline in `QNAExportError` rather than
  delegated to `NetworkExportError.trafficEquationsSingular`, because
  `validation/rqna_integration_check.sh` compiles `QNAExporter.swift` alone against
  `validation/rqna_exporter/stubs.swift`, which does not declare `NetworkExportError`, and
  `validation/` is not editable from a workstream. `BNASRBMExportError` follows the same spelling for
  consistency. If a future round makes the stub grow, the three copies can collapse into one.
  No launch-site change was needed: `runQNA` / `runRQNA` / the BNA-SRBM launches already route
  `.failure` through `reportBlocked`, and every other caller of the two exporters already handles
  `.failure` (`runComparisonInfinite` collects it into `qnaExportProblem` / `smExportProblem`).

---

## Verification actually performed

* `swift build --scratch-path /tmp/qnet-build-W6` — clean, no error names a W6 file.
* `DS_SKIP_CONTRAST=1 ./validation/design_lint.sh` — passes.
* `./validation/gui_runtime_contracts.sh` — passes (re-read before editing the program region; none
  of its `grep -Fq` targets fall inside the edited text, and the pipeline shape and
  `${PIPESTATUS[0]}` are untouched).
* `./validation/result_output_parser_check.sh` — passes.
* `./validation/rqna_integration_check.sh` — passes (this is the check that compiles the edited
  `QNAExporter.swift` against its stub).
* **R11 regression:** two binaries were built from the same tree snapshot, one with the R11 change
  reverted, and both were run over all 50 bundled examples with `--export-cmp`: **340 exported files,
  0 differing** (ignoring the `# Generated:` timestamp line). On a 3-station tandem with S1 → B2 set
  to p = 0 and S1 → B1 added at p = 1.0, the old binary wrote `qna.qna` with
  `# Total throughput per station` = `1 0 0` and `./infinite/BNAqna/bna_qna` printed `nan` for every
  node and `Total E[N]: nan`; the new binary writes no `qna.qna` (and no `cmp_sm.in`) at all, and
  `--dump-rho` prints the named refusal.
* **R10 in the running app** (PID-scoped AX, see the caveat below): File ▸ New Network → Network ▸
  Insert Archetype… → Buffers popup reads **Infinite** with the footer "This canvas is empty, so the
  choice above becomes the whole network's"; ↓ selects Tandem Line ("Will insert: 3 stations, 8
  nodes, 7 links"); Return inserts; the Run menu then reads **Run Whitt QNA [true], Run Whitt–You
  RQNA [true], Run SBD [true], Run Exact Open Product Form [true], Run Exact Matrix-Analytic QBD
  [true]** — all twelve infinite-buffer entries enabled.

### Caveat on GUI verification, for whoever reads this next

Six agents were running six builds of Qnet simultaneously, all with the same process name and the
same bundle identity. `System Events` **reads** can be scoped to a PID and were; `System Events`
**clicks** are not reliably scoped — several menu clicks aimed at this workstream's PID were executed
by another agent's front app (confirmed by the run scripts they left in `$TMPDIR`, stamped with that
app's PID). R10 above is safe because the panel that was read belonged to this PID and could not have
existed there unless the click had landed there. Reading the Shell's own text is not achievable this
way at all (SwiftTerm exposes no AX value), so R2/R3/R12 were verified by running the wrapper's exact
pipeline shape outside the GUI, against the real solvers, using the perl program extracted verbatim
from `outputPrecisionProgram` — and by reconstructing the round-3 program and confirming it
reproduces the critics' measured strings character for character before the fix.

---

## Non-blocking improvements taken (comment-only, zero behavioural change)

Two `IMPROVEMENTS.json` entries that sit inside the region R2/R3/R12 already touch were closed the
way each one asks to be closed when the fix is not worth the risk in a close-out round — by recording
the hazard where the next person will read it:

* "The filter's `holding()` comment overstates its own latency bound" — the comment now says holding
  is unbounded rather than one tick, and why releasing early is the worse failure.
* "A two-component version or identifier in prose is reformatted" and "A number immediately following
  an ANSI escape is never reformatted" — both hazards are now stated in the regex's comment block,
  with the reason each is currently unreachable.

No other improvement was taken. In particular the `$debt` column-repayment entries and the
"Elapsed time / spinner time ignore the decimals setting" entry were left alone: they change what the
filter does, and this was a close-out round.
