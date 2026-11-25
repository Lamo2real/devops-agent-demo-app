SHELL := /bin/bash
VENV  := .venv
PY    := $(VENV)/bin/python
STAMP := $(VENV)/.installed

.DEFAULT_GOAL := help
help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

$(STAMP): requirements-dev.txt
	@if command -v uv >/dev/null; then uv venv -q --allow-existing -p 3.13 $(VENV) && uv pip install -q --python $(PY) -r requirements-dev.txt; \
	else python3 -m venv $(VENV) && $(PY) -m pip install -q -r requirements-dev.txt; fi
	@touch $(STAMP)

test: $(STAMP) ## Unit tests, Terraform fmt/validate/mock tests (no AWS needed)
	AWS_DEFAULT_REGION=eu-north-1 TABLE_NAME=test $(PY) -m pytest -q
	terraform fmt -check -recursive terraform
	@for stack in main bootstrap; do \
	  echo "terraform $$stack: init, validate, test"; \
	  TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack init -backend=false -input=false >/dev/null && \
	  TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack validate && \
	  { [ ! -d terraform/$$stack/tests ] || TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack test; } || exit 1; \
	done

.PHONY: help test
