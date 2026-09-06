.PHONY: check test examples closed-example open-example mixed-example loss-example

PYTHON ?= python3

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -v

check: test examples

# Both output modes, and every packaged example. --json alone left the human
# printer — which is the mode the GUI runs — unexercised, and closed_multiclass
# was not in the list at all, so a KeyError on that one file and that one mode
# shipped.
examples:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/closed_single_class.json --json >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/closed_multiclass_bcmp.json --json >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/open_multiclass_bcmp.json --json >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/mixed_bcmp.json --json --include-states >/dev/null
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py examples/multirate_loss.json --json >/dev/null
	@for f in examples/*.json; do \
		PYTHONDONTWRITEBYTECODE=1 $(PYTHON) solver.py $$f >/dev/null || exit 1; \
	done
	@echo "all examples pass in both --json and human mode"

closed-example:
	$(PYTHON) solver.py examples/closed_single_class.json

open-example:
	$(PYTHON) solver.py examples/open_multiclass_bcmp.json

mixed-example:
	$(PYTHON) solver.py examples/mixed_bcmp.json

loss-example:
	$(PYTHON) solver.py examples/multirate_loss.json
