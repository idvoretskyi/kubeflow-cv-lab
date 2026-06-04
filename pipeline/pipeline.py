"""Kubeflow Pipeline v2: YOLOv8 training on the Aquarium Combined dataset.

Stages
------
  load_data  — download dataset from Roboflow Universe (YOLOv8 format)
  train      — train yolov8n.pt on a GPU node; log to MLflow (proxied artifacts)
  evaluate   — run val on best.pt; emit mAP50 / mAP50-95
  register   — register the model in the MLflow Model Registry

GPU scheduling (mirrors examples/kubeflow-pipelines/gpu_pipeline.py):
  * set_accelerator_type / set_accelerator_limit  — hard placement guarantee
  * add_toleration                                — tolerate nvidia.com/gpu taint
  * add_node_selector                             — GFD label nvidia.com/gpu.present=true

Override env vars at compile time for a different cluster:
  GPU_NODE_SELECTOR_KEY   (default: nvidia.com/gpu.present)
  GPU_NODE_SELECTOR_VALUE (default: true)
  GPU_TAINT_KEY           (default: nvidia.com/gpu)
  GPU_TAINT_EFFECT        (default: NoSchedule)
  GPU_NODE_SELECTOR_KEY="" to disable the node selector.

Compile:
    python pipeline/pipeline.py    # writes pipeline/pipeline.yaml
Or:
    make compile
"""

import os

from kfp import compiler, dsl
from kfp import kubernetes

# ---------------------------------------------------------------------------
# GPU scheduling config (env-overridable; no cloud-specific literals)
# ---------------------------------------------------------------------------
GPU_NODE_SELECTOR_KEY = os.environ.get("GPU_NODE_SELECTOR_KEY", "nvidia.com/gpu.present")
GPU_NODE_SELECTOR_VALUE = os.environ.get("GPU_NODE_SELECTOR_VALUE", "true")
GPU_TAINT_KEY = os.environ.get("GPU_TAINT_KEY", "nvidia.com/gpu")
GPU_TAINT_EFFECT = os.environ.get("GPU_TAINT_EFFECT", "NoSchedule")

# ---------------------------------------------------------------------------
# Component images
# ---------------------------------------------------------------------------
_ULTRALYTICS = "ultralytics/ultralytics:latest"
_PYTHON = "python:3.11-slim"


# ---------------------------------------------------------------------------
# Step 1: load_data
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=_PYTHON,
    packages_to_install=["roboflow==1.1.66"],
)
def load_data(
    workspace: str,
    project: str,
    version: int,
    dataset: dsl.Output[dsl.Dataset],
) -> None:
    """Download a Roboflow Universe dataset in YOLOv8 format."""
    import os

    from roboflow import Roboflow

    api_key = os.environ["ROBOFLOW_API_KEY"]
    rf = Roboflow(api_key=api_key)
    proj = rf.workspace(workspace).project(project)
    ver = proj.version(version)
    dl = ver.download("yolov8", location=dataset.path)
    print(f"Dataset downloaded to: {dl.location}")


# ---------------------------------------------------------------------------
# Step 2: train
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=_ULTRALYTICS,
    packages_to_install=["mlflow>=2.10"],
)
def train(
    dataset: dsl.Input[dsl.Dataset],
    model_variant: str,
    epochs: int,
    imgsz: int,
    mlflow_tracking_uri: str,
    experiment_name: str,
    model_dir: dsl.Output[dsl.Model],
) -> str:
    """Train YOLOv8 on the dataset; log to MLflow; return the MLflow run ID."""
    import glob
    import os
    import shutil

    import mlflow
    from ultralytics import YOLO, settings

    # Point Ultralytics' built-in MLflow callback at our self-hosted server.
    mlflow.set_tracking_uri(mlflow_tracking_uri)
    mlflow.set_experiment(experiment_name)

    # Enable Ultralytics → MLflow integration.
    settings.update({"mlflow": True})

    # Locate the data.yaml inside the downloaded dataset.
    data_yamls = glob.glob(os.path.join(dataset.path, "**", "data.yaml"), recursive=True)
    if not data_yamls:
        raise FileNotFoundError(f"No data.yaml found under {dataset.path}")
    data_yaml = data_yamls[0]
    print(f"Using data config: {data_yaml}")

    with mlflow.start_run() as run:
        model = YOLO(model_variant)
        model.train(
            data=data_yaml,
            epochs=epochs,
            imgsz=imgsz,
            project=model_dir.path,
            name="train",
            exist_ok=True,
        )
        run_id = run.info.run_id

    # Copy best.pt to the canonical model_dir root so downstream steps find it.
    best_candidates = glob.glob(
        os.path.join(model_dir.path, "**", "best.pt"), recursive=True
    )
    if best_candidates:
        dest = os.path.join(model_dir.path, "best.pt")
        if os.path.abspath(best_candidates[0]) != os.path.abspath(dest):
            shutil.copy(best_candidates[0], dest)
        print(f"best.pt → {dest}")
    else:
        print("WARNING: best.pt not found in train output")

    print(f"MLflow run_id: {run_id}")
    return run_id


