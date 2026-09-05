PYTHON ?= python3
SOLVER := regenerative_mc.py

.PHONY: all check test examples

all: check

check: test examples

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

examples:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/mm1.json --compact >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/multiclass_network.json --compact >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(SOLVER) examples/mm1k_importance.json --compact >/dev/null
