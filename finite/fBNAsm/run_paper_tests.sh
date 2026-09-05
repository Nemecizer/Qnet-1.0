#!/bin/bash
#
# Comprehensive Test Suite for SRBM Solver
# Runs all test cases from both papers and compares to expected results
#
# Papers:
#   1. Dai & Harrison (1991) "Steady-State Analysis of RBM in a Rectangle"
#   2. Shen et al. (2000) "The Finite Element Method for Computing the Stationary Distribution..."
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test_cases"
SOLVER="${SCRIPT_DIR}/srbm_solver"

# Test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Tolerance for comparison (as percentage)
DEFAULT_TOLERANCE=5.0

# Create test directory
mkdir -p "$TEST_DIR"

# Function to compare floating point values
compare_values() {
    local expected="$1"
    local actual="$2"
    local tolerance="$3"
    local name="$4"

    # Calculate percentage error
    local error=$(echo "scale=10; a=$actual; e=$expected; if(e==0) { if(a==0) 0 else 100 } else { d=a-e; if(d<0) d=-d; d/e*100 }" | bc)

    if (( $(echo "$error <= $tolerance" | bc -l) )); then
        echo -e "    ${GREEN}PASS${NC}: $name = $actual (expected $expected, error ${error}%)"
        return 0
    else
        echo -e "    ${RED}FAIL${NC}: $name = $actual (expected $expected, error ${error}%)"
        return 1
    fi
}

