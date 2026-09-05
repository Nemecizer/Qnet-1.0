# Multi-Class Jackson Network Discrete Event Simulators

Two discrete event simulation tools for multi-class open Jackson queueing networks.

## Programs

| Program | Description |
|---------|-------------|
| `jackson_sim` | Infinite buffer simulation (classical Jackson network) |
| `jackson_sim_finite` | Finite buffer simulation with blocking and starvation |

## Quick Start

```bash
# Build both simulators
make

# Run infinite buffer simulation
./jackson_sim example_m2.sim

# Run finite buffer simulation
./jackson_sim_finite example_finite_tandem.sim

# Compare behaviors
make compare
```

## Finite Buffer Simulator Features

### Blocking Protocols

The finite buffer simulator supports three blocking protocols:

| Protocol | Description | Use Case |
|----------|-------------|----------|
| **BAS** | Blocking After Service | Manufacturing systems - server blocks after completing service if downstream buffer is full |
| **BBS** | Blocking Before Service | Communication systems - service cannot start if downstream buffer is full |
| **RS** | Rejection/Loss | Call centers - customers are lost when buffer is full |

### Additional Statistics

The finite buffer simulator tracks:
- **Rejection rate**: Customers lost due to full buffers
- **Blocking probability**: Fraction of time each server is blocked
- **Starvation time**: Time stations are idle due to upstream blocking

## Input File Format

Both simulators use the same basic input format:

```
# Network dimensions
stations 3
classes 3

# Simulation parameters
warmup 10000
run_length 100000
replications 30
seed 12345
mcn_output output_for_mcn.txt

# Finite buffer specific (jackson_sim_finite only)
blocking BAS                    # BAS, BBS, or RS
default_buffer 10               # Default buffer capacity
station_buffer 0 20             # Override for station 0
station_buffer 1 5              # Override for station 1

# Class definitions
class 0
    arrival exponential 1.0     # External arrival distribution
    station 0                   # Constituency station
    service erlang 2 2.0        # Service time distribution
    routing 0 0.5 0.5           # Routing probabilities
end_class
```

### Supported Distributions

| Distribution | Syntax | Parameters |
|--------------|--------|------------|
| Exponential | `exponential <rate>` | λ (rate) |
| Erlang | `erlang <k> <rate>` | k (stages), λ (rate) |
| Gamma | `gamma <shape> <scale>` | α (shape), β (scale) |
| Uniform | `uniform <min> <max>` | a (min), b (max) |
| Deterministic | `deterministic <value>` | constant value |
| Hyperexponential | `hyperexp2 <p> <λ1> <λ2>` | p (probability), λ1, λ2 |
| Lognormal | `lognormal <μ> <σ>` | μ (log-mean), σ (log-std) |
| Weibull | `weibull <shape> <scale>` | k (shape), λ (scale) |
| Pareto | `pareto <shape> <scale>` | α (shape), xm (scale) |
| None | `none` | No external arrivals |

## Command Line Options

```
Usage: ./jackson_sim[_finite] input_file [options]

Common Options:
  -w <time>      Warmup time
  -r <time>      Run length
  -n <count>     Number of replications
  -s <seed>      Random seed
  -m <file>      MCN format output file
  -v             Verbose mode
  -h             Help

Finite Buffer Only:
  -b <protocol>  Blocking protocol (BAS, BBS, RS)
  -c <capacity>  Default buffer capacity
```

## Output

### Console Output
- Per-class statistics: queue time, sojourn time, throughput, rejection rate
- Per-station statistics: queue time, utilization, blocking probability
- 95% confidence intervals

### Results File
`<input_basename>_results.txt` - Machine-readable detailed statistics

### MCN Format
Optional output file compatible with `mcn.c` for heavy-traffic analysis

## Examples

### Infinite Buffer Examples

| File | Description |
|------|-------------|
| `example_m2.sim` | 2-station tandem queue |
| `example_m4.sim` | 4-station network with multiple classes |
| `example_complex.sim` | Various distribution types |

### Finite Buffer Examples

| File | Description |
|------|-------------|
| `example_finite_tandem.sim` | 3-station tandem with BAS blocking |
| `example_finite_fork.sim` | Fork-join network with finite buffers |
| `example_rejection.sim` | Loss system with RS protocol |

## Theory Background

### Infinite Buffer Networks
Classical Jackson networks satisfy product-form equilibrium when:
- External arrivals are Poisson
- Service times are exponential
- Probabilistic (Markovian) routing

The simulator extends to general distributions using simulation.

### Finite Buffer Networks
With finite buffers, blocking and starvation occur:
- **Blocking**: Server cannot release customer due to downstream congestion
- **Starvation**: Server is idle because no customers can arrive from upstream

Blocking protocols determine how the system responds:
- **BAS**: Common in manufacturing (production blocking)
- **BBS**: Common in communication (communication blocking)
- **RS**: Common in call centers (loss systems)

## Performance Measures

| Measure | Description |
|---------|-------------|
| Mean Queue Time | Average waiting time in queue (excluding service) |
| Mean Sojourn Time | Average time at a station (queue + service) |
| Throughput | Rate of customers leaving the system |
| Utilization | Fraction of time server is busy |
| Rejection Rate | Rate of customers lost (finite buffers) |
| Blocking Probability | Fraction of time server is blocked |

## Files

```
SimNet/
├── jackson_sim.c           # Infinite buffer simulator
├── jackson_sim_finite.c    # Finite buffer simulator
├── Makefile                # Build configuration
├── README_SIMULATION.md    # This file
├── example_m2.sim          # 2-station infinite buffer example
├── example_m4.sim          # 4-station infinite buffer example
├── example_complex.sim     # Complex distributions example
├── example_finite_tandem.sim   # Finite buffer tandem
├── example_finite_fork.sim     # Finite buffer fork-join
├── example_rejection.sim       # Rejection/loss system
├── mcn.c                   # MCN heavy-traffic analyzer
├── m2, m4                  # MCN input files
└── mcn.h                   # MCN header (if present)
```

## Validation

The infinite buffer simulator has been validated against M/M/1 theory:
- Utilization: ρ = λ/μ
- Mean queue time: E[W] = ρ/(μ(1-ρ))

The finite buffer simulator has been tested for:
- Blocking cascade propagation
- Correct rejection counting
- Proper unblocking when space becomes available
