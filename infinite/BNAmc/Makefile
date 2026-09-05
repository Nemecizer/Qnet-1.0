unexport MACOSX_DEPLOYMENT_TARGET

CC = cc
CFLAGS = -O2 -Wall -std=c11

# SuiteSparse paths (Homebrew on macOS)
SS_CFLAGS = $(shell pkg-config --cflags CXSparse 2>/dev/null || echo "-I/opt/homebrew/include/suitesparse")
SS_LDFLAGS = $(shell pkg-config --libs CXSparse 2>/dev/null || echo "-L/opt/homebrew/lib -lcxsparse")

# Apple Accelerate framework (macOS only)
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
ACC_LDFLAGS = -framework Accelerate
else
ACC_LDFLAGS =
endif

# OpenMP support (optional; on macOS requires: brew install libomp)
LIBOMP_PREFIX := $(shell brew --prefix libomp 2>/dev/null)
ifneq ($(LIBOMP_PREFIX),)
OMP_CFLAGS = -Xpreprocessor -fopenmp -I$(LIBOMP_PREFIX)/include
OMP_LDFLAGS = -L$(LIBOMP_PREFIX)/lib -lomp
else
OMP_CFLAGS =
OMP_LDFLAGS =
endif

ALL_CFLAGS  = $(CFLAGS) $(SS_CFLAGS) $(OMP_CFLAGS)
ALL_LDFLAGS = $(SS_LDFLAGS) $(ACC_LDFLAGS) $(OMP_LDFLAGS) -lm

.PHONY: all clean

all: rbm_mlmc gen_symmetric gen_tridiag

rbm_mlmc: rbm_mlmc.c
	$(CC) $(ALL_CFLAGS) -o $@ $< $(ALL_LDFLAGS)

gen_symmetric: gen_symmetric.c
	$(CC) $(CFLAGS) -o $@ $< -lm

gen_tridiag: gen_tridiag.c
	$(CC) $(CFLAGS) -o $@ $< -lm

clean:
	rm -f rbm_mlmc gen_symmetric gen_tridiag
	rm -f test_inputs/*.txt
