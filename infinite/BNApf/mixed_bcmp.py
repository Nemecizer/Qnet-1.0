"""Exact mixed open/closed BCMP subclass.

Open and closed classes may share processor-sharing, infinite-server, and
LCFS preemptive-resume stations.  FCFS stations are supported only when used
exclusively by open classes or exclusively by closed classes.  This boundary
keeps every unbounded open occupancy sum analytic; unsupported shared-FCFS
models are rejected rather than approximated.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:  # Package import.
    from .bcmp import (
        BCMPModel,
        BCMPStation,
        ClosedClass,
        FCFS,
        INFINITE_SERVER,
        LCFS_PR,
        PROCESSOR_SHARING,
        _direct_visit_ratios,
        _log_capacity_product,
        _routing_visit_ratios,
        _state_json,
        population_states,
        state_count,
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
        require_fields,
        sequence,
    )
    from .open_bcmp import (
        OpenClass,
        _open_station_metrics,
        _parse_open_class,
        _parse_stations,
    )
except ImportError:  # Direct execution/import with this directory on sys.path.
    from bcmp import (
        BCMPModel,
        BCMPStation,
        ClosedClass,
        FCFS,
        INFINITE_SERVER,
        LCFS_PR,
        PROCESSOR_SHARING,
        _direct_visit_ratios,
        _log_capacity_product,
        _routing_visit_ratios,
        _state_json,
        population_states,
        state_count,
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
        require_fields,
        sequence,
    )
    from open_bcmp import (
        OpenClass,
        _open_station_metrics,
        _parse_open_class,
        _parse_stations,
    )


@dataclass(frozen=True)
class MixedBCMPModel:
    name: str
    stations: Tuple[BCMPStation, ...]
    open_classes: Tuple[OpenClass, ...]
    closed_classes: Tuple[ClosedClass, ...]
    closed_projection: BCMPModel
    max_states: int
    max_servers: int


def parse_mixed_bcmp(document: Mapping[str, Any]) -> MixedBCMPModel:
    root = mapping(document, "document")
    check_keys(
        root,
        {
            "schema_version",
            "model_type",
            "name",
            "description",
            "stations",
            "open_classes",
            "closed_classes",
            "solver",
        },
        "document",
    )
    require_fields(
        root,
        {
            "schema_version",
            "model_type",
            "name",
            "stations",
            "open_classes",
            "closed_classes",
        },
        "document",
    )
    if root["model_type"] != "mixed_bcmp":
        raise ConfigError("model_type must be 'mixed_bcmp'")
    if integer(root["schema_version"], "schema_version", 1) != 1:
        raise ConfigError("schema_version must be 1")
    name = nonempty_string(root["name"], "name")
    if "description" in root and not isinstance(root["description"], str):
        raise ConfigError("description must be a string")

    raw_open = sequence(root["open_classes"], "open_classes")
    raw_closed = sequence(root["closed_classes"], "closed_classes")
    if not raw_open:
        raise ConfigError("open_classes must contain at least one open class")
    if not raw_closed:
        raise ConfigError("closed_classes must contain at least one closed class")
    open_objects = [
        mapping(item, "open_classes[{}]".format(index))
        for index, item in enumerate(raw_open)
    ]
    closed_objects = [
        mapping(item, "closed_classes[{}]".format(index))
        for index, item in enumerate(raw_closed)
    ]
    open_ids: List[str] = []
    for index, class_obj in enumerate(open_objects):
        if "id" not in class_obj:
            raise ConfigError(
                "open_classes[{}] is missing required field: id".format(index)
            )
        class_id = nonempty_string(
            class_obj["id"], "open_classes[{}].id".format(index)
        )
        if class_id in open_ids:
            raise ConfigError("class ids must be unique: {!r}".format(class_id))
        open_ids.append(class_id)
    closed_ids: List[str] = []
    populations: List[int] = []
    for index, class_obj in enumerate(closed_objects):
        context = "closed_classes[{}]".format(index)
        check_keys(
            class_obj,
            {"id", "population", "reference_station", "visit_ratios", "routing"},
            context,
        )
        require_fields(class_obj, {"id", "population"}, context)
        class_id = nonempty_string(class_obj["id"], context + ".id")
        if class_id in open_ids or class_id in closed_ids:
            raise ConfigError("class ids must be unique: {!r}".format(class_id))
        has_visits = "visit_ratios" in class_obj
        has_routing = "routing" in class_obj
        if has_visits == has_routing:
            raise ConfigError(
                "{} must contain exactly one of visit_ratios or routing".format(
                    context
                )
            )
        closed_ids.append(class_id)
        populations.append(integer(class_obj["population"], context + ".population"))
    if sum(populations) == 0:
        raise ConfigError(
            "mixed_bcmp requires at least one closed customer; use open_bcmp "
            "for an open-only network"
        )

    all_ids = open_ids + closed_ids
    stations, station_index = _parse_stations(root["stations"], all_ids)
    open_classes = tuple(
        _parse_open_class(
            class_obj,
            index,
            stations,
            station_index,
            context_prefix="open_classes",
        )
        for index, class_obj in enumerate(open_objects)
    )

    closed_classes: List[ClosedClass] = []
    for index, (class_id, population, class_obj) in enumerate(
        zip(closed_ids, populations, closed_objects)
    ):
        context = "closed_classes[{}]".format(index)
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

    open_count = len(open_classes)
    for station_index_value, station in enumerate(stations):
        open_visitors = [
            class_index
            for class_index, open_class in enumerate(open_classes)
            if open_class.traffic_rates[station_index_value] > 0.0
        ]
        closed_visitors = [
            class_index
            for class_index, closed_class in enumerate(closed_classes)
            if closed_class.visit_ratios[station_index_value] > 0.0
        ]
        for class_index in open_visitors:
            if station.service_times[class_index] is None:
                raise ConfigError(
                    "open class {!r} has positive traffic at station {!r}, but no "
                    "service time is defined".format(
                        open_classes[class_index].class_id, station.station_id
                    )
                )
        for class_index in closed_visitors:
            service_time = station.service_times[open_count + class_index]
            if service_time is None:
                raise ConfigError(
                    "closed class {!r} visits station {!r}, but no service time is "
                    "defined".format(
                        closed_classes[class_index].class_id, station.station_id
                    )
                )
            demand = (
                closed_classes[class_index].visit_ratios[station_index_value]
                * service_time
            )
            if not math.isfinite(demand):
                raise ConfigError(
                    "service demand for closed class {!r} at station {!r} exceeds "
                    "floating-point range".format(
                        closed_classes[class_index].class_id, station.station_id
                    )
                )
        if station.station_type == FCFS:
            if open_visitors and closed_visitors:
                raise ConfigError(
                    "mixed_bcmp exact subclass does not support an FCFS station "
                    "shared by open and closed classes; station {!r} must be "
                    "exclusive to one population type".format(station.station_id)
                )
            visiting_times = [
                station.service_times[index] for index in open_visitors
            ] + [
                station.service_times[open_count + index]
                for index in closed_visitors
            ]
            if visiting_times:
                baseline = float(visiting_times[0])
                for service_time in visiting_times[1:]:
                    assert service_time is not None
                    if abs(service_time - baseline) > 1.0e-12 * max(
                        1.0, baseline, service_time
                    ):
                        raise ConfigError(
                            "FCFS station {!r} must have a class-independent "
                            "exponential service time under the exact BCMP condition"
                            .format(station.station_id)
                        )

    solver_obj = mapping(root.get("solver", {}), "solver")
    check_keys(solver_obj, {"max_states", "max_servers"}, "solver")
    max_states = integer(
        solver_obj.get("max_states", 200_000), "solver.max_states", 1
    )
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

    closed_stations = tuple(
        BCMPStation(
            station.station_id,
            station.station_type,
            station.servers,
            tuple(station.service_times[open_count:]),
        )
        for station in stations
    )
    closed_projection = BCMPModel(
        name,
        closed_stations,
        tuple(closed_classes),
        max_states,
    )
    state_count(closed_projection)
    return MixedBCMPModel(
        name,
        stations,
        open_classes,
        tuple(closed_classes),
        closed_projection,
        max_states,
        max_servers,
    )


def _log_collapsed_closed_weight(
    model: MixedBCMPModel,
    state: Tuple[Tuple[int, ...], ...],
    open_metrics: Sequence[Mapping[str, Any]],
) -> float:
    result = 0.0
    for station_index, (station, counts) in enumerate(
        zip(model.closed_projection.stations, state)
    ):
        total = sum(counts)
        if total == 0:
            continue
        for class_index, count in enumerate(counts):
            if count == 0:
                continue
            service_time = station.service_times[class_index]
            visit_ratio = model.closed_classes[class_index].visit_ratios[station_index]
            if service_time is None or visit_ratio <= 0.0:
                return -math.inf
            demand = visit_ratio * service_time
            result += count * math.log(demand) - math.lgamma(count + 1.0)
        if station.station_type != INFINITE_SERVER:
            result += math.lgamma(total + 1.0)
        if station.station_type == FCFS:
            assert station.servers is not None
            result -= _log_capacity_product(total, station.servers)
        elif station.station_type in {PROCESSOR_SHARING, LCFS_PR}:
            open_load = float(open_metrics[station_index]["offered_load"])
            result -= total * math.log1p(-open_load)
    return result


def _log_closed_normalizer(
    model: MixedBCMPModel,
    open_metrics: Sequence[Mapping[str, Any]],
    populations: Optional[Sequence[int]] = None,
) -> float:
    total = -math.inf
    for state in population_states(model.closed_projection, populations):
        total = logaddexp(
            total, _log_collapsed_closed_weight(model, state, open_metrics)
        )
    if total == -math.inf:
        raise ConfigError("all mixed BCMP closed-marginal state weights are zero")
    return total


def _safe_exp(log_value: float, context: str) -> float:
    if log_value > math.log(float.fromhex("0x1.fffffffffffffp+1023")):
        raise ConfigError("{} exceeds floating-point range".format(context))
    result = math.exp(log_value)
    if result == 0.0:
        raise ConfigError("{} is below floating-point range".format(context))
    return result


def solve_mixed_bcmp(
    model: MixedBCMPModel, include_states: bool = False
) -> Dict[str, Any]:
    open_count = len(model.open_classes)
    closed_count = len(model.closed_classes)
    station_count = len(model.stations)
    open_station_metrics = []
    minimum_stability_margin: Optional[float] = None
    log_open_normalizing_factor = 0.0
    for station_index, station in enumerate(model.stations):
        rates = [
            open_class.traffic_rates[station_index]
            for open_class in model.open_classes
        ]
        metrics = _open_station_metrics(
            station, rates, station.service_times[:open_count]
        )
        open_station_metrics.append(metrics)
        log_open_normalizing_factor += metrics["log_normalizing_constant"]
        if metrics["traffic_intensity"] is not None:
            margin = 1.0 - float(metrics["traffic_intensity"])
            minimum_stability_margin = (
                margin
                if minimum_stability_margin is None
                else min(minimum_stability_margin, margin)
            )

    expected_state_count = state_count(model.closed_projection)
    states = list(population_states(model.closed_projection))
    if len(states) != expected_state_count:
        raise RuntimeError("internal mixed BCMP state-enumeration count mismatch")
    log_weights = [
        _log_collapsed_closed_weight(model, state, open_station_metrics)
        for state in states
    ]
    maximum_log_weight = max(log_weights)
    scaled_weights = [math.exp(value - maximum_log_weight) for value in log_weights]
    scaled_total = sum(scaled_weights)
    probabilities = [value / scaled_total for value in scaled_weights]
    log_closed_g = maximum_log_weight + math.log(scaled_total)

    populations = [closed_class.population for closed_class in model.closed_classes]
    reference_throughputs: List[float] = []
    log_reference_throughputs: List[Optional[float]] = []
    for class_index, closed_class in enumerate(model.closed_classes):
        if closed_class.population == 0:
            reference_throughputs.append(0.0)
            log_reference_throughputs.append(None)
            continue
        reduced = list(populations)
        reduced[class_index] -= 1
        log_reduced = _log_closed_normalizer(
            model, open_station_metrics, reduced
        )
        log_throughput = log_reduced - log_closed_g
        reference_throughputs.append(
            _safe_exp(
                log_throughput,
                "reference throughput for closed class {!r}".format(
                    closed_class.class_id
                ),
            )
        )
        log_reference_throughputs.append(log_throughput)

    closed_means = [[0.0] * closed_count for _ in range(station_count)]
    probability_closed_empty = [0.0] * station_count
    closed_mean_active_fcfs = [0.0] * station_count
    closed_probability_all_busy_fcfs = [0.0] * station_count
    for state, state_probability in zip(states, probabilities):
        for station_index, (station, counts) in enumerate(
            zip(model.stations, state)
        ):
            total = sum(counts)
            if total == 0:
                probability_closed_empty[station_index] += state_probability
            if station.station_type == FCFS:
                assert station.servers is not None
                closed_mean_active_fcfs[station_index] += (
                    state_probability * min(total, station.servers)
                )
                if total >= station.servers:
                    closed_probability_all_busy_fcfs[station_index] += state_probability
            for class_index, count in enumerate(counts):
                closed_means[station_index][class_index] += state_probability * count

    open_class_mean_numbers = [0.0] * open_count
    maximum_little_residual = 0.0
    station_results = []
    for station_index, station in enumerate(model.stations):
        base = open_station_metrics[station_index]
        closed_total_mean = sum(closed_means[station_index])
        open_load = float(base["offered_load"])
        if station.station_type == INFINITE_SERVER:
            open_means = list(base["offered_loads"])
            probability_empty = (
                probability_closed_empty[station_index]
                * (math.exp(-open_load) if open_load < 746.0 else 0.0)
            )
            mean_active = closed_total_mean + open_load
            probability_all_busy = None
            utilization = None
        elif station.station_type in {PROCESSOR_SHARING, LCFS_PR}:
            open_means = [
                value * (closed_total_mean + 1.0) / (1.0 - open_load)
                for value in base["offered_loads"]
            ]
            probability_empty = (
                probability_closed_empty[station_index] * (1.0 - open_load)
            )
            mean_active = 1.0 - probability_empty
            probability_all_busy = mean_active
            utilization = mean_active
        elif station.station_type == FCFS:
            has_open = open_load > 0.0
            has_closed = any(
                closed_class.visit_ratios[station_index] > 0.0
                for closed_class in model.closed_classes
            )
            if has_open and has_closed:
                raise RuntimeError("shared FCFS escaped mixed BCMP validation")
            if has_open:
                open_means = list(base["mean_numbers"])
                probability_empty = float(base["probability_empty"])
                mean_active = float(base["mean_active_service_positions"])
                probability_all_busy = float(base["probability_all_servers_busy"])
                utilization = float(base["server_utilization"])
            else:
                open_means = [0.0] * open_count
                probability_empty = probability_closed_empty[station_index]
                mean_active = closed_mean_active_fcfs[station_index]
                probability_all_busy = closed_probability_all_busy_fcfs[station_index]
                assert station.servers is not None
                utilization = mean_active / station.servers
        else:
            raise RuntimeError("unsupported BCMP station type")
        if any(not math.isfinite(value) for value in open_means):
            raise ConfigError(
                "mean open population at station {!r} exceeds floating-point range"
                .format(station.station_id)
            )

        per_class = []
        total_throughput = 0.0
        for class_index, open_class in enumerate(model.open_classes):
            rate = open_class.traffic_rates[station_index]
            mean_number = open_means[class_index]
            residence = optional_ratio(mean_number, rate)
            little_residual = (
                0.0 if residence is None else mean_number - rate * residence
            )
            maximum_little_residual = max(
                maximum_little_residual, abs(little_residual)
            )
            open_class_mean_numbers[class_index] += mean_number
            total_throughput += rate
            per_class.append(
                {
                    "class": open_class.class_id,
                    "kind": "open",
                    "external_arrival_rate": open_class.external_arrival_rates[
                        station_index
                    ],
                    "arrival_rate": rate,
                    "throughput": rate,
                    "exit_probability": open_class.exit_probabilities[station_index],
                    "departure_to_outside_rate": (
                        rate * open_class.exit_probabilities[station_index]
                    ),
                    "mean_service_time": station.service_times[class_index],
                    "offered_load": base["offered_loads"][class_index],
                    "mean_number": mean_number,
                    "mean_residence_time_per_visit": residence,
                    "little_law_residual": little_residual,
                }
            )
        for class_index, closed_class in enumerate(model.closed_classes):
            visit_ratio = closed_class.visit_ratios[station_index]
            throughput = reference_throughputs[class_index] * visit_ratio
            mean_number = closed_means[station_index][class_index]
            residence = optional_ratio(mean_number, throughput)
            little_residual = (
                0.0 if residence is None else mean_number - throughput * residence
            )
            maximum_little_residual = max(
                maximum_little_residual, abs(little_residual)
            )
            total_throughput += throughput
            service_time = station.service_times[open_count + class_index]
            per_class.append(
                {
                    "class": closed_class.class_id,
                    "kind": "closed",
                    "visit_ratio": visit_ratio,
                    "throughput": throughput,
                    "mean_service_time": service_time,
                    "service_demand": (
                        None
                        if service_time is None
                        else visit_ratio * service_time
                    ),
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
                "open_offered_load": open_load,
                "open_traffic_intensity": base["traffic_intensity"],
                "open_stability_margin": (
                    None
                    if base["traffic_intensity"] is None
                    else 1.0 - float(base["traffic_intensity"])
                ),
                "log_local_open_normalizing_factor": base[
                    "log_normalizing_constant"
                ],
                "mean_number": closed_total_mean + sum(open_means),
                "mean_closed_number": closed_total_mean,
                "mean_open_number": sum(open_means),
                "probability_empty": probability_empty,
                "probability_all_servers_busy": probability_all_busy,
                "mean_active_service_positions": mean_active,
                "server_utilization": utilization,
                "throughput": total_throughput,
                "classes": per_class,
            }
        )

    open_class_results = []
    maximum_traffic_residual = 0.0
    maximum_flow_residual = 0.0
    for class_index, open_class in enumerate(model.open_classes):
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
        open_class_results.append(
            {
                "id": open_class.class_id,
                "external_arrival_rate": external_total,
                "departure_rate": departure_total,
                "flow_conservation_residual": open_class.flow_conservation_residual,
                "maximum_traffic_equation_residual": open_class.maximum_traffic_residual,
                "mean_number": open_class_mean_numbers[class_index],
                "mean_time_in_network": optional_ratio(
                    open_class_mean_numbers[class_index], external_total
                ),
                "mean_station_visits_per_arrival": sum(open_class.traffic_rates)
                / external_total,
            }
        )

    closed_class_results = []
    maximum_population_residual = 0.0
    for class_index, closed_class in enumerate(model.closed_classes):
        mean_population = sum(row[class_index] for row in closed_means)
        residual = mean_population - closed_class.population
        maximum_population_residual = max(
            maximum_population_residual, abs(residual)
        )
        throughput = reference_throughputs[class_index]
        closed_class_results.append(
            {
                "id": closed_class.class_id,
                "population": closed_class.population,
                "mean_population_cross_check": mean_population,
                "population_residual": residual,
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
        "model_type": "mixed_bcmp",
        "model": {
            "name": model.name,
            "station_count": station_count,
            "open_class_count": open_count,
            "closed_class_count": closed_count,
            "total_closed_population": sum(populations),
            "exact_subclass": (
                "shared PS, infinite-server, and LCFS-PR stations; FCFS stations "
                "exclusive to open or closed populations"
            ),
        },
        "solver": {
            "method": "exact mixed BCMP analytic open marginal and closed-state enumeration",
            "closed_marginal_state_count": len(states),
            "probability_mass": sum(probabilities),
            "log_closed_marginal_normalizing_constant": log_closed_g,
            "log_open_station_normalizing_factor": log_open_normalizing_factor,
            "log_full_normalizing_constant": (
                log_closed_g + log_open_normalizing_factor
            ),
            "minimum_open_stability_margin": minimum_stability_margin,
            "maximum_open_traffic_equation_residual": maximum_traffic_residual,
            "maximum_open_flow_conservation_residual": maximum_flow_residual,
            "maximum_closed_population_residual": maximum_population_residual,
            "maximum_little_law_residual": maximum_little_residual,
            "open_state_space": (
                "countably infinite; summed analytically without truncation"
            ),
        },
        "measures": {
            "open_classes": open_class_results,
            "closed_classes": closed_class_results,
            "stations": station_results,
        },
    }
    if include_states:
        result["closed_marginal_distribution"] = [
            {
                "index": index,
                "probability": probability_value,
                "closed_state": _state_json(
                    model.closed_projection, state
                ),
            }
            for index, (state, probability_value) in enumerate(
                zip(states, probabilities)
            )
        ]
    return result
