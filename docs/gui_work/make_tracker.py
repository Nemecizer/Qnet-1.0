#!/usr/bin/env python3
"""Render the Qnet GUI refinement tracker from BACKLOG.json + STATE.json.

BACKLOG.json is the audited backlog and never changes during the effort.
STATE.json is the mutable progress record: gate results, per-task status,
re-measured metrics and the round log. Regenerate after every round:

    python3 docs/gui_work/make_tracker.py

Writes docs/gui_work/tracker.html, which is published as an Artifact.
"""

import html
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
BACKLOG = json.loads((HERE / "BACKLOG.json").read_text())
STATE = json.loads((HERE / "STATE.json").read_text())

E = html.escape

STATUS_LABEL = {
    "done": "Done",
    "partial": "Partial",
    "blocked": "Blocked",
    "planned": "Planned",
    "deferred": "Deferred",
    "dropped": "Dropped",
}


def task_state(task_id):
    return STATE.get("task_status", {}).get(task_id, "planned")


def gate_chips():
    out = []
    for g in STATE["gates"]:
        out.append(
            f'<li class="chip chip--{E(g["state"])}">'
            f'<span class="chip__dot" aria-hidden="true"></span>'
            f'<span class="chip__name">{E(g["name"])}</span>'
            f'<span class="chip__note">{E(g["note"])}</span></li>'
        )
    return "\n".join(out)


def metrics_rows():
    rows = []
    for i, m in enumerate(BACKLOG["headline_metrics"]):
        measured = STATE.get("metric_measured", {}).get(str(i))
        if measured is None:
            cell = '<td class="num num--pending">not yet re-measured</td>'
        else:
            met = measured.get("target_met")
            cls = "num--met" if met else "num--unmet"
            cell = f'<td class="num {cls}">{E(str(measured["value"]))}</td>'
        rows.append(
            "<tr>"
            f'<td class="metric__what">{E(m["metric"])}</td>'
            f'<td class="num num--base">{E(m["current_value"])}</td>'
            f'<td class="num num--target">{E(m["target"])}</td>'
            f"{cell}"
            "</tr>"
        )
    return "\n".join(rows)


def workstream_cards():
    cards = []
    for w in BACKLOG["workstreams"]:
        tasks = w["tasks"]
        done = sum(1 for t in tasks if task_state(t["id"]) == "done")
        items = []
        for t in tasks:
            st = task_state(t["id"])
            items.append(
                f'<li class="task task--{E(st)}">'
                f'<span class="task__mark" aria-hidden="true"></span>'
                f'<div class="task__body">'
                f'<p class="task__head">'
                f'<span class="task__id">{E(t["id"])}</span>'
                f'<span class="task__prio prio--{E(t["priority"])}">{E(t["priority"])}</span>'
                f'<span class="task__effort">{E(t["effort"])}</span>'
                f'<span class="task__status">{E(STATUS_LABEL.get(st, st))}</span>'
                f"</p>"
                f'<p class="task__title">{E(t["title"])}</p>'
                f'<p class="task__accept"><span class="lbl">Accepts when</span> {E(t["acceptance_criteria"])}</p>'
                f"</div></li>"
            )
        owned = ", ".join(p.split("/")[-1] for p in w["owned_files"] if not p.startswith("**"))
        new = [p.split("/")[-1] for p in w["new_files"] if p.endswith(".swift")]
        newline = (
            f'<p class="ws__new"><span class="lbl">New files</span> <code>{E(", ".join(new))}</code></p>'
            if new
            else ""
        )
        cards.append(
            f'<article class="ws">'
            f'<header class="ws__head">'
            f'<p class="ws__id">{E(w["id"])}</p>'
            f'<h3 class="ws__name">{E(w["name"])}</h3>'
            f'<p class="ws__count"><span class="ws__done">{done}</span> / {len(tasks)} tasks</p>'
            f"</header>"
            f'<p class="ws__mission">{E(w["mission"])}</p>'
            f'<p class="ws__owns"><span class="lbl">Owns</span> <code>{E(owned)}</code></p>'
            f"{newline}"
            f'<ul class="tasks">{"".join(items)}</ul>'
            f"</article>"
        )
    return "\n".join(cards)


