# Two engines, one method. `regenerative_mc.py` and `bna_rmc` read the same
# document and print the same report; Settings > Solvers > Solver Engine picks
# between them. `make parity` is what keeps that claim true.

PYTHON ?= python3
SOLVER := regenerative_mc.py

CC = gcc
# -ffp-contract=off is NOT optional and is not a performance choice. Clang on
# Apple silicon fuses `a*b+c` into a single FMA by default, which is more
# accurate per operation but produces a DIFFERENT double from the same
# expression evaluated step by step -- which is what CPython does. With
# contraction on, the C engine's standard errors differ from the Python's in
# the last two digits; with it off they are bit-identical. Removing this flag
# silently breaks the parity contract that `make parity` exists to enforce.
CFLAGS = -Wall -O2 -std=c99 -pedantic -ffp-contract=off
LDFLAGS = -lm -Wl,-headerpad_max_install_names

.PHONY: all check test examples engine parity clean

all: engine

engine: bna_rmc

bna_rmc: bna_rmc.c ../../common/bnet_json.h ../../common/bnet_pyrandom.h ../../common/bnet_fsum.h ../../common/bnet_memcheck.h
	$(CC) $(CFLAGS) -o bna_rmc bna_rmc.c $(LDFLAGS)

check: test examples engine parity

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

examples:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/mm1.json --compact >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/multiclass_network.json --compact >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/mm1k_importance.json --compact >/dev/null

parity: bna_rmc
	./tests/test_engine_parity.sh

clean:
	rm -f bna_rmc
