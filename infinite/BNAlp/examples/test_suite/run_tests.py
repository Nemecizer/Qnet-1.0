#!/usr/bin/env python3
"""Test harness for BNAlp.

Runs the srbm_lp binary against every .txt input in this directory and
compares first-moment output against the matching .output file.

Usage:
    # Single solver:
    python3 run_tests.py --solver glpk
    python3 run_tests.py --solver cplex
    # Compare two solvers side by side:
    python3 run_tests.py --solvers cplex,glpk
"""
import argparse
import os
import re
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BNALP_ROOT = os.environ.get(
    "BNALP_ROOT",
    os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..")),
)
BINARY = os.path.join(BNALP_ROOT, "srbm_lp")
HERE = os.environ.get("BNALP_SUITE_DIR", SCRIPT_DIR)


def parse_expected(path):
    means, tols = {}, {}
    d = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("dimension"):
                d = int(line.split()[1])
                continue
            m = re.match(r"E\[Z_(\d+)\]\s+([-\d.eE+]+)(?:\s+tol=([-\d.eE+]+))?", line)
            if m:
                i = int(m.group(1))
                means[i] = float(m.group(2))
                tols[i] = float(m.group(3)) if m.group(3) else 0.03
    return d, means, tols


def parse_bnalp_output(stdout):
    means = {}
    for line in stdout.splitlines():
        m = re.match(r"E\[X_(\d+)\]\s*=\s*([-\d.eE+nan]+)", line)
        if m:
            means[int(m.group(1))] = float(m.group(2))
    return means


def run_one(txt_path, solver):
    t0 = time.time()
    try:
        proc = subprocess.run(
            [BINARY, "--input", txt_path, "--solver", solver],
            capture_output=True, text=True, timeout=600,
        )
        return proc.returncode, proc.stdout, proc.stderr, time.time() - t0
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT", 600.0


def evaluate(name, txt, out_expected, solver):
    d_exp, means_exp, tols = parse_expected(out_expected)
    rc, stdout, stderr, dt = run_one(txt, solver)
    means_act = parse_bnalp_output(stdout)
    errs = {}
    worst_rel = 0.0
    status = "OK"
    if rc != 0 or not means_act:
        status = f"SOLVER_FAIL(rc={rc})"
    else:
        for i, me in means_exp.items():
            ma = means_act.get(i, float("nan"))
            abs_e = abs(ma - me)
            rel_e = abs_e / abs(me) if me != 0 else abs_e
            errs[i] = (ma, me, abs_e, rel_e)
            if rel_e > worst_rel:
                worst_rel = rel_e
            if rel_e > tols.get(i, 0.03):
                status = "FAIL"
    return {
        "name": name, "d": d_exp, "solver": solver,
        "time_s": dt, "errs": errs, "worst_rel": worst_rel,
        "status": status,
    }


def run_suite(solvers, pattern=None, verbose=False):
    tests = sorted(f for f in os.listdir(HERE)
                   if f.endswith(".txt") and (pattern is None or pattern in f))
    all_rows = {s: [] for s in solvers}
    for tf in tests:
        name = tf[:-4]
        txt = os.path.join(HERE, tf)
        expected = os.path.join(HERE, name + ".output")
        if not os.path.exists(expected):
            continue
        for s in solvers:
            r = evaluate(name, txt, expected, s)
            all_rows[s].append(r)
            if verbose:
                print(f"[{r['status']}] {s}: {name} worst={r['worst_rel']*100:.2f}% ({r['time_s']:.1f}s)")
    return all_rows


def print_single(rows, solver):
    max_d = max((r["d"] or 2) for r in rows) if rows else 2
    hdr = ["#", "Test", "d", "Time"]
    for i in range(1, max_d + 1):
        hdr += [f"Z{i}*", f"Z{i}", "rel%"]
    hdr += ["Worst%", "Status"]

    def fmt_row(r, n):
        c = [str(n), r["name"], str(r["d"] or "?"), f"{r['time_s']:.2f}s"]
        for i in range(1, max_d + 1):
            if i in r["errs"]:
                ma, me, _, rel = r["errs"][i]
                c += [f"{me:.4f}", f"{ma:.4f}", f"{rel*100:.2f}"]
            else:
                c += ["", "", ""] if (r["d"] or 0) < i else ["-", "-", "-"]
        c += [f"{r['worst_rel']*100:.2f}", r["status"]]
        return c

    all_rows_fmt = [hdr] + [fmt_row(r, i + 1) for i, r in enumerate(rows)]
    widths = [max(len(row[c]) for row in all_rows_fmt) for c in range(len(hdr))]

    def L(row):
        return "  ".join(c.ljust(w) for c, w in zip(row, widths))

    print(f"\nBNAlp Test Results  (solver={solver})")
    print("=" * 80)
    print(L(hdr))
    print("  ".join("-" * w for w in widths))
    for row in all_rows_fmt[1:]:
        print(L(row))


