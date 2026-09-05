#!/usr/bin/env python3
"""
Comprehensive Test Script for BNA/FM Algorithm

This script tests the BNA/FM algorithm against numerical results from two papers:

1. Dai, J.G. and Harrison, J.M. (1991). "Steady-State Analysis of RBM in a Rectangle:
   Numerical Methods and a Queueing Application." Annals of Applied Probability.

2. Shen, Chen, Dai, Dai (2000). "The Finite Element Method for Computing the Stationary
   Distribution of an SRBM in a Hypercube with Applications to Finite Buffer Queueing Networks."

The script:
- Generates input files for each test case
- Runs the BNA/FM algorithm
- Parses the output
- Compares to expected results from the papers
"""

import os
import subprocess
import re
import sys
from dataclasses import dataclass
from typing import List, Tuple, Optional
import tempfile

# Configuration
BNA_FM_EXECUTABLE = "./bna_fm_gauss"
TOLERANCE_PERCENT = 5.0  # Default tolerance for comparison (percentage)

@dataclass
class TestCase:
    """Represents a single test case from the papers."""
    name: str
    paper: str
    dimension: int
    gamma: List[List[float]]  # Covariance matrix
    theta: List[float]        # Drift vector
    R: List[List[float]]      # Reflection matrix (K x 2K)
    lb: List[float]           # Lower bounds
    ub: List[float]           # Upper bounds
    mesh: List[int]           # Mesh sizes
    expected_q: List[float]   # Expected stationary mean
    tolerance: float = 5.0    # Tolerance percentage for this test
    description: str = ""


def generate_input_file(tc: TestCase, filepath: str):
    """Generate input file for BNA/FM algorithm."""
    K = tc.dimension

    with open(filepath, 'w') as f:
        # Dimension
        f.write(f"{K}\n\n")

        # Covariance matrix
        for i in range(K):
            row = " ".join(f"{tc.gamma[i][j]:.6f}" for j in range(K))
            f.write(row + "\n")
        f.write("\n")

        # Drift vector
        f.write(" ".join(f"{tc.theta[i]:.6f}" for i in range(K)) + "\n\n")

        # Reflection matrix (K x 2K)
        for i in range(K):
            row = " ".join(f"{int(tc.R[i][j])}" for j in range(2*K))
            f.write(row + "\n")
        f.write("\n")

        # Lower bounds
        f.write(" ".join(f"{tc.lb[i]:.6f}" for i in range(K)) + "\n")

        # Upper bounds
        f.write(" ".join(f"{tc.ub[i]:.6f}" for i in range(K)) + "\n")

        # Mesh sizes
        f.write("\t".join(str(tc.mesh[i]) for i in range(K)) + "\n")


def run_bna_fm(input_file: str) -> Tuple[Optional[List[float]], str]:
    """Run the BNA/FM algorithm and parse results."""
    try:
        result = subprocess.run(
            [BNA_FM_EXECUTABLE, input_file],
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )
        output = result.stdout + result.stderr

        # Parse stationary mean from output
        # Looking for lines like: "  q(1) = 0.499998"
        q_values = []
        for line in output.split('\n'):
            match = re.search(r'q\((\d+)\)\s*=\s*([\d.]+)', line)
            if match:
                idx = int(match.group(1))
                val = float(match.group(2))
                while len(q_values) < idx:
                    q_values.append(0.0)
                q_values[idx-1] = val

        if not q_values:
            return None, output

        return q_values, output
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"
    except Exception as e:
        return None, str(e)


def compare_results(expected: List[float], actual: List[float], tolerance: float) -> Tuple[bool, List[float]]:
    """Compare expected and actual results, return (passed, errors)."""
    if len(expected) != len(actual):
        return False, []

    errors = []
    all_passed = True

    for exp, act in zip(expected, actual):
        if abs(exp) > 1e-10:
            error_pct = abs(act - exp) / abs(exp) * 100
        else:
            error_pct = abs(act - exp) * 100
        errors.append(error_pct)
        if error_pct > tolerance:
            all_passed = False

    return all_passed, errors


