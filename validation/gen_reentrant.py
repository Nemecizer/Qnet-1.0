#!/usr/bin/env python3
"""Generate re-entrant network .bnet input files for the Qnet examples directory.

Class numbering convention (per user spec):
  A new class is introduced ONLY when the customer revisits a station that
  the customer's *current* class has already been to. So a single class
  represents one contiguous "round" through the network in which each
  station is visited at most once. The class number increments at each
  revisit; the customer's previous-rounds history is reset for the new
  class.

  Example: visit sequence S1 → S2 → S3 → S1 → S2 → S1
    stop  station  class  reason
       1      S1      1   first stop
       2      S2      1   first visit by class 1
       3      S3      1   first visit by class 1
       4      S1      2   class 1 already visited S1 → new class
       5      S2      2   class 2 hasn't been to S2 yet → stay class 2
       6      S1      3   class 2 already visited S1 → new class

Loader convention (still required by SRBMExporter.swift:128):
  Source #i emits class i; derived classes start at numSources.

Each chain is the deterministic visit sequence of one exogenous stream,
expressed as [(station_index_1based, mean_service), ...].
"""

import json
import os
import uuid

OUT_DIR = os.path.abspath(os.path.join(
    os.path.dirname(__file__), '..', 'input', 'examples'))


def fixed_uid(prefix: str, n: int) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{prefix}/{n}")).upper()


def assign_classes(chains, num_sources):
    """Walk each chain; increment the class on every revisit. Source classes
    are 0..num_sources-1 (chain index = source class). Derived classes are
    numbered consecutively starting at num_sources, in the order they appear.

    Returns:
      class_for: dict mapping (chain_idx, stop_idx) -> class index
      K:         total number of classes
    """
    next_derived = num_sources
    class_for = {}
    for c_idx, chain in enumerate(chains):
        current_class = c_idx              # source class for this chain
        visited = set()                    # stations visited by current_class
        for stop_idx, (station, _) in enumerate(chain):
            if station in visited:
                current_class = next_derived
                next_derived += 1
                visited = set()
            visited.add(station)
            class_for[(c_idx, stop_idx)] = current_class
    return class_for, next_derived


