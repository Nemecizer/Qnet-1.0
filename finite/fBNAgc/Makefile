.PHONY: test example

PYTHON ?= python3

test:
	$(PYTHON) -m unittest discover -s tests -v

example:
	$(PYTHON) solver.py examples/mm1k.json
