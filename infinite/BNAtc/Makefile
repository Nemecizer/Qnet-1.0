PYTHON ?= python3
SOLVER := truncated_ctmc.py

.PHONY: all check test examples

all: check

check: test examples

test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

examples:
	$(PYTHON) $(SOLVER) examples/mm1.json --compact >/dev/null
	$(PYTHON) $(SOLVER) examples/tandem.json --compact >/dev/null