def create_test_cases() -> List[TestCase]:
    """Create all test cases from both papers."""
    test_cases = []

    # ========================================================================
    # PAPER 1: Dai-Harrison (1991) - Table 2 - 2D SRBM comparison with SCPACK
    # ========================================================================
    # Data: theta = 0, Gamma = 2I, S = [0,a] x [0,1]
    # R = [1, 0, -1, 1; -1, 1, 0, -1]

    # SC (Schwarz-Christoffel) exact values from Table 2 (page 29)
    table2_data = [
        (0.5, 0.258585, 0.380018),
        (1.0, 0.551506, 0.448494),
        (1.5, 0.879534, 0.471624),
        (2.0, 1.239964, 0.482830),
        (2.5, 1.628342, 0.489146),
        (3.0, 2.040075, 0.492970),
        (3.5, 2.471022, 0.495381),
        (4.0, 2.917572, 0.496936),
    ]

    for a, sc_q1, sc_q2 in table2_data:
        tc = TestCase(
            name=f"DH91_Table2_a={a}",
            paper="Dai-Harrison (1991)",
            dimension=2,
            gamma=[[2.0, 0.0], [0.0, 2.0]],
            theta=[0.0, 0.0],
            R=[[1, 0, -1, 1], [-1, 1, 0, -1]],
            lb=[0.0, 0.0],
            ub=[a, 1.0],
            mesh=[9, 9],  # 9x9 mesh as in paper
            expected_q=[sc_q1, sc_q2],
            tolerance=3.0,  # 3% tolerance
            description=f"Table 2: 2D driftless SRBM, a={a}"
        )
        test_cases.append(tc)

    # ========================================================================
    # PAPER 2: Shen-Chen-Dai-Dai (2000) - Table 3 - 3D product form solution
    # ========================================================================
    # Data from equation (29) and surrounding text
    # theta = (1, -1, -0.5), Gamma = I, S = [0,1]^3
    # R = [1, -1, 0, -1, 1, 0; 1, 1, 0, -1, -1, 0; 0, 0, 1, 0, 0, -1]
    # Exact: q1 = 0.500000, q2 = 0.343482, q3 = 0.418023

    # Test with different mesh sizes as in Table 3
    mesh_sizes_3d = [4, 6, 8, 10]

    for mesh_n in mesh_sizes_3d:
        tc = TestCase(
            name=f"SCDD00_Table3_mesh={mesh_n}",
            paper="Shen-Chen-Dai-Dai (2000)",
            dimension=3,
            gamma=[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            theta=[1.0, -1.0, -0.5],
            R=[[1, -1, 0, -1, 1, 0],
               [1, 1, 0, -1, -1, 0],
               [0, 0, 1, 0, 0, -1]],
            lb=[0.0, 0.0, 0.0],
            ub=[1.0, 1.0, 1.0],
            mesh=[mesh_n, mesh_n, mesh_n],
            expected_q=[0.500000, 0.343482, 0.418023],
            tolerance=2.0 if mesh_n >= 6 else 5.0,  # Tighter tolerance for finer meshes
            description=f"Table 3: 3D product form SRBM, {mesh_n}x{mesh_n}x{mesh_n} mesh"
        )
        test_cases.append(tc)

    # ========================================================================
    # PAPER 2: Table 2 - 2D comparison with SC solution (same problem as DH91)
    # ========================================================================
    # BNA/FM results from Table 2 (page 21-22) for comparison
    # Using smaller subset to verify BNA/FM specifically

    table2_shen = [
        (0.5, 0.258548, 0.380244),
        (1.0, 0.551511, 0.448571),
        (1.5, 0.879476, 0.471676),
        (2.0, 1.239767, 0.482937),
    ]

    for a, fm_q1, fm_q2 in table2_shen:
        tc = TestCase(
            name=f"SCDD00_Table2_a={a}",
            paper="Shen-Chen-Dai-Dai (2000)",
            dimension=2,
            gamma=[[2.0, 0.0], [0.0, 2.0]],
            theta=[0.0, 0.0],
            R=[[1, 0, -1, 1], [-1, 1, 0, -1]],
            lb=[0.0, 0.0],
            ub=[a, 1.0],
            mesh=[8, 9],  # 8x9 mesh as stated in paper
            expected_q=[fm_q1, fm_q2],
            tolerance=2.0,
            description=f"Table 2: BNA/FM 2D driftless SRBM, a={a}"
        )
        test_cases.append(tc)

    # ========================================================================
    # PAPER 1: Table 1 - Queueing application (tandem queue)
    # ========================================================================
    # From Section 6 and Table 1 (page 18)
    # This is the main motivating example - finite queues in tandem
    # Using QNET estimates which match well with simulation

    # For lambda = 1.0: gamma = 0.9688, q1 = 13.75, q2 = 11.25
    # Note: The paper uses a = 25 (buffer size), b = 1, mu = (lambda-1, 0) drift
    # Gamma = gamma * I, R = [1, 0, -1, 1; -1, 1, 0, -1]

    # Scaled problem for lambda = 1.0 from Table 1
    # The state space is [0, 25] x [0, 25] for the 25x25 buffer system
    # But we need to scale down for tractability

    # Test the theoretical example: theta = 0, Gamma = I (simplified)
    # This tests the core algorithm without queueing-specific scaling

    # ========================================================================
    # Additional test: 1D SRBM (two-sided regulated Brownian motion)
    # ========================================================================
    # This is a simple 1D case with known analytical solution
    # For theta != 0, the stationary mean is known analytically

    # 1D case with drift theta = -1, Gamma = 2, S = [0, 1]
    # Analytical: p(x) = (2*theta/sigma^2) * exp(2*theta*x/sigma^2) / (exp(2*theta*b/sigma^2) - 1)
    # For theta = -1, Gamma = 2, b = 1:
    # p(x) = -1 * exp(-x) / (exp(-1) - 1) = exp(-x) / (1 - exp(-1))
    # E[X] = integral of x*p(x) = 1 - 1/(1-e^{-1}) ≈ 0.418

    tc = TestCase(
        name="1D_RegulatedBM",
        paper="Harrison (1985) - Analytical",
        dimension=1,
        gamma=[[2.0]],
        theta=[-1.0],
        R=[[1, -1]],  # Push up at 0, push down at 1
        lb=[0.0],
        ub=[1.0],
        mesh=[20],
        expected_q=[0.418],  # Approximate analytical value
        tolerance=5.0,
        description="1D two-sided regulated Brownian motion"
    )
    test_cases.append(tc)

    return test_cases


def run_all_tests():
    """Run all test cases and report results."""
    print("=" * 80)
    print("BNA/FM Algorithm Validation Test Suite")
    print("Testing against results from Dai-Harrison (1991) and Shen-Chen-Dai-Dai (2000)")
    print("=" * 80)
    print()

    # Check executable exists
    if not os.path.isfile(BNA_FM_EXECUTABLE):
        print(f"ERROR: Executable '{BNA_FM_EXECUTABLE}' not found!")
        print("Please compile the BNA/FM code first.")
        return 1

    test_cases = create_test_cases()

    results = {
        'passed': 0,
        'failed': 0,
        'error': 0,
        'details': []
    }

    print(f"Running {len(test_cases)} test cases...\n")

    for i, tc in enumerate(test_cases):
        print(f"[{i+1}/{len(test_cases)}] {tc.name}")
        print(f"    Paper: {tc.paper}")
        print(f"    {tc.description}")

        # Generate input file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.in', delete=False) as f:
            input_file = f.name

        try:
            generate_input_file(tc, input_file)

            # Run algorithm
            q_values, output = run_bna_fm(input_file)

            if q_values is None:
                print(f"    Status: ERROR - Could not parse results")
                print(f"    Output: {output[:500]}...")
                results['error'] += 1
                results['details'].append({
                    'test': tc.name,
                    'status': 'ERROR',
                    'error': output
                })
            else:
                passed, errors = compare_results(tc.expected_q, q_values, tc.tolerance)

                status = "PASSED" if passed else "FAILED"
                results['passed' if passed else 'failed'] += 1

                print(f"    Expected: {tc.expected_q}")
                print(f"    Computed: {[f'{v:.6f}' for v in q_values]}")
                print(f"    Errors:   {[f'{e:.2f}%' for e in errors]}")
                print(f"    Status:   {status} (tolerance: {tc.tolerance}%)")

                results['details'].append({
                    'test': tc.name,
                    'paper': tc.paper,
                    'status': status,
                    'expected': tc.expected_q,
                    'computed': q_values,
                    'errors': errors,
                    'tolerance': tc.tolerance
                })

        finally:
            # Cleanup
            if os.path.exists(input_file):
                os.remove(input_file)

        print()

    # Summary
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print(f"Total tests: {len(test_cases)}")
    print(f"Passed:      {results['passed']}")
    print(f"Failed:      {results['failed']}")
    print(f"Errors:      {results['error']}")
    print()

    if results['failed'] > 0 or results['error'] > 0:
        print("FAILED/ERROR TESTS:")
        for detail in results['details']:
            if detail['status'] in ['FAILED', 'ERROR']:
                print(f"  - {detail['test']}: {detail['status']}")
                if 'errors' in detail:
                    print(f"    Errors: {[f'{e:.2f}%' for e in detail['errors']]}")

    # Detailed results table
    print()
    print("=" * 80)
    print("DETAILED RESULTS BY PAPER")
    print("=" * 80)

    # Group by paper
    papers = set(d.get('paper', '') for d in results['details'] if 'paper' in d)

    for paper in sorted(papers):
        print(f"\n{paper}:")
        print("-" * 60)
        print(f"{'Test Name':<35} {'Status':<10} {'Max Error':<10}")
        print("-" * 60)

        for detail in results['details']:
            if detail.get('paper') == paper:
                name = detail['test'][:35]
                status = detail['status']
                max_err = max(detail.get('errors', [0])) if 'errors' in detail else 'N/A'
                if isinstance(max_err, float):
                    max_err = f"{max_err:.2f}%"
                print(f"{name:<35} {status:<10} {max_err:<10}")

    print()
    return 0 if results['failed'] == 0 and results['error'] == 0 else 1


if __name__ == "__main__":
    sys.exit(run_all_tests())
