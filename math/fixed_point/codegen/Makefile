# Convenience targets for the offline coefficient toolkit.
#
# Run `make install` once (into a venv — see README), then use the targets
# below. Override the interpreter with `make PYTHON=/path/to/python <target>`.
PYTHON ?= python3

.PHONY: install regen validate check ci test

install: ## Install the package + dev dependencies into the active environment
	$(PYTHON) -m pip install -e ".[dev]"

regen: ## Re-derive coefficients and emit every generated Move file
	$(PYTHON) -m codegen.cdf.derive
	$(PYTHON) -m codegen.cdf.emit_coefficients
	$(PYTHON) -m codegen.cdf.emit_test_vectors

validate: ## Re-check the committed coefficients against scipy (the CI gate)
	$(PYTHON) -m codegen.cdf.validate

check: ## Assert every committed Move file matches its generator (needs a prior `regen`)
	$(PYTHON) -m codegen.cdf.emit_coefficients --check
	$(PYTHON) -m codegen.cdf.emit_test_vectors --check

test: ## Run the Python unit tests
	$(PYTHON) -m pytest tests -q

ci: validate test ## Exactly what CI runs (no .derive_output.json required)
	$(PYTHON) -m codegen.cdf.emit_test_vectors --check
