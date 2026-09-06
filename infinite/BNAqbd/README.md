# Matrix-analytic QBD solver

`qbd_solver.py` computes the stationary matrix-geometric solution of a
level-independent, continuous-time quasi-birth-and-death (QBD) process. It is
self-contained and uses only the Python standard library.

The state space has a boundary level 0 and homogeneous levels 1, 2, ... . The
generator is supplied in blocks:

```text
       level 0     level 1     level 2       ...
0        B00          B01          0          ...
1        B10          B11          Aup        ...
2         0         Adown         Asame       Aup
3         0            0          Adown       Asame  ...
...
```

`B00` can have a different dimension from the repeating interior blocks. The
level-1-to-level-2 block is `Aup`; only the level-1 same-level and downward
blocks may differ from the repeating interior.

## Method

With row-vector probabilities, the rate matrix is the minimal nonnegative
solution of

```text
Aup + R Asame + R^2 Adown = 0.
```

The solver obtains `R` by monotone functional iteration after uniformization,
starting at the zero matrix. It then solves the two boundary balance equations
and normalizes the matrix-geometric series

```text
pi[n] = pi[1] R^(n-1),  n >= 1.
```

Before solving, it uses the standard mean-drift test. If `alpha` is the
stationary row vector of `Adown + Asame + Aup`, a stationary distribution is
accepted only when

```text
alpha Aup 1 < alpha Adown 1.
```

Critical and upward-drifting models return a structured error instead of an
invalid stationary answer.

## Input

Pass a JSON file, or `-` to read JSON from standard input:

```sh
python3 qbd_solver.py examples/mm1.json
python3 qbd_solver.py examples/erlang2.json --compact
python3 qbd_solver.py examples/mm1.json -o result.json
python3 qbd_solver.py examples/mm1.json --human
```

The schema is:

```json
{
  "schema_version": 1,
  "process": "continuous_time_qbd",
  "name": "optional label",
  "boundary": {
    "level_0_same": [[-2.0]],
    "level_0_up": [[2.0]],
    "level_1_down": [[3.0]],
    "level_1_same": [[-5.0]]
  },
  "interior": {
    "down": [[3.0]],
    "same": [[-5.0]],
    "up": [[2.0]]
  },
  "solver": {
    "absolute_tolerance": 1e-14,
    "relative_tolerance": 1e-12,
    "residual_tolerance": 1e-11,
    "generator_tolerance": 1e-11,
    "stability_tolerance": 1e-12,
    "max_iterations": 100000,
    "max_report_level": 10,
    "tail_levels": [0, 1, 5, 10]
  }
}
```

All blocks are dense arrays. Same-level blocks must have strictly negative
diagonals and nonnegative off-diagonals. Upward and downward blocks must be
nonnegative. Each generator block row must sum to zero when the applicable
blocks are combined. Tolerances and report controls are optional.

## Output

Successful output includes:

- the rate matrix `R`;
- `pi[0]`, `pi[1]`, total interior phase masses, and phase-resolved first
  level moments;
- mean, second moment, variance, and standard deviation of the level;
- requested exact tail probabilities `P(level >= k)`;
- point probabilities through `max_report_level`;
- the drift classification, iteration count, final iterate change, rate and
  per-level balance residuals, normalization and tail-identity residuals,
  Collatz bounds plus a strict certificate for the spectral radius of `R`, and
  the fundamental-matrix norm and an infinity-norm condition estimate for
  `I - R`.

Invalid, unstable, or nonconvergent inputs produce JSON with `"status":
"error"` and a stable error `code`; the command exits with status 2.

`--human` replaces JSON with a report followed by a line-oriented parser
contract, in that order.

The report is what a reader sees: a title, the model layer, the evidence class,
a one-line run summary, and three aligned tables — queue length and drift, tail
probabilities, and numerical diagnostics. Values are printed at a fixed fraction
length so that the GUI, which rewrites every number on screen to the configured
decimal places without padding, maps a column of uniform width to a column of
uniform width.

The records follow it. Scalar and tail results use `QNET_QBD_METRIC_V1`;
numerical/method diagnostics use `QNET_QBD_EVIDENCE_V1`. Text values are
percent-encoded, so every record stays on one line. Errors print the same way —
a prose line first, then `QNET_QBD_ERROR_V1` — and retain exit status 2.

The records are a contract for `ResultOutputParser` and the CSV export, which
read them out of the tee'd archive; the GUI's display filter withholds the whole
`QNET_QBD_*` class from the screen because the report above carries the same
numbers. Do not remove the records to tidy the output, and do not make the report
the only place a number appears. JSON remains the complete archival output.

## Supported scope and limitations

- Continuous-time, skip-free, level-independent QBDs only. This is not a
  general Markov-chain or M/G/1-type solver.
- The repeating interior phase generator and the collapsed boundary/interior
  phase graph must each be strongly connected. Reducible models need explicit
  closed-class selection and are rejected rather than guessed.
- Dense standard-library arithmetic is intended for small and moderate phase
  counts. Large or sparse blocks should use a sparse linear-algebra package.
- Functional iteration is deliberately simple and auditable, but convergence
  can be slow close to the stability boundary. A production large-scale tool
  may prefer cyclic/logarithmic reduction or invariant-subspace methods.
- Input rates and results use binary double precision. Residual diagnostics
  should always be checked for ill-conditioned or nearly critical models.
- The reported `level` is the QBD level. Mapping it to customer count or jobs
  in a domain model remains the caller's responsibility.

## Verification

```sh
make check
```

The deterministic tests include an M/M/1 model with a closed-form geometric
stationary distribution and an M/E2/1 phase model with a known mean queue
length. A separate exact two-phase fixture uses noncommuting blocks to catch
matrix-order or transpose errors. Invalid, critical, unstable,
convergence-limit, and command-line error cases are also covered.
