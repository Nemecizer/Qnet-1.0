# ============================================================================
# SRBM LP Solver – Makefile
#
# Usage:
#   make                              # HiGHS only (default — redistributable)
#   make SOLVERS="cplex glpk highs"   # All three solvers
#   make SOLVERS="glpk"               # GLPK only
#   make SOLVERS="cplex highs"        # CPLEX + HiGHS (developer machines)
#   make clean
# ============================================================================

# Solver selection (default: highs — open source, ships with the app).
SOLVERS ?= highs

unexport MACOSX_DEPLOYMENT_TARGET

CC       = clang
CFLAGS   = -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -DACCELERATE_NEW_LAPACK

# Apple Accelerate (BLAS/LAPACK)
LDFLAGS  = -framework Accelerate

# OpenMP via Homebrew libomp
OMP_PREFIX = /opt/homebrew/opt/libomp
CFLAGS  += -Xclang -fopenmp -I$(OMP_PREFIX)/include
LDFLAGS += -L$(OMP_PREFIX)/lib -lomp

# SuiteSparse (available but not strictly needed for current COO→CSC)
# SS_PREFIX = /opt/homebrew/opt/suite-sparse
# CFLAGS  += -I$(SS_PREFIX)/include/suitesparse
# LDFLAGS += -L$(SS_PREFIX)/lib -lcxsparse

# Math library
LDFLAGS += -lm

# ---------- Solver-specific flags ----------

# CPLEX
CPLEX_DIR   = /Applications/CPLEX_Studio2211/cplex
CPLEX_INC   = $(CPLEX_DIR)/include
CPLEX_LIB   = $(CPLEX_DIR)/lib/arm64_osx/static_pic

# GLPK
GLPK_PREFIX = /opt/homebrew/opt/glpk

# HiGHS
HIGHS_PREFIX = /opt/homebrew/opt/highs

# ---------- Source files ----------

SRCDIR = src
OBJDIR = obj

# Core sources (always compiled)
CORE_SRC = \
	$(SRCDIR)/srbm_mem.c \
	$(SRCDIR)/srbm_params.c \
	$(SRCDIR)/srbm_grid.c \
	$(SRCDIR)/srbm_index.c \
	$(SRCDIR)/srbm_basis.c \
	$(SRCDIR)/srbm_eval.c \
	$(SRCDIR)/srbm_build.c \
	$(SRCDIR)/srbm_sparse.c \
	$(SRCDIR)/srbm_solve.c \
	$(SRCDIR)/srbm_output.c \
	$(SRCDIR)/srbm_linalg.c \
	$(SRCDIR)/main.c

SOLVER_SRC =

# Conditionally add solver backends
ifneq (,$(findstring cplex,$(SOLVERS)))
  CFLAGS     += -DHAVE_CPLEX -I$(CPLEX_INC)
  LDFLAGS    += -L$(CPLEX_LIB) -lcplex -lpthread
  SOLVER_SRC += $(SRCDIR)/srbm_solve_cplex.c
endif

ifneq (,$(findstring glpk,$(SOLVERS)))
  CFLAGS     += -DHAVE_GLPK -I$(GLPK_PREFIX)/include
  LDFLAGS    += -L$(GLPK_PREFIX)/lib -lglpk
  SOLVER_SRC += $(SRCDIR)/srbm_solve_glpk.c
endif

ifneq (,$(findstring highs,$(SOLVERS)))
  CFLAGS     += -DHAVE_HIGHS -I$(HIGHS_PREFIX)/include/highs
  LDFLAGS    += -L$(HIGHS_PREFIX)/lib -lhighs
  SOLVER_SRC += $(SRCDIR)/srbm_solve_highs.c
endif

ALL_SRC = $(CORE_SRC) $(SOLVER_SRC)
ALL_OBJ = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(ALL_SRC))

TARGET = srbm_lp

# ---------- Rules ----------

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(ALL_OBJ)
	$(CC) $(ALL_OBJ) $(LDFLAGS) -o $@

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) -c $< -o $@

$(OBJDIR):
	mkdir -p $(OBJDIR)

clean:
	rm -rf $(OBJDIR) $(TARGET)
