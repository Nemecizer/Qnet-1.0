# Two engines, one method. `truncated_ctmc.py` and `bna_tc` read the same
# document; Settings > Solvers > Solver Engine picks between them (under
# "Markovian CTMC", together with the finite generic CTMC that shares this
# power-iteration kernel). `make parity` is what keeps the claim true.

PYTHON ?= python3
SOLVER := truncated_ctmc.py

CC = gcc
# -ffp-contract=off is load-bearing. Clang fuses `a*b + c` into one FMA by
# default; CPython never does, and the fused result is a different double. With
# contraction on the two engines' residuals and moments diverge in the last
# digits and `make parity` fails. This is not a tuning flag.
CFLAGS = -Wall -O2 -std=c99 -pedantic -ffp-contract=off
LDFLAGS = -lm -Wl,-headerpad_max_install_names

.PHONY: all check test examples engine parity clean

all: engine

engine: bna_tc

bna_tc: bna_tc.c ../../common/bnet_json.h ../../common/bnet_fsum.h ../../common/bnet_memcheck.h
	$(CC) $(CFLAGS) -o bna_tc bna_tc.c $(LDFLAGS)

check: test examples engine parity

test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

examples:
	$(PYTHON) $(SOLVER) examples/mm1.json --compact >/dev/null
	$(PYTHON) $(SOLVER) examples/tandem.json --compact >/dev/null

parity: bna_tc
	./tests/test_engine_parity.sh

clean:
	rm -f bna_tc
