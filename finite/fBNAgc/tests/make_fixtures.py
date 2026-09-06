"""Fixtures for the generic-finite-CTMC engine-parity test.

The sweep exists because of how this chain is indexed. States are tuples of
ORDERED queues, enumerated breadth-first from empty, and each new state takes
the next index in the order it is DISCOVERED -- which is the order events are
generated in. Every number downstream is indexed by that. A single-station,
single-class model exercises almost none of it: no class switching, no internal
routing, no blocked internal move, no multi-server head-of-queue. These do.
"""

import json
import os
import sys


def single_class_mm1k(capacity=6):
    return {
        "schema_version": 1,
        "name": "M/M/1/K",
        "classes": ["jobs"],
        "stations": [{"id": "s", "servers": 1, "capacity": capacity,
                      "service_rates": {"jobs": 1.3}}],
        "external_arrivals": [{"station": "s", "class": "jobs", "rate": 0.9}],
    }


def multiserver_two_class():
    return {
        "schema_version": 1,
        "name": "two classes, two servers",
        "classes": ["a", "b"],
        "stations": [{"id": "pool", "servers": 2, "capacity": 5,
                      "service_rates": {"a": 1.1, "b": 0.7}}],
        "external_arrivals": [
            {"station": "pool", "class": "a", "rate": 0.5},
            {"station": "pool", "class": "b", "rate": 0.4},
        ],
    }


def tandem_with_class_switch():
    """Class switching and an internal move that can be blocked: the two
    branches of the transition builder a single-station model never reaches."""
    return {
        "schema_version": 1,
        "name": "tandem with class switching",
        "classes": ["raw", "finished"],
        "stations": [
            {"id": "cut", "servers": 1, "capacity": 3, "service_rates": {"raw": 1.4}},
            {"id": "pack", "servers": 2, "capacity": 3,
             "service_rates": {"raw": 0.9, "finished": 1.2}},
        ],
        "external_arrivals": [{"station": "cut", "class": "raw", "rate": 0.8}],
        "routing": [
            {"from_station": "cut", "from_class": "raw",
             "destinations": [
                 {"station": "pack", "class": "finished", "probability": 0.7},
                 {"exit": True, "probability": 0.3},
             ]},
            {"from_station": "pack", "from_class": "finished",
             "destinations": [{"exit": True, "probability": 1.0}]},
        ],
    }


def feedback_to_self():
    """A route whose destination is its own station, which is the one case where
    the post-completion queue length has to be decremented before the capacity
    check."""
    return {
        "schema_version": 1,
        "name": "feedback to the same station",
        "classes": ["x", "y"],
        "stations": [{"id": "loop", "servers": 1, "capacity": 4,
                      "service_rates": {"x": 1.5, "y": 1.1}}],
        "external_arrivals": [{"station": "loop", "class": "x", "rate": 0.7}],
        "routing": [
            {"from_station": "loop", "from_class": "x",
             "destinations": [
                 {"station": "loop", "class": "y", "probability": 0.4},
                 {"exit": True, "probability": 0.6},
             ]},
            {"from_station": "loop", "from_class": "y",
             "destinations": [{"exit": True, "probability": 1.0}]},
        ],
    }


def three_station_chain():
    return {
        "schema_version": 1,
        "name": "three-station chain",
        "classes": ["c"],
        "stations": [
            {"id": "a", "servers": 1, "capacity": 3, "service_rates": {"c": 1.0}},
            {"id": "b", "servers": 2, "capacity": 3, "service_rates": {"c": 0.8}},
            {"id": "z", "servers": 1, "capacity": 2, "service_rates": {"c": 1.6}},
        ],
        "external_arrivals": [{"station": "a", "class": "c", "rate": 0.6}],
        "routing": [
            {"from_station": "a", "from_class": "c",
             "destinations": [{"station": "b", "probability": 1.0}]},
            {"from_station": "b", "from_class": "c",
             "destinations": [{"station": "z", "probability": 0.8},
                              {"exit": True, "probability": 0.2}]},
        ],
    }


