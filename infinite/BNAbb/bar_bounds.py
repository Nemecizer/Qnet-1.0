#!/usr/bin/env python3
"""Validated BAR moment relaxations for orthant SRBMs.

The module is deliberately dependency free.  It constructs a transparent
semidefinite moment relaxation and delegates numerical solution, when wanted,
to the optional :mod:`cvxpy_backend` module.
"""

from __future__ import annotations

import itertools
import json
import math
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


OUTPUT_SCHEMA_VERSION = 1
INPUT_SCHEMA_VERSION = 1
IR_SCHEMA_VERSION = 1
MODEL_TYPE = "orthant_srbm_bar_bounds"
SYMMETRY_TOLERANCE = 1.0e-12
POSITIVE_TOLERANCE = 1.0e-12
DEFAULT_MAX_VARIABLES = 100_000
DEFAULT_MAX_PSD_ENTRIES = 5_000_000

MultiIndex = Tuple[int, ...]


class InputError(ValueError):
    """Raised when the requested stochastic model is outside the safe scope."""


@dataclass(frozen=True)
class Target:
    name: str
    moment: MultiIndex


@dataclass(frozen=True)
class Model:
    name: str
    dimension: int
    drift: Tuple[float, ...]
    covariance: Tuple[Tuple[float, ...], ...]
    reflection: Tuple[Tuple[float, ...], ...]
    inverse_reflection: Tuple[Tuple[float, ...], ...]
    boundary_masses: Tuple[float, ...]
    order: int
    max_variables: int
    max_psd_entries: int
    targets: Tuple[Target, ...]
    validation: Mapping[str, Any]


def _fail(message: str) -> None:
    raise InputError(message)


