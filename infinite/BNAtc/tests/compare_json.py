"""Compare the two engines' JSON by VALUE, not by text.

The Python writes its document with json.dump (sorted keys, repr floats) and
the C engine hand-writes its own, so the two are not byte-comparable and were
never meant to be. What must agree is every number the C engine publishes: for
each key it emits, the Python's document must carry the same key somewhere with
exactly the same double. Exactly -- there is no tolerance here, because this
method is deterministic and a difference is a defect.
"""

import json
import math
import sys


def flatten(value, prefix=""):
    """Every scalar in the document, keyed by its path."""
    found = {}
    if isinstance(value, dict):
        for key, item in value.items():
            found.update(flatten(item, "%s.%s" % (prefix, key) if prefix else key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.update(flatten(item, "%s[%d]" % (prefix, index)))
    else:
        found[prefix] = value
    return found


def main() -> int:
    python_path, c_path, label = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        py = flatten(json.load(open(python_path, encoding="utf-8")))
        c = flatten(json.load(open(c_path, encoding="utf-8")))
    except (OSError, json.JSONDecodeError) as error:
        print("FAIL %s --json: could not parse both documents: %s" % (label, error))
        return 1

    problems = []
    for path, actual in sorted(c.items()):
        # The C engine adds "engine": "c", which the Python has no counterpart
        # for; everything else it emits must exist there and match.
        if path == "engine":
            continue
        if path not in py:
            problems.append("%s: only the C engine emits it" % path)
            continue
        expected = py[path]
        if isinstance(actual, float) or isinstance(expected, float):
            try:
                a, b = float(actual), float(expected)
            except (TypeError, ValueError):
                problems.append("%s: python=%r c=%r" % (path, expected, actual))
                continue
            if a != b and not (math.isnan(a) and math.isnan(b)):
                problems.append("%s: python=%.17g c=%.17g" % (path, b, a))
        elif actual != expected:
            problems.append("%s: python=%r c=%r" % (path, expected, actual))

    if problems:
        print("FAIL %s --json: %d value(s) disagree" % (label, len(problems)))
        for problem in problems[:12]:
            print("   " + problem)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
