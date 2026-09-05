# ============================================================================
# fBNAlp — finite-buffer LP solver for SRBM in a d-dimensional rectangle.
# Ported from OLD/BNA/BNAlp (Saure / Glynn / Zeevi orthant solver) and
# extended to bounded boxes; see Qnet/finite/fBNAlp/README.md.
#
# Usage:
#   make                                 # default backend (HiGHS)
#   make SOLVERS="highs"                 # HiGHS only (redistributable)
#   make SOLVERS="highs glpk"            # add GLPK (also redistributable)
#   make SOLVERS="highs cplex"           # add CPLEX (developer machine only)
#   make clean
#
# CPLEX is non-redistributable, so build_app.sh always invokes the default
# (HiGHS-only) build to keep Qnet.app self-contained.
# ============================================================================

SOLVERS ?= highs

unexport MACOSX_DEPLOYMENT_TARGET

UNAME_S := $(shell uname -s)

CFLAGS   = -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS  =

ifeq ($(UNAME_S),Darwin)
    CC = clang
    CFLAGS  += -DACCELERATE_NEW_LAPACK
    LDFLAGS += -framework Accelerate

    # OpenMP via Homebrew libomp
    OMP_PREFIX = /opt/homebrew/opt/libomp
    CFLAGS  += -Xclang -fopenmp -I$(OMP_PREFIX)/include
    LDFLAGS += -L$(OMP_PREFIX)/lib -lomp

    # Solver prefixes (Homebrew)
    GLPK_PREFIX  = /opt/homebrew/opt/glpk
    HIGHS_PREFIX = /opt/homebrew/opt/highs
    CPLEX_DIR    = /Applications/CPLEX_Studio2211/cplex
    CPLEX_INC    = $(CPLEX_DIR)/include
    CPLEX_LIB    = $(CPLEX_DIR)/lib/arm64_osx/static_pic
else
    CC = gcc
    CFLAGS  += -fopenmp
    LDFLAGS += -lopenblas -llapacke -lm

    # Solver prefixes — adjust for distro layout if needed
    GLPK_PREFIX  ?= /usr
    HIGHS_PREFIX ?= /usr/local
    CPLEX_DIR    ?= /opt/cplex
    CPLEX_INC    = $(CPLEX_DIR)/include
    CPLEX_LIB    = $(CPLEX_DIR)/lib/x86-64_linux/static_pic
endif

LDFLAGS += -lm

# ---------- Source files ----------

SRCDIR = src
OBJDIR = obj

# Core sources (always compiled). Geometry-aware files (params, grid,
# basis, eval, build, output, main) are extended for the rectangle case;
# the others are inherited verbatim from the orthant BNAlp template.
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

TARGET = fBNAlp_solver

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
