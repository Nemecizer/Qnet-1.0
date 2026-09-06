"""Compare two refusal documents by code and message.

Not by bytes: the Python attaches a diagnostic `details` payload to some errors
(for a stability refusal, the entire traffic-and-stability dictionary) and the C
engine does not. What identifies a failure to a user, and to anything reading
the output, is the code and the sentence -- so those must be equal, and the rest
is allowed to differ.
"""

import json
import sys


def load(path, who):
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print("   %s output is not a JSON document: %s" % (who, error))
        return None


def main() -> int:
    py = load(sys.argv[1], "python")
    c = load(sys.argv[2], "c")
    label = sys.argv[3]
    if py is None or c is None:
        print("FAIL refusal '%s': could not parse both documents" % label)
        return 1
    problems = []
    if py.get("status") != "error" or c.get("status") != "error":
        problems.append("status: python=%r c=%r" % (py.get("status"), c.get("status")))
    for field in ("code", "message"):
        expected = py.get("error", {}).get(field)
        actual = c.get("error", {}).get(field)
        if expected != actual:
            problems.append("error.%s:\n     python=%r\n     c     =%r" % (field, expected, actual))
    if problems:
        print("FAIL refusal '%s': engines disagree" % label)
        for problem in problems:
            print("   " + problem)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
