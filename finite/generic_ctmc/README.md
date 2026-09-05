# Generic finite-state CTMC solver

`generic_ctmc` computes steady-state measures for finite-capacity open
Markovian queueing networks. It is a queue-level reference method: it solves
the discrete continuous-time Markov chain rather than an SRBM approximation.

The solver supports:

- any finite directed station topology, including feedback;
- multiple customer classes and class changes on routing;
- independent Poisson external-arrival streams;
- exponential service rates specified by station and class;
- one or more identical servers at each station;
- FCFS queues, represented with their exact ordered class sequence;
- loss on full for both external arrivals and routed transfers;
- sparse reachable-state enumeration from the empty network;
- matrix-free uniformization and stationary power iteration; and
- network, station, and station/class steady-state measures.

## Scope

`blocking` must be `"loss"`. A service completion always releases its source
slot. If the selected downstream station is full, the completed customer is
discarded.

General Blocking After Service (BAS) needs extra state describing which
servers are blocked and which completed customer each holds. It is
intentionally not approximated here. Use the existing
`finite/fBNActmc/ctmc_tandem.py` for supported BAS tandems.

The state of a station is its ordered FCFS sequence of class IDs. The first
`min(servers, population)` entries receive exponential service concurrently.
This representation is what makes different class/station service rates exact
under FCFS. It also means the state space grows with both capacity and the
number of classes.

`capacity` is total in-system capacity, including customers in service. For a
Qnet station, convert with:

```text
capacity = bufferSize + numberOfServers
```

## Run

The solver has no third-party Python dependencies.

```sh
python3 finite/generic_ctmc/solver.py \
  finite/generic_ctmc/examples/mm1k.json
```

Structured JSON can be printed or written to a file:

```sh
python3 finite/generic_ctmc/solver.py MODEL.json --json
python3 finite/generic_ctmc/solver.py MODEL.json --output result.json
```

Add `--include-states` to include every reachable state and stationary
probability. That can make the result large. `--top-states 10` prints the ten
most probable states in the human-readable output.

The numerical safety controls may be set in the input or overridden on the
command line:

```text
--tolerance FLOAT
--max-iterations INTEGER
--max-states INTEGER
--uniformization-slack FLOAT
```

The process exits with status 0 after convergence, 2 for invalid input or a
state-limit error, and 3 if power iteration reaches its iteration limit.

## Input format

[`schema.json`](schema.json) is the complete JSON Schema. The main fields are:

```json
{
  "schema_version": 1,
  "name": "Example",
  "blocking": "loss",
  "service_discipline": "fcfs",
  "classes": ["A", "B"],
  "stations": [
    {
      "id": "s1",
      "servers": 2,
      "capacity": 5,
      "service_rates": {"A": 3.0, "B": 2.0}
    }
  ],
  "external_arrivals": [
    {"station": "s1", "class": "A", "rate": 1.0}
  ],
  "routing": [
    {
      "from_station": "s1",
      "from_class": "A",
      "destinations": [
        {"station": "s1", "class": "B", "probability": 0.25},
        {"exit": true, "probability": 0.75}
      ]
    }
  ]
}
```

Each `(from_station, from_class)` pair may have at most one routing rule.
Destination probabilities may total less than one; omitted probability is
treated as exit from the network. A destination `class` may be omitted to keep
the source class. A class needs a service rate at every station it can visit.
If a pair has no routing rule, its service completions exit with probability
one. Duplicate destinations within a rule are rejected.

Every station/class pair reachable from an external stream must have a
positive-probability path to an exit. This enforces the declared open-network
scope and ensures the reachable CTMC has a unique stationary distribution.

Duplicate external streams are allowed and their rates add. IDs are arbitrary
non-empty strings and must be unique within their category. Unknown JSON
fields are rejected so misspellings do not silently change a model.

See:

- [`examples/mm1k.json`](examples/mm1k.json) for an analytical M/M/1/K case;
- [`examples/multiclass_routed.json`](examples/multiclass_routed.json) for
  multiple servers, class switching, feedback, and internal loss.

## Method

The solver begins at the empty network and uses breadth-first search over every
positive-rate state change. For each reachable state it stores only aggregated
off-diagonal transitions `(destination_index, rate)`. Lost arrivals and other
events that do not change the observable state are excluded from the minimal
generator but retained as state rewards for performance measures.

For generator `Q`, choose

```text
nu = (1 + uniformization_slack) * max_i(-Q_ii)
P  = I + Q / nu.
```

The positive slack gives `P` a self-loop and avoids periodic power iteration.
The solver iterates the row vector `pi <- pi P`, beginning at the empty state,
until the L1 change is below `tolerance`. Neither `Q` nor `P` is materialized as
a dense matrix. The result reports both the final L1 step and the independent
generator residual `||pi Q||_1`.

## Measures

JSON results contain:

- solver diagnostics: reachable states, sparse transitions, iterations,
  uniformization rate, convergence, and `||pi Q||_1`;
- network totals: mean population, external offered/accepted/lost rates,
  internal routed/accepted/lost rates, exit rate, and flow residuals;
- station measures: mean population, mean in service/waiting, server
  utilization, empty/full probability, throughput, loss probabilities, and
  Little's-law mean waiting/sojourn times; and
- station/class versions of the population, flow, loss, throughput, waiting,
  and sojourn measures.

Station/class flow residuals compare accepted arrivals with service
completions. The network population residual compares accepted external flow
with exits plus internally lost transfers. They are useful independent checks
on the stationary result.

## Limits

This is exact for the stated stochastic model up to reachability truncation
(which is not performed silently) and numerical iteration tolerance. Its main
limit is combinatorial state growth. With `C` classes and station capacity
`K`, a station can have up to `1 + C + ... + C^K` ordered states before
reachability restrictions. The default `max_states=200000` stops enumeration
instead of exhausting memory; increasing it should be deliberate.

The method does not support non-exponential service, non-Poisson external
arrivals, priorities, preemption, processor sharing, batch events, or BAS.

## Tests

Run the deterministic standard-library test suite from the repository root:

```sh
python3 -m unittest discover -s finite/generic_ctmc/tests -v
```

The suite checks the full analytical M/M/1/K distribution and means, the
rho=1 special case, multiclass routed-network flow conservation, multiple
servers, internal loss, state-limit protection, and explicit BAS rejection.