def _require_object(value: Any, where: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(f"{where} must be a JSON object")
    return value


def _check_keys(obj: Mapping[str, Any], allowed: Iterable[str], where: str) -> None:
    unknown = sorted(set(obj) - set(allowed))
    if unknown:
        _fail(f"unknown field(s) in {where}: {', '.join(unknown)}")


def _finite_number(value: Any, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(f"{where} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        _fail(f"{where} must be finite")
    return result


def _positive_integer(value: Any, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        _fail(f"{where} must be a positive integer")
    return value


def _parse_vector(value: Any, where: str) -> Tuple[float, ...]:
    if not isinstance(value, list) or not value:
        _fail(f"{where} must be a nonempty array")
    return tuple(_finite_number(item, f"{where}[{i}]") for i, item in enumerate(value))


def _parse_matrix(value: Any, dimension: int, where: str) -> Tuple[Tuple[float, ...], ...]:
    if not isinstance(value, list) or len(value) != dimension:
        _fail(f"{where} must have exactly {dimension} rows")
    rows: List[Tuple[float, ...]] = []
    for i, row in enumerate(value):
        if not isinstance(row, list) or len(row) != dimension:
            _fail(f"{where}[{i}] must have exactly {dimension} entries")
        rows.append(tuple(_finite_number(item, f"{where}[{i}][{j}]") for j, item in enumerate(row)))
    return tuple(rows)


def _matrix_scale(matrix: Sequence[Sequence[float]]) -> float:
    return max(1.0, max(abs(value) for row in matrix for value in row))


def _raw_matrix_scale(matrix: Sequence[Sequence[float]]) -> float:
    return max(abs(value) for row in matrix for value in row)


def _symmetrize_and_validate(
    matrix: Sequence[Sequence[float]],
) -> Tuple[Tuple[Tuple[float, ...], ...], float]:
    d = len(matrix)
    maximum = 0.0
    for i in range(d):
        for j in range(d):
            maximum = max(maximum, abs(matrix[i][j] - matrix[j][i]))
    if maximum != 0.0:
        _fail(
            "covariance must be exactly symmetric in the reported decimal parameters; "
            f"maximum asymmetry is {maximum:.6g}"
        )
    return tuple(tuple(row) for row in matrix), maximum


def _cholesky_min_pivot(matrix: Sequence[Sequence[float]]) -> float:
    """Validate strict positive definiteness and return the smallest pivot."""
    d = len(matrix)
    lower = [[0.0] * d for _ in range(d)]
    scale = _raw_matrix_scale(matrix)
    threshold = POSITIVE_TOLERANCE * scale
    minimum = math.inf
    for i in range(d):
        for j in range(i + 1):
            value = matrix[i][j] - sum(lower[i][k] * lower[j][k] for k in range(j))
            if i == j:
                if not math.isfinite(value) or value <= threshold:
                    _fail(
                        "covariance must be strictly positive definite; "
                        f"Cholesky pivot {i} is {value:.6g}"
                    )
                lower[i][j] = math.sqrt(value)
                minimum = min(minimum, value)
            else:
                lower[i][j] = value / lower[j][j]
    return minimum


def _matvec(matrix: Sequence[Sequence[float]], vector: Sequence[float]) -> Tuple[float, ...]:
    return tuple(sum(a * b for a, b in zip(row, vector)) for row in matrix)


def _fraction(value: float) -> Fraction:
    """Interpret the finite decimal shown in JSON/output as an exact rational."""
    return Fraction(str(value))


def _fraction_inverse(
    matrix: Sequence[Sequence[Fraction]],
) -> Tuple[Tuple[Fraction, ...], ...]:
    d = len(matrix)
    augmented = [
        list(row) + [Fraction(1 if i == j else 0) for j in range(d)]
        for i, row in enumerate(matrix)
    ]
    for column in range(d):
        pivot = next((row for row in range(column, d) if augmented[row][column]), None)
        if pivot is None:
            raise ArithmeticError("singular exact rational matrix")
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        divisor = augmented[column][column]
        augmented[column] = [value / divisor for value in augmented[column]]
        for row in range(d):
            if row == column:
                continue
            multiplier = augmented[row][column]
            if multiplier:
                augmented[row] = [
                    left - multiplier * right
                    for left, right in zip(augmented[row], augmented[column])
                ]
    return tuple(tuple(row[d:]) for row in augmented)


def _fraction_matvec(
    matrix: Sequence[Sequence[Fraction]], vector: Sequence[Fraction]
) -> Tuple[Fraction, ...]:
    return tuple(sum((a * b for a, b in zip(row, vector)), Fraction(0)) for row in matrix)


def _exact_parameter_certificate(model: Model) -> Mapping[str, Any]:
    """Check structural/sign facts in exact arithmetic on reported decimals."""
    d = model.dimension
    gamma = tuple(tuple(_fraction(value) for value in row) for row in model.covariance)
    reflection = tuple(tuple(_fraction(value) for value in row) for row in model.reflection)
    drift = tuple(_fraction(value) for value in model.drift)
    if any(gamma[i][j] != gamma[j][i] for i in range(d) for j in range(d)):
        return {"passed": False, "reason": "reported covariance is not exactly symmetric"}

    # Exact LDL' form: strict positivity of every diagonal pivot is equivalent
    # to positive definiteness for a symmetric matrix.
    lower = [[Fraction(0) for _ in range(d)] for _ in range(d)]
    diagonal: List[Fraction] = []
    for i in range(d):
        pivot = gamma[i][i] - sum(lower[i][k] * lower[i][k] * diagonal[k] for k in range(i))
        if pivot <= 0:
            return {"passed": False, "reason": f"exact covariance LDL pivot {i} is not positive"}
        diagonal.append(pivot)
        lower[i][i] = Fraction(1)
        for j in range(i + 1, d):
            numerator = gamma[j][i] - sum(
                lower[j][k] * lower[i][k] * diagonal[k] for k in range(i)
            )
            lower[j][i] = numerator / pivot

    if any(reflection[i][i] <= 0 for i in range(d)) or any(
        reflection[i][j] > 0 for i in range(d) for j in range(d) if i != j
    ):
        return {"passed": False, "reason": "exact reflection sign check failed"}
    try:
        inverse = _fraction_inverse(reflection)
    except ArithmeticError as error:
        return {"passed": False, "reason": str(error)}
    minimum_inverse = min(value for row in inverse for value in row)
    delta = _fraction_matvec(inverse, tuple(-value for value in drift))
    if minimum_inverse < 0:
        return {"passed": False, "reason": "exact inverse of reflection has a negative entry"}
    if any(value <= 0 for value in delta):
        return {"passed": False, "reason": "exact stability vector is not strictly positive"}
    return {
        "passed": True,
        "arithmetic": "exact rational arithmetic on the reported decimal parameters",
        "stability_vector_exact": [_fraction_text(value) for value in delta],
        "minimum_inverse_entry_exact": _fraction_text(minimum_inverse),
        "minimum_covariance_ldl_pivot_exact": _fraction_text(min(diagonal)),
        "delta": delta,
    }


def _fraction_text(value: Fraction) -> str:
    return str(value.numerator) if value.denominator == 1 else f"{value.numerator}/{value.denominator}"


def _validate_reflection(
    reflection: Sequence[Sequence[float]], drift: Sequence[float]
) -> Tuple[Tuple[Tuple[float, ...], ...], Tuple[float, ...], Mapping[str, Any]]:
    d = len(reflection)
    for i in range(d):
        if reflection[i][i] <= 0.0:
            _fail(f"reflection[{i}][{i}] must be strictly positive")
        for j in range(d):
            if i != j and reflection[i][j] > 0.0:
                _fail(
                    "this release requires a nonsingular M-matrix reflection: "
                    f"off-diagonal reflection[{i}][{j}] is positive"
                )
    exact_reflection = tuple(tuple(_fraction(value) for value in row) for row in reflection)
    exact_drift = tuple(_fraction(value) for value in drift)
    try:
        exact_inverse = _fraction_inverse(exact_reflection)
    except ArithmeticError:
        _fail("reflection must be nonsingular")
    exact_masses = _fraction_matvec(exact_inverse, tuple(-value for value in exact_drift))
    exact_minimum_inverse = min(value for row in exact_inverse for value in row)
    if exact_minimum_inverse < 0:
        _fail(
            "reflection is not a nonsingular M-matrix: its exact rational inverse "
            f"has entry {_fraction_text(exact_minimum_inverse)}"
        )
    if any(mass <= 0 for mass in exact_masses):
        offending = next((i, mass) for i, mass in enumerate(exact_masses) if mass <= 0)
        _fail(
            "the strict SRBM stability condition -R^{-1} drift > 0 fails: "
            f"exact boundary mass {offending[0]} is {_fraction_text(offending[1])}"
        )

    inverse = tuple(tuple(float(value) for value in row) for row in exact_inverse)
    minimum_inverse = min(value for row in inverse for value in row)
    masses = tuple(float(value) for value in exact_masses)
    residual = max(
        abs(drift[row] + sum(reflection[row][column] * masses[column] for column in range(d)))
        for row in range(d)
    )
    return inverse, masses, {
        "reflection_class": "exactly_validated_nonsingular_M_matrix",
        "minimum_inverse_entry": minimum_inverse,
        "minimum_inverse_entry_exact": _fraction_text(exact_minimum_inverse),
        "boundary_mass_balance_residual": residual,
        "strict_stability_margin": min(masses),
        "boundary_masses_exact": [_fraction_text(value) for value in exact_masses],
    }


def _parse_targets(value: Any, dimension: int, maximum_degree: int) -> Tuple[Target, ...]:
    if value is None:
        return tuple(
            Target(f"mean_x{i + 1}", tuple(1 if j == i else 0 for j in range(dimension)))
            for i in range(dimension)
        )
    if not isinstance(value, list) or not value:
        _fail("relaxation.targets must be a nonempty array")
    targets: List[Target] = []
    names = set()
    for index, raw in enumerate(value):
        target = _require_object(raw, f"relaxation.targets[{index}]")
        _check_keys(target, {"name", "moment"}, f"relaxation.targets[{index}]")
        name = target.get("name")
        if not isinstance(name, str) or not name.strip():
            _fail(f"relaxation.targets[{index}].name must be a nonempty string")
        if name in names:
            _fail(f"duplicate target name: {name}")
        names.add(name)
        moment = target.get("moment")
        if not isinstance(moment, list) or len(moment) != dimension:
            _fail(f"relaxation.targets[{index}].moment must have length {dimension}")
        parsed: List[int] = []
        for j, exponent in enumerate(moment):
            if isinstance(exponent, bool) or not isinstance(exponent, int) or exponent < 0:
                _fail(f"relaxation.targets[{index}].moment[{j}] must be a nonnegative integer")
            parsed.append(exponent)
        degree = sum(parsed)
        if degree < 1 or degree > maximum_degree:
            _fail(
                f"target {name} has degree {degree}; it must be between 1 and {maximum_degree}"
            )
        targets.append(Target(name, tuple(parsed)))
    return tuple(targets)


def load_model(document: Mapping[str, Any]) -> Model:
    """Parse and rigorously scope-check one versioned SRBM JSON document."""
    doc = _require_object(document, "input")
    _check_keys(
        doc,
        {"schema_version", "model_type", "name", "drift", "covariance", "reflection", "relaxation"},
        "input",
    )
    if doc.get("schema_version") != INPUT_SCHEMA_VERSION:
        _fail(f"schema_version must be {INPUT_SCHEMA_VERSION}")
    if doc.get("model_type") != MODEL_TYPE:
        _fail(f"model_type must be {MODEL_TYPE!r}")
    drift = _parse_vector(doc.get("drift"), "drift")
    dimension = len(drift)
    covariance_raw = _parse_matrix(doc.get("covariance"), dimension, "covariance")
    covariance, asymmetry = _symmetrize_and_validate(covariance_raw)
    minimum_covariance_pivot = _cholesky_min_pivot(covariance)
    reflection = _parse_matrix(doc.get("reflection"), dimension, "reflection")
    inverse, masses, reflection_validation = _validate_reflection(reflection, drift)

    relaxation = _require_object(doc.get("relaxation", {}), "relaxation")
    _check_keys(
        relaxation,
        {"order", "targets", "max_variables", "max_psd_entries"},
        "relaxation",
    )
    order = _positive_integer(relaxation.get("order", 2), "relaxation.order")
    if order > 8:
        _fail("relaxation.order must not exceed 8 in this release")
    max_variables = _positive_integer(
        relaxation.get("max_variables", DEFAULT_MAX_VARIABLES), "relaxation.max_variables"
    )
    max_psd_entries = _positive_integer(
        relaxation.get("max_psd_entries", DEFAULT_MAX_PSD_ENTRIES),
        "relaxation.max_psd_entries",
    )
    targets = _parse_targets(relaxation.get("targets"), dimension, 2 * order)
    name = doc.get("name", "unnamed SRBM")
    if not isinstance(name, str) or not name.strip():
        _fail("name must be a nonempty string")
    validation: Dict[str, Any] = {
        "covariance_class": "strictly_positive_definite",
        "covariance_max_asymmetry": asymmetry,
        "minimum_cholesky_pivot": minimum_covariance_pivot,
        "covariance_symmetry_check": "exact equality of reported decimal entries",
    }
    validation.update(reflection_validation)
    return Model(
        name=name,
        dimension=dimension,
        drift=drift,
        covariance=covariance,
        reflection=reflection,
        inverse_reflection=inverse,
        boundary_masses=masses,
        order=order,
        max_variables=max_variables,
        max_psd_entries=max_psd_entries,
        targets=targets,
        validation=validation,
    )


def load_model_file(path: str | Path) -> Model:
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise InputError(f"cannot read JSON model {path}: {error}") from error
    return load_model(document)


def multi_indices(dimension: int, maximum_degree: int) -> List[MultiIndex]:
    """All multi-indices in graded lexicographic order."""
    result: List[MultiIndex] = []
    for degree in range(maximum_degree + 1):
        for dividers in itertools.combinations(range(degree + dimension - 1), dimension - 1):
            points = (-1,) + dividers + (degree + dimension - 1,)
            result.append(tuple(points[i + 1] - points[i] - 1 for i in range(dimension)))
    return result


def _add_index(left: MultiIndex, right: MultiIndex) -> MultiIndex:
    return tuple(a + b for a, b in zip(left, right))


def _unit(dimension: int, coordinate: int) -> MultiIndex:
    return tuple(1 if i == coordinate else 0 for i in range(dimension))


def _subtract_units(alpha: MultiIndex, first: int, second: Optional[int] = None) -> MultiIndex:
    values = list(alpha)
    values[first] -= 1
    if second is not None:
        values[second] -= 1
    return tuple(values)


class _IRBuilder:
    def __init__(self, model: Model):
        self.model = model
        self.variables: List[Dict[str, Any]] = []
        self.variable_ids: Dict[Tuple[str, int, MultiIndex], int] = {}

    def add_variable(self, measure: str, face: int, alpha: MultiIndex) -> int:
        key = (measure, face, alpha)
        identifier = len(self.variables)
        self.variable_ids[key] = identifier
        if measure == "interior":
            name = "y[" + ",".join(map(str, alpha)) + "]"
            description = "stationary interior moment"
            face_value: Optional[int] = None
        else:
            name = f"b{face + 1}[" + ",".join(map(str, alpha)) + "]"
            description = f"boundary moment on face {face + 1}"
            face_value = face
        self.variables.append(
            {
                "id": identifier,
                "name": name,
                "measure": measure,
                "face": face_value,
                "multi_index": list(alpha),
                "description": description,
            }
        )
        return identifier

    def interior(self, alpha: MultiIndex) -> int:
        return self.variable_ids[("interior", -1, alpha)]

    def boundary(self, face: int, alpha: MultiIndex) -> Optional[int]:
        if alpha[face] != 0:
            return None
        return self.variable_ids[("boundary", face, alpha)]


def _terms_as_list(coefficients: Mapping[int, float]) -> List[Dict[str, Any]]:
    return [
        {"variable": identifier, "coefficient": coefficient}
        for identifier, coefficient in sorted(coefficients.items())
        if coefficient != 0.0
    ]


def _matrix_block(
    name: str,
    measure: str,
    face: Optional[int],
    basis: Sequence[MultiIndex],
    shift: MultiIndex,
    builder: _IRBuilder,
) -> Dict[str, Any]:
    entries: List[List[int]] = []
    for left in basis:
        row: List[int] = []
        for right in basis:
            alpha = _add_index(_add_index(left, right), shift)
            identifier = (
                builder.interior(alpha)
                if measure == "interior"
                else builder.boundary(int(face), alpha)
            )
            if identifier is None:
                raise AssertionError("boundary basis generated a moment off its supporting face")
            row.append(identifier)
        entries.append(row)
    return {
        "name": name,
        "measure": measure,
        "face": face,
        "basis": [list(alpha) for alpha in basis],
        "shift": list(shift),
        "entries": entries,
    }


def _bar_equality(alpha: MultiIndex, model: Model, builder: _IRBuilder) -> Dict[str, Any]:
    d = model.dimension
    coefficients: Dict[int, float] = {}

    def add(identifier: Optional[int], value: float) -> None:
        if identifier is None or value == 0.0:
            return
        coefficients[identifier] = coefficients.get(identifier, 0.0) + value

    # E[mu . grad f]
    for j in range(d):
        if alpha[j]:
            add(builder.interior(_subtract_units(alpha, j)), alpha[j] * model.drift[j])

    # 1/2 E[Gamma : Hessian f], using the ordered (j,k) sum.
    for j in range(d):
        if not alpha[j]:
            continue
        for k in range(d):
            derivative = alpha[j] * (alpha[k] - (1 if j == k else 0))
            if derivative <= 0:
                continue
            add(
                builder.interior(_subtract_units(alpha, j, k)),
                0.5 * model.covariance[j][k] * derivative,
            )

    # Sum_i integral_{face i} (R[:,i] . grad f) d nu_i.
    for face in range(d):
        for j in range(d):
            if alpha[j]:
                beta = _subtract_units(alpha, j)
                add(
                    builder.boundary(face, beta),
                    alpha[j] * model.reflection[j][face],
                )
    return {
        "name": "BAR_f=x^[" + ",".join(map(str, alpha)) + "]",
        "test_multi_index": list(alpha),
        "terms": _terms_as_list(coefficients),
        "rhs": 0.0,
    }


def build_relaxation(model: Model) -> Dict[str, Any]:
    """Build the finite Stieltjes moment SDP outer relaxation.

    A feasible true stationary moment sequence is retained, so exact optima of
    the minimization/maximization objectives are mathematical outer bounds.
    """
    d = model.dimension
    q = model.order
    maximum_moment_degree = 2 * q
    interior_count = math.comb(d + maximum_moment_degree, maximum_moment_degree)
    boundary_count = math.comb(d - 1 + maximum_moment_degree, maximum_moment_degree)
    planned_variables = interior_count + d * boundary_count
    if planned_variables > model.max_variables:
        _fail(
            f"relaxation needs {planned_variables} scalar moments, above "
            f"relaxation.max_variables={model.max_variables}"
        )
    interior_basis_count = math.comb(d + q, q)
    local_basis_count = math.comb(d + q - 1, q - 1)
    boundary_basis_count = math.comb(d - 1 + q, q)
    boundary_local_basis_count = math.comb(d + q - 2, q - 1)
    planned_psd_entries = (
        interior_basis_count**2
        + d * local_basis_count**2
        + d * boundary_basis_count**2
        + d * (d - 1) * boundary_local_basis_count**2
    )
    if planned_psd_entries > model.max_psd_entries:
        _fail(
            f"relaxation needs {planned_psd_entries} PSD matrix entries, above "
            f"relaxation.max_psd_entries={model.max_psd_entries}"
        )
    all_moments = multi_indices(d, maximum_moment_degree)
    builder = _IRBuilder(model)
    for alpha in all_moments:
        builder.add_variable("interior", -1, alpha)
    eliminated_support_moments = 0
    for face in range(d):
        for alpha in all_moments:
            if alpha[face] == 0:
                builder.add_variable("boundary", face, alpha)
            else:
                eliminated_support_moments += 1
    assert len(builder.variables) == planned_variables

    zero = (0,) * d
    equalities: List[Dict[str, Any]] = [
        {
            "name": "interior_probability_normalization",
            "terms": [{"variable": builder.interior(zero), "coefficient": 1.0}],
            "rhs": 1.0,
        }
    ]
    # Degree-one BAR imposes R b(0) = -mu * y(0).  Keeping those equations in
    # their original coefficient form (rather than fixing b(0) to a rounded
    # numerical inverse) preserves the outer-relaxation inclusion property.
    for alpha in multi_indices(d, 2 * q + 1):
        degree = sum(alpha)
        if degree >= 1:
            equality = _bar_equality(alpha, model, builder)
            if equality["terms"]:
                equalities.append(equality)

    psd_blocks: List[Dict[str, Any]] = []
    interior_basis = multi_indices(d, q)
    psd_blocks.append(
        _matrix_block("M_q(interior)", "interior", None, interior_basis, zero, builder)
    )
    local_basis = multi_indices(d, q - 1)
    for coordinate in range(d):
        psd_blocks.append(
            _matrix_block(
                f"M_q-1(x{coordinate + 1} interior)",
                "interior",
                None,
                local_basis,
                _unit(d, coordinate),
                builder,
            )
        )
    for face in range(d):
        face_basis = [alpha for alpha in interior_basis if alpha[face] == 0]
        psd_blocks.append(
            _matrix_block(
                f"M_q(boundary_face_{face + 1})",
                "boundary",
                face,
                face_basis,
                zero,
                builder,
            )
        )
        face_local_basis = [alpha for alpha in local_basis if alpha[face] == 0]
        for coordinate in range(d):
            if coordinate == face:
                continue
            psd_blocks.append(
                _matrix_block(
                    f"M_q-1(x{coordinate + 1} boundary_face_{face + 1})",
                    "boundary",
                    face,
                    face_local_basis,
                    _unit(d, coordinate),
                    builder,
                )
            )

    objectives = [
        {
            "name": target.name,
            "moment": list(target.moment),
            "variable": builder.interior(target.moment),
            "directions": ["minimize", "maximize"],
        }
        for target in model.targets
    ]
    return {
        "ir_schema_version": IR_SCHEMA_VERSION,
        "ir_type": "bar_truncated_stieltjes_moment_sdp",
        "mathematical_status": (
            "outer relaxation: an exact conic optimum is a valid stationary-moment bound "
            "under the documented moment-integrability assumptions"
        ),
        "model": {
            "name": model.name,
            "drift": list(model.drift),
            "covariance": [list(row) for row in model.covariance],
            "reflection": [list(row) for row in model.reflection],
        },
        "assumptions": [
            "stationary moments through degree 2*order exist",
            "the polynomial BAR is justified through test degree 2*order+1",
            "reflection direction i is column i of R",
        ],
        "dimension": d,
        "order": q,
        "maximum_moment_degree": maximum_moment_degree,
        "maximum_bar_test_degree": 2 * q + 1,
        "reflection_convention": "column i is the reflection direction on face x_i=0",
        "variables": builder.variables,
        "equalities": equalities,
        "nonnegative_variables": [variable["id"] for variable in builder.variables],
        "psd_blocks": psd_blocks,
        "objectives": objectives,
        "support_constraints": {
            "interior": "x_j >= 0 for every coordinate",
            "boundary": "boundary measure i is supported on x_i=0 and x_j>=0 for j!=i",
            "moments_eliminated_by_boundary_support": eliminated_support_moments,
        },
        "counts": {
            "variables": len(builder.variables),
            "equalities": len(equalities),
            "nonnegative_scalar_constraints": len(builder.variables),
            "psd_blocks": len(psd_blocks),
            "largest_psd_block": max(len(block["entries"]) for block in psd_blocks),
            "psd_matrix_entries": planned_psd_entries,
        },
    }


def _skew_symmetry_diagnostics(model: Model) -> Mapping[str, Any]:
    d = model.dimension
    diagonal = [model.covariance[i][i] / model.reflection[i][i] for i in range(d)]
    residuals = []
    for i in range(d):
        for j in range(d):
            right = model.reflection[i][j] * diagonal[j] + diagonal[i] * model.reflection[j][i]
            residuals.append(2.0 * model.covariance[i][j] - right)
    scale = max(1.0, _matrix_scale(model.covariance), _matrix_scale(model.reflection) * max(diagonal))
    maximum = max(abs(value) for value in residuals)
    exact_gamma = tuple(tuple(_fraction(value) for value in row) for row in model.covariance)
    exact_reflection = tuple(tuple(_fraction(value) for value in row) for row in model.reflection)
    exact_diagonal = [exact_gamma[i][i] / exact_reflection[i][i] for i in range(d)]
    exact_identity = all(
        2 * exact_gamma[i][j]
        == exact_reflection[i][j] * exact_diagonal[j]
        + exact_diagonal[i] * exact_reflection[j][i]
        for i in range(d)
        for j in range(d)
    )
    return {
        "condition": "2*Gamma = R*D + D*R^T, D_ii=Gamma_ii/R_ii",
        "maximum_absolute_residual": maximum,
        "scaled_residual": maximum / scale,
        "exact_for_reported_decimal_parameters": exact_identity,
        "near_condition_tolerance": SYMMETRY_TOLERANCE,
        "near_condition": maximum <= SYMMETRY_TOLERANCE * scale,
    }


def _exact_factorial_moment(mean: Fraction, exponent: int) -> Fraction:
    return math.factorial(exponent) * mean**exponent


def _exact_solution(model: Model) -> Optional[Dict[str, Any]]:
    if model.dimension == 1:
        certificate = _exact_parameter_certificate(model)
        if not certificate["passed"]:
            return None
        exact_mean = _fraction(model.covariance[0][0]) / (-2 * _fraction(model.drift[0]))
        mean = float(exact_mean)
        targets = {}
        for target in model.targets:
            exact_value = _exact_factorial_moment(exact_mean, target.moment[0])
            value = float(exact_value)
            targets[target.name] = {
                "moment": list(target.moment),
                "lower_bound": value,
                "upper_bound": value,
                "lower_bound_exact": _fraction_text(exact_value),
                "upper_bound_exact": _fraction_text(exact_value),
                "certified": True,
            }
        return {
            "kind": "exact_one_dimensional_srbm",
            "certified": True,
            "certification": {key: value for key, value in certificate.items() if key != "delta"},
            "statement": "The stationary law is exponential with rate -2*drift/covariance.",
            "exponential_rates": [-2.0 * model.drift[0] / model.covariance[0][0]],
            "means": [mean],
            "means_exact": [_fraction_text(exact_mean)],
            "targets": targets,
        }

    skew = _skew_symmetry_diagnostics(model)
    # A tolerance-based near equality is useful diagnostically but is not a
    # proof of product form. Only an exact rational identity for the reported
    # decimal parameters triggers a certified point result.
    if not skew["exact_for_reported_decimal_parameters"]:
        return None
    certificate = _exact_parameter_certificate(model)
    if not certificate["passed"]:
        return None
    exact_delta = certificate["delta"]
    exact_means = [
        _fraction(model.covariance[i][i])
        / (2 * _fraction(model.reflection[i][i]) * exact_delta[i])
        for i in range(model.dimension)
    ]
    means = [float(value) for value in exact_means]
    targets: Dict[str, Any] = {}
    for target in model.targets:
        exact_value = math.prod(
            _exact_factorial_moment(exact_means[i], exponent)
            for i, exponent in enumerate(target.moment)
        )
        value = float(exact_value)
        targets[target.name] = {
            "moment": list(target.moment),
            "lower_bound": value,
            "upper_bound": value,
            "lower_bound_exact": _fraction_text(exact_value),
            "upper_bound_exact": _fraction_text(exact_value),
            "certified": True,
        }
    return {
        "kind": "exact_skew_symmetric_product_form_srbm",
        "certified": True,
        "certification": {key: value for key, value in certificate.items() if key != "delta"},
        "statement": "The stationary coordinates are independent exponentials.",
        "skew_symmetry": skew,
        "exponential_rates": [1.0 / mean for mean in means],
        "means": means,
        "means_exact": [_fraction_text(value) for value in exact_means],
        "targets": targets,
    }


def _base_output(model: Model) -> Dict[str, Any]:
    return {
        "schema_version": OUTPUT_SCHEMA_VERSION,
        "model_type": MODEL_TYPE,
        "model": {
            "name": model.name,
            "dimension": model.dimension,
            "drift": list(model.drift),
            "covariance": [list(row) for row in model.covariance],
            "reflection": [list(row) for row in model.reflection],
            "reflection_convention": "column i is the reflection direction on face x_i=0",
        },
        "validation": dict(model.validation),
        "boundary_measures": {
            "masses": list(model.boundary_masses),
            "derivation": "R * boundary_masses = -drift from the degree-one BAR",
        },
    }


def solve_model(
    model: Model,
    *,
    backend: str = "none",
    cvxpy_solver: Optional[str] = None,
    force_relaxation: bool = False,
) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Return structured results and, when built, the transparent conic IR."""
    if backend not in {"none", "auto", "cvxpy"}:
        _fail("backend must be one of: none, auto, cvxpy")
    output = _base_output(model)
    skew = _skew_symmetry_diagnostics(model)
    output["validation"]["skew_symmetry"] = skew
    exact = None if force_relaxation else _exact_solution(model)
    if exact is not None:
        output["method"] = exact
        output["diagnostics"] = {
            "general_relaxation_built": False,
            "numerical_backend_used": False,
            "roundoff_note": (
                "Point bounds follow analytically for the represented real-valued parameters; "
                "reported decimal evaluation uses IEEE-754 arithmetic."
            ),
        }
        return output, None

    relaxation = build_relaxation(model)
    output["method"] = {
        "kind": "bar_moment_sdp_outer_relaxation",
        "certified": False,
        "order": model.order,
        "formulation": (
            "Polynomial BAR equalities with normalized nonnegative interior/boundary "
            "moments, exact face-support elimination, and Stieltjes moment/localizing PSD cones."
        ),
        "mathematical_bound_status": (
            "The exact optimum of each exported conic problem is an outer lower/upper bound. "
            "Floating-point backend values are not formal certificates."
        ),
        "targets": {
            target.name: {
                "moment": list(target.moment),
                "lower": {"status": "not_solved", "certified": False},
                "upper": {"status": "not_solved", "certified": False},
            }
            for target in model.targets
        },
    }
    output["relaxation"] = {
        key: relaxation[key]
        for key in (
            "ir_schema_version",
            "order",
            "maximum_moment_degree",
            "maximum_bar_test_degree",
            "counts",
            "support_constraints",
        )
    }
    if backend != "none":
        try:
            from .cvxpy_backend import BackendUnavailable, solve_relaxation
        except ImportError:  # Direct execution fallback.
            from cvxpy_backend import BackendUnavailable, solve_relaxation
        try:
            numerical = solve_relaxation(relaxation, requested_solver=cvxpy_solver)
            output["method"]["targets"] = numerical["targets"]
            output["diagnostics"] = numerical["diagnostics"]
        except BackendUnavailable as error:
            if backend == "cvxpy":
                _fail(str(error))
            output["diagnostics"] = {
                "general_relaxation_built": True,
                "numerical_backend_used": False,
                "backend_status": "unavailable",
                "message": str(error),
            }
    else:
        output["diagnostics"] = {
            "general_relaxation_built": True,
            "numerical_backend_used": False,
            "backend_status": "not_requested",
        }
    return output, relaxation