def build_reentrant_line(prefix, chains, source_rates,
                         buffer_capacity=10, infinite_buffers=True):
    """Build a deterministic re-entrant queueing network from per-stream chains
    using the revisit-only class numbering rule.
    """
    S = len(chains)
    assert len(source_rates) == S

    class_for, K = assign_classes(chains, S)

    # Per-class lifetime: list of (station, mean) in chain visit order.
    # By construction each class touches each station at most once.
    class_path = {k: [] for k in range(K)}
    for c_idx, chain in enumerate(chains):
        for stop_idx, (st, mean) in enumerate(chain):
            k = class_for[(c_idx, stop_idx)]
            class_path[k].append((st, mean))

    # Per-station per-class mean service: derive from class_path.
    # station_class_mean[(station, class)] = mean
    station_class_mean = {}
    for k, path in class_path.items():
        for st, mean in path:
            station_class_mean[(st, k)] = mean

    physical = sorted({st for path in class_path.values() for st, _ in path})

    # Physical stations.
    station_node = {}
    for i, sid in enumerate(physical):
        station_node[sid] = {
            "id": fixed_uid(prefix, 100 + sid),
            "kind": "station",
            "name": f"S{sid}",
            "bufferSize": 1,
            "distribution": "exponential",
            "distributionParameters": "rate=1.0",
            "numberOfServers": 1,
            "position": [600, 120 + i * 160],
            "serviceDistributions": {},
        }

    # One physical buffer per physical station (shared across classes).
    buffer_node = {}
    for i, sid in enumerate(physical):
        buffer_node[sid] = {
            "id": fixed_uid(prefix, 200 + sid),
            "kind": "buffer",
            "name": f"B{sid}",
            "bufferSize": buffer_capacity,
            "distribution": "exponential",
            "distributionParameters": "rate=1.0",
            "numberOfServers": 1,
            "position": [440, 120 + i * 160],
            "serviceDistributions": {},
        }

    # Sources (one per chain).
    sources = []
    for c_idx, rate in enumerate(source_rates):
        sources.append({
            "id": fixed_uid(prefix, 300 + c_idx),
            "kind": "source",
            "name": f"Src{c_idx + 1}",
            "bufferSize": 1,
            "distribution": "poisson",
            "distributionParameters": f"lambda={rate}",
            "numberOfServers": 1,
            "position": [200, 60 + c_idx * 200],
            "serviceDistributions": {},
        })

    sink_id = fixed_uid(prefix, 999)
    sink_node = {
        "id": sink_id,
        "kind": "sink",
        "name": "Sink",
        "bufferSize": 1,
        "distribution": "exponential",
        "distributionParameters": "rate=1.0",
        "numberOfServers": 1,
        "position": [820, 200],
        "serviceDistributions": {},
    }

    nodes = []
    nodes.extend(sources)
    nodes.extend(buffer_node[s] for s in physical)
    nodes.extend(station_node[s] for s in physical)
    nodes.append(sink_node)

    links = []
    link_n = [0]

    def add_link(from_id, to_id, customer_class, prob, to_class=None):
        link_n[0] += 1
        link = {
            "customerClass": customer_class,
            "fromNodeID": from_id,
            "id": fixed_uid(prefix, 5000 + link_n[0]),
            "routingProbability": prob,
            "toNodeID": to_id,
        }
        if to_class is not None and to_class != customer_class:
            link["toCustomerClass"] = to_class
        return link

    # Source -> first-stop buffer for each chain, carrying the chain's source class.
    for c_idx, chain in enumerate(chains):
        first_class = class_for[(c_idx, 0)]
        first_station = chain[0][0]
        links.append(add_link(
            sources[c_idx]["id"], buffer_node[first_station]["id"],
            customer_class=first_class, prob=1.0,
        ))

    # Buffer -> station for every (class, station) the class visits.
    for (st, k), _mean in station_class_mean.items():
        links.append(add_link(
            buffer_node[st]["id"], station_node[st]["id"],
            customer_class=k, prob=1.0,
        ))

    # Walk each chain to emit station-out links: in-class transitions when
    # the next stop is the same class, class transitions when it differs,
    # sink links at chain end.
    for c_idx, chain in enumerate(chains):
        for stop_idx in range(len(chain)):
            from_class = class_for[(c_idx, stop_idx)]
            from_station = chain[stop_idx][0]
            if stop_idx + 1 == len(chain):
                # Last stop in chain → sink (carries from_class).
                links.append(add_link(
                    station_node[from_station]["id"], sink_id,
                    customer_class=from_class, prob=1.0,
                ))
            else:
                next_class = class_for[(c_idx, stop_idx + 1)]
                next_station = chain[stop_idx + 1][0]
                # If same class, plain in-class routing; if different, class transition.
                links.append(add_link(
                    station_node[from_station]["id"],
                    buffer_node[next_station]["id"],
                    customer_class=from_class, prob=1.0,
                    to_class=(next_class if next_class != from_class else None),
                ))

    # Per-class service distributions on shared physical stations.
    for (st, k), mean in station_class_mean.items():
        rate = 1.0 / mean
        station_node[st]["serviceDistributions"][str(k)] = {
            "distribution": "exponential",
            "distributionParameters": f"rate={rate:.6f}",
        }

    return {
        "canvasScale": 1,
        "infiniteBuffers": infinite_buffers,
        "links": links,
        "nodes": nodes,
    }


def write(filename, doc):
    path = os.path.join(OUT_DIR, filename)
    with open(path, 'w') as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {path}")


# -----------------------------------------------------------------------------
# 1. Lu-Kumar 5-stop re-entrant line (banksDai96 §2 / Dai-VandeVate 1996).
# Visit sequence: S1 → S2 → S1 → S2 → S1 → exit.
# Service means per stop = (0.1, 0.6, 0.1, 0.1, 0.6); single source rate 1.
# Under revisit-only rule: 3 classes
#   c1 = stops 1,2 (S1 m=0.1, S2 m=0.6)
#   c2 = stops 3,4 (S1 m=0.1, S2 m=0.1)
#   c3 = stop 5    (S1 m=0.6)
# rho_1 = 0.1+0.1+0.6 = 0.8;  rho_2 = 0.6+0.1 = 0.7.
# -----------------------------------------------------------------------------
write(
    "LuKumar91.d2.c5.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="LuKumar91-r2",
        chains=[
            [(1, 0.1), (2, 0.6), (1, 0.1), (2, 0.1), (1, 0.6)],
        ],
        source_rates=[1.0],
    ),
)

# -----------------------------------------------------------------------------
# 2. Bramson 5-stop 2-station re-entrant line (Bramson 1994 AAP, banksDai96 §3).
# Visit sequence: S1 → S2 → S2 → S2 → S1 → exit.
# Service means per stop = (0.01, 0.88, 0.01, 0.01, 0.89).
# Under revisit-only rule: 3 classes
#   c1 = stops 1,2 (S1 m=0.01, S2 m=0.88)
#   c2 = stop 3    (S2 m=0.01)
#   c3 = stops 4,5 (S2 m=0.01, S1 m=0.89)
# rho_1 = m(c1,S1)+m(c3,S1) = 0.01+0.89 = 0.90.
# rho_2 = m(c1,S2)+m(c2,S2)+m(c3,S2) = 0.88+0.01+0.01 = 0.90.
# -----------------------------------------------------------------------------
write(
    "Bramson94.d2.c5.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="Bramson94d2-r2",
        chains=[
            [(1, 0.01), (2, 0.88), (2, 0.01), (2, 0.01), (1, 0.89)],
        ],
        source_rates=[1.0],
    ),
)

