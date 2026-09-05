# Regenerative steady-state simulation

`regenerative_mc.py` is a self-contained, standard-library-only,
continuous-time discrete-event simulator for a deliberately narrow class of
open Markovian multiclass queueing networks. It estimates steady-state
quantities from complete empty-system regenerative cycles and reports
uncertainty at the cycle level.

The implementation does **not** treat events, queue-length observations, or
fixed time slices within a cycle as IID observations.

## Supported stochastic model

The supported network has:

- one or more customer classes with independent external Poisson arrival
  streams;
- class-preserving Markovian routing, with a positive eventual probability of
  leaving the network;
- one or more FCFS nodes, each with one or more identical servers;
- independent exponential service times; and
- one service rate per node, shared by every class at that node.

The class-independent service-rate restriction is intentional. It keeps each
infinite-buffer node in the standard multiclass Jackson/BCMP FCFS class and
makes the node load test meaningful. Class-dependent FCFS service rates,
priorities, blocking-before-service, simultaneous resource possession,
fork/join, non-exponential FCFS service, class switching, and closed customer
chains are not accepted.

All nodes must use the same buffer mode:

- **infinite buffers:** the traffic equations are solved for every class and
  each node must have strict offered load below one; or
- **finite buffers:** `capacity` is the total number in service plus waiting.
  An arrival finding its destination full is lost. A routed job finding its
  next node full is also lost; it does not block its source server.

Mixed finite and infinite buffers are rejected because the ordinary unblocked
traffic equations would then be only a conservative stability test, not a
complete characterization. For an all-finite model the traffic rates in the
output are explicitly labelled *unblocked/nominal*; actual carried rates are
simulation estimates.

For class `r`, with row routing matrix `P_r`, external rate row vector
`gamma_r`, and total offered rate row vector `lambda_r`, the parser solves

```text
lambda_r = gamma_r + lambda_r P_r.
```

Every routing node must have a positive-probability path to exit. For an
infinite-buffer network, node `i` must satisfy

```text
sum_r lambda_ri / (servers_i * service_rate_i) < 1.
```

## Regeneration and the delayed first cycle

A regeneration epoch is an entrance into the empty-system state immediately
after an atomic service-completion/routing event. A cycle contains the idle
time from that empty state to the next arrival and the complete busy period up
to the next empty return. The Poisson and exponential memoryless assumptions
make successive complete cycles IID.

If `initial_jobs` is empty, time zero is already a regeneration epoch. If the
initial state is nonempty, the simulator treats the path to the first empty
return as a **delayed first cycle**, discards all of its rewards, and starts
estimation only at that return. It reports the discarded delayed time. It
never truncates a long cycle and then treats the fragment as a valid cycle.

## Regenerative ratio estimates

For complete cycles `i = 1, ..., n`, let `Y_i` be a reward and `D_i` its
denominator. Examples are queue-length area divided by cycle duration, an
event count divided by duration, and blocked arrivals divided by offered
arrivals. The estimator is

```text
theta_hat = sum_i Y_i / sum_i D_i.
```

With `Z_i = Y_i - theta_hat D_i`, its regenerative delta-method standard
error is

```text
SE(theta_hat)
  = sqrt(sample_variance(Z_i) / n) / mean(D_i).
```

The implementation retains stable sufficient statistics for this expression;
it does not retain every cycle. The reported Student-t interval is an
**asymptotic regenerative ratio interval**. It is not advertised as an exact
finite-sample interval, because cycle reward/length pairs are not normally
distributed in general.

Each metric also reports a denominator-contribution diagnostic

```text
effective_cycles = (sum_i D_i)^2 / sum_i D_i^2.
```

Under importance sampling, `D_i` includes the likelihood weight. This Kish
quantity reveals domination by a few cycles, but it is a diagnostic, not a
replacement degrees of freedom and not proof of convergence.

## Sequential fixed-width stopping

Precision is checked only at complete regeneration epochs, after
`minimum_cycles`, and then every `check_every_cycles`. Every monitored metric
must satisfy

```text
half_width <= max(absolute_half_width,
                  relative_half_width * abs(estimate)).
```

It must also meet `minimum_effective_cycles`, have positive estimated cycle
variance, and, for an event probability, have at least
`minimum_positive_cycles` cycles with a positive numerator. This prevents a
run with no observed blocking from declaring a zero-width rare-event result.

Repeated looks use summable alpha spending. At scheduled look `l`, for `m`
monitored metrics and overall alpha `a`, each two-sided t interval gets

```text
a_l = a / (m * l * (l + 1)).
```

Since `sum_l 1/(l(l+1)) = 1`, the union-bound budget across all planned looks
and metrics is at most `a`. This addresses repeated inspection at the
asymptotic-interval level. It does not turn the regenerative t approximation
into an exact finite-sample confidence sequence; the JSON output marks that
limitation explicitly. The ordinary nominal interval is also reported for
descriptive use, while the stopping decision and human display use the wider
sequential interval.

## Safeguards

The run stops or fails explicitly at configured limits:

