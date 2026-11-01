# serving/

KServe `InferenceService` for the trained YOLO model. It runs in **Standard**
(raw Deployment) mode, so it needs no Knative, and uses a CPU-only predictor.

```bash
make serve                    # kubectl apply -k serving/ + wait for Ready
make port-forward-predictor   # http://localhost:8080
```

## Model source

At startup the predictor (`images/serving/server.py`) downloads
`models:/yolov8-coco128@champion` from MLflow over HTTP. MLflow proxies the
artifacts, so the pod needs no S3 credentials. The pipeline's `register` step
moves the `champion` alias. To pick up a newer model:

```bash
kubectl -n cv-lab rollout restart deploy/yolov8-coco128-predictor
```

## Inference protocol (KServe V1)

```text
POST /v1/models/yolov8-coco128:predict
{"instances": [{"image": {"b64": "<base64 PNG/JPEG>"}}]}
```

The response has `predictions[]` entries with `boxes` (xyxy), `scores`,
`class_ids` and `class_names`.
