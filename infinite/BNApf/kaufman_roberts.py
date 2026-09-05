"""Exact Kaufman-Roberts recursion for a complete-sharing loss resource."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Tuple

try:  # Package import.
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
except ImportError:  # Direct execution/import with this directory on sys.path.
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


@dataclass(frozen=True)
class LossClass:
    class_id: str
    units: int
    offered_load: float
    arrival_rate: Optional[float]
    mean_holding_time: Optional[float]


@dataclass(frozen=True)
class KaufmanRobertsModel:
    name: str
    resource_id: str
    capacity: int
    classes: Tuple[LossClass, ...]


def parse_kaufman_roberts(document: Mapping[str, Any]) -> KaufmanRobertsModel:
    root = mapping(document, "document")
    check_keys(
        root,
        {
            "schema_version",
            "model_type",
            "name",
            "description",
            "resource",
            "classes",
            "solver",
        },
        "document",
    )
    require_fields(
        root,
        {"schema_version", "model_type", "name", "resource", "classes"},
        "document",
    )
    if root["model_type"] != "kaufman_roberts":
        raise ConfigError("model_type must be 'kaufman_roberts'")
    if integer(root["schema_version"], "schema_version", 1) != 1:
        raise ConfigError("schema_version must be 1")
    name = nonempty_string(root["name"], "name")
    if "description" in root and not isinstance(root["description"], str):
        raise ConfigError("description must be a string")

    resource_obj = mapping(root["resource"], "resource")
    check_keys(resource_obj, {"id", "capacity"}, "resource")
    require_fields(resource_obj, {"id", "capacity"}, "resource")
    resource_id = nonempty_string(resource_obj["id"], "resource.id")
    capacity = integer(resource_obj["capacity"], "resource.capacity", 1)
    solver_obj = mapping(root.get("solver", {}), "solver")
    check_keys(solver_obj, {"max_capacity"}, "solver")
    max_capacity = integer(
        solver_obj.get("max_capacity", 1_000_000), "solver.max_capacity", 1
    )
    if capacity > max_capacity:
        raise ConfigError(
            "resource capacity {} exceeds solver.max_capacity={}; increase the "
            "limit deliberately".format(capacity, max_capacity)
        )

    raw_classes = sequence(root["classes"], "classes")
    if not raw_classes:
        raise ConfigError("classes must contain at least one traffic class")
    classes: List[LossClass] = []
    class_ids = set()
    for index, raw_class in enumerate(raw_classes):
        context = "classes[{}]".format(index)
        class_obj = mapping(raw_class, context)
        check_keys(
            class_obj,
            {
                "id",
                "units",
                "offered_load",
                "arrival_rate",
                "mean_holding_time",
            },
            context,
        )
        require_fields(class_obj, {"id", "units"}, context)
        class_id = nonempty_string(class_obj["id"], context + ".id")
        if class_id in class_ids:
            raise ConfigError("class ids must be unique: {!r}".format(class_id))
        class_ids.add(class_id)
        units = integer(class_obj["units"], context + ".units", 1)
        if units > capacity:
            raise ConfigError(
                "{}.units cannot exceed resource capacity {}".format(
                    context, capacity
                )
            )
        has_load = "offered_load" in class_obj
        has_arrival = "arrival_rate" in class_obj
        has_holding = "mean_holding_time" in class_obj
        if has_load and (has_arrival or has_holding):
            raise ConfigError(
                "{} must use offered_load or arrival_rate with mean_holding_time, not both"
                .format(context)
            )
        if has_arrival != has_holding:
            raise ConfigError(
                "{} must provide arrival_rate and mean_holding_time together".format(
                    context
                )
            )
        if not has_load and not has_arrival:
            raise ConfigError(
                "{} must provide offered_load or arrival_rate with mean_holding_time"
                .format(context)
            )
        if has_load:
            offered_load = positive_number(
                class_obj["offered_load"], context + ".offered_load"
            )
            arrival_rate = None
            mean_holding_time = None
        else:
            arrival_rate = positive_number(
                class_obj["arrival_rate"], context + ".arrival_rate"
            )
            mean_holding_time = positive_number(
                class_obj["mean_holding_time"], context + ".mean_holding_time"
            )
            offered_load = arrival_rate * mean_holding_time
            if not math.isfinite(offered_load) or offered_load <= 0.0:
                raise ConfigError(
                    "{}.offered_load is outside floating-point range".format(context)
                )
        classes.append(
            LossClass(
                class_id,
                units,
                offered_load,
                arrival_rate,
                mean_holding_time,
            )
        )
    return KaufmanRobertsModel(name, resource_id, capacity, tuple(classes))


def solve_kaufman_roberts(model: KaufmanRobertsModel) -> Dict[str, Any]:
    # Log-domain Kaufman-Roberts recursion:
    #   g(c) = (1/c) sum_r a_r b_r g(c-b_r),  g(0)=1.
    # Only ratios of g matter, so log arithmetic avoids overflow at high load.
    log_weights = [-math.inf] * (model.capacity + 1)
    log_weights[0] = 0.0
    for occupied in range(1, model.capacity + 1):
        log_sum = -math.inf
        for loss_class in model.classes:
            previous = occupied - loss_class.units
            if previous < 0 or log_weights[previous] == -math.inf:
                continue
            term = (
                math.log(loss_class.offered_load)
                + math.log(loss_class.units)
                + log_weights[previous]
            )
            log_sum = logaddexp(log_sum, term)
        if log_sum != -math.inf:
            log_weights[occupied] = log_sum - math.log(occupied)

    log_normalizer = -math.inf
    for value in log_weights:
        log_normalizer = logaddexp(log_normalizer, value)
    probabilities = [
        0.0 if value == -math.inf else math.exp(value - log_normalizer)
        for value in log_weights
    ]

    class_results = []
    mean_units_from_classes = 0.0
    total_arrival_rate = 0.0
    total_accepted_rate = 0.0
    total_loss_rate = 0.0
    all_arrival_rates_known = True
    for loss_class in model.classes:
        first_blocked_occupancy = model.capacity - loss_class.units + 1
        acceptance_probability = sum(probabilities[:first_blocked_occupancy])
        blocking_probability = sum(probabilities[first_blocked_occupancy:])
        carried_load = loss_class.offered_load * acceptance_probability
        mean_calls = carried_load
        mean_units = loss_class.units * mean_calls
        mean_units_from_classes += mean_units
        if loss_class.arrival_rate is None:
            accepted_rate = None
            loss_rate = None
            all_arrival_rates_known = False
        else:
            accepted_rate = loss_class.arrival_rate * acceptance_probability
            loss_rate = loss_class.arrival_rate * blocking_probability
            total_arrival_rate += loss_class.arrival_rate
            total_accepted_rate += accepted_rate
            total_loss_rate += loss_rate
        class_results.append(
            {
                "id": loss_class.class_id,
                "units": loss_class.units,
                "offered_load": loss_class.offered_load,
                "arrival_rate": loss_class.arrival_rate,
                "mean_holding_time": loss_class.mean_holding_time,
                "blocking_probability": blocking_probability,
                "acceptance_probability": acceptance_probability,
                "carried_load": carried_load,
                "mean_calls_in_service": mean_calls,
                "mean_units_occupied": mean_units,
                "accepted_arrival_rate": accepted_rate,
                "loss_rate": loss_rate,
            }
        )

    mean_occupied = sum(
        occupied * value for occupied, value in enumerate(probabilities)
    )
    result = {
        "schema_version": 1,
        "model_type": "kaufman_roberts",
        "model": {
            "name": model.name,
            "resource": model.resource_id,
            "capacity": model.capacity,
            "class_count": len(model.classes),
        },
        "solver": {
            "method": "exact log-domain Kaufman-Roberts recursion",
            "occupancy_state_count": model.capacity + 1,
            "log_normalizing_constant": log_normalizer,
            "probability_mass": sum(probabilities),
            "mean_occupancy_conservation_residual": mean_occupied
            - mean_units_from_classes,
        },
        "measures": {
            "resource": {
                "id": model.resource_id,
                "capacity": model.capacity,
                "mean_units_occupied": mean_occupied,
                "utilization": mean_occupied / model.capacity,
                "probability_empty": probabilities[0],
                "probability_full": probabilities[-1],
                "total_arrival_rate": (
                    total_arrival_rate if all_arrival_rates_known else None
                ),
                "total_accepted_arrival_rate": (
                    total_accepted_rate if all_arrival_rates_known else None
                ),
                "total_loss_rate": total_loss_rate if all_arrival_rates_known else None,
                "aggregate_loss_probability": (
                    optional_ratio(total_loss_rate, total_arrival_rate)
                    if all_arrival_rates_known
                    else None
                ),
            },
            "classes": class_results,
            "occupancy_distribution": [
                {"occupied_units": occupied, "probability": value}
                for occupied, value in enumerate(probabilities)
            ],
        },
    }
    return result
