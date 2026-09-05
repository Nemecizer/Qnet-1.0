#!/usr/bin/env python3
"""Adaptive finite-state truncation for open Markovian queueing networks.

The numerical method uses a sparse transition operator and matrix-free
uniformization.  It intentionally depends only on the Python standard library.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


Vector = list[float]
State = tuple[int, ...]


class TruncatedCTMCError(Exception):
    code = "truncated_ctmc_error"

    def __init__(self, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.details = details or {}


class InputError(TruncatedCTMCError):
    code = "invalid_input"


class StabilityError(TruncatedCTMCError):
    code = "not_positive_recurrent"


class ConvergenceError(TruncatedCTMCError):
    code = "stationary_iteration_not_converged"


class StateLimitError(TruncatedCTMCError):
    code = "state_limit_exceeded"


@dataclass(frozen=True)
class Node:
    name: str
    external_arrival_rate: float
    service_rate_per_server: float
    servers: int


@dataclass(frozen=True)
class SolverOptions:
    initial_total_cap: int = 8
    max_total_cap: int = 64
    growth_factor: float = 1.6
    minimum_cap_increment: int = 2
    max_states: int = 200_000
    stationary_tolerance: float = 1.0e-13
    stationary_max_iterations: int = 200_000
    boundary_mass_tolerance: float = 1.0e-8
    refinement_relative_tolerance: float = 1.0e-7
    stability_tolerance: float = 1.0e-12
    routing_tolerance: float = 1.0e-12
    tail_levels: tuple[int, ...] = (1, 5, 10)
    top_state_count: int = 20
    include_state_probabilities: bool = False
    certificate_theta: float | None = None


@dataclass(frozen=True)
class NetworkModel:
    nodes: tuple[Node, ...]
    routing: tuple[tuple[float, ...], ...]
    exit_probabilities: tuple[float, ...]
    options: SolverOptions
    name: str | None = None

    @property
    def dimension(self) -> int:
        return len(self.nodes)

    @property
    def total_external_arrival_rate(self) -> float:
        try:
            result = math.fsum(node.external_arrival_rate for node in self.nodes)
        except OverflowError as error:
            raise InputError("total external arrival rate is not finite") from error
        if not math.isfinite(result):
            raise InputError("total external arrival rate is not finite")
        return result


@dataclass
class SparseUniformizedOperator:
    total_cap: int
    states: list[State]
    state_index: dict[State, int]
    transitions: list[list[tuple[int, float]]]
    exit_rates: list[float]
    uniformization_rate: float
    boundary_indices: list[int]

    def apply(self, distribution: Vector) -> Vector:
        result = [0.0 for _ in self.states]
        gamma = self.uniformization_rate
        for source, probability in enumerate(distribution):
            if probability == 0.0:
                continue
            self_weight = 1.0 - self.exit_rates[source] / gamma
            if self_weight < -1.0e-13:
                raise ConvergenceError(
                    "uniformization produced a negative self-transition",
                    {"state": list(self.states[source]), "self_weight": self_weight},
                )
            result[source] += probability * max(0.0, self_weight)
            for target, rate in self.transitions[source]:
                result[target] += probability * rate / gamma
        return result


def _finite_float(value: Any, path: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputError(f"{path} must be a finite number")
    try:
        result = float(value)
    except (OverflowError, ValueError) as error:
        raise InputError(f"{path} must be representable as a finite float") from error
    if not math.isfinite(result):
        raise InputError(f"{path} must be finite")
    return result


def _positive_float(value: Any, path: str) -> float:
    result = _finite_float(value, path)
    if result <= 0.0:
        raise InputError(f"{path} must be positive")
    return result


def _nonnegative_float(value: Any, path: str) -> float:
    result = _finite_float(value, path)
    if result < 0.0:
        raise InputError(f"{path} must be nonnegative")
    return result


def _integer(value: Any, path: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        qualifier = "positive" if minimum == 1 else "nonnegative"
        raise InputError(f"{path} must be a {qualifier} integer")
    return value


def _option_float(
    document: dict[str, Any], key: str, default: float, *, positive: bool
) -> float:
    value = document.get(key, default)
    if positive:
        return _positive_float(value, f"solver.{key}")
    return _nonnegative_float(value, f"solver.{key}")


def _option_int(
    document: dict[str, Any], key: str, default: int, minimum: int = 0
) -> int:
    return _integer(document.get(key, default), f"solver.{key}", minimum)


def parse_model(document: dict[str, Any]) -> NetworkModel:
    if not isinstance(document, dict):
        raise InputError("the JSON root must be an object")
    version = document.get("schema_version")
    if isinstance(version, bool) or version != 1:
        raise InputError("schema_version must be 1")
    if document.get("process") != "open_single_class_markovian_network":
        raise InputError(
            "process must be 'open_single_class_markovian_network'"
        )

    node_documents = document.get("nodes")
    if not isinstance(node_documents, list) or not node_documents:
        raise InputError("nodes must be a nonempty array")
    nodes: list[Node] = []
    for index, item in enumerate(node_documents):
        path = f"nodes[{index}]"
        if not isinstance(item, dict):
            raise InputError(f"{path} must be an object")
        name = item.get("name", f"node_{index + 1}")
        if not isinstance(name, str) or not name:
            raise InputError(f"{path}.name must be a nonempty string")
        nodes.append(
            Node(
                name=name,
                external_arrival_rate=_nonnegative_float(
                    item.get("external_arrival_rate"),
                    f"{path}.external_arrival_rate",
                ),
                service_rate_per_server=_positive_float(
                    item.get("service_rate_per_server"),
                    f"{path}.service_rate_per_server",
                ),
                servers=_integer(item.get("servers", 1), f"{path}.servers", 1),
            )
        )
    if len({node.name for node in nodes}) != len(nodes):
        raise InputError("node names must be unique")
    for index, node in enumerate(nodes):
        try:
            capacity = node.servers * node.service_rate_per_server
        except OverflowError as error:
            raise InputError(f"nodes[{index}] service capacity is not finite") from error
        if not math.isfinite(capacity):
            raise InputError(f"nodes[{index}] service capacity is not finite")

    dimension = len(nodes)
    routing_document = document.get("routing")
    if (
        not isinstance(routing_document, list)
        or len(routing_document) != dimension
        or any(not isinstance(row, list) or len(row) != dimension for row in routing_document)
    ):
        raise InputError(f"routing must be a {dimension}x{dimension} matrix")

    routing: list[tuple[float, ...]] = []
    exits: list[float] = []
    for i, row_document in enumerate(routing_document):
        row = tuple(
            _nonnegative_float(value, f"routing[{i}][{j}]")
            for j, value in enumerate(row_document)
        )
        row_sum = math.fsum(row)
        if row_sum > 1.0:
            raise InputError(
                f"routing row {i} sums to {row_sum:.17g}, which exceeds 1"
            )
        routing.append(row)
        exits.append(max(0.0, 1.0 - row_sum))

    solver_document = document.get("solver", {})
    if not isinstance(solver_document, dict):
        raise InputError("solver must be an object")
    initial_cap = _option_int(solver_document, "initial_total_cap", 8, 1)
    maximum_cap = _option_int(solver_document, "max_total_cap", 64, 1)
    if initial_cap > maximum_cap:
        raise InputError("solver.initial_total_cap cannot exceed max_total_cap")
    growth_factor = _option_float(
        solver_document, "growth_factor", 1.6, positive=True
    )
    if growth_factor <= 1.0:
        raise InputError("solver.growth_factor must be greater than 1")

    tail_document = solver_document.get("tail_levels", [1, 5, 10])
    if not isinstance(tail_document, list):
        raise InputError("solver.tail_levels must be an array")
    tail_levels = tuple(
        sorted(
            {
                _integer(value, f"solver.tail_levels[{index}]")
                for index, value in enumerate(tail_document)
            }
        )
    )
    include_states = solver_document.get("include_state_probabilities", False)
    if not isinstance(include_states, bool):
        raise InputError("solver.include_state_probabilities must be a boolean")
    theta_document = solver_document.get("certificate_theta")
    theta = (
        None
        if theta_document is None
        else _positive_float(theta_document, "solver.certificate_theta")
    )

    options = SolverOptions(
        initial_total_cap=initial_cap,
        max_total_cap=maximum_cap,
        growth_factor=growth_factor,
        minimum_cap_increment=_option_int(
            solver_document, "minimum_cap_increment", 2, 1
        ),
        max_states=_option_int(solver_document, "max_states", 200_000, 1),
        stationary_tolerance=_option_float(
            solver_document, "stationary_tolerance", 1.0e-13, positive=True
        ),
        stationary_max_iterations=_option_int(
            solver_document, "stationary_max_iterations", 200_000, 1
        ),
        boundary_mass_tolerance=_option_float(
            solver_document, "boundary_mass_tolerance", 1.0e-8, positive=False
        ),
        refinement_relative_tolerance=_option_float(
            solver_document,
            "refinement_relative_tolerance",
            1.0e-7,
            positive=False,
        ),
        stability_tolerance=_option_float(
            solver_document, "stability_tolerance", 1.0e-12, positive=True
        ),
        routing_tolerance=_option_float(
            solver_document, "routing_tolerance", 1.0e-12, positive=True
        ),
        tail_levels=tail_levels,
        top_state_count=_option_int(solver_document, "top_state_count", 20),
        include_state_probabilities=include_states,
        certificate_theta=theta,
    )

    name = document.get("name")
    if name is not None and not isinstance(name, str):
        raise InputError("name must be a string when present")
    return NetworkModel(
        nodes=tuple(nodes),
        routing=tuple(routing),
        exit_probabilities=tuple(exits),
        options=options,
        name=name,
    )


def solve_linear(matrix: list[list[float]], rhs: Vector) -> Vector:
    size = len(matrix)
    if size == 0 or any(len(row) != size for row in matrix) or len(rhs) != size:
        raise InputError("linear solve requires a nonempty square matrix")
    augmented = [matrix[i][:] + [float(rhs[i])] for i in range(size)]
    row_scales = [max(abs(value) for value in row) for row in matrix]
    if any(scale == 0.0 for scale in row_scales):
        raise InputError("routing matrix is singular; the network is not open")

    for column in range(size):
        pivot = max(
            range(column, size),
            key=lambda row: abs(augmented[row][column]) / row_scales[row],
        )
        floor = 8.0 * sys.float_info.epsilon * size * row_scales[pivot]
        if abs(augmented[pivot][column]) <= floor:
            raise InputError("routing matrix is singular; the network is not open")
        if pivot != column:
            augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
            row_scales[column], row_scales[pivot] = (
                row_scales[pivot],
                row_scales[column],
            )
        pivot_value = augmented[column][column]
        for row in range(column + 1, size):
            factor = augmented[row][column] / pivot_value
            augmented[row][column] = 0.0
            for j in range(column + 1, size + 1):
                augmented[row][j] -= factor * augmented[column][j]

    result = [0.0 for _ in range(size)]
    for row in range(size - 1, -1, -1):
        remainder = augmented[row][size] - math.fsum(
            augmented[row][j] * result[j] for j in range(row + 1, size)
        )
        result[row] = remainder / augmented[row][row]
    return result


def traffic_and_stability(model: NetworkModel) -> dict[str, Any]:
    dimension = model.dimension
    system = [
        [
            (1.0 if i == j else 0.0) - model.routing[j][i]
            for j in range(dimension)
        ]
        for i in range(dimension)
    ]
    external = [node.external_arrival_rate for node in model.nodes]
    try:
        throughput = solve_linear(system, external)
    except InputError as error:
        raise InputError(
            "I - routing is singular or rank deficient; routing is not open",
            {"cause": str(error)},
        ) from error

    scale = max(
        sys.float_info.min,
        max(throughput, default=0.0),
        max(external, default=0.0),
    )
    negative_tolerance = model.options.routing_tolerance * scale
    if min(throughput) < -negative_tolerance:
        raise InputError(
            "traffic equations produced a negative throughput",
            {"throughputs": throughput},
        )
    throughput = [max(0.0, value) for value in throughput]
    balance = [
        throughput[i]
        - external[i]
        - math.fsum(throughput[j] * model.routing[j][i] for j in range(dimension))
        for i in range(dimension)
    ]
    residual = max((abs(value) for value in balance), default=0.0) / scale
    if residual > model.options.routing_tolerance:
        raise InputError(
            "traffic-equation residual exceeds solver.routing_tolerance",
            {
                "traffic_equation_residual_scaled": residual,
                "routing_tolerance": model.options.routing_tolerance,
            },
        )

    capacities = [
        node.servers * node.service_rate_per_server for node in model.nodes
    ]
    utilizations = [throughput[i] / capacities[i] for i in range(dimension)]
    margins = [1.0 - utilization for utilization in utilizations]
    minimum_margin = min(margins)
    tolerance = model.options.stability_tolerance
    if minimum_margin > tolerance:
        classification = "certified_positive_recurrent"
    elif minimum_margin < -tolerance:
        classification = "certified_unstable"
    else:
        classification = "critical_or_numerically_undetermined"

    details = {
        "classification": classification,
        "basis": "Jackson traffic equations for M/M/c nodes",
        "certified": classification != "critical_or_numerically_undetermined",
        "throughput_by_node": throughput,
        "service_capacity_by_node": capacities,
        "utilization_by_node": utilizations,
        "capacity_margin_by_node": margins,
        "minimum_capacity_margin": minimum_margin,
        "decision_tolerance": tolerance,
        "traffic_equation_residual_scaled": residual,
        "assumptions": [
            "independent Poisson external arrivals",
            "independent exponential service times at each identical server",
            "state-independent Markovian routing after each service completion",
            "infinite waiting room, one customer class, and work-conserving FCFS service",
            "an open routing matrix with no closed customer class",
        ],
    }
    if classification != "certified_positive_recurrent":
        raise StabilityError(
            "the open network does not satisfy strict nodewise traffic stability",
            {"stability": details},
        )
    return details


def enumerate_states(dimension: int, total_cap: int) -> list[State]:
    partial: list[tuple[State, int]] = [((), total_cap)]
    for _ in range(dimension):
        expanded: list[tuple[State, int]] = []
        for prefix, remaining in partial:
            expanded.extend(
                (prefix + (value,), remaining - value)
                for value in range(remaining + 1)
            )
        partial = expanded
    return [state for state, _ in partial]


def state_count(dimension: int, total_cap: int) -> int:
    return math.comb(total_cap + dimension, dimension)


def build_operator(model: NetworkModel, total_cap: int) -> SparseUniformizedOperator:
    count = state_count(model.dimension, total_cap)
    if count > model.options.max_states:
        raise StateLimitError(
            "the requested initial truncation exceeds solver.max_states",
            {
                "total_cap": total_cap,
                "required_states": count,
                "max_states": model.options.max_states,
            },
        )
    states = enumerate_states(model.dimension, total_cap)
    index = {state: position for position, state in enumerate(states)}
    transitions: list[list[tuple[int, float]]] = []
    exit_rates: list[float] = []
    boundary_indices: list[int] = []

    for source, state in enumerate(states):
        total = sum(state)
        if total == total_cap:
            boundary_indices.append(source)
        targets: dict[int, float] = {}

        def add(target_state: list[int], rate: float) -> None:
            if rate <= 0.0:
                return
            target = index[tuple(target_state)]
            if target != source:
                targets[target] = targets.get(target, 0.0) + rate

        if total < total_cap:
            for i, node in enumerate(model.nodes):
                if node.external_arrival_rate > 0.0:
                    target = list(state)
                    target[i] += 1
                    add(target, node.external_arrival_rate)

        for i, node in enumerate(model.nodes):
            if state[i] == 0:
                continue
            service_rate = node.service_rate_per_server * min(state[i], node.servers)
            departure_rate = service_rate * model.exit_probabilities[i]
            if departure_rate > 0.0:
                target = list(state)
                target[i] -= 1
                add(target, departure_rate)
            for j, probability in enumerate(model.routing[i]):
                if probability == 0.0:
                    continue
                target = list(state)
                target[i] -= 1
                target[j] += 1
                add(target, service_rate * probability)

        sparse_row = sorted(targets.items())
        transitions.append(sparse_row)
        exit_rates.append(math.fsum(rate for _, rate in sparse_row))

    try:
        service_bound = math.fsum(
            node.servers * node.service_rate_per_server for node in model.nodes
        )
        gamma = model.total_external_arrival_rate + service_bound
    except OverflowError as error:
        raise InputError("the uniformization event-rate bound is not finite") from error
    if not math.isfinite(gamma) or gamma <= 0.0:
        raise InputError("the network does not have a positive finite event-rate bound")
    maximum_exit = max(exit_rates, default=0.0)
    if maximum_exit > gamma * (1.0 + 1.0e-12):
        raise InputError(
            "computed exit rate exceeds the uniformization rate",
            {"maximum_exit_rate": maximum_exit, "uniformization_rate": gamma},
        )
    return SparseUniformizedOperator(
        total_cap=total_cap,
        states=states,
        state_index=index,
        transitions=transitions,
        exit_rates=exit_rates,
        uniformization_rate=gamma,
        boundary_indices=boundary_indices,
    )


def stationary_distribution(
    operator: SparseUniformizedOperator,
    options: SolverOptions,
    warm_start: dict[State, float] | None,
) -> tuple[Vector, dict[str, Any]]:
    if warm_start:
        distribution = [warm_start.get(state, 0.0) for state in operator.states]
        total = math.fsum(distribution)
        if total <= 0.0:
            warm_start = None
        else:
            distribution = [value / total for value in distribution]
    if not warm_start:
        distribution = [0.0 for _ in operator.states]
        distribution[operator.state_index[tuple(0 for _ in operator.states[0])]] = 1.0

    delta = math.inf
    residual = math.inf
    for iteration in range(1, options.stationary_max_iterations + 1):
        candidate = operator.apply(distribution)
        total = math.fsum(candidate)
        if not math.isfinite(total) or total <= 0.0:
            raise ConvergenceError(
                "stationary iteration produced a nonnormalizable vector",
                {"iteration": iteration},
            )
        candidate = [max(0.0, value / total) for value in candidate]
        candidate_total = math.fsum(candidate)
        candidate = [value / candidate_total for value in candidate]
        delta = math.fsum(
            abs(candidate[i] - distribution[i]) for i in range(len(candidate))
        )
        distribution = candidate
        if delta <= options.stationary_tolerance:
            probe = operator.apply(distribution)
            residual = math.fsum(
                abs(probe[i] - distribution[i]) for i in range(len(distribution))
            )
            if residual <= options.stationary_tolerance:
                break
        if delta == 0.0:
            raise ConvergenceError(
                "stationary iteration stagnated above the requested residual tolerance",
                {"iteration": iteration, "uniformized_residual_l1": residual},
            )
    else:
        probe = operator.apply(distribution)
        residual = math.fsum(
            abs(probe[i] - distribution[i]) for i in range(len(distribution))
        )
        raise ConvergenceError(
            "stationary iteration reached stationary_max_iterations",
            {
                "iterations": options.stationary_max_iterations,
                "last_change_l1": delta,
                "uniformized_residual_l1": residual,
            },
        )

    minimum = min(distribution)
    normalization_residual = abs(math.fsum(distribution) - 1.0)
    return distribution, {
        "algorithm": "power_iteration_on_sparse_uniformized_operator",
        "matrix_materialized": False,
        "iterations": iteration,
        "converged": True,
        "last_change_l1": delta,
        "uniformized_residual_l1": residual,
        "generator_residual_l1": operator.uniformization_rate * residual,
        "normalization_residual": normalization_residual,
        "minimum_probability": minimum,
        "uniformization_rate": operator.uniformization_rate,
        "stored_off_diagonal_transitions": sum(
            len(row) for row in operator.transitions
        ),
    }


def summarize(
    model: NetworkModel,
    operator: SparseUniformizedOperator,
    distribution: Vector,
) -> dict[str, Any]:
    dimension = model.dimension
    means = [
        math.fsum(probability * state[i] for state, probability in zip(operator.states, distribution))
        for i in range(dimension)
    ]
    mean_total = math.fsum(means)
    second_total = math.fsum(
        probability * sum(state) ** 2
        for state, probability in zip(operator.states, distribution)
    )
    raw_variance = second_total - mean_total * mean_total
    variance_tolerance = 100.0 * sys.float_info.epsilon * max(
        1.0, abs(second_total), mean_total * mean_total
    )
    if raw_variance < -variance_tolerance:
        raise ConvergenceError(
            "truncated stationary moments produce a materially negative variance",
            {
                "raw_variance": raw_variance,
                "roundoff_tolerance": variance_tolerance,
            },
        )
    variance_total = max(0.0, raw_variance)
    mean_busy_servers = [
        math.fsum(
            probability * min(state[i], model.nodes[i].servers)
            for state, probability in zip(operator.states, distribution)
        )
        for i in range(dimension)
    ]
    completion_rates = [
        mean_busy_servers[i] * model.nodes[i].service_rate_per_server
        for i in range(dimension)
    ]
    departure_rates = [
        completion_rates[i] * model.exit_probabilities[i]
        for i in range(dimension)
    ]
    empty_state = tuple(0 for _ in range(dimension))
    boundary_mass = math.fsum(distribution[i] for i in operator.boundary_indices)
    cap_minus_one_mass = math.fsum(
        probability
        for state, probability in zip(operator.states, distribution)
        if sum(state) == max(0, operator.total_cap - 1)
    )
    tails = [
        {
            "level_at_least": level,
            "estimate": math.fsum(
                probability
                for state, probability in zip(operator.states, distribution)
                if sum(state) >= level
            ),
        }
        for level in model.options.tail_levels
    ]
    top_indices = sorted(
        range(len(distribution)),
        key=lambda index: (-distribution[index], operator.states[index]),
    )[: model.options.top_state_count]

    result: dict[str, Any] = {
        "total_cap": operator.total_cap,
        "state_count": len(operator.states),
        "empty_probability": distribution[operator.state_index[empty_state]],
        "mean_queue_length_by_node": means,
        "mean_total_jobs": mean_total,
        "second_moment_total_jobs": second_total,
        "variance_total_jobs": variance_total,
        "standard_deviation_total_jobs": math.sqrt(variance_total),
        "moment_roundoff": {
            "raw_variance_total_jobs": raw_variance,
            "variance_roundoff_tolerance": variance_tolerance,
        },
        "mean_busy_servers_by_node": mean_busy_servers,
        "service_completion_rate_by_node": completion_rates,
        "external_departure_rate_by_node": departure_rates,
        "tail_probabilities": tails,
        "boundary": {
            "evidence_kind": "heuristic_truncation_diagnostic",
            "probability_at_total_cap": boundary_mass,
            "probability_at_cap_minus_one": cap_minus_one_mass,
            "suppressed_external_arrival_rate": (
                model.total_external_arrival_rate * boundary_mass
            ),
            "suppressed_fraction_of_external_arrivals": (
                boundary_mass
                if model.total_external_arrival_rate > 0.0
                else 0.0
            ),
            "interpretation": (
                "These are stationary diagnostics of the truncated chain, not "
                "certified error bounds for the original chain."
            ),
        },
        "top_states": [
            {"state": list(operator.states[index]), "probability": distribution[index]}
            for index in top_indices
        ],
    }
    if model.options.include_state_probabilities:
        result["state_probabilities"] = [
            {"state": list(state), "probability": probability}
            for state, probability in zip(operator.states, distribution)
        ]
    return result


def _comparison_vector(summary: dict[str, Any]) -> Vector:
    return [
        summary["empty_probability"],
        summary["mean_total_jobs"],
        summary["second_moment_total_jobs"],
        *summary["mean_queue_length_by_node"],
        *(entry["estimate"] for entry in summary["tail_probabilities"]),
    ]


def compare_summaries(previous: dict[str, Any], current: dict[str, Any]) -> dict[str, float]:
    old = _comparison_vector(previous)
    new = _comparison_vector(current)
    differences = [abs(a - b) for a, b in zip(old, new)]
    relative = [
        difference / max(1.0, abs(old[i]), abs(new[i]))
        for i, difference in enumerate(differences)
    ]
    return {
        "maximum_observable_absolute_change": max(differences, default=0.0),
        "maximum_observable_scaled_change": max(relative, default=0.0),
    }


def _conservative_exp_from_log(log_value: float, cap_at_one: bool = False) -> float:
    """Convert a log upper bound without rounding it down to zero."""

    if cap_at_one and log_value >= 0.0:
        return 1.0
    if log_value >= math.log(sys.float_info.max):
        return math.inf
    if log_value <= math.log(sys.float_info.min):
        value = sys.float_info.min
    else:
        value = math.exp(log_value)
    value = math.nextafter(value, math.inf)
    return min(1.0, value) if cap_at_one else value


def foster_lyapunov_certificate(
    model: NetworkModel, total_cap: int
) -> dict[str, Any]:
    assumptions = [
        "V(x) = exp(theta * total_jobs)",
        "internal routing does not change total_jobs",
        "all event rates are bounded because every node has finitely many servers",
        "whenever total_jobs > 0, at least one server is active",
        "the certificate concerns the original untruncated CTMC",
    ]
    arrival = model.total_external_arrival_rate
    direct_departure_hazards = [
        node.service_rate_per_server * model.exit_probabilities[i]
        for i, node in enumerate(model.nodes)
    ]

    if arrival == 0.0:
        return {
            "status": "certified_degenerate_empty_network",
            "certified": True,
            "scope": "original_untruncated_ctmc",
            "assumptions": assumptions,
            "reason": "With no external arrivals and open routing, the unique stationary state is empty.",
            "bounds": {
                "probability_total_jobs_positive_upper": 0.0,
                "mean_total_jobs_upper": 0.0,
                "second_moment_total_jobs_upper": 0.0,
                "probability_outside_selected_cap_upper": 0.0,
                "first_moment_outside_selected_cap_upper": 0.0,
                "second_moment_outside_selected_cap_upper": 0.0,
            },
        }

    minimum_departure = min(direct_departure_hazards)
    drift_margin = minimum_departure - arrival
    arithmetic_guard = 128.0 * sys.float_info.epsilon * max(
        minimum_departure, arrival
    )
    sufficient_condition = drift_margin > arithmetic_guard
    maximum_theta = (
        math.log(minimum_departure) - math.log(arrival)
        if sufficient_condition
        else None
    )
    checks = {
        "total_external_arrival_rate": arrival,
        "direct_departure_hazard_by_nonempty_node": direct_departure_hazards,
        "minimum_direct_departure_hazard": minimum_departure,
        "required_strict_condition": "total_external_arrival_rate < minimum_direct_departure_hazard",
        "raw_drift_margin": drift_margin,
        "floating_point_safety_guard": arithmetic_guard,
        "condition_satisfied_with_safety_guard": sufficient_condition,
        "maximum_admissible_theta_exclusive": maximum_theta,
    }
    if maximum_theta is None:
        return {
            "status": "unavailable",
            "certified": False,
            "scope": "original_untruncated_ctmc",
            "reason_code": "sufficient_total_population_drift_condition_not_met",
            "reason": (
                "The network may still be stable, but this conservative total-population "
                "Lyapunov function cannot prove a tail or moment bound."
            ),
            "checks": checks,
            "assumptions": assumptions,
            "refused_claims": [
                "No certified tail probability is inferred from boundary mass.",
                "No certified truncation error is inferred from successive refinements.",
                "No Foster-Lyapunov moment bound is asserted.",
            ],
        }

    theta = model.options.certificate_theta or min(1.0, 0.5 * maximum_theta)
    if theta >= maximum_theta:
        checks["requested_theta"] = theta
        return {
            "status": "unavailable",
            "certified": False,
            "scope": "original_untruncated_ctmc",
            "reason_code": "certificate_theta_outside_provable_range",
            "reason": "certificate_theta must be strictly below the reported maximum.",
            "checks": checks,
            "assumptions": assumptions,
            "refused_claims": ["No Foster-Lyapunov tail or moment bound is asserted."],
        }

    try:
        exponential_increment = math.expm1(theta)
    except OverflowError:
        exponential_increment = math.inf
    q = math.exp(-theta)
    theta_drift_margin = minimum_departure * q - arrival
    theta_arithmetic_guard = 128.0 * sys.float_info.epsilon * max(
        minimum_departure * q, arrival
    )
    small_set_drift = arrival * exponential_increment
    negative_drift = exponential_increment * theta_drift_margin
    if (
        not math.isfinite(small_set_drift)
        or not math.isfinite(negative_drift)
        or theta_drift_margin <= theta_arithmetic_guard
    ):
        return {
            "status": "unavailable",
            "certified": False,
            "scope": "original_untruncated_ctmc",
            "reason_code": "certificate_arithmetic_not_positive",
            "checks": {
                **checks,
                "theta": theta,
                "theta_drift_margin": theta_drift_margin,
                "theta_floating_point_safety_guard": theta_arithmetic_guard,
            },
            "assumptions": assumptions,
            "refused_claims": ["No Foster-Lyapunov tail or moment bound is asserted."],
        }

    positive_exponential_moment = math.nextafter(
        arrival / theta_drift_margin, math.inf
    )
    if not math.isfinite(positive_exponential_moment):
        return {
            "status": "unavailable",
            "certified": False,
            "scope": "original_untruncated_ctmc",
            "reason_code": "certificate_bound_not_representable",
            "checks": {**checks, "theta": theta},
            "assumptions": assumptions,
            "refused_claims": ["No finite Foster-Lyapunov bound is asserted."],
        }
    log_positive_moment = math.log(positive_exponential_moment)
    tail_levels = sorted(set((*model.options.tail_levels, total_cap + 1)))
    tail_bounds = [
        {
            "level_at_least": level,
            "probability_upper": (
                1.0
                if level == 0
                else _conservative_exp_from_log(
                    log_positive_moment - theta * level, cap_at_one=True
                )
            ),
        }
        for level in tail_levels
    ]
    outside_level = total_cap + 1
    outside_log_bound = log_positive_moment - theta * outside_level
    outside_probability = _conservative_exp_from_log(
        outside_log_bound, cap_at_one=True
    )
    first_factor = (
        total_cap + 1.0 / (1.0 - q)
    )
    second_factor = total_cap * total_cap + (
        (2.0 * outside_level - 1.0) / (1.0 - q)
        + 2.0 * q / (1.0 - q) ** 2
    )
    first_outside = _conservative_exp_from_log(
        outside_log_bound + math.log(first_factor)
    )
    second_outside = _conservative_exp_from_log(
        outside_log_bound + math.log(second_factor)
    )
    mean_upper = _conservative_exp_from_log(
        log_positive_moment + math.log(q) - math.log1p(-q)
    )
    second_moment_upper = _conservative_exp_from_log(
        log_positive_moment
        + math.log(q)
        + math.log1p(q)
        - 2.0 * math.log1p(-q)
    )
    stationary_exponential_moment = math.nextafter(
        1.0 + positive_exponential_moment, math.inf
    )
    if not all(
        math.isfinite(value)
        for value in (
            first_outside,
            second_outside,
            mean_upper,
            second_moment_upper,
            stationary_exponential_moment,
        )
    ):
        return {
            "status": "unavailable",
            "certified": False,
            "scope": "original_untruncated_ctmc",
            "reason_code": "certificate_bound_not_representable",
            "checks": {**checks, "theta": theta},
            "assumptions": assumptions,
            "refused_claims": ["No finite Foster-Lyapunov bound is asserted."],
        }
    return {
        "status": "certified",
        "certified": True,
        "scope": "original_untruncated_ctmc",
        "method": "geometric Foster-Lyapunov drift bound",
        "assumptions": assumptions,
        "checks": {
            **checks,
            "theta": theta,
            "theta_drift_margin": theta_drift_margin,
            "theta_floating_point_safety_guard": theta_arithmetic_guard,
        },
        "drift_inequality": {
            "small_set": "total_jobs = 0",
            "small_set_drift_upper": small_set_drift,
            "negative_drift_coefficient_outside_small_set": negative_drift,
        },
        "bounds": {
            "positive_state_exponential_moment_upper": positive_exponential_moment,
            "stationary_exponential_moment_upper": stationary_exponential_moment,
            "tail_probability_upper": tail_bounds,
            "mean_total_jobs_upper": mean_upper,
            "second_moment_total_jobs_upper": second_moment_upper,
            "probability_outside_selected_cap_upper": outside_probability,
            "log_probability_outside_selected_cap_upper_unclipped": outside_log_bound,
            "first_moment_outside_selected_cap_upper": first_outside,
            "second_moment_outside_selected_cap_upper": second_outside,
        },
        "limitations": [
            "The bounds certify omitted true stationary mass/moments, not the bias of the reflected-chain probabilities inside the cap.",
            "Failure of this sufficient drift condition does not imply instability.",
        ],
    }


def next_cap(current: int, options: SolverOptions) -> int:
    grown = max(
        current + options.minimum_cap_increment,
        int(math.ceil(current * options.growth_factor)),
    )
    return min(options.max_total_cap, grown)


def solve(model: NetworkModel) -> dict[str, Any]:
    stability = traffic_and_stability(model)
    cap = model.options.initial_total_cap
    history: list[dict[str, Any]] = []
    previous_summary: dict[str, Any] | None = None
    warm_start: dict[State, float] | None = None
    final_summary: dict[str, Any] | None = None
    final_operator: SparseUniformizedOperator | None = None
    final_distribution: Vector | None = None
    final_stationary_diagnostics: dict[str, Any] | None = None
    heuristic_converged = False
    termination_reason = "max_total_cap_reached"

    while True:
        operator = build_operator(model, cap)
        distribution, stationary_diagnostics = stationary_distribution(
            operator, model.options, warm_start
        )
        summary = summarize(model, operator, distribution)
        comparison = (
            None
            if previous_summary is None
            else compare_summaries(previous_summary, summary)
        )
        boundary_ok = (
            summary["boundary"]["probability_at_total_cap"]
            <= model.options.boundary_mass_tolerance
        )
        refinement_ok = (
            comparison is not None
            and comparison["maximum_observable_scaled_change"]
            <= model.options.refinement_relative_tolerance
        )
        history.append(
            {
                "total_cap": cap,
                "state_count": len(operator.states),
                "boundary_mass": summary["boundary"]["probability_at_total_cap"],
                "mean_total_jobs": summary["mean_total_jobs"],
                "second_moment_total_jobs": summary["second_moment_total_jobs"],
                "stationary_iterations": stationary_diagnostics["iterations"],
                "uniformized_residual_l1": stationary_diagnostics[
                    "uniformized_residual_l1"
                ],
                "successive_comparison": comparison,
                "boundary_tolerance_met": boundary_ok,
                "refinement_tolerance_met": refinement_ok,
            }
        )
        final_summary = summary
        final_operator = operator
        final_distribution = distribution
        final_stationary_diagnostics = stationary_diagnostics

        if boundary_ok and refinement_ok:
            heuristic_converged = True
            termination_reason = "heuristic_tolerances_met"
            break
        if cap >= model.options.max_total_cap:
            termination_reason = "max_total_cap_reached"
            break
        proposed = next_cap(cap, model.options)
        required = state_count(model.dimension, proposed)
        if required > model.options.max_states:
            termination_reason = "max_states_prevented_next_refinement"
            break
        warm_start = {
            state: distribution[index] for index, state in enumerate(operator.states)
        }
        previous_summary = summary
        cap = proposed

    assert final_summary is not None
    assert final_operator is not None
    assert final_distribution is not None
    assert final_stationary_diagnostics is not None
    certificate = foster_lyapunov_certificate(model, final_operator.total_cap)
    result: dict[str, Any] = {
        "schema_version": 1,
        "solver_version": "1.0.0",
        "status": "ok",
        "process": "open_single_class_markovian_network",
        "network": {
            "node_names": [node.name for node in model.nodes],
            "node_count": model.dimension,
        },
        "stability": stability,
        "approximation": {
            "method": "adaptive_total_population_truncation_with_suppressed_boundary_arrivals",
            "evidence_kind": "heuristic_convergence_evidence",
            "heuristic_converged": heuristic_converged,
            "termination_reason": termination_reason,
            "selected_total_cap": final_operator.total_cap,
            "selected_state_count": len(final_operator.states),
            "claim": (
                "Successive-truncation agreement and small truncated boundary mass are diagnostics, not a proof of approximation error."
            ),
            "heuristic_criteria": {
                "boundary_mass_tolerance": model.options.boundary_mass_tolerance,
                "successive_refinement_scaled_tolerance": model.options.refinement_relative_tolerance,
                "both_required_after_at_least_two_truncations": True,
            },
            "performance": final_summary,
        },
        "refinement_history": history,
        "certificates": {"foster_lyapunov": certificate},
        "diagnostics": {
            "stationary_solver": final_stationary_diagnostics,
            "state_count_formula": "binomial(total_cap + node_count, node_count)",
            "truncation_boundary": "sum(queue_lengths) <= total_cap",
            "boundary_rule": "external arrivals at the total-population cap are suppressed",
        },
    }
    if model.name:
        result["name"] = model.name
    return result


def solve_document(document: dict[str, Any]) -> dict[str, Any]:
    return solve(parse_model(document))


def load_document(path: str) -> dict[str, Any]:
    try:
        if path == "-":
            document = json.load(sys.stdin)
        else:
            with Path(path).open("r", encoding="utf-8") as handle:
                document = json.load(handle)
    except (json.JSONDecodeError, OSError) as error:
        raise InputError(f"could not read JSON input: {error}") from error
    if not isinstance(document, dict):
        raise InputError("the JSON root must be an object")
    return document


def write_json(payload: dict[str, Any], destination: str | None, pretty: bool) -> None:
    encoded = json.dumps(
        payload, indent=2 if pretty else None, sort_keys=True, allow_nan=False
    )
    if destination:
        try:
            Path(destination).write_text(encoded + "\n", encoding="utf-8")
        except OSError as error:
            raise InputError(f"could not write {destination}: {error}") from error
    else:
        print(encoded)


def write_human(payload: dict[str, Any], destination: str | None) -> None:
    """Emit stable semantic rows for people and Qnet's result parser."""
    approximation = payload["approximation"]
    performance = approximation["performance"]
    stability = payload["stability"]
    solver = payload["diagnostics"]["stationary_solver"]
    names = payload["network"]["node_names"]
    means = performance["mean_queue_length_by_node"]
    utilizations = stability["utilization_by_node"]
    departures = performance["external_departure_rate_by_node"]
    lines = [
        "Adaptive truncated CTMC",
        "Model layer: queueing process",
        "Evidence: truncation diagnostics are heuristic; certificates are identified separately",
        f"Heuristic converged: {'yes' if approximation['heuristic_converged'] else 'no'}",
        f"Selected total cap: {approximation['selected_total_cap']}",
        f"Selected states: {approximation['selected_state_count']}",
        "",
    ]
    for index, name in enumerate(names, 1):
        lines.append(
            f"Node {index} {name}: E[N]={means[index - 1]:.12g} "
            f"utilization={utilizations[index - 1]:.12g} "
            f"departure={departures[index - 1]:.12g}"
        )
    boundary = performance["boundary"]
    comparison = payload["refinement_history"][-1].get("successive_comparison")
    lines.extend([
        "",
        f"generator residual = {solver['generator_residual_l1']:.12g}",
        f"truncation boundary mass = {boundary['probability_at_total_cap']:.12g}",
    ])
    if comparison is not None:
        lines.append(
            "successive refinement relative change = "
            f"{comparison['maximum_observable_scaled_change']:.12g}"
        )
    certificate = payload["certificates"]["foster_lyapunov"]
    if certificate.get("certified"):
        bounds = certificate["bounds"]
        lines.append("Foster-Lyapunov certificate: certified")
        lines.append(f"certified E[N] upper bound = {bounds['mean_total_jobs_upper']:.12g}")
        lines.append(
            "certified probability outside selected cap upper bound = "
            f"{bounds['probability_outside_selected_cap_upper']:.12g}"
        )
    else:
        lines.append("Foster-Lyapunov certificate: unavailable for this model")
    text = "\n".join(lines) + "\n"
    if destination:
        try:
            Path(destination).write_text(text, encoding="utf-8")
        except OSError as error:
            raise InputError(f"could not write {destination}: {error}") from error
    else:
        print(text, end="")


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Adaptively truncate an open single-class Markovian queueing-network CTMC."
    )
    parser.add_argument("input", help="input JSON file, or '-' for stdin")
    parser.add_argument("-o", "--output", help="write JSON output to this file")
    parser.add_argument("--compact", action="store_true", help="emit compact JSON")
    parser.add_argument("--human", action="store_true", help="emit concise semantic text rows")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = argument_parser().parse_args(argv)
    try:
        payload = solve_document(load_document(args.input))
        if args.human:
            write_human(payload, args.output)
        else:
            write_json(payload, args.output, pretty=not args.compact)
        return 0
    except TruncatedCTMCError as error:
        payload = {
            "schema_version": 1,
            "solver_version": "1.0.0",
            "status": "error",
            "error": {"code": error.code, "message": str(error), **error.details},
        }
        try:
            write_json(payload, args.output, pretty=not args.compact)
        except TruncatedCTMCError:
            print(json.dumps(payload, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
