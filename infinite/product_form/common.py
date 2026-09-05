"""Shared validation and numerical helpers for product-form solvers."""

from __future__ import annotations

import math
from typing import Any, Iterable, Mapping, Sequence


class ConfigError(ValueError):
    """The input document is invalid or outside the supported exact scope."""


class StateSpaceLimitError(RuntimeError):
    """Exact state enumeration exceeded its configured safety limit."""


def mapping(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError("{} must be a JSON object".format(context))
    return value


def sequence(value: Any, context: str) -> Sequence[Any]:
    if not isinstance(value, list):
        raise ConfigError("{} must be a JSON array".format(context))
    return value


def nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError("{} must be a non-empty string".format(context))
    return value.strip()


def integer(value: Any, context: str, minimum: int = 0) -> int:
    if isinstance(value, bool):
        raise ConfigError("{} must be an integer >= {}".format(context, minimum))
    if isinstance(value, int):
        result = value
    elif isinstance(value, float) and math.isfinite(value) and value.is_integer():
        result = int(value)
    else:
        raise ConfigError("{} must be an integer >= {}".format(context, minimum))
    if result < minimum:
        raise ConfigError("{} must be an integer >= {}".format(context, minimum))
    return result


def positive_number(value: Any, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError("{} must be a positive finite number".format(context))
    result = float(value)
    if not math.isfinite(result) or result <= 0.0:
        raise ConfigError("{} must be a positive finite number".format(context))
    return result


def probability(value: Any, context: str, allow_zero: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError("{} must be a finite probability".format(context))
    result = float(value)
    lower_ok = result >= 0.0 if allow_zero else result > 0.0
    if not math.isfinite(result) or not lower_ok or result > 1.0:
        interval = "[0, 1]" if allow_zero else "(0, 1]"
        raise ConfigError("{} must be in {}".format(context, interval))
    return result


def check_keys(
    obj: Mapping[str, Any], allowed: Iterable[str], context: str
) -> None:
    extras = sorted(set(obj) - set(allowed))
    if extras:
        raise ConfigError(
            "{} has unknown field{}: {}".format(
                context,
                "s" if len(extras) != 1 else "",
                ", ".join(extras),
            )
        )


def require_fields(
    obj: Mapping[str, Any], required: Iterable[str], context: str
) -> None:
    missing = [field for field in required if field not in obj]
    if missing:
        raise ConfigError(
            "{} is missing required field{}: {}".format(
                context,
                "s" if len(missing) != 1 else "",
                ", ".join(missing),
            )
        )


def optional_ratio(numerator: float, denominator: float):
    return numerator / denominator if denominator > 0.0 else None


def logaddexp(left: float, right: float) -> float:
    if left == -math.inf:
        return right
    if right == -math.inf:
        return left
    high = max(left, right)
    low = min(left, right)
    return high + math.log1p(math.exp(low - high))


def solve_linear_system(matrix, rhs, context: str):
    """Dense Gaussian elimination with partial pivoting for small routing systems."""

    size = len(rhs)
    augmented = [list(matrix[row]) + [float(rhs[row])] for row in range(size)]
    scale = max(
        1.0,
        max((abs(value) for row in matrix for value in row), default=0.0),
    )
    pivot_tolerance = 1.0e-13 * scale
    for column in range(size):
        pivot = max(range(column, size), key=lambda row: abs(augmented[row][column]))
        if abs(augmented[pivot][column]) <= pivot_tolerance:
            raise ConfigError("{} is singular or numerically degenerate".format(context))
        if pivot != column:
            augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        pivot_value = augmented[column][column]
        for entry in range(column, size + 1):
            augmented[column][entry] /= pivot_value
        for row in range(size):
            if row == column:
                continue
            factor = augmented[row][column]
            if factor == 0.0:
                continue
            for entry in range(column, size + 1):
                augmented[row][entry] -= factor * augmented[column][entry]
    return [augmented[row][size] for row in range(size)]
