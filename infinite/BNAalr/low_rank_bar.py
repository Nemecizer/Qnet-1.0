#!/usr/bin/env python3
"""Adaptive low-rank BAR approximation for an orthant SRBM.

The approximation is a nonnegative mixture of separable exponential laws.
For fixed exponential rates, the mixture weights are fitted by a convex,
simplex-constrained least-squares problem built from the moment-generating
function form of the Basic Adjoint Relationship (BAR).  Rank is increased
until both a held-out BAR residual and the change in the reported means meet
the requested tolerances.

This module deliberately distinguishes an exact Harrison--Williams
product-form answer from a general low-rank approximation.  A small BAR
residual is numerical evidence, not a certified error bound on moments.
"""

from __future__ import annotations

import argparse
from fractions import Fraction
import json
import math
import pathlib
import sys
from typing import Any, Iterable, List, Sequence, Tuple

# NumPy is OPTIONAL and must stay that way: this module is one of the
# standard-library solvers that has to keep working on a bare interpreter, which
# is the contract the packaged app relies on. When NumPy is present the two
# O(rows x n) primitives below are handed to BLAS; when it is absent the
# original pure-Python versions run unchanged and produce the same answers.
try:                                    # pragma: no cover - environment dependent
    import numpy as _np
except ImportError:                     # pragma: no cover - environment dependent
    _np = None


SCHEMA_VERSION = 1
PRIMES = (
    2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53,
    59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113,
    127, 131,
)


class ModelError(ValueError):
    """Raised when an input is outside the solver's documented scope."""


def _finite(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ModelError(f"{label} must be a finite number")
    out = float(value)
    if not math.isfinite(out):
        raise ModelError(f"{label} must be a finite number")
    return out


def _vector(value: Any, n: int, label: str) -> List[float]:
    if not isinstance(value, list) or len(value) != n:
        raise ModelError(f"{label} must contain exactly {n} numbers")
    return [_finite(x, f"{label}[{i}]") for i, x in enumerate(value)]


def _matrix(value: Any, n: int, label: str) -> List[List[float]]:
    if not isinstance(value, list) or len(value) != n:
        raise ModelError(f"{label} must be a {n} by {n} matrix")
    return [_vector(row, n, f"{label}[{i}]") for i, row in enumerate(value)]


def _solve(a: Sequence[Sequence[float]], b: Sequence[float]) -> List[float]:
    """Scaled-partial-pivot Gaussian elimination."""
    n = len(a)
    m = [list(map(float, row)) + [float(b[i])] for i, row in enumerate(a)]
    scales = [max((abs(x) for x in row), default=0.0) for row in a]
    if any(s <= 0.0 for s in scales):
        raise ModelError("reflection matrix is singular")
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(m[r][col]) / scales[r])
        if abs(m[pivot][col]) <= 1e-13 * max(1.0, scales[pivot]):
            raise ModelError("reflection matrix is singular or ill-conditioned")
        if pivot != col:
            m[col], m[pivot] = m[pivot], m[col]
            scales[col], scales[pivot] = scales[pivot], scales[col]
        piv = m[col][col]
        for row in range(col + 1, n):
            factor = m[row][col] / piv
            if factor == 0.0:
                continue
            m[row][col] = 0.0
            for k in range(col + 1, n + 1):
                m[row][k] -= factor * m[col][k]
    x = [0.0] * n
    for row in range(n - 1, -1, -1):
        rhs = m[row][n] - math.fsum(m[row][j] * x[j] for j in range(row + 1, n))
        x[row] = rhs / m[row][row]
    return x


def _inverse(a: Sequence[Sequence[float]]) -> List[List[float]]:
    n = len(a)
    columns = []
    for j in range(n):
        e = [0.0] * n
        e[j] = 1.0
        columns.append(_solve(a, e))
    return [[columns[j][i] for j in range(n)] for i in range(n)]


def _matvec(a: Sequence[Sequence[float]], x: Sequence[float]) -> List[float]:
    return [math.fsum(row[j] * x[j] for j in range(len(x))) for row in a]


