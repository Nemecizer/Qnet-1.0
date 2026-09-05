.PHONY: check test examples closed-example open-example mixed-example loss-example

PYTHON ?= python3

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -v

check: test examples

examples:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/closed_single_class.json --json >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/open_multiclass_bcmp.json --json >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/mixed_bcmp.json --json --include-states >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/multirate_loss.json --json >/dev/null

closed-example:
	$(PYTHON) solver.py examples/closed_single_class.json

open-example:
	$(PYTHON) solver.py examples/open_multiclass_bcmp.json

mixed-example:
	$(PYTHON) solver.py examples/mixed_bcmp.json

loss-example:
	$(PYTHON) solver.py examples/multirate_loss.json
