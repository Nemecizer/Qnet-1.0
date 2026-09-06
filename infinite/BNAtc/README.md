# Adaptive truncated-CTMC solver

`truncated_ctmc.py` approximates steady-state performance for an open,
single-class Markovian queueing network by solving successively larger finite
CTMCs. It uses only the Python standard library and never materializes a dense
transition matrix.

The distinction between evidence and proof is part of the output contract:

- finite-truncation estimates, boundary mass, and successive-truncation
  agreement are labeled **heuristic**;
- the Jackson traffic stability test is labeled **certified** under the stated
  model assumptions;
- a conservative geometric Foster-Lyapunov certificate is reported only when
  its sufficient drift inequality holds;
- when that inequality does not hold, the solver explicitly refuses tail and
  moment claims. Failure of the sufficient certificate does not mean that the
  network is unstable.

## Supported model

The CTMC state is the vector of queue populations `x = (x1, ..., xd)`. Each
node has independent Poisson external arrivals, one or more identical
exponential servers, an infinite waiting room, and work-conserving FCFS
service. On completion at node `i`, a customer goes to node `j` with
probability `routing[i][j]`; the remaining probability is departure from the
network.

This is an open single-class M/M/c Jackson network. The traffic equations are

```text
throughput = external_arrival + throughput * routing.
```

The implementation requires `I - routing` to be nonsingular and requires the
strict stability inequalities

```text
throughput[i] < servers[i] * service_rate_per_server[i]
```

at every node. An unstable or numerically critical network is rejected before
state enumeration, so a finite reflected chain can never be mistaken for a
stationary version of an unstable infinite network.

For this exact Jackson subset, product-form methods are normally faster and
more accurate. Truncation is useful as an independent numerical reference and
as a foundation for future Markovian state descriptions that do not retain
product form.

## JSON input, schema version 1

```json
{
  "schema_version": 1,
  "process": "open_single_class_markovian_network",
  "name": "optional label",
  "nodes": [
    {
      "name": "queue_1",
      "external_arrival_rate": 2.0,
      "service_rate_per_server": 3.0,
      "servers": 1
    }
  ],
  "routing": [[0.0]],
  "solver": {
    "initial_total_cap": 8,
    "max_total_cap": 64,
    "growth_factor": 1.6,
    "minimum_cap_increment": 2,
    "max_states": 200000,
    "stationary_tolerance": 1e-13,
    "stationary_max_iterations": 200000,
    "boundary_mass_tolerance": 1e-8,
    "refinement_relative_tolerance": 1e-7,
    "stability_tolerance": 1e-12,
    "routing_tolerance": 1e-12,
    "tail_levels": [0, 1, 5, 10],
    "top_state_count": 20,
    "include_state_probabilities": false,
    "certificate_theta": 0.1
  }
}
```

All rates must be finite and nonnegative, service rates must be positive, and
server counts must be positive integers. Routing entries must be nonnegative
and every row sum must be at most one. `certificate_theta` is optional; when
omitted, the solver selects a conservative value halfway through the provable
interval.

Run the solver with a file or standard input:

```sh
python3 truncated_ctmc.py examples/mm1.json
python3 truncated_ctmc.py examples/tandem.json --compact
python3 truncated_ctmc.py examples/tandem.json --human
python3 truncated_ctmc.py - -o result.json
```

Both success and error documents contain `schema_version` and
`solver_version`. Invalid, unstable, state-limit, and convergence errors are
structured JSON and exit with status 2.

## Truncation and sparse stationary solve

At total-population cap `K`, the retained state space is

```text
{x in nonnegative integers^d : sum(x) <= K},
```

with `binomial(K + d, d)` states. Internal routes and departures remain
unchanged. External arrivals at `sum(x) = K` are suppressed. This makes a
finite chain, but is a modeling boundary rule—not a certified representation
of the omitted states.

The solver stores only off-diagonal transitions. It uses the global event-rate
bound

```text
gamma = total_external_arrival_rate
        + sum(servers[i] * service_rate_per_server[i])
```

to apply the uniformized transition operator directly to probability vectors.
A power iteration stops only after both its iterate change and an independent
stationarity residual satisfy the requested tolerance.

Caps grow adaptively until both of these heuristic checks pass on the same
refinement:

1. stationary probability on `sum(x) = K` is below
   `boundary_mass_tolerance`;
