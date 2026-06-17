# Convenience targets for the offline coefficient toolkit.
#
# Run `make install` once (into a venv — see README), then use the targets
# below. Override the interpreter with `make PYTHON=/path/to/python <target>`.
# `regen` also formats the generated Move files with the repo's prettier
# (override with `make PRETTIER=/path/to/prettier regen`).
PYTHON ?= python3
PRETTIER ?= node_modules/.bin/prettier

# Committed Move files the generators emit (paths relative to the repo root).
GENERATED_MOVE := \
    math/fixed_point/sources/internal/cdf_coefficients.move \
    math/fixed_point/tests/sd29x9_tests/cdf_test_vectors.move \
    math/fixed_point/tests/ud30x9_tests/cdf_test_vectors.move

.PHONY: install regen validate check ci test

install: ## Install the package + dev dependencies into the active environment
	$(PYTHON) -m pip install -e ".[dev]"

regen: ## Re-derive coefficients, emit every generated Move file, then format
	$(PYTHON) -m gaussian_codegen.cdf.derive
	$(PYTHON) -m gaussian_codegen.cdf.emit_coefficients
	$(PYTHON) -m gaussian_codegen.cdf.emit_test_vectors
	cd ../.. && $(PRETTIER) --write $(GENERATED_MOVE)

validate: ## Re-check the committed coefficients against scipy (the CI gate)
	$(PYTHON) -m gaussian_codegen.cdf.validate

check: ## Drift-check generated files vs the emitters (coefficients: formatting-only, see README)
	$(PYTHON) -m gaussian_codegen.cdf.emit_coefficients --check
	$(PYTHON) -m gaussian_codegen.cdf.emit_test_vectors --check

test: ## Run the Python unit tests
	$(PYTHON) -m pytest tests -q

ci: validate test ## Exactly what CI runs (no .derive_output.json required)
	$(PYTHON) -m gaussian_codegen.cdf.emit_test_vectors --check
