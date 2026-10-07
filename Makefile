# kubeflow-cv-lab — developer tasks. `make help` lists targets.
#
# Zero to a served model on a GPU cluster with the NVIDIA GPU Operator:
#   make platform-install PRESET=lke   # Kubeflow 26.03.1, minimal profile
#   make bootstrap                     # cv-lab Profile + Secrets
#   make deploy OVERLAY=lke            # Postgres + MLflow
#   make compile                       # then upload pipeline/pipeline.yaml in the KFP UI
#   make serve                         # KServe InferenceService (after the run)

VENV    ?= .venv
PY      := $(VENV)/bin/python
PIP     := $(VENV)/bin/pip

PRESET  ?=
OVERLAY ?=
DEPLOY_DIR := $(if $(OVERLAY),deploy/overlays/$(OVERLAY),deploy)
TOFU_DIR   := tofu

.DEFAULT_GOAL := help
.PHONY: help platform-install platform-uninstall bootstrap deploy serve \
        venv compile examples-compile lint \
        port-forward-dashboard port-forward-kfp port-forward-mlflow port-forward-predictor \
        tofu-init tofu-plan tofu-apply tofu-destroy clean

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Platform -----------------------------------------------------------------

platform-install: ## Install Kubeflow (PRESET=lke, KF_PROFILE=minimal|full)
	PRESET=$(PRESET) sh platform/install.sh

platform-uninstall: ## Remove Kubeflow from the current kube context
	PRESET=$(PRESET) sh platform/uninstall.sh

# --- Lab layer ----------------------------------------------------------------

bootstrap: ## Create the cv-lab Profile and Secrets (idempotent)
	sh deploy/bootstrap.sh

deploy: ## Deploy Postgres + MLflow (OVERLAY=lke for Linode block storage)
	kubectl apply -k $(DEPLOY_DIR)
	kubectl -n cv-lab rollout status deploy/postgres --timeout=300s
	kubectl -n cv-lab rollout status deploy/mlflow --timeout=600s

serve: ## Deploy the KServe InferenceService (needs a registered model)
	kubectl apply -k serving/
	kubectl -n cv-lab wait isvc/yolov8-coco128 --for=condition=Ready --timeout=900s

# --- Pipelines ----------------------------------------------------------------

$(PY):
	python3 -m venv $(VENV)
	$(PIP) install --quiet --upgrade pip
	$(PIP) install --quiet -r pipeline/requirements.txt ruff yamllint

venv: $(PY) ## Create the local virtualenv (KFP SDK, ruff, yamllint)

compile: $(PY) ## Compile pipeline/pipeline.py -> pipeline/pipeline.yaml
	$(PY) pipeline/pipeline.py

examples-compile: $(PY) ## Compile examples/kubeflow-pipelines/*.py
	$(PY) examples/kubeflow-pipelines/hello_pipeline.py
	$(PY) examples/kubeflow-pipelines/gpu_pipeline.py

lint: $(PY) ## ruff + yamllint + shellcheck (same as CI)
	$(VENV)/bin/ruff check .
	$(VENV)/bin/yamllint -c .yamllint.yaml .
	shellcheck -s sh platform/*.sh deploy/*.sh

# --- Access -------------------------------------------------------------------

port-forward-dashboard: ## Central Dashboard on http://localhost:8080
	kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80

port-forward-kfp: ## Pipelines API/UI on http://localhost:8888
	kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8888:80

port-forward-mlflow: ## MLflow UI on http://localhost:5000
	kubectl -n cv-lab port-forward svc/mlflow 5000:5000

port-forward-predictor: ## KServe predictor on http://localhost:8080
	kubectl -n cv-lab port-forward svc/yolov8-coco128-predictor 8080:80

# --- Optional: OpenTofu-managed lab layer (alternative to `make deploy`) ------

tofu-init: ## tofu init (needs tofu/backend.conf)
	tofu -chdir=$(TOFU_DIR) init -backend-config=backend.conf

tofu-plan: ## tofu plan (needs tofu/tofu.tfvars)
	tofu -chdir=$(TOFU_DIR) plan -var-file=tofu.tfvars

tofu-apply: ## tofu apply
	tofu -chdir=$(TOFU_DIR) apply -var-file=tofu.tfvars

tofu-destroy: ## tofu destroy
	tofu -chdir=$(TOFU_DIR) destroy -var-file=tofu.tfvars

clean: ## Remove the virtualenv
	rm -rf $(VENV)
