# Compile the demo Kubeflow pipelines to their IR YAML.
#
#   make venv      # create a local virtualenv with the KFP SDK
#   make compile   # compile *.py -> *.yaml
#   make clean     # remove the venv and compiled artifacts

VENV ?= .venv
PY   := $(VENV)/bin/python

.PHONY: venv compile clean

venv:
	python3 -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r requirements.txt

compile:
	$(PY) hello_pipeline.py
	$(PY) gpu_pipeline.py
	@echo "Compiled: hello_pipeline.yaml gpu_pipeline.yaml"

clean:
	rm -rf $(VENV) hello_pipeline.yaml gpu_pipeline.yaml
