# BNA/FM Algorithm - C Implementation
# Makefile for building Gaussian and CBC-QMC versions
# Requires: brew install suite-sparse libomp (macOS) or apt install libsuitesparse-dev libomp-dev (Linux)

CC = gcc
CFLAGS = -Wall -Wextra -O3 -std=c99

# Detect platform and set SuiteSparse + OpenMP paths
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    # macOS with Homebrew
    HOMEBREW_PREFIX := $(shell brew --prefix)
    SUITESPARSE_INC = $(HOMEBREW_PREFIX)/include/suitesparse
    SUITESPARSE_LIB = $(HOMEBREW_PREFIX)/lib
    LIBOMP_PREFIX := $(shell brew --prefix libomp)
    CFLAGS += -I$(SUITESPARSE_INC) -I$(LIBOMP_PREFIX)/include -Xpreprocessor -fopenmp
    LDFLAGS = -L$(SUITESPARSE_LIB) -L$(LIBOMP_PREFIX)/lib -lomp \
              -lumfpack -lcholmod -lamd -lcolamd -lccolamd -lcamd \
              -lsuitesparseconfig -framework Accelerate -lm
else
    # Linux
    SUITESPARSE_INC ?= /usr/include/suitesparse
    CFLAGS += -I$(SUITESPARSE_INC) -fopenmp
    LDFLAGS = -lumfpack -lcholmod -lamd -lcolamd -lccolamd -lcamd \
              -lsuitesparseconfig -lblas -llapack -lgomp -lm
endif

# Executables
TARGETS = bna_fm_gauss bna_fm_cbc

# Source files
COMMON_SRC = bna_fm_common.c
GAUSS_SRC = bna_fm_gauss.c
CBC_SRC = bna_fm_cbc.c
QMC_SRCS = qmc_utils.c qmc_lattice_seq.c qmc_lattice_rules.c

# Object files
COMMON_OBJ = bna_fm_common.o
GAUSS_OBJ = bna_fm_gauss.o
CBC_OBJ = bna_fm_cbc.o
QMC_OBJS = qmc_utils.o qmc_lattice_seq.o qmc_lattice_rules.o

.PHONY: all clean test

all: $(TARGETS)

bna_fm_gauss: $(GAUSS_OBJ) $(COMMON_OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

bna_fm_cbc: $(CBC_OBJ) $(COMMON_OBJ) $(QMC_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c bna_fm.h
	$(CC) $(CFLAGS) -c $< -o $@

qmc_%.o: qmc_%.c qmc.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGETS) *.o

# Test with the 3d.in example
test: $(TARGETS)
	@echo "=== Testing Gaussian Quadrature ==="
	./bna_fm_gauss 3d.in
	@echo ""
	@echo "=== Testing CBC-QMC ==="
	./bna_fm_cbc 3d.in 256
	@echo ""
	@echo "Expected results: q = (0.5, 0.343482, 0.418023)"

# Install (optional)
PREFIX ?= /usr/local
install: $(TARGETS)
	install -d $(PREFIX)/bin
	install -m 755 $(TARGETS) $(PREFIX)/bin

# Debug build
ifeq ($(UNAME_S),Darwin)
debug: CFLAGS = -Wall -Wextra -g -O0 -std=c99 -I$(SUITESPARSE_INC) -I$(LIBOMP_PREFIX)/include -Xpreprocessor -fopenmp
else
debug: CFLAGS = -Wall -Wextra -g -O0 -std=c99 -I$(SUITESPARSE_INC) -fopenmp
endif
debug: all
