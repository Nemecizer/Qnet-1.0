# Two engines, one method. `qbd_solver.py` and `bna_qbd` read the same document
# and print byte-identical output; Settings > Solvers > Solver Engine picks
# between them, and `make parity` is what keeps that claim true.

PYTHON ?= python3
SOLVER := qbd_solver.py

CC = gcc
# -ffp-contract=off is load-bearing, not a tuning flag. Clang on Apple silicon
# fuses `a*b + c` into one FMA by default, which is a different double from the
# same expression evaluated in two steps -- and CPython never fuses. With
# contraction on, the residuals and the rate matrix drift from the Python's in
# the last digits and the parity test fails. Removing this flag breaks the
# contract `make parity` exists to enforce.
CFLAGS = -Wall -O2 -std=c99 -pedantic -ffp-contract=off
LDFLAGS = -lm -Wl,-headerpad_max_install_names

.PHONY: all check test examples engine parity clean

all: engine

engine: bna_qbd

bna_qbd: bna_qbd.c ../../common/bnet_json.h ../../common/bnet_fsum.h
	$(CC) $(CFLAGS) -o bna_qbd bna_qbd.c $(LDFLAGS)

check: test examples engine parity

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

examples:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/mm1.json --compact >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/erlang2.json --compact >/dev/null

parity: bna_qbd
	./tests/test_engine_parity.sh

clean:
	rm -f bna_qbd