def round_log():
    out = []
    for r in STATE["rounds"]:
        meta = []
        if r.get("agents"):
            meta.append(f'{r["agents"]} agents')
        if r.get("tokens"):
            meta.append(f'{r["tokens"]} tokens')
        metatxt = f'<p class="round__meta">{E(" · ".join(meta))}</p>' if meta else ""
        crit = ""
        if r.get("verdicts"):
            vs = "".join(
                f'<li class="verdict verdict--{E(v["verdict"])}">'
                f'<span class="verdict__lens">{E(v["lens"])}</span>'
                f'<span class="verdict__mark">{E(v["verdict"].replace("_", " "))}</span>'
                f'<span class="verdict__n">{v["blocking"]} blocking</span></li>'
                for v in r["verdicts"]
            )
            crit = f'<ul class="verdicts">{vs}</ul>'
        out.append(
            f'<li class="round round--{E(r["state"])}">'
            f'<div class="round__n"><span>{r["n"]}</span></div>'
            f'<div class="round__body">'
            f'<h3 class="round__title">{E(r["title"])}</h3>'
            f"{metatxt}"
            f'<p class="round__detail">{E(r["detail"])}</p>'
            f"{crit}"
            f"</div></li>"
        )
    return "\n".join(out)


def guard_list():
    items = "".join(f"<li>{E(d)}</li>" for d in BACKLOG["do_not_regress"])
    return items


