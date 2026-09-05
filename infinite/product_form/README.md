# Exact product-form solvers

This directory provides four queue-level steady-state methods that are exact
for their stated stochastic models:

1. closed Gordon-Newell/BCMP networks, solved by normalized product-form
   occupancy-state enumeration;
2. open BCMP networks, solved from traffic equations and analytic local
   normalizers without state-space truncation;
3. a delimited mixed open/closed BCMP subclass, solved by analytically summing
   the open occupancies before enumerating the finite closed marginal; and
4. one complete-sharing multi-rate loss resource, solved by the
   Kaufman-Roberts recursion.

The implementation uses only the Python standard library. It does not call an
SRBM solver and does not introduce diffusion-approximation error.

## Closed BCMP scope

`model_type: "closed_bcmp"` supports one or more fixed-population customer
classes. Each class has class-preserving routing and its own visit ratios. The
following station types are accepted:

| JSON type | Exact condition |
|---|---|
| `fcfs` | One or more identical servers; exponential service; mean service time must be independent of class at that station. |
| `processor_sharing` | One processor-sharing server; class-dependent service-time distributions enter through their means. |
| `infinite_server` | Unlimited parallel service; class-dependent service-time distributions enter through their means. |
| `lcfs_preemptive_resume` | One LCFS preemptive-resume server; class-dependent service-time distributions enter through their means. |

The last three BCMP disciplines are insensitive to service-distribution shape
under their standard independence assumptions. The input therefore asks for
mean service times rather than asserting an unnecessary distribution family.
FCFS is different: the parser enforces the class-independent mean and the
method assumes exponential service.

Every class supplies exactly one of:

- an irreducible closed routing matrix, represented as routing rows; or
- positive relative `visit_ratios` for the stations it visits.

Routing rows must sum to one. The solver obtains their invariant visit vector
with a pivoted linear solve, so deterministic periodic routes are valid.
Classes do not switch identity, split, arrive externally, or leave. Those
would change the fixed population invariants used by the closed product form.

### Product form

Let `n_ir` be the number of class `r` customers at station `i`, `n_i` their
sum, `e_ir` the visit ratio, and `S_ir` the mean service time. Define service
demand `D_ir = e_ir S_ir`.

For processor-sharing and LCFS-PR stations, the local factor is

```text
n_i! * product_r(D_ir ^ n_ir / n_ir!).
```

For an infinite-server station, the `n_i!` factor is absent. For an FCFS
station with `c_i` identical servers, divide the processor-sharing factor by

```text
product_{k=1}^{n_i} min(k, c_i).
```

The normalized product of these station factors over all occupancy states
with the requested class populations is the exact stationary occupancy law.
The implementation evaluates factors and normalizing constants in log space.

For each class, reference-station throughput is computed from normalizing
constants:

```text
X_r(N) = G(N - unit_r) / G(N).
```

Visit ratios are scaled so the selected `reference_station` has ratio one.
Thus station/class throughput is `X_r * e_ir`, and Little's law gives the mean
residence time per visit. The output independently reconstructs completion
rates from the occupancy distribution and reports the largest flow residual.

### Enumeration limit

If class `r` has population `N_r` and visits `M_r` stations, its number of
allocations is

```text
choose(N_r + M_r - 1, M_r - 1).
```

The joint state count is the product across classes. `max_states` defaults to
200,000 and is checked before allocation; no truncation occurs silently.

This version deliberately uses exact state enumeration rather than an
approximate multiclass MVA closure. It returns the full stationary occupancy
law on request and also covers exact multi-server FCFS factors, for which the
elementary single-server MVA recurrence is insufficient.

## Open BCMP scope

`model_type: "open_bcmp"` supports independent Poisson external arrivals and
class-preserving Markov routing. Each class provides a positive
`external_arrival_rates` map and optional routing rows. A missing routing row
means departure after service. Within a routing row, either provide
`exit_probability` so destinations plus exit sum to one, or omit it and let
the unused probability be the exit probability.

