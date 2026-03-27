# KitchenLoop — Makefile for development, testing, and dogfooding
#
# Targets:
#   make lint        — shellcheck all bash scripts
#   make test-smoke  — quick sanity checks (syntax, sourcing, structure)
#   make test        — full test suite (lint + smoke + integration)
#   make check       — alias for test

SHELL := /bin/bash
.DEFAULT_GOAL := test

SCRIPTS := $(shell find scripts lib -name '*.sh' -type f 2>/dev/null)

# ─── Lint ──────────────────────────────────────────────────────────
.PHONY: lint
lint:
	@echo "==> shellcheck ($(words $(SCRIPTS)) files)"
	@shellcheck --severity=warning $(SCRIPTS)
	@echo "    All clean."

# ─── Smoke Tests ───────────────────────────────────────────────────
.PHONY: test-smoke
test-smoke:
	@echo "==> Smoke tests"
	@bash tests/smoke.sh
	@echo "    All smoke tests passed."

# ─── Integration Tests ─────────────────────────────────────────────
.PHONY: test-integration
test-integration:
	@echo "==> Integration tests"
	@bash tests/test-ticket-lifecycle.sh
	@echo "    All integration tests passed."

# ─── Full Test Suite ───────────────────────────────────────────────
.PHONY: test
test: lint test-smoke test-integration
	@echo ""
	@echo "==> All tests passed."

.PHONY: check
check: test
