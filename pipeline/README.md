# pipeline/

Kubeflow Pipeline (KFP v2). Added in **Phase 3**.

Planned contents:

- `pipeline.py` — `load_data → train → evaluate → register`.
- `pipeline.yaml` — compiled IR, committed (CI checks for drift).
- `requirements.txt` — `kfp`, `kfp-kubernetes`.

The `train` step runs on the GPU pool (toleration + node selector + GPU request),
uses `ultralytics/ultralytics` as the base image, and logs to MLflow via proxied
artifacts. Compile with `make compile`.