CSS = """
:root{
  --bg:#F6F8F8; --surface:#FFFFFF; --surface2:#EFF3F3; --sunk:#E7EDED;
  --ink:#131A1C; --ink2:#33484C; --muted:#5A6A6E; --line:#DBE4E4; --line2:#C6D3D3;
  --accent:#0E6E6B; --accent-soft:#DCEDEC;
  --done:#1D7A4F; --done-soft:#DCEFE3;
  --active:#9A5B08; --active-soft:#F6E9D4;
  --blocked:#A6302E; --blocked-soft:#F6E0DF;
  --idle:#71858A; --idle-soft:#E7ECED;
  --shadow:0 1px 2px rgba(19,26,28,.05), 0 8px 24px -16px rgba(19,26,28,.28);
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:#0D1315; --surface:#141C1E; --surface2:#1A2427; --sunk:#101819;
    --ink:#E7EDED; --ink2:#BCCACC; --muted:#8FA1A4; --line:#243033; --line2:#31403F;
    --accent:#57C9C0; --accent-soft:#12302F;
    --done:#5BB483; --done-soft:#132A20;
    --active:#DDA249; --active-soft:#2C2314;
    --blocked:#E2706B; --blocked-soft:#2E1917;
    --idle:#7E9296; --idle-soft:#1B2426;
    --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.8);
  }
}
:root[data-theme="dark"]{
  --bg:#0D1315; --surface:#141C1E; --surface2:#1A2427; --sunk:#101819;
  --ink:#E7EDED; --ink2:#BCCACC; --muted:#8FA1A4; --line:#243033; --line2:#31403F;
  --accent:#57C9C0; --accent-soft:#12302F;
  --done:#5BB483; --done-soft:#132A20;
  --active:#DDA249; --active-soft:#2C2314;
  --blocked:#E2706B; --blocked-soft:#2E1917;
  --idle:#7E9296; --idle-soft:#1B2426;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.8);
}

*{box-sizing:border-box}
body{
  background:var(--bg); color:var(--ink);
  font-family:"IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  font-size:15px; line-height:1.55; margin:0;
  -webkit-font-smoothing:antialiased;
}
.wrap{max-width:1180px; margin:0 auto; padding:40px 28px 96px;
  display:flex; flex-direction:column; gap:52px}
code{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.86em}
.lbl{font-family:"IBM Plex Mono",ui-monospace,monospace; font-size:11px;
  text-transform:uppercase; letter-spacing:.09em; color:var(--muted)}
h1,h2,h3{font-family:"IBM Plex Serif",Georgia,serif; text-wrap:balance; margin:0}

/* ── masthead ─────────────────────────────────────────── */
.mast{display:flex; flex-direction:column; gap:18px;
  border-bottom:2px solid var(--ink); padding-bottom:22px}
.mast__eyebrow{display:flex; flex-wrap:wrap; gap:10px; align-items:baseline;
  font-family:"IBM Plex Mono",monospace; font-size:12px; letter-spacing:.06em;
  text-transform:uppercase; color:var(--muted); margin:0}
.mast__eyebrow b{color:var(--accent); font-weight:600}
.mast h1{font-size:clamp(30px,4.4vw,44px); line-height:1.1; font-weight:600;
  letter-spacing:-.015em; max-width:20ch}
.mast__lede{font-size:16.5px; color:var(--ink2); max-width:66ch; margin:0}
.mast__phase{display:inline-flex; align-items:center; gap:9px; align-self:flex-start;
  background:var(--active-soft); color:var(--active); border:1px solid var(--active);
  border-radius:999px; padding:5px 13px 5px 10px; font-size:12.5px; font-weight:600;
  font-family:"IBM Plex Mono",monospace}
.mast__phase::before{content:""; width:7px; height:7px; border-radius:50%;
  background:currentColor; flex:none}

/* ── section frame ─────────────────────────────────────── */
section{display:flex; flex-direction:column; gap:18px}
.sec__head{display:flex; flex-direction:column; gap:5px;
  border-bottom:1px solid var(--line2); padding-bottom:10px}
.sec__head h2{font-size:21px; font-weight:600; letter-spacing:-.01em}
.sec__head p{margin:0; color:var(--muted); font-size:13.5px; max-width:74ch}

/* ── gates ─────────────────────────────────────────────── */
.gates{list-style:none; margin:0; padding:0; display:grid; gap:8px;
  grid-template-columns:repeat(auto-fill,minmax(258px,1fr))}
.chip{display:flex; align-items:center; gap:9px; background:var(--surface);
  border:1px solid var(--line); border-radius:7px; padding:9px 12px; font-size:13px}
.chip__dot{width:8px; height:8px; border-radius:50%; flex:none; background:var(--idle)}
.chip__name{font-family:"IBM Plex Mono",monospace; font-weight:500; color:var(--ink)}
.chip__note{margin-left:auto; color:var(--muted); font-size:11.5px; text-align:right}
.chip--pass{border-color:var(--done)}
.chip--pass .chip__dot{background:var(--done)}
.chip--fail{border-color:var(--blocked); background:var(--blocked-soft)}
.chip--fail .chip__dot{background:var(--blocked)}
.chip--unknown{border-style:dashed}

/* ── metrics ───────────────────────────────────────────── */
.tablewrap{overflow-x:auto; border:1px solid var(--line); border-radius:9px;
  background:var(--surface)}
table{border-collapse:collapse; width:100%; min-width:720px; font-size:13.5px}
thead th{text-align:left; font-family:"IBM Plex Mono",monospace; font-weight:500;
  font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted);
  padding:11px 14px; border-bottom:1px solid var(--line2); white-space:nowrap;
  background:var(--surface2)}
tbody td{padding:11px 14px; border-bottom:1px solid var(--line); vertical-align:top}
tbody tr:last-child td{border-bottom:none}
.metric__what{color:var(--ink2); max-width:46ch}
.num{font-family:"IBM Plex Mono",monospace; font-variant-numeric:tabular-nums;
  font-size:12.5px; white-space:normal; max-width:22ch}
.num--base{color:var(--blocked)}
.num--target{color:var(--muted)}
.num--pending{color:var(--muted); font-style:italic; opacity:.75}
.num--met{color:var(--done); font-weight:600}
.num--unmet{color:var(--active); font-weight:600}

/* ── workstreams ───────────────────────────────────────── */
.grid{display:grid; gap:16px; grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.ws{background:var(--surface); border:1px solid var(--line); border-radius:10px;
  padding:18px; display:flex; flex-direction:column; gap:11px; box-shadow:var(--shadow)}
.ws__head{display:grid; grid-template-columns:auto 1fr auto; gap:10px; align-items:baseline}
.ws__id{margin:0; font-family:"IBM Plex Mono",monospace; font-weight:600; font-size:13px;
  color:var(--accent); background:var(--accent-soft); padding:2px 7px; border-radius:5px}
.ws__name{font-size:16px; font-weight:600; letter-spacing:-.005em}
.ws__count{margin:0; font-family:"IBM Plex Mono",monospace; font-size:12px; color:var(--muted);
  white-space:nowrap; font-variant-numeric:tabular-nums}
.ws__done{color:var(--done); font-weight:600}
.ws__mission{margin:0; font-size:13px; color:var(--ink2)}
.ws__owns,.ws__new{margin:0; font-size:11.5px; color:var(--muted); line-height:1.5}
.ws__owns code,.ws__new code{color:var(--ink2); word-break:break-word}

.tasks{list-style:none; margin:4px 0 0; padding:0; display:flex; flex-direction:column;
  border-top:1px solid var(--line)}
.task{display:grid; grid-template-columns:auto 1fr; gap:10px; padding:11px 0;
  border-bottom:1px solid var(--line)}
.task:last-child{border-bottom:none; padding-bottom:0}
.task__mark{width:15px; height:15px; border-radius:4px; border:1.5px solid var(--line2);
  margin-top:3px; flex:none; position:relative; background:var(--sunk)}
.task--done .task__mark{background:var(--done); border-color:var(--done)}
.task--done .task__mark::after{content:""; position:absolute; left:4px; top:1px;
  width:4px; height:8px; border:solid #fff; border-width:0 1.8px 1.8px 0;
  transform:rotate(42deg)}
.task--partial .task__mark{background:linear-gradient(135deg,var(--active) 50%,var(--sunk) 50%);
  border-color:var(--active)}
.task--blocked .task__mark{background:var(--blocked); border-color:var(--blocked)}
.task--blocked .task__mark::after{content:""; position:absolute; inset:0;
  background:linear-gradient(45deg,transparent 44%,#fff 44%,#fff 56%,transparent 56%)}
.task--deferred .task__mark,.task--dropped .task__mark{border-style:dashed}
.task__body{display:flex; flex-direction:column; gap:3px; min-width:0}
.task__head{margin:0; display:flex; flex-wrap:wrap; gap:7px; align-items:center;
  font-family:"IBM Plex Mono",monospace; font-size:10.5px; letter-spacing:.04em}
.task__id{color:var(--ink2); font-weight:600}
.task__prio{padding:1px 5px; border-radius:3px; font-weight:600}
.prio--P0{background:var(--blocked-soft); color:var(--blocked)}
.prio--P1{background:var(--active-soft); color:var(--active)}
.prio--P2,.prio--P3{background:var(--idle-soft); color:var(--idle)}
.task__effort{color:var(--muted); text-transform:uppercase}
.task__status{margin-left:auto; color:var(--muted); text-transform:uppercase}
.task--done .task__status{color:var(--done); font-weight:600}
.task--partial .task__status{color:var(--active); font-weight:600}
.task--blocked .task__status{color:var(--blocked); font-weight:600}
.task__title{margin:0; font-size:13.5px; font-weight:500; color:var(--ink); line-height:1.4}
.task__accept{margin:0; font-size:12px; color:var(--muted); line-height:1.5}

/* ── rounds ────────────────────────────────────────────── */
.rounds{list-style:none; margin:0; padding:0; display:flex; flex-direction:column}
.round{display:grid; grid-template-columns:auto 1fr; gap:18px; position:relative;
  padding-bottom:26px}
.round:last-child{padding-bottom:0}
.round::before{content:""; position:absolute; left:17px; top:38px; bottom:0; width:1.5px;
  background:var(--line2)}
.round:last-child::before{display:none}
.round__n{width:36px; height:36px; border-radius:50%; display:grid; place-items:center;
  font-family:"IBM Plex Mono",monospace; font-weight:600; font-size:14px;
  background:var(--surface); border:1.5px solid var(--line2); color:var(--muted);
  position:relative; z-index:1; flex:none}
.round--done .round__n{background:var(--done); border-color:var(--done); color:#fff}
.round--running .round__n{border-color:var(--active); color:var(--active);
  background:var(--active-soft)}
.round__body{display:flex; flex-direction:column; gap:7px; padding-top:5px; min-width:0}
.round__title{font-size:17px; font-weight:600}
.round__meta{margin:0; font-family:"IBM Plex Mono",monospace; font-size:11px;
  color:var(--muted); text-transform:uppercase; letter-spacing:.06em}
.round__detail{margin:0; font-size:13.5px; color:var(--ink2); max-width:78ch}
.verdicts{list-style:none; margin:6px 0 0; padding:0; display:grid; gap:6px;
  grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
.verdict{display:flex; align-items:center; gap:9px; font-size:12px; padding:7px 11px;
  border-radius:6px; border:1px solid var(--line); background:var(--surface)}
.verdict__lens{color:var(--ink2); min-width:0; overflow:hidden; text-overflow:ellipsis;
  white-space:nowrap}
.verdict__mark{margin-left:auto; font-family:"IBM Plex Mono",monospace; font-size:10.5px;
  text-transform:uppercase; letter-spacing:.05em; font-weight:600; white-space:nowrap}
.verdict__n{font-family:"IBM Plex Mono",monospace; font-size:10.5px; color:var(--muted);
  white-space:nowrap}
.verdict--ship{border-color:var(--done)} .verdict--ship .verdict__mark{color:var(--done)}
.verdict--needs_work{border-color:var(--active)}
.verdict--needs_work .verdict__mark{color:var(--active)}
.verdict--reject{border-color:var(--blocked)}
.verdict--reject .verdict__mark{color:var(--blocked)}

/* ── guard rail ────────────────────────────────────────── */
.guard{background:var(--surface2); border:1px solid var(--line2); border-left:3px solid var(--accent);
  border-radius:8px; padding:18px 20px}
.guard ol{margin:12px 0 0; padding-left:20px; display:flex; flex-direction:column; gap:7px;
  font-size:12.5px; color:var(--ink2); line-height:1.5}
.guard li::marker{font-family:"IBM Plex Mono",monospace; font-size:11px; color:var(--muted)}
details.guard summary{cursor:pointer; font-weight:600; font-size:14px;
  font-family:"IBM Plex Serif",Georgia,serif}
details.guard summary::marker{color:var(--accent)}
details.guard p{margin:8px 0 0; font-size:13px; color:var(--muted); max-width:74ch}

footer{border-top:1px solid var(--line2); padding-top:18px; font-size:12px;
  color:var(--muted); display:flex; flex-wrap:wrap; gap:14px; justify-content:space-between}
footer code{color:var(--ink2)}
a{color:var(--accent)}
:focus-visible{outline:2px solid var(--accent); outline-offset:2px; border-radius:3px}
@media (prefers-reduced-motion:reduce){*{animation:none!important; transition:none!important}}
@media (max-width:640px){
  .wrap{padding:28px 16px 64px; gap:40px}
  .task{grid-template-columns:auto 1fr}
  .round{gap:12px}
}
"""


