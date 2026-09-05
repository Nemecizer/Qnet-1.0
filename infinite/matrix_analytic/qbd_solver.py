#!/usr/bin/env python3
"""Stationary matrix-geometric solver for continuous-time QBD processes.

The implementation intentionally depends only on the Python standard library.
It is suitable for small and moderate phase blocks where dense matrix algebra
is preferable to introducing a NumPy/SciPy runtime dependency.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import quote


Matrix = list[list[float]]
Vector = list[float]


class QBDError(Exception):
    """Base class for errors that should be presented as structured output."""

    code = "qbd_error"

    def __init__(self, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.details = details or {}


class QBDInputError(QBDError):
    code = "invalid_input"


class QBDStabilityError(QBDError):
    code = "not_positive_recurrent"


class QBDConvergenceError(QBDError):
    code = "rate_matrix_not_converged"


class QBDNumericalError(QBDError):
    code = "numerical_validation_failed"


@dataclass(frozen=True)
class SolverOptions:
    absolute_tolerance: float = 1.0e-14
    relative_tolerance: float = 1.0e-12
    residual_tolerance: float = 1.0e-11
    generator_tolerance: float = 1.0e-11
    stability_tolerance: float = 1.0e-12
    max_iterations: int = 100_000
    max_report_level: int = 10
    tail_levels: tuple[int, ...] = (1, 5, 10)


@dataclass(frozen=True)
class QBDModel:
    b00: Matrix
    b01: Matrix
    b10: Matrix
    b11: Matrix
    a_down: Matrix
    a_same: Matrix
    a_up: Matrix
    options: SolverOptions
    name: str | None = None

    @property
    def boundary_phases(self) -> int:
        return len(self.b00)

    @property
    def interior_phases(self) -> int:
        return len(self.a_same)


def zeros(rows: int, columns: int) -> Matrix:
    return [[0.0 for _ in range(columns)] for _ in range(rows)]


def identity(size: int) -> Matrix:
    result = zeros(size, size)
    for i in range(size):
        result[i][i] = 1.0
    return result


def transpose(matrix: Matrix) -> Matrix:
    return [list(column) for column in zip(*matrix)]


def matrix_add(*matrices: Matrix) -> Matrix:
    rows = len(matrices[0])
    columns = len(matrices[0][0])
    return [
        [math.fsum(matrix[i][j] for matrix in matrices) for j in range(columns)]
        for i in range(rows)
    ]


def matrix_subtract(left: Matrix, right: Matrix) -> Matrix:
    return [
        [left[i][j] - right[i][j] for j in range(len(left[0]))]
        for i in range(len(left))
    ]


def matrix_scale(matrix: Matrix, scalar: float) -> Matrix:
    return [[scalar * value for value in row] for row in matrix]


def matrix_multiply(left: Matrix, right: Matrix) -> Matrix:
    rows = len(left)
    shared = len(right)
    columns = len(right[0])
    return [
        [
            math.fsum(left[i][k] * right[k][j] for k in range(shared))
            for j in range(columns)
        ]
        for i in range(rows)
    ]


def row_vector_multiply(vector: Vector, matrix: Matrix) -> Vector:
    return [
        math.fsum(vector[i] * matrix[i][j] for i in range(len(vector)))
        for j in range(len(matrix[0]))
    ]


def matrix_vector_multiply(matrix: Matrix, vector: Vector) -> Vector:
    return [
        math.fsum(entry * vector[j] for j, entry in enumerate(row))
        for row in matrix
    ]


def dot(left: Vector, right: Vector) -> float:
    return math.fsum(a * b for a, b in zip(left, right))


def max_abs_matrix(matrix: Matrix) -> float:
    return max((abs(value) for row in matrix for value in row), default=0.0)


def max_abs_vector(vector: Vector) -> float:
    return max((abs(value) for value in vector), default=0.0)


def matrix_infinity_norm(matrix: Matrix) -> float:
    return max((math.fsum(abs(value) for value in row) for row in matrix), default=0.0)


def matrix_power(matrix: Matrix, exponent: int) -> Matrix:
    """Raise a square matrix to a nonnegative integer power."""

    if exponent < 0:
        raise QBDInputError("matrix exponent must be nonnegative")
    result = identity(len(matrix))
    factor = [row[:] for row in matrix]
    remaining = exponent
    while remaining:
        if remaining & 1:
            result = matrix_multiply(result, factor)
        remaining >>= 1
        if remaining:
            factor = matrix_multiply(factor, factor)
    return result


def solve_linear(matrix: Matrix, rhs: Vector) -> Vector:
    """Solve a dense real system using scaled partial-pivot elimination."""

    size = len(matrix)
    if size == 0 or any(len(row) != size for row in matrix) or len(rhs) != size:
        raise QBDInputError("linear solve requires a nonempty square matrix")

    augmented = [list(matrix[i]) + [float(rhs[i])] for i in range(size)]
    row_scales = [max(abs(value) for value in row) for row in matrix]
    if any(scale == 0.0 for scale in row_scales):
        raise QBDInputError("singular matrix contains an all-zero equation")

    for column in range(size):
        pivot = max(
            range(column, size),
            key=lambda row: abs(augmented[row][column]) / row_scales[row],
        )
        pivot_floor = (
            8.0 * sys.float_info.epsilon * max(1, size) * row_scales[pivot]
        )
        if abs(augmented[pivot][column]) <= pivot_floor:
            raise QBDInputError(
                "singular or numerically rank-deficient matrix",
                {"pivot_column": column, "pivot_magnitude": abs(augmented[pivot][column])},
            )
        if pivot != column:
            augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
            row_scales[column], row_scales[pivot] = (
                row_scales[pivot],
                row_scales[column],
            )

        pivot_value = augmented[column][column]
        for row in range(column + 1, size):
            factor = augmented[row][column] / pivot_value
            if factor == 0.0:
                continue
            augmented[row][column] = 0.0
            for j in range(column + 1, size + 1):
                augmented[row][j] -= factor * augmented[column][j]

    solution = [0.0 for _ in range(size)]
    for row in range(size - 1, -1, -1):
        remainder = augmented[row][size] - math.fsum(
            augmented[row][j] * solution[j] for j in range(row + 1, size)
        )
        solution[row] = remainder / augmented[row][row]
    return solution


def inverse(matrix: Matrix) -> Matrix:
    size = len(matrix)
    columns: list[Vector] = []
    for column in range(size):
        rhs = [0.0 for _ in range(size)]
        rhs[column] = 1.0
        columns.append(solve_linear(matrix, rhs))
    return transpose(columns)


def solve_left_null(
    matrix: Matrix,
    normalization: Vector,
    nonnegative_tolerance: float | None = None,
) -> tuple[Vector, float]:
    """Find x with x M = 0 and x normalization = 1.

    Replacement of a redundant equation is attempted at every row. The
    candidate with the smallest balance residual is retained, which is more
    robust than assuming one particular balance equation is redundant.
    """

    size = len(matrix)
    if len(normalization) != size:
        raise QBDInputError("normalization vector has the wrong dimension")
    transposed = transpose(matrix)
    best: tuple[Vector, float] | None = None
    best_nonnegative: tuple[Vector, float] | None = None

    for replacement in range(size - 1, -1, -1):
        equations = [row[:] for row in transposed]
        equations[replacement] = normalization[:]
        rhs = [0.0 for _ in range(size)]
        rhs[replacement] = 1.0
        try:
            candidate = solve_linear(equations, rhs)
        except QBDInputError:
            continue
        residual = max_abs_vector(row_vector_multiply(candidate, matrix))
        if best is None or residual < best[1]:
            best = (candidate, residual)
        if (
            nonnegative_tolerance is not None
            and min(candidate) >= -nonnegative_tolerance
            and (best_nonnegative is None or residual < best_nonnegative[1])
        ):
            best_nonnegative = (candidate, residual)

    if best is None:
        raise QBDInputError(
            "balance equations do not have a unique normalizable solution; "
            "the QBD may be reducible"
        )
    return best_nonnegative or best


def _as_matrix(value: Any, path: str) -> Matrix:
    if not isinstance(value, list) or not value:
        raise QBDInputError(f"{path} must be a nonempty array of rows")
    if not all(isinstance(row, list) and row for row in value):
        raise QBDInputError(f"{path} must contain nonempty array rows")
    columns = len(value[0])
    if any(len(row) != columns for row in value):
        raise QBDInputError(f"{path} must be rectangular")

    matrix: Matrix = []
    for i, row in enumerate(value):
        converted: list[float] = []
        for j, entry in enumerate(row):
            if isinstance(entry, bool) or not isinstance(entry, (int, float)):
                raise QBDInputError(f"{path}[{i}][{j}] must be a finite number")
            try:
                number = float(entry)
            except (OverflowError, ValueError) as error:
                raise QBDInputError(
                    f"{path}[{i}][{j}] must be representable as a finite float"
                ) from error
            if not math.isfinite(number):
                raise QBDInputError(f"{path}[{i}][{j}] must be finite")
            converted.append(number)
        matrix.append(converted)
    return matrix


def _positive_float(mapping: dict[str, Any], key: str, default: float) -> float:
    value = mapping.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QBDInputError(f"solver.{key} must be a positive finite number")
    try:
        result = float(value)
    except (OverflowError, ValueError) as error:
        raise QBDInputError(
            f"solver.{key} must be representable as a positive finite float"
        ) from error
    if not math.isfinite(result) or result <= 0.0:
        raise QBDInputError(f"solver.{key} must be a positive finite number")
    return result


def _nonnegative_int(mapping: dict[str, Any], key: str, default: int) -> int:
    value = mapping.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise QBDInputError(f"solver.{key} must be a nonnegative integer")
    return value


def parse_model(document: dict[str, Any]) -> QBDModel:
    if not isinstance(document, dict):
        raise QBDInputError("the JSON root must be an object")
    if document.get("schema_version", 1) != 1:
        raise QBDInputError("only schema_version 1 is supported")
    if document.get("process", "continuous_time_qbd") != "continuous_time_qbd":
        raise QBDInputError("process must be 'continuous_time_qbd'")

    boundary = document.get("boundary")
    interior = document.get("interior")
    if not isinstance(boundary, dict) or not isinstance(interior, dict):
        raise QBDInputError("boundary and interior must be JSON objects")

    b00 = _as_matrix(boundary.get("level_0_same"), "boundary.level_0_same")
    b01 = _as_matrix(boundary.get("level_0_up"), "boundary.level_0_up")
    b10 = _as_matrix(boundary.get("level_1_down"), "boundary.level_1_down")
    b11 = _as_matrix(boundary.get("level_1_same"), "boundary.level_1_same")
    a_down = _as_matrix(interior.get("down"), "interior.down")
    a_same = _as_matrix(interior.get("same"), "interior.same")
    a_up = _as_matrix(interior.get("up"), "interior.up")

    options_document = document.get("solver", {})
    if not isinstance(options_document, dict):
        raise QBDInputError("solver must be a JSON object")

    max_iterations = _nonnegative_int(options_document, "max_iterations", 100_000)
    if max_iterations < 1:
        raise QBDInputError("solver.max_iterations must be at least 1")
    max_report_level = _nonnegative_int(options_document, "max_report_level", 10)

    tail_document = options_document.get("tail_levels", [1, 5, 10])
    if not isinstance(tail_document, list):
        raise QBDInputError("solver.tail_levels must be an array of nonnegative integers")
    tail_levels: list[int] = []
    for index, level in enumerate(tail_document):
        if isinstance(level, bool) or not isinstance(level, int) or level < 0:
            raise QBDInputError(
                f"solver.tail_levels[{index}] must be a nonnegative integer"
            )
        tail_levels.append(level)

    options = SolverOptions(
        absolute_tolerance=_positive_float(
            options_document, "absolute_tolerance", 1.0e-14
        ),
        relative_tolerance=_positive_float(
            options_document, "relative_tolerance", 1.0e-12
        ),
        residual_tolerance=_positive_float(
            options_document, "residual_tolerance", 1.0e-11
        ),
        generator_tolerance=_positive_float(
            options_document, "generator_tolerance", 1.0e-11
        ),
        stability_tolerance=_positive_float(
            options_document, "stability_tolerance", 1.0e-12
        ),
        max_iterations=max_iterations,
        max_report_level=max_report_level,
        tail_levels=tuple(sorted(set(tail_levels))),
    )
    name = document.get("name")
    if name is not None and not isinstance(name, str):
        raise QBDInputError("name must be a string when present")

    model = QBDModel(
        b00=b00,
        b01=b01,
        b10=b10,
        b11=b11,
        a_down=a_down,
        a_same=a_same,
        a_up=a_up,
        options=options,
        name=name,
    )
    validate_model(model)
    return model


def _check_shape(matrix: Matrix, rows: int, columns: int, name: str) -> None:
    actual = (len(matrix), len(matrix[0]))
    if actual != (rows, columns):
        raise QBDInputError(
            f"{name} has shape {actual[0]}x{actual[1]}; expected {rows}x{columns}"
        )


def _check_transition_block(matrix: Matrix, name: str, tolerance: float) -> None:
    for i, row in enumerate(matrix):
        for j, value in enumerate(row):
            if value < -tolerance:
                raise QBDInputError(f"{name}[{i}][{j}] must be nonnegative")


def _check_same_level_block(matrix: Matrix, name: str, tolerance: float) -> None:
    for i, row in enumerate(matrix):
        for j, value in enumerate(row):
            if i == j:
                if value >= 0.0:
                    raise QBDInputError(f"{name}[{i}][{j}] must be negative")
            elif value < -tolerance:
                raise QBDInputError(f"{name}[{i}][{j}] must be nonnegative")


def _check_row_sums(blocks: Sequence[Matrix], name: str, tolerance: float) -> None:
    rows = len(blocks[0])
    scale = max(
        sys.float_info.min,
        *(matrix_infinity_norm(block) for block in blocks),
    )
    for i in range(rows):
        total = math.fsum(math.fsum(block[i]) for block in blocks)
        if abs(total) > tolerance * scale:
            raise QBDInputError(
                f"{name} generator row {i} sums to {total:.17g}, not zero",
                {"row": i, "row_sum": total, "allowed_absolute_error": tolerance * scale},
            )


def _adjacency_is_strongly_connected(adjacency: list[list[int]]) -> bool:
    size = len(adjacency)
    if size <= 1:
        return True
    reverse = [[] for _ in range(size)]
    for i, targets in enumerate(adjacency):
        for j in targets:
            reverse[j].append(i)

    def visit(graph: list[list[int]]) -> set[int]:
        seen = {0}
        stack = [0]
        while stack:
            state = stack.pop()
            for target in graph[state]:
                if target not in seen:
                    seen.add(target)
                    stack.append(target)
        return seen

    return len(visit(adjacency)) == size and len(visit(reverse)) == size


def _strongly_connected(generator: Matrix) -> bool:
    adjacency = [
        [j for j, rate in enumerate(generator[i]) if i != j and rate > 0.0]
        for i in range(len(generator))
    ]
    return _adjacency_is_strongly_connected(adjacency)


def _boundary_interior_graph_is_strongly_connected(model: QBDModel) -> bool:
    """Check a necessary finite structural condition for QBD irreducibility."""

    m0 = model.boundary_phases
    m = model.interior_phases
    adjacency: list[set[int]] = [set() for _ in range(m0 + m)]

    for i in range(m0):
        for j, value in enumerate(model.b00[i]):
            if i != j and value > 0.0:
                adjacency[i].add(j)
        for j, value in enumerate(model.b01[i]):
            if value > 0.0:
                adjacency[i].add(m0 + j)

    for i in range(m):
        source = m0 + i
        for j, value in enumerate(model.b10[i]):
            if value > 0.0:
                adjacency[source].add(j)
        for block in (model.b11, model.a_down, model.a_same, model.a_up):
            for j, value in enumerate(block[i]):
                if i != j and value > 0.0:
                    adjacency[source].add(m0 + j)

    return _adjacency_is_strongly_connected(
        [sorted(targets) for targets in adjacency]
    )


def validate_model(model: QBDModel) -> None:
    m0 = model.boundary_phases
    m = model.interior_phases
    tolerance = model.options.generator_tolerance

    _check_shape(model.b00, m0, m0, "boundary.level_0_same")
    _check_shape(model.b01, m0, m, "boundary.level_0_up")
    _check_shape(model.b10, m, m0, "boundary.level_1_down")
    _check_shape(model.b11, m, m, "boundary.level_1_same")
    for matrix, name in (
        (model.a_down, "interior.down"),
        (model.a_same, "interior.same"),
        (model.a_up, "interior.up"),
    ):
        _check_shape(matrix, m, m, name)

    for matrix, name in (
        (model.b01, "boundary.level_0_up"),
        (model.b10, "boundary.level_1_down"),
        (model.a_down, "interior.down"),
        (model.a_up, "interior.up"),
    ):
        _check_transition_block(matrix, name, tolerance)
    _check_same_level_block(model.b00, "boundary.level_0_same", tolerance)
    _check_same_level_block(model.b11, "boundary.level_1_same", tolerance)
    _check_same_level_block(model.a_same, "interior.same", tolerance)

    _check_row_sums((model.b00, model.b01), "level 0", tolerance)
    _check_row_sums((model.b10, model.b11, model.a_up), "level 1", tolerance)
    _check_row_sums(
        (model.a_down, model.a_same, model.a_up), "interior", tolerance
    )

    phase_generator = matrix_add(model.a_down, model.a_same, model.a_up)
    if not _strongly_connected(phase_generator):
        raise QBDInputError(
            "the interior phase generator is reducible; schema version 1 "
            "requires one irreducible phase class"
        )
    if not _boundary_interior_graph_is_strongly_connected(model):
        raise QBDInputError(
            "the boundary/interior phase graph is reducible; schema version 1 "
            "requires one communicating structure and does not choose among "
            "multiple stationary classes"
        )


def stability_diagnostics(model: QBDModel) -> dict[str, Any]:
    ones = [1.0 for _ in range(model.interior_phases)]
    phase_generator = matrix_add(model.a_down, model.a_same, model.a_up)
    negativity_tolerance = 100.0 * model.options.generator_tolerance
    phase_vector, _ = solve_left_null(
        phase_generator, ones, nonnegative_tolerance=negativity_tolerance
    )
    negativity = min(phase_vector)
    if negativity < -negativity_tolerance:
        raise QBDInputError("interior phase stationary vector is not nonnegative")
    phase_vector = [max(0.0, value) for value in phase_vector]
    phase_total = math.fsum(phase_vector)
    if not math.isfinite(phase_total) or phase_total <= 0.0:
        raise QBDInputError("interior phase stationary vector cannot be normalized")
    phase_vector = [value / phase_total for value in phase_vector]
    phase_residual = max_abs_vector(
        row_vector_multiply(phase_vector, phase_generator)
    )
    phase_scale = max(sys.float_info.min, matrix_infinity_norm(phase_generator))

    upward = dot(row_vector_multiply(phase_vector, model.a_up), ones)
    downward = dot(row_vector_multiply(phase_vector, model.a_down), ones)
    drift = upward - downward
    drift_scale = max(upward + downward, sys.float_info.min)
    tolerance = model.options.stability_tolerance * drift_scale
    if drift < -tolerance:
        classification = "positive_recurrent"
    elif drift > tolerance:
        classification = "transient"
    else:
        classification = "null_recurrent_or_critical"

    return {
        "classification": classification,
        "phase_stationary_vector": phase_vector,
        "phase_balance_residual_inf": phase_residual,
        "phase_balance_residual_scaled": phase_residual / phase_scale,
        "mean_upward_rate": upward,
        "mean_downward_rate": downward,
        "net_level_drift": drift,
        "decision_tolerance": tolerance,
    }


def rate_equation_residuals(model: QBDModel, rate: Matrix) -> tuple[float, float]:
    rate_squared = matrix_multiply(rate, rate)
    equation = matrix_add(
        model.a_up,
        matrix_multiply(rate, model.a_same),
        matrix_multiply(rate_squared, model.a_down),
    )
    residual = matrix_infinity_norm(equation)
    scale = max(
        sys.float_info.min,
        matrix_infinity_norm(model.a_up),
        matrix_infinity_norm(model.a_same),
        matrix_infinity_norm(model.a_down),
    )
    return residual, residual / scale


def compute_rate_matrix(model: QBDModel) -> tuple[Matrix, dict[str, Any]]:
    """Compute the minimal nonnegative R by monotone uniformized iteration."""

    size = model.interior_phases
    uniformization_rate = max(-model.a_same[i][i] for i in range(size))
    if not math.isfinite(uniformization_rate) or uniformization_rate <= 0.0:
        raise QBDInputError("interior.same does not define positive holding rates")

    p_up = [
        [max(0.0, value / uniformization_rate) for value in row]
        for row in model.a_up
    ]
    p_down = [
        [max(0.0, value / uniformization_rate) for value in row]
        for row in model.a_down
    ]
    p_same = matrix_add(
        identity(size), matrix_scale(model.a_same, 1.0 / uniformization_rate)
    )
    if min(value for row in p_same for value in row) < -model.options.generator_tolerance:
        raise QBDInputError("uniformized same-level block contains a negative probability")
    p_same = [[max(0.0, value) for value in row] for row in p_same]

    rate = zeros(size, size)
    delta = math.inf
    raw_residual, residual = rate_equation_residuals(model, rate)
    iterations = 0
    for iterations in range(1, model.options.max_iterations + 1):
        rate_squared = matrix_multiply(rate, rate)
        candidate = matrix_add(
            p_up,
            matrix_multiply(rate, p_same),
            matrix_multiply(rate_squared, p_down),
        )
        if not all(math.isfinite(value) for row in candidate for value in row):
            raise QBDConvergenceError(
                "rate-matrix iteration produced a nonfinite value",
                {"iterations": iterations, "uniformization_rate": uniformization_rate},
            )

        monotonicity_floor = -100.0 * model.options.absolute_tolerance
        minimum_increment = min(
            candidate[i][j] - rate[i][j]
            for i in range(size)
            for j in range(size)
        )
        if minimum_increment < monotonicity_floor:
            raise QBDConvergenceError(
                "minimal-rate iteration lost componentwise monotonicity",
                {"iterations": iterations, "minimum_increment": minimum_increment},
            )
        candidate = [
            [max(rate[i][j], candidate[i][j], 0.0) for j in range(size)]
            for i in range(size)
        ]
        delta = max_abs_matrix(matrix_subtract(candidate, rate))
        rate = candidate
        raw_residual, residual = rate_equation_residuals(model, rate)
        threshold = (
            model.options.absolute_tolerance
            + model.options.relative_tolerance * max(1.0, max_abs_matrix(rate))
        )
        if delta <= threshold and residual <= model.options.residual_tolerance:
            break
        if delta == 0.0:
            raise QBDConvergenceError(
                "rate-matrix iteration stagnated before satisfying the residual tolerance",
                {
                    "iterations": iterations,
                    "last_iteration_delta": delta,
                    "rate_equation_residual_inf": raw_residual,
                    "rate_equation_residual_scaled": residual,
                    "uniformization_rate": uniformization_rate,
                    "partial_rate_matrix": rate,
                },
            )
    else:
        raise QBDConvergenceError(
            "minimal nonnegative rate-matrix iteration reached max_iterations",
            {
                "iterations": model.options.max_iterations,
                "last_iteration_delta": delta,
                "rate_equation_residual_inf": raw_residual,
                "rate_equation_residual_scaled": residual,
                "uniformization_rate": uniformization_rate,
                "partial_rate_matrix": rate,
            },
        )

    return rate, {
        "algorithm": "monotone_uniformized_functional_iteration",
        "iterations": iterations,
        "converged": True,
        "last_iteration_delta": delta,
        "rate_equation_residual_inf": raw_residual,
        "rate_equation_residual_scaled": residual,
        "uniformization_rate": uniformization_rate,
    }


def perron_bounds(matrix: Matrix) -> tuple[float, float, int]:
    """Return Collatz-Wielandt bounds for the Perron root."""

    size = len(matrix)
    if max_abs_matrix(matrix) == 0.0:
        return 0.0, 0.0, 0
    vector = [1.0 for _ in range(size)]
    lower = 0.0
    upper = max(sum(row) for row in matrix)
    for iteration in range(1, 10_001):
        product = matrix_vector_multiply(matrix, vector)
        ratios = [
            product[i] / vector[i]
            for i in range(size)
            if vector[i] > 1.0e-300
        ]
        if ratios:
            lower = min(ratios)
            upper = max(ratios)
        scale = max(product)
        if scale <= 0.0:
            return 0.0, 0.0, iteration
        vector = [max(value / scale, 1.0e-300) for value in product]
        if upper - lower <= 1.0e-13 * max(1.0, upper):
            return lower, upper, iteration
    return lower, upper, 10_000


def _assemble_boundary_kernel(model: QBDModel, rate: Matrix) -> Matrix:
    lower_right = matrix_add(model.b11, matrix_multiply(rate, model.a_down))
    kernel: Matrix = []
    for i in range(model.boundary_phases):
        kernel.append(model.b00[i] + model.b01[i])
    for i in range(model.interior_phases):
        kernel.append(model.b10[i] + lower_right[i])
    return kernel


def _rounded_nonnegative(value: float, tolerance: float) -> float:
    if value < 0.0 and value >= -tolerance:
        return 0.0
    return value


def solve(model: QBDModel) -> dict[str, Any]:
    stability = stability_diagnostics(model)
    if stability["classification"] != "positive_recurrent":
        raise QBDStabilityError(
            "a stationary probability distribution does not exist under the "
            "strict QBD drift criterion",
            {"stability": stability},
        )

    rate, iteration_diagnostics = compute_rate_matrix(model)
    size = model.interior_phases
    one = [1.0 for _ in range(size)]
    identity_minus_rate = matrix_subtract(identity(size), rate)
    try:
        fundamental = inverse(identity_minus_rate)
    except QBDInputError as error:
        raise QBDNumericalError(
            "I - R is singular or numerically rank deficient",
            {"cause": str(error)},
        ) from error
    negativity_tolerance = 100.0 * model.options.generator_tolerance
    minimum_fundamental_entry = min(value for row in fundamental for value in row)
    if minimum_fundamental_entry < -negativity_tolerance:
        raise QBDNumericalError(
            "(I - R)^-1 contains a materially negative entry",
            {"minimum_fundamental_entry": minimum_fundamental_entry},
        )
    fundamental = [
        [_rounded_nonnegative(value, negativity_tolerance) for value in row]
        for row in fundamental
    ]
    interior_mass_weights = matrix_vector_multiply(fundamental, one)
    if min(interior_mass_weights) <= 0.0:
        raise QBDNumericalError("(I - R)^-1 1 is not strictly positive")

    rate_times_mass_weights = matrix_vector_multiply(rate, interior_mass_weights)
    contraction_ratios = [
        rate_times_mass_weights[i] / interior_mass_weights[i]
        for i in range(size)
    ]
    contraction_upper_bound = max(contraction_ratios)
    if contraction_upper_bound >= 1.0:
        raise QBDNumericalError(
            "the computed rate matrix does not have a strict spectral-radius certificate",
            {"spectral_radius_certificate_upper_bound": contraction_upper_bound},
        )
    fundamental_norm = matrix_infinity_norm(fundamental)
    condition_estimate = matrix_infinity_norm(identity_minus_rate) * fundamental_norm

    normalization = [1.0 for _ in range(model.boundary_phases)] + interior_mass_weights
    boundary_kernel = _assemble_boundary_kernel(model, rate)
    boundary_solution, _ = solve_left_null(
        boundary_kernel,
        normalization,
        nonnegative_tolerance=negativity_tolerance,
    )
    pi0 = boundary_solution[: model.boundary_phases]
    pi1 = boundary_solution[model.boundary_phases :]

    minimum_probability = min(boundary_solution)
    if minimum_probability < -negativity_tolerance:
        raise QBDInputError(
            "stationary boundary solution contains a negative probability; "
            "the QBD may be reducible or ill-conditioned",
            {"minimum_probability": minimum_probability},
        )
    pi0 = [_rounded_nonnegative(value, negativity_tolerance) for value in pi0]
    pi1 = [_rounded_nonnegative(value, negativity_tolerance) for value in pi1]

    total_mass = math.fsum((math.fsum(pi0), dot(pi1, interior_mass_weights)))
    if not math.isfinite(total_mass) or total_mass <= 0.0:
        raise QBDInputError("stationary normalization is not positive and finite")
    pi0 = [value / total_mass for value in pi0]
    pi1 = [value / total_mass for value in pi1]
    normalization_residual = abs(
        math.fsum((math.fsum(pi0), dot(pi1, interior_mass_weights))) - 1.0
    )

    fundamental_squared = matrix_multiply(fundamental, fundamental)
    fundamental_cubed = matrix_multiply(fundamental_squared, fundamental)
    mean_level = dot(row_vector_multiply(pi1, fundamental_squared), one)
    factorial_second_operator = matrix_scale(
        matrix_multiply(rate, fundamental_cubed), 2.0
    )
    factorial_second = dot(
        row_vector_multiply(pi1, factorial_second_operator), one
    )
    second_moment = mean_level + factorial_second
    raw_variance = second_moment - mean_level * mean_level
    variance_scale = max(1.0, abs(second_moment), mean_level * mean_level)
    variance_roundoff_tolerance = max(
        100.0 * sys.float_info.epsilon * max(1.0, condition_estimate) * variance_scale,
        10.0 * model.options.residual_tolerance * variance_scale,
    )
    if raw_variance < -variance_roundoff_tolerance:
        raise QBDNumericalError(
            "computed queue-length variance is materially negative",
            {
                "raw_variance": raw_variance,
                "roundoff_tolerance": variance_roundoff_tolerance,
            },
        )
    variance = max(0.0, raw_variance)

    total_phase_mass = row_vector_multiply(pi1, fundamental)
    mean_level_by_phase = row_vector_multiply(pi1, fundamental_squared)

    report_limit = model.options.max_report_level
    level_probabilities: list[dict[str, Any]] = [
        {"level": 0, "probability": math.fsum(pi0), "phase_vector": pi0}
    ]
    current = pi1[:]
    for level in range(1, report_limit + 1):
        level_probabilities.append(
            {
                "level": level,
                "probability": max(0.0, math.fsum(current)),
                "phase_vector": current,
            }
        )
        current = row_vector_multiply(current, rate)

    tail_levels = sorted(set(model.options.tail_levels))
    tails: list[dict[str, Any]] = []
    tail_vector = pi1[:]
    current_level = 1
    for requested in tail_levels:
        if requested == 0:
            tails.append({"level_at_least": 0, "probability": 1.0})
            continue
        if current_level < requested:
            tail_vector = row_vector_multiply(
                tail_vector, matrix_power(rate, requested - current_level)
            )
            current_level = requested
        probability = dot(tail_vector, interior_mass_weights)
        tails.append(
            {"level_at_least": requested, "probability": max(0.0, probability)}
        )

    lower_radius, upper_radius, radius_iterations = perron_bounds(rate)
    full_boundary = pi0 + pi1
    boundary_residual = max_abs_vector(
        row_vector_multiply(full_boundary, boundary_kernel)
    )
    normalized_boundary_residual = boundary_residual / max(
        sys.float_info.min, matrix_infinity_norm(boundary_kernel)
    )

    pi2 = row_vector_multiply(pi1, rate)
    pi3 = row_vector_multiply(pi2, rate)
    level_0_balance = matrix_add(
        [row_vector_multiply(pi0, model.b00)],
        [row_vector_multiply(pi1, model.b10)],
    )[0]
    level_1_balance = matrix_add(
        [row_vector_multiply(pi0, model.b01)],
        [row_vector_multiply(pi1, model.b11)],
        [row_vector_multiply(pi2, model.a_down)],
    )[0]
    interior_level_balance = matrix_add(
        [row_vector_multiply(pi1, model.a_up)],
        [row_vector_multiply(pi2, model.a_same)],
        [row_vector_multiply(pi3, model.a_down)],
    )[0]
    generator_scale = max(
        sys.float_info.min,
        matrix_infinity_norm(model.b00),
        matrix_infinity_norm(model.b01),
        matrix_infinity_norm(model.b10),
        matrix_infinity_norm(model.b11),
        matrix_infinity_norm(model.a_down),
        matrix_infinity_norm(model.a_same),
        matrix_infinity_norm(model.a_up),
    )
    level_0_residual = max_abs_vector(level_0_balance) / generator_scale
    level_1_residual = max_abs_vector(level_1_balance) / generator_scale
    interior_level_residual = (
        max_abs_vector(interior_level_balance) / generator_scale
    )
    tail_one = dot(pi1, interior_mass_weights)
    tail_two = dot(pi2, interior_mass_weights)
    tail_identity_residual = abs(tail_one - tail_two - math.fsum(pi1))

    result: dict[str, Any] = {
        "status": "ok",
        "process": "continuous_time_qbd",
        "dimensions": {
            "boundary_phases": model.boundary_phases,
            "interior_phases": model.interior_phases,
        },
        "stability": stability,
        "rate_matrix": rate,
        "stationary": {
            "level_0_vector": pi0,
            "level_1_vector": pi1,
            "total_interior_phase_mass": total_phase_mass,
            "mean_level_by_phase": mean_level_by_phase,
        },
        "queue_length": {
            "mean": mean_level,
            "second_moment": second_moment,
            "variance": variance,
            "standard_deviation": math.sqrt(variance),
        },
        "tail_probabilities": tails,
        "level_probabilities": level_probabilities,
        "diagnostics": {
            **iteration_diagnostics,
            "boundary_balance_residual_inf": boundary_residual,
            "boundary_balance_residual_scaled": normalized_boundary_residual,
            "level_0_balance_residual_scaled": level_0_residual,
            "level_1_balance_residual_scaled": level_1_residual,
            "interior_level_2_balance_residual_scaled": interior_level_residual,
            "normalization_residual": normalization_residual,
            "tail_identity_residual": tail_identity_residual,
            "minimum_boundary_probability": minimum_probability,
            "minimum_rate_matrix_entry": min(
                value for row in rate for value in row
            ),
            "minimum_fundamental_matrix_entry": minimum_fundamental_entry,
            "rate_spectral_radius_lower_bound": lower_radius,
            "rate_spectral_radius_upper_bound": upper_radius,
            "rate_spectral_radius_certificate_upper_bound": contraction_upper_bound,
            "rate_spectral_radius_certificate_margin": 1.0
            - contraction_upper_bound,
            "spectral_radius_iterations": radius_iterations,
            "fundamental_matrix_inf_norm": fundamental_norm,
            "identity_minus_rate_condition_inf_estimate": condition_estimate,
            "raw_variance": raw_variance,
            "variance_roundoff_tolerance": variance_roundoff_tolerance,
        },
    }
    if model.name:
        result["name"] = model.name
    return result


def solve_document(document: dict[str, Any]) -> dict[str, Any]:
    return solve(parse_model(document))


def load_document(path: str) -> dict[str, Any]:
    if path == "-":
        try:
            document = json.load(sys.stdin)
        except (json.JSONDecodeError, OSError) as error:
            raise QBDInputError(f"could not read JSON from stdin: {error}") from error
    else:
        try:
            with Path(path).open("r", encoding="utf-8") as handle:
                document = json.load(handle)
        except (json.JSONDecodeError, OSError) as error:
            raise QBDInputError(f"could not read {path}: {error}") from error
    if not isinstance(document, dict):
        raise QBDInputError("the JSON root must be an object")
    return document


def _write_json(payload: dict[str, Any], destination: str | None, pretty: bool) -> None:
    text = json.dumps(
        payload,
        indent=2 if pretty else None,
        sort_keys=True,
        allow_nan=False,
    )
    if destination:
        try:
            Path(destination).write_text(text + "\n", encoding="utf-8")
        except OSError as error:
            raise QBDInputError(f"could not write {destination}: {error}") from error
    else:
        print(text)


def _human_number(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QBDNumericalError("human output expected a numeric value")
    result = float(value)
    if not math.isfinite(result):
        raise QBDNumericalError("human output cannot represent a non-finite value")
    return format(result, ".17g")


def _human_token(value: Any) -> str:
    """Percent-encode text so every human record remains one parseable line."""

    return quote(str(value), safe="-._~")


def format_human(payload: dict[str, Any]) -> str:
    """Return the stable line grammar consumed by Qnet's result workspace."""

    queue_length = payload["queue_length"]
    stationary = payload["stationary"]
    stability = payload["stability"]
    diagnostics = payload["diagnostics"]
    lines = [
        "QNET_QBD_EVIDENCE_V1 key=status value=ok",
        "QNET_QBD_METRIC_V1 metric=mean_level estimate={}"
        .format(_human_number(queue_length["mean"])),
        "QNET_QBD_METRIC_V1 metric=second_moment_level estimate={}"
        .format(_human_number(queue_length["second_moment"])),
        "QNET_QBD_METRIC_V1 metric=variance_level estimate={}"
        .format(_human_number(queue_length["variance"])),
        "QNET_QBD_METRIC_V1 metric=standard_deviation_level estimate={}"
        .format(_human_number(queue_length["standard_deviation"])),
        "QNET_QBD_METRIC_V1 metric=probability_empty estimate={}"
        .format(_human_number(math.fsum(stationary["level_0_vector"]))),
    ]
    for tail in payload["tail_probabilities"]:
        lines.append(
            "QNET_QBD_METRIC_V1 metric=tail_probability level={} estimate={}"
            .format(
                int(tail["level_at_least"]),
                _human_number(tail["probability"]),
            )
        )
    evidence = (
        ("process", payload["process"]),
        ("name", payload.get("name", "unnamed")),
        ("stability_classification", stability["classification"]),
        ("mean_upward_rate", _human_number(stability["mean_upward_rate"])),
        ("mean_downward_rate", _human_number(stability["mean_downward_rate"])),
        ("net_level_drift", _human_number(stability["net_level_drift"])),
        ("algorithm", diagnostics["algorithm"]),
        ("iterations", str(int(diagnostics["iterations"]))),
        (
            "rate_equation_residual_inf",
            _human_number(diagnostics["rate_equation_residual_inf"]),
        ),
        (
            "boundary_balance_residual_scaled",
            _human_number(diagnostics["boundary_balance_residual_scaled"]),
        ),
        (
            "normalization_residual",
            _human_number(diagnostics["normalization_residual"]),
        ),
        (
            "spectral_radius_certificate_upper_bound",
            _human_number(
                diagnostics["rate_spectral_radius_certificate_upper_bound"]
            ),
        ),
        (
            "identity_minus_rate_condition_inf_estimate",
            _human_number(
                diagnostics["identity_minus_rate_condition_inf_estimate"]
            ),
        ),
    )
    lines.extend(
        "QNET_QBD_EVIDENCE_V1 key={} value={}".format(
            _human_token(key), _human_token(value)
        )
        for key, value in evidence
    )
    return "\n".join(lines) + "\n"