# ---------------------------------------------------------------------------
# Step 3: evaluate
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=_ULTRALYTICS,
    packages_to_install=["mlflow>=2.10"],
)
def evaluate(
    dataset: dsl.Input[dsl.Dataset],
    model_dir: dsl.Input[dsl.Model],
    mlflow_tracking_uri: str,
    run_id: str,
) -> float:
    """Run validation; log mAP50-95 to the existing MLflow run; return it."""
    import glob
    import os

    import mlflow
    from ultralytics import YOLO

    mlflow.set_tracking_uri(mlflow_tracking_uri)

    data_yamls = glob.glob(os.path.join(dataset.path, "**", "data.yaml"), recursive=True)
    data_yaml = data_yamls[0]

    best_pt = os.path.join(model_dir.path, "best.pt")
    if not os.path.exists(best_pt):
        candidates = glob.glob(
            os.path.join(model_dir.path, "**", "best.pt"), recursive=True
        )
        best_pt = candidates[0] if candidates else best_pt

    model = YOLO(best_pt)
    results = model.val(data=data_yaml)
    map50_95 = float(results.box.map)
    map50 = float(results.box.map50)
    print(f"mAP50: {map50:.4f}  mAP50-95: {map50_95:.4f}")

    with mlflow.start_run(run_id=run_id):
        mlflow.log_metrics({"val/mAP50": map50, "val/mAP50-95": map50_95})

    return map50_95


# ---------------------------------------------------------------------------
# Step 4: register
# ---------------------------------------------------------------------------
@dsl.component(
    base_image=_PYTHON,
    packages_to_install=["mlflow>=2.10", "boto3"],
)
def register(
    run_id: str,
    registered_model_name: str,
    mlflow_tracking_uri: str,
    map50_95: float,
) -> str:
    """Register the trained model in the MLflow Model Registry."""
    import mlflow
    from mlflow import MlflowClient

    mlflow.set_tracking_uri(mlflow_tracking_uri)
    client = MlflowClient()

    model_uri = f"runs:/{run_id}/weights"
    mv = mlflow.register_model(model_uri, registered_model_name)
    print(f"Registered: {registered_model_name} v{mv.version}  (run {run_id})")
    print(f"mAP50-95: {map50_95:.4f}")

    client.set_model_version_tag(
        registered_model_name, str(mv.version), "mAP50-95", f"{map50_95:.4f}"
    )

    return f"models:/{registered_model_name}/{mv.version}"


# ---------------------------------------------------------------------------
# Pipeline definition
# ---------------------------------------------------------------------------
@dsl.pipeline(
    name="yolov8-aquarium-training",
    description=(
        "Roboflow → YOLOv8 GPU training → MLflow tracking & registry → "
        "model URI for KServe serving."
    ),
)
def yolov8_pipeline(
    roboflow_workspace: str = "roboflow-jvuqo",
    roboflow_project: str = "aquarium-combined",
    roboflow_version: int = 6,
    model_variant: str = "yolov8n.pt",
    epochs: int = 10,
    imgsz: int = 640,
    mlflow_tracking_uri: str = "http://mlflow.cv-lab:5000",
    experiment_name: str = "aquarium-yolov8",
    registered_model_name: str = "yolov8-aquarium",
) -> None:
    # ------------------------------------------------------------------
    # load_data — CPU, reads Roboflow API key from K8s secret
    # ------------------------------------------------------------------
    load_task = load_data(
        workspace=roboflow_workspace,
        project=roboflow_project,
        version=roboflow_version,
    )
    kubernetes.use_secret_as_env(
        load_task,
        secret_name="roboflow-api-key",
        secret_key_to_env={"ROBOFLOW_API_KEY": "ROBOFLOW_API_KEY"},
    )

    # ------------------------------------------------------------------
    # train — GPU required
    # ------------------------------------------------------------------
    train_task = train(
        dataset=load_task.outputs["dataset"],
        model_variant=model_variant,
        epochs=epochs,
        imgsz=imgsz,
        mlflow_tracking_uri=mlflow_tracking_uri,
        experiment_name=experiment_name,
    )

    # GPU contract (matches AGENTS.md)
    train_task.set_accelerator_type("nvidia.com/gpu")
    train_task.set_accelerator_limit(1)
    kubernetes.add_toleration(
        train_task,
        key=GPU_TAINT_KEY,
        operator="Exists",
        effect=GPU_TAINT_EFFECT,
    )
    if GPU_NODE_SELECTOR_KEY:
        kubernetes.add_node_selector(
            train_task,
            label_key=GPU_NODE_SELECTOR_KEY,
            label_value=GPU_NODE_SELECTOR_VALUE,
        )

    # ------------------------------------------------------------------
    # evaluate — CPU (keeps the GPU free after training)
    # ------------------------------------------------------------------
    eval_task = evaluate(
        dataset=load_task.outputs["dataset"],
        model_dir=train_task.outputs["model_dir"],
        mlflow_tracking_uri=mlflow_tracking_uri,
        run_id=train_task.outputs["Output"],
    )

    # ------------------------------------------------------------------
    # register — CPU
    # ------------------------------------------------------------------
    register(
        run_id=train_task.outputs["Output"],
        registered_model_name=registered_model_name,
        mlflow_tracking_uri=mlflow_tracking_uri,
        map50_95=eval_task.outputs["Output"],
    )


# ---------------------------------------------------------------------------
# Compile when run directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import pathlib

    out = pathlib.Path(__file__).parent / "pipeline.yaml"
    compiler.Compiler().compile(pipeline_func=yolov8_pipeline, package_path=str(out))
    print(f"Compiled → {out}")
