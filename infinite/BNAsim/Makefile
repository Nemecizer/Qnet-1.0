# Makefile for Multi-Class Jackson Network Simulators
#
# Usage:
#   make              - Build both simulators
#   make infinite     - Build infinite buffer simulator only
#   make finite       - Build finite buffer simulator only
#   make test         - Run example simulations (infinite buffers)
#   make test-finite  - Run example simulations (finite buffers)
#   make clean        - Remove compiled files

unexport MACOSX_DEPLOYMENT_TARGET

CC = cc
CFLAGS = -Wall -O2 -std=c99
LDFLAGS = -lm -Wl,-headerpad_max_install_names

# OpenMP support (Apple Clang + Homebrew libomp) — enabled by default.
# Parallelizes the per-replication loop; disable with `make OPENMP=0`.
OPENMP ?= 1
ifeq ($(OPENMP),1)
OMP_PREFIX = $(shell brew --prefix libomp 2>/dev/null || echo /opt/homebrew/opt/libomp)
CFLAGS  += -Xpreprocessor -fopenmp -I$(OMP_PREFIX)/include
LDFLAGS += -L$(OMP_PREFIX)/lib -lomp
endif

# Main targets
all: jackson_sim jackson_sim_finite

infinite: jackson_sim

finite: jackson_sim_finite

jackson_sim: jackson_sim.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

jackson_sim_finite: jackson_sim_finite.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Debug builds
debug: CFLAGS = -Wall -g -DDEBUG -std=c99
debug: all

# Run tests with infinite buffer examples
test: jackson_sim
	@echo "========================================"
	@echo "Running 2-station example (m2)..."
	@echo "========================================"
	./jackson_sim example_m2.sim
	@echo ""
	@echo "========================================"
	@echo "Running 4-station example (m4)..."
	@echo "========================================"
	./jackson_sim example_m4.sim

# Run tests with finite buffer examples
test-finite: jackson_sim_finite
	@echo "========================================"
	@echo "Running tandem queue with finite buffers..."
	@echo "========================================"
	./jackson_sim_finite example_finite_tandem.sim
	@echo ""
	@echo "========================================"
	@echo "Running fork-join with finite buffers..."
	@echo "========================================"
	./jackson_sim_finite example_finite_fork.sim
	@echo ""
	@echo "========================================"
	@echo "Running rejection/loss system..."
	@echo "========================================"
	./jackson_sim_finite example_rejection.sim

# Quick tests with fewer replications
quicktest: jackson_sim
	./jackson_sim example_m2.sim -n 5 -w 1000 -r 10000

quicktest-finite: jackson_sim_finite
	./jackson_sim_finite example_finite_tandem.sim -n 5 -w 2000 -r 20000

# Compare infinite vs finite buffer behavior
compare: jackson_sim jackson_sim_finite
	@echo "========================================"
	@echo "Infinite buffer tandem queue..."
	@echo "========================================"
	./jackson_sim example_m2.sim -n 10 -w 5000 -r 50000
	@echo ""
	@echo "========================================"
	@echo "Finite buffer tandem queue (BAS)..."
	@echo "========================================"
	./jackson_sim_finite example_finite_tandem.sim -n 10 -w 5000 -r 50000

# Clean up
clean:
	rm -f jackson_sim jackson_sim_finite
	rm -f *_results.txt
	rm -f *_mcn.txt

.PHONY: all infinite finite debug test test-finite quicktest quicktest-finite compare clean