- `maximum_cycles`;
- `maximum_events`;
- `maximum_simulated_time`;
- `maximum_wall_seconds`;
- `maximum_cycle_time`; and
- `maximum_events_per_cycle`.

A total-run limit returns estimates from complete cycles and reports that the
precision target was not achieved. A per-cycle limit raises a structured
`cycle_safeguard_exceeded` error. The offending cycle is not truncated,
discarded as though missing at random, or included in the estimator, because
doing any of those would bias the regenerative sample.

## Reproducible random streams

Input supplies unsigned 64-bit `base_seed` and `stream` values. SplitMix64 is
used to derive separate time and event-choice seeds, each of which initializes
its own Python `random.Random` generator. Exponential variates are generated
directly as `-log1p(-U)/rate`. The effective seeds are returned in JSON.

The same model, Python implementation, base seed, and stream reproduce the
same result provided the wall-clock safeguard does not intervene. A different
stream provides a deterministic replication stream; the stream construction
is a practical separation mechanism, not a formal proof that arbitrary finite
pseudorandom streams are statistically independent.

## Optional M/M/1/K importance sampling

Rare-event handling is off by default. The implemented method is intentionally
limited to exactly one class, one finite-capacity single-server node, no
feedback routing, and positive external arrival rate: an M/M/1/K loss queue.
Other models are rejected rather than given an invalid likelihood ratio.

Set:

```json
"rare_event": {
  "method": "importance_sampling_mm1k",
  "arrival_rate_multiplier": 1.35,
  "service_rate_multiplier": 0.85
}
```

If the target rates are `lambda, mu` and proposal rates are
`lambda_star, mu_star`, the simulator changes both event hazards under the
proposal. For every holding interval of length `dt` in state `n`, it adds

```text
(q_star(n) - q(n)) * dt
```

to the log likelihood ratio. At an arrival event it adds
`log(lambda/lambda_star)` and at a service event it adds
`log(mu/mu_star)`. Here

```text
q(n) = lambda + mu * indicator(n > 0),
```

with the analogous proposal expression. Arrival attempts at a full buffer
remain explicit self-events and receive the arrival likelihood factor. This
is necessary: dropping full-buffer arrivals from the event history would give
the wrong likelihood and the wrong blocking estimator.

For a complete path/cycle likelihood `L_i`, target-measure ratios are estimated
as

```text
sum_i L_i Y_i / sum_i L_i D_i.
```

Their variance uses the IID proposal-cycle observations
`L_i(Y_i - theta_hat D_i)`. Log weights are accumulated and all sufficient
statistics are dynamically rescaled by a common factor, so a large path
likelihood need not be exponentiated directly.

The output reports log-weight range, likelihood-weight effective cycles,
largest normalized weight, squared coefficient of variation, and the log
sample mean likelihood ratio. Poor effective sample size or a log mean far
from zero is a warning that the proposal is unsuitable. These diagnostics do
not guarantee a finite second moment; aggressive tilts can make a
regenerative likelihood-ratio estimator worse than crude simulation.

No splitting implementation is claimed.

## Input example

```json
{
  "schema_version": 1,
  "process": "open_markovian_queueing_network",
  "name": "M/M/1 example",
  "nodes": [
    {
      "id": "server",
      "servers": 1,
      "service_rate": 2.0,
      "capacity": null
    }
  ],
  "classes": [
    {
      "id": "jobs",
      "external_arrival_rates": {"server": 1.0},
      "routing": {"server": {}}
    }
  ],
  "initial_jobs": {},
  "random": {"base_seed": 7319921, "stream": 0},
  "stopping": {
    "confidence": 0.95,
    "absolute_half_width": 0.1,
    "relative_half_width": 0.08,
    "monitored_metrics": ["mean_number_in_system"],
    "minimum_cycles": 500,
    "minimum_effective_cycles": 30,
    "minimum_positive_cycles": 5,
    "check_every_cycles": 250,
    "maximum_cycles": 20000,
    "maximum_events": 2000000,
    "maximum_simulated_time": 10000000.0,
    "maximum_cycle_time": 1000000.0,
    "maximum_events_per_cycle": 100000,
    "maximum_wall_seconds": 30.0
  }
}
```

Routing is an object keyed by source node, then destination node. Missing
probability is exit probability. An empty routing row therefore means certain
exit after service. Unknown fields and identifiers are rejected.

The included examples are:

- `examples/mm1.json`: an infinite-buffer M/M/1 reference;
- `examples/multiclass_network.json`: a two-class, two-node network initialized
  nonempty to exercise the delayed first cycle; and
- `examples/mm1k_importance.json`: likelihood-ratio importance sampling for
  M/M/1/8 blocking.

## Metrics and output

The flat `estimates` object contains cycle-ratio estimates and diagnostics for:

- mean jobs in the network, at each node, by class, and by node/class;
- mean waiting jobs and server utilization at each node;
- external offered, accepted, and blocked rates;
- external blocking probabilities overall and by class;
- internal routed-arrival blocking probability;
- node service-completion rates; and
- normal-exit and routed-loss rates; and
- total accepted-job departure rates overall and by class (normal exits plus
  routed losses).

