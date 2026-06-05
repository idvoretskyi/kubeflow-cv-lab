# images/

Container images that must be built and pushed.

## serving/

KServe custom predictor wrapping Ultralytics YOLOv8. Published to
`ghcr.io/idvoretskyi/kubeflow-cv-lab-serving`.

| File | Purpose |
|---|---|
| `Dockerfile` | CPU-only image: `python:3.11-slim` + CPU torch + ultralytics + kserve |
| `server.py` | `kserve.Model` subclass — loads weights from MLflow, serves V1 predict API |
| `requirements.txt` | `ultralytics`, `kserve>=0.13,<0.17`, `mlflow==2.22.0`, `Pillow` |

The image is built and pushed automatically by
`.github/workflows/build-serving.yml` on every push that touches
`images/serving/**`.

The trainer step needs **no** custom image — it uses `ultralytics/ultralytics`
directly as a KFP `base_image`. The MLflow server uses the official
`ghcr.io/mlflow/mlflow` image with drivers installed at pod start.