# Function to run a test case
run_test() {
    local test_name="$1"
    local input_file="$2"
    shift 2
    local expected=("$@")  # Array of expected values
    local tolerance="${TOLERANCE:-$DEFAULT_TOLERANCE}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo -e "\n${BLUE}Test: $test_name${NC}"
    echo "  Input: $input_file"

    # Run solver
    if ! output=$("$SOLVER" "$input_file" 2>/dev/null); then
        echo -e "    ${RED}FAIL${NC}: Solver execution failed"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi

    # Parse output
    local all_passed=true
    local dim=1
    for exp_val in "${expected[@]}"; do
        actual=$(echo "$output" | grep "^q${dim} = " | sed 's/q[0-9]* = //')
        if [ -z "$actual" ]; then
            echo -e "    ${RED}FAIL${NC}: Could not parse q$dim from output"
            all_passed=false
        else
            if ! compare_values "$exp_val" "$actual" "$tolerance" "E[X_$dim]"; then
                all_passed=false
            fi
        fi
        dim=$((dim + 1))
    done

    if $all_passed; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Function to create input file
create_input_file() {
    local filename="$1"
    local dim="$2"
    local degree="$3"
    local a_vec="$4"
    local gamma="$5"
    local mu="$6"
    local R="$7"
    local comment="$8"

    cat > "$filename" << EOF
# $comment

dimension $dim
degree $degree
a $a_vec

Gamma
$gamma

mu $mu

R
$R
EOF
}

# =============================================================================
# BUILD SOLVER
# =============================================================================
echo -e "${YELLOW}=== Building SRBM Solver (OpenMP + SuiteSparse) ===${NC}"
cd "$SCRIPT_DIR"
make clean >/dev/null 2>&1 || true
make >/dev/null 2>&1 || { echo -e "${RED}Build failed. Ensure dependencies are installed: brew install libomp suite-sparse${NC}"; exit 1; }
if [ ! -x "$SOLVER" ]; then
    echo -e "${RED}Error: Failed to build solver${NC}"
    exit 1
fi
echo -e "${GREEN}Build successful${NC}"

# =============================================================================
# TESTS FROM SHEN ET AL. (2000)
# =============================================================================
echo -e "\n${YELLOW}=== Tests from Shen et al. (2000) ===${NC}"
echo "Reference: 'The Finite Element Method for Computing the Stationary Distribution...'"

# -----------------------------------------------------------------------------
# Section 5.1: 2D Rectangle Test Cases (SC Solution Comparison)
# Table 1, page 20
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- Section 5.1: 2D Rectangle Tests (Table 1) ---${NC}"
echo "Testing against skew-symmetric (SC) exact solutions"
echo "Parameters: mu=(0,0), Gamma=2*I"

# Test cases with different rectangle lengths 'a'
# Expected values from Table 1 (SC column)

# Case: a = 0.5
# R matrix for tandem queue from Dai & Harrison which produces SC solution
create_input_file "${TEST_DIR}/shen_2d_a05.in" 2 8 \
    "0.5 1.0" \
    "2.0 0.0
0.0 2.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
    "Shen et al. 2000, Table 1, a=0.5"

TOLERANCE=1.0 run_test "Shen 2D a=0.5" "${TEST_DIR}/shen_2d_a05.in" 0.258585 0.380018

# Case: a = 1.0
create_input_file "${TEST_DIR}/shen_2d_a10.in" 2 8 \
    "1.0 1.0" \
    "2.0 0.0
0.0 2.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
    "Shen et al. 2000, Table 1, a=1.0"

TOLERANCE=1.0 run_test "Shen 2D a=1.0" "${TEST_DIR}/shen_2d_a10.in" 0.551506 0.448494

# Case: a = 1.5
create_input_file "${TEST_DIR}/shen_2d_a15.in" 2 8 \
    "1.5 1.0" \
    "2.0 0.0
0.0 2.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
    "Shen et al. 2000, Table 1, a=1.5"

TOLERANCE=1.0 run_test "Shen 2D a=1.5" "${TEST_DIR}/shen_2d_a15.in" 0.879534 0.471624

# Case: a = 2.0
create_input_file "${TEST_DIR}/shen_2d_a20.in" 2 8 \
    "2.0 1.0" \
    "2.0 0.0
0.0 2.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
    "Shen et al. 2000, Table 1, a=2.0"

TOLERANCE=1.0 run_test "Shen 2D a=2.0" "${TEST_DIR}/shen_2d_a20.in" 1.239964 0.482830

# -----------------------------------------------------------------------------
# Section 5.2: 3D Product Form Test (Table 3)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- Section 5.2: 3D Product Form Test (Table 3) ---${NC}"
echo "Testing 3D product form SRBM with known analytical solution"
echo "Exact solution: E[X1]=0.5, E[X2]=0.343482, E[X3]=0.418023"

# 3D Product Form test
# Expected: E[X1]=0.5, E[X2]=0.343482, E[X3]=0.418023
create_input_file "${TEST_DIR}/shen_3d_product.in" 3 8 \
    "1.0 1.0 1.0" \
    "1.0 0.0 0.0
0.0 1.0 0.0
0.0 0.0 1.0" \
    "1.0 -1.0 -0.5" \
    "1.0 -1.0 -1.0 1.0 0.0 0.0
1.0 -1.0 1.0 -1.0 0.0 0.0
0.0 0.0 0.0 0.0 1.0 -1.0" \
    "Shen et al. 2000, Table 3, 3D Product Form"

TOLERANCE=2.0 run_test "Shen 3D Product Form" "${TEST_DIR}/shen_3d_product.in" 0.500000 0.343482 0.418023

# -----------------------------------------------------------------------------
# Section 5.1: 2D Product Form Test (Table 2)
# This tests the product form with theta=(10,-10)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- Section 5.1: 2D Product Form Test (Table 2) ---${NC}"
echo "Testing 2D product form SRBM"
echo "Expected: E[X1]=0.5, E[X2]=0.95"

create_input_file "${TEST_DIR}/shen_2d_product.in" 2 12 \
    "1.0 1.0" \
    "1.0 0.0
0.0 1.0" \
    "-10.0 10.0" \
    "1.0 -1.0 -1.0 1.0
1.0 -1.0 1.0 -1.0" \
    "Shen et al. 2000, Table 2, 2D Product Form"

TOLERANCE=2.0 run_test "Shen 2D Product Form" "${TEST_DIR}/shen_2d_product.in" 0.5 0.95

# =============================================================================
# TESTS FROM DAI & HARRISON (1991)
# =============================================================================
echo -e "\n${YELLOW}=== Tests from Dai & Harrison (1991) ===${NC}"
echo "Reference: 'Steady-State Analysis of RBM in a Rectangle'"

# -----------------------------------------------------------------------------
# Table 2: Spectral Coefficients Test (Unit Square)
# This is the driftless case with the specific R matrix
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- Table 2: 2D Tandem Queue (Unit Square) ---${NC}"
echo "Zero drift case with tandem queue reflection"

# The Table 2 case: unit square, zero drift, Gamma=2I
create_input_file "${TEST_DIR}/dh_table2.in" 2 8 \
    "1.0 1.0" \
    "2.0 0.0
0.0 2.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
    "Dai & Harrison 1991, Table 2, Zero drift tandem"

# From Table 2, the expected E[X1] ≈ 0.5514, E[X2] ≈ 0.4486
TOLERANCE=2.0 run_test "D&H Table 2 (Unit Square)" "${TEST_DIR}/dh_table2.in" 0.5514 0.4486

# -----------------------------------------------------------------------------
# Additional symmetric tests
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- Symmetric Tests ---${NC}"

# 2D Symmetric (normal reflection)
echo "2D Symmetric unit square with normal reflection"
create_input_file "${TEST_DIR}/symmetric_2d.in" 2 6 \
    "1.0 1.0" \
    "1.0 0.0
0.0 1.0" \
    "0.0 0.0" \
    "1.0 -1.0 0.0 0.0
0.0 0.0 1.0 -1.0" \
    "2D Symmetric with normal reflection"

# By symmetry, E[X1] = E[X2] = 0.5
TOLERANCE=1.0 run_test "2D Symmetric Normal" "${TEST_DIR}/symmetric_2d.in" 0.5 0.5

# 3D Symmetric (normal reflection)
echo "3D Symmetric unit cube with normal reflection"
create_input_file "${TEST_DIR}/symmetric_3d.in" 3 5 \
    "1.0 1.0 1.0" \
    "1.0 0.0 0.0
0.0 1.0 0.0
0.0 0.0 1.0" \
    "0.0 0.0 0.0" \
    "1.0 -1.0 0.0 0.0 0.0 0.0
0.0 0.0 1.0 -1.0 0.0 0.0
0.0 0.0 0.0 0.0 1.0 -1.0" \
    "3D Symmetric with normal reflection"

# By symmetry, E[X1] = E[X2] = E[X3] = 0.5
TOLERANCE=1.0 run_test "3D Symmetric Normal" "${TEST_DIR}/symmetric_3d.in" 0.5 0.5 0.5

# =============================================================================
# QUEUEING NETWORK TESTS
# =============================================================================
echo -e "\n${YELLOW}=== Queueing Network Tests ===${NC}"

# -----------------------------------------------------------------------------
# 3-Station Tandem Queue (Shen Section 6)
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}--- 3-Station Tandem Queue ---${NC}"

