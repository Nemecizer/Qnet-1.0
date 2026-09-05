#!/usr/bin/env python3
"""Finite-buffer fixed-point decomposition for open multi-class networks.

The solver replaces each station by an M/M/c/K birth-death submodel.  For
loss networks it iterates offered class flows, station blocking probabilities,
and admitted throughputs until the routed flow equations agree.  Optional BAS
modes use an explicitly approximate downstream-availability correction; see
README.md and the ``semantics`` object in JSON output.

The module uses only the Python standard library and is importable by tests or
other tools.  Run ``python3 fbna_decomp.py --help`` for the command-line API.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


SCHEMA_VERSION = 1
OUTPUT_SCHEMA_VERSION = 1
EPSILON = 1.0e-14
MIN_ACCEPTANCE = 1.0e-12


class InputError(ValueError):
    """Raised when an input document does not describe a valid open network."""


@dataclass(frozen=True)
class Station:
    id: str
    name: str
    servers: int
    capacity: int
    service_rates: tuple[float, ...]


@dataclass(frozen=True)
class CustomerClass:
    id: str
    name: str
    external_arrivals: tuple[float, ...]


@dataclass(frozen=True)
class Route:
    from_class: int
    from_station: int
    to_class: int
    to_station: int
    probability: float


@dataclass(frozen=True)
class Network:
    name: str
    blocking: str
    stations: tuple[Station, ...]
    classes: tuple[CustomerClass, ...]
    routes: tuple[Route, ...]
    routes_from: tuple[tuple[tuple[Route, ...], ...], ...]
    route_sums: tuple[tuple[float, ...], ...]

    @property
    def station_count(self) -> int:
        return len(self.stations)

    @property
    def class_count(self) -> int:
        return len(self.classes)


@dataclass(frozen=True)
class SolverOptions:
    tolerance: float = 1.0e-10
    max_iterations: int = 1000
    damping: float = 0.5


@dataclass(frozen=True)
class MMcKResult:
    probabilities: tuple[float, ...]
    blocking_probability: float
    throughput: float
    mean_number: float
    mean_queue: float
    mean_in_service: float
    utilization: float
    waiting_probability_admitted: float
    mean_waiting_time: Optional[float]
    mean_sojourn_time: Optional[float]
    flow_balance_residual: float


@dataclass(frozen=True)
class Evaluation:
    offered: tuple[tuple[float, ...], ...]
    throughputs: tuple[tuple[float, ...], ...]
    full: tuple[float, ...]
    effective_class_service_rates: tuple[tuple[float, ...], ...]
    station_effective_service_rates: tuple[Optional[float], ...]
    station_models: tuple[MMcKResult, ...]
    downstream_blocking: tuple[tuple[float, ...], ...]


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _finite_nonnegative(value: Any, label: str) -> float:
    if not _is_number(value):
        raise InputError(f"{label} must be a number")
    number = float(value)
    if not math.isfinite(number) or number < 0.0:
        raise InputError(f"{label} must be finite and non-negative")
    return number


def _finite_positive(value: Any, label: str) -> float:
    number = _finite_nonnegative(value, label)
    if number <= 0.0:
        raise InputError(f"{label} must be greater than zero")
    return number


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise InputError(f"{label} must be a positive integer")
    return value


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InputError(f"{label} must be a non-empty string")
    return value.strip()


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InputError(f"{label} must be a JSON object")
    return value


def _list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise InputError(f"{label} must be a JSON array")
    return value


def parse_document(document: dict[str, Any]) -> tuple[Network, SolverOptions]:
    """Validate and convert an input JSON object into immutable model data."""
    if not isinstance(document, dict):
        raise InputError("input must be a JSON object")
    version = document.get("schema_version", SCHEMA_VERSION)
    if version != SCHEMA_VERSION:
        raise InputError(
            f"unsupported schema_version {version!r}; expected {SCHEMA_VERSION}"
        )

    name = str(document.get("name", "Untitled finite network"))
    blocking = document.get("blocking", "loss")
    allowed_modes = {"loss", "bas_external_loss", "bas"}
    if blocking not in allowed_modes:
        raise InputError(
            "blocking must be one of: loss, bas_external_loss, bas"
        )

    class_docs = _list(document.get("classes"), "classes")
    station_docs = _list(document.get("stations"), "stations")
    if not class_docs:
        raise InputError("classes must contain at least one class")
    if not station_docs:
        raise InputError("stations must contain at least one station")

    class_ids: list[str] = []
    class_names: list[str] = []
    external_docs: list[dict[str, Any]] = []
    for index, raw in enumerate(class_docs):
        item = _mapping(raw, f"classes[{index}]")
        class_id = _identifier(item.get("id"), f"classes[{index}].id")
        if class_id in class_ids:
            raise InputError(f"duplicate class id {class_id!r}")
        class_ids.append(class_id)
        class_names.append(str(item.get("name", class_id)))
        external_docs.append(
            _mapping(
                item.get("external_arrivals", {}),
                f"classes[{index}].external_arrivals",
            )
        )

    class_index = {class_id: index for index, class_id in enumerate(class_ids)}
    station_ids: list[str] = []
    station_names: list[str] = []
    station_servers: list[int] = []
    station_capacities: list[int] = []
    station_service_docs: list[dict[str, Any] | float] = []
    for index, raw in enumerate(station_docs):
        item = _mapping(raw, f"stations[{index}]")
        station_id = _identifier(item.get("id"), f"stations[{index}].id")
        if station_id in station_ids:
            raise InputError(f"duplicate station id {station_id!r}")
        station_ids.append(station_id)
        station_names.append(str(item.get("name", station_id)))
        servers = _positive_int(item.get("servers", 1), f"stations[{index}].servers")
        capacity = _positive_int(item.get("capacity"), f"stations[{index}].capacity")
        if capacity < servers:
            raise InputError(
                f"stations[{index}].capacity must be at least its server count; "
                "capacity includes jobs in service"
            )
        station_servers.append(servers)
        station_capacities.append(capacity)
        if "service_rates" in item:
            station_service_docs.append(
                _mapping(item["service_rates"], f"stations[{index}].service_rates")
            )
        elif "service_rate" in item:
            station_service_docs.append(
                _finite_positive(item["service_rate"], f"stations[{index}].service_rate")
            )
        else:
            raise InputError(
                f"stations[{index}] requires service_rate or service_rates"
            )

    station_index = {
        station_id: index for index, station_id in enumerate(station_ids)
    }
    class_count = len(class_ids)
    station_count = len(station_ids)

    external: list[list[float]] = [
        [0.0 for _ in range(station_count)] for _ in range(class_count)
    ]
    for k, external_doc in enumerate(external_docs):
        for station_id, raw_rate in external_doc.items():
            if station_id not in station_index:
                raise InputError(
                    f"classes[{k}].external_arrivals names unknown station "
                    f"{station_id!r}"
                )
            external[k][station_index[station_id]] = _finite_nonnegative(
                raw_rate,
                f"classes[{k}].external_arrivals[{station_id!r}]",
            )

    service_by_station: list[list[float]] = []
    for i, raw_services in enumerate(station_service_docs):
        if isinstance(raw_services, float):
            service_by_station.append([raw_services] * class_count)
            continue
        unknown = sorted(set(raw_services) - set(class_ids))
        if unknown:
            raise InputError(
                f"stations[{i}].service_rates has unknown classes: "
                + ", ".join(unknown)
            )
        missing = [class_id for class_id in class_ids if class_id not in raw_services]
        if missing:
            raise InputError(
                f"stations[{i}].service_rates is missing: " + ", ".join(missing)
            )
        service_by_station.append(
            [
                _finite_positive(
                    raw_services[class_id],
                    f"stations[{i}].service_rates[{class_id!r}]",
                )
                for class_id in class_ids
            ]
        )

    stations = tuple(
        Station(
            id=station_ids[i],
            name=station_names[i],
            servers=station_servers[i],
            capacity=station_capacities[i],
            service_rates=tuple(service_by_station[i][k] for k in range(class_count)),
        )
        for i in range(station_count)
    )
    classes = tuple(
        CustomerClass(
            id=class_ids[k],
            name=class_names[k],
            external_arrivals=tuple(external[k]),
        )
        for k in range(class_count)
    )

    route_docs = _list(document.get("routes", []), "routes")
    routes: list[Route] = []
    route_sums = [
        [0.0 for _ in range(station_count)] for _ in range(class_count)
    ]
    for index, raw in enumerate(route_docs):
        item = _mapping(raw, f"routes[{index}]")
        from_class_id = _identifier(item.get("class"), f"routes[{index}].class")
        to_class_id = _identifier(
            item.get("to_class", from_class_id), f"routes[{index}].to_class"
        )
        from_station_id = _identifier(item.get("from"), f"routes[{index}].from")
        to_station_id = _identifier(item.get("to"), f"routes[{index}].to")
        if from_class_id not in class_index:
            raise InputError(f"routes[{index}] names unknown class {from_class_id!r}")
        if to_class_id not in class_index:
            raise InputError(f"routes[{index}] names unknown to_class {to_class_id!r}")
        if from_station_id not in station_index:
            raise InputError(
                f"routes[{index}] names unknown from station {from_station_id!r}"
            )
        if to_station_id not in station_index:
            raise InputError(
                f"routes[{index}] names unknown to station {to_station_id!r}"
            )
        probability = _finite_nonnegative(
            item.get("probability"), f"routes[{index}].probability"
        )
        if probability > 1.0:
            raise InputError(f"routes[{index}].probability cannot exceed one")
        if probability == 0.0:
            continue
        route = Route(
            from_class=class_index[from_class_id],
            from_station=station_index[from_station_id],
            to_class=class_index[to_class_id],
            to_station=station_index[to_station_id],
            probability=probability,
        )
        routes.append(route)
        route_sums[route.from_class][route.from_station] += probability

    for k in range(class_count):
        for i in range(station_count):
            if route_sums[k][i] > 1.0 + 1.0e-12:
                raise InputError(
                    f"routing probabilities from class {class_ids[k]!r}, station "
                    f"{station_ids[i]!r} sum to {route_sums[k][i]:.12g}, above one"
                )
            if route_sums[k][i] > 1.0:
                route_sums[k][i] = 1.0

    routes_from_lists: list[list[list[Route]]] = [
        [[] for _ in range(station_count)] for _ in range(class_count)
    ]
    for route in routes:
        routes_from_lists[route.from_class][route.from_station].append(route)
    routes_from = tuple(
        tuple(tuple(items) for items in by_station)
        for by_station in routes_from_lists
    )

    network = Network(
        name=name,
        blocking=blocking,
        stations=stations,
        classes=classes,
        routes=tuple(routes),
        routes_from=routes_from,
        route_sums=tuple(tuple(row) for row in route_sums),
    )
    _validate_open_routing(network)

    solver_doc = _mapping(document.get("solver", {}), "solver")
    tolerance = _finite_positive(
        solver_doc.get("tolerance", 1.0e-10), "solver.tolerance"
    )
    max_iterations = _positive_int(
        solver_doc.get("max_iterations", 1000), "solver.max_iterations"
    )
    damping = _finite_positive(solver_doc.get("damping", 0.5), "solver.damping")
    if damping > 1.0:
        raise InputError("solver.damping must be at most one")
    return network, SolverOptions(tolerance, max_iterations, damping)


def _validate_open_routing(network: Network) -> None:
    """Reject externally reachable closed communicating classes.

    A reachable class/station state is open if some path from it reaches a
    routing row whose missing probability represents departure from the
    network. This graph test is exact for finite substochastic routing and
    avoids a numerical spectral-radius dependency.
    """
    class_count = network.class_count
    station_count = network.station_count
    state_count = class_count * station_count

    def state(k: int, i: int) -> int:
        return k * station_count + i

    adjacency: list[list[int]] = [[] for _ in range(state_count)]
    reverse: list[list[int]] = [[] for _ in range(state_count)]
    exit_states: list[int] = []
    externally_reachable: list[int] = []
    for k in range(class_count):
        for i in range(station_count):
            origin = state(k, i)
            if network.route_sums[k][i] < 1.0 - 1.0e-12:
                exit_states.append(origin)
            if network.classes[k].external_arrivals[i] > 0.0:
                externally_reachable.append(origin)
            for route in network.routes_from[k][i]:
                destination = state(route.to_class, route.to_station)
                adjacency[origin].append(destination)
                reverse[destination].append(origin)

    reachable: set[int] = set()
    stack = list(externally_reachable)
    while stack:
        current = stack.pop()
        if current in reachable:
            continue
        reachable.add(current)
        stack.extend(adjacency[current])

    can_exit: set[int] = set()
    stack = exit_states[:]
    while stack:
        current = stack.pop()
        if current in can_exit:
            continue
        can_exit.add(current)
        stack.extend(reverse[current])

    closed = sorted(reachable - can_exit)
    if closed:
        labels = []
        for flat in closed[:8]:
            k, i = divmod(flat, station_count)
            labels.append(f"{network.classes[k].id}@{network.stations[i].id}")
        suffix = " …" if len(closed) > len(labels) else ""
        raise InputError(
            "network is not open: externally reachable routing states cannot "
            "reach an exit: " + ", ".join(labels) + suffix
        )


def mmck(offered_rate: float, service_rate: float, servers: int, capacity: int) -> MMcKResult:
    """Stationary metrics of an M/M/c/K queue, computed in log space.

    ``capacity`` is K, the maximum total number at the station including
    customers in service. Arrivals finding state K are lost/blocked.
    """
    if offered_rate < 0.0 or not math.isfinite(offered_rate):
        raise ValueError("offered_rate must be finite and non-negative")
    if service_rate <= 0.0 or not math.isfinite(service_rate):
        raise ValueError("service_rate must be finite and positive")
    if servers <= 0 or capacity < servers:
        raise ValueError("servers must be positive and capacity >= servers")

    if offered_rate == 0.0:
        probabilities = (1.0,) + (0.0,) * capacity
    else:
        log_weights = [0.0]
        log_arrival = math.log(offered_rate)
        log_service = math.log(service_rate)
        for number in range(1, capacity + 1):
            death_servers = min(number, servers)
            log_weights.append(
                log_weights[-1]
                + log_arrival
                - log_service
                - math.log(death_servers)
            )
        shift = max(log_weights)
        weights = [math.exp(value - shift) for value in log_weights]
        normalizer = math.fsum(weights)
        probabilities = tuple(value / normalizer for value in weights)

    blocking = probabilities[-1]
    mean_number = math.fsum(
        number * probability
        for number, probability in enumerate(probabilities)
    )
    mean_in_service = math.fsum(
        min(number, servers) * probability
        for number, probability in enumerate(probabilities)
    )
    mean_queue = math.fsum(
        max(number - servers, 0) * probability
        for number, probability in enumerate(probabilities)
    )
    throughput = offered_rate * (1.0 - blocking)
    utilization = mean_in_service / servers
    admitted_probability = 1.0 - blocking
    if admitted_probability > EPSILON:
        waiting_probability = math.fsum(
            probabilities[number]
            for number in range(servers, capacity)
        ) / admitted_probability
    else:
        waiting_probability = 0.0
    if throughput > EPSILON:
        mean_waiting_time: Optional[float] = mean_queue / throughput
        mean_sojourn_time: Optional[float] = mean_number / throughput
    else:
        mean_waiting_time = None
        mean_sojourn_time = None
    flow_residual = abs(throughput - service_rate * mean_in_service)
    return MMcKResult(
        probabilities=probabilities,
        blocking_probability=blocking,
        throughput=throughput,
        mean_number=mean_number,
        mean_queue=mean_queue,
        mean_in_service=mean_in_service,
        utilization=utilization,
        waiting_probability_admitted=waiting_probability,
        mean_waiting_time=mean_waiting_time,
        mean_sojourn_time=mean_sojourn_time,
        flow_balance_residual=flow_residual,
    )


def _zeros(class_count: int, station_count: int) -> list[list[float]]:
    return [[0.0 for _ in range(station_count)] for _ in range(class_count)]


def _external_matrix(network: Network) -> list[list[float]]:
    return [list(customer_class.external_arrivals) for customer_class in network.classes]


def _normalized_matrix_residual(
    lhs: list[list[float]] | tuple[tuple[float, ...], ...],
    rhs: list[list[float]] | tuple[tuple[float, ...], ...],
) -> float:
    residual = 0.0
    for left_row, right_row in zip(lhs, rhs):
        for left, right in zip(left_row, right_row):
            residual = max(residual, abs(left - right) / (1.0 + max(abs(left), abs(right))))
    return residual


def _downstream_blocking(
    network: Network, full: Iterable[float]
) -> list[list[float]]:
    full_values = list(full)
    result = _zeros(network.class_count, network.station_count)
    for k in range(network.class_count):
        for i in range(network.station_count):
            result[k][i] = math.fsum(
                route.probability * full_values[route.to_station]
                for route in network.routes_from[k][i]
            )
    return result


def _evaluate(
    network: Network,
    offered: list[list[float]],
    full_for_bas: list[float],
) -> Evaluation:
    class_count = network.class_count
    station_count = network.station_count
    downstream = _downstream_blocking(network, full_for_bas)
    effective_class_mu = _zeros(class_count, station_count)
    for k in range(class_count):
        for i in range(station_count):
            base = network.stations[i].service_rates[k]
            if network.blocking == "loss":
                effective_class_mu[k][i] = base
            else:
                # Frozen-server / repetitive-service availability closure.
                # It is deliberately labelled approximate in every output.
                availability = max(MIN_ACCEPTANCE, 1.0 - downstream[k][i])
                effective_class_mu[k][i] = base * availability

    station_models: list[MMcKResult] = []
    station_mu: list[Optional[float]] = []
    full: list[float] = []
    throughputs = _zeros(class_count, station_count)
    for i, station in enumerate(network.stations):
        aggregate_offered = math.fsum(offered[k][i] for k in range(class_count))
        if aggregate_offered > EPSILON:
            mean_service = math.fsum(
                (offered[k][i] / aggregate_offered) / effective_class_mu[k][i]
                for k in range(class_count)
            )
            effective_mu = 1.0 / mean_service
        else:
            # The value is immaterial for an empty M/M/c/K chain. Preserve a
            # meaningful diagnostic by using the harmonic mean across classes.
            effective_mu = class_count / math.fsum(
                1.0 / effective_class_mu[k][i] for k in range(class_count)
            )
        model = mmck(
            aggregate_offered,
            effective_mu,
            station.servers,
            station.capacity,
        )
        station_models.append(model)
        station_mu.append(effective_mu if aggregate_offered > EPSILON else None)
        full.append(model.blocking_probability)
        for k in range(class_count):
            throughputs[k][i] = offered[k][i] * (1.0 - model.blocking_probability)

    return Evaluation(
        offered=tuple(tuple(row) for row in offered),
        throughputs=tuple(tuple(row) for row in throughputs),
        full=tuple(full),
        effective_class_service_rates=tuple(
            tuple(row) for row in effective_class_mu
        ),
        station_effective_service_rates=tuple(station_mu),
        station_models=tuple(station_models),
        downstream_blocking=tuple(tuple(row) for row in downstream),
    )


def _routed_flows(network: Network, evaluation: Evaluation) -> list[list[float]]:
    incoming = _zeros(network.class_count, network.station_count)
    for route in network.routes:
        incoming[route.to_class][route.to_station] += (
            evaluation.throughputs[route.from_class][route.from_station]
            * route.probability
        )
    return incoming


def _target_offered(
    network: Network, evaluation: Evaluation
) -> tuple[list[list[float]], list[list[float]]]:
    incoming = _routed_flows(network, evaluation)
    external = _external_matrix(network)
    target = _zeros(network.class_count, network.station_count)
    for k in range(network.class_count):
        for i in range(network.station_count):
            if network.blocking == "loss":
                target[k][i] = external[k][i] + incoming[k][i]
                continue
            acceptance = max(MIN_ACCEPTANCE, 1.0 - evaluation.full[i])
            if network.blocking == "bas_external_loss":
                # External arrivals remain attempts and may be lost. Internal
                # customers are held upstream until their transfer succeeds.
                target[k][i] = external[k][i] + incoming[k][i] / acceptance
            else:  # pure BAS: external source is held too
                target[k][i] = (external[k][i] + incoming[k][i]) / acceptance
    return target, incoming


def solve(network: Network, options: SolverOptions) -> dict[str, Any]:
    """Run the damped fixed point and return a JSON-serializable result."""
    offered = _external_matrix(network)
    full_guess = [0.0 for _ in network.stations]
    residual_history: list[float] = []
    converged = False
    evaluation: Optional[Evaluation] = None
    target: list[list[float]] = offered

    for iteration in range(1, options.max_iterations + 1):
        evaluation = _evaluate(network, offered, full_guess)
        target, _ = _target_offered(network, evaluation)
        flow_residual = _normalized_matrix_residual(offered, target)
        if network.blocking == "loss":
            full_residual = 0.0
        else:
            full_residual = max(
                abs(evaluation.full[i] - full_guess[i])
                for i in range(network.station_count)
            )
        residual = max(flow_residual, full_residual)
        residual_history.append(residual)
        if residual <= options.tolerance:
            converged = True
            break

        for k in range(network.class_count):
            for i in range(network.station_count):
                offered[k][i] = (
                    (1.0 - options.damping) * offered[k][i]
                    + options.damping * target[k][i]
                )
        if network.blocking == "loss":
            full_guess = list(evaluation.full)
        else:
            full_guess = [
                (1.0 - options.damping) * full_guess[i]
                + options.damping * evaluation.full[i]
                for i in range(network.station_count)
            ]

    assert evaluation is not None
    # Report evidence for the final iterate, not the penultimate update.
    evaluation = _evaluate(network, offered, full_guess)
    target, _ = _target_offered(network, evaluation)
    final_flow_residual = _normalized_matrix_residual(offered, target)
    final_full_residual = 0.0 if network.blocking == "loss" else max(
        abs(evaluation.full[i] - full_guess[i])
        for i in range(network.station_count)
    )
    final_residual = max(final_flow_residual, final_full_residual)
    if final_residual <= options.tolerance:
        converged = True

    warnings = _warnings(network, evaluation, converged, final_residual, options)
    result = _assemble_result(
        network=network,
        options=options,
        evaluation=evaluation,
        converged=converged,
        iterations=len(residual_history),
        residual=final_residual,
        residual_history=residual_history,
        warnings=warnings,
    )
    return result


def solve_document(
    document: dict[str, Any],
    *,
    tolerance: Optional[float] = None,
    max_iterations: Optional[int] = None,
    damping: Optional[float] = None,
) -> dict[str, Any]:
    network, defaults = parse_document(document)
    options = SolverOptions(
        tolerance=defaults.tolerance if tolerance is None else _finite_positive(
            tolerance, "tolerance override"
        ),
        max_iterations=defaults.max_iterations if max_iterations is None else _positive_int(
            max_iterations, "max_iterations override"
        ),
        damping=defaults.damping if damping is None else _finite_positive(
            damping, "damping override"
        ),
    )
    if options.damping > 1.0:
        raise InputError("damping override must be at most one")
    return solve(network, options)


def _warnings(
    network: Network,
    evaluation: Evaluation,
    converged: bool,
    residual: float,
    options: SolverOptions,
) -> list[str]:
    warnings: list[str] = []
    if not any(
        rate > 0.0
        for customer_class in network.classes
        for rate in customer_class.external_arrivals
    ):
        warnings.append("network has no positive external arrival rate.")
    if network.blocking != "loss":
        warnings.append(
            "BAS results are an independence/frozen-server approximation, "
            "not an exact blocking-after-service solution."
        )
    for i, station in enumerate(network.stations):
        rates = station.service_rates
        if max(rates) - min(rates) > 1.0e-12 * max(rates):
            warnings.append(
                f"{station.id}: class-dependent service is compressed to a "
                "flow-weighted harmonic mean in the M/M/c/K submodel."
            )
        if evaluation.full[i] >= 0.25:
            warnings.append(
                f"{station.id}: full probability is {evaluation.full[i]:.3g}; "
                "inter-station blocking correlations may be material."
            )
    if network.blocking != "loss":
        for k, customer_class in enumerate(network.classes):
            for i, station in enumerate(network.stations):
                availability = 1.0 - evaluation.downstream_blocking[k][i]
                if availability < 0.10:
                    warnings.append(
                        f"{customer_class.id}@{station.id}: downstream availability "
                        f"is only {availability:.3g}; BAS closure is near its numerical limit."
                    )
    if not converged:
        warnings.append(
            f"fixed point did not reach tolerance {options.tolerance:.3g} in "
            f"{options.max_iterations} iterations (residual {residual:.3g})."
        )
    return warnings


def _assemble_result(
    *,
    network: Network,
    options: SolverOptions,
    evaluation: Evaluation,
    converged: bool,
    iterations: int,
    residual: float,
    residual_history: list[float],
    warnings: list[str],
) -> dict[str, Any]:
    class_count = network.class_count
    station_count = network.station_count
    external = _external_matrix(network)
    full = evaluation.full
    throughputs = evaluation.throughputs

    external_admitted = _zeros(class_count, station_count)
    external_lost = _zeros(class_count, station_count)
    for k in range(class_count):
        for i in range(station_count):
            if network.blocking in {"loss", "bas_external_loss"}:
                external_admitted[k][i] = external[k][i] * (1.0 - full[i])
                external_lost[k][i] = external[k][i] * full[i]
            else:
                external_admitted[k][i] = external[k][i]

    internal_admitted = _zeros(class_count, station_count)
    internal_lost = _zeros(class_count, station_count)
    class_transition_in = [0.0 for _ in range(class_count)]
    class_transition_out = [0.0 for _ in range(class_count)]
    flows: list[dict[str, Any]] = []
    for route in network.routes:
        origin_rate = throughputs[route.from_class][route.from_station]
        routed_rate = origin_rate * route.probability
        if network.blocking == "loss":
            admitted = routed_rate * (1.0 - full[route.to_station])
            lost = routed_rate * full[route.to_station]
            equivalent_attempt = routed_rate
        else:
            admitted = routed_rate
            lost = 0.0
            equivalent_attempt = routed_rate / max(
                MIN_ACCEPTANCE, 1.0 - full[route.to_station]
            )
        internal_admitted[route.to_class][route.to_station] += admitted
        internal_lost[route.from_class][route.from_station] += lost
        if route.from_class != route.to_class:
            class_transition_out[route.from_class] += admitted
            class_transition_in[route.to_class] += admitted
        flows.append(
            {
                "from_class": network.classes[route.from_class].id,
                "from_station": network.stations[route.from_station].id,
                "to_class": network.classes[route.to_class].id,
                "to_station": network.stations[route.to_station].id,
                "routing_probability": route.probability,
                "routed_completion_rate": routed_rate,
                "equivalent_offered_attempt_rate": equivalent_attempt,
                "admitted_transfer_rate": admitted,
                "loss_rate": lost,
                "destination_full_probability": full[route.to_station],
            }
        )

    exit_by_class = [0.0 for _ in range(class_count)]
    exit_by_station_class = _zeros(class_count, station_count)
    for k in range(class_count):
        for i in range(station_count):
            exit_rate = throughputs[k][i] * (1.0 - network.route_sums[k][i])
            exit_by_class[k] += exit_rate
            exit_by_station_class[k][i] = exit_rate

    station_results: list[dict[str, Any]] = []
    class_mean_number = [0.0 for _ in range(class_count)]
    for i, station in enumerate(network.stations):
        model = evaluation.station_models[i]
        station_classes: list[dict[str, Any]] = []
        for k, customer_class in enumerate(network.classes):
            throughput = throughputs[k][i]
            wait = model.mean_waiting_time
            effective_mu = evaluation.effective_class_service_rates[k][i]
            if throughput > EPSILON and wait is not None:
                mean_in_service = throughput / effective_mu
                mean_queue = throughput * wait
                mean_number = mean_in_service + mean_queue
                mean_sojourn: Optional[float] = wait + 1.0 / effective_mu
            else:
                mean_in_service = 0.0
                mean_queue = 0.0
                mean_number = 0.0
                mean_sojourn = None
            class_mean_number[k] += mean_number
            station_classes.append(
                {
                    "id": customer_class.id,
                    "name": customer_class.name,
                    "offered_rate": evaluation.offered[k][i],
                    "external_offered_rate": external[k][i],
                    "external_admitted_rate": external_admitted[k][i],
                    "external_loss_rate": external_lost[k][i],
                    "internal_admitted_rate": internal_admitted[k][i],
                    "throughput": throughput,
                    "blocking_probability": full[i],
                    "base_service_rate": station.service_rates[k],
                    "effective_service_rate": effective_mu,
                    "downstream_blocking_probability": evaluation.downstream_blocking[k][i],
                    "mean_number": mean_number,
                    "mean_queue": mean_queue,
                    "mean_in_service": mean_in_service,
                    "mean_waiting_time": wait if throughput > EPSILON else None,
                    "mean_sojourn_time": mean_sojourn,
                    "utilization_contribution": mean_in_service / station.servers,
                    "exit_rate": exit_by_station_class[k][i],
                    "internal_loss_after_service_rate": internal_lost[k][i],
                }
            )
        admitted_rate = math.fsum(throughputs[k][i] for k in range(class_count))
        inflow_rate = math.fsum(
            external_admitted[k][i] + internal_admitted[k][i]
            for k in range(class_count)
        )
        station_results.append(
            {
                "id": station.id,
                "name": station.name,
                "servers": station.servers,
                "capacity": station.capacity,
                "capacity_includes_service": True,
                "offered_rate": math.fsum(
                    evaluation.offered[k][i] for k in range(class_count)
                ),
                "admitted_rate": admitted_rate,
                "successful_inflow_rate": inflow_rate,
                "throughput": admitted_rate,
                "blocking_probability": model.blocking_probability,
                "state_probabilities": list(model.probabilities),
                "effective_service_rate": evaluation.station_effective_service_rates[i],
                "mean_number": model.mean_number,
                "mean_queue": model.mean_queue,
                "mean_in_service": model.mean_in_service,
                "utilization": model.utilization,
                "waiting_probability_given_admission": model.waiting_probability_admitted,
                "mean_waiting_time": model.mean_waiting_time,
                "mean_sojourn_time": model.mean_sojourn_time,
                "local_birth_death_balance_residual": model.flow_balance_residual,
                "station_flow_conservation_residual": abs(admitted_rate - inflow_rate),
                "classes": station_classes,
            }
        )

    class_results: list[dict[str, Any]] = []
    class_conservation_residuals: list[float] = []
    for k, customer_class in enumerate(network.classes):
        external_offered_total = math.fsum(external[k])
        external_admitted_total = math.fsum(external_admitted[k])
        external_loss_total = math.fsum(external_lost[k])
        internal_loss_total = math.fsum(internal_lost[k])
        conservation = abs(
            external_offered_total + class_transition_in[k]
            - external_loss_total
            - internal_loss_total
            - exit_by_class[k]
            - class_transition_out[k]
        )
        class_conservation_residuals.append(conservation)
        class_entry_rate = external_admitted_total + class_transition_in[k]
        has_class_transition = class_transition_in[k] > EPSILON or class_transition_out[k] > EPSILON
        class_results.append(
            {
                "id": customer_class.id,
                "name": customer_class.name,
                "external_offered_rate": external_offered_total,
                "external_admitted_rate": external_admitted_total,
                "external_loss_rate": external_loss_total,
                "internal_loss_rate": internal_loss_total,
                "transition_in_rate": class_transition_in[k],
                "transition_out_rate": class_transition_out[k],
                "exit_rate": exit_by_class[k],
                "mean_number_in_network": class_mean_number[k],
                "mean_residence_time_in_class": (
                    class_mean_number[k] / class_entry_rate
                    if class_entry_rate > EPSILON
                    else None
                ),
                "mean_time_in_network_until_exit_or_loss": (
                    None
                    if has_class_transition
                    else (
                        class_mean_number[k] / external_admitted_total
                        if external_admitted_total > EPSILON
                        else None
                    )
                ),
                "flow_conservation_residual": conservation,
            }
        )

    total_external = math.fsum(math.fsum(row) for row in external)
    total_external_admitted = math.fsum(
        math.fsum(row) for row in external_admitted
    )
    total_external_loss = math.fsum(math.fsum(row) for row in external_lost)
    total_internal_loss = math.fsum(math.fsum(row) for row in internal_lost)
    total_exit = math.fsum(exit_by_class)
    network_conservation = abs(
        total_external - total_external_loss - total_internal_loss - total_exit
    )
    if network_conservation > max(options.tolerance * 10.0, 1.0e-9):
        warnings.append(
            f"network flow conservation residual is {network_conservation:.3g}."
        )

    bas = network.blocking != "loss"
    semantics = {
        "mode": network.blocking,
        "loss_semantics_complete": network.blocking == "loss",
        "bas_is_approximation": bas,
        "description": (
            "Arrivals that see a full station are lost, including internal transfers."
            if network.blocking == "loss"
            else (
                "Internal transfers wait upstream; external arrivals that see a full "
                "station are lost. Downstream blocking uses an independence/frozen-server approximation."
                if network.blocking == "bas_external_loss"
                else "Internal transfers and external sources wait for space. Downstream "
                "blocking uses an independence/frozen-server approximation."
            )
        ),
    }

    return {
        "schema_version": OUTPUT_SCHEMA_VERSION,
        "method": {
            "id": "finite.mmck-fixed-point-decomposition",
            "name": "Finite-buffer M/M/c/K fixed-point decomposition",
            "model_layer": "queueing approximation",
        },
        "input_name": network.name,
        "status": "converged" if converged else "not_converged",
        "semantics": semantics,
        "convergence": {
            "converged": converged,
            "iterations": iterations,
            "residual": residual,
            "tolerance": options.tolerance,
            "max_iterations": options.max_iterations,
            "damping": options.damping,
            "initial_residual": residual_history[0] if residual_history else residual,
            "residual_history_tail": residual_history[-10:],
        },
        "network": {
            "station_count": station_count,
            "class_count": class_count,
            "external_offered_rate": total_external,
            "external_admitted_rate": total_external_admitted,
            "external_loss_rate": total_external_loss,
            "internal_loss_rate": total_internal_loss,
            "exit_rate": total_exit,
            "internal_admitted_transfer_rate": math.fsum(
                math.fsum(row) for row in internal_admitted
            ),
            "mean_number": math.fsum(
                station["mean_number"] for station in station_results
            ),
            "flow_conservation_residual": network_conservation,
            "maximum_class_conservation_residual": max(
                class_conservation_residuals, default=0.0
            ),
        },
        "classes": class_results,
        "stations": station_results,
        "flows": flows,
        "warnings": warnings,
    }


def format_text(result: dict[str, Any]) -> str:
    convergence = result["convergence"]
    network = result["network"]
    semantics = result["semantics"]
    lines = [
        "FINITE-BUFFER M/M/c/K DECOMPOSITION",
        "====================================",
        f"Network: {result['input_name']}",
        f"Status: {result['status']}",
        f"Blocking: {semantics['mode']}",
        f"Semantics: {semantics['description']}",
        (
            "Convergence: iterations={iterations} residual={residual:.6g} "
            "tolerance={tolerance:.6g} damping={damping:.3g}"
        ).format(**convergence),
        (
            "Network flow: external={external_offered_rate:.6g} "
            "external_loss={external_loss_rate:.6g} "
            "internal_loss={internal_loss_rate:.6g} exit={exit_rate:.6g} "
            "residual={flow_conservation_residual:.3g}"
        ).format(**network),
        "",
    ]
    for index, station in enumerate(result["stations"], start=1):
        lines.append(
            "S{index} {name}: offered={offered_rate:.6g} throughput={throughput:.6g} "
            "P(full)={blocking_probability:.6g} E[N]={mean_number:.6g} "
            "E[Q]={mean_queue:.6g} util={utilization:.6g} W={wait} T={sojourn}".format(
                index=index,
                name=station["name"],
                offered_rate=station["offered_rate"],
                throughput=station["throughput"],
                blocking_probability=station["blocking_probability"],
                mean_number=station["mean_number"],
                mean_queue=station["mean_queue"],
                utilization=station["utilization"],
                wait=_text_number(station["mean_waiting_time"]),
                sojourn=_text_number(station["mean_sojourn_time"]),
            )
        )
        for customer_class in station["classes"]:
            lines.append(
                "  {id}: offered={offered_rate:.6g} throughput={throughput:.6g} "
                "E[N]={mean_number:.6g} T={sojourn}".format(
                    **customer_class,
                    sojourn=_text_number(customer_class["mean_sojourn_time"]),
                )
            )
    if result["warnings"]:
        lines.extend(["", "Warnings:"])
        lines.extend(f"  - {warning}" for warning in result["warnings"])
    return "\n".join(lines) + "\n"


def _text_number(value: Optional[float]) -> str:
    return "n/a" if value is None else f"{value:.6g}"


def _read_json(path: str) -> dict[str, Any]:
    try:
        if path == "-":
            value = json.load(sys.stdin)
        else:
            with Path(path).open("r", encoding="utf-8") as handle:
                value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise InputError(f"could not read input JSON: {error}") from error
    if not isinstance(value, dict):
        raise InputError("input JSON root must be an object")
    return value


def _write_output(text: str, path: Optional[str]) -> None:
    if path is None or path == "-":
        sys.stdout.write(text)
        return
    try:
        Path(path).write_text(text, encoding="utf-8")
    except OSError as error:
        raise InputError(f"could not write output: {error}") from error


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="input JSON file, or - for standard input")
    parser.add_argument(
        "--format", choices=("json", "text"), default="json", help="output format"
    )
    parser.add_argument("-o", "--output", help="output file; default is standard output")
    parser.add_argument("--tolerance", type=float, help="override solver tolerance")
    parser.add_argument("--max-iterations", type=int, help="override iteration cap")
    parser.add_argument("--damping", type=float, help="override damping in (0, 1]")
    parser.add_argument(
        "--compact", action="store_true", help="emit compact rather than indented JSON"
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    try:
        document = _read_json(args.input)
        result = solve_document(
            document,
            tolerance=args.tolerance,
            max_iterations=args.max_iterations,
            damping=args.damping,
        )
        if args.format == "text":
            output = format_text(result)
        else:
            output = json.dumps(
                result,
                indent=None if args.compact else 2,
                sort_keys=True,
                allow_nan=False,
            ) + "\n"
        _write_output(output, args.output)
        return 0 if result["convergence"]["converged"] else 3
    except InputError as error:
        print(f"fBNAdecomp: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
