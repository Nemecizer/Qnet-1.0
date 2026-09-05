# SRBM in Hypercube - MATLAB Implementation

Implementation of the algorithm from:

> J.G. Dai and J.M. Harrison, "Steady-State Analysis of RBM in a Rectangle:
> Numerical Methods and a Queueing Application", *The Annals of Applied Probability*,
> Vol. 1, No. 1, 1991, pp. 16-35.

## Overview

This package computes the stationary distribution of Semimartingale Reflected
Brownian Motion (SRBM) in a hypercube. The algorithm uses a least-squares /
Gram-Schmidt orthogonalization approach to solve the basic adjoint relationship.

## Files

### Main Solvers
- `srbm_2d_solver.m` - Original 2D implementation (rectangle state space)
- `srbm_nd_solver.m` - Generalized n-dimensional implementation (hypercube state space)

### Helper Functions
- `create_reflection_matrix.m` - Create reflection matrices for various models:
  - `'normal'` - Perpendicular reflection on all faces
  - `'tandem'` - Tandem queue model
  - `'jackson'` - Jackson network model

### Test Scripts
- `test_table2.m` - Reproduce Table 2 from the paper (zero-drift case)
- `test_table1_tandem_queue.m` - Reproduce Table 1 (tandem queue performance)
- `test_table3_iteration.m` - Reproduce Table 3 (iterative throughput calculation)
- `test_basic_validation.m` - Basic validation tests
- `test_nd_2d_validation.m` - Validate n-D solver against 2D results
- `test_nd_3d.m` - Test 3D cases
- `test_nd_arbitrary.m` - Test arbitrary dimensions (1D to 5D)
- `test_nd_tandem_queue.m` - Test n-dimensional tandem queues
- `run_all_tests.m` - Run all 2D validation tests
- `visualize_density.m` - Visualization of results

## Usage

### 2D Solver
```matlab
% Parameters
a = 1;  % Rectangle width (x1 in [0,a])
b = 1;  % Rectangle height (x2 in [0,b])
n = 6;  % Polynomial approximation order
Gamma = 2*eye(2);  % Covariance matrix
mu = [0; 0];  % Drift vector
R = [1, 0, -1, 1; -1, 1, 0, -1];  % Reflection matrix

% Solve
[q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);
```

### N-Dimensional Solver
```matlab
% Parameters
n_dim = 3;  % Number of dimensions
a_vec = [5; 5; 5];  % Hypercube dimensions
n_approx = 4;  % Polynomial order
Gamma = eye(n_dim);  % Covariance
mu = zeros(n_dim, 1);  % Drift
R = create_reflection_matrix(n_dim, 'tandem');  % Reflection matrix

% Solve
[q, delta, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);
% q(k) = E[X_k] for k = 1,...,n_dim
% delta(i) = boundary measure on face i
```

## Algorithm Summary

1. **State Space**: Hypercube S = [0,a₁] × [0,a₂] × ... × [0,aₙ]

2. **SRBM Definition**: Z(t) = X(t) + R·L(t) where:
   - X(t) is Brownian motion with drift μ and covariance Γ
   - L(t) is the local time vector keeping Z in S
   - R is the reflection matrix

3. **Basic Adjoint Relationship**: The stationary density p satisfies
   ∫_S (Af · p) dη = 0 for all test functions f

4. **Numerical Method**:
   - Generate polynomial basis {f_α = x^α : 1 ≤ |α| ≤ n}
   - Apply operator A to get basis for approximating subspace H_n
   - Use Gram-Schmidt to orthogonalize
   - Project φ₀ = (1 in interior, 0 on boundary) onto H_n
   - Residual gives approximate stationary density

## Computational Complexity

The basis dimension grows as:
- 2D: O(n²)
- 3D: O(n³)
- n-D: O(n^d / d!)

For higher dimensions, use smaller approximation orders (n ≤ 4 for 3D, n ≤ 3 for 4D).

## Results Summary

### Table 2 Reproduction (2D, zero drift)
| a | q₁ (QNET) | q₁ (SC) | q₂ (QNET) | q₂ (SC) |
|---|-----------|---------|-----------|---------|
| 1.0 | 0.5514 | 0.5515 | 0.4486 | 0.4485 |

### Validation (n-dimensional)
- 2D results match original solver exactly
- 3D symmetric case: Perfect symmetry (E[Xᵢ] = 0.5 for all i)
- 4D and 5D: Tested successfully with expected symmetry

## Notes

1. **Covariance for Zero-Drift Case**: Use Γ = 2I (not I) for the zero-drift
   case to match the paper's convention (Section 5).

2. **Reflection Matrix Convention**:
   - 2D solver: Columns ordered as [v_{x1=0}, v_{x2=0}, v_{x1=a}, v_{x2=b}]
   - N-D solver: Columns ordered as [v_{x1=0}, v_{x1=a₁}, v_{x2=0}, v_{x2=a₂}, ...]

3. **Numerical Precision**: Results match SCPACK within 1% for most quantities.

## References

1. Dai, J.G. and Harrison, J.M. (1991). Steady-state analysis of RBM in a rectangle.
2. Harrison, J.M. and Williams, R.J. (1987). Brownian models of open queueing networks.
3. Trefethen, L. and Williams, R.J. (1986). Conformal mapping solution of Laplace's equation.
