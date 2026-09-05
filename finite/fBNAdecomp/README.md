# fBNAdecomp

`fBNAdecomp` is a fast steady-state approximation for open, multi-class
finite-capacity queueing networks. It decomposes the network into independent
`M/M/c/K` birth-death stations and closes their offered-arrival and routed-flow
equations with a damped fixed-point iteration.

The implementation uses only the Python standard library. It is intended to
fill the gap between exact finite-state CTMC analysis and discrete-event
simulation when the complete product state space is too large.

## Quick start

From this directory:

```sh
python3 fbna_decomp.py examples/mm1k_loss.json --format text
python3 fbna_decomp.py examples/multiclass_feedback_loss.json > result.json
python3 -m unittest discover -s tests -v
```

Use `-` as the input or output filename for standard input/output. A converged
run exits with status 0, invalid input with 2, and a valid but unconverged run
with 3. JSON is the default output; `--format text` prints a compact report.

## Input schema

Capacity `K` is the maximum number at a station **including jobs in service**.
Thus an `M/M/1/5` queue has `servers: 1, capacity: 5` and states 0 through 5.

```json
{
  "schema_version": 1,
  "name": "Two-class example",
  "blocking": "loss",
  "stations": [
    {
      "id": "s1",
      "name": "Inspection",
      "servers": 2,
      "capacity": 8,
      "service_rates": {"regular": 1.2, "urgent": 1.5}
    },
    {
      "id": "s2",
      "name": "Repair",
      "servers": 1,
      "capacity": 5,
      "service_rate": 1.0
    }
  ],
  "classes": [
    {"id": "regular", "external_arrivals": {"s1": 0.7}},
    {"id": "urgent", "external_arrivals": {"s1": 0.2}}
  ],
  "routes": [
    {"class": "regular", "from": "s1", "to": "s2", "probability": 0.8},
    {"class": "urgent", "from": "s1", "to": "s2", "probability": 0.6}
  ],
  "solver": {
    "tolerance": 1e-10,
    "max_iterations": 1000,
    "damping": 0.5
  }
}
```

Each missing fraction of a routing row is the probability of leaving the
network. Routes are sparse list entries. `to_class` is optional and defaults to
`class`; supplying it models a class transition. Feedback routes are allowed.
Every externally reachable class/station routing state must have a path to an
exit.

`service_rate` applies to every class. Use `service_rates` when classes have
different exponential service rates at a station. External arrivals are
independent Poisson streams in the station approximation.

## Loss fixed point

Let `e[k,i]` be the external offered rate of class `k` to station `i`,
`a[k,i]` its total offered rate, `B[i]` the full probability returned by the
station's `M/M/c/K` model, and `x[k,i]` its admitted throughput. For loss
semantics the solver iterates

```text
x[k,i] = a[k,i] (1 - B[i])
a[k,i] = e[k,i] + sum_(l,h) x[l,h] p[(l,h) -> (k,i)].
```

An external or routed arrival finding its destination full is lost. An
upstream service completion still occurs when its routed customer is lost.
This is the complete loss semantics used for the flow accounting: output
separately reports external and internal loss, successful transfers, exits,
and class/network conservation residuals.

For station `i`, class-dependent service times are collapsed to their offered-
flow mean:

```text
1 / mu_eff[i] = sum_k (a[k,i] / sum_l a[l,i]) / mu[k,i].
```

The resulting aggregate rate drives an exact `M/M/c/K` birth-death submodel:

```text
pi[n] / pi[n-1] = lambda / (min(n,c) mu_eff),  1 <= n <= K.
```

Probabilities are normalized in log space. Station throughput is checked both
as `lambda (1-pi[K])` and `mu_eff E[min(N,c)]`; their absolute difference is
reported as the local birth-death balance residual.

Class mean numbers are apportioned consistently with Little's law. All classes
share the aggregate FCFS waiting time; class `k` then has approximate sojourn
time `Wq + 1/mu[k,i]`. This allocation sums back to the station's aggregate
mean number.

## BAS modes are explicitly approximate

Two optional modes are accepted:

- `bas_external_loss`: internal transfers wait at the upstream station, but
  an external arrival seeing its first station full is lost.
- `bas`: internal transfers and external sources both wait until space is
  available; there is no external loss.

Neither is an exact BAS solution. They use two independence closures:

1. A server whose completed job routes downstream is treated as available in
   proportion to `1 - sum_j p[i,j] B[j]`. The class service rate is multiplied
   by this downstream availability (a frozen-server/repetitive-service
   correction).
2. A held internal flow of rate `r` is represented at its destination by an
   equivalent enabled-arrival intensity `r / (1-B)`, so its admitted flow is
   `r` rather than a loss. Pure BAS applies the same correction to the external
   source; `bas_external_loss` does not.

These closures preserve steady-state flow by construction, but they ignore
the joint occupancy and blocking-duration correlations that drive exact BAS.
Treat BAS estimates cautiously when full probabilities are high, feedback is
strong, or downstream availability is small. The JSON output always sets
`bas_is_approximation: true` and emits a warning.

## Convergence

The raw fixed-point map is damped:

```text
state_next = (1-damping) state + damping target,  0 < damping <= 1.
```

The reported residual is the largest normalized offered-flow mismatch. BAS
also includes the largest mismatch between the full probabilities used in the
availability correction and those returned by the station submodels. Output
includes the initial residual, final residual, iteration count, solver
controls, and the final ten residuals.

`damping=0.5` is deliberately conservative for feedback networks. Acyclic
loss networks can usually use 1.0. Nonconvergence is returned as data rather
than hidden; the CLI also exits with status 3.

## Output

JSON output contains:

- method identity, modeling layer, blocking semantics, and convergence proof;
- network external admission/loss, internal loss, exit rate, total population,
  and conservation residual;
- per-class external/loss/exit and class-transition rates, population,
  class-residence time, and flow residual (whole-network time is omitted for
  classes that transition because it is no longer a per-class quantity);
- per-station `P(full)`, state probabilities, utilization, throughput,
  `E[N]`, `E[Q]`, wait/sojourn time, and local residuals;
- per-station/per-class offered and admitted rates, service-rate correction,
  population, delay, utilization contribution, loss and exit rates;
- every routed flow's completion, equivalent attempt, admission and loss rate;
- warnings for approximation-sensitive regimes.

All undefined delays are JSON `null`, never non-standard `NaN` or infinity.

## Assumptions and limitations

- The isolated station formula is exact for an `M/M/c/K` queue. The network
  decomposition is generally approximate because internal departures are
  treated as independent Poisson offered streams.
- FCFS classes share capacity and blocking. There are no priorities, class
  reservations, processor sharing, or class-specific buffer partitions.
- Class-dependent exponential service mixtures are represented by their mean
  through a harmonic effective rate; higher moments are not retained.
- Routing is state-independent. Batch arrivals, synchronized forks/joins, and
  simultaneous resource possession are outside the model.
- The loss calculation does not approximate a diffusion: it works directly
  with finite queue capacities, but it does not capture cross-station occupancy
  correlations.
- BAS corrections are heuristic and are not substitutes for the exact CTMC or
  finite-buffer discrete-event simulator when blocking dependencies matter.

The decomposition structure is in the tradition of generalized expansion and
decomposition methods for finite queueing networks. Its exact equations and
reported semantics are documented above so results remain auditable rather
than relying on a method name alone.
