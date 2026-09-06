"""Fixtures for the adaptive-truncated-CTMC engine-parity test.

Two families:

  * `sweep` — valid networks of growing dimension and cap. Dimension is what
    matters: a one-node model exercises none of the state-ranking arithmetic,
    the routing matrix or the multi-node moment sums, so a transcription error
    in any of them survives a single-node test.

  * `refusals` — one invalid document per validation rule, so that a document
    the reference engine rejects is rejected by the other with the same code
    and the same sentence.
"""

import json
import os
import sys


def tandem(nodes, cap, max_states, rate=0.6):
    return {
        "schema_version": 1,
        "process": "open_single_class_markovian_network",
        "name": "%d-node tandem" % nodes,
        "nodes": [
            {
                "name": "n%d" % i,
                "external_arrival_rate": rate if i == 0 else 0.0,
                "service_rate_per_server": 1.0,
                "servers": 1,
            }
            for i in range(nodes)
        ],
        "routing": [
            [1.0 if j == i + 1 else 0.0 for j in range(nodes)] for i in range(nodes)
        ],
        "solver": {
            "initial_total_cap": max(2, cap // 2),
            "max_total_cap": cap,
            "max_states": max_states,
            "tail_levels": [1, 3, 7],
        },
    }


def feedback_multiserver():
    """Feedback routing, several servers, and arrivals at two nodes: the
    combination that exercises the load-dependent service rate and the
    internal-move branch of the operator build together."""
    return {
        "schema_version": 1,
        "process": "open_single_class_markovian_network",
        "name": "feedback with multiple servers",
        "nodes": [
            {"name": "front", "external_arrival_rate": 0.7,
             "service_rate_per_server": 0.9, "servers": 2},
            {"name": "back", "external_arrival_rate": 0.2,
             "service_rate_per_server": 1.3, "servers": 3},
        ],
        "routing": [[0.0, 0.5], [0.25, 0.0]],
        "solver": {"initial_total_cap": 4, "max_total_cap": 18, "max_states": 50000},
    }


SWEEP = [
    ("1-node cap 12", tandem(1, 12, 10000)),
    ("2-node cap 14", tandem(2, 14, 20000)),
    ("3-node cap 12", tandem(3, 12, 30000)),
    ("4-node cap 10", tandem(4, 10, 40000)),
    ("feedback multi-server", feedback_multiserver()),
]


def base():
    return tandem(2, 10, 10000)


def mutate(**changes):
    document = base()
    for path, value in changes.items():
        parts = path.split(".")
        target = document
        for part in parts[:-1]:
            target = target[part]
        if value is None:
            target.pop(parts[-1], None)
        else:
            target[parts[-1]] = value
    return document


REFUSALS = [
    ("schema version",         mutate(schema_version=2)),
    ("wrong process",          mutate(process="closed_network")),
    ("no nodes",               mutate(nodes=[])),
    ("duplicate node names",   mutate(nodes=[{"name": "a", "external_arrival_rate": 0.5,
                                              "service_rate_per_server": 1.0},
                                             {"name": "a", "external_arrival_rate": 0.0,
                                              "service_rate_per_server": 1.0}])),
    ("negative arrival",       mutate(**{"nodes": [{"name": "a", "external_arrival_rate": -1.0,
                                                    "service_rate_per_server": 1.0},
                                                   {"name": "b", "external_arrival_rate": 0.0,
                                                    "service_rate_per_server": 1.0}]})),
    ("zero service rate",      mutate(**{"nodes": [{"name": "a", "external_arrival_rate": 0.5,
                                                    "service_rate_per_server": 0.0},
                                                   {"name": "b", "external_arrival_rate": 0.0,
                                                    "service_rate_per_server": 1.0}]})),
    ("zero servers",           mutate(**{"nodes": [{"name": "a", "external_arrival_rate": 0.5,
                                                    "service_rate_per_server": 1.0, "servers": 0},
                                                   {"name": "b", "external_arrival_rate": 0.0,
                                                    "service_rate_per_server": 1.0}]})),
    ("routing wrong shape",    mutate(routing=[[0.0, 1.0]])),
    ("routing row over one",   mutate(routing=[[0.6, 0.6], [0.0, 0.0]])),
    ("negative routing",       mutate(routing=[[0.0, -0.5], [0.0, 0.0]])),
    ("unstable",               mutate(**{"nodes": [{"name": "a", "external_arrival_rate": 2.0,
                                                    "service_rate_per_server": 1.0},
                                                   {"name": "b", "external_arrival_rate": 0.0,
                                                    "service_rate_per_server": 1.0}]})),
    ("closed routing",         mutate(routing=[[0.0, 1.0], [1.0, 0.0]])),
    ("initial cap over max",   mutate(solver={"initial_total_cap": 20, "max_total_cap": 5})),
    ("growth factor at one",   mutate(solver={"growth_factor": 1.0})),
    ("state limit",            mutate(solver={"initial_total_cap": 40, "max_total_cap": 40,
                                              "max_states": 10})),
    ("tail levels not array",  mutate(solver={"tail_levels": 3})),
    ("negative tail level",    mutate(solver={"tail_levels": [-2]})),
    ("include not boolean",    mutate(solver={"include_state_probabilities": "yes"})),
    ("name not a string",      mutate(name=7)),
]


def write(cases, work, prefix):
    rows = []
    for index, (label, document) in enumerate(cases):
        path = os.path.join(work, "%s_%02d.json" % (prefix, index))
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        rows.append("%s\t%s" % (path, label))
    with open(os.path.join(work, "%s.tsv" % prefix), "w", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")


def main() -> int:
    work = sys.argv[1]
    write(SWEEP, work, "sweep")
    write(REFUSALS, work, "refusals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
