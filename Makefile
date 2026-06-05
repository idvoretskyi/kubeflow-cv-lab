# kubeflow-cv-lab — developer tasks
#
#   make platform-install           # install Kubeflow (auto-detects webhook sources)
#   make platform-install PRESET=lke  # install using the LKE preset
#   make platform-uninstall         # remove Kubeflow from the current cluster context
#   make venv                       # create a local virtualenv with the pipeline SDK
#   make compile                    # compile pipeline/pipeline.py -> pipeline/pipeline.yaml
#   make examples-compile           # compile examples/kubeflow-pipelines/*.py -> *.yaml
#   make lint                       # ruff + yamllint (best-effort; installs into the venv)
#   make deploy                     # kubectl apply -k deploy/ (requires a configured kubeconfig)
#   make tofu-init                  # tofu init -backend-config=tofu/backend.conf
#   make tofu-plan                  # tofu plan -var-file=tofu/tofu.tfvars
#   make tofu-apply                 # tofu apply -var-file=tofu/tofu.tfvars
#   make tofu-destroy               # tofu destroy -var-file=tofu/tofu.tfvars
#   make clean                      # remove the venv and compiled artifacts

VENV ?= .venv
PY   := $(VENV)/bin/python
PIP  := $(VENV)/bin/pip

NAMESPACE ?= cv-lab
PRESET    ?=
TOFU_DIR  := tofu

.PHONY: platform-install platform-uninstall venv compile examples-compile lint deploy \
        tofu-init tofu-plan tofu-apply tofu-destroy serve clean help

help:
	@echo "Targets: platform-install platform-uninstall venv compile examples-compile lint deploy"
	@echo "         tofu-init tofu-plan tofu-apply tofu-destroy serve clean"

# ---------------------------------------------------------------------------
# Platform (Kubeflow install / uninstall)
# ---------------------------------------------------------------------------

platform-install:
	@if [ -n "$(PRESET)" ]; then \
		echo "Using preset: $(PRESET)"; \
	elif [ -f platform/config.env ]; then \
		echo "Using platform/config.env"; \
	else \
		echo "Note: no preset or config.env — using built-in defaults (auto webhook detection)."; \
		echo "  Use PRESET=lke for Linode/Akamai LKE, or copy platform/config.env.example."; \
	fi
	PRESET=$(PRESET) sh platform/install.sh

platform-uninstall:
	sh platform/uninstall.sh

# ---------------------------------------------------------------------------
# Pipeline SDK
# ---------------------------------------------------------------------------

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

examples-compile: venv
	@cd examples/kubeflow-pipelines && \
		../../$(VENV)/bin/python hello_pipeline.py && \
		../../$(VENV)/bin/python gpu_pipeline.py && \
		echo "Compiled: hello_pipeline.yaml gpu_pipeline.yaml"

lint:
	$(PIP) install --quiet ruff yamllint
	$(VENV)/bin/ruff check . || true
	$(VENV)/bin/yamllint -d relaxed . || true

deploy:
	kubectl apply -k deploy/

serve:
	kubectl apply -k serving/

# ---------------------------------------------------------------------------
# Tofu (MLflow + Postgres platform layer)
# ---------------------------------------------------------------------------
# Prerequisites:
#   cp tofu/backend.conf.example tofu/backend.conf   # fill in Linode OBJ keys
#   cp tofu/tofu.tfvars.example  tofu/tofu.tfvars    # set postgres_storage_class

tofu-init:
	tofu -chdir=$(TOFU_DIR) init -backend-config=backend.conf

tofu-plan:
	tofu -chdir=$(TOFU_DIR) plan -var-file=tofu.tfvars

tofu-apply:
	tofu -chdir=$(TOFU_DIR) apply -var-file=tofu.tfvars

tofu-destroy:
	tofu -chdir=$(TOFU_DIR) destroy -var-file=tofu.tfvars

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean:
	rm -rf $(VENV) pipeline/pipeline.yaml