def _jacobi_eigenvalues(a: Sequence[Sequence[float]]) -> List[float]:
    """Eigenvalues of a small real symmetric matrix without dependencies."""
    n = len(a)
    m = [list(row) for row in a]
    scale = max(1.0, max(abs(x) for row in m for x in row))
    for _ in range(max(20, 40 * n * n)):
        p, q, largest = 0, 0, 0.0
        for i in range(n):
            for j in range(i + 1, n):
                if abs(m[i][j]) > largest:
                    p, q, largest = i, j, abs(m[i][j])
        if largest <= 1e-14 * scale:
            break
        app, aqq, apq = m[p][p], m[q][q], m[p][q]
        tau = (aqq - app) / (2.0 * apq)
        t = math.copysign(1.0, tau) / (abs(tau) + math.sqrt(1.0 + tau * tau))
        c = 1.0 / math.sqrt(1.0 + t * t)
        s = t * c
        for k in range(n):
            if k == p or k == q:
                continue
            mkp, mkq = m[k][p], m[k][q]
            m[k][p] = m[p][k] = c * mkp - s * mkq
            m[k][q] = m[q][k] = s * mkp + c * mkq
        m[p][p] = c * c * app - 2.0 * s * c * apq + s * s * aqq
        m[q][q] = s * s * app + 2.0 * s * c * apq + c * c * aqq
        m[p][q] = m[q][p] = 0.0
    return [m[i][i] for i in range(n)]


def _halton(index: int, base: int) -> float:
    result = 0.0
    factor = 1.0 / base
    i = index
    while i > 0:
        result += factor * (i % base)
        i //= base
        factor /= base
    return result


def _project_simplex(values: Sequence[float], mass: float) -> List[float]:
    if mass == 0.0:
        return [0.0] * len(values)
    ordered = sorted(values, reverse=True)
    cumulative = 0.0
    rho = 0
    theta = 0.0
    for j, value in enumerate(ordered, 1):
        cumulative += value
        candidate = (cumulative - mass) / j
        if value - candidate > 0.0:
            rho = j
            theta = candidate
    if rho == 0:
        return [mass / len(values)] * len(values)
    return [max(value - theta, 0.0) for value in values]


def _project_groups(values: Sequence[float], rank: int, masses: Sequence[float]) -> List[float]:
    out: List[float] = []
    for group, mass in enumerate(masses):
        start = group * rank
        out.extend(_project_simplex(values[start:start + rank], mass))
    return out


def _objective_and_gradient(a: Sequence[Sequence[float]], x: Sequence[float]) -> Tuple[float, List[float]]:
    rows = len(a)
    residuals = [math.fsum(row[j] * x[j] for j in range(len(x))) for row in a]
    objective = 0.5 * math.fsum(r * r for r in residuals) / rows
    gradient = [
        math.fsum(a[i][j] * residuals[i] for i in range(rows)) / rows
        for j in range(len(x))
    ]
    return objective, gradient


def _lipschitz(a: Sequence[Sequence[float]]) -> float:
    n = len(a[0])
    rows = len(a)
    v = [1.0 / math.sqrt(n)] * n
    estimate = 0.0
    for _ in range(60):
        av = [math.fsum(row[j] * v[j] for j in range(n)) for row in a]
        w = [math.fsum(a[i][j] * av[i] for i in range(rows)) / rows for j in range(n)]
        norm = math.sqrt(math.fsum(z * z for z in w))
        if norm <= 1e-30:
            return 1.0
        v = [z / norm for z in w]
        estimate = math.fsum(v[j] * w[j] for j in range(n))
    return max(estimate, 1e-12)