2. selected observables agree with the previous truncation within
   `refinement_relative_tolerance`.

The result remains usable when a cap or state limit is reached, but
`heuristic_converged` is then false and the reason is explicit. The refinement
history retains state counts, boundary masses, moments, iteration counts, and
successive changes.

## What is and is not certified

### Traffic stability

Under the supported Jackson assumptions, solving the traffic equations and
checking every M/M/c capacity inequality is an exact positive-recurrence test.
The output includes throughputs, utilizations, margins, and the traffic-equation
residual.

### Optional Foster-Lyapunov certificate

Let `N = sum(x)`, `A` be the total external arrival rate, and

```text
Dmin = min_i(service_rate_per_server[i] * direct_exit_probability[i]).
```

For `V(x) = exp(theta N)`, internal routing leaves `N` unchanged. Whenever
`N > 0`, at least one server is active, so the direct departure hazard is at
least `Dmin`. If

```text
A < Dmin
```

and `0 < theta < log(Dmin / A)`, the generator satisfies

```text
L V(x) <= -c V(x),  N > 0,
c = (exp(theta) - 1) * (Dmin * exp(-theta) - A) > 0.
```

At the empty state, `L V(0) = b = A * (exp(theta) - 1)`. Stationarity therefore
gives the conservative bound

```text
E[V(X); N > 0] <= b / c.
```

The solver derives certified upper bounds for `P(N >= n)`, the first and
second moments, and the true stationary probability/first moment/second moment
outside the selected cap. These concern the original untruncated CTMC.

This sufficient condition is intentionally strong. For example, the tandem
example has no direct departure from its first node, so `Dmin = 0`; its Jackson
stability is certified, but this particular Lyapunov certificate is correctly
reported as unavailable. No tail or moment bound is invented from truncated
boundary mass.

Even an available Foster certificate bounds omitted true mass and moments; it
does **not** by itself bound the bias of reflected-chain probabilities inside
the truncation. The output states this limitation next to the bounds.

## Output measures

The selected truncated chain reports:

- empty probability;
- mean queue length by node and total first/second moments;
- mean busy servers and completion/departure rates;
- requested total-population tail estimates;
- probability at the cap and cap minus one;
- suppressed-arrival rate and fraction under the truncated model;
- highest-probability states, with optional complete state probabilities;
- sparse operator size, uniformization rate, convergence, normalization, and
  stationarity residuals.

Queue and tail values in `approximation.performance` are estimates. Only
quantities inside a `certified: true` object carry a mathematical guarantee.

## Limitations

- No multiple classes, priorities, blocking, abandonment, batch events,
  non-exponential service, infinite-server nodes, or state-dependent routing.
- Only a total-population truncation and suppressed-arrival boundary rule are
  implemented.
- State count grows combinatorially. `max_states` is checked before enumeration
  at every refinement.
- Power iteration can be slow for nearly decomposable finite chains.
- Floating-point residuals diagnose numerical balance but do not constitute a
  theorem about truncation error.
- Full state probabilities can make output very large and are disabled by
  default.

## Verification

```sh
make check
```

Deterministic tests cover the exact reflected M/M/1 distribution, convergence
toward the infinite M/M/1 mean, certified stability and Foster bounds, explicit
certificate refusal for a tandem, sparse-operator probability conservation,
closed routing, state limits, deterministic output, CLI contracts, and
unstable-network rejection.

## Two engines

This method ships two implementations of one algorithm: `truncated_ctmc.py` (the
reference) and `bna_tc` (a C engine). `Settings > Solvers > Solver Engine`
chooses between them in the GUI; on the command line, run whichever binary you
want.

They are not two algorithms. The C engine was written to reproduce this
Python's arithmetic operation by operation, and `tests/test_engine_parity.sh`
runs both on every packaged example, on a sweep of model sizes, and on one
malformed document per validation rule, then compares the output. `make check`
runs it. A document that solves produces identical output byte for byte. A document that is refused produces the same exit status, the same error code and the same message -- but not the same bytes, because the Python attaches a diagnostic details payload that the C engine does not reproduce.

Measured on the machine this was developed on: a three-node tandem at cap 40 (12,341 states, 1,672 iterations), 9.09 s under Python and 0.43 s in C, a factor of 21.

If you change either engine, run `make parity` before you believe the change.
A failure there means the two have drifted, and the fix is to make them agree
again -- not to loosen the test.