def _write_human(payload: dict[str, Any], destination: str | None) -> None:
    text = format_human(payload)
    if destination:
        try:
            Path(destination).write_text(text, encoding="utf-8")
        except OSError as error:
            raise QBDInputError(f"could not write {destination}: {error}") from error
    else:
        sys.stdout.write(text)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Solve the stationary distribution of a level-independent continuous-time QBD."
    )
    parser.add_argument("input", help="input JSON file, or '-' for stdin")
    parser.add_argument("-o", "--output", help="write JSON result to this file")
    output_format = parser.add_mutually_exclusive_group()
    output_format.add_argument(
        "--compact", action="store_true", help="emit compact JSON instead of indented JSON"
    )
    output_format.add_argument(
        "--human",
        action="store_true",
        help="emit stable QNET_QBD_METRIC_V1 and QNET_QBD_EVIDENCE_V1 records",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    try:
        payload = solve_document(load_document(args.input))
        if args.human:
            _write_human(payload, args.output)
        else:
            _write_json(payload, args.output, pretty=not args.compact)
        return 0
    except QBDError as error:
        payload = {
            "status": "error",
            "error": {"code": error.code, "message": str(error), **error.details},
        }
        try:
            if args.human:
                message = _human_token(error)
                text = "QNET_QBD_ERROR_V1 code={} message={}\n".format(
                    _human_token(error.code), message
                )
                if args.output:
                    Path(args.output).write_text(text, encoding="utf-8")
                else:
                    sys.stdout.write(text)
            else:
                _write_json(payload, args.output, pretty=not args.compact)
        except (QBDError, OSError):
            print(json.dumps(payload, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
