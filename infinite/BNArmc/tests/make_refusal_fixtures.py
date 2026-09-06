"""One malformed document per validation rule, for the engine-parity test.

Kept as data rather than inline in the shell script: the point of the list is
that it enumerates the RULES, and a reader should be able to see at a glance
which rule has no case. Each entry is (label, document); the label is what the
parity test prints when the two engines word a refusal differently.
"""

import json
import os
import sys

CASES = [
    ("empty nodes",             {"nodes": []}),
    ("empty classes",           {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": []}),
    ("schema version",          {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "schema_version": 2}),
    ("wrong process",           {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "process": "wrong"}),
    ("unknown root key",        {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stoping": {}}),
    ("empty node id",           {"nodes": [{"id": "", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {}}]}),
    ("zero service rate",       {"nodes": [{"id": "a", "service_rate": 0.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}]}),
    ("zero servers",            {"nodes": [{"id": "a", "service_rate": 1.0, "servers": 0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}]}),
    ("capacity below servers",  {"nodes": [{"id": "a", "service_rate": 1.0, "servers": 2, "capacity": 1}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}]}),
    ("duplicate node id",       {"nodes": [{"id": "a", "service_rate": 1.0}, {"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}]}),
    ("mixed buffers",           {"nodes": [{"id": "a", "service_rate": 1.0, "capacity": 3}, {"id": "b", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}]}),
    ("no exit path",            {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}, "routing": {"a": {"a": 1.0}}}]}),
    ("routing row over one",    {"nodes": [{"id": "a", "service_rate": 1.0}, {"id": "b", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}, "routing": {"a": {"b": 0.7, "a": 0.7}}}]}),
    ("unknown arrival node",    {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"nope": 1.0}}]}),
    ("no arrivals",             {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.0}}]}),
    ("unstable",                {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 2.0}}]}),
    ("confidence out of range", {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"confidence": 0.4}}),
    ("no half-width target",    {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"absolute_half_width": 0, "relative_half_width": 0}}),
    ("min cycles below 30",     {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"minimum_cycles": 5}}),
    ("max below min cycles",    {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"minimum_cycles": 40, "maximum_cycles": 30}}),
    ("empty monitored list",    {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"monitored_metrics": []}}),
    ("unknown metric",          {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "stopping": {"monitored_metrics": ["not_a_metric"]}}),
    ("bad rare-event method",   {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "rare_event": {"method": "bogus"}}),
    ("multiplier without IS",   {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "rare_event": {"method": "none", "arrival_rate_multiplier": 2.0}}),
    ("unknown initial node",    {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "initial_jobs": {"zzz": {"c": 1}}}),
    ("initial over capacity",   {"nodes": [{"id": "a", "service_rate": 1.0, "capacity": 2}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "initial_jobs": {"a": {"c": 5}}}),
    ("negative seed",           {"nodes": [{"id": "a", "service_rate": 1.0}], "classes": [{"id": "c", "external_arrival_rates": {"a": 0.5}}], "random": {"base_seed": -1}}),
]


def main() -> int:
    work = sys.argv[1]
    rows = []
    for index, (label, document) in enumerate(CASES):
        path = os.path.join(work, "refusal_%02d.json" % index)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        rows.append("%s\t%s" % (path, label))
    with open(os.path.join(work, "refusals.tsv"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
