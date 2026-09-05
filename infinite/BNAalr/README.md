# Adaptive low-rank BAR solver

`low_rank_bar.py` computes stationary moments of a semimartingale reflected
Brownian motion (SRBM) in the nonnegative orthant using an adaptive mixture of
separable exponential distributions. It is a complementary high-dimensional
method: its storage grows linearly with the selected rank and dimension rather
than as a full tensor grid.

The solver uses the Qnet convention

```text
Z(t) = Z(0) + X(t) + R L(t),
```

where the columns of `R` are the lower-face reflection directions, `X` has
drift `mu` and covariance `Sigma`, and `L_i` grows only when `Z_i = 0`.

## Method and evidence level

For a nonpositive transform argument `s`, the stationary Basic Adjoint
Relationship is

```text
(mu·s + 1/2 s' Sigma s) phi(s)
    + sum_i (s' R[:,i]) phi_i(s) = 0.
```

The interior transform `phi` is represented as a nonnegative mixture of
products of univariate exponential transforms. Each boundary transform
`phi_i` is a corresponding mixture with coordinate `i` omitted. The interior
weights sum to one, while boundary weights sum to
`delta = -inverse(R) mu`, as follows from the BAR applied to linear test
functions. With rates fixed, fitting these weights is a convex projected
least-squares problem. The solver expands the rank and stops only after both:

1. BAR residuals on a deterministic held-out collocation set meet the chosen
   tolerance; and
2. stationary means change by less than the moment tolerance on two
   consecutive refinements.

This residual is strong numerical evidence, but it is **not an error bound on
the moments**. The JSON result therefore says “approximation (not a certified
moment bound)” for a general model. It reports exactness only when the
Harrison--Williams skew-symmetry identity is verified in exact rational
arithmetic for the supplied decimal parameters and the rank-one
product-form transform satisfies the held-out BAR equations. Use the separate
`bar_bounds` solver for optimization bounds and compare difficult cases with
SRBM MLMC or the existing grid/spectral methods.

## Supported class

- One to sixteen dimensions.
- Constant drift and symmetric positive-semidefinite covariance with positive
  diagonal.
- A nonsingular reflection M-matrix: positive diagonal, nonpositive
  off-diagonals, and a numerically nonnegative inverse.
- Strict stability in this class: `-inverse(R) mu` is componentwise positive.

These restrictions cover the standard Harrison--Reiman reflection matrices
exported for open generalized Jackson networks. A general completely-S
reflection matrix is rejected rather than silently passed through an
insufficient stability test.

## Input and use

```json
{
  "schema_version": 1,
  "drift": [-1.0],
  "covariance": [[2.0]],
  "reflection": [[1.0]],
  "options": {
    "max_rank": 12,
    "training_points": 64,
    "validation_points": 32,
    "bar_tolerance": 0.00002,
    "moment_tolerance": 0.002,
    "log_rate_span": 1.6,
    "max_iterations": 6000
  }
}
```

```sh
python3 low_rank_bar.py examples/one_dimensional.json
python3 low_rank_bar.py examples/non_product_2d.json --json
python3 low_rank_bar.py model.json --json --output result.json
python3 low_rank_bar.py model.json --require-tolerance
make check
```

`--require-tolerance` returns status 3 if the rank cap is reached before both
refinement checks pass. Ordinary mode still returns the best approximation,
sets `converged` to false, and emits a warning.

## Diagnostics and limitations

The result includes training and held-out BAR residuals, the full rank history,
successive mean changes, simplex mass error, covariance eigenvalue bounds,
the skew-symmetry residual, both the numerical-candidate and exact-decimal
product-form flags, mixture rates/weights, and the boundary-measure masses.
The deterministic collocation design is reproducible and avoids a
random seed, but it is not an exhaustive transform-domain test. A finite
mixture can miss tail shapes or local boundary behavior even when its sampled
BAR residual is small. Near-critical models may need a broader rate span and
larger rank.

The model layer is the stationary **SRBM diffusion**, not the original discrete
queueing network. Agreement with another SRBM solver validates the numerical
solution of that diffusion; it does not validate heavy-traffic modeling error.

## Primary references

- J. G. Dai and J. M. Harrison, “Reflected Brownian Motion in an Orthant:
  Numerical Methods for Steady-State Analysis,” *Annals of Applied
  Probability* 2 (1992), 65–86. The paper develops the BAR numerical framework.
  https://people.orie.cornell.edu/jdai/publications/daiHarrison92.pdf
- J. M. Harrison and R. J. Williams, “Multidimensional Reflected Brownian
  Motions Having Exponential Stationary Distributions,” *Annals of
  Probability* 15 (1987), 115–137. https://doi.org/10.1214/aop/1176992259
- D. Saure, P. W. Glynn, and A. Zeevi, “A Linear Programming Algorithm for
  Computing the Stationary Distribution of Semimartingale Reflected Brownian
  Motion” (2008). https://www.dii.uchile.cl/~dsaure/papers/LP_SRBM.pdf
