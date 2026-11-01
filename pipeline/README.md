# pipeline/

KFP v2 pipeline `yolov8-training`: `load_data → train → evaluate → register`.

| File | Purpose |
|---|---|
| `pipeline.py` | Pipeline source |
| `pipeline.yaml` | Compiled IR (committed; CI fails on drift) |
| `gpu_scheduling.py` | Shared GPU scheduling contract (also used by `examples/`) |
| `versions.py` | Pinned MLflow version and base images |
| `requirements.txt` | Pinned KFP SDK (`kfp==2.17.0`, `kfp-kubernetes==2.17.0`) |

```bash
make compile   # pipeline.py -> pipeline.yaml (commit the result)
```

Upload `pipeline.yaml` in the Kubeflow Pipelines UI and create a run.

## Steps

| Step | Image | Resources | Notes |
|---|---|---|---|
| `load_data` | `python:3.12-slim` | CPU | Downloads a YOLO-format zip and patches `data.yaml` |
| `train` | `ultralytics/ultralytics:8.4.174` | **1 GPU**, 2 vCPU, 6–12 Gi, 2 Gi `/dev/shm` | Logs to MLflow, returns the run ID |
| `evaluate` | `ultralytics/ultralytics:8.4.174` | CPU, 1 vCPU, 2–4 Gi | Logs `val/mAP50` and `val/mAP50-95` |
| `register` | `python:3.12-slim` | CPU | Creates a model version, tags mAP, sets alias `champion` |

## Parameters

| Parameter | Default |
|---|---|
| `dataset_url` | `https://ultralytics.com/assets/coco128.zip` |
| `dataset_yaml_url` | Ultralytics `coco128.yaml` (leave empty if the zip has `data.yaml`) |
| `model_variant` | `yolov8n.pt` |
| `epochs` | `10` |
| `imgsz` | `640` |
| `mlflow_tracking_uri` | `http://mlflow.cv-lab:5000` |
| `experiment_name` | `coco128-yolov8` |
| `registered_model_name` | `yolov8-coco128` |

## GPU scheduling

See `gpu_scheduling.py`. GPU steps request `nvidia.com/gpu: 1`, tolerate the
`nvidia.com/gpu` taint, and select `nvidia.com/gpu.present=true` (the GFD label).
CPU steps only tolerate the taint (`GPU_TOLERATE_CPU_STEPS=0` disables this).
Override the selector at compile time, for example for strict LKE pool pinning:

```bash
GPU_NODE_SELECTOR_KEY=nodepool.lke/role GPU_NODE_SELECTOR_VALUE=gpu make compile
```

Do not commit YAML compiled with cloud-specific labels.
