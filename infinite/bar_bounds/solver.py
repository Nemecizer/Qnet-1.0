#!/usr/bin/env python3
"""Command-line interface for the orthant-SRBM BAR bounds toolkit."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping

if __package__:
    from .bar_bounds import InputError, build_relaxation, load_model_file, solve_model
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from bar_bounds import InputError, build_relaxation, load_model_file, solve_model


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Construct or solve BAR moment bounds for a stable orthant SRBM."
    )
    parser.add_argument("model", help="versioned JSON model file")
    parser.add_argument(
        "--backend",
        choices=("none", "auto", "cvxpy"),
        default="none",
        help="none exports/builds only; auto uses CVXPY if present; cvxpy requires it",
    )
    parser.add_argument("--cvxpy-solver", help="specific installed CVXPY solver name")
    parser.add_argument(
        "--force-relaxation",
        action="store_true",
        help="build the SDP even when an exact 1D/product-form answer exists",
    )
    parser.add_argument("--export-relaxation", help="write the complete conic IR as JSON")
    parser.add_argument("--output", help="write the versioned result JSON to this path")
    parser.add_argument("--json", action="store_true", help="print result JSON to stdout")
    parser.add_argument(
        "--require-bounds",
        action="store_true",
        help="exit nonzero when no exact or numerical target bound was produced",
    )
    return parser


def _write_json(path: str, value: Mapping[str, Any]) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")


def _human(result: Mapping[str, Any]) -> str:
    method = result["method"]
    diagnostics = result.get("diagnostics", {})
    lines = [
        f"Model: {result['model']['name']} ({result['model']['dimension']} dimensions)",
        f"Method: {method['kind']}",
        f"Certified: {'yes' if method.get('certified') else 'no'}",
    ]
    backend_status = diagnostics.get("backend_status")
    if backend_status:
        lines.append(f"Backend status: {backend_status}")
    if diagnostics.get("message"):
        lines.append(f"Backend detail: {diagnostics['message']}")
    solved_targets = 0
    for name, target in method.get("targets", {}).items():
        if "lower_bound" in target:
            solved_targets += 1
            lines.append(
                f"  {name}: [{target['lower_bound']:.12g}, {target['upper_bound']:.12g}] (exact)"
            )
        else:
            lower = target["lower"]
            upper = target["upper"]
            if lower.get("numerical_value") is not None or upper.get("numerical_value") is not None:
                solved_targets += 1
            lines.append(
                f"  {name}: lower={lower.get('numerical_value')} ({lower['status']}), "
                f"upper={upper.get('numerical_value')} ({upper['status']})"
            )
    lines.append(
        f"Targets with numerical values: {solved_targets}/{len(method.get('targets', {}))}"
    )
    if "relaxation" in result:
        counts = result["relaxation"]["counts"]
        lines.append(
            f"Relaxation: {counts['variables']} moments, {counts['equalities']} equalities, "
            f"{counts['psd_blocks']} PSD blocks"
        )
    return "\n".join(lines)


def _has_reported_bound(result: Mapping[str, Any]) -> bool:
    for target in result.get("method", {}).get("targets", {}).values():
        if "lower_bound" in target or "upper_bound" in target:
            return True
        for side in ("lower", "upper"):
            if target.get(side, {}).get("numerical_value") is not None:
                return True
    return False


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        model = load_model_file(args.model)
        result, relaxation = solve_model(
            model,
            backend=args.backend,
            cvxpy_solver=args.cvxpy_solver,
            force_relaxation=args.force_relaxation,
        )
        if args.export_relaxation:
            if relaxation is None:
                relaxation = build_relaxation(model)
            _write_json(args.export_relaxation, relaxation)
            result.setdefault("artifacts", {})["relaxation"] = str(
                Path(args.export_relaxation).resolve()
            )
        if args.output:
            _write_json(args.output, result)
        if args.json:
            json.dump(result, sys.stdout, indent=2, sort_keys=True, allow_nan=False)
            sys.stdout.write("\n")
        else:
            print(_human(result))
        if args.require_bounds and not _has_reported_bound(result):
            detail = result.get("diagnostics", {}).get(
                "message", "the selected backend returned no target values"
            )
            print(f"error: no performance bounds were produced: {detail}", file=sys.stderr)
            return 3
        return 0
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
