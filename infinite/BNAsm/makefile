# Makefile for BNET with SuiteSparse CHOLMOD, Apple Accelerate, and OpenMP
#
# Compiler settings
# Use Homebrew GCC for OpenMP support (macOS clang doesn't support -fopenmp)
unexport MACOSX_DEPLOYMENT_TARGET

CC = /opt/homebrew/bin/gcc-13

# Machine type
MACHINE = LINUX

# Homebrew paths for SuiteSparse
HBINC = /opt/homebrew/include
HBLIB = /opt/homebrew/lib

# Compiler flags
# -fopenmp: Enable OpenMP
# -I$(HBINC): Include path for SuiteSparse headers
# -DANSI_C: Use ANSI C function prototypes
CFLAGS = -DANSI_C -D${MACHINE} -O3 -w \
         -fopenmp \
         -I$(HBINC) \
         -I$(HBINC)/suitesparse

# Linker flags
# Link against SuiteSparse libraries, Apple Accelerate (parallelized BLAS/LAPACK), and OpenMP
LDFLAGS = -L$(HBLIB) \
          -lcholmod \
          -lumfpack \
          -lamd \
          -lcolamd \
          -lcamd \
          -lccolamd \
          -lsuitesparseconfig \
          -framework Accelerate \
          -lm \
          -fopenmp

# Source files
GJN = gjn.o
MCN = mcn.o
BNET = bnet.o index.o bnetio.o suitesparse_compat.o

# Targets
all: bnet

bnet: ${BNET}
	$(CC) $(CFLAGS) -o bnet ${BNET} $(LDFLAGS)

bnet.o: bnet.c bnet.h suitesparse_compat.h
	$(CC) $(CFLAGS) -c bnet.c

bnetio.o: bnetio.c bnet.h suitesparse_compat.h
	$(CC) $(CFLAGS) -c bnetio.c

index.o: index.c bnet.h
	$(CC) $(CFLAGS) -c index.c

suitesparse_compat.o: suitesparse_compat.c suitesparse_compat.h
	$(CC) $(CFLAGS) -c suitesparse_compat.c

clean:
	-rm -f *.o
	-rm -f bnet gjn mcn

test: bnet
	@echo "Testing bnet with b2..."
	./bnet b2
	@echo ""
	@echo "Testing bnet with b4..."
	./bnet b4
	@echo ""

# Performance test with timing
perf: bnet
	@echo "Performance test with b8 (single thread)..."
	OMP_NUM_THREADS=1 time ./bnet b8
	@echo ""
	@echo "Performance test with b8 (4 threads)..."
	OMP_NUM_THREADS=4 time ./bnet b8
	@echo ""

.PHONY: all clean test perf