def build():
    return f"""<title>Qnet GUI Refinement</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Serif:wght@500;600&display=swap">
<style>{CSS}</style>

<div class="wrap">

  <header class="mast">
    <p class="mast__eyebrow">
      <b>Qnet 0.90.34</b><span>&middot;</span><span>macOS queueing-network analyzer</span>
      <span>&middot;</span><span>87 Swift files &middot; 63,846 lines</span>
      <span>&middot;</span><span>{E(STATE["generated"])}</span>
    </p>
    <h1>Bringing the Qnet GUI to commercial grade</h1>
    <p class="mast__lede">
      A multi-agent build-and-critique loop refining the canvas, the window layout, the movable
      dialogs, the interactive shell and the numeric output of Qnet &mdash; measured against the
      bar set by MATLAB and Maple. Implementers work in parallel over disjoint file sets; critics
      review each round on separate lenses and hold the gate.
    </p>
    <p class="mast__phase">{E(STATE["phase"])}</p>
  </header>

  <section>
    <div class="sec__head">
      <h2>Gates</h2>
      <p>Every round must leave all of these green. A gate is never weakened to make work pass &mdash;
         a critic checks <code>validation/</code> for exactly that, every round.</p>
    </div>
    <ul class="gates">{gate_chips()}</ul>
  </section>

  <section>
    <div class="sec__head">
      <h2>Headline metrics</h2>
      <p>Objectively re-measurable, most by a literal <code>grep</code>. Critics re-measure rather
         than take an implementer&rsquo;s word; the last column is what was actually observed.</p>
    </div>
    <div class="tablewrap">
      <table>
        <thead><tr>
          <th scope="col">Measure</th><th scope="col">Baseline</th>
          <th scope="col">Target</th><th scope="col">Measured</th>
        </tr></thead>
        <tbody>{metrics_rows()}</tbody>
      </table>
    </div>
  </section>

  <section>
    <div class="sec__head">
      <h2>Workstreams</h2>
      <p>Six streams with <strong>disjoint file ownership</strong>. This is not a git repository, so
         there is no merge and no undo &mdash; two agents in one file would silently destroy each
         other&rsquo;s work. Anything a stream needs in a file it does not own goes through a written
         integration request that a serial integrator applies after the round.</p>
    </div>
    <div class="grid">{workstream_cards()}</div>
  </section>

  <section>
    <div class="sec__head">
      <h2>Round log</h2>
      <p>Rounds are sequential: each one&rsquo;s critique becomes the next one&rsquo;s assignment.
         The loop ends when critics find no blocking issues and judge that further review would not
         add value.</p>
    </div>
    <ol class="rounds">{round_log()}</ol>
  </section>

  <section>
    <details class="guard">
      <summary>Do not regress &mdash; {len(BACKLOG["do_not_regress"])} behaviours the audit found already correct</summary>
      <p>Qnet is a mature codebase with a genuinely good substrate. These are the parts the audit
         verified are already right; a regression here costs more than a missing feature is worth.
         Every round&rsquo;s craft critic checks the highest-value ones survived.</p>
      <ol>{guard_list()}</ol>
    </details>
  </section>

  <footer>
    <span>Generated from <code>docs/gui_work/BACKLOG.json</code> + <code>STATE.json</code> by <code>make_tracker.py</code></span>
    <span>Version pinned at <code>0.90.34</code> &mdash; rebuilding never bumps it</span>
  </footer>

</div>
"""


(HERE / "tracker.html").write_text(build())
print(f"wrote {HERE / 'tracker.html'}")