# -----------------------------------------------------------------------------
# 3. Kumar-Seidman 4-stop 2-station network (Kumar-Seidman 1990; banksDai96 §6).
# Two exogenous streams (rate 1 each):
#   Src1 path: S1 (m=0.1) → S2 (m=0.6) → exit
#   Src2 path: S2 (m=0.1) → S1 (m=0.6) → exit
# Neither path revisits a station, so each stream stays in its source class.
# Classes: c1 (Src1), c2 (Src2). Service rates per (station, class):
#   S1: c1 m=0.1, c2 m=0.6 → rho_1 = 0.7
#   S2: c1 m=0.6, c2 m=0.1 → rho_2 = 0.7
# -----------------------------------------------------------------------------
write(
    "KumarSeidman90.d2.c4.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="KumarSeidman90-r2",
        chains=[
            [(1, 0.1), (2, 0.6)],
            [(2, 0.1), (1, 0.6)],
        ],
        source_rates=[1.0, 1.0],
    ),
)

# -----------------------------------------------------------------------------
# 4. Bramson 5-stop 3-station variant (banksDai96 §3 Fig. 4).
# Visit sequence: S1 → S2 → S3 → S2 → S1 → exit.
# Service means per stop = (0.01, 0.88, 0.01, 0.01, 0.89).
# Under revisit-only rule: 2 classes
#   c1 = stops 1,2,3 (S1 m=0.01, S2 m=0.88, S3 m=0.01)
#   c2 = stops 4,5   (S2 m=0.01, S1 m=0.89)
# rho_1 = 0.01+0.89 = 0.90; rho_2 = 0.88+0.01 = 0.89; rho_3 = 0.01.
# -----------------------------------------------------------------------------
write(
    "Bramson94.d3.c5.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="Bramson94d3-r2",
        chains=[
            [(1, 0.01), (2, 0.88), (3, 0.01), (2, 0.01), (1, 0.89)],
        ],
        source_rates=[1.0],
    ),
)

# -----------------------------------------------------------------------------
# 5. Dai-Meyn 9-stop 3-station Kelly-type (banksDai96 §4 Fig. 5).
# Visit sequence: S1 → S2 → S3 → S2 → S3 → S2 → S1 → S3 → S1 → exit.
# Kelly-type: m=0.3 at S1 and S2, m=0.1 at S3 for every visit.
# Under revisit-only rule: 4 classes
#   c1 = stops 1,2,3 (S1, S2, S3)
#   c2 = stops 4,5   (S2, S3)
#   c3 = stops 6,7,8 (S2, S1, S3)
#   c4 = stop 9      (S1)
# rho_1 = 0.3+0.3+0.3 = 0.90;  rho_2 = 0.3+0.3+0.3 = 0.90;  rho_3 = 0.1+0.1+0.1 = 0.30.
# -----------------------------------------------------------------------------
write(
    "DaiMeyn95.d3.c9.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="DaiMeyn95-r2",
        chains=[
            [(1, 0.3), (2, 0.3), (3, 0.1), (2, 0.3), (3, 0.1),
             (2, 0.3), (1, 0.3), (3, 0.1), (1, 0.3)],
        ],
        source_rates=[1.0],
    ),
)

# -----------------------------------------------------------------------------
# 6. BanksDai96 SPT-perturbed 9-stop variant (banksDai96 §5).
# Same 9-stop topology as #5, class-dependent service means
#   m = (0.35, 0.25, 0.10, 0.30, 0.20, 0.35, 0.30, 0.30, 0.25).
# Class structure same as #5 (4 classes derived by revisit-only rule).
# rho_1 = m(c1,S1)+m(c3,S1)+m(c4,S1) = 0.35+0.30+0.25 = 0.90.
# rho_2 = m(c1,S2)+m(c2,S2)+m(c3,S2) = 0.25+0.30+0.35 = 0.90.
# rho_3 = m(c1,S3)+m(c2,S3)+m(c3,S3) = 0.10+0.20+0.30 = 0.60.
# -----------------------------------------------------------------------------
write(
    "BanksDai96.d3.c9.spt.reentrant.inf.bnet",
    build_reentrant_line(
        prefix="BanksDai96spt-r2",
        chains=[
            [(1, 0.35), (2, 0.25), (3, 0.10), (2, 0.30), (3, 0.20),
             (2, 0.35), (1, 0.30), (3, 0.30), (1, 0.25)],
        ],
        source_rates=[1.0],
    ),
)
