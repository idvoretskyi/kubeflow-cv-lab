# images/

Container images that must be built and pushed. Added in **Phase 4**.

Planned contents:

- `serving/` — KServe custom predictor wrapping Ultralytics YOLO
  (`Dockerfile`, `model.py`, `requirements.txt`). Published to
  `ghcr.io/idvoretskyi/kubeflow-cv-lab-serving`.

The trainer step needs **no** custom image — it uses `ultralytics/ultralytics`
directly as a KFP `base_image`. The MLflow server uses the official
`ghcr.io/mlflow/mlflow` image with drivers installed at pod start.
