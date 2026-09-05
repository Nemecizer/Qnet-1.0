#!/usr/bin/env python3
"""Sparse finite-state CTMC solver for open Markovian queueing networks.

The state at each station is an ordered tuple of customer classes.  The first
``servers`` entries are in service and the remainder wait FCFS.  External
arrivals are Poisson, service times are exponential by station and class, and
routing occurs at service completion.  An arrival or routed transfer that
finds its destination at total capacity is lost.

The generator is stored as off-diagonal adjacency lists.  Stationary
probabilities are computed without constructing a dense matrix, using
uniformization followed by power iteration.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


State = Tuple[Tuple[int, ...], ...]


class ConfigError(ValueError):
    """The input document does not describe a supported CTMC."""


class StateSpaceLimitError(RuntimeError):
    """Reachability enumeration exceeded its configured safety limit."""


class ConvergenceError(RuntimeError):
    """The stationary iteration did not meet its requested tolerance."""


@dataclass(frozen=True)
class Station:
    station_id: str
    servers: int
    capacity: int
    service_rates: Tuple[Optional[float], ...]


@dataclass(frozen=True)
class ExternalArrival:
    station: int
    customer_class: int
    rate: float


@dataclass(frozen=True)
class Route:
    station: Optional[int]
    customer_class: Optional[int]
    probability: float


@dataclass(frozen=True)
class SolverSettings:
    tolerance: float = 1.0e-12
    max_iterations: int = 200_000
    max_states: int = 200_000
    uniformization_slack: float = 0.05


@dataclass(frozen=True)
class NetworkModel:
    name: str
    class_ids: Tuple[str, ...]
    stations: Tuple[Station, ...]
    external_arrivals: Tuple[ExternalArrival, ...]
    routing: Mapping[Tuple[int, int], Tuple[Route, ...]]
    settings: SolverSettings

    def service_rate(self, station: int, customer_class: int) -> float:
        rate = self.stations[station].service_rates[customer_class]
        if rate is None:
            raise ConfigError(
                "no service rate for class {!r} at station {!r}".format(
                    self.class_ids[customer_class],
                    self.stations[station].station_id,
                )
            )
        return rate

    def routes(self, station: int, customer_class: int) -> Tuple[Route, ...]:
        routes = self.routing.get((station, customer_class))
        if routes is not None:
            return routes
        return (Route(None, None, 1.0),)


@dataclass(frozen=True)
class SparseChain:
    states: Tuple[State, ...]
    rows: Tuple[Tuple[Tuple[int, float], ...], ...]
    leaving_rates: Tuple[float, ...]
    off_diagonal_count: int


@dataclass(frozen=True)
class StationarySolution:
    probabilities: Tuple[float, ...]
    iterations: int
    converged: bool
    l1_step: float
    generator_residual_l1: float
    uniformization_rate: float


def _mapping(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError("{} must be a JSON object".format(context))
    return value


def _sequence(value: Any, context: str) -> Sequence[Any]:
    if not isinstance(value, list):
        raise ConfigError("{} must be a JSON array".format(context))
    return value


def _nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError("{} must be a non-empty string".format(context))
    return value.strip()


def _integer(value: Any, context: str, minimum: int = 1) -> int:
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


def _positive_number(value: Any, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError("{} must be a positive finite number".format(context))
    result = float(value)
    if not math.isfinite(result) or result <= 0.0:
        raise ConfigError("{} must be a positive finite number".format(context))
    return result


def _probability(value: Any, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError("{} must be a probability in (0, 1]".format(context))
    result = float(value)
    if not math.isfinite(result) or result <= 0.0 or result > 1.0:
        raise ConfigError("{} must be a probability in (0, 1]".format(context))
    return result


def _check_keys(
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


def parse_model(document: Mapping[str, Any]) -> NetworkModel:
    """Validate a decoded JSON document and return an indexed network model."""

    root = _mapping(document, "document")
    _check_keys(
        root,
        {
            "schema_version",
            "name",
            "description",
            "blocking",
            "service_discipline",
            "classes",
            "stations",
            "external_arrivals",
            "routing",
            "solver",
        },
        "document",
    )
    for required_field in (
        "schema_version",
        "name",
        "classes",
        "stations",
        "external_arrivals",
    ):
        if required_field not in root:
            raise ConfigError("document is missing required field {!r}".format(required_field))

    version = _integer(root["schema_version"], "schema_version")
    if version != 1:
        raise ConfigError("schema_version must be 1")
    if "description" in root and not isinstance(root["description"], str):
        raise ConfigError("description must be a string")

    blocking = root.get("blocking", "loss")
    if blocking != "loss":
        raise ConfigError(
            "blocking={!r} is not supported by generic_ctmc; use 'loss'. "
            "The existing finite/fBNActmc tandem solver handles BAS models."
            .format(blocking)
        )

    service_discipline = root.get("service_discipline", "fcfs")
    if service_discipline != "fcfs":
        raise ConfigError(
            "service_discipline={!r} is not supported; generic_ctmc uses 'fcfs'"
            .format(service_discipline)
        )

    name = _nonempty_string(root["name"], "name")
    class_values = _sequence(root.get("classes"), "classes")
    if not class_values:
        raise ConfigError("classes must contain at least one class id")
    class_ids = tuple(
        _nonempty_string(value, "classes[{}]".format(index))
        for index, value in enumerate(class_values)
    )
    if len(set(class_ids)) != len(class_ids):
        raise ConfigError("class ids must be unique")
    class_index = {class_id: i for i, class_id in enumerate(class_ids)}

    station_values = _sequence(root.get("stations"), "stations")
    if not station_values:
        raise ConfigError("stations must contain at least one station")
    stations: List[Station] = []
    station_index: Dict[str, int] = {}
    for index, raw_station in enumerate(station_values):
        context = "stations[{}]".format(index)
        station_obj = _mapping(raw_station, context)
        _check_keys(
            station_obj,
            {"id", "servers", "capacity", "service_rates"},
            context,
        )
        station_id = _nonempty_string(station_obj.get("id"), context + ".id")
        if station_id in station_index:
            raise ConfigError("station ids must be unique: {!r}".format(station_id))
        servers = _integer(station_obj.get("servers"), context + ".servers")
        capacity = _integer(station_obj.get("capacity"), context + ".capacity")
        if servers > capacity:
            raise ConfigError(
                "{}.servers cannot exceed total in-system capacity".format(context)
            )
        rate_obj = _mapping(
            station_obj.get("service_rates"), context + ".service_rates"
        )
        if not rate_obj:
            raise ConfigError("{}.service_rates cannot be empty".format(context))
        unknown_classes = sorted(set(rate_obj) - set(class_index))
        if unknown_classes:
            raise ConfigError(
                "{}.service_rates refers to unknown classes: {}".format(
                    context, ", ".join(unknown_classes)
                )
            )
        rates: List[Optional[float]] = [None] * len(class_ids)
        for class_id, raw_rate in rate_obj.items():
            rates[class_index[class_id]] = _positive_number(
                raw_rate,
                "{}.service_rates.{}".format(context, class_id),
            )
        station_index[station_id] = index
        stations.append(Station(station_id, servers, capacity, tuple(rates)))

    arrival_values = _sequence(
        root.get("external_arrivals", []), "external_arrivals"
    )
    arrivals: List[ExternalArrival] = []
    for index, raw_arrival in enumerate(arrival_values):
        context = "external_arrivals[{}]".format(index)
        arrival_obj = _mapping(raw_arrival, context)
        _check_keys(arrival_obj, {"station", "class", "rate"}, context)
        station_id = _nonempty_string(
            arrival_obj.get("station"), context + ".station"
        )
        class_id = _nonempty_string(arrival_obj.get("class"), context + ".class")
        if station_id not in station_index:
            raise ConfigError("{} refers to unknown station {!r}".format(context, station_id))
        if class_id not in class_index:
            raise ConfigError("{} refers to unknown class {!r}".format(context, class_id))
        s = station_index[station_id]
        c = class_index[class_id]
        rate = _positive_number(arrival_obj.get("rate"), context + ".rate")
        if stations[s].service_rates[c] is None:
            raise ConfigError(
                "{} targets class {!r} at station {!r}, but no service rate is defined"
                .format(context, class_id, station_id)
            )
        arrivals.append(ExternalArrival(s, c, rate))

    routing_values = _sequence(root.get("routing", []), "routing")
    routing: Dict[Tuple[int, int], Tuple[Route, ...]] = {}
    for index, raw_rule in enumerate(routing_values):
        context = "routing[{}]".format(index)
        rule_obj = _mapping(raw_rule, context)
        _check_keys(
            rule_obj,
            {"from_station", "from_class", "destinations"},
            context,
        )
        from_station_id = _nonempty_string(
            rule_obj.get("from_station"), context + ".from_station"
        )
        from_class_id = _nonempty_string(
            rule_obj.get("from_class"), context + ".from_class"
        )
        if from_station_id not in station_index:
            raise ConfigError(
                "{} refers to unknown source station {!r}".format(
                    context, from_station_id
                )
            )
        if from_class_id not in class_index:
            raise ConfigError(
                "{} refers to unknown source class {!r}".format(
                    context, from_class_id
                )
            )
        from_station = station_index[from_station_id]
        from_class = class_index[from_class_id]
        source_key = (from_station, from_class)
        if source_key in routing:
            raise ConfigError(
                "duplicate routing rule for class {!r} at station {!r}".format(
                    from_class_id, from_station_id
                )
            )
        if stations[from_station].service_rates[from_class] is None:
            raise ConfigError(
                "routing source class {!r} at station {!r} has no service rate"
                .format(from_class_id, from_station_id)
            )

        destination_values = _sequence(
            rule_obj.get("destinations"), context + ".destinations"
        )
        if not destination_values:
            raise ConfigError("{}.destinations cannot be empty".format(context))
        parsed_routes: List[Route] = []
        raw_destinations_seen = set()
        total_probability = 0.0
        for dest_index, raw_destination in enumerate(destination_values):
            dest_context = "{}.destinations[{}]".format(context, dest_index)
            dest_obj = _mapping(raw_destination, dest_context)
            _check_keys(
                dest_obj,
                {"station", "class", "exit", "probability"},
                dest_context,
            )
            probability = _probability(
                dest_obj.get("probability"), dest_context + ".probability"
            )
            is_exit = dest_obj.get("exit", False)
            if not isinstance(is_exit, bool):
                raise ConfigError("{}.exit must be a boolean".format(dest_context))
            if is_exit:
                if "station" in dest_obj or "class" in dest_obj:
                    raise ConfigError(
                        "{} cannot combine exit=true with station/class".format(
                            dest_context
                        )
                    )
                destination_key = (None, None)
                if destination_key in raw_destinations_seen:
                    raise ConfigError("{} contains a duplicate exit destination".format(context))
                raw_destinations_seen.add(destination_key)
                parsed_routes.append(Route(None, None, probability))
            else:
                if "exit" in dest_obj:
                    raise ConfigError(
                        "{}.exit may only be supplied as true for an exit destination"
                        .format(dest_context)
                    )
                destination_station_id = _nonempty_string(
                    dest_obj.get("station"), dest_context + ".station"
                )
                destination_class_id = _nonempty_string(
                    dest_obj.get("class", from_class_id), dest_context + ".class"
                )
                if destination_station_id not in station_index:
                    raise ConfigError(
                        "{} refers to unknown station {!r}".format(
                            dest_context, destination_station_id
                        )
                    )
                if destination_class_id not in class_index:
                    raise ConfigError(
                        "{} refers to unknown class {!r}".format(
                            dest_context, destination_class_id
                        )
                    )
                destination_station = station_index[destination_station_id]
                destination_class = class_index[destination_class_id]
                if stations[destination_station].service_rates[destination_class] is None:
                    raise ConfigError(
                        "{} targets class {!r} at station {!r}, but no service rate is defined"
                        .format(
                            dest_context,
                            destination_class_id,
                            destination_station_id,
                        )
                    )
                destination_key = (destination_station, destination_class)
                if destination_key in raw_destinations_seen:
                    raise ConfigError(
                        "{} contains duplicate destination class {!r} at station {!r}"
                        .format(
                            context,
                            destination_class_id,
                            destination_station_id,
                        )
                    )
                raw_destinations_seen.add(destination_key)
                parsed_routes.append(
                    Route(destination_station, destination_class, probability)
                )
            total_probability += probability

        if total_probability > 1.0 + 1.0e-12:
            raise ConfigError(
                "{} routing probabilities sum to {:.17g}, which exceeds 1"
                .format(context, total_probability)
            )
        if total_probability > 1.0:
            parsed_routes = [
                Route(route.station, route.customer_class, route.probability / total_probability)
                for route in parsed_routes
            ]
            total_probability = 1.0
        remainder = 1.0 - total_probability
        if remainder > 1.0e-15:
            parsed_routes.append(Route(None, None, remainder))
        routing[source_key] = tuple(parsed_routes)

    solver_obj = _mapping(root.get("solver", {}), "solver")
    _check_keys(
        solver_obj,
        {"tolerance", "max_iterations", "max_states", "uniformization_slack"},
        "solver",
    )
    tolerance = _positive_number(
        solver_obj.get("tolerance", 1.0e-12), "solver.tolerance"
    )
    max_iterations = _integer(
        solver_obj.get("max_iterations", 200_000), "solver.max_iterations"
    )
    max_states = _integer(
        solver_obj.get("max_states", 200_000), "solver.max_states"
    )
    slack = _positive_number(
        solver_obj.get("uniformization_slack", 0.05),
        "solver.uniformization_slack",
    )
    if slack > 10.0:
        raise ConfigError("solver.uniformization_slack must be <= 10")

    # The format describes an open network. Requiring an exit path from every
    # station/class pair reachable from an external stream guarantees that
    # every enumerated state can drain to empty. Because every enumerated state
    # is reachable from empty, the reachable CTMC then has one communicating
    # class and a unique stationary distribution.
    reachable_pairs = {
        (arrival.station, arrival.customer_class) for arrival in arrivals
    }
    frontier = deque(reachable_pairs)
    while frontier:
        pair = frontier.popleft()
        pair_routes = routing.get(pair, (Route(None, None, 1.0),))
        for route in pair_routes:
            if route.station is None:
                continue
            if route.customer_class is None:
                raise ConfigError("internal routing destination has no customer class")
            indexed_destination = (route.station, route.customer_class)
            if indexed_destination not in reachable_pairs:
                reachable_pairs.add(indexed_destination)
                frontier.append(indexed_destination)

    can_reach_exit = {
        pair
        for pair in reachable_pairs
        if any(
            route.station is None
            for route in routing.get(pair, (Route(None, None, 1.0),))
        )
    }
    changed = True
    while changed:
        changed = False
        for pair in reachable_pairs - can_reach_exit:
            if any(
                route.station is not None
                and (route.station, route.customer_class) in can_reach_exit
                for route in routing.get(pair, (Route(None, None, 1.0),))
            ):
                can_reach_exit.add(pair)
                changed = True
    trapped_pairs = reachable_pairs - can_reach_exit
    if trapped_pairs:
        labels = sorted(
            "{}/{}".format(stations[s].station_id, class_ids[c])
            for s, c in trapped_pairs
        )
        raise ConfigError(
            "network is not open: reachable station/class pair{} {} cannot "
            "reach an exit; the stationary distribution would not be unique"
            .format("s" if len(labels) != 1 else "", ", ".join(labels))
        )

    return NetworkModel(
        name=name,
        class_ids=class_ids,
        stations=tuple(stations),
        external_arrivals=tuple(arrivals),
        routing=routing,
        settings=SolverSettings(tolerance, max_iterations, max_states, slack),
    )


def load_model(path: Path) -> NetworkModel:
    """Load and validate a model from a UTF-8 JSON file."""

    try:
        with path.open("r", encoding="utf-8") as stream:
            document = json.load(stream)
    except OSError as error:
        raise ConfigError("cannot read {}: {}".format(path, error)) from error
    except json.JSONDecodeError as error:
        raise ConfigError(
            "invalid JSON in {} at line {}, column {}: {}".format(
                path, error.lineno, error.colno, error.msg
            )
        ) from error
    return parse_model(_mapping(document, "document"))


def empty_state(model: NetworkModel) -> State:
    return tuple(() for _ in model.stations)


def _replace_queue(state: State, station: int, queue: Sequence[int]) -> State:
    queues = list(state)
    queues[station] = tuple(queue)
    return tuple(queues)


def _arrival_state(
    model: NetworkModel, state: State, station: int, customer_class: int
) -> Optional[State]:
    queue = state[station]
    if len(queue) >= model.stations[station].capacity:
        return None
    return _replace_queue(state, station, queue + (customer_class,))


def transition_rates(model: NetworkModel, state: State) -> Dict[State, float]:
    """Return aggregated positive-rate state changes from ``state``.

    Lost arrivals and other events that leave the observable state unchanged
    are rewards, not off-diagonal generator entries, and are intentionally
    omitted.  This is the standard minimal CTMC generator for the state
    process.
    """

    rates: Dict[State, float] = {}

    def add(next_state: Optional[State], rate: float) -> None:
        if next_state is None or next_state == state or rate <= 0.0:
            return
        rates[next_state] = rates.get(next_state, 0.0) + rate

    for arrival in model.external_arrivals:
        add(
            _arrival_state(
                model, state, arrival.station, arrival.customer_class
            ),
            arrival.rate,
        )

    for source_station, station in enumerate(model.stations):
        queue = state[source_station]
        for service_position, source_class in enumerate(queue[: station.servers]):
            service_rate = model.service_rate(source_station, source_class)
            source_after = list(queue)
            del source_after[service_position]
            base_queues = list(state)
            base_queues[source_station] = tuple(source_after)
            departure_state = tuple(base_queues)

            for route in model.routes(source_station, source_class):
                event_rate = service_rate * route.probability
                if route.station is None:
                    add(departure_state, event_rate)
                    continue

                destination_station = route.station
                destination_class = route.customer_class
                if destination_class is None:
                    raise ConfigError("internal routing destination has no customer class")
                destination_queue = departure_state[destination_station]
                if len(destination_queue) >= model.stations[destination_station].capacity:
                    # Completion occurred, but the routed customer is lost.
                    add(departure_state, event_rate)
                else:
                    routed_queues = list(departure_state)
                    routed_queues[destination_station] = (
                        destination_queue + (destination_class,)
                    )
                    add(tuple(routed_queues), event_rate)

    return rates


def enumerate_chain(model: NetworkModel, max_states: Optional[int] = None) -> SparseChain:
    """Breadth-first enumeration of states reachable from the empty network."""

    limit = model.settings.max_states if max_states is None else max_states
    if limit < 1:
        raise ValueError("max_states must be >= 1")

    initial = empty_state(model)
    states: List[State] = [initial]
    state_index: Dict[State, int] = {initial: 0}
    rows: List[Tuple[Tuple[int, float], ...]] = []
    leaving_rates: List[float] = []
    pending = deque([initial])
    off_diagonal_count = 0

    while pending:
        state = pending.popleft()
        indexed_row: List[Tuple[int, float]] = []
        for next_state, rate in transition_rates(model, state).items():
            next_index = state_index.get(next_state)
            if next_index is None:
                if len(states) >= limit:
                    raise StateSpaceLimitError(
                        "reachable state count exceeds max_states={}; increase the "
                        "limit deliberately or reduce capacities/classes".format(limit)
                    )
                next_index = len(states)
                state_index[next_state] = next_index
                states.append(next_state)
                pending.append(next_state)
            indexed_row.append((next_index, rate))
        indexed_row.sort(key=lambda item: item[0])
        row = tuple(indexed_row)
        rows.append(row)
        row_leaving_rate = sum(rate for _, rate in row)
        leaving_rates.append(row_leaving_rate)
        off_diagonal_count += len(row)

    return SparseChain(
        states=tuple(states),
        rows=tuple(rows),
        leaving_rates=tuple(leaving_rates),
        off_diagonal_count=off_diagonal_count,
    )


def generator_residual_l1(
    chain: SparseChain, probabilities: Sequence[float]
) -> float:
    """Compute ``||pi Q||_1`` without materializing Q."""

    residual = [0.0] * len(chain.states)
    for source, mass in enumerate(probabilities):
        if mass == 0.0:
            continue
        residual[source] -= mass * chain.leaving_rates[source]
        for destination, rate in chain.rows[source]:
            residual[destination] += mass * rate
    return sum(abs(value) for value in residual)


def solve_stationary(
    chain: SparseChain,
    tolerance: float = 1.0e-12,
    max_iterations: int = 200_000,
    uniformization_slack: float = 0.05,
) -> StationarySolution:
    """Solve for the stationary row vector by matrix-free uniformization."""

    if tolerance <= 0.0 or not math.isfinite(tolerance):
        raise ValueError("tolerance must be positive and finite")
    if max_iterations < 1:
        raise ValueError("max_iterations must be >= 1")
    if uniformization_slack <= 0.0 or not math.isfinite(uniformization_slack):
        raise ValueError("uniformization_slack must be positive and finite")

    state_count = len(chain.states)
    if state_count == 0:
        raise ValueError("chain has no states")
    maximum_leaving_rate = max(chain.leaving_rates)
    if maximum_leaving_rate == 0.0:
        probabilities = (1.0,) + (0.0,) * (state_count - 1)
        return StationarySolution(probabilities, 0, True, 0.0, 0.0, 0.0)

    uniformization_rate = maximum_leaving_rate * (1.0 + uniformization_slack)
    probabilities = [0.0] * state_count
    probabilities[0] = 1.0
    last_step = math.inf

    for iteration in range(1, max_iterations + 1):
        next_probabilities = [0.0] * state_count
        for source, mass in enumerate(probabilities):
            if mass == 0.0:
                continue
            self_probability = 1.0 - chain.leaving_rates[source] / uniformization_rate
            next_probabilities[source] += mass * self_probability
            scale = mass / uniformization_rate
            for destination, rate in chain.rows[source]:
                next_probabilities[destination] += scale * rate

        total = sum(next_probabilities)
        if not math.isfinite(total) or total <= 0.0:
            raise ConvergenceError("stationary iteration produced invalid probability mass")
        if abs(total - 1.0) > 1.0e-14:
            inverse_total = 1.0 / total
            next_probabilities = [value * inverse_total for value in next_probabilities]

        last_step = sum(
            abs(new - old)
            for new, old in zip(next_probabilities, probabilities)
        )
        probabilities = next_probabilities
        if last_step <= tolerance:
            residual = generator_residual_l1(chain, probabilities)
            return StationarySolution(
                probabilities=tuple(probabilities),
                iterations=iteration,
                converged=True,
                l1_step=last_step,
                generator_residual_l1=residual,
                uniformization_rate=uniformization_rate,
            )

    residual = generator_residual_l1(chain, probabilities)
    return StationarySolution(
        probabilities=tuple(probabilities),
        iterations=max_iterations,
        converged=False,
        l1_step=last_step,
        generator_residual_l1=residual,
        uniformization_rate=uniformization_rate,
    )


def _zeros(rows: int, columns: int) -> List[List[float]]:
    return [[0.0 for _ in range(columns)] for _ in range(rows)]


def _ratio(numerator: float, denominator: float) -> Optional[float]:
    return numerator / denominator if denominator > 0.0 else None


def compute_measures(
    model: NetworkModel,
    chain: SparseChain,
    solution: StationarySolution,
) -> Dict[str, Any]:
    """Compute state rewards grouped by network, station, and class."""

    station_count = len(model.stations)
    class_count = len(model.class_ids)
    mean_number = _zeros(station_count, class_count)
    mean_in_service = _zeros(station_count, class_count)
    mean_waiting = _zeros(station_count, class_count)
    completions = _zeros(station_count, class_count)
    external_attempts = _zeros(station_count, class_count)
    external_accepted = _zeros(station_count, class_count)
    external_lost = _zeros(station_count, class_count)
    internal_attempts = _zeros(station_count, class_count)
    internal_accepted = _zeros(station_count, class_count)
    internal_lost = _zeros(station_count, class_count)
    exits = _zeros(station_count, class_count)
    probability_full = [0.0] * station_count
    probability_empty = [0.0] * station_count

    for state, probability in zip(chain.states, solution.probabilities):
        if probability == 0.0:
            continue
        for station_index, station in enumerate(model.stations):
            queue = state[station_index]
            if not queue:
                probability_empty[station_index] += probability
            if len(queue) == station.capacity:
                probability_full[station_index] += probability
            for position, customer_class in enumerate(queue):
                mean_number[station_index][customer_class] += probability
                if position < station.servers:
                    mean_in_service[station_index][customer_class] += probability
                else:
                    mean_waiting[station_index][customer_class] += probability

        for arrival in model.external_arrivals:
            event_rate = probability * arrival.rate
            external_attempts[arrival.station][arrival.customer_class] += event_rate
            if len(state[arrival.station]) < model.stations[arrival.station].capacity:
                external_accepted[arrival.station][arrival.customer_class] += event_rate
            else:
                external_lost[arrival.station][arrival.customer_class] += event_rate

        for source_station, station in enumerate(model.stations):
            queue = state[source_station]
            for service_position, source_class in enumerate(queue[: station.servers]):
                base_rate = probability * model.service_rate(
                    source_station, source_class
                )
                completions[source_station][source_class] += base_rate
                for route in model.routes(source_station, source_class):
                    event_rate = base_rate * route.probability
                    if route.station is None:
                        exits[source_station][source_class] += event_rate
                        continue
                    destination_station = route.station
                    destination_class = route.customer_class
                    if destination_class is None:
                        raise ConfigError("internal routing destination has no customer class")
                    internal_attempts[destination_station][destination_class] += event_rate
                    destination_length_after_completion = len(state[destination_station])
                    if destination_station == source_station:
                        destination_length_after_completion -= 1
                    if (
                        destination_length_after_completion
                        < model.stations[destination_station].capacity
                    ):
                        internal_accepted[destination_station][destination_class] += event_rate
                    else:
                        internal_lost[destination_station][destination_class] += event_rate

    station_results: List[Dict[str, Any]] = []
    maximum_class_balance_residual = 0.0
    for station_index, station in enumerate(model.stations):
        class_results: List[Dict[str, Any]] = []
        for customer_class, class_id in enumerate(model.class_ids):
            accepted = (
                external_accepted[station_index][customer_class]
                + internal_accepted[station_index][customer_class]
            )
            completion_rate = completions[station_index][customer_class]
            balance_residual = accepted - completion_rate
            maximum_class_balance_residual = max(
                maximum_class_balance_residual, abs(balance_residual)
            )
            class_results.append(
                {
                    "class": class_id,
                    "service_rate": station.service_rates[customer_class],
                    "mean_number": mean_number[station_index][customer_class],
                    "mean_in_service": mean_in_service[station_index][customer_class],
                    "mean_waiting": mean_waiting[station_index][customer_class],
                    "service_completion_rate": completion_rate,
                    "external_arrival_rate": external_attempts[station_index][customer_class],
                    "external_accepted_rate": external_accepted[station_index][customer_class],
                    "external_loss_rate": external_lost[station_index][customer_class],
                    "internal_arrival_rate": internal_attempts[station_index][customer_class],
                    "internal_accepted_rate": internal_accepted[station_index][customer_class],
                    "internal_loss_rate": internal_lost[station_index][customer_class],
                    "accepted_arrival_rate": accepted,
                    "mean_sojourn_time": _ratio(
                        mean_number[station_index][customer_class], accepted
                    ),
                    "mean_waiting_time": _ratio(
                        mean_waiting[station_index][customer_class], accepted
                    ),
                    "flow_balance_residual": balance_residual,
                    "exit_rate": exits[station_index][customer_class],
                }
            )

        station_mean_number = sum(mean_number[station_index])
        station_mean_in_service = sum(mean_in_service[station_index])
        station_mean_waiting = sum(mean_waiting[station_index])
        station_completion_rate = sum(completions[station_index])
        station_accepted_rate = sum(external_accepted[station_index]) + sum(
            internal_accepted[station_index]
        )
        external_attempt_rate = sum(external_attempts[station_index])
        external_accepted_rate = sum(external_accepted[station_index])
        external_loss_rate = sum(external_lost[station_index])
        internal_attempt_rate = sum(internal_attempts[station_index])
        internal_accepted_rate = sum(internal_accepted[station_index])
        internal_loss_rate = sum(internal_lost[station_index])
        station_results.append(
            {
                "id": station.station_id,
                "servers": station.servers,
                "capacity": station.capacity,
                "mean_number": station_mean_number,
                "mean_in_service": station_mean_in_service,
                "mean_waiting": station_mean_waiting,
                "server_utilization": station_mean_in_service / station.servers,
                "probability_empty": probability_empty[station_index],
                "probability_full": probability_full[station_index],
                "service_completion_rate": station_completion_rate,
                "accepted_arrival_rate": station_accepted_rate,
                "mean_sojourn_time": _ratio(
                    station_mean_number, station_accepted_rate
                ),
                "mean_waiting_time": _ratio(
                    station_mean_waiting, station_accepted_rate
                ),
                "external_arrival_rate": external_attempt_rate,
                "external_accepted_rate": external_accepted_rate,
                "external_loss_rate": external_loss_rate,
                "external_loss_probability": _ratio(
                    external_loss_rate, external_attempt_rate
                ),
                "internal_arrival_rate": internal_attempt_rate,
                "internal_accepted_rate": internal_accepted_rate,
                "internal_loss_rate": internal_loss_rate,
                "internal_loss_probability": _ratio(
                    internal_loss_rate, internal_attempt_rate
                ),
                "exit_rate": sum(exits[station_index]),
                "flow_balance_residual": station_accepted_rate
                - station_completion_rate,
                "classes": class_results,
            }
        )

    total_external_attempts = sum(sum(row) for row in external_attempts)
    total_external_accepted = sum(sum(row) for row in external_accepted)
    total_external_lost = sum(sum(row) for row in external_lost)
    total_internal_attempts = sum(sum(row) for row in internal_attempts)
    total_internal_accepted = sum(sum(row) for row in internal_accepted)
    total_internal_lost = sum(sum(row) for row in internal_lost)
    total_exit_rate = sum(sum(row) for row in exits)
    mean_total_number = sum(sum(row) for row in mean_number)
    mean_total_in_service = sum(sum(row) for row in mean_in_service)
    mean_total_waiting = sum(sum(row) for row in mean_waiting)
    total_service_completions = sum(sum(row) for row in completions)
    network_departure_rate = total_exit_rate + total_internal_lost

    return {
        "network": {
            "mean_total_number": mean_total_number,
            "mean_total_in_service": mean_total_in_service,
            "mean_total_waiting": mean_total_waiting,
            "service_completion_rate": total_service_completions,
            "external_arrival_rate": total_external_attempts,
            "external_accepted_rate": total_external_accepted,
            "external_loss_rate": total_external_lost,
            "external_loss_probability": _ratio(
                total_external_lost, total_external_attempts
            ),
            "internal_arrival_rate": total_internal_attempts,
            "internal_accepted_rate": total_internal_accepted,
            "internal_loss_rate": total_internal_lost,
            "internal_loss_probability": _ratio(
                total_internal_lost, total_internal_attempts
            ),
            "exit_rate": total_exit_rate,
            "total_loss_rate": total_external_lost + total_internal_lost,
            "departure_rate_including_internal_loss": network_departure_rate,
            "population_flow_residual": total_external_accepted
            - network_departure_rate,
            "maximum_station_class_flow_residual": maximum_class_balance_residual,
        },
        "stations": station_results,
    }


def state_as_json(model: NetworkModel, state: State) -> Dict[str, List[str]]:
    return {
        station.station_id: [model.class_ids[c] for c in state[index]]
        for index, station in enumerate(model.stations)
    }


def build_result(
    model: NetworkModel,
    chain: SparseChain,
    solution: StationarySolution,
    include_states: bool = False,
) -> Dict[str, Any]:
    measures = compute_measures(model, chain, solution)
    result: Dict[str, Any] = {
        "schema_version": 1,
        "model": {
            "name": model.name,
            "blocking": "loss",
            "service_discipline": "FCFS",
            "classes": list(model.class_ids),
            "station_count": len(model.stations),
        },
        "solver": {
            "method": "matrix-free uniformization power iteration",
            "state_count": len(chain.states),
            "off_diagonal_transition_count": chain.off_diagonal_count,
            "iterations": solution.iterations,
            "converged": solution.converged,
            "l1_step": solution.l1_step,
            "generator_residual_l1": solution.generator_residual_l1,
            "uniformization_rate": solution.uniformization_rate,
        },
        "measures": measures,
    }
    if include_states:
        result["stationary_distribution"] = [
            {
                "index": index,
                "probability": probability,
                "state": state_as_json(model, state),
            }
            for index, (state, probability) in enumerate(
                zip(chain.states, solution.probabilities)
            )
        ]
    return result


def solve_model(
    model: NetworkModel,
    tolerance: Optional[float] = None,
    max_iterations: Optional[int] = None,
    max_states: Optional[int] = None,
    uniformization_slack: Optional[float] = None,
) -> Tuple[SparseChain, StationarySolution, Dict[str, Any]]:
    """Enumerate, solve, and summarize a model for library callers."""

    effective_tolerance = (
        model.settings.tolerance if tolerance is None else tolerance
    )
    effective_max_iterations = (
        model.settings.max_iterations
        if max_iterations is None
        else max_iterations
    )
    effective_max_states = (
        model.settings.max_states if max_states is None else max_states
    )
    effective_slack = (
        model.settings.uniformization_slack
        if uniformization_slack is None
        else uniformization_slack
    )
    chain = enumerate_chain(model, effective_max_states)
    solution = solve_stationary(
        chain,
        tolerance=effective_tolerance,
        max_iterations=effective_max_iterations,
        uniformization_slack=effective_slack,
    )
    return chain, solution, compute_measures(model, chain, solution)


def _format_optional(value: Optional[float]) -> str:
    return "n/a" if value is None else "{:.8g}".format(value)


def print_human_result(result: Mapping[str, Any], top_states: int = 0) -> None:
    solver = result["solver"]
    measures = result["measures"]
    network = measures["network"]
    print("Generic finite-state CTMC — loss on full")
    print("Model: {}".format(result["model"]["name"]))
    print(
        "States: {}  Transitions: {}".format(
            solver["state_count"], solver["off_diagonal_transition_count"]
        )
    )
    print(
        "Stationary solve: {} after {} iterations; ||pi Q||_1={:.3e}".format(
            "converged" if solver["converged"] else "NOT CONVERGED",
            solver["iterations"],
            solver["generator_residual_l1"],
        )
    )
    print(
        "Network: E[N]={:.8g}  external accepted={:.8g}  "
        "external loss P={}".format(
            network["mean_total_number"],
            network["external_accepted_rate"],
            _format_optional(network["external_loss_probability"]),
        )
    )
    print(
        "Flow residuals: population={:.3e}  max station/class={:.3e}".format(
            network["population_flow_residual"],
            network["maximum_station_class_flow_residual"],
        )
    )
    for station in measures["stations"]:
        print(
            "Station {id}: E[N]={mean_number:.8g}  utilization={server_utilization:.8g}  "
            "P(full)={probability_full:.8g}  throughput={service_completion_rate:.8g}  "
            "E[T]={sojourn}".format(
                sojourn=_format_optional(station["mean_sojourn_time"]), **station
            )
        )
        for class_result in station["classes"]:
            if (
                class_result["accepted_arrival_rate"] == 0.0
                and class_result["mean_number"] == 0.0
            ):
                continue
            print(
                "  Class {class}: E[N]={mean_number:.8g}  accepted={accepted_arrival_rate:.8g}  "
                "completed={service_completion_rate:.8g}  E[T]={sojourn}".format(
                    sojourn=_format_optional(class_result["mean_sojourn_time"]),
                    **class_result
                )
            )

    if top_states > 0 and "stationary_distribution" in result:
        states = sorted(
            result["stationary_distribution"],
            key=lambda item: item["probability"],
            reverse=True,
        )[:top_states]
        print("Top stationary states:")
        for item in states:
            print("  {:.8g}  {}".format(item["probability"], item["state"]))


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Enumerate and solve a finite loss-on-full Markovian queueing "
            "network from JSON. General BAS is intentionally unsupported."
        )
    )
    parser.add_argument("input", type=Path, help="path to a schema-version 1 JSON model")
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_stdout",
        help="write structured JSON to stdout instead of the human summary",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="also write structured JSON to this file",
    )
    parser.add_argument(
        "--include-states",
        action="store_true",
        help="include every state and stationary probability in JSON output",
    )
    parser.add_argument(
        "--top-states",
        type=int,
        default=0,
        help="show N highest-probability states in human output",
    )
    parser.add_argument("--tolerance", type=float, help="override solver tolerance")
    parser.add_argument(
        "--max-iterations", type=int, help="override stationary-iteration limit"
    )
    parser.add_argument(
        "--max-states", type=int, help="override reachability-enumeration limit"
    )
    parser.add_argument(
        "--uniformization-slack",
        type=float,
        help="override positive fractional slack above max generator exit rate",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _argument_parser().parse_args(argv)
    if args.top_states < 0:
        print("error: --top-states must be >= 0", file=sys.stderr)
        return 2
    try:
        model = load_model(args.input)
        chain, solution, _ = solve_model(
            model,
            tolerance=args.tolerance,
            max_iterations=args.max_iterations,
            max_states=args.max_states,
            uniformization_slack=args.uniformization_slack,
        )
        include_states = args.include_states or args.top_states > 0
        result = build_result(model, chain, solution, include_states=include_states)
        serialized = json.dumps(result, indent=2, sort_keys=True, allow_nan=False)
        if args.output is not None:
            try:
                args.output.write_text(serialized + "\n", encoding="utf-8")
            except OSError as error:
                raise ConfigError(
                    "cannot write {}: {}".format(args.output, error)
                ) from error
        if args.json_stdout:
            print(serialized)
        else:
            print_human_result(result, top_states=args.top_states)
        if not solution.converged:
            print(
                "error: stationary iteration did not converge; increase "
                "max_iterations or relax tolerance",
                file=sys.stderr,
            )
            return 3
        return 0
    except (ConfigError, StateSpaceLimitError, ConvergenceError, ValueError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
