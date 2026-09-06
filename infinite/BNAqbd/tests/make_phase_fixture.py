"""An M/E_k/1 QBD with k interior phases, for the engine-parity sweep.

The point of the sweep is dimension. A 1x1 QBD exercises none of the matrix
kernel's indexing: a transposed loop, a row/column mix-up or an ordering
difference in the exact summation all give the right answer on a scalar. These
fixtures grow the interior dimension while keeping the model one whose answer
is known in closed form, so a failure is legible.

Erlang-k service at total rate mu, Poisson arrivals at lambda: the level is the
number in system, the phase is the service stage. Mean queue length is
rho + rho^2 (1 + 1/k) / (2 (1 - rho)), which for rho = 1/2 is 0.75 + 0.25/k.
"""

import json
import sys

ARRIVAL = 1.0
SERVICE = 2.0


def build(k):
    phase_rate = k * SERVICE
    same = [[0.0] * k for _ in range(k)]
    up = [[0.0] * k for _ in range(k)]
    down = [[0.0] * k for _ in range(k)]
    for i in range(k):
        up[i][i] = ARRIVAL                 # an arrival raises the level, phase unchanged
        if i + 1 < k:
            same[i][i + 1] = phase_rate    # advance to the next service stage
        else:
            down[i][0] = phase_rate        # the last stage completes: level down, restart
        same[i][i] = -(ARRIVAL + phase_rate)
    return {
        "schema_version": 1,
        "process": "continuous_time_qbd",
        "name": "M/E%d/1" % k,
        "boundary": {
            "level_0_same": [[-ARRIVAL]],
            "level_0_up": [[ARRIVAL] + [0.0] * (k - 1)],
            "level_1_down": [[phase_rate if i == k - 1 else 0.0] for i in range(k)],
            "level_1_same": [row[:] for row in same],
        },
        "interior": {"down": down, "same": same, "up": up},
        "solver": {"tail_levels": [0, 1, 5], "max_report_level": 5},
    }


def main() -> int:
    k = int(sys.argv[1])
    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        json.dump(build(k), handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