For every class the solver forms the substochastic routing matrix `P` and
solves

```text
lambda = gamma + lambda P
```

with pivoted elimination. It checks that every externally reachable station
can reach an exit, rejects unreachable routing rows, and reports both the
largest traffic-equation residual and the external-arrival/departure flow
residual. Classes never switch identity; a destination names only a station,
not another class.

The four station disciplines in the closed solver are also available here
under the same BCMP service assumptions. If `a_ir = lambda_ir S_ir` and
`a_i = sum_r a_ir`, the exact stability conditions are:

| Station | Exact open stability condition |
|---|---|
| `fcfs` with `c_i` identical servers | `a_i / c_i < 1`; service is exponential and class independent. |
| `processor_sharing` | `a_i < 1`. |
| `lcfs_preemptive_resume` | `a_i < 1`. |
| `infinite_server` | Always stable for finite offered load. |

The FCFS result uses the exact Erlang-C normalizer, including multi-server
empty, delay, queue-length, busy-server, and utilization measures. PS and
LCFS-PR have geometric total occupancy with a multinomial class mix.
Infinite-server class populations are independent Poisson variables. The
product of these normalized local laws is the exact open-network stationary
law; the solver reports its moments analytically and never truncates the
countably infinite state space. Consequently `--include-states` and
`--top-states` are rejected for an open model rather than returning a partial
distribution. `solver.max_servers` (default 100,000) guards the linear-time
Erlang-C normalization loop.

## Exact mixed BCMP subclass

`model_type: "mixed_bcmp"` requires nonempty `open_classes` and
`closed_classes`. Open classes use the open input above. Closed classes use
the fixed populations, visit ratios, or irreducible routing accepted by
`closed_bcmp`.

The implemented exact subclass allows open and closed classes to share:

- processor-sharing stations;
- infinite-server stations; and
- LCFS preemptive-resume stations.

An FCFS station is also exact when it is visited exclusively by open classes
or exclusively by closed classes. A station shared by both population types
is rejected with a specific error. It is not sent through an approximate
closure. This is an implementation boundary, not a claim that no broader
mixed-network theorem exists.

For a shared PS or LCFS-PR station, let `m_i` be its closed population and
`rho_i` its total open offered load. Summing all open class occupancies from
the joint BCMP factor gives

```text
m_i! / (1 - rho_i)^(m_i + 1).
```

Thus one state-independent factor `1/(1-rho_i)` is analytic, while every
closed demand at that station is scaled by `1/(1-rho_i)` in the finite closed
marginal. Conditional on `m_i`, total open occupancy is negative binomial
with mean `(m_i + 1) rho_i/(1-rho_i)`, split among open classes by their
offered loads. At a shared infinite-server station, the open populations are
independent Poisson variables and factor completely from the closed state.

The solver enumerates only closed occupancy allocations, with the same
`solver.max_states` guard as `closed_bcmp`. It reports open traffic and
stability residuals, closed population residuals, both parts of the log
normalizer, and Little's-law residuals. `--include-states` returns a field
named `closed_marginal_distribution`; it never labels that finite marginal as
the full stationary distribution, whose open component is countably infinite.

## Kaufman-Roberts scope

`model_type: "kaufman_roberts"` represents a single complete-sharing resource
with integer capacity. Each independent Poisson traffic class requests an
integer number of capacity units. Calls finding insufficient free capacity
are lost; accepted calls hold all requested units for an independent holding
time.

Specify either:

- `offered_load` directly in Erlangs; or
- both `arrival_rate` and `mean_holding_time`, whose product is the offered
  load.

The recursion is insensitive to holding-time shape. It returns the complete
aggregate occupancy distribution, per-class blocking probabilities, carried
loads, mean calls and units in service, and arrival/loss rates when an arrival
rate was supplied. Its log-domain implementation remains stable under large
offered loads. Because the recursion stores `capacity + 1` values,
`solver.max_capacity` defaults to 1,000,000 and must be raised deliberately for
a larger resource.

