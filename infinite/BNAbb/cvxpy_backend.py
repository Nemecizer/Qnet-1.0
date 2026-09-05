"""Optional CVXPY adapter for the BAR conic intermediate representation.

CVXPY and NumPy are intentionally optional.  This module never labels a
floating-point optimizer value as a formal certificate.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple


VALIDATION_TOLERANCE = 1.0e-7


class BackendUnavailable(RuntimeError):
    """Raised when a requested conic backend cannot be used."""


def _imports():
    try:
        import cvxpy as cp  # type: ignore
        import numpy as np  # type: ignore
    except ImportError as error:
        raise BackendUnavailable(
            "CVXPY is not installed. The relaxation can still be exported as JSON; "
            "install cvxpy with an SDP-capable solver to obtain numerical candidates."
        ) from error
    return cp, np


def _choose_solvers(cp: Any, requested: Optional[str]) -> List[str]:
    installed = set(cp.installed_solvers())
    if requested:
        if requested not in installed:
            raise BackendUnavailable(
                f"requested CVXPY solver {requested!r} is not installed; installed solvers: "
                + (", ".join(sorted(installed)) or "none")
            )
        return [requested]
    candidates = [name for name in ("MOSEK", "CVXOPT", "CLARABEL", "SCS") if name in installed]
    if not candidates:
        raise BackendUnavailable(
            "CVXPY is installed, but no recognized SDP-capable solver is available "
            "(tried MOSEK, CVXOPT, CLARABEL, and SCS)."
        )
    return candidates


def _linear_expression(cp: Any, x: Any, terms: Sequence[Mapping[str, Any]]) -> Any:
    expression = 0.0
    for term in terms:
        expression += float(term["coefficient"]) * x[int(term["variable"])]
    return expression


def _constraints(cp: Any, x: Any, ir: Mapping[str, Any]) -> List[Any]:
    constraints: List[Any] = []
    nonnegative = [int(identifier) for identifier in ir["nonnegative_variables"]]
    if nonnegative:
        constraints.append(x[nonnegative] >= 0.0)
    for equality in ir["equalities"]:
        constraints.append(
            _linear_expression(cp, x, equality["terms"]) == float(equality["rhs"])
        )
    for block in ir["psd_blocks"]:
        matrix = cp.bmat(
            [[x[int(identifier)] for identifier in row] for row in block["entries"]]
        )
        constraints.append(matrix >> 0)
    return constraints


def _validate_primal(np: Any, values: Any, ir: Mapping[str, Any]) -> Mapping[str, Any]:
    vector = np.asarray(values, dtype=float).reshape(-1)
    if vector.size != len(ir["variables"]) or not np.all(np.isfinite(vector)):
        return {
            "passed": False,
            "reason": "primal vector is missing or contains non-finite values",
        }
    maximum_equality_residual = 0.0
    maximum_scaled_equality_residual = 0.0
    for equality in ir["equalities"]:
        lhs = sum(
            float(term["coefficient"]) * vector[int(term["variable"])]
            for term in equality["terms"]
        )
        rhs = float(equality["rhs"])
        residual = abs(lhs - rhs)
        scale = max(
            1.0,
            abs(rhs),
            sum(
                abs(float(term["coefficient"]) * vector[int(term["variable"])])
                for term in equality["terms"]
            ),
        )
        maximum_equality_residual = max(maximum_equality_residual, residual)
        maximum_scaled_equality_residual = max(maximum_scaled_equality_residual, residual / scale)

    maximum_value_scale = max(1.0, float(np.max(np.abs(vector))))
    minimum_nonnegative = min(
        (float(vector[int(identifier)]) for identifier in ir["nonnegative_variables"]),
        default=0.0,
    )
    scaled_nonnegative_violation = max(0.0, -minimum_nonnegative) / maximum_value_scale
    minimum_psd_eigenvalue = math.inf
    maximum_scaled_psd_violation = 0.0
    for block in ir["psd_blocks"]:
        matrix = np.asarray(
            [[vector[int(identifier)] for identifier in row] for row in block["entries"]],
            dtype=float,
        )
        eigenvalue = float(np.min(np.linalg.eigvalsh(0.5 * (matrix + matrix.T))))
        minimum_psd_eigenvalue = min(minimum_psd_eigenvalue, eigenvalue)
        block_scale = max(1.0, float(np.max(np.abs(matrix))))
        maximum_scaled_psd_violation = max(
            maximum_scaled_psd_violation, max(0.0, -eigenvalue) / block_scale
        )
    passed = (
        maximum_scaled_equality_residual <= VALIDATION_TOLERANCE
        and scaled_nonnegative_violation <= VALIDATION_TOLERANCE
        and maximum_scaled_psd_violation <= VALIDATION_TOLERANCE
    )
    return {
        "passed": passed,
        "tolerance": VALIDATION_TOLERANCE,
        "maximum_equality_residual": maximum_equality_residual,
        "maximum_scaled_equality_residual": maximum_scaled_equality_residual,
        "minimum_nonnegative_moment": minimum_nonnegative,
        "scaled_nonnegative_violation": scaled_nonnegative_violation,
        "minimum_psd_eigenvalue": minimum_psd_eigenvalue,
        "maximum_scaled_psd_violation": maximum_scaled_psd_violation,
        "formal_certificate": False,
        "roundoff_note": (
            "Residual checks reject visibly infeasible iterates but do not provide interval- "
            "or rational-arithmetic proof of the optimum."
        ),
    }

def _one_direction(
    cp: Any,
    np: Any,
    ir: Mapping[str, Any],
    objective: Mapping[str, Any],
    direction: str,
    solvers: Sequence[str],
) -> Tuple[Mapping[str, Any], Optional[str]]:
    last_error: Optional[str] = None
    for solver in solvers:
        x = cp.Variable(len(ir["variables"]))
        constraints = _constraints(cp, x, ir)
        target = x[int(objective["variable"])]
        cvx_objective = cp.Minimize(target) if direction == "lower" else cp.Maximize(target)
        problem = cp.Problem(cvx_objective, constraints)
        try:
            value = problem.solve(solver=solver, verbose=False)
        except Exception as error:  # CVXPY exposes solver-specific exception types.
            last_error = f"{solver}: {type(error).__name__}: {error}"
            continue
        status = str(problem.status)
        result: Dict[str, Any] = {
            "solver": solver,
            "solver_status": status,
            "certified": False,
        }
        if status in {"unbounded", "unbounded_inaccurate"}:
            result.update(
                {
                    "status": "no_finite_relaxation_bound_detected",
                    "numerical_value": None,
                }
            )
            return result, None
        if status not in {"optimal", "optimal_inaccurate"} or x.value is None:
            result.update({"status": "solver_did_not_return_an_optimum", "numerical_value": None})
            return result, None
        validation = _validate_primal(np, x.value, ir)
        result["validation"] = validation
        result["numerical_value"] = float(value) if value is not None and math.isfinite(value) else None
        if status == "optimal" and validation["passed"] and result["numerical_value"] is not None:
            result["status"] = "validated_numerical_candidate"
        else:
            result["status"] = "numerical_candidate_rejected_for_reporting"
        result["interpretation"] = (
            "This is a floating-point estimate of the exact outer-relaxation optimum, "
            "not a formally certified stationary-moment bound."
        )
        return result, None
    return {
        "status": "backend_failure",
        "certified": False,
        "numerical_value": None,
        "message": last_error or "all candidate solvers failed",
    }, last_error


def solve_relaxation(
    ir: Mapping[str, Any], *, requested_solver: Optional[str] = None
) -> Mapping[str, Any]:
    """Solve every lower/upper objective and independently check feasibility."""
    cp, np = _imports()
    solvers = _choose_solvers(cp, requested_solver)
    results: Dict[str, Any] = {}
    failures: List[str] = []
    used = set()
    for objective in ir["objectives"]:
        target = {"moment": objective["moment"]}
        for direction in ("lower", "upper"):
            result, error = _one_direction(cp, np, ir, objective, direction, solvers)
            target[direction] = result
            if result.get("solver"):
                used.add(result["solver"])
            if error:
                failures.append(error)
        results[objective["name"]] = target
    return {
        "targets": results,
        "diagnostics": {
            "general_relaxation_built": True,
            "numerical_backend_used": True,
            "backend": "cvxpy",
            "installed_solvers_considered": solvers,
            "solvers_used": sorted(used),
            "backend_failures": failures,
            "formal_certification_available": False,
        },
    }
