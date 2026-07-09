# Convenience targets for the offline coefficient toolkit.
#
# Run `make install` once (into a venv - see README), then use the targets
# below. Override the interpreter with `make PYTHON=/path/to/python <target>`.
# The emitters format their own output via the repo's prettier
# (`node_modules/.bin/prettier`), so run `npm ci` at the repo root first.
PYTHON ?= python3

.PHONY: install regen validate check check-cdf check-pdf check-inverse-cdf ci test

install: ## Install the package + dev dependencies into the active environment
	$(PYTHON) -m pip install -e ".[dev]"

regen: ## Re-derive coefficients and emit every generated Move file (prettier-formatted)
	$(PYTHON) -m gaussian_codegen.cdf.derive
	$(PYTHON) -m gaussian_codegen.cdf.emit_coefficients
	$(PYTHON) -m gaussian_codegen.cdf.emit_test_vectors
	$(PYTHON) -m gaussian_codegen.pdf.derive
	$(PYTHON) -m gaussian_codegen.pdf.emit_coefficients
	$(PYTHON) -m gaussian_codegen.pdf.emit_test_vectors
	$(PYTHON) -m gaussian_codegen.inverse_cdf.derive
	$(PYTHON) -m gaussian_codegen.inverse_cdf.emit_coefficients
	$(PYTHON) -m gaussian_codegen.inverse_cdf.emit_test_vectors

validate: ## Re-check the committed coefficients against the oracle (the CI gate)
	$(PYTHON) -m gaussian_codegen.cdf.validate
	$(PYTHON) -m gaussian_codegen.pdf.validate
	$(PYTHON) -m gaussian_codegen.inverse_cdf.validate

check: check-cdf check-pdf check-inverse-cdf ## Drift-check generated files vs the emitters (both exact; needs prettier)

check-cdf:
	$(PYTHON) -m gaussian_codegen.cdf.emit_coefficients --check
	$(PYTHON) -m gaussian_codegen.cdf.emit_test_vectors --check

check-pdf:
	$(PYTHON) -m gaussian_codegen.pdf.emit_coefficients --check
	$(PYTHON) -m gaussian_codegen.pdf.emit_test_vectors --check

check-inverse-cdf:
	$(PYTHON) -m gaussian_codegen.inverse_cdf.emit_coefficients --check
	$(PYTHON) -m gaussian_codegen.inverse_cdf.emit_test_vectors --check

test: ## Run the Python unit tests
	$(PYTHON) -m pytest tests -q

ci: validate test check ## Exactly what CI runs
