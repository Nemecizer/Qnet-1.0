# W5 → W6 integration (round 6)

## Context

Defect: **cancelling a run is reported to the user as a solver failure.**

Reproduced by the verifier and by W5 on the final binary: Run ▸ Run Monte Carlo… at
999,999,999 time units / 50 replications, then Run ▸ Stop Monte Carlo, produced

    [07:03:07] [WARNING] Monte Carlo cancelled.
    [07:03:09] [ERROR]   Monte Carlo failed (exit 129) after 16 s

plus a red-X "Monte Carlo — Queue — 0 measurements" record in the Results workspace.

Root cause was in **W5-owned `TerminalModel.swift`** and is **already fixed there**:
`TerminalRunSummary.cancelled` pattern-matched a whitelist of exit codes (130, 143) and
the SIGHUP-shaped 129 that the escalation actually produced was not in it. The struct now
carries a stored `let userStopped: Bool`, set in `finishRun` from `cancelRequestedAt != nil`,
and `cancelled` keys off that instead of the exit status:

```swift
var cancelled: Bool {
    guard exitCode != 0 else { return false }
    return userStopped
        || exitCode == Self.cancelledExitCode
        || exitCode == 143
}
```

(The `exitCode != 0` guard is deliberate: Stop pressed in the same instant a solver finished
must not throw away a completed result. The exit-code arm stays for a ^C typed in the shell
itself, where Stop was never pressed.)

**No change is required in QnetGUIApp.swift or ResultsWorkspace.swift for the two-line
symptom.** `finalizeStructuredResult` already excludes cancellations from the `.error`
status line and already routes them to `store.cancelRun` rather than `store.failRun`; it was
only ever being handed the wrong verdict. W5 verified on the rebuilt binary that a stopped
run now logs exactly one line ("Monte Carlo cancelled.") and files a **Cancelled** record,
and that a solver that exits non-zero on its own still logs
"[ERROR] Monte Carlo failed (exit 3) after 0.7 s" and files a **Failed** record.

## The one change W5 cannot make (optional, W6-owned)

The round-6 brief also asks that a stopped run leave **no result entry at all** — today it
leaves a grey "Cancelled — 0 measurements" row (previously a red-X "Failed" row). Removing
the row is a record-filing decision that lives in W6-owned `QnetGUIApp.swift`.

**File:** `Sources/Qnet/QnetGUIApp.swift`, in `finalizeStructuredResult(_:)`
(the branch immediately after `guard let record = store.record(id: summary.id)`).

Replace:

```swift
        if summary.cancelled {
            store.cancelRun(summary.id, rawOutput: raw, completedAt: summary.finishedAt)
            return
        }
```

with:

```swift
        if summary.cancelled {
            // A run the user stopped is not a result. Filing a 0-measurement
            // record for it makes a deliberate Stop look like a failed run in
            // the Results workspace; the Status log's "… cancelled." line is
            // the whole trace a cancellation should leave.
            store.delete(summary.id)
            return
        }
```

`ResultsStore.delete(_:)` already exists (ResultsWorkspace.swift:621) and persists.

Notes for whoever applies this:

* **Do not delete `ResultRunStatus.cancelled`.** It becomes unreachable for *new* runs, but
  it is a `Codable` case and persisted stores on user machines (including this machine's)
  already contain records with `status == "cancelled"`; removing the case would break
  decoding of the whole store.
* If W6 would rather keep a visible trace of stopped runs (the record retains provenance,
  parameters and the partial raw output, which can be useful), leaving `store.cancelRun`
  in place is also defensible — the reported defect (red error line + failed record) is
  fixed either way. This is the only open judgement call.

## Nothing else is requested of W6

No exporter, parser, solver or `ResultsWorkspace.swift` change is needed for this defect.