def print_compare(all_rows, solvers):
    tests = [r["name"] for r in all_rows[solvers[0]]]
    hdr = ["#", "Test", "d", "Expected"]
    for s in solvers:
        hdr += [f"{s}-worst%", f"{s}-time", f"{s}-status"]

    table = [hdr]
    for n, name in enumerate(tests, 1):
        d = all_rows[solvers[0]][n-1]["d"]
        errs = all_rows[solvers[0]][n-1]["errs"]
        exp_str = "/".join(f"{v[1]:.3f}" for v in errs.values())
        row = [str(n), name, str(d), exp_str]
        for s in solvers:
            r = all_rows[s][n-1]
            row += [f"{r['worst_rel']*100:.2f}", f"{r['time_s']:.1f}s", r["status"]]
        table.append(row)

    widths = [max(len(c) for c in col) for col in zip(*table)]

    def L(row):
        return "  ".join(c.ljust(w) for c, w in zip(row, widths))

    print(f"\nBNAlp Solver Comparison")
    print("=" * 80)
    print(L(hdr))
    print("  ".join("-" * w for w in widths))
    for row in table[1:]:
        print(L(row))


def print_summary(rows, label):
    total = len(rows)
    ok = sum(1 for r in rows if r["status"] == "OK")
    fail = sum(1 for r in rows if r["status"] == "FAIL")
    err = total - ok - fail
    print(f"\n[{label}] {ok}/{total} PASS, {fail} FAIL, {err} solver errors")
    if rows:
        by_rel = sorted((r for r in rows if r["status"] != "SOLVER_FAIL"),
                        key=lambda r: r["worst_rel"])
        if by_rel:
            print(f"  Best:  {by_rel[0]['name']} ({by_rel[0]['worst_rel']*100:.3f}%)")
            print(f"  Worst: {by_rel[-1]['name']} ({by_rel[-1]['worst_rel']*100:.3f}%)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--solver", default=None)
    ap.add_argument("--solvers", default=None, help="Comma-separated list")
    ap.add_argument("--pattern")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--normalize", action="store_true",
                    help="Append basis_normalize=1 to every input")
    ap.add_argument("--smoothness", type=float, default=0.0,
                    help="Append smoothness_weight=... to every input")
    args = ap.parse_args()

    # If extra options requested, stage a temp directory with augmented inputs
    if args.normalize or args.smoothness > 0:
        import tempfile, shutil
        tmp = tempfile.mkdtemp(prefix="bnalp_suite_")
        global HERE
        for f in os.listdir(HERE):
            src = os.path.join(HERE, f)
            dst = os.path.join(tmp, f)
            if f.endswith(".txt"):
                with open(src) as fh: body = fh.read()
                body = body.rstrip() + "\n"
                if args.normalize:
                    body += "basis_normalize 1\n"
                if args.smoothness > 0:
                    body += f"smoothness_weight {args.smoothness}\n"
                with open(dst, "w") as fh: fh.write(body)
            else:
                shutil.copyfile(src, dst)
        HERE = tmp
        print(f"(using staged inputs in {tmp})")

    if args.solvers:
        solvers = args.solvers.split(",")
    elif args.solver:
        solvers = [args.solver]
    else:
        solvers = ["cplex", "glpk"]

    if not os.path.exists(BINARY):
        print(f"Binary not found: {BINARY}", file=sys.stderr)
        sys.exit(1)

    all_rows = run_suite(solvers, args.pattern, args.verbose)
    if not any(all_rows.values()):
        print("No tests matched.", file=sys.stderr)
        sys.exit(1)

    if len(solvers) == 1:
        print_single(all_rows[solvers[0]], solvers[0])
    else:
        for s in solvers:
            print_single(all_rows[s], s)
        print_compare(all_rows, solvers)

    for s in solvers:
        print_summary(all_rows[s], s)


if __name__ == "__main__":
    main()
