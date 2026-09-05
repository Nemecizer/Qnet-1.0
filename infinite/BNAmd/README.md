# Class-aware workload diffusion

This directory contains Qnet's richer multiclass diffusion path. It preserves
class-specific external arrivals, service-time moments, visit ratios, and
routing covariance while retaining one workload coordinate per station. The
resulting SRBM is solved by the included finite-element engine and then mapped
back to class-level delay and population summaries.

This is the maintained location of the former ignored `experiment/` solver.
Keeping it under `infinite/` makes the implementation part of the source tree,
allows the application bundle to include it, and prevents the GUI's
“Multi-Class SRBM” command from referring to an absent binary.

## What is richer than the station-aggregate export

- Per-class traffic equations are solved before aggregation.
- Service means are mixed as a compound service-time distribution. Thus the
  effective rate is the reciprocal of the throughput-weighted mean service
  time, not an arithmetic average of class rates.
- Second service moments retain both within-class variation and variation
  between class means.
- Multinomial routing covariance is accumulated class by class before the
  covariance matrix is aggregated.
- The output retains per-class visit ratios and service rates for mapping the
  workload solution back to per-class estimates.

The `--legacy-params` option remains available solely for controlled
comparisons with the older station-aggregate formulas.

## Model boundary

This is still a **workload SRBM approximation**, not a full station-by-class
state descriptor. It assumes state-space collapse is a reasonable
heavy-traffic model and uses class proportions for post-processing. It cannot
represent every scheduling discipline, priority interaction, re-entrant
instability, or class-dependent service order. The finite-element solve also
uses a finite upper truncation for an infinite orthant; increase the mesh/domain
and compare refinements before treating a result as settled.

The GUI labels the method experimental for these reasons. A comparison with a
queue-process simulation is the appropriate modeling check; agreement with a
different SRBM solver checks only the diffusion numerics.

## Build and verification

The complete solver requires cJSON, SuiteSparse, OpenMP, and Apple Accelerate:

```sh
make solver
./mc_solver --dump-params network.bnet
./mc_solver -G network.bnet
```

The parameter layer has a dependency-light deterministic test, so its traffic,
compound-service, routing, covariance, drift, reflection, and distribution
moment formulas can be checked even on a machine without those solver
libraries:

```sh
make check
```

Supported input is the Qnet `.bnet` document format, with at most eight
stations and eight classes. The application invokes the same binary directly,
so the network snapshot used for the run remains available in result
provenance.

## References

- J. G. Dai and V. Nguyen, “On the Convergence of Multiclass Queueing Networks
  in Heavy Traffic,” *Annals of Applied Probability* 4 (1994), 26–42.
- J. G. Dai and J. M. Harrison, “Reflected Brownian Motion in an Orthant:
  Numerical Methods for Steady-State Analysis,” *Annals of Applied
  Probability* 2 (1992), 65–86.
- M. I. Reiman, “Open Queueing Networks in Heavy Traffic,” *Mathematics of
  Operations Research* 9 (1984), 441–458.
