# pipeline/

Kubeflow Pipeline (KFP v2): end-to-end YOLOv8 training on the
[Aquarium Combined](https://universe.roboflow.com/roboflow-jvuqo/aquarium-combined)
dataset.

## Stages

```text
load_data → train → evaluate → register
```

| Step | Image | GPU | What it does |
|---|---|---|---|
| `load_data` | `python:3.11-slim` + roboflow | No | Downloads dataset from Roboflow Universe (YOLOv8 format) |
| `train` | `ultralytics/ultralytics` + mlflow | **Yes** | Trains `yolov8n.pt`; logs params/metrics/weights to MLflow via proxied artifacts |
| `evaluate` | `ultralytics/ultralytics` + mlflow | No | Runs `val`; logs `mAP50` / `mAP50-95` to the existing MLflow run |
| `register` | `python:3.11-slim` + mlflow + boto3 | No | Registers model in MLflow Model Registry; returns `models:/yolov8-aquarium/<version>` |

## Prerequisites

- `cv-lab` Profile applied (`kubectl apply -f deploy/profile.yaml`)
- Secrets present in `cv-lab`: `roboflow-api-key`, `seaweedfs-s3-credentials`, `postgres-credentials`
- MLflow running (`kubectl rollout status deployment/mlflow -n cv-lab`)
- `s3://mlflow` bucket created (`kubectl apply -f deploy/mlflow/create-bucket-job.yaml`)

## Compile

```bash
make compile          # pipeline/pipeline.py → pipeline/pipeline.yaml
```

The compiled `pipeline.yaml` is committed; CI fails on drift.

## Submit (in-cluster Notebook)

From a Kubeflow Notebook running in the `cv-lab` profile:

```python
import kfp
client = kfp.Client()          # uses in-cluster SA token automatically
client.create_run_from_pipeline_package(
    "pipeline.yaml",
    arguments={},              # all params have defaults
    run_name="aquarium-yolov8-run-1",
    experiment_name="aquarium-yolov8",
)
```

## Pipeline parameters

| Parameter | Default | Description |
|---|---|---|
| `roboflow_workspace` | `roboflow-jvuqo` | Roboflow workspace slug |
| `roboflow_project` | `aquarium-combined` | Project slug |
| `roboflow_version` | `6` | Dataset version (latest) |
| `model_variant` | `yolov8n.pt` | Ultralytics model checkpoint |
| `epochs` | `10` | Training epochs (raise to 50+ for real runs) |
| `imgsz` | `640` | Input image size |
| `mlflow_tracking_uri` | `http://mlflow.cv-lab:5000` | MLflow server (in-cluster) |
| `experiment_name` | `aquarium-yolov8` | MLflow experiment name |
| `registered_model_name` | `yolov8-aquarium` | MLflow Model Registry name |
