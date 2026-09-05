"""Exact closed BCMP/Gordon-Newell state-enumeration solver."""

from __future__ import annotations

import itertools
import math
from dataclasses import dataclass
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Tuple

try:  # Package import.
    from .common import (
        ConfigError,
        StateSpaceLimitError,
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
    from common import (
        ConfigError,
        StateSpaceLimitError,
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


StationState = Tuple[Tuple[int, ...], ...]

FCFS = "fcfs"
PROCESSOR_SHARING = "processor_sharing"
INFINITE_SERVER = "infinite_server"
LCFS_PR = "lcfs_preemptive_resume"
STATION_TYPES = {FCFS, PROCESSOR_SHARING, INFINITE_SERVER, LCFS_PR}


@dataclass(frozen=True)
class BCMPStation:
    station_id: str
    station_type: str
    servers: Optional[int]
    service_times: Tuple[Optional[float], ...]


@dataclass(frozen=True)
class ClosedClass:
    class_id: str
    population: int
    reference_station: int
    visit_ratios: Tuple[float, ...]


@dataclass(frozen=True)
class BCMPModel:
    name: str
    stations: Tuple[BCMPStation, ...]
    classes: Tuple[ClosedClass, ...]
    max_states: int


def _graph_reachable(start: int, adjacency: Mapping[int, Iterable[int]]) -> set:
    visited = {start}
    stack = [start]
    while stack:
        node = stack.pop()
        for destination in adjacency.get(node, ()):
            if destination not in visited:
                visited.add(destination)
                stack.append(destination)
    return visited


def _routing_visit_ratios(
    raw_routing: Any,
    station_index: Mapping[str, int],
    stations: Sequence[BCMPStation],
    reference_id: Optional[str],
    context: str,
) -> Tuple[int, Tuple[float, ...]]:
    rules = sequence(raw_routing, context)
    if not rules:
        raise ConfigError("{} cannot be empty".format(context))
    rows: Dict[int, Dict[int, float]] = {}
    visited = set()
    for rule_index, raw_rule in enumerate(rules):
        rule_context = "{}[{}]".format(context, rule_index)
        rule = mapping(raw_rule, rule_context)
        check_keys(rule, {"from_station", "destinations"}, rule_context)
        require_fields(rule, {"from_station", "destinations"}, rule_context)
        source_id = nonempty_string(
            rule["from_station"], rule_context + ".from_station"
        )
        if source_id not in station_index:
            raise ConfigError(
                "{} refers to unknown station {!r}".format(rule_context, source_id)
            )
        source = station_index[source_id]
        if source in rows:
            raise ConfigError(
                "{} contains duplicate routing row for station {!r}".format(
                    context, source_id
                )
            )
        destinations = sequence(
            rule["destinations"], rule_context + ".destinations"
        )
        if not destinations:
            raise ConfigError("{}.destinations cannot be empty".format(rule_context))
        row: Dict[int, float] = {}
        total = 0.0
        for destination_index, raw_destination in enumerate(destinations):
            destination_context = "{}.destinations[{}]".format(
                rule_context, destination_index
            )
            destination = mapping(raw_destination, destination_context)
            check_keys(destination, {"station", "probability"}, destination_context)
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
            if destination_station in row:
                raise ConfigError(
                    "{} contains duplicate destination {!r}".format(
                        rule_context, destination_id
                    )
                )
            route_probability = probability(
                destination["probability"], destination_context + ".probability"
            )
            row[destination_station] = route_probability
            total += route_probability
            visited.add(destination_station)
        if abs(total - 1.0) > 1.0e-12:
            raise ConfigError(
                "{} probabilities must sum to 1; found {:.17g}".format(
                    rule_context, total
                )
            )
        if total != 1.0:
            row = {destination: value / total for destination, value in row.items()}
        rows[source] = row
        visited.add(source)

    missing_rows = visited - set(rows)
    if missing_rows:
        labels = ", ".join(sorted(stations[i].station_id for i in missing_rows))
        raise ConfigError(
            "{} is closed but has no routing row for visited station{} {}".format(
                context, "s" if len(missing_rows) != 1 else "", labels
            )
        )

    start = min(visited)
    forward = {source: set(row) for source, row in rows.items()}
    reverse: Dict[int, set] = {station: set() for station in visited}
    for source, destinations in forward.items():
        for destination in destinations:
            reverse[destination].add(source)
    if _graph_reachable(start, forward) != visited or _graph_reachable(start, reverse) != visited:
        raise ConfigError(
            "{} must be irreducible over its visited stations".format(context)
        )

    ordered = sorted(visited)
    local_index = {station: index for index, station in enumerate(ordered)}
    size = len(ordered)
    transition = [[0.0 for _ in range(size)] for _ in range(size)]
    for source, row in rows.items():
        for destination, value in row.items():
            transition[local_index[source]][local_index[destination]] = value

    # Solve (P^T-I)v=0 with sum(v)=1. This works for periodic routing chains,
    # unlike direct power iteration on P.
    matrix = [
        [
            transition[column][row] - (1.0 if row == column else 0.0)
            for column in range(size)
        ]
        for row in range(size)
    ]
    matrix[-1] = [1.0] * size
    rhs = [0.0] * size
    rhs[-1] = 1.0
    invariant = solve_linear_system(matrix, rhs, context + " traffic equations")
    if min(invariant) < -1.0e-10:
        raise ConfigError("{} produced a negative visit ratio".format(context))
    invariant = [max(0.0, value) for value in invariant]
    invariant_sum = sum(invariant)
    if invariant_sum <= 0.0:
        raise ConfigError("{} produced zero visit ratios".format(context))
    invariant = [value / invariant_sum for value in invariant]

    if reference_id is None:
        reference = ordered[0]
    else:
        if reference_id not in station_index:
            raise ConfigError(
                "{} reference_station {!r} is unknown".format(context, reference_id)
            )
        reference = station_index[reference_id]
        if reference not in visited:
            raise ConfigError(
                "{} reference_station {!r} is not visited".format(context, reference_id)
            )
    reference_value = invariant[local_index[reference]]
    if reference_value <= 0.0:
        raise ConfigError("{} reference visit ratio is numerically zero".format(context))
    visits = [0.0] * len(stations)
    for station, value in zip(ordered, invariant):
        scaled_value = value / reference_value
        if not math.isfinite(scaled_value):
            raise ConfigError("{} visit-ratio scaling overflowed".format(context))
        visits[station] = scaled_value
    return reference, tuple(visits)


def _direct_visit_ratios(
    raw_visits: Any,
    station_index: Mapping[str, int],
    stations: Sequence[BCMPStation],
    reference_id: Optional[str],
    context: str,
) -> Tuple[int, Tuple[float, ...]]:
    visit_obj = mapping(raw_visits, context)
    if not visit_obj:
        raise ConfigError("{} cannot be empty".format(context))
    unknown = sorted(set(visit_obj) - set(station_index))
    if unknown:
        raise ConfigError(
            "{} refers to unknown stations: {}".format(context, ", ".join(unknown))
        )
    raw_values = [0.0] * len(stations)
    for station_id, raw_value in visit_obj.items():
        raw_values[station_index[station_id]] = positive_number(
            raw_value, "{}.{}".format(context, station_id)
        )
    if reference_id is None:
        reference = next(index for index, value in enumerate(raw_values) if value > 0.0)
    else:
        if reference_id not in station_index:
            raise ConfigError(
                "{} reference_station {!r} is unknown".format(context, reference_id)
            )
        reference = station_index[reference_id]
        if raw_values[reference] <= 0.0:
            raise ConfigError(
                "{} reference_station {!r} has no visit ratio".format(
                    context, reference_id
                )
            )
    scale = raw_values[reference]
    visits = tuple(value / scale for value in raw_values)
    if any(not math.isfinite(value) for value in visits):
        raise ConfigError("{} visit-ratio scaling overflowed".format(context))
    return reference, visits


def parse_bcmp(document: Mapping[str, Any]) -> BCMPModel:
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
    if root["model_type"] != "closed_bcmp":
        raise ConfigError("model_type must be 'closed_bcmp'")
    if integer(root["schema_version"], "schema_version", 1) != 1:
        raise ConfigError("schema_version must be 1")
    name = nonempty_string(root["name"], "name")
    if "description" in root and not isinstance(root["description"], str):
        raise ConfigError("description must be a string")

    raw_classes = sequence(root["classes"], "classes")
    if not raw_classes:
        raise ConfigError("classes must contain at least one closed class")
    class_ids: List[str] = []
    populations: List[int] = []
    class_objects: List[Mapping[str, Any]] = []
    for class_index, raw_class in enumerate(raw_classes):
        context = "classes[{}]".format(class_index)
        class_obj = mapping(raw_class, context)
        check_keys(
            class_obj,
            {
                "id",
                "population",
                "reference_station",
                "visit_ratios",
                "routing",
            },
            context,
        )
        require_fields(class_obj, {"id", "population"}, context)
        class_id = nonempty_string(class_obj["id"], context + ".id")
        if class_id in class_ids:
            raise ConfigError("class ids must be unique: {!r}".format(class_id))
        has_visits = "visit_ratios" in class_obj
        has_routing = "routing" in class_obj
        if has_visits == has_routing:
            raise ConfigError(
                "{} must contain exactly one of visit_ratios or routing".format(context)
            )
        class_ids.append(class_id)
        populations.append(integer(class_obj["population"], context + ".population"))
        class_objects.append(class_obj)

    raw_stations = sequence(root["stations"], "stations")
    if not raw_stations:
        raise ConfigError("stations must contain at least one station")
    station_index: Dict[str, int] = {}
    stations: List[BCMPStation] = []
    for index, raw_station in enumerate(raw_stations):
        context = "stations[{}]".format(index)
        station_obj = mapping(raw_station, context)
        check_keys(
            station_obj,
            {"id", "type", "servers", "service_times"},
            context,
        )
        require_fields(station_obj, {"id", "type", "service_times"}, context)
        station_id = nonempty_string(station_obj["id"], context + ".id")
        if station_id in station_index:
            raise ConfigError("station ids must be unique: {!r}".format(station_id))
        station_type = nonempty_string(station_obj["type"], context + ".type")
        if station_type not in STATION_TYPES:
            raise ConfigError(
                "{}.type must be one of {}".format(
                    context, ", ".join(sorted(STATION_TYPES))
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
        unknown_classes = sorted(set(service_obj) - set(class_ids))
        if unknown_classes:
            raise ConfigError(
                "{}.service_times refers to unknown classes: {}".format(
                    context, ", ".join(unknown_classes)
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

    closed_classes: List[ClosedClass] = []
    for index, (class_id, population, class_obj) in enumerate(
        zip(class_ids, populations, class_objects)
    ):
        context = "classes[{}]".format(index)
        reference_id = None
        if "reference_station" in class_obj:
            reference_id = nonempty_string(
                class_obj["reference_station"], context + ".reference_station"
            )
        if "visit_ratios" in class_obj:
            reference, visits = _direct_visit_ratios(
                class_obj["visit_ratios"],
                station_index,
                stations,
                reference_id,
                context + ".visit_ratios",
            )
        else:
            reference, visits = _routing_visit_ratios(
                class_obj["routing"],
                station_index,
                stations,
                reference_id,
                context + ".routing",
            )
        closed_classes.append(ClosedClass(class_id, population, reference, visits))

    for station_position, station in enumerate(stations):
        visiting_times = []
        for class_position, closed_class in enumerate(closed_classes):
            if closed_class.visit_ratios[station_position] <= 0.0:
                continue
            service_time = station.service_times[class_position]
            if service_time is None:
                raise ConfigError(
                    "class {!r} visits station {!r}, but no service time is defined"
                    .format(closed_class.class_id, station.station_id)
                )
            demand = closed_class.visit_ratios[station_position] * service_time
            if not math.isfinite(demand) or demand <= 0.0:
                raise ConfigError(
                    "service demand for class {!r} at station {!r} is outside "
                    "floating-point range".format(
                        closed_class.class_id, station.station_id
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

    solver_obj = mapping(root.get("solver", {}), "solver")
    check_keys(solver_obj, {"max_states"}, "solver")
    max_states = integer(solver_obj.get("max_states", 200_000), "solver.max_states", 1)
    return BCMPModel(name, tuple(stations), tuple(closed_classes), max_states)


def _compositions(total: int, parts: int) -> Iterator[Tuple[int, ...]]:
    if parts == 1:
        yield (total,)
        return
    # Stars and bars without Python recursion, so a zero/small population may
    # safely visit a large number of stations.
    slot_count = total + parts - 1
    for bars in itertools.combinations(range(slot_count), parts - 1):
        values = []
        previous = -1
        for bar in bars:
            values.append(bar - previous - 1)
            previous = bar
        values.append(slot_count - previous - 1)
        yield tuple(values)


def state_count(model: BCMPModel, populations: Optional[Sequence[int]] = None) -> int:
    if populations is None:
        populations = [closed_class.population for closed_class in model.classes]
    if len(populations) != len(model.classes):
        raise ConfigError("population vector length must equal class count")
    count = 1
    for population, closed_class in zip(populations, model.classes):
        if isinstance(population, bool) or not isinstance(population, int) or population < 0:
            raise ConfigError("population vector entries must be nonnegative integers")
        visited_count = sum(value > 0.0 for value in closed_class.visit_ratios)
        if visited_count == 0:
            raise ConfigError("class {!r} visits no stations".format(closed_class.class_id))
        count *= math.comb(population + visited_count - 1, visited_count - 1)
        if count > model.max_states:
            raise StateSpaceLimitError(
                "closed BCMP occupancy state count {} exceeds max_states={}; "
                "reduce populations/classes or increase the limit deliberately"
                .format(count, model.max_states)
            )
    return count


def population_states(
    model: BCMPModel, populations: Optional[Sequence[int]] = None
) -> Iterator[StationState]:
    if populations is None:
        populations = [closed_class.population for closed_class in model.classes]
    state_count(model, populations)
    station_count = len(model.stations)
    allocation_options: List[List[Tuple[int, ...]]] = []
    for population, closed_class in zip(populations, model.classes):
        visited = [
            index for index, value in enumerate(closed_class.visit_ratios) if value > 0.0
        ]
        options: List[Tuple[int, ...]] = []
        for compact in _compositions(population, len(visited)):
            full = [0] * station_count
            for station, value in zip(visited, compact):
                full[station] = value
            options.append(tuple(full))
        allocation_options.append(options)

    for class_allocations in itertools.product(*allocation_options):
        yield tuple(
            tuple(class_allocations[class_index][station_index]
                  for class_index in range(len(model.classes)))
            for station_index in range(station_count)
        )


def _log_capacity_product(population: int, servers: int) -> float:
    if population <= servers:
        return math.lgamma(population + 1.0)
    return math.lgamma(servers + 1.0) + (population - servers) * math.log(servers)


def log_state_weight(model: BCMPModel, state: StationState) -> float:
    result = 0.0
    for station_index, (station, counts) in enumerate(zip(model.stations, state)):
        total = sum(counts)
        if total == 0:
            continue
        for class_index, count in enumerate(counts):
            if count == 0:
                continue
            service_time = station.service_times[class_index]
            visit_ratio = model.classes[class_index].visit_ratios[station_index]
            if service_time is None or visit_ratio <= 0.0:
                return -math.inf
            demand = visit_ratio * service_time
            result += count * math.log(demand) - math.lgamma(count + 1.0)
        if station.station_type != INFINITE_SERVER:
            result += math.lgamma(total + 1.0)
        if station.station_type == FCFS:
            assert station.servers is not None
            result -= _log_capacity_product(total, station.servers)
    return result


def log_normalizing_constant(
    model: BCMPModel, populations: Optional[Sequence[int]] = None
) -> float:
    total = -math.inf
    for state in population_states(model, populations):
        total = logaddexp(total, log_state_weight(model, state))
    if total == -math.inf:
        raise ConfigError("all BCMP product-form state weights are zero")
    return total


def _safe_exp(log_value: float, context: str) -> float:
    if log_value > math.log(sys_float_max()):
        raise ConfigError("{} exceeds floating-point range".format(context))
    result = math.exp(log_value)
    if result == 0.0:
        raise ConfigError("{} is below floating-point range".format(context))
    return result


def sys_float_max() -> float:
    # Kept local to avoid a NumPy dependency and a platform-specific literal.
    return float.fromhex("0x1.fffffffffffffp+1023")


def _state_json(model: BCMPModel, state: StationState) -> Dict[str, Dict[str, int]]:
    return {
        station.station_id: {
            closed_class.class_id: state[station_index][class_index]
            for class_index, closed_class in enumerate(model.classes)
        }
        for station_index, station in enumerate(model.stations)
    }


def solve_bcmp(model: BCMPModel, include_states: bool = False) -> Dict[str, Any]:
    expected_state_count = state_count(model)
    states: List[StationState] = []
    log_weights: List[float] = []
    for state in population_states(model):
        states.append(state)
        log_weights.append(log_state_weight(model, state))
    if len(states) != expected_state_count:
        raise RuntimeError("internal BCMP state-enumeration count mismatch")
    maximum_log_weight = max(log_weights)
    scaled_weights = [math.exp(value - maximum_log_weight) for value in log_weights]
    scaled_total = sum(scaled_weights)
    probabilities = [value / scaled_total for value in scaled_weights]
    log_g = maximum_log_weight + math.log(scaled_total)

    reference_throughputs: List[float] = []
    log_reference_throughputs: List[Optional[float]] = []
    populations = [closed_class.population for closed_class in model.classes]
    for class_index, closed_class in enumerate(model.classes):
        if closed_class.population == 0:
            reference_throughputs.append(0.0)
            log_reference_throughputs.append(None)
            continue
        reduced = list(populations)
        reduced[class_index] -= 1
        log_g_reduced = log_normalizing_constant(model, reduced)
        log_throughput = log_g_reduced - log_g
        reference_throughputs.append(
            _safe_exp(
                log_throughput,
                "reference throughput for class {!r}".format(closed_class.class_id),
            )
        )
        log_reference_throughputs.append(log_throughput)

    station_count = len(model.stations)
    class_count = len(model.classes)
    mean_counts = [[0.0] * class_count for _ in range(station_count)]
    probability_empty = [0.0] * station_count
    probability_all_busy = [0.0] * station_count
    mean_active_positions = [0.0] * station_count
    inferred_completion = [[0.0] * class_count for _ in range(station_count)]

    for state, state_probability in zip(states, probabilities):
        for station_index, (station, counts) in enumerate(zip(model.stations, state)):
            total = sum(counts)
            if total == 0:
                probability_empty[station_index] += state_probability
            if station.station_type == FCFS:
                assert station.servers is not None
                active = min(total, station.servers)
                if total >= station.servers:
                    probability_all_busy[station_index] += state_probability
            elif station.station_type == INFINITE_SERVER:
                active = total
            else:
                active = 1 if total > 0 else 0
                if total > 0:
                    probability_all_busy[station_index] += state_probability
            mean_active_positions[station_index] += state_probability * active

            for class_index, count in enumerate(counts):
                mean_counts[station_index][class_index] += state_probability * count
                if count == 0:
                    continue
                service_time = station.service_times[class_index]
                assert service_time is not None
                if station.station_type == INFINITE_SERVER:
                    conditional_completion = count / service_time
                elif station.station_type == FCFS:
                    conditional_completion = active * count / (total * service_time)
                else:
                    conditional_completion = count / (total * service_time)
                inferred_completion[station_index][class_index] += (
                    state_probability * conditional_completion
                )

    station_results: List[Dict[str, Any]] = []
    max_throughput_residual = 0.0
    for station_index, station in enumerate(model.stations):
        class_results = []
        total_throughput = 0.0
        for class_index, closed_class in enumerate(model.classes):
            visit_ratio = closed_class.visit_ratios[station_index]
            throughput = reference_throughputs[class_index] * visit_ratio
            total_throughput += throughput
            residual = inferred_completion[station_index][class_index] - throughput
            max_throughput_residual = max(max_throughput_residual, abs(residual))
            class_results.append(
                {
                    "class": closed_class.class_id,
                    "visit_ratio": visit_ratio,
                    "mean_service_time": station.service_times[class_index],
                    "service_demand": (
                        None
                        if station.service_times[class_index] is None
                        else visit_ratio * station.service_times[class_index]
                    ),
                    "mean_number": mean_counts[station_index][class_index],
                    "throughput": throughput,
                    "mean_residence_time_per_visit": optional_ratio(
                        mean_counts[station_index][class_index], throughput
                    ),
                    "completion_rate_cross_check": inferred_completion[station_index][
                        class_index
                    ],
                    "flow_residual": residual,
                }
            )
        if station.station_type == FCFS:
            assert station.servers is not None
            utilization = mean_active_positions[station_index] / station.servers
        elif station.station_type in {PROCESSOR_SHARING, LCFS_PR}:
            utilization = 1.0 - probability_empty[station_index]
        else:
            utilization = None
        station_results.append(
            {
                "id": station.station_id,
                "type": station.station_type,
                "servers": station.servers,
                "mean_number": sum(mean_counts[station_index]),
                "probability_empty": probability_empty[station_index],
                "probability_all_servers_busy": (
                    None
                    if station.station_type == INFINITE_SERVER
                    else probability_all_busy[station_index]
                ),
                "mean_active_service_positions": mean_active_positions[station_index],
                "server_utilization": utilization,
                "throughput": total_throughput,
                "classes": class_results,
            }
        )

    class_results = []
    max_population_residual = 0.0
    for class_index, closed_class in enumerate(model.classes):
        mean_population = sum(row[class_index] for row in mean_counts)
        population_residual = mean_population - closed_class.population
        max_population_residual = max(max_population_residual, abs(population_residual))
        throughput = reference_throughputs[class_index]
        class_results.append(
            {
                "id": closed_class.class_id,
                "population": closed_class.population,
                "mean_population_cross_check": mean_population,
                "population_residual": population_residual,
                "reference_station": model.stations[
                    closed_class.reference_station
                ].station_id,
                "reference_throughput": throughput,
                "log_reference_throughput": log_reference_throughputs[class_index],
                "mean_time_per_reference_visit": optional_ratio(
                    float(closed_class.population), throughput
                ),
            }
        )

    result: Dict[str, Any] = {
        "schema_version": 1,
        "model_type": "closed_bcmp",
        "model": {
            "name": model.name,
            "station_count": station_count,
            "class_count": class_count,
            "total_population": sum(populations),
        },
        "solver": {
            "method": "exact BCMP product-form occupancy enumeration",
            "state_count": len(states),
            "log_normalizing_constant": log_g,
            "probability_mass": sum(probabilities),
            "maximum_population_residual": max_population_residual,
            "maximum_throughput_cross_check_residual": max_throughput_residual,
        },
        "measures": {
            "classes": class_results,
            "stations": station_results,
        },
    }
    if include_states:
        result["stationary_distribution"] = [
            {
                "index": index,
                "probability": state_probability,
                "state": _state_json(model, state),
            }
            for index, (state, state_probability) in enumerate(
                zip(states, probabilities)
            )
        ]
    return result
