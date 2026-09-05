"""Exact open BCMP solver with class-preserving routing.

The solver uses the traffic equations for each open class and the closed-form
normalizing constants of quasi-reversible BCMP stations.  It never truncates
the (infinite) occupancy state space.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:  # Package import.
    from .bcmp import (
        BCMPStation,
        FCFS,
        INFINITE_SERVER,
        LCFS_PR,
        PROCESSOR_SHARING,
        STATION_TYPES,
    )
    from .common import (
        ConfigError,
        check_keys,
        integer,
        logaddexp,
        mapping,
        nonempty_string,
        optional_ratio,
        positive_number,
        probability,
        require_fields,
        sequence,
        solve_linear_system,
    )
except ImportError:  # Direct execution/import with this directory on sys.path.
    from bcmp import (
        BCMPStation,
        FCFS,
        INFINITE_SERVER,
        LCFS_PR,
        PROCESSOR_SHARING,
        STATION_TYPES,
    )
    from common import (
        ConfigError,
        check_keys,
        integer,
        logaddexp,
        mapping,
        nonempty_string,
        optional_ratio,
        positive_number,
        probability,
        require_fields,
        sequence,
        solve_linear_system,
    )


@dataclass(frozen=True)
class OpenClass:
    class_id: str
    external_arrival_rates: Tuple[float, ...]
    routing: Tuple[Tuple[float, ...], ...]
    exit_probabilities: Tuple[float, ...]
    traffic_rates: Tuple[float, ...]
    maximum_traffic_residual: float
    flow_conservation_residual: float


@dataclass(frozen=True)
class OpenBCMPModel:
    name: str
    stations: Tuple[BCMPStation, ...]
    classes: Tuple[OpenClass, ...]
    max_servers: int


def _parse_stations(
    raw_stations: Any,
    class_ids: Sequence[str],
    allowed_types: Sequence[str] = tuple(STATION_TYPES),
) -> Tuple[Tuple[BCMPStation, ...], Dict[str, int]]:
    station_items = sequence(raw_stations, "stations")
    if not station_items:
        raise ConfigError("stations must contain at least one station")
    allowed = set(allowed_types)
    station_index: Dict[str, int] = {}
    stations: List[BCMPStation] = []
    for index, raw_station in enumerate(station_items):
        context = "stations[{}]".format(index)
        station_obj = mapping(raw_station, context)
        check_keys(
            station_obj, {"id", "type", "servers", "service_times"}, context
        )
        require_fields(station_obj, {"id", "type", "service_times"}, context)
        station_id = nonempty_string(station_obj["id"], context + ".id")
        if station_id in station_index:
            raise ConfigError("station ids must be unique: {!r}".format(station_id))
        station_type = nonempty_string(station_obj["type"], context + ".type")
        if station_type not in allowed:
            raise ConfigError(
                "{}.type must be one of {}".format(
                    context, ", ".join(sorted(allowed))
                )
            )
        if station_type == FCFS:
            servers = integer(station_obj.get("servers", 1), context + ".servers", 1)
        else:
            if "servers" in station_obj:
                raise ConfigError(
                    "{}.servers is only valid for fcfs stations".format(context)
                )
            servers = None
        service_obj = mapping(
            station_obj["service_times"], context + ".service_times"
        )
        if not service_obj:
            raise ConfigError("{}.service_times cannot be empty".format(context))
        unknown = sorted(set(service_obj) - set(class_ids))
        if unknown:
            raise ConfigError(
                "{}.service_times refers to unknown classes: {}".format(
                    context, ", ".join(unknown)
                )
            )
        service_times: List[Optional[float]] = [None] * len(class_ids)
        for class_id, raw_time in service_obj.items():
            service_times[class_ids.index(class_id)] = positive_number(
                raw_time, "{}.service_times.{}".format(context, class_id)
            )
        station_index[station_id] = index
        stations.append(
            BCMPStation(station_id, station_type, servers, tuple(service_times))
        )
    return tuple(stations), station_index


def _reachable(starts: Sequence[int], adjacency: Mapping[int, Sequence[int]]) -> set:
    visited = set(starts)
    stack = list(starts)
    while stack:
        source = stack.pop()
        for destination in adjacency.get(source, ()):
            if destination not in visited:
                visited.add(destination)
                stack.append(destination)
    return visited


def _parse_open_class(
    class_obj: Mapping[str, Any],
    class_index: int,
    stations: Sequence[BCMPStation],
    station_index: Mapping[str, int],
    context_prefix: str = "classes",
) -> OpenClass:
    context = "{}[{}]".format(context_prefix, class_index)
    check_keys(
        class_obj,
        {"id", "external_arrival_rates", "routing"},
        context,
    )
    require_fields(class_obj, {"id", "external_arrival_rates"}, context)
    class_id = nonempty_string(class_obj["id"], context + ".id")
    external_obj = mapping(
        class_obj["external_arrival_rates"], context + ".external_arrival_rates"
    )
    if not external_obj:
        raise ConfigError(
            "{}.external_arrival_rates must contain at least one positive source"
            .format(context)
        )
    unknown = sorted(set(external_obj) - set(station_index))
    if unknown:
        raise ConfigError(
            "{}.external_arrival_rates refers to unknown stations: {}".format(
                context, ", ".join(unknown)
            )
        )
    station_count = len(stations)
    external = [0.0] * station_count
    for station_id, raw_rate in external_obj.items():
        external[station_index[station_id]] = positive_number(
            raw_rate,
            "{}.external_arrival_rates.{}".format(context, station_id),
        )

    routing = [[0.0] * station_count for _ in range(station_count)]
    exits = [1.0] * station_count
    explicit_sources = set()
    raw_rows = sequence(class_obj.get("routing", []), context + ".routing")
    for row_index, raw_row in enumerate(raw_rows):
        row_context = "{}.routing[{}]".format(context, row_index)
        row = mapping(raw_row, row_context)
        check_keys(
            row,
            {"from_station", "destinations", "exit_probability"},
            row_context,
        )
        require_fields(row, {"from_station"}, row_context)
        source_id = nonempty_string(
            row["from_station"], row_context + ".from_station"
        )
        if source_id not in station_index:
            raise ConfigError(
                "{} refers to unknown station {!r}".format(row_context, source_id)
            )
        source = station_index[source_id]
        if source in explicit_sources:
            raise ConfigError(
                "{}.routing contains duplicate row for station {!r}".format(
                    context, source_id
                )
            )
        explicit_sources.add(source)
        destinations = sequence(
            row.get("destinations", []), row_context + ".destinations"
        )
        total = 0.0
        seen_destinations = set()
        for destination_index, raw_destination in enumerate(destinations):
            destination_context = "{}.destinations[{}]".format(
                row_context, destination_index
            )
            destination = mapping(raw_destination, destination_context)
            check_keys(
                destination, {"station", "probability"}, destination_context
            )
            require_fields(
                destination, {"station", "probability"}, destination_context
            )
            destination_id = nonempty_string(
                destination["station"], destination_context + ".station"
            )
            if destination_id not in station_index:
                raise ConfigError(
                    "{} refers to unknown station {!r}".format(
                        destination_context, destination_id
                    )
                )
            destination_station = station_index[destination_id]
            if destination_station in seen_destinations:
                raise ConfigError(
                    "{} contains duplicate destination {!r}".format(
                        row_context, destination_id
                    )
                )
            route_probability = probability(
                destination["probability"], destination_context + ".probability"
            )
            routing[source][destination_station] = route_probability
            seen_destinations.add(destination_station)
            total += route_probability
        if "exit_probability" in row:
            exit_probability = probability(
                row["exit_probability"],
                row_context + ".exit_probability",
                allow_zero=True,
            )
            row_total = total + exit_probability
            if abs(row_total - 1.0) > 1.0e-12:
                raise ConfigError(
                    "{} destination and exit probabilities must sum to 1; "
                    "found {:.17g}".format(row_context, row_total)
                )
            if row_total != 1.0:
                for destination_station in seen_destinations:
                    routing[source][destination_station] /= row_total
                exit_probability /= row_total
        else:
            if total > 1.0 + 1.0e-12:
                raise ConfigError(
                    "{} destination probabilities cannot exceed 1; found {:.17g}"
                    .format(row_context, total)
                )
            if total > 1.0:
                for destination_station in seen_destinations:
                    routing[source][destination_station] /= total
                exit_probability = 0.0
            else:
                exit_probability = 1.0 - total
        exits[source] = exit_probability

    forward = {
        source: [destination for destination, value in enumerate(row) if value > 0.0]
        for source, row in enumerate(routing)
    }
    starts = [index for index, value in enumerate(external) if value > 0.0]
    traffic_reachable = _reachable(starts, forward)
    unreachable_rows = explicit_sources - traffic_reachable
    if unreachable_rows:
        labels = ", ".join(sorted(stations[index].station_id for index in unreachable_rows))
        raise ConfigError(
            "{}.routing contains row{} unreachable from external arrivals: {}"
            .format(context, "s" if len(unreachable_rows) != 1 else "", labels)
        )

    reverse: Dict[int, List[int]] = {index: [] for index in range(station_count)}
    for source, destinations in forward.items():
        for destination in destinations:
            reverse[destination].append(source)
    exit_nodes = [index for index in traffic_reachable if exits[index] > 0.0]
    can_reach_exit = _reachable(exit_nodes, reverse)
    trapped = traffic_reachable - can_reach_exit
    if trapped:
        labels = ", ".join(sorted(stations[index].station_id for index in trapped))
        raise ConfigError(
            "{} routing is not open: reachable station{} {} cannot reach an exit"
            .format(context, "s" if len(trapped) != 1 else "", labels)
        )

    traffic_matrix = [
        [
            (1.0 if row == column else 0.0) - routing[column][row]
            for column in range(station_count)
        ]
        for row in range(station_count)
    ]
    external_total = sum(external)
    if not math.isfinite(external_total):
        raise ConfigError(
            "{}.external_arrival_rates total exceeds floating-point range"
            .format(context)
        )
    traffic = solve_linear_system(
        traffic_matrix, external, context + " open traffic equations"
    )
    if any(not math.isfinite(value) for value in traffic):
        raise ConfigError(
            "{} traffic rates exceed floating-point range".format(context)
        )
    scale = max(1.0, max(traffic, default=0.0), sum(external))
    if min(traffic) < -1.0e-10 * scale:
        raise ConfigError("{} traffic equations produced a negative rate".format(context))
    traffic = [max(0.0, value) for value in traffic]
    residuals = [
        traffic[destination]
        - external[destination]
        - sum(
            traffic[source] * routing[source][destination]
            for source in range(station_count)
        )
        for destination in range(station_count)
    ]
    maximum_residual = max(abs(value) for value in residuals)
    departure_total = sum(
        rate * exit_probability for rate, exit_probability in zip(traffic, exits)
    )
    if not math.isfinite(departure_total):
        raise ConfigError(
            "{} departure rate exceeds floating-point range".format(context)
        )
    flow_residual = departure_total - external_total
    tolerance = 1.0e-10 * max(1.0, external_total, max(traffic, default=0.0))
    if maximum_residual > tolerance or abs(flow_residual) > tolerance:
        raise ConfigError(
            "{} traffic equations failed residual checks; max={:.3e}, flow={:.3e}"
            .format(context, maximum_residual, flow_residual)
        )
    return OpenClass(
        class_id,
        tuple(external),
        tuple(tuple(row) for row in routing),
        tuple(exits),
        tuple(traffic),
        maximum_residual,
        flow_residual,
    )


def _validate_open_service_scope(
    stations: Sequence[BCMPStation], classes: Sequence[OpenClass]
) -> None:
    for station_index, station in enumerate(stations):
        visiting_times = []
        for class_index, open_class in enumerate(classes):
            if open_class.traffic_rates[station_index] <= 0.0:
                continue
            service_time = station.service_times[class_index]
            if service_time is None:
                raise ConfigError(
                    "class {!r} has positive traffic at station {!r}, but no "
                    "service time is defined".format(
                        open_class.class_id, station.station_id
                    )
                )
            visiting_times.append(service_time)
        if station.station_type == FCFS and visiting_times:
            baseline = visiting_times[0]
            for service_time in visiting_times[1:]:
                if abs(service_time - baseline) > 1.0e-12 * max(
                    1.0, baseline, service_time
                ):
                    raise ConfigError(
                        "FCFS station {!r} must have a class-independent exponential "
                        "service time under the exact BCMP condition".format(
                            station.station_id
                        )
                    )


def parse_open_bcmp(document: Mapping[str, Any]) -> OpenBCMPModel:
    root = mapping(document, "document")
    check_keys(
        root,
        {
            "schema_version",
            "model_type",
            "name",
            "description",
            "stations",
            "classes",
            "solver",
        },
        "document",
    )
    require_fields(
        root,
        {"schema_version", "model_type", "name", "stations", "classes"},
        "document",
    )
    if root["model_type"] != "open_bcmp":
        raise ConfigError("model_type must be 'open_bcmp'")
    if integer(root["schema_version"], "schema_version", 1) != 1:
        raise ConfigError("schema_version must be 1")
    name = nonempty_string(root["name"], "name")
    if "description" in root and not isinstance(root["description"], str):
        raise ConfigError("description must be a string")

    raw_classes = sequence(root["classes"], "classes")
    if not raw_classes:
        raise ConfigError("classes must contain at least one open class")
    class_objects = [
        mapping(item, "classes[{}]".format(index))
        for index, item in enumerate(raw_classes)
    ]
    class_ids = []
    for index, class_obj in enumerate(class_objects):
        if "id" not in class_obj:
            raise ConfigError("classes[{}] is missing required field: id".format(index))
        class_id = nonempty_string(class_obj["id"], "classes[{}].id".format(index))
        if class_id in class_ids:
            raise ConfigError("class ids must be unique: {!r}".format(class_id))
        class_ids.append(class_id)

    stations, station_index = _parse_stations(root["stations"], class_ids)
    classes = tuple(
        _parse_open_class(class_obj, index, stations, station_index)
        for index, class_obj in enumerate(class_objects)
    )
    _validate_open_service_scope(stations, classes)
    solver_obj = mapping(root.get("solver", {}), "solver")
    check_keys(solver_obj, {"max_servers"}, "solver")
    max_servers = integer(
        solver_obj.get("max_servers", 100_000), "solver.max_servers", 1
    )
    for station in stations:
        if station.station_type == FCFS:
            assert station.servers is not None
            if station.servers > max_servers:
                raise ConfigError(
                    "FCFS station {!r} has {} servers, exceeding max_servers={}"
                    .format(station.station_id, station.servers, max_servers)
                )
    return OpenBCMPModel(name, stations, classes, max_servers)


def _mmc_aggregate_metrics(offered_load: float, servers: int) -> Dict[str, float]:
    if offered_load == 0.0:
        return {
            "traffic_intensity": 0.0,
            "log_normalizing_constant": 0.0,
            "probability_empty": 1.0,
            "probability_all_servers_busy": 0.0,
            "mean_number": 0.0,
            "mean_active_service_positions": 0.0,
            "server_utilization": 0.0,
        }
    traffic_intensity = offered_load / servers
    if traffic_intensity >= 1.0:
        raise ConfigError(
            "open M/M/{} FCFS station is unstable: offered load {:.17g} "
            "gives traffic intensity {:.17g} >= 1".format(
                servers, offered_load, traffic_intensity
            )
        )
    log_offered = math.log(offered_load)
    log_sum_before_capacity = 0.0
    log_term = 0.0
    for population in range(1, servers):
        log_term += log_offered - math.log(population)
        log_sum_before_capacity = logaddexp(log_sum_before_capacity, log_term)
    log_capacity_term = (
        servers * log_offered - math.lgamma(servers + 1.0)
    )
    log_tail = log_capacity_term - math.log1p(-traffic_intensity)
    log_g = logaddexp(log_sum_before_capacity, log_tail)
    probability_empty = math.exp(-log_g) if log_g < 746.0 else 0.0
    probability_all_busy = math.exp(log_tail - log_g)
    mean_queue = (
        probability_all_busy
        * traffic_intensity
        / (1.0 - traffic_intensity)
    )
    return {
        "traffic_intensity": traffic_intensity,
        "log_normalizing_constant": log_g,
        "probability_empty": probability_empty,
        "probability_all_servers_busy": probability_all_busy,
        "mean_number": offered_load + mean_queue,
        "mean_active_service_positions": offered_load,
        "server_utilization": traffic_intensity,
    }


def _open_station_metrics(
    station: BCMPStation,
    arrival_rates: Sequence[float],
    service_times: Sequence[Optional[float]],
) -> Dict[str, Any]:
    offered_by_class = [
        0.0 if rate == 0.0 else rate * float(service_time)
        for rate, service_time in zip(arrival_rates, service_times)
    ]
    offered_load = sum(offered_by_class)
    if not math.isfinite(offered_load):
        raise ConfigError(
            "offered load at station {!r} exceeds floating-point range".format(
                station.station_id
            )
        )
    if station.station_type == FCFS:
        assert station.servers is not None
        try:
            aggregate = _mmc_aggregate_metrics(offered_load, station.servers)
        except ConfigError as error:
            raise ConfigError(
                "station {!r}: {}".format(station.station_id, error)
            ) from error
        if offered_load > 0.0:
            means = [
                aggregate["mean_number"] * value / offered_load
                for value in offered_by_class
            ]
        else:
            means = [0.0] * len(offered_by_class)
    elif station.station_type in {PROCESSOR_SHARING, LCFS_PR}:
        if offered_load >= 1.0:
            raise ConfigError(
                "station {!r} is unstable: open offered load {:.17g} >= 1"
                .format(station.station_id, offered_load)
            )
        denominator = 1.0 - offered_load
        means = [value / denominator for value in offered_by_class]
        aggregate = {
            "traffic_intensity": offered_load,
            "log_normalizing_constant": -math.log1p(-offered_load),
            "probability_empty": denominator,
            "probability_all_servers_busy": offered_load,
            "mean_number": sum(means),
            "mean_active_service_positions": offered_load,
            "server_utilization": offered_load,
        }
    elif station.station_type == INFINITE_SERVER:
        means = list(offered_by_class)
        aggregate = {
            "traffic_intensity": None,
            "log_normalizing_constant": offered_load,
            "probability_empty": math.exp(-offered_load)
            if offered_load < 746.0
            else 0.0,
            "probability_all_servers_busy": None,
            "mean_number": offered_load,
            "mean_active_service_positions": offered_load,
            "server_utilization": None,
        }
    else:  # Defensive: the parser has already restricted station types.
        raise RuntimeError("unsupported BCMP station type")
    aggregate["offered_load"] = offered_load
    aggregate["offered_loads"] = offered_by_class
    aggregate["mean_numbers"] = means
    return aggregate


def solve_open_bcmp(model: OpenBCMPModel) -> Dict[str, Any]:
    station_count = len(model.stations)
    class_count = len(model.classes)
    station_results = []
    class_mean_numbers = [0.0] * class_count
    maximum_little_residual = 0.0
    log_normalizing_constant = 0.0
    minimum_stability_margin: Optional[float] = None

    for station_index, station in enumerate(model.stations):
        arrival_rates = [
            open_class.traffic_rates[station_index] for open_class in model.classes
        ]
        metrics = _open_station_metrics(
            station, arrival_rates, station.service_times
        )
        log_normalizing_constant += metrics["log_normalizing_constant"]
        if metrics["traffic_intensity"] is not None:
            margin = 1.0 - metrics["traffic_intensity"]
            minimum_stability_margin = (
                margin
                if minimum_stability_margin is None
                else min(minimum_stability_margin, margin)
            )
        per_class = []
        for class_index, open_class in enumerate(model.classes):
            arrival_rate = arrival_rates[class_index]
            mean_number = metrics["mean_numbers"][class_index]
            residence = optional_ratio(mean_number, arrival_rate)
            little_residual = (
                0.0
                if residence is None
                else mean_number - arrival_rate * residence
            )
            maximum_little_residual = max(
                maximum_little_residual, abs(little_residual)
            )
            class_mean_numbers[class_index] += mean_number
            service_time = station.service_times[class_index]
            per_class.append(
                {
                    "class": open_class.class_id,
                    "external_arrival_rate": open_class.external_arrival_rates[
                        station_index
                    ],
                    "arrival_rate": arrival_rate,
                    "throughput": arrival_rate,
                    "exit_probability": open_class.exit_probabilities[station_index],
                    "departure_to_outside_rate": (
                        arrival_rate * open_class.exit_probabilities[station_index]
                    ),
                    "mean_service_time": service_time,
                    "offered_load": metrics["offered_loads"][class_index],
                    "mean_number": mean_number,
                    "mean_residence_time_per_visit": residence,
                    "little_law_residual": little_residual,
                }
            )
        station_results.append(
            {
                "id": station.station_id,
                "type": station.station_type,
                "servers": station.servers,
                "offered_load": metrics["offered_load"],
                "traffic_intensity": metrics["traffic_intensity"],
                "stability_margin": (
                    None
                    if metrics["traffic_intensity"] is None
                    else 1.0 - metrics["traffic_intensity"]
                ),
                "log_local_normalizing_constant": metrics[
                    "log_normalizing_constant"
                ],
                "mean_number": metrics["mean_number"],
                "probability_empty": metrics["probability_empty"],
                "probability_all_servers_busy": metrics[
                    "probability_all_servers_busy"
                ],
                "mean_active_service_positions": metrics[
                    "mean_active_service_positions"
                ],
                "server_utilization": metrics["server_utilization"],
                "throughput": sum(arrival_rates),
                "classes": per_class,
            }
        )

    class_results = []
    maximum_traffic_residual = 0.0
    maximum_flow_residual = 0.0
    for class_index, open_class in enumerate(model.classes):
        external_total = sum(open_class.external_arrival_rates)
        departure_total = sum(
            rate * exit_probability
            for rate, exit_probability in zip(
                open_class.traffic_rates, open_class.exit_probabilities
            )
        )
        maximum_traffic_residual = max(
            maximum_traffic_residual, open_class.maximum_traffic_residual
        )
        maximum_flow_residual = max(
            maximum_flow_residual, abs(open_class.flow_conservation_residual)
        )
        class_results.append(
            {
                "id": open_class.class_id,
                "external_arrival_rate": external_total,
                "departure_rate": departure_total,
                "flow_conservation_residual": open_class.flow_conservation_residual,
                "maximum_traffic_equation_residual": open_class.maximum_traffic_residual,
                "mean_number": class_mean_numbers[class_index],
                "mean_time_in_network": optional_ratio(
                    class_mean_numbers[class_index], external_total
                ),
                "mean_station_visits_per_arrival": sum(open_class.traffic_rates)
                / external_total,
            }
        )

    return {
        "schema_version": 1,
        "model_type": "open_bcmp",
        "model": {
            "name": model.name,
            "station_count": station_count,
            "class_count": class_count,
        },
        "solver": {
            "method": "exact open BCMP traffic equations and local product forms",
            "state_space": "countably infinite; normalized analytically without truncation",
            "probability_mass": 1.0,
            "log_normalizing_constant": log_normalizing_constant,
            "minimum_stability_margin": minimum_stability_margin,
            "maximum_traffic_equation_residual": maximum_traffic_residual,
            "maximum_flow_conservation_residual": maximum_flow_residual,
            "maximum_little_law_residual": maximum_little_residual,
        },
        "measures": {
            "classes": class_results,
            "stations": station_results,
        },
    }