def _accelerated_primitives(a: Sequence[Sequence[float]]):
    """(objective_and_gradient, lipschitz) backed by BLAS, or None without NumPy.

    Both are the same mathematics as the pure-Python functions above:
    ``residual = A x``, ``objective = |r|^2 / 2 rows``, ``gradient = A^T r / rows``.
    Profiling put 99.8% of this module's runtime inside those two mat-vecs,
    expressed as Python generator expressions over ``math.fsum``.

    One deliberate numerical difference: ``math.fsum`` sums exactly, while BLAS
    sums pairwise. Results therefore agree to roughly machine epsilon rather
    than bit-for-bit. That is well inside every tolerance this module asserts,
    and the fallback path remains available for anyone who needs the exact
    summation.
    """
    if _np is None:
        return None
    matrix = _np.asarray(a, dtype=float)
    if matrix.ndim != 2 or matrix.size == 0:
        return None
    rows = matrix.shape[0]

    def objective_and_gradient(_a, x):
        residual = matrix @ _np.asarray(x, dtype=float)
        objective = 0.5 * float(residual @ residual) / rows
        return objective, (matrix.T @ residual / rows).tolist()

    def lipschitz(_a):
        n = matrix.shape[1]
        v = _np.full(n, 1.0 / math.sqrt(n))
        estimate = 0.0
        for _ in range(60):
            w = matrix.T @ (matrix @ v) / rows
            norm = float(_np.sqrt(w @ w))
            if norm <= 1e-30:
                return 1.0
            v = w / norm
            estimate = float(v @ w)
        return max(estimate, 1e-12)

    return objective_and_gradient, lipschitz


def _fit_weights(
    a: Sequence[Sequence[float]], rank: int, masses: Sequence[float],
    maximum_iterations: int, initial: Sequence[float] | None = None,
) -> Tuple[List[float], int, float, float]:
    # Swap only the two hot primitives. The FISTA body below is O(n) per
    # iteration with n = rank * groups, which is small; the mat-vecs are
    # O(rows * n) and are the whole cost.
    _accelerated = _accelerated_primitives(a)
    if _accelerated is None:
        _objgrad, _lip = _objective_and_gradient, _lipschitz
    else:
        _objgrad, _lip = _accelerated

    n = rank * len(masses)
    if initial is None or len(initial) != n:
        x = [mass / rank for mass in masses for _ in range(rank)]
    else:
        x = _project_groups(initial, rank, masses)
    y = list(x)
    momentum = 1.0
    step = 0.95 / _lip(a)
    old_objective, _ = _objgrad(a, x)
    projected_change = math.inf
    for iteration in range(1, maximum_iterations + 1):
        _, gradient = _objgrad(a, y)
        candidate = _project_groups(
            [y[j] - step * gradient[j] for j in range(n)], rank, masses
        )
        objective, _ = _objgrad(a, candidate)
        if objective > old_objective * (1.0 + 1e-12):
            # Restart acceleration. The underlying projected-gradient step is
            # monotone for the estimated Lipschitz constant.
            y = list(x)
            momentum = 1.0
            _, gradient = _objgrad(a, y)
            candidate = _project_groups(
                [y[j] - step * gradient[j] for j in range(n)], rank, masses
            )
            objective, _ = _objgrad(a, candidate)
            if objective > old_objective:
                step *= 0.5
                continue
        projected_change = max(abs(candidate[j] - x[j]) for j in range(n))
        next_momentum = 0.5 * (1.0 + math.sqrt(1.0 + 4.0 * momentum * momentum))
        y = [
            candidate[j] + ((momentum - 1.0) / next_momentum) * (candidate[j] - x[j])
            for j in range(n)
        ]
        x = candidate
        relative_drop = abs(old_objective - objective) / max(1.0, old_objective)
        old_objective = objective
        momentum = next_momentum
        if projected_change <= 2e-13 and relative_drop <= 2e-14:
            break
    return x, iteration, old_objective, projected_change


def _skew_symmetry_residual(
    reflection: Sequence[Sequence[float]], covariance: Sequence[Sequence[float]],
) -> float:
    d = len(reflection)
    diag = [covariance[i][i] / reflection[i][i] for i in range(d)]
    worst = 0.0
    for i in range(d):
        for j in range(d):
            lhs = 2.0 * covariance[i][j]
            rhs = reflection[i][j] * diag[j] + diag[i] * reflection[j][i]
            worst = max(worst, abs(lhs - rhs) / max(1.0, abs(lhs), abs(rhs)))
    return worst


