#!/usr/bin/env python3
"""Regenerative steady-state simulation for a documented Jackson-network class.

The module intentionally uses only the Python standard library.  Complete
empty-to-empty regenerative cycles, rather than individual events or time
samples, are the independent observations used by its uncertainty estimates.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote


MASK64 = (1 << 64) - 1
GOLDEN64 = 0x9E3779B97F4A7C15


class SimulationError(Exception):
    """Base class for errors intended for structured presentation."""

    code = "simulation_error"

    def __init__(self, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.details = details or {}


class InputError(SimulationError):
    code = "invalid_input"


class StabilityError(SimulationError):
    code = "stability_check_failed"


class CycleLimitError(SimulationError):
    code = "cycle_safeguard_exceeded"


@dataclass(frozen=True)
class Node:
    identifier: str
    servers: int
    service_rate: float
    capacity: int | None


@dataclass(frozen=True)
class CustomerClass:
    identifier: str
    external_rates: tuple[float, ...]
    routing: tuple[tuple[float, ...], ...]


@dataclass(frozen=True)
class StoppingOptions:
    confidence: float
    absolute_half_width: float
    relative_half_width: float
    monitored_metrics: tuple[str, ...]
    minimum_cycles: int
    minimum_effective_cycles: float
    minimum_positive_cycles: int
    check_every_cycles: int
    maximum_cycles: int
    maximum_events: int
    maximum_simulated_time: float
    maximum_cycle_time: float
    maximum_events_per_cycle: int
    maximum_wall_seconds: float


@dataclass(frozen=True)
class RareEventOptions:
    method: str
    arrival_rate_multiplier: float = 1.0
    service_rate_multiplier: float = 1.0


@dataclass(frozen=True)
class Model:
    name: str
    nodes: tuple[Node, ...]
    classes: tuple[CustomerClass, ...]
    initial_jobs: tuple[tuple[int, ...], ...]
    base_seed: int
    stream: int
    stopping: StoppingOptions
    rare_event: RareEventOptions
    traffic_rates: tuple[tuple[float, ...], ...]
    offered_loads: tuple[float, ...]
    finite_buffers: bool


@dataclass(frozen=True)
class MetricDefinition:
    key: str
    description: str
    numerator_key: str
    denominator_key: str
    denominator_multiplier: float = 1.0
    lower_bound: float | None = 0.0
    upper_bound: float | None = None
    event_probability: bool = False


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _finite_float(value: Any, path: str) -> float:
    if not _is_number(value):
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


def _positive_int(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise InputError(f"{path} must be a positive integer")
    return value


def _nonnegative_int(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InputError(f"{path} must be a nonnegative integer")
    return value


def _mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InputError(f"{path} must be a JSON object")
    return value


def _check_unknown(mapping: dict[str, Any], allowed: set[str], path: str) -> None:
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        raise InputError(f"{path} contains unknown field(s): {', '.join(unknown)}")


def _solve_linear(matrix: list[list[float]], rhs: list[float]) -> list[float]:
    """Dense scaled-partial-pivot solve used by the traffic equations."""

    n = len(matrix)
    if n == 0 or len(rhs) != n or any(len(row) != n for row in matrix):
        raise InputError("traffic equation is not square")
    augmented = [list(matrix[i]) + [rhs[i]] for i in range(n)]
    scales = [max(abs(value) for value in row) for row in matrix]
    if any(scale == 0.0 for scale in scales):
        raise InputError("routing matrix has a closed class (singular traffic equations)")
    for column in range(n):
        pivot = max(
            range(column, n),
            key=lambda row: abs(augmented[row][column]) / scales[row],
        )
        floor = 16.0 * sys.float_info.epsilon * n * scales[pivot]
        if abs(augmented[pivot][column]) <= floor:
            raise InputError("routing matrix has a closed or numerically singular class")
        if pivot != column:
            augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
            scales[column], scales[pivot] = scales[pivot], scales[column]
        pivot_value = augmented[column][column]
        for row in range(column + 1, n):
            factor = augmented[row][column] / pivot_value
            augmented[row][column] = 0.0
            for j in range(column + 1, n + 1):
                augmented[row][j] -= factor * augmented[column][j]
    answer = [0.0] * n
    for row in range(n - 1, -1, -1):
        remainder = augmented[row][n] - math.fsum(
            augmented[row][j] * answer[j] for j in range(row + 1, n)
        )
        answer[row] = remainder / augmented[row][row]
    return answer


def _traffic_rates(customer: CustomerClass) -> tuple[float, ...]:
    count = len(customer.external_rates)
    equations = [
        [
            (1.0 if i == j else 0.0) - customer.routing[j][i]
            for j in range(count)
        ]
        for i in range(count)
    ]
    rates = _solve_linear(equations, list(customer.external_rates))
    tolerance = 2.0e-11 * max(1.0, max(rates, default=0.0))
    if min(rates, default=0.0) < -tolerance:
        raise InputError(
            f"traffic equations for class {customer.identifier!r} produced a negative rate"
        )
    rates = [max(0.0, value) for value in rates]
    residual = max(
        (
            abs(
                rates[i]
                - customer.external_rates[i]
                - math.fsum(rates[j] * customer.routing[j][i] for j in range(count))
            )
            for i in range(count)
        ),
        default=0.0,
    )
    if residual > tolerance:
        raise InputError(
            f"traffic equations for class {customer.identifier!r} are ill-conditioned",
            {"residual": residual, "tolerance": tolerance},
        )
    return tuple(rates)


def _all_nodes_reach_exit(customer: CustomerClass) -> bool:
    count = len(customer.routing)
    exit_nodes = {
        i for i, row in enumerate(customer.routing) if math.fsum(row) < 1.0 - 1.0e-14
    }
    can_exit = set(exit_nodes)
    changed = True
    while changed:
        changed = False
        for source, row in enumerate(customer.routing):
            if source in can_exit:
                continue
            if any(probability > 0.0 and destination in can_exit for destination, probability in enumerate(row)):
                can_exit.add(source)
                changed = True
    return len(can_exit) == count


def _splitmix64(value: int) -> int:
    value = (value + GOLDEN64) & MASK64
    value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
    return (value ^ (value >> 31)) & MASK64


def derive_seed(base_seed: int, stream: int, component: int) -> int:
    value = (base_seed + GOLDEN64 * (stream + 1) + component) & MASK64
    return _splitmix64(value)


def parse_model(document: dict[str, Any]) -> Model:
    if not isinstance(document, dict):
        raise InputError("the JSON root must be an object")
    _check_unknown(
        document,
        {
            "schema_version",
            "process",
            "name",
            "nodes",
            "classes",
            "initial_jobs",
            "random",
            "stopping",
            "rare_event",
        },
        "root",
    )
    if document.get("schema_version", 1) != 1:
        raise InputError("only schema_version 1 is supported")
    if document.get("process", "open_markovian_queueing_network") != "open_markovian_queueing_network":
        raise InputError("process must be 'open_markovian_queueing_network'")
    name = document.get("name", "open Markovian queueing network")
    if not isinstance(name, str) or not name.strip():
        raise InputError("name must be a nonempty string")

    nodes_document = document.get("nodes")
    if not isinstance(nodes_document, list) or not nodes_document:
        raise InputError("nodes must be a nonempty array")
    nodes: list[Node] = []
    node_index: dict[str, int] = {}
    for index, raw in enumerate(nodes_document):
        mapping = _mapping(raw, f"nodes[{index}]")
        _check_unknown(mapping, {"id", "servers", "service_rate", "capacity"}, f"nodes[{index}]")
        identifier = mapping.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InputError(f"nodes[{index}].id must be a nonempty string")
        if identifier in node_index:
            raise InputError(f"duplicate node id {identifier!r}")
        servers = _positive_int(mapping.get("servers", 1), f"nodes[{index}].servers")
        service_rate = _positive_float(mapping.get("service_rate"), f"nodes[{index}].service_rate")
        capacity_value = mapping.get("capacity")
        if capacity_value is None:
            capacity = None
        else:
            capacity = _positive_int(capacity_value, f"nodes[{index}].capacity")
            if capacity < servers:
                raise InputError(f"nodes[{index}].capacity must be at least servers")
        node_index[identifier] = index
        nodes.append(Node(identifier, servers, service_rate, capacity))

    finite_flags = {node.capacity is not None for node in nodes}
    if len(finite_flags) != 1:
        raise InputError("mixed finite- and infinite-buffer nodes are outside the supported class")
    finite_buffers = True in finite_flags

    classes_document = document.get("classes")
    if not isinstance(classes_document, list) or not classes_document:
        raise InputError("classes must be a nonempty array")
    classes: list[CustomerClass] = []
    class_index: dict[str, int] = {}
    for index, raw in enumerate(classes_document):
        mapping = _mapping(raw, f"classes[{index}]")
        _check_unknown(mapping, {"id", "external_arrival_rates", "routing"}, f"classes[{index}]")
        identifier = mapping.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InputError(f"classes[{index}].id must be a nonempty string")
        if identifier in class_index:
            raise InputError(f"duplicate class id {identifier!r}")

        external_document = _mapping(
            mapping.get("external_arrival_rates", {}),
            f"classes[{index}].external_arrival_rates",
        )
        unknown_nodes = sorted(set(external_document) - set(node_index))
        if unknown_nodes:
            raise InputError(
                f"classes[{index}].external_arrival_rates names unknown nodes: "
                + ", ".join(unknown_nodes)
            )
        external = [0.0] * len(nodes)
        for node_id, value in external_document.items():
            external[node_index[node_id]] = _nonnegative_float(
                value, f"classes[{index}].external_arrival_rates.{node_id}"
            )

        routing_document = _mapping(mapping.get("routing", {}), f"classes[{index}].routing")
        unknown_sources = sorted(set(routing_document) - set(node_index))
        if unknown_sources:
            raise InputError(
                f"classes[{index}].routing names unknown source nodes: "
                + ", ".join(unknown_sources)
            )
        routing: list[tuple[float, ...]] = []
        for source_node in nodes:
            raw_row = routing_document.get(source_node.identifier, {})
            row_document = _mapping(
                raw_row, f"classes[{index}].routing.{source_node.identifier}"
            )
            unknown_destinations = sorted(set(row_document) - set(node_index))
            if unknown_destinations:
                raise InputError(
                    f"classes[{index}].routing.{source_node.identifier} names unknown destinations: "
                    + ", ".join(unknown_destinations)
                )
            row = [0.0] * len(nodes)
            for destination, value in row_document.items():
                probability = _nonnegative_float(
                    value,
                    f"classes[{index}].routing.{source_node.identifier}.{destination}",
                )
                if probability > 1.0:
                    raise InputError("routing probabilities cannot exceed one")
                row[node_index[destination]] = probability
            row_sum = math.fsum(row)
            if row_sum > 1.0 + 1.0e-12:
                raise InputError(
                    f"routing row for class {identifier!r} at node "
                    f"{source_node.identifier!r} sums to {row_sum}, greater than one"
                )
            if row_sum > 1.0:
                row = [value / row_sum for value in row]
            routing.append(tuple(row))

        customer = CustomerClass(identifier, tuple(external), tuple(routing))
        if not _all_nodes_reach_exit(customer):
            raise InputError(
                f"every node in class {identifier!r} routing must have a path to exit"
            )
        class_index[identifier] = index
        classes.append(customer)

    if math.fsum(rate for customer in classes for rate in customer.external_rates) <= 0.0:
        raise InputError("at least one positive external arrival rate is required")

    initial_document = _mapping(document.get("initial_jobs", {}), "initial_jobs")
    unknown_initial_nodes = sorted(set(initial_document) - set(node_index))
    if unknown_initial_nodes:
        raise InputError("initial_jobs names unknown nodes: " + ", ".join(unknown_initial_nodes))
    initial = [[0 for _ in classes] for _ in nodes]
    for node_id, raw_counts in initial_document.items():
        counts_document = _mapping(raw_counts, f"initial_jobs.{node_id}")
        unknown_classes = sorted(set(counts_document) - set(class_index))
        if unknown_classes:
            raise InputError(
                f"initial_jobs.{node_id} names unknown classes: " + ", ".join(unknown_classes)
            )
        for class_id, value in counts_document.items():
            initial[node_index[node_id]][class_index[class_id]] = _nonnegative_int(
                value, f"initial_jobs.{node_id}.{class_id}"
            )
    for node, counts in zip(nodes, initial):
        if node.capacity is not None and sum(counts) > node.capacity:
            raise InputError(f"initial_jobs at node {node.identifier!r} exceed its capacity")

    random_document = _mapping(document.get("random", {}), "random")
    _check_unknown(random_document, {"base_seed", "stream"}, "random")
    base_seed = _nonnegative_int(random_document.get("base_seed", 20260904), "random.base_seed")
    stream = _nonnegative_int(random_document.get("stream", 0), "random.stream")
    if base_seed > MASK64 or stream > MASK64:
        raise InputError("random.base_seed and random.stream must fit in an unsigned 64-bit integer")

    stop_document = _mapping(document.get("stopping", {}), "stopping")
    _check_unknown(
        stop_document,
        {
            "confidence",
            "absolute_half_width",
            "relative_half_width",
            "monitored_metrics",
            "minimum_cycles",
            "minimum_effective_cycles",
            "minimum_positive_cycles",
            "check_every_cycles",
            "maximum_cycles",
            "maximum_events",
            "maximum_simulated_time",
            "maximum_cycle_time",
            "maximum_events_per_cycle",
            "maximum_wall_seconds",
        },
        "stopping",
    )
    confidence = _finite_float(stop_document.get("confidence", 0.95), "stopping.confidence")
    if not 0.5 < confidence < 1.0:
        raise InputError("stopping.confidence must be between 0.5 and 1")
    absolute_half_width = _nonnegative_float(
        stop_document.get("absolute_half_width", 0.02),
        "stopping.absolute_half_width",
    )
    relative_half_width = _nonnegative_float(
        stop_document.get("relative_half_width", 0.05),
        "stopping.relative_half_width",
    )
    if absolute_half_width == 0.0 and relative_half_width == 0.0:
        raise InputError("at least one stopping half-width target must be positive")
    monitored_raw = stop_document.get("monitored_metrics", ["mean_number_in_system"])
    if (
        not isinstance(monitored_raw, list)
        or not monitored_raw
        or any(not isinstance(value, str) or not value for value in monitored_raw)
        or len(set(monitored_raw)) != len(monitored_raw)
    ):
        raise InputError("stopping.monitored_metrics must be a nonempty array of unique strings")
    minimum_cycles = _positive_int(stop_document.get("minimum_cycles", 200), "stopping.minimum_cycles")
    if minimum_cycles < 30:
        raise InputError("stopping.minimum_cycles must be at least 30 for the regenerative t interval")
    minimum_effective_cycles = _positive_float(
        stop_document.get("minimum_effective_cycles", 30.0),
        "stopping.minimum_effective_cycles",
    )
    if minimum_effective_cycles > minimum_cycles:
        raise InputError("minimum_effective_cycles cannot exceed minimum_cycles")
    minimum_positive_cycles = _positive_int(
        stop_document.get("minimum_positive_cycles", 5),
        "stopping.minimum_positive_cycles",
    )
    check_every = _positive_int(
        stop_document.get("check_every_cycles", 50),
        "stopping.check_every_cycles",
    )
    maximum_cycles = _positive_int(
        stop_document.get("maximum_cycles", 100_000),
        "stopping.maximum_cycles",
    )
    if maximum_cycles < minimum_cycles:
        raise InputError("stopping.maximum_cycles cannot be less than minimum_cycles")
    stopping = StoppingOptions(
        confidence=confidence,
        absolute_half_width=absolute_half_width,
        relative_half_width=relative_half_width,
        monitored_metrics=tuple(monitored_raw),
        minimum_cycles=minimum_cycles,
        minimum_effective_cycles=minimum_effective_cycles,
        minimum_positive_cycles=minimum_positive_cycles,
        check_every_cycles=check_every,
        maximum_cycles=maximum_cycles,
        maximum_events=_positive_int(
            stop_document.get("maximum_events", 10_000_000), "stopping.maximum_events"
        ),
        maximum_simulated_time=_positive_float(
            stop_document.get("maximum_simulated_time", 1.0e9),
            "stopping.maximum_simulated_time",
        ),
        maximum_cycle_time=_positive_float(
            stop_document.get("maximum_cycle_time", 1.0e7),
            "stopping.maximum_cycle_time",
        ),
        maximum_events_per_cycle=_positive_int(
            stop_document.get("maximum_events_per_cycle", 2_000_000),
            "stopping.maximum_events_per_cycle",
        ),
        maximum_wall_seconds=_positive_float(
            stop_document.get("maximum_wall_seconds", 120.0),
            "stopping.maximum_wall_seconds",
        ),
    )

    rare_document = _mapping(document.get("rare_event", {}), "rare_event")
    _check_unknown(
        rare_document,
        {"method", "arrival_rate_multiplier", "service_rate_multiplier"},
        "rare_event",
    )
    method = rare_document.get("method", "none")
    if method not in {"none", "importance_sampling_mm1k"}:
        raise InputError("rare_event.method must be 'none' or 'importance_sampling_mm1k'")
    if method == "none" and (
        "arrival_rate_multiplier" in rare_document
        or "service_rate_multiplier" in rare_document
    ):
        raise InputError(
            "rare-event rate multipliers are valid only with importance_sampling_mm1k"
        )
    rare_event = RareEventOptions(method=method)
    if method == "importance_sampling_mm1k":
        rare_event = RareEventOptions(
            method=method,
            arrival_rate_multiplier=_positive_float(
                rare_document.get("arrival_rate_multiplier"),
                "rare_event.arrival_rate_multiplier",
            ),
            service_rate_multiplier=_positive_float(
                rare_document.get("service_rate_multiplier"),
                "rare_event.service_rate_multiplier",
            ),
        )
        if len(nodes) != 1 or len(classes) != 1:
            raise InputError("importance_sampling_mm1k requires exactly one node and one class")
        if nodes[0].servers != 1 or nodes[0].capacity is None:
            raise InputError("importance_sampling_mm1k requires a finite-buffer M/M/1/K node")
        if any(probability != 0.0 for probability in classes[0].routing[0]):
            raise InputError("importance_sampling_mm1k does not permit feedback routing")
        if classes[0].external_rates[0] <= 0.0:
            raise InputError("importance_sampling_mm1k requires a positive arrival rate")

    traffic = tuple(_traffic_rates(customer) for customer in classes)
    offered_loads = tuple(
        math.fsum(traffic[c][n] for c in range(len(classes)))
        / (nodes[n].servers * nodes[n].service_rate)
        for n in range(len(nodes))
    )
    if not finite_buffers:
        unstable = [
            {
                "node": node.identifier,
                "offered_load": offered_loads[i],
                "required": "strictly less than 1",
            }
            for i, node in enumerate(nodes)
            if offered_loads[i] >= 1.0 - 1.0e-12
        ]
        if unstable:
            raise StabilityError(
                "infinite-buffer network fails the Jackson load condition",
                {"unstable_nodes": unstable},
            )

    model = Model(
        name=name,
        nodes=tuple(nodes),
        classes=tuple(classes),
        initial_jobs=tuple(tuple(row) for row in initial),
        base_seed=base_seed,
        stream=stream,
        stopping=stopping,
        rare_event=rare_event,
        traffic_rates=traffic,
        offered_loads=offered_loads,
        finite_buffers=finite_buffers,
    )
    known_metrics = {definition.key for definition in metric_definitions(model)}
    unknown_metrics = sorted(set(stopping.monitored_metrics) - known_metrics)
    if unknown_metrics:
        raise InputError(
            "stopping.monitored_metrics contains unknown metric(s): "
            + ", ".join(unknown_metrics),
            {"available_metrics": sorted(known_metrics)},
        )
    return model


def metric_definitions(model: Model) -> list[MetricDefinition]:
    definitions = [
        MetricDefinition(
            "mean_number_in_system",
            "time-average jobs in the complete network",
            "area.system",
            "time",
        ),
        MetricDefinition(
            "external_offered_rate",
            "external arrival attempts per unit time",
            "count.external.offered",
            "time",
        ),
        MetricDefinition(
            "external_accepted_rate",
            "accepted external arrivals per unit time",
            "count.external.accepted",
            "time",
        ),
        MetricDefinition(
            "external_blocking_rate",
            "blocked external arrivals per unit time",
            "count.external.blocked",
            "time",
        ),
        MetricDefinition(
            "external_blocking_probability",
            "blocked fraction of external arrival attempts",
            "count.external.blocked",
            "count.external.offered",
            upper_bound=1.0,
            event_probability=True,
        ),
        MetricDefinition(
            "routed_blocking_probability",
            "blocked fraction of internal routing attempts",
            "count.routed.blocked",
            "count.routed.offered",
            upper_bound=1.0,
            event_probability=True,
        ),
        MetricDefinition(
            "departure_rate",
            "accepted jobs leaving by normal exit or routed-arrival loss per unit time",
            "count.departure",
            "time",
        ),
        MetricDefinition(
            "normal_exit_rate",
            "jobs taking a normal post-service network exit per unit time",
            "count.exit",
            "time",
        ),
        MetricDefinition(
            "routed_loss_rate",
            "jobs lost on arrival to a full routed destination per unit time",
            "count.routed.blocked",
            "time",
        ),
    ]
    for node in model.nodes:
        node_id = node.identifier
        definitions.extend(
            [
                MetricDefinition(
                    f"mean_number_at_node:{node_id}",
                    f"time-average jobs at node {node_id}",
                    f"area.node.{node_id}",
                    "time",
                ),
                MetricDefinition(
                    f"mean_queue_at_node:{node_id}",
                    f"time-average waiting jobs at node {node_id}",
                    f"area.queue.{node_id}",
                    "time",
                ),
                MetricDefinition(
                    f"utilization:{node_id}",
                    f"mean busy fraction of the {node.servers} server(s) at node {node_id}",
                    f"area.busy.{node_id}",
                    "time",
                    denominator_multiplier=float(node.servers),
                    upper_bound=1.0,
                ),
                MetricDefinition(
                    f"service_completion_rate:{node_id}",
                    f"service completions at node {node_id} per unit time",
                    f"count.service.{node_id}",
                    "time",
                ),
            ]
        )
    for customer in model.classes:
        class_id = customer.identifier
        definitions.extend(
            [
                MetricDefinition(
                    f"mean_number_class:{class_id}",
                    f"time-average class {class_id} jobs in the network",
                    f"area.class.{class_id}",
                    "time",
                ),
                MetricDefinition(
                    f"external_offered_rate_class:{class_id}",
                    f"class {class_id} external arrival attempts per unit time",
                    f"count.external.offered.class.{class_id}",
                    "time",
                ),
                MetricDefinition(
                    f"external_accepted_rate_class:{class_id}",
                    f"accepted class {class_id} external arrivals per unit time",
                    f"count.external.accepted.class.{class_id}",
                    "time",
                ),
                MetricDefinition(
                    f"external_blocking_rate_class:{class_id}",
                    f"blocked class {class_id} external arrivals per unit time",
                    f"count.external.blocked.class.{class_id}",
                    "time",
                ),
                MetricDefinition(
                    f"external_blocking_probability_class:{class_id}",
                    f"blocked fraction of class {class_id} external arrivals",
                    f"count.external.blocked.class.{class_id}",
                    f"count.external.offered.class.{class_id}",
                    upper_bound=1.0,
                    event_probability=True,
                ),
                MetricDefinition(
                    f"departure_rate_class:{class_id}",
                    f"accepted class {class_id} jobs leaving by exit or routed loss per unit time",
                    f"count.departure.class.{class_id}",
                    "time",
                ),
                MetricDefinition(
                    f"normal_exit_rate_class:{class_id}",
                    f"class {class_id} normal post-service exits per unit time",
                    f"count.exit.class.{class_id}",
                    "time",
                ),
            ]
        )
        for node in model.nodes:
            definitions.append(
                MetricDefinition(
                    f"mean_number:{node.identifier}:{class_id}",
                    f"time-average class {class_id} jobs at node {node.identifier}",
                    f"area.node_class.{node.identifier}.{class_id}",
                    "time",
                )
            )
    return definitions


def _continued_fraction_beta(a: float, b: float, x: float) -> float:
    maximum_iterations = 300
    epsilon = 3.0e-14
    tiny = sys.float_info.min / epsilon
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < tiny:
        d = tiny
    d = 1.0 / d
    result = d
    for iteration in range(1, maximum_iterations + 1):
        m2 = 2 * iteration
        aa = iteration * (b - iteration) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        result *= d * c
        aa = -(a + iteration) * (qab + iteration) * x / (
            (a + m2) * (qap + m2)
        )
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        delta = d * c
        result *= delta
        if abs(delta - 1.0) <= epsilon:
            return result
    raise SimulationError("incomplete-beta continued fraction did not converge")


def regularized_incomplete_beta(a: float, b: float, x: float) -> float:
    if a <= 0.0 or b <= 0.0 or not 0.0 <= x <= 1.0:
        raise InputError("invalid incomplete-beta arguments")
    if x == 0.0:
        return 0.0
    if x == 1.0:
        return 1.0
    front = math.exp(
        math.lgamma(a + b)
        - math.lgamma(a)
        - math.lgamma(b)
        + a * math.log(x)
        + b * math.log1p(-x)
    )
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _continued_fraction_beta(a, b, x) / a
    return 1.0 - front * _continued_fraction_beta(b, a, 1.0 - x) / b


def student_t_cdf(value: float, degrees_freedom: int) -> float:
    if degrees_freedom <= 0:
        raise InputError("Student t degrees of freedom must be positive")
    if value == 0.0:
        return 0.5
    x = degrees_freedom / (degrees_freedom + value * value)
    tail_twice = regularized_incomplete_beta(degrees_freedom / 2.0, 0.5, x)
    if value > 0.0:
        return 1.0 - 0.5 * tail_twice
    return 0.5 * tail_twice


def student_t_quantile(probability: float, degrees_freedom: int) -> float:
    if not 0.0 < probability < 1.0:
        raise InputError("Student t probability must be strictly between zero and one")
    if probability == 0.5:
        return 0.0
    if probability < 0.5:
        return -student_t_quantile(1.0 - probability, degrees_freedom)
    lower = 0.0
    upper = 1.0
    while student_t_cdf(upper, degrees_freedom) < probability:
        upper *= 2.0
        if upper > 1.0e12:
            return math.inf
    for _ in range(100):
        middle = (lower + upper) / 2.0
        if student_t_cdf(middle, degrees_freedom) < probability:
            lower = middle
        else:
            upper = middle
    return (lower + upper) / 2.0


class RatioAccumulator:
    """Sufficient statistics for a ratio of weighted regenerative means."""

    def __init__(self, definition: MetricDefinition):
        self.definition = definition
        self.cycles = 0
        self.sum_a = 0.0
        self.sum_b = 0.0
        self.sum_a2 = 0.0
        self.sum_b2 = 0.0
        self.sum_ab = 0.0
        self.max_b = 0.0
        self.raw_sum_y = 0.0
        self.raw_sum_d = 0.0
        self.denominator_positive_cycles = 0
        self.numerator_positive_cycles = 0

    def rescale(self, factor: float) -> None:
        factor2 = factor * factor
        self.sum_a *= factor
        self.sum_b *= factor
        self.sum_a2 *= factor2
        self.sum_b2 *= factor2
        self.sum_ab *= factor2
        self.max_b *= factor

    def add(self, weight: float, numerator: float, denominator: float) -> None:
        a = weight * numerator
        b = weight * denominator
        self.cycles += 1
        self.sum_a += a
        self.sum_b += b
        self.sum_a2 += a * a
        self.sum_b2 += b * b
        self.sum_ab += a * b
        self.max_b = max(self.max_b, b)
        self.raw_sum_y += numerator
        self.raw_sum_d += denominator
        if denominator > 0.0:
            self.denominator_positive_cycles += 1
        if numerator > 0.0:
            self.numerator_positive_cycles += 1

    def core(self) -> dict[str, Any]:
        if self.cycles < 1 or self.sum_b <= 0.0:
            return {
                "available": False,
                "cycles": self.cycles,
                "reason": "no positive denominator reward was observed",
                "observed_numerator_total": self.raw_sum_y,
                "observed_denominator_total": self.raw_sum_d,
            }
        estimate = self.sum_a / self.sum_b
        effective = self.sum_b * self.sum_b / self.sum_b2 if self.sum_b2 > 0.0 else 0.0
        z_squares = (
            self.sum_a2
            - 2.0 * estimate * self.sum_ab
            + estimate * estimate * self.sum_b2
        )
        roundoff = 128.0 * sys.float_info.epsilon * max(
            1.0,
            abs(self.sum_a2),
            abs(2.0 * estimate * self.sum_ab),
            abs(estimate * estimate * self.sum_b2),
        )
        if z_squares < 0.0 and abs(z_squares) <= roundoff:
            z_squares = 0.0
        if z_squares < 0.0:
            raise SimulationError(
                f"negative regenerative variance for metric {self.definition.key}",
                {"centered_sum_squares": z_squares},
            )
        if self.cycles >= 2:
            standard_error = math.sqrt(
                self.cycles * z_squares / (self.cycles - 1)
            ) / self.sum_b
            centered_variance = z_squares / (self.cycles - 1)
        else:
            standard_error = None
            centered_variance = None
        return {
            "available": True,
            "estimate": estimate,
            "cycles": self.cycles,
            "standard_error": standard_error,
            "centered_cycle_variance_scaled": centered_variance,
            "effective_cycles": effective,
            "largest_denominator_weight_fraction": self.max_b / self.sum_b,
            "denominator_positive_cycles": self.denominator_positive_cycles,
            "numerator_positive_cycles": self.numerator_positive_cycles,
            "observed_numerator_total": self.raw_sum_y,
            "observed_denominator_total": self.raw_sum_d,
        }

    def summary(self, confidence: float) -> dict[str, Any]:
        result = self.core()
        result["description"] = self.definition.description
        if not result["available"] or result["standard_error"] is None:
            result["confidence_interval"] = None
            return result
        critical = student_t_quantile(
            0.5 + confidence / 2.0, self.cycles - 1
        )
        half_width = critical * result["standard_error"]
        raw_low = result["estimate"] - half_width
        raw_high = result["estimate"] + half_width
        low = raw_low
        high = raw_high
        if self.definition.lower_bound is not None:
            low = max(self.definition.lower_bound, low)
        if self.definition.upper_bound is not None:
            high = min(self.definition.upper_bound, high)
        result["confidence_interval"] = {
            "method": "regenerative_ratio_student_t_asymptotic",
            "confidence": confidence,
            "critical_value": critical,
            "half_width": half_width,
            "low": low,
            "high": high,
            "raw_low": raw_low,
            "raw_high": raw_high,
        }
        return result


class RegenerativeEstimator:
    def __init__(self, definitions: Iterable[MetricDefinition]):
        self.accumulators = {
            definition.key: RatioAccumulator(definition) for definition in definitions
        }
        self.cycles = 0
        self.log_weight_scale: float | None = None
        self.sum_weight = 0.0
        self.sum_weight2 = 0.0
        self.max_weight = 0.0
        self.minimum_log_weight = math.inf
        self.maximum_log_weight = -math.inf

    def _rescale(self, factor: float) -> None:
        factor2 = factor * factor
        for accumulator in self.accumulators.values():
            accumulator.rescale(factor)
        self.sum_weight *= factor
        self.sum_weight2 *= factor2
        self.max_weight *= factor

    def add_cycle(self, values: dict[str, float], log_weight: float) -> None:
        if not math.isfinite(log_weight):
            raise SimulationError("a cycle likelihood ratio is non-finite")
        if self.log_weight_scale is None:
            self.log_weight_scale = log_weight
        elif log_weight > self.log_weight_scale:
            factor = math.exp(self.log_weight_scale - log_weight)
            self._rescale(factor)
            self.log_weight_scale = log_weight
        weight = math.exp(log_weight - self.log_weight_scale)
        self.cycles += 1
        self.sum_weight += weight
        self.sum_weight2 += weight * weight
        self.max_weight = max(self.max_weight, weight)
        self.minimum_log_weight = min(self.minimum_log_weight, log_weight)
        self.maximum_log_weight = max(self.maximum_log_weight, log_weight)
        for accumulator in self.accumulators.values():
            definition = accumulator.definition
            numerator = values.get(definition.numerator_key, 0.0)
            denominator = (
                values.get(definition.denominator_key, 0.0)
                * definition.denominator_multiplier
            )
            accumulator.add(weight, numerator, denominator)

    def weight_diagnostics(self) -> dict[str, Any]:
        if self.cycles == 0 or self.log_weight_scale is None:
            return {
                "cycles": 0,
                "effective_cycles": 0.0,
                "log_mean_likelihood_ratio": None,
            }
        effective = self.sum_weight * self.sum_weight / self.sum_weight2
        log_mean = self.log_weight_scale + math.log(self.sum_weight / self.cycles)
        cv_squared = self.cycles * self.sum_weight2 / (self.sum_weight * self.sum_weight) - 1.0
        return {
            "cycles": self.cycles,
            "effective_cycles": effective,
            "effective_fraction": effective / self.cycles,
            "largest_normalized_weight": self.max_weight / self.sum_weight,
            "coefficient_of_variation_squared": max(0.0, cv_squared),
            "minimum_log_likelihood_ratio": self.minimum_log_weight,
            "maximum_log_likelihood_ratio": self.maximum_log_weight,
            "log_mean_likelihood_ratio": log_mean,
        }


class RunningMoments:
    def __init__(self) -> None:
        self.count = 0
        self.mean = 0.0
        self.m2 = 0.0
        self.minimum = math.inf
        self.maximum = 0.0

    def add(self, value: float) -> None:
        self.count += 1
        delta = value - self.mean
        self.mean += delta / self.count
        self.m2 += delta * (value - self.mean)
        self.minimum = min(self.minimum, value)
        self.maximum = max(self.maximum, value)

    def summary(self) -> dict[str, Any]:
        return {
            "count": self.count,
            "mean": self.mean if self.count else None,
            "standard_deviation": (
                math.sqrt(max(0.0, self.m2 / (self.count - 1)))
                if self.count >= 2
                else None
            ),
            "minimum": self.minimum if self.count else None,
            "maximum": self.maximum if self.count else None,
        }


class Simulator:
    def __init__(self, model: Model):
        self.model = model
        self.time_seed = derive_seed(model.base_seed, model.stream, 0x54494D45)
        self.choice_seed = derive_seed(model.base_seed, model.stream, 0x43484F49)
        self.time_rng = random.Random(self.time_seed)
        self.choice_rng = random.Random(self.choice_seed)
        self.queues: list[list[int]] = [[] for _ in model.nodes]
        self.counts = [[0 for _ in model.classes] for _ in model.nodes]
        for node_index, class_counts in enumerate(model.initial_jobs):
            for class_index, count in enumerate(class_counts):
                self.queues[node_index].extend([class_index] * count)
                self.counts[node_index][class_index] = count
        self.total_jobs = sum(len(queue) for queue in self.queues)
        self.initial_state_was_regeneration = self.total_jobs == 0
        self.collecting = self.initial_state_was_regeneration
        self.segment_start = 0.0
        self.cycle_values: dict[str, float] = {"time": 0.0}
        self.cycle_log_weight = 0.0
        self.cycle_events = 0
        self.events = 0
        self.time = 0.0
        self.delayed_time = 0.0
        self.discarded_incomplete_cycle = False
        self.estimator = RegenerativeEstimator(metric_definitions(model))
        self.cycle_durations = RunningMoments()
        self.collected_time = 0.0
        self.looks = 0
        self.last_precision: dict[str, Any] | None = None
        self.start_wall = time.monotonic()
        self._external_events = [
            (node_index, class_index, customer.external_rates[node_index])
            for class_index, customer in enumerate(model.classes)
            for node_index in range(len(model.nodes))
            if customer.external_rates[node_index] > 0.0
        ]

    def _increment(self, key: str, amount: float = 1.0) -> None:
        if self.collecting:
            self.cycle_values[key] = self.cycle_values.get(key, 0.0) + amount

    def _accrue(self, duration: float) -> None:
        if not self.collecting:
            return
        self.cycle_values["time"] = self.cycle_values.get("time", 0.0) + duration
        self._increment("area.system", self.total_jobs * duration)
        for node_index, node in enumerate(self.model.nodes):
            queue_length = len(self.queues[node_index])
            busy = min(queue_length, node.servers)
            self._increment(f"area.node.{node.identifier}", queue_length * duration)
            self._increment(
                f"area.queue.{node.identifier}",
                max(0, queue_length - node.servers) * duration,
            )
            self._increment(f"area.busy.{node.identifier}", busy * duration)
            for class_index, customer in enumerate(self.model.classes):
                count = self.counts[node_index][class_index]
                self._increment(
                    f"area.node_class.{node.identifier}.{customer.identifier}",
                    count * duration,
                )
        for class_index, customer in enumerate(self.model.classes):
            class_count = sum(row[class_index] for row in self.counts)
            self._increment(f"area.class.{customer.identifier}", class_count * duration)

    def _proposal_external_rate(self, original: float) -> float:
        if self.model.rare_event.method == "importance_sampling_mm1k":
            return original * self.model.rare_event.arrival_rate_multiplier
        return original

    def _proposal_service_rate(self, node_index: int) -> float:
        original = self.model.nodes[node_index].service_rate
        if self.model.rare_event.method == "importance_sampling_mm1k":
            return original * self.model.rare_event.service_rate_multiplier
        return original

    def _event_rates(self) -> tuple[list[tuple[str, int, int | None, float, float]], float, float]:
        events: list[tuple[str, int, int | None, float, float]] = []
        original_total = 0.0
        proposal_total = 0.0
        for node_index, class_index, original in self._external_events:
            proposal = self._proposal_external_rate(original)
            events.append(("external", node_index, class_index, original, proposal))
            original_total += original
            proposal_total += proposal
        for node_index, node in enumerate(self.model.nodes):
            busy = min(len(self.queues[node_index]), node.servers)
            if busy:
                original = busy * node.service_rate
                proposal = busy * self._proposal_service_rate(node_index)
                events.append(("service", node_index, None, original, proposal))
                original_total += original
                proposal_total += proposal
        return events, original_total, proposal_total

    def _accept(self, node_index: int, class_index: int) -> bool:
        node = self.model.nodes[node_index]
        if node.capacity is not None and len(self.queues[node_index]) >= node.capacity:
            return False
        self.queues[node_index].append(class_index)
        self.counts[node_index][class_index] += 1
        self.total_jobs += 1
        return True

    def _route(self, source: int, class_index: int) -> None:
        customer = self.model.classes[class_index]
        draw = self.choice_rng.random()
        cumulative = 0.0
        for destination, probability in enumerate(customer.routing[source]):
            cumulative += probability
            if draw < cumulative:
                self._increment("count.routed.offered")
                if self._accept(destination, class_index):
                    self._increment("count.routed.accepted")
                else:
                    self._increment("count.routed.blocked")
                    self._increment("count.departure")
                    self._increment(f"count.departure.class.{customer.identifier}")
                return
        self._increment("count.departure")
        self._increment(f"count.departure.class.{customer.identifier}")
        self._increment("count.exit")
        self._increment(f"count.exit.class.{customer.identifier}")

    def _execute_event(
        self, event: tuple[str, int, int | None, float, float]
    ) -> None:
        kind, node_index, class_index_or_none, original_rate, proposal_rate = event
        if self.collecting and self.model.rare_event.method != "none":
            self.cycle_log_weight += math.log(original_rate / proposal_rate)
        if kind == "external":
            class_index = int(class_index_or_none)
            customer = self.model.classes[class_index]
            self._increment("count.external.offered")
            self._increment(f"count.external.offered.class.{customer.identifier}")
            if self._accept(node_index, class_index):
                self._increment("count.external.accepted")
                self._increment(f"count.external.accepted.class.{customer.identifier}")
            else:
                self._increment("count.external.blocked")
                self._increment(f"count.external.blocked.class.{customer.identifier}")
            return

        node = self.model.nodes[node_index]
        busy = min(len(self.queues[node_index]), node.servers)
        completion_index = min(busy - 1, int(self.choice_rng.random() * busy))
        class_index = self.queues[node_index].pop(completion_index)
        self.counts[node_index][class_index] -= 1
        self.total_jobs -= 1
        self._increment(f"count.service.{node.identifier}")
        self._route(node_index, class_index)

    def _precision_check(self) -> bool:
        options = self.model.stopping
        if self.estimator.cycles < options.minimum_cycles:
            return False
        self.looks += 1
        metric_count = len(options.monitored_metrics)
        overall_alpha = 1.0 - options.confidence
        look_alpha = overall_alpha / (metric_count * self.looks * (self.looks + 1))
        details: dict[str, Any] = {}
        all_met = True
        for key in options.monitored_metrics:
            accumulator = self.estimator.accumulators[key]
            core = accumulator.core()
            metric_result: dict[str, Any] = {
                "available": core["available"],
                "target_met": False,
            }
            if core["available"] and core["standard_error"] is not None:
                probability = 1.0 - look_alpha / 2.0
                critical = None
                half_width = None
                if probability < 1.0:
                    critical = student_t_quantile(probability, accumulator.cycles - 1)
                    half_width = critical * core["standard_error"]
                target = max(
                    options.absolute_half_width,
                    options.relative_half_width * abs(core["estimate"]),
                )
                sequential_interval = None
                if half_width is not None and math.isfinite(half_width):
                    raw_low = core["estimate"] - half_width
                    raw_high = core["estimate"] + half_width
                    low = raw_low
                    high = raw_high
                    if accumulator.definition.lower_bound is not None:
                        low = max(accumulator.definition.lower_bound, low)
                    if accumulator.definition.upper_bound is not None:
                        high = min(accumulator.definition.upper_bound, high)
                    sequential_interval = {
                        "low": low,
                        "high": high,
                        "raw_low": raw_low,
                        "raw_high": raw_high,
                        "per_metric_per_look_alpha": look_alpha,
                    }
                enough_effective = core["effective_cycles"] >= options.minimum_effective_cycles
                enough_positive = (
                    not accumulator.definition.event_probability
                    or core["numerator_positive_cycles"] >= options.minimum_positive_cycles
                )
                positive_variance = core["centered_cycle_variance_scaled"] > 0.0
                met = (
                    half_width is not None
                    and math.isfinite(half_width)
                    and half_width <= target
                    and enough_effective
                    and enough_positive
                    and positive_variance
                )
                metric_result.update(
                    {
                        "estimate": core["estimate"],
                        "standard_error": core["standard_error"],
                        "critical_value": critical,
                        "sequential_half_width": half_width,
                        "sequential_confidence_interval": sequential_interval,
                        "target_half_width": target,
                        "effective_cycles": core["effective_cycles"],
                        "enough_effective_cycles": enough_effective,
                        "enough_positive_cycles": enough_positive,
                        "positive_variance_observed": positive_variance,
                        "target_met": met,
                    }
                )
            all_met = all_met and bool(metric_result["target_met"])
            details[key] = metric_result
        self.last_precision = {
            "look": self.looks,
            "per_metric_per_look_alpha": look_alpha,
            "alpha_spending_rule": "alpha / (metric_count * look * (look + 1))",
            "metrics": details,
            "target_met": all_met,
        }
        return all_met

    def _finalize_cycle(self) -> bool:
        duration = self.time - self.segment_start
        if duration <= 0.0:
            raise SimulationError("a regenerative cycle had nonpositive duration")
        self.estimator.add_cycle(self.cycle_values, self.cycle_log_weight)
        self.cycle_durations.add(duration)
        self.collected_time += duration
        options = self.model.stopping
        check_due = (
            self.estimator.cycles >= options.minimum_cycles
            and (
                (self.estimator.cycles - options.minimum_cycles) % options.check_every_cycles == 0
                or self.estimator.cycles >= options.maximum_cycles
            )
        )
        precision_met = self._precision_check() if check_due else False
        self.segment_start = self.time
        self.cycle_values = {"time": 0.0}
        self.cycle_log_weight = 0.0
        self.cycle_events = 0
        return precision_met

    def run(self) -> tuple[str, bool]:
        options = self.model.stopping
        reason = "maximum_cycles"
        precision_met = False
        while True:
            if self.estimator.cycles >= options.maximum_cycles:
                reason = "maximum_cycles"
                break
            if self.events >= options.maximum_events:
                reason = "maximum_events"
                self.discarded_incomplete_cycle = self.collecting
                break
            if self.time >= options.maximum_simulated_time:
                reason = "maximum_simulated_time"
                self.discarded_incomplete_cycle = self.collecting
                break
            if time.monotonic() - self.start_wall >= options.maximum_wall_seconds:
                reason = "maximum_wall_seconds"
                self.discarded_incomplete_cycle = self.collecting
                break

            events, original_total, proposal_total = self._event_rates()
            if proposal_total <= 0.0 or not events:
                raise SimulationError("the event calendar is empty")
            uniform = self.time_rng.random()
            while uniform == 0.0:
                # random.Random can represent zero.  It has measure zero under
                # the ideal uniform law but would create a zero holding time.
                uniform = self.time_rng.random()
            duration = -math.log1p(-uniform) / proposal_total
            if self.time + duration > options.maximum_simulated_time:
                reason = "maximum_simulated_time"
                self.discarded_incomplete_cycle = self.collecting
                break
            if self.time + duration - self.segment_start > options.maximum_cycle_time:
                stage = "complete_cycle" if self.collecting else "delayed_first_cycle"
                raise CycleLimitError(
                    f"{stage} exceeded stopping.maximum_cycle_time; it was not truncated or used",
                    {
                        "stage": stage,
                        "limit": options.maximum_cycle_time,
                        "elapsed_before_next_event": self.time + duration - self.segment_start,
                        "completed_cycles": self.estimator.cycles,
                    },
                )

            self._accrue(duration)
            if self.collecting and self.model.rare_event.method != "none":
                self.cycle_log_weight += (proposal_total - original_total) * duration
            self.time += duration
            draw = self.choice_rng.random() * proposal_total
            cumulative = 0.0
            selected = events[-1]
            for event in events:
                cumulative += event[4]
                if draw < cumulative:
                    selected = event
                    break
            self._execute_event(selected)
            self.events += 1
            self.cycle_events += 1
            if self.cycle_events > options.maximum_events_per_cycle:
                stage = "complete_cycle" if self.collecting else "delayed_first_cycle"
                raise CycleLimitError(
                    f"{stage} exceeded stopping.maximum_events_per_cycle; it was not used",
                    {
                        "stage": stage,
                        "limit": options.maximum_events_per_cycle,
                        "completed_cycles": self.estimator.cycles,
                    },
                )

            if self.total_jobs == 0:
                if self.collecting:
                    if self._finalize_cycle():
                        reason = "precision_target_met"
                        precision_met = True
                        break
                else:
                    self.delayed_time = self.time
                    self.collecting = True
                    self.segment_start = self.time
                    self.cycle_values = {"time": 0.0}
                    self.cycle_log_weight = 0.0
                    self.cycle_events = 0
        return reason, precision_met


def _analytic_benchmark(model: Model) -> dict[str, Any] | None:
    if len(model.nodes) != 1 or len(model.classes) != 1:
        return None
    node = model.nodes[0]
    customer = model.classes[0]
    if node.servers != 1 or any(customer.routing[0]):
        return None
    arrival = customer.external_rates[0]
    service = node.service_rate
    rho = arrival / service
    if node.capacity is None:
        if rho >= 1.0:
            return None
        return {
            "model": "M/M/1",
            "arrival_rate": arrival,
            "service_rate": service,
            "traffic_intensity": rho,
            "mean_number_in_system": rho / (1.0 - rho),
            "utilization": rho,
            "external_blocking_probability": 0.0,
            "departure_rate": arrival,
        }
    capacity = node.capacity
    log_rho = math.log(rho)
    if log_rho == 0.0:
        full_probability = 1.0 / (capacity + 1)
        mean_number = capacity / 2.0
        empty_probability = full_probability
    else:
        magnitude = abs(log_rho)
        edge_probability = (
            -math.expm1(-magnitude)
            / -math.expm1(-(capacity + 1) * magnitude)
        )
        opposite_edge = edge_probability * math.exp(-capacity * magnitude)
        span = (capacity + 1) * magnitude
        if span < 1.0e-5:
            # First-order exponential-family expansion about the uniform law.
            mean_from_heavy_edge = (
                capacity / 2.0
                - magnitude * capacity * (capacity + 2) / 12.0
            )
        else:
            first_term = 0.0 if magnitude > 700.0 else 1.0 / math.expm1(magnitude)
            second_term = 0.0 if span > 700.0 else (capacity + 1) / math.expm1(span)
            mean_from_heavy_edge = first_term - second_term
        if log_rho < 0.0:
            empty_probability = edge_probability
            full_probability = opposite_edge
            mean_number = mean_from_heavy_edge
        else:
            full_probability = edge_probability
            empty_probability = opposite_edge
            mean_number = capacity - mean_from_heavy_edge
    return {
        "model": "M/M/1/K",
        "capacity": capacity,
        "arrival_rate": arrival,
        "service_rate": service,
        "traffic_intensity": rho,
        "mean_number_in_system": mean_number,
        "utilization": 1.0 - empty_probability,
        "external_blocking_probability": full_probability,
        "departure_rate": arrival * (1.0 - full_probability),
    }


def _benchmark_comparison(
    benchmark: dict[str, Any] | None, estimates: dict[str, dict[str, Any]], model: Model
) -> dict[str, Any] | None:
    if benchmark is None:
        return None
    mapping = {
        "mean_number_in_system": "mean_number_in_system",
        "external_blocking_probability": "external_blocking_probability",
        "departure_rate": "departure_rate",
        "utilization": f"utilization:{model.nodes[0].identifier}",
    }
    comparison: dict[str, Any] = {}
    for formula_key, estimate_key in mapping.items():
        summary = estimates.get(estimate_key)
        if summary and summary.get("available"):
            exact = benchmark[formula_key]
            standard_error = summary.get("standard_error")
            comparison[formula_key] = {
                "exact": exact,
                "estimate": summary["estimate"],
                "error": summary["estimate"] - exact,
                "standardized_error": (
                    (summary["estimate"] - exact) / standard_error
                    if standard_error not in {None, 0.0}
                    else None
                ),
            }
    return comparison


def solve_model(model: Model) -> dict[str, Any]:
    simulator = Simulator(model)
    stopping_reason, precision_met = simulator.run()
    estimates = {
        key: accumulator.summary(model.stopping.confidence)
        for key, accumulator in simulator.estimator.accumulators.items()
    }
    benchmark = _analytic_benchmark(model)
    rare_diagnostics = simulator.estimator.weight_diagnostics()
    if model.rare_event.method == "none":
        rare_output: dict[str, Any] = {
            "enabled": False,
            "method": "none",
            "cycle_likelihood_weights_are_unity": True,
        }
    else:
        node = model.nodes[0]
        customer = model.classes[0]
        original_arrival = customer.external_rates[0]
        original_service = node.service_rate
        rare_output = {
            "enabled": True,
            "method": model.rare_event.method,
            "target_measure": {
                "arrival_rate": original_arrival,
                "service_rate": original_service,
            },
            "proposal_measure": {
                "arrival_rate": original_arrival * model.rare_event.arrival_rate_multiplier,
                "service_rate": original_service * model.rare_event.service_rate_multiplier,
            },
            "likelihood": (
                "full continuous-time empty-to-empty path likelihood, including "
                "holding-time factors and blocked arrival self-events"
            ),
            "weight_diagnostics": rare_diagnostics,
        }

    traffic = {
        "classes": [
            {
                "id": customer.identifier,
                "unblocked_traffic_equation_node_rates": {
                    node.identifier: model.traffic_rates[class_index][node_index]
                    for node_index, node in enumerate(model.nodes)
                },
            }
            for class_index, customer in enumerate(model.classes)
        ],
        "nodes": [
            {
                "id": node.identifier,
                "nominal_unblocked_offered_load": model.offered_loads[index],
                "finite_buffer": node.capacity is not None,
            }
            for index, node in enumerate(model.nodes)
        ],
        "stability_basis": (
            "finite state space"
            if model.finite_buffers
            else "strict Jackson offered load below one at every node"
        ),
    }
    precision = simulator.last_precision or {
        "look": 0,
        "metrics": {},
        "target_met": False,
        "reason": "minimum cycles were not reached at a scheduled look",
    }
    precision.update(
        {
            "overall_confidence": model.stopping.confidence,
            "sequential_method": (
                "regenerative ratio t intervals with summable alpha spending "
                "over metrics and scheduled looks"
            ),
            "asymptotic_not_finite_sample": True,
            "target_met": precision_met,
            "stopping_reason": stopping_reason,
            "absolute_half_width_target": model.stopping.absolute_half_width,
            "relative_half_width_target": model.stopping.relative_half_width,
            "monitored_metrics": list(model.stopping.monitored_metrics),
        }
    )
    return {
        "schema_version": 1,
        "process": "open_markovian_queueing_network",
        "status": "ok",
        "model": {
            "name": model.name,
            "node_count": len(model.nodes),
            "class_count": len(model.classes),
            "node_ids": [node.identifier for node in model.nodes],
            "class_ids": [customer.identifier for customer in model.classes],
            "buffer_mode": "finite_loss_on_arrival" if model.finite_buffers else "infinite",
            "discipline": "FCFS M/M/c with node-specific class-independent service rates",
        },
        "random": {
            "base_seed": model.base_seed,
            "stream": model.stream,
            "derivation": "SplitMix64 component seeds feeding Python random.Random",
            "time_seed": simulator.time_seed,
            "choice_seed": simulator.choice_seed,
        },
        "traffic": traffic,
        "regeneration": {
            "state": "empty system immediately after an exit or loss-on-routing event",
            "initial_state_was_regeneration": simulator.initial_state_was_regeneration,
            "delayed_first_cycle_discarded": not simulator.initial_state_was_regeneration,
            "delayed_time": simulator.delayed_time,
            "complete_cycles": simulator.estimator.cycles,
            "proposal_simulated_time": simulator.time,
            "proposal_collected_cycle_time": simulator.collected_time,
            "events": simulator.events,
            "incomplete_final_cycle_discarded": simulator.discarded_incomplete_cycle,
            "cycle_duration_under_proposal": simulator.cycle_durations.summary(),
            "iid_unit": "complete regenerative cycle; events within a cycle are not IID",
        },
        "precision": precision,
        "estimates": estimates,
        "rare_event": rare_output,
        "analytic_benchmark": benchmark,
        "benchmark_comparison": _benchmark_comparison(benchmark, estimates, model),
        "diagnostics": {
            "likelihood_weight_effective_cycles": rare_diagnostics["effective_cycles"],
            "likelihood_weight_effective_fraction": rare_diagnostics.get("effective_fraction"),
            "precision_achieved": precision_met,
            "stopping_reason": stopping_reason,
        },
    }


def solve_document(document: dict[str, Any]) -> dict[str, Any]:
    return solve_model(parse_model(document))


def _error_document(error: SimulationError) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "process": "open_markovian_queueing_network",
        "status": "error",
        "error": {
            "code": error.code,
            "message": str(error),
            **error.details,
        },
    }


def _human_number(value: Any) -> str:
    """Stable finite-float token for parser-facing human-output records."""

    if value is None or isinstance(value, bool) or not _is_number(value):
        return "NA"
    number = float(value)
    return format(number, ".17g") if math.isfinite(number) else "NA"


def _node_metric_line(
    node_id: str,
    metric: str,
    summary: dict[str, Any],
    class_id: str | None = None,
) -> str:
    interval = summary.get("confidence_interval") or {}
    fields = [
        "QNET_NODE_METRIC_V1",
        f"node_id={quote(node_id, safe='')}",
        f"metric={metric}",
        f"class_id={quote(class_id, safe='') if class_id is not None else '-'}",
        f"estimate={_human_number(summary.get('estimate'))}",
        f"standard_error={_human_number(summary.get('standard_error'))}",
        f"ci_confidence={_human_number(interval.get('confidence'))}",
        f"ci_low={_human_number(interval.get('low'))}",
        f"ci_high={_human_number(interval.get('high'))}",
        f"ci_half_width={_human_number(interval.get('half_width'))}",
        f"effective_cycles={_human_number(summary.get('effective_cycles'))}",
    ]
    return " ".join(fields)


def _fmt(value: Any, digits: int = 6) -> str:
    """Human column value, at a FIXED fraction length.

    Fixed rather than %g on purpose. The GUI re-formats every number on screen
    to Settings > Output Format > Decimal places, and it never pads, because
    padding prose was a real defect. So a column whose source values differ in
    width (%g gives 0.00485 and 0.0236) comes out ragged after the rewrite,
    while a column of uniform width maps to a column of uniform width. The
    fraction length here is only the pre-image; what the reader sees is their
    own setting.
    """
    if value is None or isinstance(value, bool) or not _is_number(value):
        return "-"
    number = float(value)
    if not math.isfinite(number):
        return "-"
    return f"{number:.{digits}f}"


def _human(result: dict[str, Any]) -> str:
    """Reader-facing report, in the same shape the other Qnet solvers print.

    The QNET_NODE_METRIC_V1 records this used to lead with are a parser
    contract, not a report: ten `key=value` pairs at 17 significant digits, one
    line per node per metric. They are still emitted at the end, because
    ResultOutputParser and the CSV export read them out of the tee'd archive —
    but they are no longer what a person is shown, and the GUI's display filter
    drops them now that the table above carries the same numbers.

    House style, matching truncated_ctmc.py and the awk-formatted native
    solvers: a title, the model layer, the evidence class, a short run summary,
    then one aligned row per node.
    """
    if result["status"] != "ok":
        error = result["error"]
        return f"Simulation error [{error['code']}]: {error['message']}"

    regeneration = result["regeneration"]
    precision = result["precision"]
    model = result["model"]
    estimates = result["estimates"]
    node_ids = list(model["node_ids"])
    class_ids = list(model["class_ids"])

    lines = [
        "Regenerative Monte Carlo",
        "Model layer: queueing process (simulation)",
        "Evidence: regenerative ratio confidence intervals; asymptotic, not "
        "finite-sample, and they describe sampling error only",
        f"Model: {model['name']}",
        "",
        f"Complete empty-to-empty cycles: {regeneration['complete_cycles']}",
        f"Stopping reason: {precision['stopping_reason']}",
        f"Precision target met: {'yes' if precision['target_met'] else 'no'}",
        "",
    ]

    # ── Per-node table ────────────────────────────────────────────────
    # One row per node, the columns the other solvers print: mean number,
    # mean queue, utilisation and throughput.
    header = f"{'Node':<14}{'E[N]':>13}{'E[Q]':>13}{'utilisation':>13}{'throughput':>13}"
    lines.append(header)
    lines.append("-" * len(header))
    for node_id in node_ids:
        def at(prefix: str) -> Any:
            summary = estimates.get(f"{prefix}:{node_id}")
            return summary.get("estimate") if summary and summary.get("available") else None
        lines.append(
            f"{node_id:<14}"
            f"{_fmt(at('mean_number_at_node')):>13}"
            f"{_fmt(at('mean_queue_at_node')):>13}"
            f"{_fmt(at('utilization')):>13}"
            f"{_fmt(at('service_completion_rate')):>13}"
        )
    lines.append("")

    # ── Confidence intervals, one row per reported quantity ───────────
    # Kept separate from the table: a half-width belongs beside its estimate,
    # not squeezed into a column, and only a simulation has them at all.
    ci_header = (
        f"{'Quantity':<34}{'estimate':>13}{'std error':>12}"
        f"{'95% interval':>26}{'eff. cycles':>13}"
    )
    lines.append(ci_header)
    lines.append("-" * len(ci_header))

    def ci_row(label: str, summary: dict[str, Any] | None) -> None:
        if not summary or not summary.get("available"):
            return
        # Node and class ids are user-supplied and can be long. Let one run past
        # its column and every number to its right shifts, which is exactly the
        # ragged output this rewrite exists to remove. Elide instead.
        if len(label) > 33:
            label = label[:32] + "\u2026"
        interval = summary.get("confidence_interval") or {}
        low, high = interval.get("low"), interval.get("high")
        span = (
            f"[{_fmt(low)}, {_fmt(high)}]"
            if low is not None and high is not None else "-"
        )
        lines.append(
            f"{label:<34}"
            f"{_fmt(summary.get('estimate')):>13}"
            f"{_fmt(summary.get('standard_error')):>12}"
            f"{span:>26}"
            f"{_fmt(summary.get('effective_cycles'), 1):>13}"
        )

    for key, label in (
        ("mean_number_in_system", "Mean number in system"),
        ("external_blocking_probability", "External blocking probability"),
        ("departure_rate", "Departure rate"),
    ):
        ci_row(label, estimates.get(key))
    for node_id in node_ids:
        for prefix, label in (
            ("mean_number_at_node", "E[N]"),
            ("utilization", "utilisation"),
        ):
            ci_row(f"{label} at {node_id}", estimates.get(f"{prefix}:{node_id}"))
        for class_id in class_ids:
            ci_row(
                f"E[N] at {node_id}, class {class_id}",
                estimates.get(f"mean_number:{node_id}:{class_id}"),
            )
    lines.append("")

    benchmark = result.get("analytic_benchmark")
    if benchmark:
        lines.append(f"Analytic check available: {benchmark['model']}")
    if result["rare_event"]["enabled"]:
        weights = result["rare_event"]["weight_diagnostics"]
        lines.append(
            f"Importance-sampling weight ESS: {weights['effective_cycles']:.1f} "
            f"of {weights['cycles']} cycles"
        )
    lines.append(
        "Uncertainty uses complete regenerative cycles, not individual events."
    )

    # ── Machine records, last ─────────────────────────────────────────
    # Unchanged in content and format: ResultOutputParser matches these exactly
    # and reads them from the tee'd archive. They sit after the report so that
    # what a reader sees first is the report.
    machine: list[str] = []
    aggregate_metrics = (
        ("mean_number_at_node", "mean_number"),
        ("mean_queue_at_node", "mean_queue"),
        ("utilization", "utilization"),
        ("service_completion_rate", "service_completion_rate"),
    )
    for node_id in node_ids:
        for estimate_prefix, metric_token in aggregate_metrics:
            summary = estimates.get(f"{estimate_prefix}:{node_id}")
            if summary and summary.get("available"):
                machine.append(_node_metric_line(node_id, metric_token, summary))
        for class_id in class_ids:
            summary = estimates.get(f"mean_number:{node_id}:{class_id}")
            if summary and summary.get("available"):
                machine.append(
                    _node_metric_line(
                        node_id, "mean_number_class", summary, class_id=class_id
                    )
                )
    if machine:
        lines.append("")
        lines.extend(machine)
    return "\n".join(lines)


def _read_document(path: str) -> dict[str, Any]:
    if path == "-":
        try:
            value = json.load(sys.stdin)
        except (json.JSONDecodeError, UnicodeError) as error:
            raise InputError(f"invalid JSON on standard input: {error}") from error
    else:
        try:
            with Path(path).open("r", encoding="utf-8") as handle:
                value = json.load(handle)
        except OSError as error:
            raise InputError(f"cannot read input file {path!r}: {error}") from error
        except (json.JSONDecodeError, UnicodeError) as error:
            raise InputError(f"invalid JSON in {path!r}: {error}") from error
    if not isinstance(value, dict):
        raise InputError("the JSON root must be an object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", help="JSON model path, or - for standard input")
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument("--json", action="store_true", help="pretty JSON on standard output")
    output_group.add_argument("--compact", action="store_true", help="compact JSON on standard output")
    parser.add_argument("-o", "--output", help="write structured JSON to this path")
    args = parser.parse_args(argv)
    try:
        result = solve_document(_read_document(args.model))
        exit_code = 0
    except SimulationError as error:
        result = _error_document(error)
        exit_code = 2

    if args.output:
        try:
            with Path(args.output).open("w", encoding="utf-8") as handle:
                json.dump(result, handle, indent=2, sort_keys=True, allow_nan=False)
                handle.write("\n")
        except OSError as error:
            print(f"cannot write output file {args.output!r}: {error}", file=sys.stderr)
            return 2
    if args.json or args.compact:
        json.dump(
            result,
            sys.stdout,
            indent=None if args.compact else 2,
            separators=(",", ":") if args.compact else None,
            sort_keys=True,
            allow_nan=False,
        )
        sys.stdout.write("\n")
    elif not args.output:
        stream = sys.stdout if exit_code == 0 else sys.stderr
        print(_human(result), file=stream)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