This is the exact single-resource complete-sharing model. It is not a
reduced-load approximation for a network of multiple simultaneous resources.

## Run

From the repository root:

```sh
python3 infinite/product_form/solver.py \
  infinite/product_form/examples/closed_single_class.json

python3 infinite/product_form/solver.py \
  infinite/product_form/examples/open_multiclass_bcmp.json

python3 infinite/product_form/solver.py \
  infinite/product_form/examples/mixed_bcmp.json

python3 infinite/product_form/solver.py \
  infinite/product_form/examples/multirate_loss.json
```

Structured JSON output:

```sh
python3 infinite/product_form/solver.py MODEL.json --json
python3 infinite/product_form/solver.py MODEL.json --output result.json
```

For closed BCMP models, `--include-states` includes every state probability.
For mixed BCMP it includes the finite closed marginal only. `--top-states 10`
prints the corresponding ten most probable closed states. The options are
unavailable for open BCMP because its state space is infinite. The
Kaufman-Roberts result always includes its `capacity + 1` occupancy
probabilities.

The input contract is in [`schema.json`](schema.json). Examples are:

- [`examples/closed_single_class.json`](examples/closed_single_class.json):
  deterministic two-node routing with one FCFS and one delay station;
- [`examples/closed_multiclass_bcmp.json`](examples/closed_multiclass_bcmp.json):
  all four supported BCMP disciplines and multi-server FCFS; and
- [`examples/open_multiclass_bcmp.json`](examples/open_multiclass_bcmp.json):
  two class-preserving open chains through all four BCMP disciplines;
- [`examples/mixed_bcmp.json`](examples/mixed_bcmp.json): open and closed
  classes sharing PS and infinite-server stations while FCFS remains
  population-type exclusive; and
- [`examples/multirate_loss.json`](examples/multirate_loss.json): two request
  sizes sharing one loss resource.

Unknown fields, duplicate IDs, nonpositive values, invalid routing matrices,
non-irreducible class routes, missing service times, and FCFS violations are
rejected.

## Output

Every result has `schema_version`, `model_type`, `model`, `solver`, and
`measures` sections.

Closed BCMP results include:

- state count, log normalizing constant, probability mass, and population and
  throughput residuals;
- reference throughput and `N/X` per class; and
- station/class visits, demands, means, throughput, residence time, service
  occupancy, utilization, and empty/all-servers-busy probabilities.

Open BCMP results include:

- solved external, station, and departure rates with traffic and flow
  residuals;
- exact stability margins and local log normalizers;
- class and station means, residence times, throughput, utilization, and
  empty/all-servers-busy probabilities; and
- an explicit statement that the infinite state space was normalized
  analytically without truncation.

Mixed BCMP results include:

- the finite closed-marginal state count and optional distribution;
- analytic open normalizing factors and open conditional means;
- open traffic/stability plus closed population diagnostics; and
- separate open-class, closed-class, and combined station measures.

Kaufman-Roberts results include:

- the occupancy distribution and normalization diagnostics;
- resource mean occupancy, utilization, empty/full probabilities, and
  aggregate arrival/loss measures when available; and
- class blocking, carried load, mean calls, mean occupied units, and optional
  accepted/lost arrival rates.

## Tests

```sh
python3 -m unittest discover -s infinite/product_form/tests -v
```

The deterministic suite checks hand-derived Gordon-Newell and BCMP state
probabilities, open feedback traffic, PS class means, Erlang-C measures,
mixed negative-binomial and Poisson marginals, single-class MVA-equivalent
means, multi-class population and flow conservation, all four disciplines,
periodic and transient routing, two exact Kaufman-Roberts recursions,
log-domain scaling, CLI human and JSON output, state/iteration limits,
stability rejection, FCFS condition enforcement, and the explicit shared-FCFS
mixed boundary.
