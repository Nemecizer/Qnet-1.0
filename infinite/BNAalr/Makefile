.PHONY: test check examples

test:
	python3 -m unittest discover -s tests -v

check: test examples

examples:
	python3 low_rank_bar.py examples/one_dimensional.json --require-tolerance >/dev/null
	python3 low_rank_bar.py examples/skew_symmetric_2d.json --json --require-tolerance >/dev/null
	python3 low_rank_bar.py examples/non_product_2d.json --json >/dev/null
