#!/usr/bin/env python3
"""Parse the raw outputs in validation/feedback_runs/ and produce a comparison
table per network (rho, Gamma, sojourn per station; per-class T_total). Sim is
treated as ground truth; each analytical method is reported with relative
deviation vs sim where applicable.
"""
import os, re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
RUNS = os.path.join(ROOT, 'validation', 'feedback_runs')


def parse_solver_out(path):
    """Pull out the per-station rho/Gamma/sojourn and per-class T_total values
    from a -c (compact) output file. Returns dict of {key: value}.
    """
    if not os.path.exists(path):
        return {}
    text = open(path).read()
    # Strip the simulator's ± stderr in parens so a bare float remains.
    text = re.sub(r'\s*\([0-9.+-]+\)\s*', '', text)
    out = {}
    for m in re.finditer(r'^(rho|Gamma|sojourn)_(\d+)\s*=\s*([0-9eE.+-]+)', text, re.M):
        out[f"{m.group(1)}_{int(m.group(2))}"] = float(m.group(3))
    for m in re.finditer(r'^E\[Q_(\d+)\]\s*=\s*([0-9eE.+-]+)', text, re.M):
        out[f"Q_{int(m.group(1))}"] = float(m.group(2))
    for m in re.finditer(r'^T_total\(class\s+(\d+)\)\s*=\s*([0-9eE.+-]+)', text, re.M):
        out[f"T_class_{int(m.group(1))}"] = float(m.group(2))
    for m in re.finditer(r'^W_total\(class\s+(\d+)\)\s*=\s*([0-9eE.+-]+)', text, re.M):
        out[f"W_class_{int(m.group(1))}"] = float(m.group(2))
    return out


def fmt(v):
    if v is None: return "    -    "
    if isinstance(v, float):
        if abs(v) < 1e-6: return f"{0.0:>9.4f}"
        return f"{v:>9.4f}"
    return f"{v:>9}"


def deltapct(val, ref):
    if val is None or ref is None or ref == 0: return "      "
    pct = 100.0 * (val - ref) / ref
    return f"{pct:+6.1f}%"


def report_network(name, indices_to_show=None):
    base = os.path.join(RUNS, name)
    qna = parse_solver_out(os.path.join(base, 'qna.out'))
    sbd = parse_solver_out(os.path.join(base, 'sbd.out'))
    sm  = parse_solver_out(os.path.join(base, 'sm.out'))
    sim = parse_solver_out(os.path.join(base, 'sim.out'))

    # Determine number of stations from rho keys
    stations = sorted({int(k.split('_')[1]) for k in sim.keys() if k.startswith('rho_')})
    if not stations:
        stations = sorted({int(k.split('_')[1]) for k in qna.keys() if k.startswith('rho_')})
    classes = sorted({int(k.split('_')[2]) for k in sim.keys() if k.startswith('T_class_')})

    print(f"\n### {name}")
    print()
    if not stations:
        print("(no station data)")
        return
    # rho
    print("Per-station ρ:")
    print(f"  {'Station':>8s} | {'QNA':>9s} | {'SBD':>9s} | {'SM':>9s} | {'Sim':>9s}")
    for i in stations:
        k = f"rho_{i}"
        print(f"  S{i:>7d} | {fmt(qna.get(k))} | {fmt(sbd.get(k))} | {fmt(sm.get(k))} | {fmt(sim.get(k))}")
    # Gamma
    print("\nPer-station Γ (throughput):")
    print(f"  {'Station':>8s} | {'QNA':>9s} | {'SBD':>9s} | {'SM':>9s} | {'Sim':>9s}")
    for i in stations:
        k = f"Gamma_{i}"
        print(f"  S{i:>7d} | {fmt(qna.get(k))} | {fmt(sbd.get(k))} | {fmt(sm.get(k))} | {fmt(sim.get(k))}")
    # Sojourn per station (per visit)
    print("\nPer-station mean sojourn (per visit):")
    print(f"  {'Station':>8s} | {'QNA':>9s} {'%vs sim':>7s} | {'SBD':>9s} {'%vs sim':>7s} | {'SM':>9s} {'%vs sim':>7s} | {'Sim':>9s}")
    for i in stations:
        k = f"sojourn_{i}"
        sv = sim.get(k)
        print(f"  S{i:>7d} | {fmt(qna.get(k))} {deltapct(qna.get(k), sv)} | "
              f"{fmt(sbd.get(k))} {deltapct(sbd.get(k), sv)} | "
              f"{fmt(sm.get(k))} {deltapct(sm.get(k), sv)} | "
              f"{fmt(sv)}")

    # Per-class total time in system (sum across visits per entering class)
    if classes:
        print("\nPer-class T_total (sum of sojourns across all class transitions):")
        print(f"  {'Class':>8s} | {'QNA':>9s} {'%vs sim':>7s} | {'SBD':>9s} {'%vs sim':>7s} | {'SM':>9s} {'%vs sim':>7s} | {'Sim':>9s}")
        for c in classes:
            k = f"T_class_{c}"
            sv = sim.get(k)
            if sv is None or sv < 1e-9:  # zero or missing sim values are usually derived classes
                continue
            print(f"  c{c:>7d} | {fmt(qna.get(k))} {deltapct(qna.get(k), sv)} | "
                  f"{fmt(sbd.get(k))} {deltapct(sbd.get(k), sv)} | "
                  f"{fmt(sm.get(k))} {deltapct(sm.get(k), sv)} | "
                  f"{fmt(sv)}")


for d in sorted(os.listdir(RUNS)):
    if os.path.isdir(os.path.join(RUNS, d)):
        report_network(d)
