# Makefile for SRBM Solver
#
# Supports:
#   - macOS with Apple Accelerate framework
#   - Linux with OpenBLAS or Intel MKL
#   - OpenMP parallelization (enabled by default)
#   - SuiteSparse for optimized matrix operations (enabled by default)
#
# To disable: make OPENMP=0 SUITESPARSE=0

# Detect OS
UNAME_S := $(shell uname -s)

# Enable OpenMP and SuiteSparse by default (disable with =0)
OPENMP ?= 1
SUITESPARSE ?= 1

# Compiler
CC = gcc

# Base flags
CFLAGS = -Wall -Wextra -O3 -std=c11

# Debug build
ifdef DEBUG
	CFLAGS = -Wall -Wextra -g -O0 -std=c11 -DDEBUG
endif

# Platform-specific settings
ifeq ($(UNAME_S),Darwin)
	# macOS: Use Accelerate framework
	LDFLAGS += -framework Accelerate
	CFLAGS += -DACCELERATE -DACCELERATE_NEW_LAPACK

	# Use clang on macOS
	CC = clang

	# OpenMP with Homebrew libomp on macOS
	ifeq ($(OPENMP),1)
		LIBOMP_PATH := $(shell brew --prefix libomp 2>/dev/null)
		ifneq ($(LIBOMP_PATH),)
			CFLAGS += -Xpreprocessor -fopenmp -I$(LIBOMP_PATH)/include
			LDFLAGS += -L$(LIBOMP_PATH)/lib -lomp
		else
			$(warning OpenMP enabled but libomp not found. Install with: brew install libomp)
		endif
	endif

	# SuiteSparse support on macOS
	ifeq ($(SUITESPARSE),1)
		SUITESPARSE_ROOT := $(shell brew --prefix suite-sparse 2>/dev/null)
		ifneq ($(SUITESPARSE_ROOT),)
			CFLAGS += -DUSE_SUITESPARSE -I$(SUITESPARSE_ROOT)/include/suitesparse
			LDFLAGS += -L$(SUITESPARSE_ROOT)/lib
			LDFLAGS += -lcholmod -lamd -lcolamd -lcamd -lccolamd -lsuitesparseconfig
		else
			$(warning SuiteSparse enabled but not found. Install with: brew install suite-sparse)
		endif
	endif
else
	# Linux

	# OpenMP support on Linux
	ifeq ($(OPENMP),1)
		CFLAGS += -fopenmp
		LDFLAGS += -fopenmp
	endif

	# BLAS/LAPACK: Use OpenBLAS or MKL
	ifdef MKL
		CFLAGS += -DMKL -I${MKLROOT}/include
		LDFLAGS += -L${MKLROOT}/lib/intel64 -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -lpthread -lm
	else
		# Default: OpenBLAS
		LDFLAGS += -lopenblas -llapacke -lm
	endif

	# SuiteSparse support on Linux
	ifeq ($(SUITESPARSE),1)
		CFLAGS += -DUSE_SUITESPARSE
		# Try pkg-config first
		SUITESPARSE_CFLAGS := $(shell pkg-config --cflags suitesparse 2>/dev/null)
		SUITESPARSE_LIBS := $(shell pkg-config --libs suitesparse 2>/dev/null)
		ifneq ($(SUITESPARSE_LIBS),)
			CFLAGS += $(SUITESPARSE_CFLAGS)
			LDFLAGS += $(SUITESPARSE_LIBS)
		else
			# Fallback to standard paths
			CFLAGS += -I/usr/include/suitesparse
			LDFLAGS += -lcholmod -lamd -lcolamd -lcamd -lccolamd -lsuitesparseconfig
		endif
	endif
endif

# Source files
SRCS = main.c srbm_solver.c poly_ops.c input_parser.c

# Add SuiteSparse sources if enabled
ifeq ($(SUITESPARSE),1)
	SRCS += suitesparse_wrapper.c gram_matrix.c
endif

OBJS = $(SRCS:.c=.o)
HEADERS = srbm_types.h srbm_solver.h

# Add SuiteSparse headers if enabled
ifeq ($(SUITESPARSE),1)
	HEADERS += suitesparse_wrapper.h gram_matrix.h
endif

# Target
TARGET = srbm_solver

# Default target
all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $(TARGET) $(LDFLAGS)

%.o: %.c $(HEADERS)
	$(CC) $(CFLAGS) -c $< -o $@

# Clean
clean:
	rm -f $(OBJS) $(TARGET)

# Install (optional)
PREFIX ?= /usr/local
install: $(TARGET)
	install -d $(PREFIX)/bin
	install -m 755 $(TARGET) $(PREFIX)/bin/

# Test targets
test: $(TARGET)
	./$(TARGET) test_input_2d.txt -v

test3d: $(TARGET)
	./$(TARGET) test_input_3d.txt -v

# Help
help:
	@echo "SRBM Solver Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Build the solver (default, with OpenMP + SuiteSparse)"
	@echo "  clean   - Remove build files"
	@echo "  install - Install to PREFIX (default: /usr/local)"
	@echo "  test    - Run 2D test"
	@echo "  test3d  - Run 3D test"
	@echo ""
	@echo "Options (OpenMP and SuiteSparse are enabled by default):"
	@echo "  OPENMP=0      - Disable OpenMP parallelization"
	@echo "  SUITESPARSE=0 - Disable SuiteSparse optimized solver"
	@echo "  DEBUG=1       - Build with debug symbols"
	@echo "  MKL=1         - Use Intel MKL (Linux only)"
	@echo ""
	@echo "Examples:"
	@echo "  make                                # Build with all optimizations (default)"
	@echo "  make OPENMP=0 SUITESPARSE=0         # Build without optimizations"
	@echo "  make DEBUG=1                        # Build debug version"
	@echo ""
	@echo "Prerequisites (macOS): brew install libomp suite-sparse"
	@echo ""
	@echo "Runtime:"
	@echo "  ./srbm_solver input.txt             # Run solver (SuiteSparse by default)"
	@echo "  ./srbm_solver input.txt -g          # Force Gram-Schmidt solver"
	@echo "  ./srbm_solver input.txt -v          # Verbose output"

.PHONY: all clean install test test3d help