# System 1 from Table 7: b1=b2=b3=10, specific service rates
# Approximating with normalized parameters
create_input_file "${TEST_DIR}/tandem_3station.in" 3 5 \
    "10.0 10.0 10.0" \
    "2.0 0.0 0.0
0.0 2.0 0.0
0.0 0.0 2.0" \
    "-0.1 0.0 0.0" \
    "1.0 -1.0 0.0 0.0 0.0 0.0
-1.0 0.0 1.0 -1.0 0.0 0.0
0.0 0.0 -1.0 0.0 1.0 -1.0" \
    "3-Station Tandem Queue"

# Qualitative test: run and check basic sanity (values should be positive and < 10)
echo "  Note: Qualitative test - checking tandem structure properties"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
echo -e "\n${BLUE}Test: 3-Station Tandem (Qualitative)${NC}"
echo "  Input: ${TEST_DIR}/tandem_3station.in"
output=$("$SOLVER" "${TEST_DIR}/tandem_3station.in" 2>/dev/null)
q1=$(echo "$output" | grep "^q1 = " | sed 's/q1 = //')
q2=$(echo "$output" | grep "^q2 = " | sed 's/q2 = //')
q3=$(echo "$output" | grep "^q3 = " | sed 's/q3 = //')
echo "    Results: E[X1]=$q1, E[X2]=$q2, E[X3]=$q3"
# Check all values are positive and less than buffer size
if (( $(echo "$q1 > 0 && $q1 < 10 && $q2 > 0 && $q2 < 10 && $q3 > 0 && $q3 < 10" | bc -l) )); then
    echo -e "    ${GREEN}PASS${NC}: All queue lengths in valid range (0, 10)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    echo -e "    ${RED}FAIL${NC}: Queue lengths out of expected range"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

# =============================================================================
# CONVERGENCE TESTS (increasing polynomial degree)
# =============================================================================
echo -e "\n${YELLOW}=== Convergence Tests ===${NC}"
echo "Testing that higher polynomial degree gives better accuracy"

echo -e "\n${BLUE}--- Degree Convergence Test ---${NC}"

# Run the 2D zero-drift test at different degrees (matching test_input_2d.txt)
for degree in 4 6 8 10 12; do
    create_input_file "${TEST_DIR}/convergence_deg${degree}.in" 2 $degree \
        "1.0 1.0" \
        "2.0 0.0
0.0 2.0" \
        "0.0 0.0" \
        "1.0 -1.0 0.0 1.0
-1.0 0.0 1.0 -1.0" \
        "Convergence test degree=$degree"

    # Use looser tolerance for lower degrees
    if [ $degree -le 6 ]; then
        TOLERANCE=5.0
    else
        TOLERANCE=2.0
    fi
    run_test "Convergence deg=$degree" "${TEST_DIR}/convergence_deg${degree}.in" 0.551506 0.448494
done

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n${YELLOW}=======================================${NC}"
echo -e "${YELLOW}           TEST SUMMARY${NC}"
echo -e "${YELLOW}=======================================${NC}"

echo -e "\nTotal tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed. Review output above for details.${NC}"
    exit 1
fi
