"""Exact Mean Value Analysis for closed multiclass BCMP networks.

Why this exists
---------------
``bcmp.solve_bcmp`` computes the same quantities by enumerating every feasible
population state and normalising. That is exact and it is the reference, but the
state count is ``prod_r C(N_r + I - 1, I - 1)``, which is combinatorial in both
the population and the station count: a single class of 50 jobs over 6 stations
is 3,478,761 states, past the module's 200,000-state guard.

MVA (Reiser and Lavenberg 1980) computes the same means from a recursion over
the *population lattice* ``prod_r (N_r + 1)`` instead. The same network is 51
steps. The recursion is exact — this is not an approximation of the enumerator,
it is a different route to the same product-form solution, and
``tests/test_mva.py`` asserts they agree to 1e-9 on every model small enough to
enumerate.

Scope, and the reason for it
----------------------------
MVA is polynomial in the *population* and exponential in the *number of
classes*, because the lattice has one axis per class. Enumeration is
combinatorial in both. So MVA is a strict improvement for few classes and large
populations — which is the case enumeration cannot do — and the two swap places
only for many classes and tiny populations, where enumeration is instant anyway.
``solver.py`` chooses on that basis rather than always preferring one.

What it computes, and what it does not
--------------------------------------
MVA yields exact *means*: per-class queue lengths, residence times, throughputs
and utilisations. It does not yield the full joint state distribution, so the
state-probability payload the enumerator can return has no MVA counterpart. The
marginal-probability terms this module computes for multi-server stations are
kept, because they are exact and the enumerator reports the same quantity.

Station types map onto the recursion exactly as ``bcmp.log_state_weight``
defines them:

* ``infinite_server``      delay term, ``R = D``
* ``processor_sharing``    load-independent single server
* ``lcfs_preemptive_resume`` load-independent single server
* ``fcfs`` with ``servers == 1``  load-independent single server
* ``fcfs`` with ``servers > 1``   load-dependent; needs the marginal
  probabilities ``p_i(j | n)`` for ``j < c_i``, which are carried through the
  recursion alongside the queue lengths.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:  # Package import.
    from .bcmp import FCFS, INFINITE_SERVER, BCMPModel
    from .common import ConfigError
except ImportError:  # Direct script execution.
    from bcmp import FCFS, INFINITE_SERVER, BCMPModel
    from common import ConfigError


def lattice_size(model: BCMPModel) -> int:
    """Number of MVA recursion steps: ``prod_r (N_r + 1)``.

    This is the figure to compare against ``bcmp.state_count`` when deciding
    which method to run.
    """
    size = 1
    for closed_class in model.classes:
        size *= closed_class.population + 1
    return size


def _is_delay(station) -> bool:
    return station.station_type == INFINITE_SERVER


def _server_count(station) -> int:
    """Servers as the recursion sees them.

    PS and LCFS-PR are single-server queueing stations in the BCMP product form
    — `bcmp.log_state_weight` gives them the ``n_i!`` factor with no capacity
    correction, which is the ``c = 1`` case. Their ``servers`` field, if set, is
    not a load-dependent capacity and must not be read as one.
    """
    if station.station_type == FCFS:
        return int(station.servers or 1)
    return 1


def _demands(model: BCMPModel) -> List[List[float]]:
    """``D[i][r] = V_ir * S_ir``, with 0 where class r never visits station i."""
    demands: List[List[float]] = []
    for station_index, station in enumerate(model.stations):
        row: List[float] = []
        for class_index, closed_class in enumerate(model.classes):
            visit_ratio = closed_class.visit_ratios[station_index]
            service_time = station.service_times[class_index]
            if service_time is None or visit_ratio <= 0.0:
                row.append(0.0)
            else:
                row.append(visit_ratio * service_time)
        demands.append(row)
    return demands


def solve_mva(model: BCMPModel) -> Dict[str, Any]:
    """Exact MVA. Returns the same metric names ``bcmp.solve_bcmp`` returns."""
    station_count = len(model.stations)
    class_count = len(model.classes)
    populations = [closed_class.population for closed_class in model.classes]
    demands = _demands(model)
    servers = [_server_count(station) for station in model.stations]
    delay = [_is_delay(station) for station in model.stations]
    max_servers = max(servers) if servers else 1

    # Mixed-radix indexing over the population lattice. radix[r] is the stride
    # for class r, so a population vector maps to one integer and the "remove
    # one job of class r" neighbour is a subtraction of that stride.
    radix: List[int] = []
    stride = 1
    for population in populations:
        radix.append(stride)
        stride *= population + 1
    total_points = stride

    # queue[point][i] — mean number at station i at that population.
    queue: List[List[float]] = [[0.0] * station_count for _ in range(total_points)]
    # marginal[point][i][j] — P(j jobs at station i), j = 0 .. c_i - 1. Only
    # needed for load-dependent stations; kept empty otherwise so the common
    # single-server case costs nothing.
    needs_marginal = any(c > 1 and not d for c, d in zip(servers, delay))
    marginal: List[List[List[float]]] = []
    if needs_marginal:
        marginal = [
            [[0.0] * max_servers for _ in range(station_count)]
            for _ in range(total_points)
        ]
        for station_index in range(station_count):
            marginal[0][station_index][0] = 1.0

    throughput_at: Dict[int, List[float]] = {}
    residence_at: Dict[int, List[List[float]]] = {}

    # Walk the lattice in increasing total population so that every
    # (n - e_r) neighbour is already solved.
    for point in range(1, total_points):
        counts: List[int] = []
        remainder = point
        for class_index in range(class_count):
            counts.append((remainder // radix[class_index]) % (populations[class_index] + 1))
        # residence[i][r] — mean time class r spends at station i per reference visit
        residence = [[0.0] * class_count for _ in range(station_count)]
        for class_index in range(class_count):
            if counts[class_index] == 0:
                continue
            previous = point - radix[class_index]
            for station_index in range(station_count):
                demand = demands[station_index][class_index]
                if demand <= 0.0:
                    continue
                if delay[station_index]:
                    residence[station_index][class_index] = demand
                    continue
                capacity = servers[station_index]
                if capacity <= 1:
                    residence[station_index][class_index] = demand * (
                        1.0 + queue[previous][station_index]
                    )
                else:
                    # Reiser's load-dependent term: the arriving job waits
                    # behind the queue it sees, minus the work that idle
                    # servers absorb.
                    correction = 0.0
                    for j in range(capacity - 1):
                        correction += (capacity - 1 - j) * marginal[previous][station_index][j]
                    residence[station_index][class_index] = (
                        demand
                        * (1.0 + queue[previous][station_index] + correction)
                        / capacity
                    )

        throughput = [0.0] * class_count
        for class_index in range(class_count):
            if counts[class_index] == 0:
                continue
            total_residence = math.fsum(
                residence[station_index][class_index] for station_index in range(station_count)
            )
            if total_residence <= 0.0:
                raise ConfigError(
                    "class {!r} has zero total service demand; it cannot be a closed "
                    "class with a positive population".format(model.classes[class_index].class_id)
                )
            throughput[class_index] = counts[class_index] / total_residence

        for station_index in range(station_count):
            queue[point][station_index] = math.fsum(
                throughput[class_index] * residence[station_index][class_index]
                for class_index in range(class_count)
            )

        if needs_marginal:
            for station_index in range(station_count):
                capacity = servers[station_index]
                if capacity <= 1 or delay[station_index]:
                    marginal[point][station_index][0] = 1.0
                    continue
                utilisation_terms = [
                    demands[station_index][class_index] * throughput[class_index]
                    for class_index in range(class_count)
                ]
                for j in range(1, capacity):
                    accumulated = 0.0
                    for class_index in range(class_count):
                        if counts[class_index] == 0:
                            continue
                        previous = point - radix[class_index]
                        accumulated += (
                            utilisation_terms[class_index]
                            * marginal[previous][station_index][j - 1]
                        )
                    marginal[point][station_index][j] = accumulated / j
                busy = math.fsum(utilisation_terms) / capacity
                tail = math.fsum(
                    (capacity - j) * marginal[point][station_index][j]
                    for j in range(1, capacity)
                )
                marginal[point][station_index][0] = max(0.0, 1.0 - busy - tail / capacity)

        throughput_at[point] = throughput
        residence_at[point] = residence

    full = total_points - 1
    if full <= 0:
        # Every class has population zero: an empty but well-defined network.
        reference_throughputs = [0.0] * class_count
        final_residence = [[0.0] * class_count for _ in range(station_count)]
        final_queue = [0.0] * station_count
    else:
        reference_throughputs = throughput_at[full]
        final_residence = residence_at[full]
        final_queue = queue[full]

    station_results: List[Dict[str, Any]] = []
    for station_index, station in enumerate(model.stations):
        class_results = []
        total_throughput = 0.0
        busy_positions = 0.0
        for class_index, closed_class in enumerate(model.classes):
            visit_ratio = closed_class.visit_ratios[station_index]
            station_throughput = reference_throughputs[class_index] * visit_ratio
            total_throughput += station_throughput
            service_time = station.service_times[class_index]
            if service_time is not None and visit_ratio > 0.0:
                busy_positions += reference_throughputs[class_index] * visit_ratio * service_time
            mean_number = (
                reference_throughputs[class_index] * final_residence[station_index][class_index]
            )
            class_results.append(
                {
                    "class": closed_class.class_id,
                    "visit_ratio": visit_ratio,
                    "mean_service_time": service_time,
                    "service_demand": (
                        None if service_time is None else visit_ratio * service_time
                    ),
                    "mean_number": mean_number,
                    "throughput": station_throughput,
                    "mean_residence_time_per_visit": (
                        None
                        if station_throughput <= 0.0
                        else mean_number / station_throughput
                    ),
                }
            )

        if delay[station_index]:
            utilisation: Optional[float] = None
            probability_empty: Optional[float] = None
        elif servers[station_index] > 1:
            utilisation = busy_positions / servers[station_index]
            probability_empty = (
                marginal[full][station_index][0] if needs_marginal and full > 0 else None
            )
        else:
            utilisation = busy_positions
            # For a single-server station the product form gives P(empty)
            # exactly as 1 - utilisation; no separate recursion is needed.
            probability_empty = 1.0 - busy_positions

        station_results.append(
            {
                "id": station.station_id,
                "type": station.station_type,
                "servers": station.servers,
                "mean_number": final_queue[station_index],
                "probability_empty": probability_empty,
                "mean_active_service_positions": busy_positions,
                "server_utilization": utilisation,
                "throughput": total_throughput,
                "classes": class_results,
            }
        )

    # Field names mirror bcmp.solve_bcmp exactly, so the two are directly
    # comparable and either can populate the same result envelope.
    class_results_top = []
    for class_index, closed_class in enumerate(model.classes):
        cross_check = math.fsum(
            result["classes"][class_index]["mean_number"] for result in station_results
        )
        class_results_top.append({
            "id": closed_class.class_id,
            "population": closed_class.population,
            "mean_population_cross_check": cross_check,
            "population_residual": cross_check - closed_class.population,
            "reference_station": model.stations[closed_class.reference_station].station_id,
            "reference_throughput": reference_throughputs[class_index],
            "mean_time_per_reference_visit": (
                None
                if reference_throughputs[class_index] <= 0.0
                else closed_class.population / reference_throughputs[class_index]
            ),
        })

    # Little's law over the whole network, per class: N_r = X_r * sum_i R_ir.
    # Reported rather than asserted — it is a diagnostic on this computation,
    # not a certificate about the queueing model.
    little_residual = 0.0
    for class_index, closed_class in enumerate(model.classes):
        modelled = reference_throughputs[class_index] * math.fsum(
            final_residence[station_index][class_index]
            for station_index in range(len(model.stations))
        )
        little_residual = max(little_residual, abs(modelled - closed_class.population))

    population_residual = 0.0
    for class_index, closed_class in enumerate(model.classes):
        total = math.fsum(
            result["classes"][class_index]["mean_number"] for result in station_results
        )
        population_residual = max(population_residual, abs(total - closed_class.population))

    return {
        "method": "exact_mva",
        "model": model.name,
        "network_type": "closed",
        "measures": {
            "classes": class_results_top,
            "stations": station_results,
        },
        "diagnostics": {
            "algorithm": "exact mean value analysis (Reiser-Lavenberg)",
            "lattice_points": total_points,
            "enumerated_states_avoided": None,
            "littles_law_residual": little_residual,
            "population_conservation_residual": population_residual,
            "state_distribution_available": False,
            "state_distribution_reason": (
                "MVA computes exact means through a recursion over the population "
                "lattice and never forms the joint state distribution; run the "
                "enumerating solver if the full state law is required"
            ),
        },
    }
