# images/

## serving/

KServe custom predictor that wraps Ultralytics YOLO, published as
`ghcr.io/idvoretskyi/kubeflow-cv-lab-serving` (`:latest` and `:<git-sha>`).

| File | Purpose |
|---|---|
| `Dockerfile` | `python:3.12-slim` + CPU-only PyTorch 2.14.1, runs as non-root |
| `server.py` | `kserve.Model` subclass that loads weights from MLflow and serves the V1 predict API |
| `requirements.txt` | `ultralytics==8.4.174`, `kserve>=0.18,<0.19`, `mlflow-skinny==3.17.0`, `Pillow` |

`.github/workflows/build-serving.yml` builds the image on every PR that touches
`images/serving/**` and pushes it from `main`.

No other custom images exist. Training uses `ultralytics/ultralytics` as a KFP
`base_image`, and MLflow uses the official `ghcr.io/mlflow/mlflow` image.
