# Round 4 — W2 integration requests

One request. It completes the converse half of blocker **R1** ("Link out of a sink: created
silently, drawn on canvas, dropped by every exporter"). The authoring half — the Link tool no
longer *creates* such a link — shipped in `Sources/Qnet/NetworkEditorModel.swift` this round and
needs nothing from the integrator. This request covers documents that already contain the link:
one saved before this build, one hand-edited, one produced by the AI Assistant's `add_link` tool
(a thin primitive whose header says validation is the caller's responsibility), or one imported
from anywhere else.

---

## W2-INT-1 — `validateLinkStructure` must report a link OUT of a sink

1. **ID** — `W2-INT-1`, completes blocker `R1`. R1's authoring half is shipped and independently
   verified without this; an *imported or previously saved* document with a sink-sourced link is
   still solved silently as a different network until this lands. Ship R1 without it and the app
   is fixed for links drawn from now on, and still silent about the ones already on disk.

2. **Target file and anchor** — `Sources/Qnet/QnetGUIApp.swift`, inside
   `private static func validateLinkStructure(nodes:links:infiniteBuffers:)`. Anchor, quoted
   verbatim from today's source at line 7558-7561 (W6 is editing this file this round, so the
   line number will drift — match on the quoted text, not the number):

   ```swift
            // Rule 1 — sources feed buffers only.
            if from.kind == .source && to.kind != .buffer {
                out.append("link from source '\(from.name)' goes to '\(to.name)' (kind=\(to.kind.rawValue)); sources must route to a buffer.")
            }
   ```

   The new rule goes immediately **after** that `if` block and **before** the existing
   `// Rule 2 — sink sources depend on buffer model.` block, inside the same
   `for link in links { … }` loop, so it sees the same `from` / `to` bindings.

3. **Insert** — add exactly this:

   ```swift
            // Rule 1b — a sink is terminal. Every exporter walks
            // source → buffer → station → sink and drops an arc that
            // leaves a sink, so a document carrying one is solved as a
            // different network than the one drawn. The Link tool refuses
            // to create one (NetworkEditorModel.handleLinkSelection); this
            // is the converse rule, for a document that already has one.
            if from.kind == .sink {
                out.append("link out of sink '\(from.name)' goes to '\(to.name)' (kind=\(to.kind.rawValue)); a sink is terminal, and every exporter ignores this link. Delete it, or route from the station that feeds the sink instead.")
            }
   ```

   Nothing else changes: no signature change, no new call site. The function's three existing
   callers (`:6747`, `:7019`, `:7813`) all append its output to `warnings` / read it as
   `structureViolations`, so the new string surfaces in the Warnings pill, in
   `Network ▸ Analyze Network`, and in the pre-export structure check with no further wiring.

4. **New symbols it depends on** — none. `NodeKind.sink`, `NetworkNode.name` and
   `NodeKind.rawValue` are all already used by the two rules on either side of the insertion
   point. No token, no type, nothing added by W2 this round is referenced.

5. **Gate impact** — none that I can find, and I checked each gate by name:
   - `validation/gui_runtime_contracts.sh` greps `QnetGUIApp.swift` only for the awk formatters,
     the `commandWithCleanup` count, the EXIT/INT/TERM trap shape and `${PIPESTATUS[0]}`. This
     touches none of them; the script passed on my tree with the authoring half in place.
   - `validation/design_lint.sh` inspects views, tokens, `DSEmptyState` titles, `Divider()`,
     menu-path arrows and ⌘-digit shortcuts. This adds a diagnostic string inside a static
     function — no view, no token, no menu path. Note the message contains no `▸`, deliberately.
   - No `.keyboardShortcut`, so `QNET_MENU_AUDIT=1` is unaffected.
   - The headless unit checks compile one real file each, and `QnetGUIApp.swift` is not one of
     them.

6. **Verification** — the rule is reached only through `networkWarnings`' two callers (the
   `Network ▸ Show Network Primitives` path at `:6807` and the silent re-analysis at `:7079`),
   not through any `--dump-*` CLI entry point, so this is a GUI check. Build a document that
   carries the link and open it:

   ```sh
   python3 - <<'PY'
   import json
   d = json.load(open('input/examples/3dtandem.inf.bnet'))
   sink = next(n for n in d['nodes'] if n['kind'] == 'sink')
   buf  = next(n for n in d['nodes'] if n['kind'] == 'buffer')
   d['links'].append({'id': '00000000-0000-0000-0000-0000000000FF',
                      'fromNodeID': sink['id'], 'toNodeID': buf['id'],
                      'routingProbability': 1.0, 'customerClass': 0})
   json.dump(d, open('/tmp/sinkout.bnet', 'w'))
   PY
   ```

   Open `/tmp/sinkout.bnet` in the app and run `Network ▸ Analyze Network`. Today the extra arc
   is drawn on the canvas, counted in the status bar's link total, and reported nowhere; after
   this change the Warnings pill and the analysis report both carry
   "link out of sink 'Sink1' goes to 'B1' …". `Qnet --dump-rho /tmp/sinkout.bnet` stays
   byte-identical to the unmodified example either way — that identity IS the R1 evidence, and
   this request does not change it.

   Optional but recommended in the same edit: the function's doc comment (`:7531-7544`) lists its
   rules as bullets. Add one — "• No link may leave a sink. A sink is terminal; the exporters
   ignore an arc out of one." — so the comment still describes what the function does.

7. **Priority** — **P1**. The path a user actually walks — draw the arc with the Link tool — is
   closed and verified without this. This closes the same hole for a document that arrives
   already carrying the link.