def _exact_decimal_skew_symmetry(
    reflection: Sequence[Sequence[float]], covariance: Sequence[Sequence[float]],
) -> bool:
    """Verify product-form skew symmetry for the actual decimal input."""

    d = len(reflection)
    r = [[Fraction(str(value)) for value in row] for row in reflection]
    sigma = [[Fraction(str(value)) for value in row] for row in covariance]
    diagonal = [sigma[i][i] / r[i][i] for i in range(d)]
    return all(
        2 * sigma[i][j]
        == r[i][j] * diagonal[j] + diagonal[i] * r[j][i]
        for i in range(d)
        for j in range(d)
    )


def _candidate_rates(base_rates: Sequence[float], maximum_rank: int, log_span: float) -> List[List[float]]:
    rates = [list(base_rates)]
    for h in range(1, maximum_rank):
        vector = []
        for j, base in enumerate(base_rates):
            u = _halton(h + 1, PRIMES[j])
            vector.append(base * math.exp(log_span * (2.0 * u - 1.0)))
        rates.append(vector)
    return rates


def _collocation_points(
    base_rates: Sequence[float], count: int, offset: int,
) -> List[List[float]]:
    d = len(base_rates)
    points: List[List[float]] = []
    # Axis points make marginal transforms visible even in a small design.
    for j in range(d):
        for multiple in (0.15, 0.5, 1.25):
            s = [0.0] * d
            s[j] = -multiple * base_rates[j]
            points.append(s)
            if len(points) >= count:
                return points
    index = offset
    while len(points) < count:
        points.append([
            -base_rates[j] * (0.04 + 1.46 * _halton(index, PRIMES[j]))
            for j in range(d)
        ])
        index += 1
    return points


def _gamma(s: Sequence[float], drift: Sequence[float], covariance: Sequence[Sequence[float]]) -> float:
    linear = math.fsum(drift[j] * s[j] for j in range(len(s)))
    quadratic = 0.5 * math.fsum(
        s[i] * covariance[i][j] * s[j]
        for i in range(len(s)) for j in range(len(s))
    )
    return linear + quadratic


def _transform(s: Sequence[float], rates: Sequence[float], omitted: int | None = None) -> float:
    return math.prod(
        rates[j] / (rates[j] - s[j])
        for j in range(len(s)) if j != omitted
    )


def _bar_matrix(
    points: Sequence[Sequence[float]], rates: Sequence[Sequence[float]],
    drift: Sequence[float], covariance: Sequence[Sequence[float]],
    reflection: Sequence[Sequence[float]], boundary_masses: Sequence[float],
) -> List[List[float]]:
    rank, d = len(rates), len(drift)
    rows: List[List[float]] = []
    for s in points:
        g = _gamma(s, drift, covariance)
        face_dot = [math.fsum(s[j] * reflection[j][i] for j in range(d)) for i in range(d)]
        scale = abs(g) + math.fsum(abs(face_dot[i]) * boundary_masses[i] for i in range(d)) + 1e-12
        row = [g * _transform(s, rates[h]) / scale for h in range(rank)]
        for i in range(d):
            row.extend(
                face_dot[i] * _transform(s, rates[h], omitted=i) / scale
                for h in range(rank)
            )
        rows.append(row)
    return rows


def _unscaled_residuals(
    points: Sequence[Sequence[float]], rates: Sequence[Sequence[float]], weights: Sequence[float],
    drift: Sequence[float], covariance: Sequence[Sequence[float]],
    reflection: Sequence[Sequence[float]], boundary_masses: Sequence[float],
) -> Tuple[float, float]:
    rank, d = len(rates), len(drift)
    relative: List[float] = []
    for s in points:
        interior_transform = math.fsum(
            weights[h] * _transform(s, rates[h]) for h in range(rank)
        )
        g = _gamma(s, drift, covariance)
        residual = g * interior_transform
        scale = abs(g * interior_transform)
        for i in range(d):
            face_dot = math.fsum(s[j] * reflection[j][i] for j in range(d))
            boundary_transform = math.fsum(
                weights[(i + 1) * rank + h] * _transform(s, rates[h], omitted=i)
                for h in range(rank)
            )
            residual += face_dot * boundary_transform
            scale += abs(face_dot * boundary_transform)
        relative.append(abs(residual) / max(scale, 1e-13))
    rms = math.sqrt(math.fsum(x * x for x in relative) / len(relative))
    return rms, max(relative)