SWEEP = [
    ("M/M/1/K", single_class_mm1k()),
    ("M/M/1/K capacity 9", single_class_mm1k(9)),
    ("two classes two servers", multiserver_two_class()),
    ("tandem with class switching", tandem_with_class_switch()),
    ("feedback to the same station", feedback_to_self()),
    ("three-station chain", three_station_chain()),
]


def mutate(**changes):
    document = single_class_mm1k()
    for key, value in changes.items():
        if value is None:
            document.pop(key, None)
        else:
            document[key] = value
    return document


REFUSALS = [
    ("missing name",            mutate(name=None)),
    ("schema version",          mutate(schema_version=2)),
    ("unknown root field",      mutate(blocked="yes")),
    ("blocking not loss",       mutate(blocking="BAS")),
    ("discipline not fcfs",     mutate(service_discipline="lcfs")),
    ("no classes",              mutate(classes=[])),
    ("duplicate class ids",     mutate(classes=["jobs", "jobs"])),
    ("no stations",             mutate(stations=[])),
    ("servers over capacity",   mutate(stations=[{"id": "s", "servers": 4, "capacity": 2,
                                                  "service_rates": {"jobs": 1.0}}])),
    ("empty service rates",     mutate(stations=[{"id": "s", "servers": 1, "capacity": 2,
                                                  "service_rates": {}}])),
    ("unknown rate class",      mutate(stations=[{"id": "s", "servers": 1, "capacity": 2,
                                                  "service_rates": {"nope": 1.0}}])),
    ("zero service rate",       mutate(stations=[{"id": "s", "servers": 1, "capacity": 2,
                                                  "service_rates": {"jobs": 0.0}}])),
    ("unknown arrival station", mutate(external_arrivals=[{"station": "zz", "class": "jobs",
                                                           "rate": 0.5}])),
    ("unknown arrival class",   mutate(external_arrivals=[{"station": "s", "class": "zz",
                                                           "rate": 0.5}])),
    ("zero arrival rate",       mutate(external_arrivals=[{"station": "s", "class": "jobs",
                                                           "rate": 0.0}])),
    ("unknown station field",   mutate(stations=[{"id": "s", "servers": 1, "capacity": 2,
                                                  "service_rates": {"jobs": 1.0},
                                                  "colour": "red"}])),
    ("routing unknown source",  mutate(routing=[{"from_station": "zz", "from_class": "jobs",
                                                 "destinations": [{"exit": True,
                                                                   "probability": 1.0}]}])),
    ("duplicate routing rule",  mutate(routing=[
        {"from_station": "s", "from_class": "jobs",
         "destinations": [{"exit": True, "probability": 1.0}]},
        {"from_station": "s", "from_class": "jobs",
         "destinations": [{"exit": True, "probability": 1.0}]}])),
    ("empty destinations",      mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": []}])),
    ("exit with a station",     mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": [{"exit": True, "station": "s",
                                                                   "probability": 1.0}]}])),
    ("exit false",              mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": [{"exit": False, "station": "s",
                                                                   "probability": 1.0}]}])),
    ("duplicate destination",   mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": [
                                                     {"station": "s", "probability": 0.4},
                                                     {"station": "s", "probability": 0.4}]}])),
    ("probability over one",    mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": [{"exit": True,
                                                                   "probability": 1.5}]}])),
    ("probabilities sum over one", mutate(
        classes=["jobs", "other"],
        stations=[{"id": "s", "servers": 1, "capacity": 2,
                   "service_rates": {"jobs": 1.0, "other": 1.0}}],
        routing=[{"from_station": "s", "from_class": "jobs",
                  "destinations": [{"station": "s", "class": "other", "probability": 0.9},
                                   {"exit": True, "probability": 0.9}]}])),
    ("not open",                mutate(routing=[{"from_station": "s", "from_class": "jobs",
                                                 "destinations": [{"station": "s",
                                                                   "probability": 1.0}]}])),
    ("state limit",             mutate(stations=[{"id": "s", "servers": 1, "capacity": 50,
                                                  "service_rates": {"jobs": 1.0}}],
                                       solver={"max_states": 5})),
    ("slack too large",         mutate(solver={"uniformization_slack": 20.0})),
    ("unknown solver field",    mutate(solver={"speed": 1})),
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
