"""Single source of truth for runtime versions baked into compiled pipelines.

Keep in sync with:
  * deploy/base/mlflow/deployment.yaml (ghcr.io/mlflow/mlflow:v<MLFLOW_VERSION>)
  * images/serving/requirements.txt (mlflow==<MLFLOW_VERSION>)
"""

MLFLOW_VERSION = "3.17.0"
ULTRALYTICS_IMAGE = "ultralytics/ultralytics:8.4.174"
PYTHON_IMAGE = "python:3.12-slim"
CUDA_BASE_IMAGE = "nvidia/cuda:13.4.2-base-ubuntu24.04"
