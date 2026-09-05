.PHONY: test check examples

PYTHON ?= python3
PYTHONPYCACHEPREFIX ?= /tmp/qnet-bar-bounds-pycache
export PYTHONPYCACHEPREFIX

test:
	$(PYTHON) -m unittest discover -s tests -v

check: test
	$(PYTHON) -m py_compile __init__.py bar_bounds.py cvxpy_backend.py solver.py tests/test_bar_bounds.py

examples:
	$(PYTHON) solver.py examples/one_dimensional.json --json
	$(PYTHON) solver.py examples/skew_product_form.json --json
	$(PYTHON) solver.py examples/general_two_station.json --force-relaxation --export-relaxation /tmp/qnet-bar-relaxation.json --json