An unavailable ratio, such as routed blocking when there were no routing
attempts, is returned explicitly with `available: false`.

For a one-node, one-class M/M/1 or M/M/1/K model with no feedback, output also
includes the exact stationary benchmark and standardized simulation error.
For M/M/1, `rho=lambda/mu`, `E[N]=rho/(1-rho)`. For M/M/1/K,

```text
P(block) = P(N=K)
         = (1-rho) rho^K / (1-rho^(K+1)),  rho != 1,
```

with `P(block)=1/(K+1)` at `rho=1`. PASTA makes this full-state probability
the external blocking probability. The implementation evaluates the
`rho > 1` case through inverse powers to avoid overflow.

## Run

From this directory:

```sh
python3 regenerative_mc.py examples/mm1.json
python3 regenerative_mc.py examples/mm1.json --json
python3 regenerative_mc.py examples/mm1.json --compact
python3 regenerative_mc.py examples/mm1.json --output result.json
cat examples/mm1.json | python3 regenerative_mc.py - --compact
```

The default is concise human-readable output. `--json`, `--compact`, and
`--output` produce structured JSON. Model/validation failures exit with code
2 and are structured when a JSON mode is selected.

### Stable per-node records in human output

The original concise human summary is followed by one versioned,
parser-facing line for every available aggregate node metric and node/class
mean. The exact field order is:

```text
QNET_NODE_METRIC_V1 node_id=<ID> metric=<METRIC> class_id=<CLASS> estimate=<VALUE> standard_error=<VALUE> ci_confidence=<VALUE> ci_low=<VALUE> ci_high=<VALUE> ci_half_width=<VALUE> effective_cycles=<VALUE>
```

The grammar is:

```text
ID, CLASS := UTF-8 identifier encoded by urllib.parse.quote(..., safe="")
CLASS     := "-" for an aggregate node metric, otherwise an encoded class ID
METRIC    := "mean_number"
           | "mean_queue"
           | "utilization"
           | "service_completion_rate"
           | "mean_number_class"
VALUE     := a finite base-10 float token parseable by Python float(), or "NA"
```

Fields are separated by one ASCII space and contain no unescaped whitespace.
Numeric values use 17 significant digits. `standard_error` and CI fields are
`NA` when too few complete cycles exist; only metrics whose ratio denominator
is available get a record. The CI fields are the ordinary nominal
regenerative-t interval from structured output. `ci_low`/`ci_high` respect a
metric's physical bounds, while `ci_half_width` is the untrimmed t half-width.
The wider alpha-spending interval used for an actively monitored stopping
metric remains in the preceding human summary and the JSON `precision`
section.

Record order is model node order, then `mean_number`, `mean_queue`,
`utilization`, `service_completion_rate`, followed by `mean_number_class` in
model class order. Consumers should select records by the
`QNET_NODE_METRIC_V1` prefix and ignore unrelated prose lines.

## Verification

```sh
make check
```

The deterministic tests cover Student-t quantiles, seed/stream reproduction,
M/M/1 mean and utilization, M/M/1/K blocking, a multiclass delayed first
cycle, sequential alpha spending, total and per-cycle safeguards, unstable and
closed-routing rejection, JSON and human CLI output, and importance sampling.
The unit-tilt test proves that likelihood weighting reduces exactly to the
same crude sample path. A nontrivial tilt is checked against the closed-form
M/M/1/K probability and must report usable weight effective sample size.

## Limitations

- Confidence intervals are regenerative-CLT approximations. Heavy-tailed busy
  cycles and near-critical infinite queues may need far more cycles than the
  defaults and may invalidate a finite-variance approximation.
- A single run, even with sequential alpha spending, is not a substitute for
  independent replication and proposal-sensitivity analysis.
- Empty-state regeneration can be inefficient in large or highly utilized
  networks. The simulator deliberately does not invent partial regeneration,
  batch means, or approximate independence.
- Finite-buffer routing is loss-on-arrival. Manufacturing blocking, upstream
  holding, retrials, and reservation policies require different state and
  event semantics.
- Importance sampling is only the documented M/M/1/K change of measure. It is
  not silently generalized to network paths.
- Dense queues and Python event processing target verification and moderate
  experiments, not high-throughput production simulation.

## References

- Søren Asmussen and Peter W. Glynn, *Stochastic Simulation: Algorithms and
  Analysis*, Springer, 2007. Regenerative steady-state estimation and
  likelihood-ratio change of measure.
- M. A. Crane and D. L. Iglehart, “Simulating Stable Stochastic Systems, III:
  Regenerative Processes and Discrete-Event Simulations,” *Operations
  Research* 23(1), 1975, pp. 33–45.
- Sheldon M. Ross, *Introduction to Probability Models*, Academic Press.
  Jackson networks, birth-death queues, and the M/M/1/K stationary law.
- Reuven Y. Rubinstein and Dirk P. Kroese, *Simulation and the Monte Carlo
  Method*, Wiley. Importance sampling and likelihood-ratio estimators.
