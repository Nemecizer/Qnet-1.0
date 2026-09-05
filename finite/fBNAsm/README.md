# SRBM Solver - C Implementation

High-performance C implementation of the SRBM (Semimartingale Reflected Brownian Motion)
algorithm from Dai & Harrison (1991).

## Features

- N-dimensional hypercube state space
- OpenMP parallelization for multi-core systems
- Apple Accelerate framework support (macOS)
- OpenBLAS/LAPACK support (Linux)
- Configurable via input files

## Building

### macOS (with Homebrew)

```bash
# Install dependencies
brew install libomp

# Build without OpenMP
make

# Build with OpenMP
make clean all OPENMP=1
```

### Linux

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get install build-essential libopenblas-dev liblapacke-dev

# Build without OpenMP
make

# Build with OpenMP
make clean all OPENMP=1
```

### Debug Build

```bash
make clean all DEBUG=1
```

## Usage

```bash
./srbm_solver <input_file> [-v]
```

Options:
- `-v` : Verbose mode (prints additional information to stderr)

Output (to stdout):
```
E[X_1] E[X_2] ... E[X_n]
```

## Input File Format

```
# Comment lines start with #
n_dim <int>              # Number of dimensions
n_approx <int>           # Polynomial approximation order
a_vec <d1> <d2> ...      # Hypercube dimensions
Gamma                    # Covariance matrix header
<row1>                   # n_dim x n_dim matrix rows
...
mu <d1> <d2> ...         # Drift vector

# Reflection matrix (explicit)
R                        # Matrix header
<row1>                   # n_dim x (2*n_dim) matrix rows
...

# OR use auto-generated reflection:
R_type normal|tandem     # Reflection type
```

### Reflection Matrix Convention

The reflection matrix R is n_dim x (2*n_dim), where columns are ordered as:
- Column 2k: reflection direction on face x_k = 0 (lower)
- Column 2k+1: reflection direction on face x_k = a_k (upper)

for k = 0, 1, ..., n_dim-1.

### Auto-Generated Reflection Types

- `normal`: Perpendicular reflection (+e_k on lower, -e_k on upper)
- `tandem`: Tandem queue model with blocking effects

## Examples

### 2D Test (Table 2 from paper)

```bash
./srbm_solver test_input_2d.txt -v
```

Expected output: `0.5513890428 0.4486109572`

### 3D Symmetric Test

```bash
./srbm_solver test_input_3d.txt -v
```

Expected output: `0.5000000000 0.5000000000 0.5000000000`

### 3-Station Tandem Queue

```bash
./srbm_solver test_input_tandem.txt -v
```

## Performance Notes

- The basis dimension grows as O(n^d) where n is the approximation order and d is the dimension
- For d > 3, use smaller approximation orders (n ≤ 3)
- OpenMP provides significant speedup for larger problems

Recommended settings:
| Dimension | Max n_approx | Basis size |
|-----------|--------------|------------|
| 2         | 8            | ~44        |
| 3         | 5            | ~55        |
| 4         | 3            | ~34        |
| 5         | 3            | ~55        |

## Files

```
c_solver/
├── srbm_types.h      # Data structures
├── srbm_solver.h     # Function prototypes
├── srbm_solver.c     # Main solver implementation
├── poly_ops.c        # Polynomial operations
├── input_parser.c    # Input file parser
├── main.c            # Main program
├── Makefile          # Build configuration
├── test_input_2d.txt # 2D test input
├── test_input_3d.txt # 3D test input
└── test_input_tandem.txt  # Tandem queue test
```

## Reference

J.G. Dai and J.M. Harrison, "Steady-State Analysis of RBM in a Rectangle:
Numerical Methods and a Queueing Application", *The Annals of Applied Probability*,
Vol. 1, No. 1, 1991, pp. 16-35.
