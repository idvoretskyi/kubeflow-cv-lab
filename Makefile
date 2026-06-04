# kubeflow-cv-lab — developer tasks
#
#   make venv       # create a local virtualenv with the pipeline SDK
#   make compile    # compile pipeline/pipeline.py -> pipeline/pipeline.yaml
#   make lint       # ruff + yamllint (best-effort; installs into the venv)
#   make deploy     # kubectl apply -k deploy/ (requires a configured kubeconfig)
#   make clean      # remove the venv and compiled artifacts
#
# NOTE: deploy/, pipeline/, and serving/ are filled in during later phases.
# The targets are defined now so the workflow is stable from day one.

VENV ?= .venv
PY   := $(VENV)/bin/python
PIP  := $(VENV)/bin/pip

NAMESPACE ?= cv-lab

.PHONY: venv compile lint deploy clean help

help:
	@echo "Targets: venv compile lint deploy clean"

venv:
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	@if [ -f pipeline/requirements.txt ]; then $(PIP) install -r pipeline/requirements.txt; fi

compile:
	@if [ -f pipeline/pipeline.py ]; then \
		$(PY) pipeline/pipeline.py && echo "Compiled: pipeline/pipeline.yaml"; \
	else \
		echo "pipeline/pipeline.py not present yet (added in a later phase)."; \
	fi

lint:
	$(PIP) install --quiet ruff yamllint
	$(VENV)/bin/ruff check . || true
	$(VENV)/bin/yamllint -d relaxed . || true

deploy:
	kubectl apply -k deploy/

clean:
	rm -rf $(VENV) pipeline/pipeline.yaml
