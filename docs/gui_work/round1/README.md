# Round 1 — integration-document contract

`Sources/Qnet/QnetGUIApp.swift` is owned **exclusively by W6** this round. It holds the awk
formatters, the 22 Run actions and the two shell wrappers; W6-01 edits the tee line inside both
wrappers, which is the single most contract-sensitive region in the repository
(`validation/gui_runtime_contracts.sh` asserts the EXIT/INT/TERM traps, the count of exactly 8
`commandWithCleanup` Python runners, and `${PIPESTATUS[0]}` semantics that depend on the pipeline
shape). Two agents editing that file at once is a data-integrity risk, not merely a merge risk.

`Sources/Qnet/DesignSystem.swift` is **integrator-owned and frozen** for round 1. It was seeded
before the round opened with `DS.Number.display`, the dialog/detached-pane size bands,
`DS.Layout.shellRowIdealHeight`, and the detach / reattach / paneMaximize / paneRestore /
sortAscending / sortDescending symbols. Need another token? Put it in your integration document.

`Sources/Qnet/NetworkEditorModel.swift` is owned by **W2**, and was seeded with the inert API W1
calls: `pendingLinkPoint`, `toolBeforeStickyPan`, `enterStickyPan()`, `exitStickyPan()`,
`pendingFitOnAppear`. **W2 must not remove or rename these.**

`Sources/Qnet/QnetCommands.swift` is owned by **W5**.

## How to request a change to a file you do not own

Write exactly one file: `docs/gui_work/round1/<W#>-integration.md`. It is not a wish list — it is a
patch expressed in prose, and an integrator with no context must be able to apply it without doing
any design work. One section per request, these seven fields, nothing else:

1. **ID** — `<workstream>-INT-<n>`, plus the task id it completes, and whether that task is
   shippable without it.
2. **Target file and anchor** — exact file, exact function or `Commands` block, and an anchor line
   **quoted verbatim from today's source** with its line number. Line numbers drift during the
   round; the quoted text is what the integrator matches on.
3. **Insert / replace** — the literal Swift to add, or the exact before → after. Titles,
   `.help(…)` text, `.disabled(…)` predicates and `.keyboardShortcut(…)` fully spelled out.
   Never "add a menu item for the archetype gallery".
4. **New symbols it depends on** — every type, property or function the snippet references that you
   added this round, with its file and declaration, so the integrator can confirm it exists first.
5. **Gate impact** — does it touch a string `validation/gui_runtime_contracts.sh` greps (name the
   assertion)? Does it add a `.keyboardShortcut` that `QNET_MENU_AUDIT=1` must re-clear? Does it add
   a `DSEmptyState` title, a `Divider()`, a menu-path arrow or a bare ⌘-digit that
   `validation/design_lint.sh` inspects?
6. **Verification** — the one command or click sequence that proves it landed.
7. **Priority** — P0 = a shipped task is half-dead without it. P1 = the feature is reachable another
   way meanwhile.

A serial integrator pass runs **after** all six agents finish, applies these documents, and runs the
round-1 exit gate. Nothing you write here is applied by you.

## Exit gate for the round

```sh
swift build
validation/design_lint.sh
validation/gui_runtime_contracts.sh
validation/result_output_parser_check.sh
validation/steady_state_suite.sh
swift run Qnet --version      # must still print "Qnet 0.90.34"
```

`AppVersion.swift` stays at 0.90.34. Add bullets to the topmost `timestamp: nil` entry in
`Changelog.swift` (W6 owns that file) rather than creating a new release entry.
