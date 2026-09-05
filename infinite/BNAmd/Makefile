# Multi-class SRBM experiment — research-grade solver
#
#   * OpenMP   — for FEM element-assembly parallelism (Tier 1 pattern)
#   * Accelerate — Apple's BLAS + SpMV (SparseBLAS)
#   * SuiteSparse — UMFPACK for unsymmetric LU, CHOLMOD for supernodal
#     Cholesky with Tikhonov regularization (Tier 2 pattern)
#   * cJSON    — for direct .bnet JSON parsing

CC      = cc
CSTD    = -std=c99
OPT     = -O3
WARN    = -Wall -Wextra -Wno-unused-parameter

HB_INC  = -I/opt/homebrew/include
HB_LIB  = -L/opt/homebrew/lib
OMP_DIR = /opt/homebrew/opt/libomp
OMP_INC = -I$(OMP_DIR)/include
OMP_LIB = -L$(OMP_DIR)/lib
SUITE_INC = -I/opt/homebrew/include/suitesparse

CFLAGS  = $(CSTD) $(OPT) $(WARN) $(OMP_INC) $(HB_INC) $(SUITE_INC) \
          -Icommon -Isrc \
          -Xpreprocessor -fopenmp \
          -DACCELERATE_NEW_LAPACK
LDFLAGS = $(OMP_LIB) $(HB_LIB) \
          -lomp -lumfpack -lcholmod -lamd -lcolamd -lccolamd -lcamd \
          -lsuitesparseconfig -lcjson -framework Accelerate -lm

# ─── Sources ──────────────────────────────────────────────────────────────
COMMON_SRC = common/bna_fm_common.c
PARSER_SRC = src/bnet_parser.c
DIST_SRC   = src/mc_dist.c
PARAMS_SRC = src/mc_params.c
ADAPT_SRC  = src/mc_adapter.c
FEM_SRC    = src/mc_fem_gauss.c
SOLVER_SRC = src/mc_solver.c

MC_SOLVER_SRC = $(COMMON_SRC) $(PARSER_SRC) $(DIST_SRC) $(PARAMS_SRC) \
                $(ADAPT_SRC) $(FEM_SRC) $(SOLVER_SRC)
MC_SOLVER_OBJ = $(MC_SOLVER_SRC:.c=.o)

# ─── Targets ──────────────────────────────────────────────────────────────
.PHONY: all solver clean check test

all: solver

solver: mc_solver

mc_solver: $(MC_SOLVER_OBJ)
	$(CC) $(CFLAGS) -o $@ $(MC_SOLVER_OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Parameter-computation-only check: prints the resolved
#   (theta, Sigma, R, a) from any .bnet input so we can diff it against
#   what the Swift exporter would have produced.
tests/test_params: tests/test_params.c src/mc_params.c src/mc_dist.c src/mc_srbm.h
	$(CC) -std=c99 -O2 -Wall -Wextra -Werror -Isrc \
		tests/test_params.c src/mc_params.c src/mc_dist.c -lm -o $@

test: tests/test_params
	./tests/test_params

check: test
	@echo "Core multiclass primitive tests passed. Run 'make solver' when cJSON, SuiteSparse, libomp and Accelerate are installed."

clean:
	rm -f $(MC_SOLVER_OBJ)
	rm -f mc_solver tests/test_params
