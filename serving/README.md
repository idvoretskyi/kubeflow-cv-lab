# serving/

KServe `InferenceService` manifests for the trained YOLOv8 model.

Apply with:

```bash
make serve
# or
kubectl apply -k serving/
```

## Files

| File | Purpose |
|---|---|
| `inference-service.yaml` | `InferenceService` in `cv-lab` — custom predictor loading from MLflow |
| `kustomization.yaml` | kustomize entry point |

## Model source

The predictor fetches model weights from the MLflow Model Registry at pod
startup via `mlflow.artifacts.download_artifacts("models:/yolov8-coco128/1")`.
MLflow proxies the artifact download over HTTP — the pod does **not** need
direct S3 credentials.

## Inference protocol

KServe V1 prediction protocol:

```text
POST /v1/models/yolov8-coco128:predict
{"instances": [{"image": {"b64": "<base64 PNG/JPEG>"}}]}
```
