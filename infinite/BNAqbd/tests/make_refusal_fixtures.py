"""One malformed QBD document per validation rule, for the engine-parity test.

Kept as data so a reader can see which rule has no case. Each entry is
(label, document); the label is what the parity test prints when the two
engines word a refusal differently.
"""

import json
import os
import sys

# A well-formed M/M/1 QBD, mutated per case.
def base():
    return {
        "schema_version": 1,
        "process": "continuous_time_qbd",
        "name": "base",
        "boundary": {
            "level_0_same": [[-1.0]],
            "level_0_up": [[1.0]],
            "level_1_down": [[2.0]],
            "level_1_same": [[-3.0]],
        },
        "interior": {"down": [[2.0]], "same": [[-3.0]], "up": [[1.0]]},
    }


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


CASES = [
    ("schema version",        mutate(schema_version=2)),
    ("wrong process",         mutate(process="discrete_time_qbd")),
    ("missing boundary",      mutate(boundary=None)),
    ("missing interior",      mutate(interior=None)),
    ("empty matrix",          mutate(**{"interior.up": []})),
    ("ragged matrix",         mutate(**{"interior.up": [[1.0], [1.0, 2.0]]})),
    ("shape mismatch",        mutate(**{"interior.up": [[1.0, 0.0], [0.0, 1.0]]})),
    ("negative transition",   mutate(**{"interior.up": [[-1.0]]})),
    ("positive diagonal",     mutate(**{"interior.same": [[3.0]]})),
    ("row sum nonzero",       mutate(**{"interior.up": [[1.5]]})),
    ("transient",             mutate(**{"interior.up": [[4.0]], "interior.same": [[-6.0]],
                                        "boundary.level_1_same": [[-6.0]]})),
    ("bad tail level",        mutate(solver={"tail_levels": [-1]})),
    ("tail levels not array", mutate(solver={"tail_levels": 5})),
    ("zero max iterations",   mutate(solver={"max_iterations": 0})),
    ("negative tolerance",    mutate(solver={"absolute_tolerance": -1.0})),
    ("name not a string",     mutate(name=5)),
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
