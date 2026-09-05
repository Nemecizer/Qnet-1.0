.PHONY: test examples

test:
	python3 -m unittest discover -s tests -v

examples:
	python3 fbna_decomp.py examples/mm1k_loss.json --format text
	python3 fbna_decomp.py examples/multiclass_feedback_loss.json --format text
	python3 fbna_decomp.py examples/multiclass_bas_approx.json --format text
