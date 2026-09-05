# BAR steady-state moment bounds for orthant SRBMs

This directory provides a deliberately narrow, mathematically explicit
toolkit for steady-state moment bounds of a semimartingale reflected Brownian
motion (SRBM) in the nonnegative orthant. It is independent of the Qnet GUI and
uses only the Python standard library unless numerical SDP solution is
requested.

The default operation constructs and validates a finite conic relaxation. It
does **not** turn an approximate optimizer value into a claimed rigorous
bound. Two analytically exact cases return certified point bounds directly:

1. every stable one-dimensional SRBM; and
2. a multidimensional SRBM satisfying the Harrison-Williams skew-symmetry
   identity exactly for the reported decimal parameters.

## Model and reflection convention

The model is

```text
Z(t) = Z(0) + mu*t + B(t) + R*Y(t),        Z(t) in R_+^d,
```

where `B` has covariance matrix `Gamma`, regulator `Y_i` can increase only on
the face `Z_i=0`, and **column `i` of `R` is the reflection direction on that
face**. This agrees with Qnet's existing SRBM exporter: it sets
`R[j][k] = -P[k][j]` for reflection face `k`.

This release accepts only:

- a finite, exactly symmetric, strictly positive-definite `Gamma`;
- a nonsingular M-matrix `R` (positive diagonal, nonpositive off-diagonal,
  and an exactly nonnegative inverse for the reported decimals); and
- strict stability `delta = -R^{-1} mu > 0` componentwise.

The restriction is intentional. M-matrix inverse signs and the stability
vector are checked using exact rational arithmetic on the reported decimal
parameters, while a Cholesky margin protects numerical use of the covariance.
This gives a checkable sufficient structural class and a sharp drift test.
Arbitrary completely-S reflection matrices,
degenerate Brownian covariance, curved/polyhedral domains other than the
orthant, state-dependent coefficients, jumps, and finite-capacity upper-face
reflection are not represented.

The degree-one BAR gives the boundary-measure masses directly:

```text
R * (nu_1(1), ..., nu_d(1))' = -mu.
```

## Finite BAR moment relaxation

For a polynomial `f`, stationary interior probability measure `pi`, and
boundary measures `nu_i`, the Basic Adjoint Relationship is

```text
integral Lf d pi + sum_i integral (R[:,i]' grad f) d nu_i = 0,
Lf = mu' grad f + (1/2) Gamma : Hessian f.
```

At order `q`, the program creates:

- interior moments `y_alpha = integral x^alpha d pi` through degree `2q`,
  with `y_0=1`;
- boundary moments through degree `2q`, with their masses determined by the
  degree-one BAR `R*nu(1) = -mu`;
- exact boundary support identities by omitting `nu_i` moments having
  `alpha_i>0`;
- monomial BAR equalities for test degrees 1 through `2q+1`;
- nonnegativity of every represented monomial moment;
- the order-`q` moment matrix and order-`q-1` coordinate-localizing matrices
  for the interior measure; and
- the analogous Stieltjes moment/localizing matrices on every boundary face.

These are necessary conditions for measures supported on their respective
orthants. Therefore the feasible set is an **outer relaxation** of all true
stationary moment sequences: in exact conic arithmetic, minimizing a target
moment gives a valid lower bound and maximizing it gives a valid upper bound.
An upper problem can legitimately be unbounded. Because the support is
noncompact, no finite-order convergence or finite-upper-bound claim is made.
The interpretation also assumes the stationary moments used by the selected
BAR tests exist and justify the polynomial BAR; this is true for the usual
stable, nondegenerate M-matrix queueing SRBMs, but it remains a model
assumption rather than something inferred from a finite JSON file.

The complete relaxation is exported as versioned JSON. It contains scalar
moment variables, sparse linear equalities, nonnegative variables, PSD-block
entry maps, and both objective directions. This representation is intended to
be auditable and easy to translate to another conic system.

## Exact cases

For one dimension, the stationary distribution is exponential with

```text
rate = -2*mu/Gamma,     E[Z^k] = k! * (Gamma/(-2*mu))^k.
```

In multiple dimensions, define `D_ii = Gamma_ii/R_ii`. If

```text
2*Gamma = R*D + D*R',
```

the stationary coordinates are independent exponentials with

```text
E[Z_i] = Gamma_ii / (2*R_ii*delta_i),     delta = -R^{-1}mu.
```

The program reports the scaled skew-symmetry residual. It also rechecks
covariance definiteness, M-matrix signs/inverse, stability, and skew symmetry
using exact rational arithmetic on the reported decimal parameters. A merely
near-zero residual does not trigger the exact branch; the BAR relaxation is
used instead. Exact branches include rational strings for every point bound as
well as convenient floating-point evaluations.

## Run and export

From this directory:

```sh
python3 solver.py examples/one_dimensional.json --json
python3 solver.py examples/skew_product_form.json --json
python3 solver.py examples/general_two_station.json \
  --force-relaxation \
  --export-relaxation /tmp/qnet-bar-relaxation.json \
  --json
```

`--output RESULT.json` writes the versioned result. `--export-relaxation`
writes the full conic intermediate representation even for an exact case.
Inputs are governed by [`schema.json`](schema.json); the executable additionally
checks matrix dimensions and all mathematical sign/stability conditions.

## Optional CVXPY backend and certification policy

Use `--backend auto` to try CVXPY when installed, or `--backend cvxpy` to
require it. `--cvxpy-solver NAME` chooses a specific installed SDP-capable
solver. The adapter recognizes MOSEK, CVXOPT, CLARABEL, and SCS.
[`requirements-optional.txt`](requirements-optional.txt) records the optional
Python dependency; the choice and licensing of an SDP solver remain external.

After every solve, it independently recomputes scaled equality residuals,
nonnegative-moment violations, and the smallest eigenvalue of every moment
and localizing matrix. A candidate is exposed only with its solver status and
these checks. It is always labelled `certified: false`: ordinary
floating-point CVXPY output plus residual checks is not an interval or rational
certificate of the optimal value. Exact 1D and exactly skew-symmetric branches
are the only results labelled certified by this release.

No SDP package is bundled and the default `--backend none` performs no
numerical optimization. This makes construction and exact cases usable in a
standard-library Python installation while keeping the dependency boundary
honest.

## Limitations

- This bounds the stationary **SRBM approximation**, not the underlying
  discrete queue-length process.
- It does not derive `(mu, Gamma, R)` from a network model.
- It does not support finite buffers, blocking-after-service, upper-face
  reflection, non-M-matrix directions, or singular covariance.
- Truncation order can grow combinatorially; `max_variables` (default 100,000)
  and `max_psd_entries` (default 5,000,000) fail from closed-form size counts
  before an unexpectedly large construction is allocated.
- A finite-order outer SDP may be weak or unbounded, and numerical solver
  output is not a proof certificate.
- No hierarchy-convergence claim is made without additional tail/Carleman
  assumptions.

## Tests

```sh
make test
make check
```

The deterministic tests cover 1D exponential moments and reflection scaling,
a hand-solvable two-dimensional skew-symmetric product form, exact BAR
coefficients and boundary support, cone dimensions, versioned CLI/export I/O,
near-product-form nonclassification, model-size protection, and failures for
unstable drift, invalid covariance, invalid reflection signs, unknown fields,
and excessive target degree.