def _moments(rates: Sequence[Sequence[float]], weights: Sequence[float]) -> Tuple[List[float], List[float], List[float]]:
    rank, d = len(rates), len(rates[0])
    means = [math.fsum(weights[h] / rates[h][j] for h in range(rank)) for j in range(d)]
    seconds = [math.fsum(2.0 * weights[h] / (rates[h][j] ** 2) for h in range(rank)) for j in range(d)]
    variances = [max(0.0, seconds[j] - means[j] * means[j]) for j in range(d)]
    return means, seconds, variances


def _expanded_initial(previous: Sequence[float] | None, old_rank: int, rank: int, masses: Sequence[float]) -> List[float] | None:
    if previous is None or old_rank + 1 != rank:
        return None
    epsilon = min(1e-3, 0.1 / rank)
    out: List[float] = []
    for group, mass in enumerate(masses):
        old = previous[group * old_rank:(group + 1) * old_rank]
        out.extend(value * (1.0 - epsilon) for value in old)
        out.append(mass * epsilon)
    return out


def solve(model: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(model, dict):
        raise ModelError("input must be a JSON object")
    version = model.get("schema_version", SCHEMA_VERSION)
    if version != SCHEMA_VERSION:
        raise ModelError(f"unsupported schema_version {version!r}; expected {SCHEMA_VERSION}")
    drift_value = model.get("drift")
    if not isinstance(drift_value, list) or not drift_value:
        raise ModelError("drift must be a nonempty array")
    d = len(drift_value)
    if d > len(PRIMES):
        raise ModelError(f"dimension {d} exceeds the supported maximum {len(PRIMES)}")
    drift = _vector(drift_value, d, "drift")
    covariance = _matrix(model.get("covariance"), d, "covariance")
    reflection = _matrix(model.get("reflection"), d, "reflection")

    matrix_scale = max(1.0, max(abs(x) for row in covariance for x in row))
    symmetry_error = max(abs(covariance[i][j] - covariance[j][i]) for i in range(d) for j in range(d))
    if symmetry_error > 1e-10 * matrix_scale:
        raise ModelError("covariance must be symmetric")
    eigenvalues = _jacobi_eigenvalues(covariance)
    if min(eigenvalues) < -1e-10 * matrix_scale:
        raise ModelError("covariance must be positive semidefinite")
    for i in range(d):
        if covariance[i][i] <= 0.0:
            raise ModelError("every covariance diagonal must be positive")
        if reflection[i][i] <= 0.0:
            raise ModelError("every reflection diagonal must be positive")
        for j in range(d):
            if i != j and reflection[i][j] > 1e-12:
                raise ModelError("this solver requires a reflection M-matrix (nonpositive off-diagonals)")

    inverse = _inverse(reflection)
    inverse_scale = max(1.0, max(abs(x) for row in inverse for x in row))
    if min(x for row in inverse for x in row) < -1e-10 * inverse_scale:
        raise ModelError("reflection is not a nonsingular M-matrix (its inverse is not nonnegative)")
    boundary_masses = _solve(reflection, [-x for x in drift])
    if min(boundary_masses) <= 1e-12:
        raise ModelError("SRBM is outside the supported stable class: -R^{-1} drift must be strictly positive")

    options = model.get("options", {})
    if not isinstance(options, dict):
        raise ModelError("options must be an object")
    maximum_rank = int(options.get("max_rank", 12))
    training_count = int(options.get("training_points", max(64, 12 * d)))
    validation_count = int(options.get("validation_points", max(32, 6 * d)))
    maximum_iterations = int(options.get("max_iterations", 6000))
    bar_tolerance = _finite(options.get("bar_tolerance", 2e-5), "options.bar_tolerance")
    moment_tolerance = _finite(options.get("moment_tolerance", 2e-3), "options.moment_tolerance")
    log_span = _finite(options.get("log_rate_span", 1.6), "options.log_rate_span")
    if not 1 <= maximum_rank <= 32:
        raise ModelError("options.max_rank must be between 1 and 32")
    if training_count < max(8, 3 * d) or validation_count < max(6, 2 * d):
        raise ModelError("too few training or validation points for the dimension")
    if not 100 <= maximum_iterations <= 100_000:
        raise ModelError("options.max_iterations must be between 100 and 100000")
    if bar_tolerance <= 0.0 or moment_tolerance <= 0.0 or not 0.05 <= log_span <= 4.0:
        raise ModelError("tolerances must be positive and log_rate_span must lie in [0.05, 4]")

    base_rates = [
        2.0 * reflection[i][i] * boundary_masses[i] / covariance[i][i]
        for i in range(d)
    ]
    rates_pool = _candidate_rates(base_rates, maximum_rank, log_span)
    training_points = _collocation_points(base_rates, training_count, 101)
    validation_points = _collocation_points(base_rates, validation_count, 10007)
    skew_residual = _skew_symmetry_residual(reflection, covariance)
    numerical_product_form_candidate = skew_residual <= 2e-10
    exact_product_form = d == 1 or _exact_decimal_skew_symmetry(
        reflection, covariance
    )

    masses = [1.0] + boundary_masses
    previous_weights: List[float] | None = None
    previous_means: List[float] | None = None
    previous_rank = 0
    history: List[dict[str, Any]] = []
    converged = False
    final: dict[str, Any] | None = None
    stable_steps = 0

    for rank in range(1, maximum_rank + 1):
        rates = rates_pool[:rank]
        a = _bar_matrix(training_points, rates, drift, covariance, reflection, boundary_masses)
        initial = _expanded_initial(previous_weights, previous_rank, rank, masses)
        weights, iterations, objective, projected_change = _fit_weights(
            a, rank, masses, maximum_iterations, initial
        )
        train_rms, train_max = _unscaled_residuals(
            training_points, rates, weights, drift, covariance, reflection, boundary_masses
        )
        validation_rms, validation_max = _unscaled_residuals(
            validation_points, rates, weights, drift, covariance, reflection, boundary_masses
        )
        means, seconds, variances = _moments(rates, weights)
        mean_change = None if previous_means is None else max(
            abs(means[j] - previous_means[j]) / max(1e-12, abs(means[j]), abs(previous_means[j]))
            for j in range(d)
        )
        entry = {
            "rank": rank,
            "training_relative_bar_rms": train_rms,
            "validation_relative_bar_rms": validation_rms,
            "validation_relative_bar_max": validation_max,
            "relative_mean_change": mean_change,
            "optimizer_iterations": iterations,
        }
        history.append(entry)
        final = {
            "rank": rank,
            "rates": rates,
            "weights": weights[:rank],
            "boundary_weights": [
                weights[(i + 1) * rank:(i + 2) * rank] for i in range(d)
            ],
            "means": means,
            "second_moments": seconds,
            "variances": variances,
            "training_rms": train_rms,
            "training_max": train_max,
            "validation_rms": validation_rms,
            "validation_max": validation_max,
            "objective": objective,
            "projected_change": projected_change,
            "iterations": iterations,
            "mean_change": mean_change,
        }
        if exact_product_form and rank == 1 and validation_rms <= max(bar_tolerance, 2e-10):
            converged = True
            break
        if mean_change is not None and validation_rms <= bar_tolerance and mean_change <= moment_tolerance:
            stable_steps += 1
        else:
            stable_steps = 0
        if stable_steps >= 2:
            converged = True
            break
        previous_weights = weights
        previous_means = means
        previous_rank = rank

    assert final is not None
    group_errors = [abs(math.fsum(final["weights"]) - 1.0)]
    group_errors.extend(
        abs(math.fsum(final["boundary_weights"][i]) - boundary_masses[i]) for i in range(d)
    )
    claim = (
        "exact Harrison-Williams product-form stationary distribution"
        if exact_product_form and converged and final["rank"] == 1
        else "adaptive low-rank BAR approximation (not a certified moment bound)"
    )
    warnings: List[str] = []
    if not converged:
        warnings.append(
            "The requested refinement criteria were not met before max_rank; increase max_rank/log_rate_span or cross-check with another method."
        )
    if not exact_product_form:
        warnings.append(
            "Held-out BAR residuals test the fitted transform but do not bound error in the reported moments."
        )
    if numerical_product_form_candidate and not exact_product_form:
        warnings.append(
            "The skew-symmetry residual is numerically small, but the identity is not exact for the supplied decimal parameters; the result remains an approximation."
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "method": "adaptive_low_rank_bar",
        "model_layer": "stationary orthant SRBM diffusion",
        "claim": claim,
        "dimension": d,
        "converged": converged,
        "stationary_means": final["means"],
        "stationary_second_moments": final["second_moments"],
        "stationary_variances": final["variances"],
        "mixture": {
            "rank": final["rank"],
            "rates": final["rates"],
            "interior_weights": final["weights"],
            "boundary_weights": final["boundary_weights"],
        },
        "diagnostics": {
            "boundary_measure_masses": boundary_masses,
            "base_exponential_rates": base_rates,
            "covariance_eigenvalue_bounds": [min(eigenvalues), max(eigenvalues)],
            "covariance_symmetry_error": symmetry_error,
            "skew_symmetry_relative_residual": skew_residual,
            "exact_product_form_detected": exact_product_form,
            "numerical_product_form_candidate": numerical_product_form_candidate,
            "training_relative_bar_rms": final["training_rms"],
            "training_relative_bar_max": final["training_max"],
            "validation_relative_bar_rms": final["validation_rms"],
            "validation_relative_bar_max": final["validation_max"],
            "simplex_mass_error": max(group_errors),
            "optimizer_objective": final["objective"],
            "optimizer_projected_change": final["projected_change"],
            "optimizer_iterations": final["iterations"],
            "relative_mean_change": final["mean_change"],
            "refinement_history": history,
        },
        "warnings": warnings,
    }


def _human(result: dict[str, Any]) -> str:
    diagnostics = result["diagnostics"]
    lines = [
        "Adaptive low-rank BAR analysis",
        f"Model layer: {result['model_layer']}",
        f"Claim: {result['claim']}",
        f"Rank: {result['mixture']['rank']}  converged: {'yes' if result['converged'] else 'no'}",
        "",
    ]
    for i, (mean, variance) in enumerate(zip(result["stationary_means"], result["stationary_variances"]), 1):
        lines.append(f"E[Z_{i}] = {mean:.10g}    Var[Z_{i}] = {variance:.10g}")
    lines.extend([
        "",
        f"Held-out relative BAR RMS = {diagnostics['validation_relative_bar_rms']:.6g}",
        f"Held-out relative BAR max = {diagnostics['validation_relative_bar_max']:.6g}",
        f"Skew-symmetry residual    = {diagnostics['skew_symmetry_relative_residual']:.6g}",
        f"Simplex mass error        = {diagnostics['simplex_mass_error']:.3g}",
    ])
    for warning in result["warnings"]:
        lines.append(f"WARNING: {warning}")
    return "\n".join(lines) + "\n"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path, help="JSON SRBM model")
    parser.add_argument("--json", action="store_true", help="print versioned JSON instead of human output")
    parser.add_argument("--output", type=pathlib.Path, help="write output to this file")
    parser.add_argument("--require-tolerance", action="store_true", help="exit 3 if adaptive criteria are not met")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        with args.input.open("r", encoding="utf-8") as handle:
            model = json.load(handle)
        result = solve(model)
    except (OSError, json.JSONDecodeError, ModelError) as exc:
        print(f"low_rank_bar: {exc}", file=sys.stderr)
        return 2
    text = json.dumps(result, indent=2, sort_keys=True) + "\n" if args.json else _human(result)
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    if args.require_tolerance and not result["converged"]:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
