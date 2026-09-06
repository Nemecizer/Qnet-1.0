# Two engines, one method. `solver.py` and `fbna_gc` read the same document and
# print byte-identical output; Settings > Solvers > Solver Engine picks between
# them (under "Markovian CTMC", the row shared with the adaptive truncated CTMC,
# because the two run the same power-iteration kernel). `make parity` is what
# keeps that claim true.

.PHONY: all test example engine parity check clean

PYTHON ?= python3

CC = gcc
# -ffp-contract=off keeps `a*b + c` two operations, as CPython evaluates it.
# Nothing in this solver uses math.fsum -- every accumulation is a plain sum --
# so the arithmetic matches with no exact-summation machinery, but only if the
# compiler is not allowed to fuse.
CFLAGS = -Wall -O2 -std=c99 -pedantic -ffp-contract=off
LDFLAGS = -lm -Wl,-headerpad_max_install_names

all: engine

engine: fbna_gc

fbna_gc: fbna_gc.c ../../common/bnet_json.h ../../common/bnet_memcheck.h
	$(CC) $(CFLAGS) -o fbna_gc fbna_gc.c $(LDFLAGS)

check: test example engine parity

test:
	$(PYTHON) -m unittest discover -s tests -v

example:
	$(PYTHON) solver.py examples/mm1k.json

parity: fbna_gc
	./tests/test_engine_parity.sh

clean:
	rm -f fbna_gc
